use std::fs;
use std::path::Path;
use rusqlite::{params, Connection, Result};
use crate::engine::ownership::get_protected_folders;
use crate::logging::append_app_log;

pub fn remove_addon(
    conn: &mut Connection,
    addon_id: &str,
    flavour: &str,
    addons_path: &Path,
) -> Result<(), String> {
    // 1. Fetch folders owned by this addon
    let mut stmt = conn
        .prepare("SELECT folder FROM addon_folders WHERE addon_id = ?1 AND flavour = ?2")
        .map_err(|e| e.to_string())?;
    let frows = stmt
        .query_map(params![addon_id, flavour], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?;
    let folders: Vec<String> = frows.flatten().collect();
    drop(stmt);

    // 2. Fetch protected folders (owned by OTHER addons)

    let protected = get_protected_folders(conn, flavour, Some(addon_id)).map_err(|e| e.to_string())?;

    // 3. Remove non-protected folders from disk
    for f in &folders {
        if protected.contains(&f.to_ascii_lowercase()) {
            append_app_log(
                "INFO",
                &format!("Kept folder '{}' - tracked by another addon during removal", f),
            );
            continue;
        }

        let folder_dir = addons_path.join(f);
        if folder_dir.exists() {
            let _ = fs::remove_dir_all(&folder_dir);
            append_app_log("INFO", &format!("Removed folder '{}' for addon {}", f, addon_id));
        }
    }

    // 4. Remove from DB in transaction
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    tx.execute("DELETE FROM addon_folders WHERE addon_id = ?1", params![addon_id]).map_err(|e| e.to_string())?;
    tx.execute("DELETE FROM check_results WHERE addon_id = ?1", params![addon_id]).map_err(|e| e.to_string())?;
    tx.execute("DELETE FROM addons WHERE id = ?1", params![addon_id]).map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())?;

    append_app_log("INFO", &format!("Removed addon {} from flavour {}", addon_id, flavour));
    Ok(())
}
