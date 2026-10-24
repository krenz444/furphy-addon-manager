use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use crate::db::open_connection;
use crate::db::repo::get_settings_map;
use crate::engine::import_list::{export_addon_list_v2_with_options, import_addon_list};
use crate::net::policy::NetworkPolicy;
use crate::paths::{detect_wow_root, get_data_dir, get_db_path, is_dev};

#[derive(Debug, Serialize, Deserialize)]
pub struct DiagnosticItemDto {
    pub name: String,
    pub ok: bool,
    pub detail: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct MigrationBackupDto {
    pub name: String,
    pub path: String,
    pub size_bytes: u64,
}

#[tauri::command]
pub fn get_settings() -> Result<HashMap<String, Value>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let mut map = get_settings_map(&conn).map_err(|e| e.to_string())?;

    // Token is write-only, show ONLY whether token is set!
    let has_token = match map.get("githubToken") {
        Some(Value::String(s)) => !s.trim().is_empty(),
        _ => false,
    };
    map.remove("githubToken");
    map.insert("hasGithubToken".to_string(), Value::Bool(has_token));

    Ok(map)
}

#[tauri::command]
pub fn update_settings(key: String, value: Value) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let json_str = serde_json::to_string(&value).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2",
        rusqlite::params![key, json_str],
    )
    .map_err(|e| e.to_string())?;
    crate::db::export_v1::trigger_dual_write_if_v1_exists(&conn);
    Ok(())
}

#[tauri::command]
pub fn export_list(
    flavour: String,
    include_wtf: bool,
    path: Option<String>,
) -> Result<String, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let wow_root = detect_wow_root(None).ok();
    let flv_clean = flavour.trim_matches('_');
    let flv_folder = format!("_{}_", flv_clean);

    let dest = if let Some(p) = path {
        PathBuf::from(p)
    } else {
        let filename = format!(
            "furphy-addons-{}-{}.json",
            flv_clean,
            chrono::Utc::now().format("%Y%m%d")
        );
        get_data_dir().join(filename)
    };

    export_addon_list_v2_with_options(
        &conn,
        &flavour,
        &dest,
        include_wtf,
        wow_root.as_deref(),
        Some(&flv_folder),
    )?;

    Ok(dest.to_string_lossy().to_string())
}

#[tauri::command]
pub fn import_list(path: Option<String>, flavour: String) -> Result<usize, String> {
    let db_path = get_db_path();
    let mut conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let target_path = if let Some(p) = path {
        PathBuf::from(p)
    } else {
        let data_dir = get_data_dir();
        let mut newest: Option<PathBuf> = None;
        if let Ok(entries) = std::fs::read_dir(&data_dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_file() && p.extension().map(|e| e == "json").unwrap_or(false) {
                    if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                        if name.starts_with("furphy-addons-") || name.starts_with("addons-") {
                            newest = Some(p);
                        }
                    }
                }
            }
        }
        newest.ok_or_else(|| "No export file specified and none found in data folder".to_string())?
    };

    if !target_path.exists() {
        return Err(format!("Import file not found: {}", target_path.display()));
    }
    let count = import_addon_list(&mut conn, &flavour, &target_path).map_err(|e| e.to_string())?;
    Ok(count)
}

#[tauri::command]
pub async fn run_diagnostics(
    policy: tauri::State<'_, Arc<NetworkPolicy>>,
) -> Result<Vec<DiagnosticItemDto>, String> {
    let mut list = Vec::new();

    // 1. WoW Root
    match detect_wow_root(None) {
        Ok(root) => list.push(DiagnosticItemDto {
            name: "World of Warcraft Root".into(),
            ok: true,
            detail: root.to_string_lossy().to_string(),
        }),
        Err(e) => list.push(DiagnosticItemDto {
            name: "World of Warcraft Root".into(),
            ok: false,
            detail: e.to_string(),
        }),
    }

    // 2. Data directory
    let data_dir = get_data_dir();
    list.push(DiagnosticItemDto {
        name: "Data Directory".into(),
        ok: data_dir.is_dir(),
        detail: data_dir.to_string_lossy().to_string(),
    });

    // 3. Database
    let db_path = get_db_path();
    let (db_ok, db_detail) = match open_connection(&db_path) {
        Ok(c) => match c.query_row("SELECT 1", [], |_| Ok(())) {
            Ok(_) => (true, db_path.to_string_lossy().to_string()),
            Err(e) => (false, format!("{} ({})", db_path.display(), e)),
        },
        Err(e) => (false, format!("{} ({})", db_path.display(), e)),
    };
    list.push(DiagnosticItemDto {
        name: "SQLite Database".into(),
        ok: db_ok,
        detail: db_detail,
    });

    // 4. CurseForge Policy & 24h Fallback (ADR-312)
    let cf_fallback = policy.is_cf_fallback_active().await;
    list.push(DiagnosticItemDto {
        name: "CurseForge Policy".into(),
        ok: true,
        detail: if cf_fallback {
            "24-hour rate fallback active (1 request in flight, 300ms pacing)".into()
        } else {
            "Standard policy active (2 requests in flight, 100ms pacing)".into()
        },
    });

    // 5. Host Breaker status
    let cf_offline = policy.breaker.is_open("curseforge.com");
    let wago_offline = policy.breaker.is_open("addons.wago.io");
    let gh_offline = policy.breaker.is_open("api.github.com");
    list.push(DiagnosticItemDto {
        name: "Host Breakers".into(),
        ok: !cf_offline && !wago_offline && !gh_offline,
        detail: format!(
            "CurseForge: {}, Wago: {}, GitHub: {}",
            if cf_offline { "OFFLINE" } else { "online" },
            if wago_offline { "OFFLINE" } else { "online" },
            if gh_offline { "OFFLINE" } else { "online" }
        ),
    });

    // 6. Running Mode
    list.push(DiagnosticItemDto {
        name: "Application Mode".into(),
        ok: true,
        detail: if is_dev() {
            "Development (Furphy Dev)"
        } else {
            "Production"
        }
        .into(),
    });

    Ok(list)
}

