use std::collections::HashMap;
use rusqlite::{params, Connection, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddonDto {
    pub id: String,
    pub flavour: String,
    pub name: Option<String>,
    pub author: Option<String>,
    pub source: Option<String>,
    pub version: Option<String>,
    pub project_id: Option<i64>,
    pub file_id: Option<String>,
    pub file_name: Option<String>,
    pub folders: Vec<String>,
    pub installed_at: Option<String>,
    pub adopted: bool,
    pub ignore_updates: bool,
    pub pinned_file_id: Option<String>,
    pub release_type: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlavourDto {
    pub id: String,
    pub folder: String,
    pub label: String,
    pub product: Option<String>,
    pub installed: bool,
    pub client_build: Option<String>,
    pub client_interface: Option<i32>,
    pub custom_root: Option<String>,
    pub addons_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WtfSnapshotRecord {
    pub id: String,
    pub addon_id: Option<String>,
    pub account: Option<String>,
    pub scope: Option<String>,
    pub path: String,
    pub size: Option<i64>,
    pub created_at: Option<String>,
    pub kind: Option<String>,
    pub restored_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupRecord {
    pub id: String,
    pub addon_id: Option<String>,
    pub kind: String,
    pub file_id: Option<String>,
    pub version: Option<String>,
    pub path: String,
    pub size: Option<i64>,
    pub created_at: Option<String>,
}

pub fn get_installed_flavours_db(conn: &Connection) -> Result<Vec<FlavourDto>> {
    let mut stmt = conn.prepare(
        "SELECT id, folder, label, product, installed, client_build, client_interface, custom_root \
         FROM flavours WHERE installed = 1"
    )?;
    let rows = stmt.query_map([], |row| {
        let id: String = row.get(0)?;
        let folder: String = row.get(1)?;
        let label: String = row.get(2)?;
        let product: Option<String> = row.get(3)?;
        let installed: bool = row.get::<_, i32>(4)? != 0;
        let client_build: Option<String> = row.get(5).ok().flatten();
        let client_interface: Option<i32> = row.get::<_, Option<String>>(6)
            .ok()
            .flatten()
            .and_then(|s| s.parse::<i32>().ok())
            .or_else(|| row.get::<_, Option<i32>>(6).ok().flatten());
        let custom_root: Option<String> = row.get(7).ok().flatten();

        Ok(FlavourDto {
            id,
            folder,
            label,
            product,
            installed,
            client_build,
            client_interface,
            custom_root,
            addons_path: None,
        })
    })?;

    let mut result = Vec::new();
    for r in rows {
        result.push(r?);
    }
    Ok(result)
}

pub fn set_flavour_custom_root(conn: &Connection, flavour_id: &str, custom_root: &str) -> Result<()> {
    conn.execute(
        "UPDATE flavours SET custom_root = ?1 WHERE id = ?2",
        params![custom_root, flavour_id],
    )?;
    Ok(())
}

pub fn reset_flavour_custom_root(conn: &Connection, flavour_id: &str) -> Result<()> {
    conn.execute(
        "UPDATE flavours SET custom_root = NULL WHERE id = ?1",
        params![flavour_id],
    )?;
    Ok(())
}

pub fn get_flavour_custom_root(conn: &Connection, flavour_id: &str) -> Result<Option<String>> {
    let clean_id = flavour_id.trim_matches('_');
    let mut stmt = conn.prepare(
        "SELECT custom_root FROM flavours WHERE id = ?1 OR folder = ?1 OR id = ?2 OR folder = ?2",
    )?;
    let mut rows = stmt.query(params![flavour_id, clean_id])?;
    if let Some(row) = rows.next()? {
        let cr: Option<String> = row.get(0)?;
        Ok(cr)
    } else {
        Ok(None)
    }
}

pub fn get_addons_by_flavour(conn: &Connection, flavour: &str) -> Result<Vec<AddonDto>> {
    // 1. Single batch query for all folders in this flavour to prevent N+1 connection lock stalls
    let mut folder_stmt = conn.prepare(
        "SELECT addon_id, folder FROM addon_folders WHERE flavour = ?1 ORDER BY folder COLLATE NOCASE ASC",
    )?;
    let folder_rows = folder_stmt.query_map(params![flavour], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut folder_map: HashMap<String, Vec<String>> = HashMap::new();
    for fr in folder_rows {
        let (aid, folder) = fr?;
        folder_map.entry(aid).or_default().push(folder);
    }

    // 2. Fetch all addons for the flavour in alphabetical order
    let mut stmt = conn.prepare(
        "SELECT id, flavour, name, author, source, version, project_id, file_id, file_name, \
         installed_at, adopted, ignore_updates, pinned_file_id, release_type \
         FROM addons WHERE flavour = ?1 ORDER BY name COLLATE NOCASE ASC",
    )?;

    let rows = stmt.query_map(params![flavour], |row| {
        let addon_id: String = row.get(0)?;
        let flavour_id: String = row.get(1)?;
        let name: Option<String> = row.get(2)?;
        let author: Option<String> = row.get(3)?;
        let source: Option<String> = row.get(4)?;
        let version: Option<String> = row.get(5)?;
        let project_id: Option<i64> = row.get(6)?;
        let file_id: Option<String> = row.get(7)?;
        let file_name: Option<String> = row.get(8)?;
        let installed_at: Option<String> = row.get(9)?;
        let adopted: bool = row.get::<_, i32>(10)? != 0;
        let ignore_updates: bool = row.get::<_, i32>(11)? != 0;
        let pinned_file_id: Option<String> = row.get(12)?;
        let release_type: Option<i64> = row.get(13)?;

        Ok((
            addon_id, flavour_id, name, author, source, version,
            project_id, file_id, file_name, installed_at, adopted,
            ignore_updates, pinned_file_id, release_type,
        ))
    })?;

    let mut result = Vec::new();
    for r in rows {
        let (
            addon_id, flavour_id, name, author, source, version,
            project_id, file_id, file_name, installed_at, adopted,
            ignore_updates, pinned_file_id, release_type,
        ) = r?;

        let folders = folder_map.remove(&addon_id).unwrap_or_default();

        result.push(AddonDto {
            id: addon_id,
            flavour: flavour_id,
            name,
            author,
            source,
            version,
            project_id,
            file_id,
            file_name,
            folders,
            installed_at,
            adopted,
            ignore_updates,
            pinned_file_id,
            release_type,
        });
    }

    Ok(result)
}

pub fn get_settings_map(conn: &Connection) -> Result<HashMap<String, Value>> {
    let mut stmt = conn.prepare("SELECT key, value FROM settings")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;

    let mut map = HashMap::new();
    for r in rows {
        let (k, v) = r?;
        if let Ok(val) = serde_json::from_str::<Value>(&v) {
            map.insert(k, val);
        }
    }
    Ok(map)
}

pub fn get_wtf_snapshots_for_addon(conn: &Connection, addon_id: &str) -> Result<Vec<WtfSnapshotRecord>> {
    let mut stmt = conn.prepare(
        "SELECT id, addon_id, account, scope, path, size, created_at, kind, restored_at \
         FROM wtf_snapshots WHERE addon_id = ?1 ORDER BY created_at DESC",
    )?;
    let rows = stmt.query_map(params![addon_id], |r| {
        Ok(WtfSnapshotRecord {
            id: r.get(0)?,
            addon_id: r.get(1)?,
            account: r.get(2)?,
            scope: r.get(3)?,
            path: r.get(4)?,
            size: r.get(5)?,
            created_at: r.get(6)?,
            kind: r.get(7)?,
            restored_at: r.get(8)?,
        })
    })?;

    let mut result = Vec::new();
    for r in rows {
        result.push(r?);
    }
    Ok(result)
}

pub fn prune_stale_backups(
    conn: &Connection,
    addon_id: &str,
    kind: &str,
    keep_limit: usize,
) -> Result<usize> {
    let mut stmt = conn.prepare(
        "SELECT id, path FROM backups WHERE addon_id = ?1 AND kind = ?2 ORDER BY created_at DESC, rowid DESC",
    )?;
    let rows = stmt.query_map(params![addon_id, kind], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })?;

    let mut backups = Vec::new();
    for r in rows {
        backups.push(r?);
    }

    let mut pruned = 0;
    if backups.len() > keep_limit {
        for (old_id, old_path) in &backups[keep_limit..] {
            let _ = std::fs::remove_file(old_path);
            conn.execute("DELETE FROM backups WHERE id = ?1", params![old_id])?;
            pruned += 1;
        }
    }
    Ok(pruned)
}

pub fn prune_stale_wtf_snapshots(
    conn: &Connection,
    addon_id: &str,
    kind: Option<&str>,
    keep_limit: usize,
) -> Result<usize> {
    let mut snapshots = Vec::new();
    if let Some(k) = kind {
        let mut stmt = conn.prepare(
            "SELECT id, path FROM wtf_snapshots WHERE addon_id = ?1 AND kind = ?2 ORDER BY created_at DESC, rowid DESC",
        )?;
        let rows = stmt.query_map(params![addon_id, k], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?;
        for r in rows {
            snapshots.push(r?);
        }
    } else {
        let mut stmt = conn.prepare(
            "SELECT id, path FROM wtf_snapshots WHERE addon_id = ?1 ORDER BY created_at DESC, rowid DESC",
        )?;
        let rows = stmt.query_map(params![addon_id], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?;
        for r in rows {
            snapshots.push(r?);
        }
    };

    let mut pruned = 0;
    if snapshots.len() > keep_limit {
        for (old_id, old_path) in &snapshots[keep_limit..] {
            let _ = std::fs::remove_file(old_path);
            conn.execute("DELETE FROM wtf_snapshots WHERE id = ?1", params![old_id])?;
            pruned += 1;
        }
    }
    Ok(pruned)
}

pub fn delete_wtf_snapshot(conn: &Connection, snapshot_id: &str) -> Result<bool> {
    let path_opt: Option<String> = conn
        .query_row(
            "SELECT path FROM wtf_snapshots WHERE id = ?1",
            params![snapshot_id],
            |r| r.get(0),
        )
        .ok();

    if let Some(path) = path_opt {
        let _ = std::fs::remove_file(&path);
        conn.execute("DELETE FROM wtf_snapshots WHERE id = ?1", params![snapshot_id])?;
        Ok(true)
    } else {
        Ok(false)
    }
}

pub fn set_addon_auto_update(conn: &Connection, addon_id: &str, auto_update: bool) -> Result<()> {
    conn.execute(
        "UPDATE addons SET auto_update = ?1 WHERE id = ?2",
        params![if auto_update { 1 } else { 0 }, addon_id],
    )?;
    Ok(())
}

pub fn get_addon_auto_update(conn: &Connection, addon_id: &str) -> Result<bool> {
    conn.query_row(
        "SELECT auto_update FROM addons WHERE id = ?1",
        params![addon_id],
        |r| Ok(r.get::<_, i32>(0)? != 0),
    )
}

pub fn set_addon_ignored_until_build(conn: &Connection, addon_id: &str, build: Option<&str>) -> Result<()> {
    conn.execute(
        "UPDATE addons SET ignored_until_build = ?1 WHERE id = ?2",
        params![build, addon_id],
    )?;
    Ok(())
}

pub fn get_addon_ignored_until_build(conn: &Connection, addon_id: &str) -> Result<Option<String>> {
    conn.query_row(
        "SELECT ignored_until_build FROM addons WHERE id = ?1",
        params![addon_id],
        |r| r.get(0),
    )
}

pub fn set_addon_integrity_status(conn: &Connection, addon_id: &str, status: &str) -> Result<()> {
    conn.execute(
        "UPDATE addons SET integrity_status = ?1 WHERE id = ?2",
        params![status, addon_id],
    )?;
    Ok(())
}

pub fn get_addon_integrity_status(conn: &Connection, addon_id: &str) -> Result<Option<String>> {
    conn.query_row(
        "SELECT integrity_status FROM addons WHERE id = ?1",
        params![addon_id],
        |r| r.get(0),
    )
}

pub fn set_flavour_update_mode(conn: &Connection, flavour: &str, mode: &str) -> Result<()> {
    conn.execute(
        "UPDATE flavours SET update_mode = ?1 WHERE id = ?2",
        params![mode, flavour],
    )?;
    Ok(())
}

pub fn get_flavour_update_mode(conn: &Connection, flavour: &str) -> Result<String> {
    conn.query_row(
        "SELECT update_mode FROM flavours WHERE id = ?1",
        params![flavour],
        |r| r.get(0),
    )
}

pub fn get_flavour_update_modes(conn: &Connection) -> Result<HashMap<String, String>> {
    let mut stmt = conn.prepare("SELECT id, update_mode FROM flavours")?;
    let rows = stmt.query_map([], |row| {
        let id: String = row.get(0)?;
        let mode: String = row.get::<_, Option<String>>(1)?.unwrap_or_else(|| "auto".to_string());
        Ok((id, mode))
    })?;
    let mut map = HashMap::new();
    for r in rows {
        let (id, mode) = r?;
        map.insert(id, mode);
    }
    Ok(map)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use crate::db::schema::INITIAL_SCHEMA;

    fn setup_test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();
        conn
    }

    #[test]
    fn test_get_installed_flavours_and_custom_roots() {
        let conn = setup_test_db();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, product, installed, custom_root) \
             VALUES ('retail', '_retail_', 'Retail', 'wow', 1, NULL), \
                    ('forever', '_forever_', 'WoW Forever', 'wowf', 1, 'D:/Games/WoWForever')",
            [],
        ).unwrap();

        let flavours = get_installed_flavours_db(&conn).unwrap();
        assert_eq!(flavours.len(), 2);
        assert_eq!(flavours[0].id, "retail");
        assert!(flavours[0].custom_root.is_none());
        assert_eq!(flavours[1].id, "forever");
        assert_eq!(flavours[1].custom_root.as_deref(), Some("D:/Games/WoWForever"));

        // Test get_flavour_custom_root helper
        let cr_forever = get_flavour_custom_root(&conn, "forever").unwrap();
        assert_eq!(cr_forever.as_deref(), Some("D:/Games/WoWForever"));

        let cr_by_folder = get_flavour_custom_root(&conn, "_forever_").unwrap();
        assert_eq!(cr_by_folder.as_deref(), Some("D:/Games/WoWForever"));

        let cr_retail = get_flavour_custom_root(&conn, "retail").unwrap();
        assert!(cr_retail.is_none());

        // Update custom root
        set_flavour_custom_root(&conn, "retail", "C:/CustomRetail").unwrap();
        assert_eq!(get_flavour_custom_root(&conn, "retail").unwrap().as_deref(), Some("C:/CustomRetail"));

        // Reset custom root
        reset_flavour_custom_root(&conn, "retail").unwrap();
        assert!(get_flavour_custom_root(&conn, "retail").unwrap().is_none());
    }

    #[test]
    fn test_get_addons_by_flavour_batch_folders_no_n_plus_one() {
        let conn = setup_test_db();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name, adopted) VALUES \
             ('addon-details', 'retail', 'Details! Damage Meter', 0), \
             ('addon-dbm', 'retail', 'Deadly Boss Mods', 0)",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES \
             ('retail', 'Details', 'addon-details'), \
             ('retail', 'Details_DataStorage', 'addon-details'), \
             ('retail', 'DBM-Core', 'addon-dbm')",
            [],
        ).unwrap();

        let addons = get_addons_by_flavour(&conn, "retail").unwrap();
        assert_eq!(addons.len(), 2);

        // Ordered by name: Deadly Boss Mods first
        assert_eq!(addons[0].name.as_deref(), Some("Deadly Boss Mods"));
        assert_eq!(addons[0].folders, vec!["DBM-Core"]);

        assert_eq!(addons[1].name.as_deref(), Some("Details! Damage Meter"));
        assert_eq!(addons[1].folders, vec!["Details", "Details_DataStorage"]);
    }

    #[test]
    fn test_prune_stale_backups_and_snapshots() {
        let conn = setup_test_db();
        let temp = tempfile::tempdir().unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO addons (id, flavour, name) VALUES ('addon-1', 'retail', 'Addon1')",
            [],
        ).unwrap();

        // Create 4 backup files on disk and in DB
        for i in 1..=4 {
            let p = temp.path().join(format!("backup_{}.zip", i));
            std::fs::write(&p, b"backup_content").unwrap();
            conn.execute(
                "INSERT INTO backups (id, addon_id, kind, path, created_at) VALUES (?1, 'addon-1', 'rollback', ?2, ?3)",
                params![format!("bk-{}", i), p.to_string_lossy(), format!("2026-11-03T0{}:00:00Z", i)],
            ).unwrap();
        }

        // Prune to keep 3
        let pruned_backups = prune_stale_backups(&conn, "addon-1", "rollback", 3).unwrap();
        assert_eq!(pruned_backups, 1);
        let remaining_bks: i64 = conn.query_row("SELECT COUNT(*) FROM backups WHERE addon_id = 'addon-1'", [], |r| r.get(0)).unwrap();
        assert_eq!(remaining_bks, 3);
        // The oldest backup (bk-1) must be deleted from disk
        assert!(!temp.path().join("backup_1.zip").exists());
        assert!(temp.path().join("backup_4.zip").exists());

        // Create 4 WTF snapshots on disk and in DB
        for i in 1..=4 {
            let p = temp.path().join(format!("snapshot_{}.zip", i));
            std::fs::write(&p, b"snap_content").unwrap();
            conn.execute(
                "INSERT INTO wtf_snapshots (id, addon_id, path, created_at, kind) VALUES (?1, 'addon-1', ?2, ?3, 'pre-update')",
                params![format!("snap-{}", i), p.to_string_lossy(), format!("2026-11-03T0{}:00:00Z", i)],
            ).unwrap();
        }

        let pruned_snaps = prune_stale_wtf_snapshots(&conn, "addon-1", Some("pre-update"), 3).unwrap();
        assert_eq!(pruned_snaps, 1);
        let remaining_snaps: i64 = conn.query_row("SELECT COUNT(*) FROM wtf_snapshots WHERE addon_id = 'addon-1'", [], |r| r.get(0)).unwrap();
        assert_eq!(remaining_snaps, 3);
        assert!(!temp.path().join("snapshot_1.zip").exists());

        // Test delete_wtf_snapshot
        let deleted = delete_wtf_snapshot(&conn, "snap-4").unwrap();
        assert!(deleted);
        assert!(!temp.path().join("snapshot_4.zip").exists());
        let count_after: i64 = conn.query_row("SELECT COUNT(*) FROM wtf_snapshots WHERE id = 'snap-4'", [], |r| r.get(0)).unwrap();
        assert_eq!(count_after, 0);
    }
}
