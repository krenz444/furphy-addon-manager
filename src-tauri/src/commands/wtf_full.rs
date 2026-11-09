use crate::db::open_connection;
use crate::engine::wtf_full::{
    delete_whole_wtf_backup, list_whole_wtf_backups, preview_restore_whole_wtf,
    WholeWtfBackupRecord, WtfRestorePreview,
};
use crate::paths::{detect_wow_root, get_db_path};

#[tauri::command]
pub fn wtf_backups_list(flavour: String) -> Result<Vec<WholeWtfBackupRecord>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    list_whole_wtf_backups(&conn, &flavour).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn wtf_restore_preview(backup_id: String) -> Result<WtfRestorePreview, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let wow_root = detect_wow_root(None).map_err(|e| e.to_string())?;
    preview_restore_whole_wtf(&conn, &wow_root, "_retail_", &backup_id)
}

#[tauri::command]
pub fn wtf_backup_delete(backup_id: String) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    delete_whole_wtf_backup(&conn, &backup_id)
}
