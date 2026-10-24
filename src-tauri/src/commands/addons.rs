use std::sync::Arc;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::State;
use crate::db::open_connection;
use crate::db::repo::{get_installed_flavours_db, FlavourDto};
use crate::engine::adopt::adopt_candidate_group;
use crate::engine::compat::{list_not_built_for_patch as engine_compat, PatchCompatStatus};
use crate::engine::flavours::detect_installed_flavours_in_root;
use crate::engine::ignore::set_ignore_updates;
use crate::engine::pin::{pin_addon, unpin_addon};
use crate::engine::scan::{scan_untracked_addons, ScannedCandidateGroup};
use crate::jobs::runner::{JobRecord, JobRunner};
use crate::paths::{detect_wow_root, get_db_path, is_dev};
use crate::system::game::is_wow_running;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppInfoDto {
    pub name: String,
    pub version: String,
    pub is_dev: bool,
    pub identifier: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddonDto {
    pub id: String,
    pub flavour: String,
    pub name: Option<String>,
    pub author: Option<String>,
    pub source: Option<String>,
    pub version: Option<String>,
    pub project_id: Option<i64>,
    pub file_id: Option<String>,
    pub file_name: Option<String>,
    pub folders: Vec<String>,
    pub installed_at: Option<String>,
    pub adopted: bool,
    pub ignore_updates: bool,
    pub pinned_file_id: Option<String>,
    pub release_type: Option<i64>,
    pub update_version: Option<String>,
    pub update_file_id: Option<String>,
    pub check_status: Option<String>,
    pub error: Option<String>,
    pub is_old_patch: bool,
    pub missing_deps: Vec<String>,
    pub ignored_deps: Vec<String>,
    pub wago_slug: Option<String>,
    pub repo: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VersionItemDto {
    pub file_id: String,
    pub version: String,
    pub kind: String,
    pub date: Option<String>,
    pub is_current: bool,
    pub is_pinned: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FreshnessDto {
    pub state: String,
    pub checked_at: Option<String>,
    pub updates_count: usize,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppStateDto {
    pub addons: Vec<AddonDto>,
    pub flavours: Vec<FlavourDto>,
    pub active_flavour: String,
    pub freshness: FreshnessDto,
    pub running_job: Option<JobRecord>,
    pub untracked_count: usize,
    pub is_game_active: bool,
    pub app_info: AppInfoDto,
}

pub fn fetch_addons_with_details(conn: &Connection, flavour: &str) -> Result<Vec<AddonDto>, String> {
    let (mut client_interface, mut client_build): (Option<i32>, Option<String>) = conn
        .query_row(
            "SELECT client_interface, client_build FROM flavours WHERE id = ?1",
            rusqlite::params![flavour],
            |r| {
                let ci: Option<i32> = r
                    .get::<_, Option<String>>(0)
                    .ok()
                    .flatten()
                    .and_then(|s| s.parse::<i32>().ok())
                    .or_else(|| r.get::<_, Option<i32>>(0).ok().flatten());
                let cb: Option<String> = r.get::<_, Option<String>>(1).ok().flatten();
                Ok((ci, cb))
            },
        )
        .unwrap_or((None, None));

    if client_interface.is_none() {
        if let Ok(wow_root) = detect_wow_root(None) {
            let installed = detect_installed_flavours_in_root(&wow_root);
            if let Some(target) = installed.iter().find(|f| f.id == flavour) {
                client_interface = target.client_interface;
                if client_build.is_none() {
                    client_build = target.client_build.clone();
                }
            }
        }
    }

    let mut stmt = conn
        .prepare(
            "SELECT a.id, a.flavour, a.name, a.author, a.source, a.version, a.project_id, \
             a.file_id, a.file_name, a.installed_at, a.adopted, a.ignore_updates, \
             a.pinned_file_id, a.release_type, a.wago_slug, a.repo, \
             c.update_version, c.update_file_id, c.status, c.error, a.latest_game_versions, a.ignored_deps \
             FROM addons a \
             LEFT JOIN check_results c ON a.id = c.addon_id \
             WHERE a.flavour = ?1 ORDER BY a.name COLLATE NOCASE ASC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map(rusqlite::params![flavour], |row| {
            let addon_id: String = row.get(0)?;
            let flavour_id: String = row.get(1)?;
            let name: Option<String> = row.get(2)?;
            let author: Option<String> = row.get(3)?;
            let source: Option<String> = row.get(4)?;
            let version: Option<String> = row.get(5)?;
            let project_id: Option<i64> = row.get(6)?;
            let file_id: Option<String> = row.get(7)?;
            let file_name: Option<String> = row.get(8)?;
            let installed_at: Option<String> = row.get(9)?;
            let adopted: bool = row.get::<_, i32>(10)? != 0;
            let ignore_updates: bool = row.get::<_, i32>(11)? != 0;
            let pinned_file_id: Option<String> = row.get(12)?;
            let release_type: Option<i64> = row.get(13)?;
            let wago_slug: Option<String> = row.get(14)?;
            let repo: Option<String> = row.get(15)?;
            let update_version: Option<String> = row.get(16)?;
            let update_file_id: Option<String> = row.get(17)?;
            let check_status: Option<String> = row.get(18)?;
            let error: Option<String> = row.get(19)?;
            let latest_gv_json: Option<String> = row.get(20)?;
            let ignored_deps_json: Option<String> = row.get(21)?;

            Ok((
                addon_id, flavour_id, name, author, source, version,
                project_id, file_id, file_name, installed_at, adopted,
                ignore_updates, pinned_file_id, release_type, wago_slug,
                repo, update_version, update_file_id, check_status, error, latest_gv_json, ignored_deps_json,
            ))
        })
        .map_err(|e| e.to_string())?;

    let mut result = Vec::new();
    for r in rows {
        let (
            addon_id, flavour_id, name, author, source, version,
            project_id, file_id, file_name, installed_at, adopted,
            ignore_updates, pinned_file_id, release_type, wago_slug,
            repo, update_version, update_file_id, check_status, error, latest_gv_json, ignored_deps_json,
        ) = r.map_err(|e| e.to_string())?;

        let mut folder_stmt = conn
            .prepare(
                "SELECT folder FROM addon_folders WHERE flavour = ?1 AND addon_id = ?2 ORDER BY folder COLLATE NOCASE ASC",
            )
            .map_err(|e| e.to_string())?;
        let frows = folder_stmt
            .query_map(rusqlite::params![flavour_id, addon_id], |fr| fr.get::<_, String>(0))
            .map_err(|e| e.to_string())?;
        let folders: Vec<String> = frows.flatten().collect();

        let is_old_patch = if client_interface.is_some() {
            let latest_gv: Vec<String> = latest_gv_json
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_default();
            !crate::engine::compat::is_addon_built_for_patch(
                client_interface,
                None,
                &latest_gv,
                client_build.as_deref(),
            )
        } else {
            false
        };

        let missing_deps = crate::engine::deps::check_missing_dependencies(conn, &flavour_id, &addon_id)
            .unwrap_or_default();
        let ignored_deps: Vec<String> = ignored_deps_json
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();

        let is_error = error.is_some() || check_status.as_deref() == Some("failed");
        let is_up_to_date = !is_error && match (&file_id, &update_file_id, &version, &update_version) {
            (Some(fid), Some(ufid), _, _) if fid == ufid => true,
            (_, _, Some(ver), Some(uver)) if ver == uver => true,
            (Some(fid), Some(ufid), _, _) => {
                if let (Ok(installed_fid), Ok(target_fid)) = (fid.parse::<i64>(), ufid.parse::<i64>()) {
                    installed_fid >= target_fid
                } else {
                    false
                }
            }
            _ => false,
        };

        let (final_update_version, final_update_file_id, final_check_status) = if is_up_to_date {
            (None, None, Some("up_to_date".to_string()))
        } else {
            (update_version, update_file_id, check_status)
        };

        result.push(AddonDto {
            id: addon_id,
            flavour: flavour_id,
            name,
            author,
            source,
            version,
            project_id,
            file_id,
            file_name,
            folders,
            installed_at,
            adopted,
            ignore_updates,
            pinned_file_id,
            release_type,
            update_version: final_update_version,
            update_file_id: final_update_file_id,
            check_status: final_check_status,
            error,
            is_old_patch,
            missing_deps,
            ignored_deps,
            wago_slug,
            repo,
        });
    }

    Ok(result)
}

#[tauri::command]
pub fn get_addons(flavour: Option<String>) -> Result<Vec<AddonDto>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let active_flavour = flavour.unwrap_or_else(|| "retail".into());
    fetch_addons_with_details(&conn, &active_flavour)
}

#[tauri::command]
pub fn get_flavours() -> Result<Vec<FlavourDto>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    get_installed_flavours_db(&conn).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_app_info() -> Result<AppInfoDto, String> {
    let dev = is_dev();
    Ok(AppInfoDto {
        name: if dev {
            "Furphy Dev".into()
        } else {
            "Furphy Addon Manager".into()
        },
        version: env!("CARGO_PKG_VERSION").into(),
        is_dev: dev,
        identifier: if dev {
            "krenzcreative.furphy.addonmanager.dev".into()
        } else {
            "krenzcreative.furphy.addonmanager".into()
        },
    })
}

#[tauri::command]
pub fn get_state(flavour: Option<String>) -> Result<AppStateDto, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let active_flavour = flavour.unwrap_or_else(|| "retail".into());

    let addons = fetch_addons_with_details(&conn, &active_flavour)?;
    let flavours = get_installed_flavours_db(&conn).unwrap_or_default();

    // Freshness calculation
    let mut updates_count = 0;
    for a in &addons {
        if a.update_version.is_some() && !a.ignore_updates && a.pinned_file_id.is_none() {
            updates_count += 1;
        }
    }

    let (freshness_state, checked_at, last_error): (String, Option<String>, Option<String>) = conn
        .query_row(
            "SELECT state, checked_at, last_error FROM freshness WHERE flavour = ?1",
            rusqlite::params![active_flavour],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap_or_else(|_| {
            if updates_count > 0 {
                ("updates_ready".into(), None, None)
            } else if !addons.is_empty() {
                ("clean".into(), None, None)
            } else {
                ("not_checked".into(), None, None)
            }
        });

    let effective_freshness_state = if updates_count > 0 {
        "updates_ready".to_string()
    } else if freshness_state == "updates_ready" || freshness_state == "up_to_date" {
        "clean".to_string()
    } else {
        freshness_state
    };

    let freshness = FreshnessDto {
        state: effective_freshness_state,
        checked_at,
        updates_count,
        last_error,
    };

    // Running job
    let running_job = conn
        .query_row(
            "SELECT id, kind, flavour, params, state, started_at, finished_at, error, results, reload_needed, log_path \
             FROM jobs WHERE state = 'running' ORDER BY started_at DESC LIMIT 1",
            [],
            |r| {
                Ok(JobRecord {
                    id: r.get(0)?,
                    kind: r.get(1)?,
                    flavour: r.get(2)?,
                    params: r.get(3)?,
                    state: r.get(4)?,
                    started_at: r.get(5)?,
                    finished_at: r.get(6)?,
                    error: r.get(7)?,
                    results: r.get(8)?,
                    reload_needed: r.get::<_, i32>(9)? != 0,
                    log_path: r.get(10)?,
                })
            },
        )
        .ok();

    // Untracked count: count ONLY identifiable groups per §2.E
    let untracked_count = if let Ok(wow_root) = detect_wow_root(None) {
        let installed = detect_installed_flavours_in_root(&wow_root);
        if let Some(target_flv) = installed.iter().find(|f| f.id == active_flavour) {
            scan_untracked_addons(&conn, &target_flv.addons_path, &active_flavour, target_flv.client_interface)
                .map(|cands| {
                    cands
                        .iter()
                        .filter(|c| c.source.is_some() || c.project_id.is_some() || c.wago_id.is_some())
                        .count()
                })
                .unwrap_or(0)
        } else {
            0
        }
    } else {
        0
    };

    let is_game_active = is_wow_running();
    let app_info = get_app_info()?;

    Ok(AppStateDto {
        addons,
        flavours,
        active_flavour,
        freshness,
        running_job,
        untracked_count,
        is_game_active,
        app_info,
    })
}

#[tauri::command]
pub fn set_ignore(id: String, ignore: bool) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    set_ignore_updates(&conn, &id, ignore).map_err(|e| e.to_string())?;
    crate::db::export_v1::trigger_dual_write_if_v1_exists(&conn);
    Ok(())
}

#[tauri::command]
pub fn unpin(id: String) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    unpin_addon(&conn, &id).map_err(|e| e.to_string())?;
    crate::db::export_v1::trigger_dual_write_if_v1_exists(&conn);
    Ok(())
}

