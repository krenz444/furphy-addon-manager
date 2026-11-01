use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use chrono::Utc;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use crate::db::export_v1::export_to_v1;
use crate::engine::archive::extract_addon_archive;
use crate::engine::backups::{cleanup_orphaned_backups, create_backup_zip, record_and_prune_backup};
use crate::engine::flavours::get_flavour_mapping;
use crate::engine::ownership::{check_folder_ownership_conflicts, get_protected_folders};
use crate::engine::select::{select_cf_file, select_github_asset, select_github_release, select_wago_release};
use crate::engine::staging::prepare_flavour_staging_dir;
use crate::engine::swap::execute_atomic_swap;
use crate::engine::toc::{find_primary_toc, parse_toc_file, strip_wow_formatting};
use crate::engine::wtf::take_wtf_snapshot;
use crate::logging::append_sync_log;
use crate::net::curseforge::{create_cf_client, download_cf_file, get_cf_file_by_id, get_cf_files, CfFile};
use crate::net::github::{create_github_client, download_github_asset, get_github_releases};
use crate::net::policy::NetworkPolicy;
use crate::net::wago::{create_wago_client, download_wago_release, get_wago_releases_page, WagoRelease, WagoSession};
use crate::paths::get_v1_sync_folder;
use crate::system::game::is_wow_running;


#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddonSyncResult {
    pub addon_id: String,
    pub name: String,
    pub status: String, // "Up-to-date", "Updated", "Installed", "Failed", "Skipped", "Pinned", "Ignored"
    pub previous_version: Option<String>,
    pub new_version: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncRunReport {
    pub flavour: String,
    pub started_at: String,
    pub finished_at: String,
    pub updated: usize,
    pub up_to_date: usize,
    pub failed: usize,
    pub reload_needed: bool,
    pub results: Vec<AddonSyncResult>,
}

