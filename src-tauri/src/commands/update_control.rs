use std::collections::HashMap;
use crate::db::open_connection;
use crate::paths::get_db_path;

#[tauri::command]
pub fn hold_ignore_for_build(addon_id: String, build: String) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
    let exists: bool = conn
        .query_row(
            "SELECT COUNT(*) > 0 FROM addons WHERE id = ?1",
            rusqlite::params![addon_id],
            |r| r.get(0),
        )
        .map_err(|e| format!("Database error: {}", e))?;
    if !exists {
        return Err(format!("Addon {} not found", addon_id));
    }
    crate::engine::holdback::set_ignored_until_build(&conn, &addon_id, &build)
        .map_err(|e| format!("Database error: {}", e))?;
    Ok(())
}

#[tauri::command]
pub fn set_release_channel(addon_id: String, release_type: i64) -> Result<(), String> {
    if !(1..=3).contains(&release_type) {
        return Err("Invalid release type: must be 1 (stable), 2 (beta), or 3 (alpha)".to_string());
    }
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
    crate::engine::update_control::set_addon_release_channel(&conn, &addon_id, release_type)
        .map_err(|e| format!("Database error: {}", e))?;
    Ok(())
}

#[tauri::command]
pub fn set_auto_update(addon_id: String, auto_update: bool) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
    crate::engine::update_control::set_addon_auto_update(&conn, &addon_id, auto_update)
        .map_err(|e| format!("Database error: {}", e))?;
    Ok(())
}

#[tauri::command]
pub fn set_update_mode(flavour: String, update_mode: String) -> Result<(), String> {
    let mode_lower = update_mode.to_ascii_lowercase();
    if mode_lower != "auto" && mode_lower != "notify" {
        return Err("Invalid update mode: must be 'auto' or 'notify'".to_string());
    }
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
    crate::engine::update_control::set_flavour_update_mode(&conn, &flavour, &mode_lower)
        .map_err(|e| format!("Database error: {}", e))?;
    Ok(())
}

#[tauri::command]
pub fn get_update_modes() -> Result<HashMap<String, String>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;
    crate::engine::update_control::get_flavour_update_modes(&conn)
        .map_err(|e| format!("Database error: {}", e))
}
