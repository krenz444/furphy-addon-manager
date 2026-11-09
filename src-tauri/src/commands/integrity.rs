use crate::db::open_connection;
use crate::engine::integrity::{verify_addon_integrity, IntegrityReport};
use crate::paths::{detect_wow_root, get_db_path};

#[tauri::command]
pub fn show_addon_folder(flavour: String, addon_id: String) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;

    let wow_root = detect_wow_root(None).ok();
    let installed = crate::engine::flavours::detect_all_installed_flavours(&conn, wow_root.as_deref());
    let flv = installed
        .iter()
        .find(|f| f.id == flavour)
        .ok_or_else(|| format!("Flavour {} not installed", flavour))?;

    let folder_name: Option<String> = conn
        .query_row(
            "SELECT folder FROM addon_folders WHERE flavour = ?1 AND addon_id = ?2 ORDER BY folder ASC LIMIT 1",
            rusqlite::params![flavour, addon_id],
            |r| r.get(0),
        )
        .ok();

    let folder_name = folder_name.ok_or_else(|| format!("Addon {} folder not found on disk", addon_id))?;
    let folder_path = flv.addons_path.join(folder_name);
    if !folder_path.exists() {
        return Err(format!("Addon {} folder not found on disk", addon_id));
    }

    crate::commands::open::open_folder_path(&folder_path)
}

#[tauri::command]
pub fn integrity_report(flavour: String, addon_id: String) -> Result<IntegrityReport, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;

    let wow_root = detect_wow_root(None).ok();
    let installed = crate::engine::flavours::detect_all_installed_flavours(&conn, wow_root.as_deref());
    let flv = installed
        .iter()
        .find(|f| f.id == flavour)
        .ok_or_else(|| format!("Flavour {} not installed", flavour))?;

    verify_addon_integrity(&conn, &flv.addons_path, &addon_id)
}
