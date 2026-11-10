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
    tx.execute("DELETE FROM addon_manifests WHERE addon_id = ?1", params![addon_id]).map_err(|e| e.to_string())?;
    // Group memberships go with the addon even when foreign keys are off; the table exists from schema version 8.
    if let Err(e) = tx.execute("DELETE FROM addon_group_members WHERE addon_id = ?1", params![addon_id]) {
        let text = e.to_string();
        if !text.contains("no such table") {
            return Err(text);
        }
    }
    tx.execute("DELETE FROM addon_folders WHERE addon_id = ?1", params![addon_id]).map_err(|e| e.to_string())?;
    tx.execute("DELETE FROM check_results WHERE addon_id = ?1", params![addon_id]).map_err(|e| e.to_string())?;
    tx.execute("DELETE FROM addons WHERE id = ?1", params![addon_id]).map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())?;

    append_app_log("INFO", &format!("Removed addon {} from flavour {}", addon_id, flavour));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::migrate::run_migrations;

    #[test]
    fn remove_addon_deletes_its_group_memberships_and_keeps_the_others() {
        let mut conn = Connection::open_in_memory().unwrap();
        run_migrations(&mut conn).unwrap();
        // Foreign keys off: the explicit delete in remove_addon must do the work on its own.
        conn.execute_batch("PRAGMA foreign_keys = OFF;").unwrap();

        conn.execute("INSERT INTO addons (id, flavour, name) VALUES ('a1', 'retail', 'One')", []).unwrap();
        conn.execute("INSERT INTO addons (id, flavour, name) VALUES ('a2', 'retail', 'Two')", []).unwrap();
        conn.execute("INSERT INTO addon_groups (id, name, created_at) VALUES ('g1', 'Raid', '2026-11-10T00:00:00Z')", []).unwrap();
        conn.execute("INSERT INTO addon_group_members (group_id, addon_id) VALUES ('g1', 'a1')", []).unwrap();
        conn.execute("INSERT INTO addon_group_members (group_id, addon_id) VALUES ('g1', 'a2')", []).unwrap();

        let dir = tempfile::tempdir().unwrap();
        remove_addon(&mut conn, "a1", "retail", dir.path()).unwrap();

        let members: Vec<String> = {
            let mut stmt = conn.prepare("SELECT addon_id FROM addon_group_members ORDER BY addon_id").unwrap();
            let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
            rows.flatten().collect()
        };
        assert_eq!(members, vec!["a2".to_string()]);
        let addons: i64 = conn.query_row("SELECT COUNT(*) FROM addons WHERE id = 'a1'", [], |r| r.get(0)).unwrap();
        assert_eq!(addons, 0);
        let group_still_there: i64 = conn.query_row("SELECT COUNT(*) FROM addon_groups WHERE id = 'g1'", [], |r| r.get(0)).unwrap();
        assert_eq!(group_still_there, 1, "removing an addon never deletes its group");
    }
}
