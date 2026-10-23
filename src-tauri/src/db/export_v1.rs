use std::fs;
use std::path::Path;
use rusqlite::{params, Connection};
use serde_json::{json, Map, Value};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ExportError {
    #[error("Failed to write file '{path}': {source}")]
    IoError {
        path: String,
        source: std::io::Error,
    },

    #[error("Database error: {0}")]
    DatabaseError(#[from] rusqlite::Error),

    #[error("Failed to serialize JSON: {0}")]
    JsonError(#[from] serde_json::Error),
}

pub fn export_to_v1(conn: &Connection, target_dir: &Path) -> Result<(), ExportError> {
    fs::create_dir_all(target_dir).map_err(|e| ExportError::IoError {
        path: target_dir.display().to_string(),
        source: e,
    })?;

    // 1. Export settings.json
    let mut settings_map = Map::new();
    let mut stmt = conn.prepare("SELECT key, value FROM settings")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;

    for row in rows {
        let (k, v) = row?;
        if let Ok(val) = serde_json::from_str::<Value>(&v) {
            settings_map.insert(k, val);
        }
    }

    // Ensure all 14 v1 standard keys exist with defaults if missing
    settings_map.entry("releaseType").or_insert(json!(1));
    settings_map.entry("port").or_insert(json!(47831));
    settings_map.entry("adFilter").or_insert(json!(true));
    settings_map.entry("cfFocus").or_insert(json!(true));
    settings_map.entry("hostWindow").or_insert(Value::Null);

    // Export current theme from ui_prefs into hostTheme (§7)
    let theme_val: Option<String> = conn
        .query_row("SELECT value FROM ui_prefs WHERE key = 'theme'", [], |r| r.get(0))
        .ok()
        .or_else(|| {
            conn.query_row("SELECT value FROM settings WHERE key = 'hostTheme'", [], |r| r.get(0))
                .ok()
                .and_then(|s: String| serde_json::from_str::<String>(&s).ok().or(Some(s)))
        });
    let host_theme_val = if let Some(theme) = theme_val {
        json!({ "name": theme })
    } else {
        json!({ "name": "tokyo-rain" })
    };
    settings_map.insert("hostTheme".to_string(), host_theme_val);

    settings_map.entry("backgroundUpdates").or_insert(json!(false));
    settings_map.entry("backgroundIntervalMinutes").or_insert(json!(120));
    settings_map.entry("runAtStartup").or_insert(json!(false));
    settings_map.entry("appUpdateAutoInstall").or_insert(json!(true));
    settings_map.entry("schemaVersion").or_insert(json!(2));
    settings_map.entry("activeFlavour").or_insert(json!("retail"));
    settings_map.entry("showTestRealms").or_insert(json!(false));
    settings_map.entry("githubToken").or_insert(Value::Null);

    let settings_path = target_dir.join("settings.json");
    let settings_json_str = serde_json::to_string_pretty(&Value::Object(settings_map))?;
    fs::write(&settings_path, settings_json_str).map_err(|e| ExportError::IoError {
        path: settings_path.display().to_string(),
        source: e,
    })?;

    // 2. Export flavours/<flavour>/addons.json
    let mut flavour_stmt = conn.prepare(
        "SELECT id FROM flavours WHERE installed = 1 
         UNION 
         SELECT DISTINCT flavour FROM addons",
    )?;
    let flavour_rows = flavour_stmt.query_map([], |r| r.get::<_, String>(0))?;

    for flavour_res in flavour_rows {
        let flavour_id = flavour_res?;
        let flavour_dir = target_dir.join("flavours").join(&flavour_id);
        fs::create_dir_all(&flavour_dir).map_err(|e| ExportError::IoError {
            path: flavour_dir.display().to_string(),
            source: e,
        })?;

        let mut addon_stmt = conn.prepare(
            "SELECT 
                id, name, project_id, file_id, version, file_name, installed_at,
                author, ignore_updates, pinned_file_id, release_type, previous_file_id,
                previous_version, required_deps, source, wago_id, wago_slug,
                curse_id, latest_game_versions, adopted, repo, installed_tag,
                asset_name, github_rate_limited_until, extra
             FROM addons WHERE flavour = ?1 ORDER BY rowid",
        )?;

        let mut addons_list: Vec<Value> = Vec::new();
        let addon_rows = addon_stmt.query_map(params![flavour_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<i64>>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, i32>(8)?,
                row.get::<_, Option<String>>(9)?,
                row.get::<_, Option<i64>>(10)?,
                row.get::<_, Option<String>>(11)?,
                row.get::<_, Option<String>>(12)?,
                row.get::<_, Option<String>>(13)?,
                row.get::<_, Option<String>>(14)?,
                row.get::<_, Option<String>>(15)?,
                row.get::<_, Option<String>>(16)?,
                row.get::<_, Option<String>>(17)?,
                row.get::<_, Option<String>>(18)?,
                row.get::<_, i32>(19)?,
                row.get::<_, Option<String>>(20)?,
                row.get::<_, Option<String>>(21)?,
                row.get::<_, Option<String>>(22)?,
                row.get::<_, Option<String>>(23)?,
                row.get::<_, Option<String>>(24)?,
            ))
        })?;

        for r in addon_rows {
            let (
                addon_id, name, project_id, file_id, version, file_name, installed_at,
                author, ignore_updates, pinned_file_id, release_type, previous_file_id,
                previous_version, required_deps_str, source, wago_id, wago_slug,
                curse_id, latest_game_versions_str, adopted, repo, installed_tag,
                asset_name, github_rate_limited_until, extra_str
            ) = r?;

            // Retrieve folders from addon_folders
            let mut folder_stmt = conn.prepare(
                "SELECT folder FROM addon_folders WHERE flavour = ?1 AND addon_id = ?2 ORDER BY rowid",
            )?;
            let folder_rows = folder_stmt.query_map(params![flavour_id, addon_id], |fr| fr.get::<_, String>(0))?;
            let folders: Vec<String> = folder_rows.flatten().collect();

            let required_deps: Value = required_deps_str
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_else(|| json!([]));

            let latest_game_versions: Value = latest_game_versions_str
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_else(|| json!([]));

            let format_file_id = |s: Option<String>| -> Value {
                match s {
                    Some(val) => {
                        if source.as_deref() == Some("curseforge") {
                            if let Ok(num) = val.parse::<i64>() {
                                json!(num)
                            } else {
                                json!(val)
                            }
                        } else {
                            json!(val)
                        }
                    }
                    None => Value::Null,
                }
            };

            let mut addon_map = Map::new();
            addon_map.insert("name".into(), json!(name));
            addon_map.insert("projectId".into(), json!(project_id));
            addon_map.insert("fileId".into(), format_file_id(file_id));
            addon_map.insert("version".into(), json!(version));
            addon_map.insert("fileName".into(), json!(file_name));
            addon_map.insert("installedAt".into(), json!(installed_at));
            addon_map.insert("folders".into(), json!(folders));
            addon_map.insert("author".into(), json!(author));
            addon_map.insert("ignoreUpdates".into(), json!(ignore_updates != 0));
            addon_map.insert("pinnedFileId".into(), format_file_id(pinned_file_id));
            addon_map.insert("releaseType".into(), json!(release_type));
            addon_map.insert("previousFileId".into(), format_file_id(previous_file_id));
            addon_map.insert("previousVersion".into(), json!(previous_version));
            addon_map.insert("requiredDeps".into(), required_deps);
            addon_map.insert("source".into(), json!(source.unwrap_or_else(|| "curseforge".into())));
            addon_map.insert("wagoId".into(), json!(wago_id));
            addon_map.insert("slug".into(), json!(wago_slug));
            addon_map.insert("curseId".into(), json!(curse_id));
            addon_map.insert("latestGameVersions".into(), latest_game_versions);
            addon_map.insert("adopted".into(), json!(adopted != 0));
            addon_map.insert("repo".into(), json!(repo));
            addon_map.insert("installedTag".into(), json!(installed_tag));
            addon_map.insert("assetName".into(), json!(asset_name));
            addon_map.insert("githubRateLimitedUntil".into(), json!(github_rate_limited_until));

            // Merge any extra fields back into the record
            if let Some(extra) = extra_str {
                if let Ok(Value::Object(extra_map)) = serde_json::from_str::<Value>(&extra) {
                    for (k, v) in extra_map {
                        addon_map.insert(k, v);
                    }
                }
            }

            addons_list.push(Value::Object(addon_map));
        }

        let addons_file_path = flavour_dir.join("addons.json");
        let addons_json_str = serde_json::to_string_pretty(&addons_list)?;
        fs::write(&addons_file_path, addons_json_str).map_err(|e| ExportError::IoError {
            path: addons_file_path.display().to_string(),
            source: e,
        })?;
    }

    Ok(())
}

/// Triggers export_to_v1 if a v1 directory exists next to the WoW installation
pub fn trigger_dual_write_if_v1_exists(conn: &Connection) {
    if let Ok(wow_root) = crate::paths::detect_wow_root(None) {
        let v1_dir = crate::paths::get_v1_sync_folder(&wow_root);
        if v1_dir.exists() {
            let _ = export_to_v1(conn, &v1_dir);
        }
    }
}
