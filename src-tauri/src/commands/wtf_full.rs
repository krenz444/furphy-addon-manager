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

    let flavour: String = conn
        .query_row(
            "SELECT flavour FROM whole_wtf_backups WHERE id = ?1",
            rusqlite::params![backup_id],
            |r| r.get(0),
        )
        .map_err(|e| format!("Backup '{}' not found: {}", backup_id, e))?;

    let flavour_folder: String = conn
        .query_row(
            "SELECT folder FROM flavours WHERE id = ?1",
            rusqlite::params![flavour],
            |r| r.get(0),
        )
        .unwrap_or_else(|_| {
            crate::paths::FLAVOUR_DEFS
                .iter()
                .find(|f| f.id == flavour)
                .map(|f| f.folder.to_string())
                .unwrap_or_else(|| format!("_{}_", flavour))
        });

    preview_restore_whole_wtf(&conn, &wow_root, &flavour_folder, &backup_id)
}

#[tauri::command]
pub fn wtf_backup_delete(backup_id: String) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    delete_whole_wtf_backup(&conn, &backup_id)
}