pub async fn run_sync_for_flavour(
    conn: &mut Connection,
    wow_root: &Path,
    flavour: &str,
    flavour_folder: &str,
    addons_path: &Path,
    data_dir: &Path,
    client_interface: Option<i32>,
    policy: Arc<NetworkPolicy>,
    github_token: Option<String>,
    only_addon_ids: Option<&[String]>,
    force: bool,
) -> Result<SyncRunReport, String> {
    let started_at = Utc::now().to_rfc3339();
    append_sync_log(Some(flavour), "INFO", "Starting addon sync...");

    let cf_client = create_cf_client().map_err(|e| e.to_string())?;
    let wago_client = create_wago_client().map_err(|e| e.to_string())?;
    let github_client = create_github_client().map_err(|e| e.to_string())?;
    let wago_session = WagoSession::new();

    let mapping = get_flavour_mapping(flavour, client_interface);

    // 1. Fetch addons for this flavour
    struct SyncRow {
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
        adopted: bool,
    }

    let mut stmt = conn
        .prepare(
            "SELECT id, name, source, project_id, wago_slug, wago_id, repo, file_id, version, pinned_file_id, ignore_updates, release_type, adopted \
             FROM addons WHERE flavour = ?1 ORDER BY name COLLATE NOCASE ASC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map(params![flavour], |r| {
            Ok(SyncRow {
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
                adopted: r.get::<_, i32>(12)? != 0,
            })
        })
        .map_err(|e| e.to_string())?;

    let mut addons = Vec::new();
    for r in rows {
        addons.push(r.map_err(|e| e.to_string())?);
    }

    let mut results = Vec::new();
    let mut updated_count = 0;
    let mut up_to_date_count = 0;
    let mut failed_count = 0;
    let mut any_installed_while_game_running = false;

    let staging_root = prepare_flavour_staging_dir(data_dir, flavour).map_err(|e| e.to_string())?;

    for a in &addons {
        if let Some(ref only_ids) = only_addon_ids {
            if !only_ids.contains(&a.id) {
                continue;
            }
        }

        if a.ignore_updates && !force && only_addon_ids.is_none() {
            results.push(AddonSyncResult {
                addon_id: a.id.clone(),
                name: a.name.clone(),
                status: "Ignored".to_string(),
                previous_version: a.version.clone(),
                new_version: a.version.clone(),
                error: None,
            });
            continue;
        }

        // If the addon has no remote provider configured (e.g. locally adopted addon without upstream source):
        if a.project_id.is_none() && a.wago_slug.is_none() && a.repo.is_none() {
            up_to_date_count += 1;
            let now_str = Utc::now().to_rfc3339();
            let _ = conn.execute(
                "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
                 VALUES (?1, ?2, NULL, NULL, 'up_to_date', NULL)",
                params![a.id, now_str],
            );
            results.push(AddonSyncResult {
                addon_id: a.id.clone(),
                name: a.name.clone(),
                status: "Up-to-date".to_string(),
                previous_version: a.version.clone(),
                new_version: a.version.clone(),
                error: None,
            });
            append_sync_log(Some(flavour), "INFO", &format!("{}: Up-to-date (local/adopted)", a.name));
            continue;
        }

        // Retrieve existing folders for this addon
        let mut fstmt = conn
            .prepare("SELECT folder FROM addon_folders WHERE addon_id = ?1 AND flavour = ?2")
            .map_err(|e| e.to_string())?;
        let frows = fstmt
            .query_map(params![a.id, flavour], |fr| fr.get::<_, String>(0))
            .map_err(|e| e.to_string())?;
        let previous_folders: Vec<String> = frows.flatten().collect();

        let src = a.source.as_deref().unwrap_or("curseforge");
        let safe_id = a.id.replace([':', '/', '\\', '*', '?', '"', '<', '>', '|'], "_");
        let download_zip_path = staging_root.join(format!("{}.zip", safe_id));
        let extract_dir = staging_root.join(&safe_id);

        let mut chosen_file_id: Option<String> = None;
        let mut chosen_version: Option<String> = None;
        let mut chosen_file_name: Option<String> = None;
        let mut sync_error: Option<String> = None;

        let mut target_addon_id = a.id.clone();
        let mut target_addon_name = a.name.clone();
        let mut prev_backup_file_id = a.file_id.clone();
        let mut prev_backup_version = a.version.clone();

        // Step 1: Query and download
        match src {
            "curseforge" => {
                if let Some(pid) = a.project_id {
                    let type_id = mapping.type_id.unwrap_or(517);
                    let prefix = mapping.version_prefix.as_deref().unwrap_or("12.");

                    let target_file: Option<CfFile> = if let Some(ref pin) = a.pinned_file_id {
                        if let Ok(fid) = pin.parse::<i64>() {
                            get_cf_file_by_id(&policy, &cf_client, pid, fid).await.unwrap_or(None)
                        } else {
                            None
                        }
                    } else {
                        match get_cf_files(&policy, &cf_client, pid, a.release_type).await {
                            Ok(files) => select_cf_file(&files, a.release_type, type_id, prefix),
                            Err(e) => {
                                sync_error = Some(e);
                                None
                            }
                        }
                    };

                    if let Some(cf_file) = target_file {
                        let cf_id_str = cf_file.id.to_string();
                        let is_already_current_or_newer = if let Some(ref curr_fid) = a.file_id {
                            if curr_fid == &cf_id_str {
                                true
                            } else if let Ok(c_id) = curr_fid.parse::<i64>() {
                                c_id >= cf_file.id
                            } else {
                                false
                            }
                        } else {
                            false
                        };

                        if !force && is_already_current_or_newer {
                            up_to_date_count += 1;
                            let now_str = Utc::now().to_rfc3339();
                            let _ = conn.execute(
                                "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
                                 VALUES (?1, ?2, NULL, NULL, 'up_to_date', NULL)",
                                params![a.id, now_str],
                            );
                            results.push(AddonSyncResult {
                                addon_id: a.id.clone(),
                                name: a.name.clone(),
                                status: "Up-to-date".to_string(),
                                previous_version: a.version.clone(),
                                new_version: a.version.clone(),
                                error: None,
                            });
                            append_sync_log(Some(flavour), "INFO", &format!("{}: Up-to-date", a.name));
                            continue;
                        }

                        chosen_file_id = Some(cf_id_str);
                        chosen_version = cf_file.display_name.clone().or(cf_file.file_name.clone());
                        chosen_file_name = cf_file.file_name.clone();

                        if let Err(e) = download_cf_file(&policy, &cf_client, pid, &cf_file, &download_zip_path).await {
                            sync_error = Some(e);
                        }
                    } else if sync_error.is_none() {
                        sync_error = Some("No compatible CurseForge file found".to_string());
                    }
                } else {
                    sync_error = Some("CurseForge addon missing project ID".to_string());
                }
            }
            "wago" => {
                if let Some(ref slug) = a.wago_slug {
                    let wago_field = mapping.wago_field.as_deref().unwrap_or("retail");
                    let target_release: Option<WagoRelease> = if let Some(ref pin) = a.pinned_file_id {
                        // For pinned, page up to 10
                        let mut found = None;
                        for page in 1..=10 {
                            if let Ok((rel_page, has_next)) = get_wago_releases_page(&policy, &wago_client, &wago_session, slug, page).await {
                                if let Some(r) = rel_page.iter().find(|rel| &rel.id == pin) {
                                    found = Some(r.clone());
                                    break;
                                }
                                if !has_next {
                                    break;
                                }
                            } else {
                                break;
                            }
                        }
                        found
                    } else {
                        // Paging with early exit at the first page that yields a selection (Section 3.3)
                        let mut chosen = None;
                        for page in 1..=10 {
                            match get_wago_releases_page(&policy, &wago_client, &wago_session, slug, page).await {
                                Ok((rel_page, has_next)) => {
                                    if let Some(sel) = select_wago_release(&rel_page, a.release_type, wago_field) {
                                        chosen = Some(sel);
                                        break;
                                    }
                                    if !has_next {
                                        break;
                                    }
                                }
                                Err(e) => {
                                    sync_error = Some(e);
                                    break;
                                }
                            }
                        }
                        chosen
                    };

                    if let Some(wago_rel) = target_release {
                        if !force && a.file_id.as_deref() == Some(&wago_rel.id) {
                            up_to_date_count += 1;
                            let now_str = Utc::now().to_rfc3339();
                            let _ = conn.execute(
                                "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
                                 VALUES (?1, ?2, NULL, NULL, 'up_to_date', NULL)",
                                params![a.id, now_str],
                            );
                            results.push(AddonSyncResult {
                                addon_id: a.id.clone(),
                                name: a.name.clone(),
                                status: "Up-to-date".to_string(),
                                previous_version: a.version.clone(),
                                new_version: a.version.clone(),
                                error: None,
                            });
                            append_sync_log(Some(flavour), "INFO", &format!("{}: Up-to-date", a.name));
                            continue;
                        }

                        chosen_file_id = Some(wago_rel.id.clone());
                        chosen_version = wago_rel.version.clone().or(wago_rel.name.clone());
                        chosen_file_name = Some(format!("{}-{}.zip", slug, wago_rel.id));

                        if let Some(dl_url) = wago_rel.url {
                            if let Err(e) = download_wago_release(&policy, &wago_client, &dl_url, wago_rel.size, &download_zip_path).await {
                                sync_error = Some(e);
                            }
                        } else {
                            sync_error = Some("Wago release has no download URL".to_string());
                        }
                    } else if sync_error.is_none() {
                        sync_error = Some("No compatible Wago release found".to_string());
                    }
                } else {
                    sync_error = Some("Wago addon missing slug".to_string());
                }
            }
            "github" => {
                if let Some(ref repo) = a.repo {
                    let parts: Vec<&str> = repo.split('/').collect();
                    if parts.len() == 2 {
                        match get_github_releases(&policy, &github_client, parts[0], parts[1], github_token.as_deref()).await {
                            Ok(releases) => {
                                let pin_ref = a.pinned_file_id.as_deref();
                                if let Some(chosen) = select_github_release(&releases, a.release_type, pin_ref) {
                                    if !force && (a.file_id.as_deref() == Some(&chosen.tag_name) || a.version.as_deref() == Some(&chosen.tag_name)) {
                                        up_to_date_count += 1;
                                        let now_str = Utc::now().to_rfc3339();
                                        let _ = conn.execute(
                                            "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
                                             VALUES (?1, ?2, NULL, NULL, 'up_to_date', NULL)",
                                            params![a.id, now_str],
                                        );
                                        results.push(AddonSyncResult {
                                            addon_id: a.id.clone(),
                                            name: a.name.clone(),
                                            status: "Up-to-date".to_string(),
                                            previous_version: a.version.clone(),
                                            new_version: a.version.clone(),
                                            error: None,
                                        });
                                        append_sync_log(Some(flavour), "INFO", &format!("{}: Up-to-date", a.name));
                                        continue;
                                    }

                                    chosen_file_id = Some(chosen.tag_name.clone());
                                    chosen_version = Some(chosen.tag_name.clone());

                                    // Pick best asset with .zip, else zipball
                                    let asset_opt = select_github_asset(&chosen, &repo);
                                    let is_zipball = asset_opt.is_none();
                                    let dl_url = asset_opt
                                        .map(|ast| ast.url.clone())
                                        .or(chosen.zipball_url.clone());

                                    if let Some(url) = dl_url {
                                        let target_dl_path = if is_zipball {
                                            staging_root.join(format!("{}_raw.zip", safe_id))
                                        } else {
                                            download_zip_path.clone()
                                        };
                                        let expected_digest = asset_opt.and_then(|ast| ast.digest.as_deref());
                                        if let Err(e) = download_github_asset(
                                            &policy,
                                            &github_client,
                                            &url,
                                            github_token.as_deref(),
                                            expected_digest,
                                            &target_dl_path,
                                        )
                                        .await
                                        {
                                            sync_error = Some(e);
                                        } else if is_zipball {
                                            let repo_name = parts[1].strip_suffix(".git").unwrap_or(parts[1]);
                                            if let Err(e) = crate::engine::archive::normalize_github_zipball(
                                                &target_dl_path,
                                                repo_name,
                                                &download_zip_path,
                                            ) {
                                                sync_error = Some(format!("Failed normalizing GitHub zipball: {}", e));
                                            }
                                        }
                                    } else {
                                        sync_error = Some("No download asset or zipball available".to_string());
                                    }
                                } else {
                                    sync_error = Some("No compatible GitHub release found".to_string());
                                }
                            }
                            Err((e, _)) => {
                                sync_error = Some(e);
                            }
                        }
                    } else {
                        sync_error = Some(format!("Invalid GitHub repository format: '{}'", repo));
                    }
                } else {
                    sync_error = Some("GitHub addon missing repository".to_string());
                }
            }
            _ => {
                sync_error = Some(format!("Unknown source '{}'", src));
            }
        }

        if let Some(err) = sync_error {
            failed_count += 1;
            let now_str = Utc::now().to_rfc3339();
            let _ = conn.execute(
                "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
                 VALUES (?1, ?2, ?3, ?4, 'failed', ?5)",
                params![a.id, now_str, a.file_id, a.version, &err],
            );
            results.push(AddonSyncResult {
                addon_id: a.id.clone(),
                name: a.name.clone(),
                status: "Failed".to_string(),
                previous_version: a.version.clone(),
                new_version: None,
                error: Some(err.clone()),
            });
            append_sync_log(Some(flavour), "ERROR", &format!("{}: Failed: {}", a.name, err));
            continue;
        }

        // Step 2: Safe extraction
        let candidate_folders = match extract_addon_archive(&download_zip_path, &extract_dir) {
            Ok(c) => c,
            Err(e) => {
                failed_count += 1;
                let emsg = format!("Archive extraction error: {}", e);
                let now_str = Utc::now().to_rfc3339();
                let _ = conn.execute(
                    "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
                     VALUES (?1, ?2, ?3, ?4, 'failed', ?5)",
                    params![a.id, now_str, a.file_id, a.version, &emsg],
                );
                results.push(AddonSyncResult {
                    addon_id: a.id.clone(),
                    name: a.name.clone(),
                    status: "Failed".to_string(),
                    previous_version: a.version.clone(),
                    new_version: None,
                    error: Some(emsg.clone()),
                });
                append_sync_log(Some(flavour), "ERROR", &format!("{}: Failed: {}", a.name, emsg));
                continue;
            }
        };

        // Step 3: Ownership conflict check
        let mut conflicts = match check_folder_ownership_conflicts(conn, flavour, &candidate_folders, Some(&target_addon_id)) {
            Ok(c) => c,
            Err(e) => {
                failed_count += 1;
                let emsg = e.to_string();
                let now_str = Utc::now().to_rfc3339();
                let _ = conn.execute(
                    "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
                     VALUES (?1, ?2, ?3, ?4, 'failed', ?5)",
                    params![target_addon_id, now_str, a.file_id, a.version, &emsg],
                );
                results.push(AddonSyncResult {
                    addon_id: target_addon_id.clone(),
                    name: target_addon_name.clone(),
                    status: "Failed".to_string(),
                    previous_version: a.version.clone(),
                    new_version: None,
                    error: Some(emsg),
                });
                continue;
            }
        };

        if !conflicts.is_empty() {
            let mut can_adopt_existing = false;
            let mut existing_addon_id_to_replace: Option<String> = None;

            if a.file_id.is_none() {
                let mut stmt_find_owners = conn.prepare(
                    "SELECT DISTINCT addon_id FROM addon_folders WHERE flavour = ?1 AND folder = ?2 COLLATE NOCASE"
                ).ok();
                if let Some(ref mut stmt) = stmt_find_owners {
                    let mut owners = std::collections::HashSet::new();
                    for folder in &candidate_folders {
                        if let Ok(mut rows) = stmt.query(params![flavour, folder]) {
                            while let Ok(Some(row)) = rows.next() {
                                if let Ok(owner_id) = row.get::<_, String>(0) {
                                    owners.insert(owner_id);
                                }
                            }
                        }
                    }

                    if owners.len() == 1 {
                        let conflicting_id = owners.into_iter().next().unwrap();
                        let mut stmt_owned = conn.prepare(
                            "SELECT folder FROM addon_folders WHERE flavour = ?1 AND addon_id = ?2"
                        ).ok();
                        if let Some(ref mut s_owned) = stmt_owned {
                            if let Ok(owned_rows) = s_owned.query_map(params![flavour, conflicting_id], |r| r.get::<_, String>(0)) {
                                let owned_folders: Vec<String> = owned_rows.flatten().collect();
                                let all_owned_in_candidates = !owned_folders.is_empty() && owned_folders.iter().all(|of| {
                                    candidate_folders.iter().any(|cf| cf.eq_ignore_ascii_case(of))
                                });

                                if all_owned_in_candidates {
                                    can_adopt_existing = true;
                                    existing_addon_id_to_replace = Some(conflicting_id);
                                }
                            }
                        }
                    }
                }
            }

            if can_adopt_existing {
                if let Some(existing_id) = existing_addon_id_to_replace {
                    append_sync_log(
                        Some(flavour),
                        "INFO",
                        &format!("Upgrading existing addon {} to {} (source: {})", existing_id, target_addon_name, src),
                    );

                    let existing_backup_info: Option<(Option<String>, Option<String>)> = conn.query_row(
                        "SELECT file_id, version FROM addons WHERE id = ?1",
                        params![existing_id],
                        |r| Ok((r.get(0)?, r.get(1)?)),
                    ).ok();

                    let _ = conn.execute(
                        "UPDATE addons SET source = ?1, project_id = ?2, wago_slug = ?3, wago_id = ?4, repo = ?5, name = ?6 WHERE id = ?7",
                        params![a.source, a.project_id, a.wago_slug, a._wago_id, a.repo, target_addon_name, existing_id],
                    );

                    let _ = conn.execute("DELETE FROM addons WHERE id = ?1", params![target_addon_id]);
                    let _ = conn.execute("DELETE FROM check_results WHERE addon_id = ?1", params![target_addon_id]);

                    target_addon_id = existing_id;
                    if let Some((ex_fid, ex_ver)) = existing_backup_info {
                        if ex_fid.is_some() || ex_ver.is_some() {
                            prev_backup_file_id = ex_fid;
                            prev_backup_version = ex_ver;
                        }
                    }
                    conflicts.clear();
                }
            }
        }

        if !conflicts.is_empty() {
            failed_count += 1;
            let (f, owner) = &conflicts[0];
            let emsg = format!("Folder '{}' is already owned by {}", f, owner);
            let now_str = Utc::now().to_rfc3339();
            let _ = conn.execute(
                "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
                 VALUES (?1, ?2, ?3, ?4, 'failed', ?5)",
                params![target_addon_id, now_str, a.file_id, a.version, &emsg],
            );
            results.push(AddonSyncResult {
                addon_id: target_addon_id.clone(),
                name: target_addon_name.clone(),
                status: "Failed".to_string(),
                previous_version: a.version.clone(),
                new_version: None,
                error: Some(emsg.clone()),
            });
            append_sync_log(Some(flavour), "ERROR", &format!("{}: Failed: {}", target_addon_name, emsg));
            continue;
        }

        // Step 4: WTF snapshot before swap (ADR-314) - union of previous_folders and candidate_folders
        let mut snapshot_folders = previous_folders.clone();
        for f in &candidate_folders {
            if !snapshot_folders.iter().any(|existing| existing.eq_ignore_ascii_case(f)) {
                snapshot_folders.push(f.clone());
            }
        }
        let _ = take_wtf_snapshot(
            conn,
            wow_root,
            flavour_folder,
            &target_addon_id,
            &snapshot_folders,
            data_dir,
            "pre-update",
        );

        // Step 5: Backup outgoing version
        if !previous_folders.is_empty() {
            let target_safe_id = target_addon_id.replace([':', '/', '\\', '*', '?', '"', '<', '>', '|'], "_");
            let backup_dir = data_dir.join("backups").join(flavour).join(&target_safe_id);
            let safe_file_id = if let Some(ref fid) = prev_backup_file_id {
                fid.replace([':', '/', '\\', '*', '?', '"', '<', '>', '|'], "_")
            } else {
                format!("backup_{}", Utc::now().format("%Y%m%d_%H%M%S"))
            };
            let backup_file = backup_dir.join(format!("{}.zip", safe_file_id));
            let kind = if a.adopted { "pre-adopt" } else { "update" };

            if let Ok(size) = create_backup_zip(addons_path, &previous_folders, &backup_file) {
                let _ = record_and_prune_backup(
                    conn,
                    &target_addon_id,
                    flavour,
                    kind,
                    prev_backup_file_id.as_deref(),
                    prev_backup_version.as_deref(),
                    &backup_file,
                    size,
                );
            }
        }

        // Step 6: Atomic swap
        let protected = match get_protected_folders(conn, flavour, Some(&target_addon_id)) {
            Ok(p) => p,
            Err(_) => HashSet::new(),
        };

        let installed_folders = match execute_atomic_swap(
            addons_path,
            &extract_dir,
            &candidate_folders,
            &previous_folders,
            &protected,
        ) {
            Ok(f) => f,
            Err(e) => {
                failed_count += 1;
                let now_str = Utc::now().to_rfc3339();
                let _ = conn.execute(
                    "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
                     VALUES (?1, ?2, ?3, ?4, 'failed', ?5)",
                    params![a.id, now_str, a.file_id, a.version, &e],
                );
                results.push(AddonSyncResult {
                    addon_id: a.id.clone(),
                    name: a.name.clone(),
                    status: "Failed".to_string(),
                    previous_version: a.version.clone(),
                    new_version: None,
                    error: Some(e.clone()),
                });
                append_sync_log(Some(flavour), "ERROR", &format!("{}: Failed swap: {}", a.name, e));
                continue;
            }
        };

        // Step 7: Parse installed .toc files across all installed folders to collect required deps and identify primary title/version
        let mut required_deps: Vec<String> = Vec::new();

        // Find primary folder that best matches addon identity (e.g. name or slug)
        let primary_folder = installed_folders
            .iter()
            .find(|f| {
                let fl = f.to_ascii_lowercase();
                let name_lower = target_addon_name.to_ascii_lowercase();
                fl == name_lower
                    || a.wago_slug
                        .as_ref()
                        .map(|s| fl == s.to_ascii_lowercase())
                        .unwrap_or(false)
            })
            .or_else(|| installed_folders.first());

        if let Some(pf) = primary_folder {
            if let Some(primary_toc) = find_primary_toc(&addons_path.join(pf), flavour, client_interface) {
                let toc_meta = parse_toc_file(&primary_toc);
                if chosen_version.is_none() {
                    chosen_version = toc_meta.version;
                }
                if let Some(ref t) = toc_meta.title {
                    let cleaned = strip_wow_formatting(t);
                    if !cleaned.is_empty() && (target_addon_name == "CurseForge Addon" || target_addon_name.starts_with("CurseForge project ")) {
                        target_addon_name = cleaned;
                        let _ = conn.execute("UPDATE addons SET name = ?1 WHERE id = ?2", params![target_addon_name, target_addon_id]);
                    }
                }
            }
        }

        // Aggregate required_deps from all installed folders in this addon
        let target_norm = crate::engine::deps::normalize_dep_slug(&target_addon_name);
        for folder in &installed_folders {
            if let Some(toc_path) = find_primary_toc(&addons_path.join(folder), flavour, client_interface) {
                let toc_meta = parse_toc_file(&toc_path);
                for dep in toc_meta.required_deps {
                    let dep_norm = crate::engine::deps::normalize_dep_slug(&dep);

                    // Comprehensive internal submodule detection
                    let is_internal = installed_folders.iter().any(|f| {
                        f.eq_ignore_ascii_case(&dep)
                            || crate::engine::deps::normalize_dep_slug(f) == dep_norm
                            || crate::engine::deps::get_dependency_alias(f).map(|a| a == dep_norm).unwrap_or(false)
                            || crate::engine::deps::get_dependency_alias(&dep).map(|a| a == crate::engine::deps::normalize_dep_slug(f)).unwrap_or(false)
                    })
                    || target_addon_name.eq_ignore_ascii_case(&dep)
                    || target_norm == dep_norm
                    || a.wago_slug.as_ref().map(|s| s.eq_ignore_ascii_case(&dep) || crate::engine::deps::normalize_dep_slug(s) == dep_norm).unwrap_or(false)
                    || a.repo.as_ref().map(|r| {
                        r.eq_ignore_ascii_case(&dep)
                            || r.split('/').last().map(|rn| rn.eq_ignore_ascii_case(&dep) || crate::engine::deps::normalize_dep_slug(rn) == dep_norm).unwrap_or(false)
                    }).unwrap_or(false);

                    if !is_internal && !required_deps.iter().any(|d| d.eq_ignore_ascii_case(&dep) || crate::engine::deps::normalize_dep_slug(d) == dep_norm) {
                        required_deps.push(dep);
                    }
                }
            }
        }

        // Step 8: Update SQLite
        let now = Utc::now().to_rfc3339();
        let req_deps_json = serde_json::to_string(&required_deps).unwrap_or_else(|_| "[]".to_string());

        let _ = conn.execute(
            "UPDATE addons SET version = ?1, file_id = ?2, file_name = ?3, installed_at = ?4, \
             required_deps = ?5, adopted = 0, previous_file_id = ?6, previous_version = ?7 WHERE id = ?8",
            params![
                chosen_version,
                chosen_file_id,
                chosen_file_name,
                now,
                req_deps_json,
                prev_backup_file_id,
                prev_backup_version,
                target_addon_id
            ],
        );

        let _ = conn.execute("DELETE FROM addon_folders WHERE addon_id = ?1", params![target_addon_id]);
        for f in &installed_folders {
            let _ = conn.execute(
                "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES (?1, ?2, ?3)",
                params![flavour, f, target_addon_id],
            );
        }

        let now_str = Utc::now().to_rfc3339();
        let _ = conn.execute(
            "INSERT OR REPLACE INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
             VALUES (?1, ?2, NULL, NULL, 'up_to_date', NULL)",
            params![target_addon_id, now_str],
        );

        updated_count += 1;
        if is_wow_running() {
            any_installed_while_game_running = true;
        }

        let outcome_status = if a.file_id.is_none() { "Installed" } else { "Updated" };
        results.push(AddonSyncResult {
            addon_id: target_addon_id.clone(),
            name: target_addon_name.clone(),
            status: outcome_status.to_string(),
            previous_version: a.version.clone(),
            new_version: chosen_version.clone(),
            error: None,
        });

        append_sync_log(
            Some(flavour),
            "INFO",
            &format!("{}: {} to {:?}", target_addon_name, outcome_status, chosen_version),
        );
    }

    // Cleanup orphaned backups older than 30 days (Round 49)
    let _ = cleanup_orphaned_backups(conn, 30);

    // Dual-write: update v1 folder if exists (D-03)
    let v1_dir = get_v1_sync_folder(wow_root);
    if v1_dir.exists() {
        let _ = export_to_v1(conn, &v1_dir);
    }

    let finished_at = Utc::now().to_rfc3339();

    // Refresh freshness table so UI knows if updates remain or if all is clean
    let remaining_updates: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM check_results cr \
             JOIN addons a ON a.id = cr.addon_id \
             WHERE a.flavour = ?1 \
               AND (cr.status = 'Would-update' OR cr.status = 'would_update') \
               AND ( \
                 (cr.update_file_id IS NOT NULL AND cr.update_file_id != IFNULL(a.file_id, '')) \
                 OR (cr.update_version IS NOT NULL AND cr.update_version != IFNULL(a.version, '')) \
               )",
            params![flavour],
            |r| r.get(0),
        )
        .unwrap_or(0);

    let overall_state = if remaining_updates > 0 {
        "updates_ready"
    } else if failed_count > 0 && updated_count == 0 && up_to_date_count == 0 {
        "failed"
    } else {
        "clean"
    };

    let _ = conn.execute(
        "INSERT OR REPLACE INTO freshness (flavour, state, checked_at, last_success_at, last_error) \
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            flavour,
            overall_state,
            finished_at,
            if failed_count == 0 { Some(finished_at.clone()) } else { None },
            if failed_count > 0 { Some(format!("{} sync(s) failed", failed_count)) } else { None }
        ],
    );

    append_sync_log(
        Some(flavour),
        "INFO",
        &format!(
            "Sync complete: {} updated, {} up-to-date, {} failed (reload needed: {})",
            updated_count, up_to_date_count, failed_count, any_installed_while_game_running
        ),
    );

    Ok(SyncRunReport {
        flavour: flavour.to_string(),
        started_at,
        finished_at,
        updated: updated_count,
        up_to_date: up_to_date_count,
        failed: failed_count,
        reload_needed: any_installed_while_game_running,
        results,
    })
}
