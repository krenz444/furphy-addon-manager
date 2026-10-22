use std::fs;
use std::path::{Path, PathBuf};
use chrono::Utc;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ImportError {
    #[error("v1 directory does not exist: {0}")]
    V1DirectoryNotFound(String),

    #[error("Folder ownership conflict in flavour '{flavour}': folder '{folder}' is already claimed by addon '{existing_addon}', cannot be claimed by '{new_addon}'")]
    FolderOwnershipConflict {
        flavour: String,
        folder: String,
        existing_addon: String,
        new_addon: String,
    },

    #[error("Failed to read file '{path}': {source}")]
    IoError {
        path: String,
        source: std::io::Error,
    },

    #[error("Failed to parse JSON in '{path}': {source}")]
    JsonError {
        path: String,
        source: serde_json::Error,
    },

    #[error("Database error: {0}")]
    DatabaseError(#[from] rusqlite::Error),
}

#[derive(Debug, Default)]
pub struct ImportSummary {
    pub already_imported: bool,
    pub addons_imported: usize,
    pub flavours_imported: usize,
    pub backups_copied: usize,
}

fn parse_flexible_i64(v: Option<Value>) -> Option<i64> {
    v.and_then(|val| {
        if let Some(i) = val.as_i64() {
            Some(i)
        } else if let Some(s) = val.as_str() {
            s.parse::<i64>().ok()
        } else {
            None
        }
    })
}

fn parse_flexible_string(v: Option<Value>) -> Option<String> {
    v.and_then(|val| {
        if let Some(s) = val.as_str() {
            Some(s.to_string())
        } else if let Some(i) = val.as_i64() {
            Some(i.to_string())
        } else {
            None
        }
    })
}

pub fn import_from_v1(
    conn: &mut Connection,
    v1_dir: &Path,
    v2_data_dir: &Path,
    force: bool,
) -> Result<ImportSummary, ImportError> {
    if !v1_dir.exists() {
        return Err(ImportError::V1DirectoryNotFound(v1_dir.display().to_string()));
    }

    // Check if already imported
    let already_imported: bool = conn
        .query_row(
            "SELECT COUNT(*) > 0 FROM meta WHERE key = 'imported_from_v1_at'",
            [],
            |row| row.get(0),
        )
        .unwrap_or(false);

    if already_imported && !force {
        return Ok(ImportSummary {
            already_imported: true,
            ..Default::default()
        });
    }

    let mut summary = ImportSummary::default();

    let tx = conn.transaction()?;

    // 1. Read VERSION if present
    let version_file = v1_dir.join("VERSION");
    let v1_version = if version_file.exists() {
        fs::read_to_string(&version_file)
            .unwrap_or_else(|_| "1.27.1".into())
            .trim()
            .to_string()
    } else {
        "1.27.1".to_string()
    };

    // 2. Read settings.json
    let settings_path = v1_dir.join("settings.json");
    let mut schema_version = 2;
    if settings_path.exists() {
        let content = fs::read_to_string(&settings_path).map_err(|e| ImportError::IoError {
            path: settings_path.display().to_string(),
            source: e,
        })?;
        let content_trimmed = content.trim_start_matches('\u{feff}');
        let settings_val: Value = serde_json::from_str(content_trimmed).map_err(|e| ImportError::JsonError {
            path: settings_path.display().to_string(),
            source: e,
        })?;

        if let Value::Object(map) = settings_val {
            if let Some(sv) = map.get("schemaVersion").and_then(|v| v.as_i64()) {
                schema_version = sv as i32;
            }

            // Map hostTheme to ui_prefs
            if let Some(host_theme) = map.get("hostTheme") {
                let theme_name = if let Some(obj) = host_theme.as_object() {
                    obj.get("name").and_then(|v| v.as_str()).unwrap_or("tokyo-rain")
                } else if let Some(s) = host_theme.as_str() {
                    s
                } else {
                    "tokyo-rain"
                };
                tx.execute(
                    "INSERT OR REPLACE INTO ui_prefs (key, value) VALUES ('theme', ?1)",
                    params![theme_name],
                )?;
            } else {
                tx.execute(
                    "INSERT OR REPLACE INTO ui_prefs (key, value) VALUES ('theme', 'tokyo-rain')",
                    [],
                )?;
            }

            for (k, mut v) in map {
                // Drop legacy keys: cfApiKey, autoUpdateOnLaunch
                if k == "cfApiKey" || k == "autoUpdateOnLaunch" {
                    continue;
                }

                // Clamps
                if k == "backgroundIntervalMinutes" {
                    if let Some(mins) = v.as_i64() {
                        let clamped = mins.clamp(30, 1440);
                        v = json!(clamped);
                    }
                } else if k == "releaseType" {
                    if let Some(rt) = v.as_i64() {
                        let clamped = rt.clamp(1, 3);
                        v = json!(clamped);
                    }
                }

                tx.execute(
                    "INSERT OR REPLACE INTO settings (key, value) VALUES (?1, ?2)",
                    params![k, v.to_string()],
                )?;
            }
        }
    }

    // 3. Detect flavours and layout
    // In schemaVersion 1 (pre-flavour), addons.json and backups live at top-level
    let mut flavour_addons: Vec<(String, PathBuf)> = Vec::new();
    let mut flavour_backups: Vec<(String, PathBuf)> = Vec::new();

    let top_addons = v1_dir.join("addons.json");
    let flavours_dir = v1_dir.join("flavours");

    if schema_version < 2 || (top_addons.exists() && !flavours_dir.join("retail").join("addons.json").exists()) {
        if top_addons.exists() {
            flavour_addons.push(("retail".into(), top_addons));
        }
        let top_backups = v1_dir.join("backups");
        if top_backups.exists() {
            flavour_backups.push(("retail".into(), top_backups));
        }
    } else if flavours_dir.exists() {
        if let Ok(entries) = fs::read_dir(&flavours_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    let folder_name = entry.file_name().to_string_lossy().to_string();
                    if folder_name.starts_with("_migration-backup-") {
                        continue;
                    }
                    let addons_file = path.join("addons.json");
                    if addons_file.exists() {
                        flavour_addons.push((folder_name.clone(), addons_file));
                    }
                    let backups_dir = path.join("backups");
                    if backups_dir.exists() {
                        flavour_backups.push((folder_name, backups_dir));
                    }
                }
            }
        }
    }

    // 4. Import addons and enforce folder ownership
    for (flavour_id, addons_path) in flavour_addons {
        // Mark flavour installed in flavours table
        tx.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES (?1, ?2, ?3, 1) \
             ON CONFLICT(id) DO UPDATE SET installed = 1",
            params![
                flavour_id,
                format!("_{}_", flavour_id),
                capitalize(&flavour_id)
            ],
        )?;
        summary.flavours_imported += 1;

        let content = fs::read_to_string(&addons_path).map_err(|e| ImportError::IoError {
            path: addons_path.display().to_string(),
            source: e,
        })?;
        let content_trimmed = content.trim_start_matches('\u{feff}');
        let addons_array: Vec<Value> = serde_json::from_str(content_trimmed).map_err(|e| ImportError::JsonError {
            path: addons_path.display().to_string(),
            source: e,
        })?;

        for record in addons_array {
            if let Value::Object(mut map) = record {
                let name = map.remove("name").and_then(|v| v.as_str().map(String::from));
                let author = map.remove("author").and_then(|v| v.as_str().map(String::from));
                let source = map.remove("source").and_then(|v| v.as_str().map(String::from)).unwrap_or_else(|| "curseforge".into());
                let project_id = parse_flexible_i64(map.remove("projectId"));
                let wago_id = map.remove("wagoId").and_then(|v| v.as_str().map(String::from));
                let wago_slug = map.remove("slug").or_else(|| map.remove("wagoSlug")).and_then(|v| v.as_str().map(String::from));
                let curse_id = map.remove("curseId").and_then(|v| {
                    if let Some(s) = v.as_str() {
                        Some(s.to_string())
                    } else if let Some(i) = v.as_i64() {
                        Some(i.to_string())
                    } else {
                        None
                    }
                });
                let repo = map.remove("repo").and_then(|v| v.as_str().map(String::from));
                let version = map.remove("version").and_then(|v| v.as_str().map(String::from));
                let file_id = parse_flexible_string(map.remove("fileId"));
                let file_name = map.remove("fileName").and_then(|v| v.as_str().map(String::from));
                let installed_tag = map.remove("installedTag").and_then(|v| v.as_str().map(String::from));
                let asset_name = map.remove("assetName").and_then(|v| v.as_str().map(String::from));
                let installed_at = map.remove("installedAt").and_then(|v| v.as_str().map(String::from));
                let adopted = map.remove("adopted").and_then(|v| v.as_bool()).unwrap_or(false) as i32;
                let pinned_file_id = parse_flexible_string(map.remove("pinnedFileId"));
                let previous_file_id = parse_flexible_string(map.remove("previousFileId"));
                let previous_version = map.remove("previousVersion").and_then(|v| v.as_str().map(String::from));
                let ignore_updates = map.remove("ignoreUpdates").and_then(|v| v.as_bool()).unwrap_or(false) as i32;
                let release_type = parse_flexible_i64(map.remove("releaseType"));
                let latest_game_versions = map.remove("latestGameVersions").map(|v| v.to_string());
                let required_deps = map.remove("requiredDeps").map(|v| v.to_string());
                let github_rate_limited_until = map.remove("githubRateLimitedUntil").and_then(|v| v.as_str().map(String::from));

                // Extract folders
                let folders: Vec<String> = map
                    .remove("folders")
                    .and_then(|v| {
                        if let Value::Array(arr) = v {
                            Some(
                                arr.into_iter()
                                    .filter_map(|x| x.as_str().map(String::from))
                                    .collect(),
                            )
                        } else {
                            None
                        }
                    })
                    .unwrap_or_default();

                // Generate deterministic ID
                let addon_id = if let Some(pid) = project_id {
                    format!("{}:cf:{}", flavour_id, pid)
                } else if let Some(ref wid) = wago_id {
                    if !wid.trim().is_empty() {
                        format!("{}:wago:{}", flavour_id, wid.trim())
                    } else if let Some(ref slug) = wago_slug {
                        format!("{}:wago:{}", flavour_id, slug.trim())
                    } else {
                        format!("{}:uuid:{}", flavour_id, uuid::Uuid::new_v4())
                    }
                } else if let Some(ref r) = repo {
                    if !r.trim().is_empty() {
                        format!("{}:gh:{}", flavour_id, r.trim())
                    } else {
                        format!("{}:uuid:{}", flavour_id, uuid::Uuid::new_v4())
                    }
                } else if !folders.is_empty() {
                    format!("{}:folder:{}", flavour_id, folders[0])
                } else {
                    format!("{}:uuid:{}", flavour_id, uuid::Uuid::new_v4())
                };

                // The remaining fields in `map` go into `extra`
                let extra_json = if !map.is_empty() {
                    Some(Value::Object(map).to_string())
                } else {
                    None
                };

                // Insert into addons table
                tx.execute(
                    "INSERT OR REPLACE INTO addons (
                        id, flavour, source, project_id, wago_slug, wago_id, curse_id, repo,
                        name, author, version, file_id, file_name, installed_tag, asset_name,
                        installed_at, adopted, pinned_file_id, previous_file_id, previous_version,
                        ignore_updates, release_type, latest_game_versions, required_deps,
                        github_rate_limited_until, extra
                    ) VALUES (
                        ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8,
                        ?9, ?10, ?11, ?12, ?13, ?14, ?15,
                        ?16, ?17, ?18, ?19, ?20,
                        ?21, ?22, ?23, ?24,
                        ?25, ?26
                    )",
                    params![
                        addon_id,
                        flavour_id,
                        source,
                        project_id,
                        wago_slug,
                        wago_id,
                        curse_id,
                        repo,
                        name,
                        author,
                        version,
                        file_id,
                        file_name,
                        installed_tag,
                        asset_name,
                        installed_at,
                        adopted,
                        pinned_file_id,
                        previous_file_id,
                        previous_version,
                        ignore_updates,
                        release_type,
                        latest_game_versions,
                        required_deps,
                        github_rate_limited_until,
                        extra_json,
                    ],
                )?;

                // Enforce folder ownership guard via addon_folders table
                let mut seen_folders = std::collections::HashSet::new();
                for folder in folders {
                    if !seen_folders.insert(folder.to_lowercase()) {
                        continue;
                    }
                    let insert_res = tx.execute(
                        "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES (?1, ?2, ?3)",
                        params![flavour_id, folder, addon_id],
                    );

                    if let Err(rusqlite::Error::SqliteFailure(err, _)) = &insert_res {
                        if err.extended_code == 1555 || err.extended_code == 2067 || err.code == rusqlite::ErrorCode::ConstraintViolation {
                            let existing_addon: String = tx
                                .query_row(
                                    "SELECT addon_id FROM addon_folders WHERE flavour = ?1 AND folder = ?2 COLLATE NOCASE",
                                    params![flavour_id, folder],
                                    |r| r.get(0),
                                )
                                .unwrap_or_else(|_| "unknown".into());

                            return Err(ImportError::FolderOwnershipConflict {
                                flavour: flavour_id,
                                folder,
                                existing_addon,
                                new_addon: addon_id,
                            });
                        }
                    }

                    insert_res?;
                }

                summary.addons_imported += 1;
            }
        }
    }

    // 5. Copy rollback zips into v2 data folder and record in backups
    let v2_backups_root = v2_data_dir.join("backups");
    for (flavour_id, backups_dir) in flavour_backups {
        if let Ok(entries) = fs::read_dir(&backups_dir) {
            for entry in entries.flatten() {
                let sub_path = entry.path();
                if sub_path.is_dir() {
                    let backup_key = entry.file_name().to_string_lossy().to_string();
                    if let Ok(zip_entries) = fs::read_dir(&sub_path) {
                        for zip_entry in zip_entries.flatten() {
                            let zip_path = zip_entry.path();
                            if zip_path.is_file() && zip_path.extension().map_or(false, |ext| ext == "zip") {
                                let filename = zip_entry.file_name().to_string_lossy().to_string();
                                let target_dir = v2_backups_root.join(&flavour_id).join(&backup_key);
                                fs::create_dir_all(&target_dir).map_err(|e| ImportError::IoError {
                                    path: target_dir.display().to_string(),
                                    source: e,
                                })?;

                                let target_zip = target_dir.join(&filename);
                                fs::copy(&zip_path, &target_zip).map_err(|e| ImportError::IoError {
                                    path: target_zip.display().to_string(),
                                    source: e,
                                })?;

                                let metadata = fs::metadata(&target_zip).map_err(|e| ImportError::IoError {
                                    path: target_zip.display().to_string(),
                                    source: e,
                                })?;

                                let size = metadata.len() as i64;
                                let is_pre_adopt = filename == "adopted-original.zip";
                                let kind = if is_pre_adopt { "pre-adopt" } else { "update" };

                                let file_id = if is_pre_adopt {
                                    None
                                } else {
                                    filename.strip_suffix(".zip").map(String::from)
                                };

                                // Find matching addon_id
                                let matching_addon: Option<String> = tx
                                    .query_row(
                                        "SELECT id FROM addons WHERE flavour = ?1 AND (
                                            project_id = ?2 OR
                                            wago_id = ?3 OR
                                            wago_slug = ?3 OR
                                            repo = ?3 OR
                                            curse_id = ?3
                                        ) LIMIT 1",
                                        params![
                                            flavour_id,
                                            backup_key.parse::<i64>().ok(),
                                            backup_key
                                        ],
                                        |r| r.get(0),
                                    )
                                    .ok();

                                let backup_id = uuid::Uuid::new_v4().to_string();
                                let created_at = Utc::now().to_rfc3339();

                                tx.execute(
                                    "INSERT OR REPLACE INTO backups (
                                        id, addon_id, kind, file_id, version, path, size, created_at
                                    ) VALUES (?1, ?2, ?3, ?4, NULL, ?5, ?6, ?7)",
                                    params![
                                        backup_id,
                                        matching_addon,
                                        kind,
                                        file_id,
                                        target_zip.display().to_string(),
                                        size,
                                        created_at,
                                    ],
                                )?;

                                summary.backups_copied += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    // 6. Read state.json if present
    let state_path = v1_dir.join("state.json");
    if state_path.exists() {
        if let Ok(content) = fs::read_to_string(&state_path) {
            if let Ok(state_val) = serde_json::from_str::<Value>(&content) {
                if let Value::Object(state_map) = state_val {
                    // updatesCheckedAt -> freshness
                    if let Some(Value::Object(checked_map)) = state_map.get("updatesCheckedAt") {
                        for (flavour, timestamp_val) in checked_map {
                            if let Some(ts) = timestamp_val.as_str() {
                                tx.execute(
                                    "INSERT OR REPLACE INTO freshness (flavour, state, checked_at, last_success_at)
                                     VALUES (?1, 'clean', ?2, ?2)",
                                    params![flavour, ts],
                                )?;
                            }
                        }
                    }

                    // updateAvailable -> check_results
                    if let Some(Value::Object(avail_map)) = state_map.get("updateAvailable") {
                        for (flavour, updates_val) in avail_map {
                            if let Value::Object(addon_updates) = updates_val {
                                for (key, update_info) in addon_updates {
                                    let matching_addon: Option<String> = tx
                                        .query_row(
                                            "SELECT id FROM addons WHERE flavour = ?1 AND (
                                                project_id = ?2 OR
                                                wago_id = ?3 OR
                                                wago_slug = ?3 OR
                                                repo = ?3 OR
                                                curse_id = ?3
                                            ) LIMIT 1",
                                            params![
                                                flavour,
                                                key.parse::<i64>().ok(),
                                                key
                                            ],
                                            |r| r.get(0),
                                        )
                                        .ok();

                                    if let Some(aid) = matching_addon {
                                        let update_file_id = update_info.get("fileId").and_then(|v| v.as_i64());
                                        let update_version = update_info.get("version").and_then(|v| v.as_str().map(String::from));
                                        let checked_at = Utc::now().to_rfc3339();

                                        tx.execute(
                                            "INSERT OR REPLACE INTO check_results (
                                                addon_id, checked_at, update_file_id, update_version, status, error
                                            ) VALUES (?1, ?2, ?3, ?4, 'update_available', NULL)",
                                            params![aid, checked_at, update_file_id, update_version],
                                        )?;
                                    }
                                }
                            }
                        }
                    }

                    // jobs -> last 20 jobs
                    if let Some(Value::Array(jobs_arr)) = state_map.get("jobs") {
                        for job in jobs_arr.iter().take(20) {
                            if let Value::Object(job_map) = job {
                                let job_id = job_map.get("id").and_then(|v| v.as_str()).map(String::from).unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
                                let kind = job_map.get("kind").and_then(|v| v.as_str()).unwrap_or("check");
                                let flavour = job_map.get("flavour").and_then(|v| v.as_str());
                                let state = job_map.get("state").and_then(|v| v.as_str()).unwrap_or("completed");
                                let started_at = job_map.get("startedAt").and_then(|v| v.as_str()).unwrap_or("");
                                let finished_at = job_map.get("finishedAt").and_then(|v| v.as_str());
                                let results = job_map.get("results").map(|v| v.to_string());
                                let reload_needed = job_map.get("reloadNeeded").and_then(|v| v.as_bool()).unwrap_or(false) as i32;

                                tx.execute(
                                    "INSERT OR REPLACE INTO jobs (
                                        id, kind, flavour, state, started_at, finished_at, results, reload_needed
                                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                                    params![job_id, kind, flavour, state, started_at, finished_at, results, reload_needed],
                                )?;
                            }
                        }
                    }
                }
            }
        }
    }

    // 7. Read tray-state.json
    let tray_state_path = v1_dir.join("tray-state.json");
    if tray_state_path.exists() {
        if let Ok(content) = fs::read_to_string(&tray_state_path) {
            tx.execute(
                "INSERT OR REPLACE INTO tray_state (id, data) VALUES (1, ?1)",
                params![content],
            )?;
        }
    }

    // 8. Read app-update.json
    let app_update_path = v1_dir.join("app-update.json");
    if app_update_path.exists() {
        if let Ok(content) = fs::read_to_string(&app_update_path) {
            tx.execute(
                "INSERT OR REPLACE INTO app_update (id, data) VALUES (1, ?1)",
                params![content],
            )?;
        }
    }

    // 9. Record metadata
    let now = Utc::now().to_rfc3339();
    tx.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('imported_from_v1_at', ?1)",
        params![now],
    )?;
    tx.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('v1_root', ?1)",
        params![v1_dir.display().to_string()],
    )?;
    tx.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('v1_version', ?1)",
        params![v1_version],
    )?;
    tx.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('dual_write_until', '2.1.0')",
        [],
    )?;

    tx.commit()?;

    Ok(summary)
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        None => String::new(),
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
    }
}