#[tauri::command]
pub fn list_migration_backups() -> Result<Vec<MigrationBackupDto>, String> {
    let mig_dir = get_data_dir().join("migration_backups");
    if !mig_dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut list = Vec::new();
    if let Ok(entries) = std::fs::read_dir(mig_dir) {
        for entry in entries.flatten() {
            let meta = entry.metadata().ok();
            let is_file = meta.as_ref().map(|m| m.is_file()).unwrap_or(false);
            if is_file {
                list.push(MigrationBackupDto {
                    name: entry.file_name().to_string_lossy().to_string(),
                    path: entry.path().to_string_lossy().to_string(),
                    size_bytes: meta.as_ref().map(|m| m.len()).unwrap_or(0),
                });
            }
        }
    }
    Ok(list)
}

#[tauri::command]
pub fn delete_migration_backups() -> Result<(), String> {
    let mig_dir = get_data_dir().join("migration_backups");
    if mig_dir.is_dir() {
        let _ = std::fs::remove_dir_all(&mig_dir);
        let _ = std::fs::create_dir_all(&mig_dir);
    }
    Ok(())
}

#[tauri::command]
pub fn quit_app() -> Result<(), String> {
    std::process::exit(0);
}

#[tauri::command]
pub fn set_window_theme(theme: String) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let val = serde_json::to_string(&theme).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('hostTheme', ?1) ON CONFLICT(key) DO UPDATE SET value = ?1",
        rusqlite::params![val],
    )
    .map_err(|e| e.to_string())?;
    let _ = conn.execute(
        "INSERT INTO ui_prefs (key, value) VALUES ('theme', ?1) ON CONFLICT(key) DO UPDATE SET value = ?1",
        rusqlite::params![theme],
    );
    crate::db::export_v1::trigger_dual_write_if_v1_exists(&conn);
    Ok(())
}

#[tauri::command]
pub async fn app_update_check() -> Result<Value, String> {
    let status = crate::update::app_update::check_for_updates(None).await?;
    let db_path = get_db_path();
    if let Ok(conn) = open_connection(&db_path) {
        let _ = crate::update::app_update::save_app_update_state(&conn, &status);
    }
    serde_json::to_value(&status).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn app_update_install(
    runner: tauri::State<'_, Arc<crate::jobs::runner::JobRunner>>,
) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;

    let is_busy = runner.is_busy().await;
    let status = crate::update::app_update::load_app_update_state(&conn)
        .ok_or_else(|| "No update state found. Check for updates first.".to_string())?;

    match crate::update::app_update::install_update(&status, is_busy, true).await {
        Ok(_) => Ok(()),
        Err(e) => {
            let mut err_status = status.clone();
            err_status.status = "error".into();
            err_status.error = Some(e.clone());
            let _ = crate::update::app_update::save_app_update_state(&conn, &err_status);
            Err(e)
        }
    }
}

#[tauri::command]
pub fn app_update_status() -> Result<Value, String> {
    let db_path = get_db_path();
    let (status, first_run_update) = if let Ok(conn) = open_connection(&db_path) {
        let first_run = crate::update::app_update::check_first_run_after_update(&conn);
        let s = crate::update::app_update::load_app_update_state(&conn).unwrap_or_default();
        (s, first_run)
    } else {
        (crate::update::app_update::AppUpdateStatus::default(), None)
    };

    let mut val = serde_json::to_value(&status).map_err(|e| e.to_string())?;
    if let Value::Object(ref mut map) = val {
        map.insert(
            "first_run_update".into(),
            serde_json::to_value(&first_run_update).unwrap_or(Value::Null),
        );
    }
    Ok(val)
}
