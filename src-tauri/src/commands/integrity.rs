use crate::db::open_connection;
use crate::engine::integrity::{verify_addon_integrity, IntegrityReport};
use crate::paths::{detect_wow_root, get_db_path};

#[tauri::command]
pub fn show_addon_folder(flavour: String, addon_id: String) -> Result<(), String> {
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

    let wow_root = detect_wow_root(None).ok();
    let installed = crate::engine::flavours::detect_all_installed_flavours(&conn, wow_root.as_deref());
    let flv = installed
        .iter()
        .find(|f| f.id == flavour)
        .ok_or_else(|| format!("Flavour {} not installed", flavour))?;

    let mut stmt = conn
        .prepare("SELECT folder FROM addon_folders WHERE flavour = ?1 AND addon_id = ?2 ORDER BY folder ASC")
        .map_err(|e| format!("Database error: {}", e))?;
    let folder_iter = stmt
        .query_map(rusqlite::params![flavour, addon_id], |r| r.get::<_, String>(0))
        .map_err(|e| format!("Database error: {}", e))?;

    let mut found_path = None;
    for f in folder_iter {
        let folder_name = f.map_err(|e| format!("Database error: {}", e))?;
        let folder_path = flv.addons_path.join(folder_name);
        if folder_path.exists() {
            found_path = Some(folder_path);
            break;
        }
    }

    let folder_path = found_path.ok_or_else(|| format!("Addon {} folder not found on disk", addon_id))?;
    crate::commands::open::open_folder_path(&folder_path)
}

#[tauri::command]
pub fn integrity_report(flavour: String, addon_id: String) -> Result<IntegrityReport, String> {
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

    let wow_root = detect_wow_root(None).ok();
    let installed = crate::engine::flavours::detect_all_installed_flavours(&conn, wow_root.as_deref());
    let flv = installed
        .iter()
        .find(|f| f.id == flavour)
        .ok_or_else(|| format!("Flavour {} not installed", flavour))?;

    let report = verify_addon_integrity(&conn, &flv.addons_path, &addon_id)?;
    conn.execute(
        "UPDATE addons SET integrity_status = ?1 WHERE id = ?2",
        rusqlite::params![report.status.as_str(), addon_id],
    )
    .map_err(|e| format!("Database error: {}", e))?;

    Ok(report)
}
