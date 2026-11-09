use crate::db::open_connection;
use crate::engine::activity::{clear_activity_records, list_activity_records, ActivityEntry};
use crate::paths::get_db_path;

#[tauri::command]
pub fn list_activity(flavour: Option<String>, limit: Option<usize>) -> Result<Vec<ActivityEntry>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    list_activity_records(&conn, flavour.as_deref(), limit).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn clear_activity(flavour: Option<String>) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    clear_activity_records(&conn, flavour.as_deref()).map_err(|e| e.to_string())
}
