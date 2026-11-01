use std::sync::Arc;
use chrono::Utc;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use crate::engine::flavours::get_flavour_mapping;
use crate::engine::select::{select_cf_file, select_github_release, select_wago_release};
use crate::logging::append_sync_log;
use crate::net::curseforge::{create_cf_client, get_cf_files};
use crate::net::github::{create_github_client, get_github_releases};
use crate::net::policy::NetworkPolicy;
use crate::net::wago::{create_wago_client, get_wago_releases_page, WagoSession};


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
    append_sync_log(Some(flavour), "INFO", "Starting check (dry run)...");

    let cf_client = create_cf_client().map_err(|e| e.to_string())?;
    let wago_client = create_wago_client().map_err(|e| e.to_string())?;
    let github_client = create_github_client().map_err(|e| e.to_string())?;
    let wago_session = WagoSession::new();

    let mapping = get_flavour_mapping(flavour, client_interface);

    // 1. Fetch addons for this flavour
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
    }

    let mut stmt = conn
        .prepare(
            "SELECT id, name, source, project_id, wago_slug, wago_id, repo, file_id, version, installed_tag, pinned_file_id, ignore_updates, release_type, github_rate_limited_until \
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
            })
        })
        .map_err(|e| e.to_string())?;

    let mut addons = Vec::new();
    for r in rows {
        addons.push(r.map_err(|e| e.to_string())?);
    }
    drop(stmt);

    let mut outcomes = Vec::new();

    let mut would_update_count = 0;
    let mut up_to_date_count = 0;
    let mut ignored_count = 0;
    let mut pinned_count = 0;
    let mut failed_count = 0;

    for a in &addons {
        if a.ignore_updates {
            ignored_count += 1;
            outcomes.push(AddonCheckOutcome {
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
            continue;
        }

        if a.pinned_file_id.is_some() {
            pinned_count += 1;
            outcomes.push(AddonCheckOutcome {
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
            continue;
        }

        let src = a.source.as_deref().unwrap_or("curseforge");
        let mut outcome_status = "Up-to-date".to_string();
        let mut upd_ver = None;
        let mut upd_file = None;
        let mut err_msg = None;

        match src {
            "curseforge" => {
                if let Some(pid) = a.project_id {
                    let type_id = mapping.type_id.unwrap_or(517);
                    let prefix = mapping.version_prefix.as_deref().unwrap_or("12.");
                    match get_cf_files(&policy, &cf_client, pid, a.release_type).await {
                        Ok(files) => {
                            if let Some(chosen) = select_cf_file(&files, a.release_type, type_id, prefix) {
                                let chosen_id_str = chosen.id.to_string();
                                let chosen_ver = chosen.display_name.clone().or(chosen.file_name.clone());

                                let is_up_to_date = match (a.file_id.as_deref().and_then(|s| s.parse::<i64>().ok()), Some(chosen.id)) {
                                    (Some(curr_fid), Some(target_fid)) => {
                                        curr_fid >= target_fid
                                    }
                                    _ => {
                                        a.file_id.as_deref() == Some(&chosen_id_str)
                                            || is_version_equivalent(a.version.as_deref(), chosen_ver.as_deref())
                                    }
                                };

                                if !is_up_to_date {
                                    outcome_status = "Would-update".to_string();
                                    upd_file = Some(chosen_id_str);
                                    upd_ver = chosen_ver;
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
                if let Some(ref slug) = a.wago_slug {
                    let wago_field = mapping.wago_field.as_deref().unwrap_or("retail");
                    // Paging with early exit at the first page that yields a selection (Section 3.3)
                    let mut found_selection = None;
                    for page in 1..=10 {
                        match get_wago_releases_page(&policy, &wago_client, &wago_session, slug, page).await {
                            Ok((releases, has_next)) => {
                                if let Some(chosen) = select_wago_release(&releases, a.release_type, wago_field) {
                                    found_selection = Some(chosen);
                                    break;
                                }
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

                    if let Some(chosen) = found_selection {
                        let chosen_ver = chosen.version.clone().or(chosen.name.clone());
                        let is_up_to_date = a.file_id.as_deref() == Some(&chosen.id)
                            || is_version_equivalent(a.version.as_deref(), chosen_ver.as_deref());
                        if !is_up_to_date {
                            outcome_status = "Would-update".to_string();
                            upd_file = Some(chosen.id);
                            upd_ver = chosen_ver;
                        }
                    }
                }
            }
            "github" => {
                if let Some(ref repo) = a.repo {
                    let mut is_rate_limited = false;
                    if let Some(ref until_str) = a.github_rate_limited_until {
                        if let Ok(until_dt) = chrono::DateTime::parse_from_rfc3339(until_str) {
                            if Utc::now() < until_dt.with_timezone(&Utc) {
                                append_sync_log(
                                    Some(flavour),
                                    "INFO",
                                    &format!("{}: GitHub rate limited until {}, skipping check", a.name, until_str),
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
                            match get_github_releases(&policy, &github_client, parts[0], parts[1], github_token.as_deref()).await {
                                Ok(releases) => {
                                    if let Some(chosen) = select_github_release(&releases, a.release_type, None) {
                                        let is_same_tag = a.installed_tag.as_deref() == Some(&chosen.tag_name);
                                        let is_same_ver = a.version.as_deref() == Some(&chosen.tag_name);
                                        let is_same_file = a.file_id.as_deref() == Some(&chosen.tag_name);

                                        if !is_same_tag && !is_same_ver && !is_same_file {
                                            outcome_status = "Would-update".to_string();
                                            upd_file = Some(chosen.tag_name.clone());
                                            upd_ver = Some(chosen.tag_name);
                                        }
                                    }

                                    if a.github_rate_limited_until.is_some() {
                                        let _ = conn.execute(
                                            "UPDATE addons SET github_rate_limited_until = NULL WHERE id = ?1",
                                            params![a.id],
                                        );
                                    }
                                }
                                Err((e, limited_until)) => {
                                    outcome_status = "Failed".to_string();
                                    err_msg = Some(e);
                                    if let Some(until) = limited_until {
                                        let _ = conn.execute(
                                            "UPDATE addons SET github_rate_limited_until = ?1 WHERE id = ?2",
                                            params![until.to_rfc3339(), a.id],
                                        );
                                    }
                                }
                            }
                        }
                    }
                }
            }
            _ => {}
        }

        match outcome_status.as_str() {
            "Would-update" => {
                would_update_count += 1;
                append_sync_log(
                    Some(flavour),
                    "INFO",
                    &format!("{}: Would update to {:?}", a.name, upd_ver),
                );
            }
            "Up-to-date" => {
                up_to_date_count += 1;
                append_sync_log(Some(flavour), "INFO", &format!("{}: Up-to-date", a.name));
            }
            "Failed" => {
                failed_count += 1;
                append_sync_log(
                    Some(flavour),
                    "ERROR",
                    &format!("{}: Failed check: {:?}", a.name, err_msg),
                );
            }
            _ => {}
        }

        outcomes.push(AddonCheckOutcome {
            addon_id: a.id.clone(),
            name: a.name.clone(),
            status: outcome_status,
            current_version: a.version.clone(),
            current_file_id: a.file_id.clone(),
            update_version: upd_ver,
            update_file_id: upd_file,
            error: err_msg,
        });
    }

    // 2. Persist to check_results and freshness tables
    let now = Utc::now().to_rfc3339();
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    for o in &outcomes {
        tx.execute(
            "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![o.addon_id, now, o.update_file_id, o.update_version, o.status, o.error],
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

    Ok(CheckRunReport {
        flavour: flavour.to_string(),
        checked_at: now,
        total: addons.len(),
        would_update_count,
        up_to_date_count,
        ignored_count,
        pinned_count,
        failed_count,
        outcomes,
    })
}
