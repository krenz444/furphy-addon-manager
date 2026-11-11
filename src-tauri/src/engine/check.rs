use std::sync::Arc;
use chrono::Utc;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;
use tokio::task::JoinSet;
use crate::engine::flavours::{detect_all_installed_flavours, get_flavour_mapping};
use crate::engine::integrity::refresh_integrity_status;
use crate::engine::select::{select_cf_file, select_github_release, select_wago_release, select_wago_release_strict};
use crate::jobs::progress::{JobProgressStep, ProgressTallies};
use crate::logging::append_sync_log;
use crate::net::curseforge::{create_cf_client, get_cf_files};
use crate::net::github::{create_github_client, get_github_releases};
use crate::net::policy::NetworkPolicy;
use crate::net::tukui::create_tukui_client;
use crate::net::wago::{create_wago_client, get_wago_releases_page, WagoSession};
use crate::paths::detect_wow_root;

const CHECK_CONCURRENCY: usize = 6;

pub type ProgressSink = Arc<dyn Fn(JobProgressStep) + Send + Sync>;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddonCheckOutcome {
    pub addon_id: String,
    pub name: String,
    pub status: String, // "Up-to-date", "Would-update", "Pinned", "Ignored", "Failed"
    pub current_version: Option<String>,
    pub current_file_id: Option<String>,
    pub update_version: Option<String>,
    pub update_file_id: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckRunReport {
    pub flavour: String,
    pub checked_at: String,
    pub total: usize,
    pub would_update_count: usize,
    pub up_to_date_count: usize,
    pub ignored_count: usize,
    pub pinned_count: usize,
    pub failed_count: usize,
    #[serde(default)]
    pub held_count: usize,
    #[serde(default)]
    pub modified_count: usize,
    pub outcomes: Vec<AddonCheckOutcome>,
}

pub fn normalize_version_token(v: &str) -> String {
    let trimmed = v.trim();
    let lower = trimmed.to_ascii_lowercase();
    let stripped_prefix = lower.strip_prefix('v').unwrap_or(&lower);
    let stripped_ext = stripped_prefix.strip_suffix(".zip").unwrap_or(stripped_prefix);
    stripped_ext.trim().to_string()
}

pub fn is_version_equivalent(local_ver: Option<&str>, remote_ver: Option<&str>) -> bool {
    match (local_ver, remote_ver) {
        (Some(l), Some(r)) => {
            if l.eq_ignore_ascii_case(r) {
                return true;
            }
            let norm_l = normalize_version_token(l);
            let norm_r = normalize_version_token(r);
            if !norm_l.is_empty() && norm_l == norm_r {
                return true;
            }
            if !norm_l.is_empty() && norm_r.contains(&norm_l) {
                return true;
            }
            false
        }
        _ => false,
    }
}

pub async fn run_check_for_flavour(
    conn: &mut Connection,
    flavour: &str,
    client_interface: Option<i32>,
    policy: Arc<NetworkPolicy>,
    github_token: Option<String>,
) -> Result<CheckRunReport, String> {
    let wago_session = Arc::new(WagoSession::new());
    run_check_for_flavour_with_session_and_progress(
        conn,
        flavour,
        client_interface,
        policy,
        github_token,
        wago_session,
        None,
    )
    .await
}

pub async fn run_check_for_flavour_with_session_and_progress(
    conn: &mut Connection,
    flavour: &str,
    client_interface: Option<i32>,
    policy: Arc<NetworkPolicy>,
    github_token: Option<String>,
    wago_session: Arc<WagoSession>,
    on_progress: Option<ProgressSink>,
) -> Result<CheckRunReport, String> {
    append_sync_log(Some(flavour), "INFO", "Starting check (dry run)...");

    let cf_client = create_cf_client().map_err(|e| e.to_string())?;
    let wago_client = create_wago_client().map_err(|e| e.to_string())?;
    let github_client = create_github_client().map_err(|e| e.to_string())?;
    let tukui_client = create_tukui_client().map_err(|e| e.to_string())?;

    let mapping = get_flavour_mapping(flavour, client_interface);

    let wow_root = detect_wow_root(None).ok();
    let addons_path = detect_all_installed_flavours(conn, wow_root.as_deref())
        .into_iter()
        .find(|f| f.id == flavour)
        .map(|f| f.addons_path);

    let (client_build, update_mode): (Option<String>, String) = conn
        .query_row(
            "SELECT client_build, update_mode FROM flavours WHERE id = ?1",
            params![flavour],
            |r| Ok((r.get(0)?, r.get::<_, Option<String>>(1)?.unwrap_or_else(|| "auto".to_string()))),
        )
        .unwrap_or((None, "auto".to_string()));

    // 1. Fetch addons for this flavour
    #[derive(Clone)]
    struct RowData {
        id: String,
        name: String,
        source: Option<String>,
        project_id: Option<i64>,
        wago_slug: Option<String>,
        _wago_id: Option<String>,
        repo: Option<String>,
        file_id: Option<String>,
        version: Option<String>,
        installed_tag: Option<String>,
        pinned_file_id: Option<String>,
        ignore_updates: bool,
        release_type: i64,
        github_rate_limited_until: Option<String>,
        ignored_until_build: Option<String>,
        auto_update: bool,
        integrity_status: Option<String>,
        tukui_slug: Option<String>,
    }

    let mut stmt = conn
        .prepare(
            "SELECT id, name, source, project_id, wago_slug, wago_id, repo, file_id, version, installed_tag, pinned_file_id, ignore_updates, release_type, github_rate_limited_until, ignored_until_build, auto_update, integrity_status, tukui_slug \
             FROM addons WHERE flavour = ?1 ORDER BY name COLLATE NOCASE ASC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map(params![flavour], |r| {
            Ok(RowData {
                id: r.get(0)?,
                name: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                source: r.get(2)?,
                project_id: r.get(3)?,
                wago_slug: r.get(4)?,
                _wago_id: r.get(5)?,
                repo: r.get(6)?,
                file_id: r.get(7)?,
                version: r.get(8)?,
                installed_tag: r.get(9)?,
                pinned_file_id: r.get(10)?,
                ignore_updates: r.get::<_, i32>(11)? != 0,
                release_type: r.get::<_, Option<i64>>(12)?.unwrap_or(1),
                github_rate_limited_until: r.get(13)?,
                ignored_until_build: r.get(14)?,
                auto_update: r.get::<_, Option<i32>>(15)?.unwrap_or(1) != 0,
                integrity_status: r.get(16)?,
                tukui_slug: r.get(17)?,
            })
        })
        .map_err(|e| e.to_string())?;

    let mut addons = Vec::new();
    for r in rows {
        addons.push(r.map_err(|e| e.to_string())?);
    }
    drop(stmt);

    let total_addons = addons.len();
    let mut outcomes_slots: Vec<Option<AddonCheckOutcome>> = vec![None; total_addons];

    let mut would_update_count = 0;
    let mut up_to_date_count = 0;
    let mut ignored_count = 0;
    let mut pinned_count = 0;
    let mut failed_count = 0;
    let mut held_count = 0;
    let mut modified_count = 0;
    let mut checked_count = 0;

    let mut check_details: std::collections::HashMap<String, (i32, Option<String>)> = std::collections::HashMap::new();

    let emit_step = |checked: usize,
                     would_upd: usize,
                     up_to_date: usize,
                     failed: usize,
                     addon: Option<String>,
                     phase: &str| {
        if let Some(ref cb) = on_progress {
            cb(JobProgressStep {
                total: total_addons,
                index: checked,
                addon,
                phase: phase.to_string(),
                bytes_done: None,
                bytes_total: None,
                tallies: ProgressTallies {
                    checked,
                    updated: 0,
                    failed,
                    up_to_date,
                    updates_found: would_upd,
                },
            });
        }
    };

    if total_addons > 0 {
        emit_step(0, 0, 0, 0, None, "checking");
    }

    struct CheckedAddonFetch {
        idx: usize,
        outcome_status: String,
        upd_ver: Option<String>,
        upd_file: Option<String>,
        targets: Vec<String>,
        err_msg: Option<String>,
        released_at_to_store: Option<Option<String>>,
        clear_github_rate_limit: bool,
        set_github_rate_limit: Option<String>,
    }

    let sem = Arc::new(Semaphore::new(CHECK_CONCURRENCY));
    let mut join_set: JoinSet<CheckedAddonFetch> = JoinSet::new();

    for (idx, a) in addons.iter().enumerate() {
        if a.ignore_updates {
            ignored_count += 1;
            checked_count += 1;
            outcomes_slots[idx] = Some(AddonCheckOutcome {
                addon_id: a.id.clone(),
                name: a.name.clone(),
                status: "Ignored".to_string(),
                current_version: a.version.clone(),
                current_file_id: a.file_id.clone(),
                update_version: None,
                update_file_id: None,
                error: None,
            });
            append_sync_log(Some(flavour), "INFO", &format!("{}: Ignored (updates disabled)", a.name));
            emit_step(
                checked_count,
                would_update_count,
                up_to_date_count,
                failed_count,
                Some(a.name.clone()),
                "checking",
            );
            continue;
        }

        if a.pinned_file_id.is_some() {
            pinned_count += 1;
            checked_count += 1;
            outcomes_slots[idx] = Some(AddonCheckOutcome {
                addon_id: a.id.clone(),
                name: a.name.clone(),
                status: "Pinned".to_string(),
                current_version: a.version.clone(),
                current_file_id: a.file_id.clone(),
                update_version: None,
                update_file_id: a.pinned_file_id.clone(),
                error: None,
            });
            append_sync_log(Some(flavour), "INFO", &format!("{}: Pinned", a.name));
            emit_step(
                checked_count,
                would_update_count,
                up_to_date_count,
                failed_count,
                Some(a.name.clone()),
                "checking",
            );
            continue;
        }

        let src = match a.source.as_deref() {
            Some(s) => s.to_string(),
            None => {
                if a.tukui_slug.is_some() {
                    "tukui".to_string()
                } else if a.repo.is_some() {
                    "github".to_string()
                } else if a.wago_slug.is_some() {
                    "wago".to_string()
                } else if a.project_id.is_some() {
                    "curseforge".to_string()
                } else {
                    "local".to_string()
                }
            }
        };

        let a_clone = a.clone();
        let mapping_clone = mapping.clone();
        let policy_clone = Arc::clone(&policy);
        let cf_client_clone = cf_client.clone();
        let wago_client_clone = wago_client.clone();
        let wago_session_clone = Arc::clone(&wago_session);
        let github_client_clone = github_client.clone();
        let tukui_client_clone = tukui_client.clone();
        let github_token_clone = github_token.clone();
        let flavour_owned = flavour.to_string();
        let client_build_clone = client_build.clone();
        let sem_clone = Arc::clone(&sem);

        join_set.spawn(async move {
            let _permit = sem_clone.acquire_owned().await.ok();

            let mut outcome_status = "Up-to-date".to_string();
            let mut upd_ver = None;
            let mut upd_file = None;
            let mut targets: Vec<String> = Vec::new();
            let mut err_msg = None;
            let mut released_at_to_store: Option<Option<String>> = None;
            let mut clear_github_rate_limit = false;
            let mut set_github_rate_limit = None;

            match src.as_str() {
                "curseforge" => {
                    if let Some(pid) = a_clone.project_id {
                        let type_id = mapping_clone.type_id.unwrap_or(517);
                        let prefix = mapping_clone.version_prefix.as_deref().unwrap_or("12.");
                        match get_cf_files(&policy_clone, &cf_client_clone, pid, a_clone.release_type, mapping_clone.type_id).await {
                            Ok(files) => {
                                if let Some(chosen) = select_cf_file(&files, a_clone.release_type, type_id, prefix) {
                                    targets = crate::engine::holdback::cf_file_targets(&chosen);
                                    let chosen_id_str = chosen.id.to_string();
                                    let chosen_ver = chosen.display_name.clone().or(chosen.file_name.clone());

                                    let is_up_to_date = match (a_clone.file_id.as_deref().and_then(|s| s.parse::<i64>().ok()), Some(chosen.id)) {
                                        (Some(curr_fid), Some(target_fid)) => curr_fid >= target_fid,
                                        _ => {
                                            a_clone.file_id.as_deref() == Some(&chosen_id_str)
                                                || is_version_equivalent(a_clone.version.as_deref(), chosen_ver.as_deref())
                                        }
                                    };

                                    if !is_up_to_date {
                                        outcome_status = "Would-update".to_string();
                                        upd_file = Some(chosen_id_str);
                                        upd_ver = chosen_ver;
                                    } else if a_clone.file_id.as_deref() == Some(&chosen_id_str) {
                                        released_at_to_store = Some(chosen.date_created);
                                    }
                                }
                            }
                            Err(e) => {
                                outcome_status = "Failed".to_string();
                                err_msg = Some(e);
                            }
                        }
                    }
                }
                "wago" => {
                    if let Some(ref slug) = a_clone.wago_slug {
                        let wago_field = mapping_clone.wago_field.as_deref().unwrap_or("retail");
                        // Multi-page search: prioritize strict flavour match across all pages first (ADR-323)
                        let mut all_releases = Vec::new();
                        let mut found_selection = None;
                        for page in 1..=10 {
                            match get_wago_releases_page(&policy_clone, &wago_client_clone, &wago_session_clone, slug, page).await {
                                Ok((releases, has_next)) => {
                                    if let Some(chosen) = select_wago_release_strict(&releases, a_clone.release_type, wago_field) {
                                        found_selection = Some(chosen);
                                        break;
                                    }
                                    all_releases.extend(releases);
                                    if !has_next {
                                        break;
                                    }
                                }
                                Err(e) => {
                                    outcome_status = "Failed".to_string();
                                    err_msg = Some(e);
                                    break;
                                }
                            }
                        }
                        if found_selection.is_none() && err_msg.is_none() && !all_releases.is_empty() {
                            found_selection = select_wago_release(&all_releases, a_clone.release_type, wago_field);
                        }

                        if let Some(chosen) = found_selection {
                            targets = crate::engine::holdback::wago_release_targets(&chosen, wago_field);
                            let chosen_ver = chosen.version.clone().or(chosen.name.clone());
                            let is_up_to_date = a_clone.file_id.as_deref() == Some(&chosen.id)
                                || is_version_equivalent(a_clone.version.as_deref(), chosen_ver.as_deref());
                            if !is_up_to_date {
                                outcome_status = "Would-update".to_string();
                                upd_file = Some(chosen.id);
                                upd_ver = chosen_ver;
                            } else if a_clone.file_id.as_deref() == Some(&chosen.id) {
                                released_at_to_store = Some(chosen.created_at);
                            }
                        }
                    }
                }
                "github" => {
                    if let Some(ref repo) = a_clone.repo {
                        let mut is_rate_limited = false;
                        if let Some(ref until_str) = a_clone.github_rate_limited_until {
                            if let Ok(until_dt) = chrono::DateTime::parse_from_rfc3339(until_str) {
                                if Utc::now() < until_dt.with_timezone(&Utc) {
                                    append_sync_log(
                                        Some(&flavour_owned),
                                        "INFO",
                                        &format!("{}: GitHub rate limited until {}, skipping check", a_clone.name, until_str),
                                    );
                                    outcome_status = "Failed".to_string();
                                    err_msg = Some(format!("GitHub rate limited until {}", until_str));
                                    is_rate_limited = true;
                                }
                            }
                        }

                        if !is_rate_limited {
                            let parts: Vec<&str> = repo.split('/').collect();
                            if parts.len() == 2 {
                                match get_github_releases(&policy_clone, &github_client_clone, parts[0], parts[1], github_token_clone.as_deref()).await {
                                    Ok(releases) => {
                                        if let Some(chosen) = select_github_release(&releases, a_clone.release_type, None, Some(&flavour_owned)) {
                                            let is_same_tag = a_clone.installed_tag.as_deref() == Some(&chosen.tag_name);
                                            let is_same_ver = a_clone.version.as_deref() == Some(&chosen.tag_name);
                                            let is_same_file = a_clone.file_id.as_deref() == Some(&chosen.tag_name);

                                            if !is_same_tag && !is_same_ver && !is_same_file {
                                                outcome_status = "Would-update".to_string();
                                                upd_file = Some(chosen.tag_name.clone());
                                                upd_ver = Some(chosen.tag_name);
                                            } else if is_same_file || is_same_tag {
                                                released_at_to_store = Some(chosen.published_at);
                                            }
                                        }

                                        if a_clone.github_rate_limited_until.is_some() {
                                            clear_github_rate_limit = true;
                                        }
                                    }
                                    Err((e, limited_until)) => {
                                        outcome_status = "Failed".to_string();
                                        err_msg = Some(e);
                                        if let Some(until) = limited_until {
                                            set_github_rate_limit = Some(until.to_rfc3339());
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                "tukui" => {
                    if let Some(ref slug) = a_clone.tukui_slug {
                        match crate::engine::tukui::choose_tukui_release(
                            &policy_clone,
                            &tukui_client_clone,
                            slug,
                            &flavour_owned,
                            &mapping_clone.era_label,
                            client_build_clone.as_deref(),
                        )
                        .await
                        {
                            Ok(chosen) => {
                                let is_same_file = a_clone.file_id.as_deref() == Some(&chosen.file_id);
                                let is_same_ver = a_clone.version.as_deref() == Some(&chosen.version)
                                    || is_version_equivalent(a_clone.version.as_deref(), Some(&chosen.version));

                                if !is_same_file && !is_same_ver {
                                    outcome_status = "Would-update".to_string();
                                    upd_file = Some(chosen.file_id.clone());
                                    upd_ver = Some(chosen.version);
                                } else if is_same_file {
                                    released_at_to_store = Some(chosen.released);
                                }
                            }
                            Err(e) => {
                                outcome_status = "Failed".to_string();
                                err_msg = Some(e);
                            }
                        }
                    }
                }
                "zip" | "local" | "adopted" => {}
                _ => {}
            }

            CheckedAddonFetch {
                idx,
                outcome_status,
                upd_ver,
                upd_file,
                targets,
                err_msg,
                released_at_to_store,
                clear_github_rate_limit,
                set_github_rate_limit,
            }
        });
    }

    while let Some(joined) = join_set.join_next().await {
        let fetched = match joined {
            Ok(res) => res,
            Err(join_err) => {
                append_sync_log(Some(flavour), "ERROR", &format!("Check task panicked: {}", join_err));
                failed_count += 1;
                checked_count += 1;
                emit_step(
                    checked_count,
                    would_update_count,
                    up_to_date_count,
                    failed_count,
                    None,
                    "failed",
                );
                continue;
            }
        };

        let a = &addons[fetched.idx];

        if let Some(ref rel) = fetched.released_at_to_store {
            crate::engine::released::store_released_at(conn, &a.id, rel.as_deref());
        }
        if fetched.clear_github_rate_limit {
            let _ = conn.execute(
                "UPDATE addons SET github_rate_limited_until = NULL WHERE id = ?1",
                params![a.id],
            );
        }
        if let Some(ref until) = fetched.set_github_rate_limit {
            let _ = conn.execute(
                "UPDATE addons SET github_rate_limited_until = ?1 WHERE id = ?2",
                params![until, a.id],
            );
        }

        let mut held_val = 0;
        let mut held_reason_val = None;

        let integrity_now: Option<String> = addons_path
            .as_deref()
            .and_then(|p| refresh_integrity_status(conn, p, &a.id))
            .or_else(|| a.integrity_status.clone());

        let step_phase = match fetched.outcome_status.as_str() {
            "Would-update" => {
                would_update_count += 1;
                append_sync_log(
                    Some(flavour),
                    "INFO",
                    &format!("{}: Would update to {:?}", a.name, fetched.upd_ver),
                );

                let p_ctx = crate::engine::update_policy::PolicyContext {
                    addon_id: &a.id,
                    name: &a.name,
                    flavour,
                    client_build: client_build.as_deref(),
                    target_game_versions: &fetched.targets,
                    ignored_until_build: a.ignored_until_build.as_deref(),
                    ignore_updates: a.ignore_updates,
                    is_pinned: a.pinned_file_id.is_some(),
                    auto_update: a.auto_update,
                    update_mode: &update_mode,
                    origin: crate::engine::update_policy::SyncOrigin::Manual,
                    override_hold: false,
                    override_modified: false,
                    integrity_status: integrity_now.as_deref(),
                    is_newer: true,
                    force: false,
                };
                let action = crate::engine::update_policy::decide(&p_ctx);
                if let crate::engine::update_policy::PolicyAction::SkipHeld { reason } = action {
                    held_count += 1;
                    held_val = 1;
                    held_reason_val = Some(reason);
                }
                "checking"
            }
            "Up-to-date" => {
                up_to_date_count += 1;
                append_sync_log(Some(flavour), "INFO", &format!("{}: Up-to-date", a.name));
                "up_to_date"
            }
            "Failed" => {
                failed_count += 1;
                append_sync_log(
                    Some(flavour),
                    "ERROR",
                    &format!("{}: Failed check: {:?}", a.name, fetched.err_msg),
                );
                "failed"
            }
            _ => "checking",
        };

        if !fetched.targets.is_empty() {
            let _ = crate::engine::holdback::store_latest_game_versions(conn, &a.id, &fetched.targets);
        }

        if integrity_now.as_deref() == Some("modified") {
            modified_count += 1;
        }

        check_details.insert(a.id.clone(), (held_val, held_reason_val));

        outcomes_slots[fetched.idx] = Some(AddonCheckOutcome {
            addon_id: a.id.clone(),
            name: a.name.clone(),
            status: fetched.outcome_status,
            current_version: a.version.clone(),
            current_file_id: a.file_id.clone(),
            update_version: fetched.upd_ver,
            update_file_id: fetched.upd_file,
            error: fetched.err_msg,
        });

        checked_count += 1;
        emit_step(
            checked_count,
            would_update_count,
            up_to_date_count,
            failed_count,
            Some(a.name.clone()),
            step_phase,
        );
    }

    let outcomes: Vec<AddonCheckOutcome> = outcomes_slots.into_iter().flatten().collect();

    // 2. Persist to check_results and freshness tables
    let now = Utc::now().to_rfc3339();
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    for o in &outcomes {
        let (held, held_reason) = check_details.get(&o.addon_id).cloned().unwrap_or((0, None));
        tx.execute(
            "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error, held, held_reason) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![o.addon_id, now, o.update_file_id, o.update_version, o.status, o.error, held, held_reason],
        )
        .map_err(|e| e.to_string())?;
    }

    let overall_state = if would_update_count > 0 {
        "updates_ready"
    } else if failed_count > 0 && up_to_date_count == 0 {
        "failed"
    } else {
        "clean"
    };

    tx.execute(
        "INSERT OR REPLACE INTO freshness (flavour, state, checked_at, last_success_at, last_error) \
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            flavour,
            overall_state,
            now,
            if failed_count == 0 { Some(now.clone()) } else { None },
            if failed_count > 0 { Some(format!("{} check(s) failed", failed_count)) } else { None }
        ],
    )
    .map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    append_sync_log(
        Some(flavour),
        "INFO",
        &format!(
            "Check complete: {} would update, {} up-to-date, {} ignored, {} pinned, {} failed",
            would_update_count, up_to_date_count, ignored_count, pinned_count, failed_count
        ),
    );

    emit_step(
        total_addons,
        would_update_count,
        up_to_date_count,
        failed_count,
        None,
        "done",
    );

    Ok(CheckRunReport {
        flavour: flavour.to_string(),
        checked_at: now,
        total: addons.len(),
        would_update_count,
        up_to_date_count,
        ignored_count,
        pinned_count,
        failed_count,
        held_count,
        modified_count,
        outcomes,
    })
}
