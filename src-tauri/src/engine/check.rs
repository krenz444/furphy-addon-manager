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
        pinned_file_id: Option<String>,
        ignore_updates: bool,
        release_type: i64,
    }

    let mut stmt = conn
        .prepare(
            "SELECT id, name, source, project_id, wago_slug, wago_id, repo, file_id, version, pinned_file_id, ignore_updates, release_type \
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
                pinned_file_id: r.get(9)?,
                ignore_updates: r.get::<_, i32>(10)? != 0,
                release_type: r.get::<_, Option<i64>>(11)?.unwrap_or(1),
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
                                if a.file_id.as_deref() != Some(&chosen_id_str) {
                                    outcome_status = "Would-update".to_string();
                                    upd_file = Some(chosen_id_str);
                                    upd_ver = chosen.display_name.clone().or(chosen.file_name.clone());
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
                    // Early exit optimization: page 1 first
                    match get_wago_releases_page(&policy, &wago_client, &wago_session, slug, 1).await {
                        Ok((releases, _)) => {
                            if let Some(chosen) = select_wago_release(&releases, a.release_type, wago_field) {
                                if a.file_id.as_deref() != Some(&chosen.id) {
                                    outcome_status = "Would-update".to_string();
                                    upd_file = Some(chosen.id);
                                    upd_ver = chosen.version.clone().or(chosen.name.clone());
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
            "github" => {
                if let Some(ref repo) = a.repo {
                    let parts: Vec<&str> = repo.split('/').collect();
                    if parts.len() == 2 {
                        match get_github_releases(&policy, &github_client, parts[0], parts[1], github_token.as_deref()).await {
                            Ok(releases) => {
                                if let Some(chosen) = select_github_release(&releases, a.release_type, None) {
                                    if a.file_id.as_deref() != Some(&chosen.tag_name) && a.version.as_deref() != Some(&chosen.tag_name) {
                                        outcome_status = "Would-update".to_string();
                                        upd_file = Some(chosen.tag_name.clone());
                                        upd_ver = Some(chosen.tag_name);
                                    }
                                }
                            }
                            Err((e, _)) => {
                                outcome_status = "Failed".to_string();
                                err_msg = Some(e);
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
        "error"
    } else {
        "up_to_date"
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