#[tauri::command]
pub fn pin_version(id: String, file_id: String) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    pin_addon(&conn, &id, &file_id).map_err(|e| e.to_string())?;
    crate::db::export_v1::trigger_dual_write_if_v1_exists(&conn);
    Ok(())
}

#[tauri::command]
pub fn list_files(id: String) -> Result<Vec<VersionItemDto>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;

    let (current_file_id, current_version, pinned_file_id): (Option<String>, Option<String>, Option<String>) = conn
        .query_row(
            "SELECT file_id, version, pinned_file_id FROM addons WHERE id = ?1",
            rusqlite::params![id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .map_err(|e| e.to_string())?;

    let mut versions = Vec::new();

    // 1. Current version
    if let (Some(fid), Some(ver)) = (&current_file_id, &current_version) {
        versions.push(VersionItemDto {
            file_id: fid.clone(),
            version: ver.clone(),
            kind: "installed".into(),
            date: None,
            is_current: true,
            is_pinned: pinned_file_id.as_deref() == Some(fid.as_str()),
        });
    }

    // 2. Backup versions
    let mut stmt = conn
        .prepare(
            "SELECT file_id, version, kind, created_at FROM backups WHERE addon_id = ?1 ORDER BY created_at DESC",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(rusqlite::params![id], |r| {
            Ok((
                r.get::<_, Option<String>>(0)?,
                r.get::<_, Option<String>>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Option<String>>(3)?,
            ))
        })
        .map_err(|e| e.to_string())?;

    for r in rows.flatten() {
        if let (Some(fid), Some(ver)) = (r.0, r.1) {
            if !versions.iter().any(|v: &VersionItemDto| v.file_id == fid) {
                versions.push(VersionItemDto {
                    file_id: fid.clone(),
                    version: ver,
                    kind: r.2,
                    date: r.3,
                    is_current: current_file_id.as_deref() == Some(fid.as_str()),
                    is_pinned: pinned_file_id.as_deref() == Some(fid.as_str()),
                });
            }
        }
    }

    Ok(versions)
}

#[tauri::command]
pub fn scan_untracked(flavour: Option<String>) -> Result<Vec<ScannedCandidateGroup>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let flv_id = flavour.unwrap_or_else(|| "retail".into());
    let wow_root = detect_wow_root(None).map_err(|e| e.to_string())?;
    let installed = detect_installed_flavours_in_root(&wow_root);
    let target_flv = match installed.iter().find(|f| f.id == flv_id) {
        Some(f) => f,
        None => return Ok(Vec::new()),
    };
    scan_untracked_addons(
        &conn,
        &target_flv.addons_path,
        &flv_id,
        target_flv.client_interface,
    )
    .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn delete_untracked_addon(flavour: String, folders: Vec<String>) -> Result<(), String> {
    if folders.is_empty() {
        return Ok(());
    }

    if is_wow_running() {
        return Err("World of Warcraft is running. Please exit the game before deleting addons to prevent file locking issues.".into());
    }

    // Sanitize all folder names (including Windows trailing dot / 8.3 bypass prevention)
    let mut clean_folders = Vec::new();
    for folder in &folders {
        let clean = folder.trim().trim_end_matches('.');
        if clean.is_empty()
            || clean == "."
            || clean == ".."
            || clean.contains('/')
            || clean.contains('\\')
            || clean.contains("..")
            || clean.contains(':')
        {
            return Err("Invalid folder name: path separators and directory traversal are rejected".into());
        }
        clean_folders.push(clean.to_string());
    }

    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;

    for clean in &clean_folders {
        let mut stmt = conn
            .prepare("SELECT 1 FROM addon_folders WHERE flavour = ?1 AND LOWER(folder) = LOWER(?2)")
            .map_err(|e| e.to_string())?;
        let mut rows = stmt
            .query(rusqlite::params![flavour, clean])
            .map_err(|e| e.to_string())?;
        if rows.next().map_err(|e| e.to_string())?.is_some() {
            return Err(format!(
                "Folder '{}' is tracked by an existing addon and cannot be deleted as untracked",
                clean
            ));
        }
    }

    let wow_root = detect_wow_root(None).map_err(|e| e.to_string())?;
    let installed = detect_installed_flavours_in_root(&wow_root);
    let flv = installed
        .iter()
        .find(|f| f.id == flavour)
        .ok_or_else(|| format!("Flavour '{}' not installed", flavour))?;

    for clean in &clean_folders {
        let target = flv.addons_path.join(clean);
        if target.is_dir() {
            std::fs::remove_dir_all(&target).map_err(|e| e.to_string())?;
            for _ in 0..50 {
                if !target.exists() {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        } else if target.is_file() {
            std::fs::remove_file(&target).map_err(|e| e.to_string())?;
            for _ in 0..50 {
                if !target.exists() {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
        let _ = conn.execute(
            "DELETE FROM ignored_untracked_folders WHERE flavour = ?1 AND LOWER(folder) = LOWER(?2)",
            rusqlite::params![flavour, clean],
        );
    }
    Ok(())
}

#[tauri::command]
pub fn delete_untracked_folder(flavour: String, folder: String) -> Result<(), String> {
    delete_untracked_addon(flavour, vec![folder])
}

#[tauri::command]
pub fn ignore_untracked_addon(flavour: String, folders: Vec<String>) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;

    for folder in folders {
        let trimmed = folder.trim();
        if trimmed.is_empty() {
            continue;
        }
        conn.execute(
            "INSERT OR IGNORE INTO ignored_untracked_folders (flavour, folder) VALUES (?1, ?2)",
            rusqlite::params![flavour, trimmed],
        )
        .map_err(|e| e.to_string())?;
    }

    Ok(())
}

#[tauri::command]
pub fn unignore_untracked_folder(flavour: String, folder: String) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;

    conn.execute(
        "DELETE FROM ignored_untracked_folders WHERE flavour = ?1 AND LOWER(folder) = LOWER(?2)",
        rusqlite::params![flavour, folder.trim()],
    )
    .map_err(|e| e.to_string())?;

    Ok(())
}

#[tauri::command]
pub fn list_ignored_untracked(flavour: String) -> Result<Vec<String>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;

    let mut stmt = conn
        .prepare("SELECT folder FROM ignored_untracked_folders WHERE flavour = ?1 ORDER BY folder COLLATE NOCASE ASC")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(rusqlite::params![flavour], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?;

    let result = rows.flatten().collect();
    Ok(result)
}

#[tauri::command]
pub fn ignore_dependency(addon_id: String, dep_name: String) -> Result<(), String> {
    let dep_trimmed = dep_name.trim();
    if dep_trimmed.is_empty() {
        return Err("Dependency name cannot be empty".into());
    }

    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;

    let existing_json: Option<String> = conn
        .query_row(
            "SELECT ignored_deps FROM addons WHERE id = ?1",
            rusqlite::params![addon_id],
            |r| r.get(0),
        )
        .map_err(|e| format!("Addon '{}' not found: {}", addon_id, e))?;

    let mut list: Vec<String> = existing_json
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    if !list.iter().any(|d| d.eq_ignore_ascii_case(dep_trimmed)) {
        list.push(dep_trimmed.to_string());
    }

    let new_json = serde_json::to_string(&list).map_err(|e| e.to_string())?;
    conn.execute(
        "UPDATE addons SET ignored_deps = ?1 WHERE id = ?2",
        rusqlite::params![new_json, addon_id],
    )
    .map_err(|e| e.to_string())?;

    crate::db::export_v1::trigger_dual_write_if_v1_exists(&conn);
    Ok(())
}

#[tauri::command]
pub fn unignore_dependency(addon_id: String, dep_name: String) -> Result<(), String> {
    let dep_trimmed = dep_name.trim();
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;

    let existing_json: Option<String> = conn
        .query_row(
            "SELECT ignored_deps FROM addons WHERE id = ?1",
            rusqlite::params![addon_id],
            |r| r.get(0),
        )
        .map_err(|e| format!("Addon '{}' not found: {}", addon_id, e))?;

    let list: Vec<String> = existing_json
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    let updated_list: Vec<String> = list
        .into_iter()
        .filter(|d| !d.eq_ignore_ascii_case(dep_trimmed))
        .collect();

    let new_json = serde_json::to_string(&updated_list).map_err(|e| e.to_string())?;
    conn.execute(
        "UPDATE addons SET ignored_deps = ?1 WHERE id = ?2",
        rusqlite::params![new_json, addon_id],
    )
    .map_err(|e| e.to_string())?;

    crate::db::export_v1::trigger_dual_write_if_v1_exists(&conn);
    Ok(())
}

#[tauri::command]
pub fn adopt_untracked(
    flavour: String,
    candidate: ScannedCandidateGroup,
) -> Result<String, String> {
    let db_path = get_db_path();
    let mut conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    adopt_candidate_group(&mut conn, &flavour, &candidate).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn adopt_all_untracked(flavour: String) -> Result<usize, String> {
    let db_path = get_db_path();
    let mut conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let wow_root = detect_wow_root(None).map_err(|e| e.to_string())?;
    let installed = detect_installed_flavours_in_root(&wow_root);
    let target_flv = installed
        .iter()
        .find(|f| f.id == flavour)
        .ok_or_else(|| format!("Flavour '{}' not installed", flavour))?;

    let candidates = scan_untracked_addons(
        &conn,
        &target_flv.addons_path,
        &flavour,
        target_flv.client_interface,
    )
    .map_err(|e| e.to_string())?;

    let mut count = 0;
    for c in &candidates {
        if c.source.is_some() || c.project_id.is_some() || c.wago_id.is_some() {
            if adopt_candidate_group(&mut conn, &flavour, c).is_ok() {
                count += 1;
            }
        }
    }
    Ok(count)
}

#[tauri::command]
pub fn list_not_built_for_patch(
    flavour: Option<String>,
) -> Result<Vec<PatchCompatStatus>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let flv = flavour.unwrap_or_else(|| "retail".into());

    let wow_root = detect_wow_root(None).ok();
    let mut client_interface = None;
    let mut client_build = None;
    if let Some(ref root) = wow_root {
        let installed = detect_installed_flavours_in_root(root);
        if let Some(target) = installed.iter().find(|f| f.id == flv) {
            client_interface = target.client_interface;
            client_build = target.client_build.clone();
        }
    }

    engine_compat(
        &conn,
        &flv,
        client_interface,
        client_build.as_deref(),
    )
    .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn install_dependencies(
    runner: State<'_, Arc<JobRunner>>,
    flavour: String,
    addon_id: Option<String>,
) -> Result<Value, String> {
    let runner = runner.inner().clone();
    let (tx, rx) = tokio::sync::oneshot::channel();
    let params_val = serde_json::json!({
        "addon_id": addon_id,
    });

    std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(r) => r,
            Err(e) => {
                let _ = tx.send(Err(format!("Failed to build async runtime for dependency installation: {}", e)));
                return;
            }
        };

        rt.block_on(async move {
            let db_path = get_db_path();
            let mut conn = match open_connection(&db_path) {
                Ok(c) => c,
                Err(e) => {
                    let _ = tx.send(Err(e.to_string()));
                    return;
                }
            };
            let res = runner
                .run_job(&mut conn, "install-deps", Some(&flavour), params_val)
                .await
                .map(|rec| serde_json::to_value(&rec).unwrap_or(Value::Null))
                .map_err(|e| e.to_string());
            let _ = tx.send(res);
        });
    });

    rx.await.map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use crate::db::schema::INITIAL_SCHEMA;

    #[test]
    fn test_delete_untracked_addon_traversal_rejection() {
        let bad = [
            "../SavedVariables",
            "../../Windows",
            "folder/subfolder",
            "folder\\subfolder",
            "C:AddOns",
            "..",
            ".",
            "   ",
        ];

        for folder in bad {
            let res = delete_untracked_addon("retail".to_string(), vec![folder.to_string()]);
            assert!(res.is_err(), "Expected folder '{}' to be rejected", folder);
            let err = res.unwrap_err();
            assert!(
                err.contains("path separators and directory traversal are rejected")
                    || err.contains("Invalid folder name"),
                "Unexpected error message: {}",
                err
            );
        }
    }

    #[test]
    fn test_ignored_dependency_lifecycle() {
        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let temp = tempdir().unwrap();
        let orig_local = std::env::var("LOCALAPPDATA").ok();
        std::env::set_var("LOCALAPPDATA", temp.path().to_str().unwrap());

        let db_path = get_db_path();
        let conn = open_connection(&db_path).unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name) VALUES ('addon-1', 'retail', 'TestAddon')",
            [],
        ).unwrap();

        // 1. Ignore "exwindcore"
        ignore_dependency("addon-1".to_string(), "exwindcore".to_string()).unwrap();

        let val: String = conn.query_row(
            "SELECT ignored_deps FROM addons WHERE id = 'addon-1'",
            [],
            |r| r.get(0),
        ).unwrap();
        let list: Vec<String> = serde_json::from_str(&val).unwrap();
        assert_eq!(list, vec!["exwindcore"]);

        // 2. Ignore "Ace3"
        ignore_dependency("addon-1".to_string(), "Ace3".to_string()).unwrap();
        let val2: String = conn.query_row(
            "SELECT ignored_deps FROM addons WHERE id = 'addon-1'",
            [],
            |r| r.get(0),
        ).unwrap();
        let list2: Vec<String> = serde_json::from_str(&val2).unwrap();
        assert_eq!(list2, vec!["exwindcore", "Ace3"]);

        // 3. Duplicate ignore is no-op
        ignore_dependency("addon-1".to_string(), "exwindcore".to_string()).unwrap();
        let val3: String = conn.query_row(
            "SELECT ignored_deps FROM addons WHERE id = 'addon-1'",
            [],
            |r| r.get(0),
        ).unwrap();
        let list3: Vec<String> = serde_json::from_str(&val3).unwrap();
        assert_eq!(list3, vec!["exwindcore", "Ace3"]);

        // 4. Unignore "exwindcore" (case insensitive)
        unignore_dependency("addon-1".to_string(), "ExWindCore".to_string()).unwrap();
        let val4: String = conn.query_row(
            "SELECT ignored_deps FROM addons WHERE id = 'addon-1'",
            [],
            |r| r.get(0),
        ).unwrap();
        let list4: Vec<String> = serde_json::from_str(&val4).unwrap();
        assert_eq!(list4, vec!["Ace3"]);

        // Restore env
        if let Some(l) = orig_local {
            std::env::set_var("LOCALAPPDATA", l);
        } else {
            std::env::remove_var("LOCALAPPDATA");
        }
    }

    #[test]
    fn test_ignored_untracked_folders_lifecycle() {
        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let temp = tempdir().unwrap();
        let orig_local = std::env::var("LOCALAPPDATA").ok();
        std::env::set_var("LOCALAPPDATA", temp.path().to_str().unwrap());

        let db_path = get_db_path();
        let conn = open_connection(&db_path).unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        // 1. Initially empty
        let initial = list_ignored_untracked("retail".to_string()).unwrap();
        assert!(initial.is_empty());

        // 2. Ignore multiple folders
        ignore_untracked_addon(
            "retail".to_string(),
            vec!["FolderA".to_string(), "FolderB".to_string()],
        ).unwrap();

        let list = list_ignored_untracked("retail".to_string()).unwrap();
        assert_eq!(list, vec!["FolderA", "FolderB"]);

        // 3. Unignore FolderA case-insensitively
        unignore_untracked_folder("retail".to_string(), "foldera".to_string()).unwrap();

        let list_after = list_ignored_untracked("retail".to_string()).unwrap();
        assert_eq!(list_after, vec!["FolderB"]);

        // Restore env
        if let Some(l) = orig_local {
            std::env::set_var("LOCALAPPDATA", l);
        } else {
            std::env::remove_var("LOCALAPPDATA");
        }
    }

    #[test]
    fn test_delete_untracked_addon_success_and_tracked_guard() {
        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let orig_fake_wow = std::env::var("FURPHY_DEV_FAKE_WOW").ok();
        std::env::remove_var("FURPHY_DEV_FAKE_WOW");
        let temp_local = tempdir().unwrap();
        let orig_local = std::env::var("LOCALAPPDATA").ok();
        std::env::set_var("LOCALAPPDATA", temp_local.path().to_str().unwrap());

        let temp_wow_dir = tempdir().unwrap();
        let temp_wow = temp_wow_dir.path().join("furphy test wow (delete untracked)");
        let retail_addons = temp_wow.join("_retail_").join("Interface").join("AddOns");
        std::fs::create_dir_all(&retail_addons).unwrap();
        std::env::set_var("FURPHY_DEV_WOWROOT", temp_wow.to_str().unwrap());

        let db_path = get_db_path();
        let conn = open_connection(&db_path).unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        // Create 2 untracked folders on disk
        let dir1 = retail_addons.join("UntrackedFolder1");
        let dir2 = retail_addons.join("UntrackedFolder2");
        std::fs::create_dir_all(&dir1).unwrap();
        std::fs::create_dir_all(&dir2).unwrap();
        assert!(dir1.exists());
        assert!(dir2.exists());

        // Delete untracked addon with both folders
        delete_untracked_addon(
            "retail".to_string(),
            vec!["UntrackedFolder1".to_string(), "UntrackedFolder2".to_string()],
        ).unwrap();

        for _ in 0..50 {
            if !dir1.exists() && !dir2.exists() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        assert!(!dir1.exists());
        assert!(!dir2.exists());

        // Now test tracked guard
        let tracked_dir = retail_addons.join("TrackedAddonFolder");
        std::fs::create_dir_all(&tracked_dir).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name) VALUES ('addon-tracked', 'retail', 'Tracked')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'TrackedAddonFolder', 'addon-tracked')",
            [],
        ).unwrap();

        let res = delete_untracked_addon("retail".to_string(), vec!["TrackedAddonFolder".to_string()]);
        assert!(res.is_err());
        assert!(res.unwrap_err().contains("is tracked by an existing addon"));
        assert!(tracked_dir.exists(), "Tracked folder must not be deleted");

        // Clean up
        let _ = std::fs::remove_dir_all(&temp_wow);
        std::env::remove_var("FURPHY_DEV_WOWROOT");
        if let Some(fw) = orig_fake_wow {
            std::env::set_var("FURPHY_DEV_FAKE_WOW", fw);
        } else {
            std::env::remove_var("FURPHY_DEV_FAKE_WOW");
        }
        if let Some(l) = orig_local {
            std::env::set_var("LOCALAPPDATA", l);
        } else {
            std::env::remove_var("LOCALAPPDATA");
        }
    }

    #[test]
    fn test_fetch_addons_with_details_includes_error() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name, version) VALUES ('addon-err', 'retail', 'FailedAddon', '1.0.0')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO check_results (addon_id, checked_at, status, error) VALUES ('addon-err', '2026-10-23T00:00:00Z', 'failed', 'Network timeout connecting to provider')",
            [],
        ).unwrap();

        let addons = fetch_addons_with_details(&conn, "retail").unwrap();
        assert_eq!(addons.len(), 1);
        let dto = &addons[0];
        assert_eq!(dto.id, "addon-err");
        assert_eq!(dto.name.as_deref(), Some("FailedAddon"));
        assert_eq!(dto.check_status.as_deref(), Some("failed"));
        assert_eq!(dto.error.as_deref(), Some("Network timeout connecting to provider"));
    }

    #[test]
    fn test_fetch_addons_with_details_clears_stale_update_when_already_installed_or_newer() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        // 1. Addon with identical file_id and version in check_results
        conn.execute(
            "INSERT INTO addons (id, flavour, name, version, file_id) VALUES ('addon-same', 'retail', 'SameAddon', 'v427.8', '9299959')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO check_results (addon_id, checked_at, update_file_id, update_version, status) \
             VALUES ('addon-same', '2026-10-23T00:00:00Z', '9299959', 'v427.8', 'Would-update')",
            [],
        ).unwrap();

        // 2. Addon installed with newer numeric file_id than check_results
        conn.execute(
            "INSERT INTO addons (id, flavour, name, version, file_id) VALUES ('addon-newer', 'retail', 'NewerAddon', '6.3.20', '9301495')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO check_results (addon_id, checked_at, update_file_id, update_version, status) \
             VALUES ('addon-newer', '2026-10-23T00:00:00Z', '9300069', '6.3.18', 'Would-update')",
            [],
        ).unwrap();

        // 3. Addon with genuine pending update
        conn.execute(
            "INSERT INTO addons (id, flavour, name, version, file_id) VALUES ('addon-update', 'retail', 'UpdateAddon', '1.0.0', '9200000')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO check_results (addon_id, checked_at, update_file_id, update_version, status) \
             VALUES ('addon-update', '2026-10-23T00:00:00Z', '9300000', '1.1.0', 'Would-update')",
            [],
        ).unwrap();

        let dtos = fetch_addons_with_details(&conn, "retail").unwrap();
        assert_eq!(dtos.len(), 3);

        let same = dtos.iter().find(|d| d.id == "addon-same").unwrap();
        assert_eq!(same.update_version, None);
        assert_eq!(same.update_file_id, None);
        assert_eq!(same.check_status.as_deref(), Some("up_to_date"));

        let newer = dtos.iter().find(|d| d.id == "addon-newer").unwrap();
        assert_eq!(newer.update_version, None);
        assert_eq!(newer.update_file_id, None);
        assert_eq!(newer.check_status.as_deref(), Some("up_to_date"));

        let update = dtos.iter().find(|d| d.id == "addon-update").unwrap();
        assert_eq!(update.update_version.as_deref(), Some("1.1.0"));
        assert_eq!(update.update_file_id.as_deref(), Some("9300000"));
        assert_eq!(update.check_status.as_deref(), Some("Would-update"));
    }
}
