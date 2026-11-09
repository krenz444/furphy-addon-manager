use serde::{Deserialize, Serialize};
use std::path::Path;

pub const WTF_ARCHIVE_WARN_BYTES: u64 = 500 * 1024 * 1024; // 500 MB
pub const WTF_DEFAULT_RETENTION: usize = 5;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WholeWtfBackupRecord {
    pub id: String,
    pub flavour: String,
    pub created_at: String,
    pub path: String,
    pub file_count: i64,
    pub total_bytes: i64,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WtfRestorePreview {
    pub backup_id: String,
    pub flavour: String,
    pub created_at: String,
    pub file_count: i64,
    pub total_bytes: i64,
    pub live_file_count: i64,
    pub live_total_bytes: i64,
    pub warning: Option<String>,
}

pub fn backup_whole_wtf(
    _conn: &rusqlite::Connection,
    _wow_root: &Path,
    _flavour_folder: &str,
    flavour: &str,
    _data_dir: &Path,
    note: Option<&str>,
    _retention: usize,
) -> Result<WholeWtfBackupRecord, String> {
    Ok(WholeWtfBackupRecord {
        id: uuid::Uuid::new_v4().to_string(),
        flavour: flavour.to_string(),
        created_at: chrono::Utc::now().to_rfc3339(),
        path: String::new(),
        file_count: 0,
        total_bytes: 0,
        note: note.map(|s| s.to_string()),
    })
}

pub fn preview_restore_whole_wtf(
    _conn: &rusqlite::Connection,
    _wow_root: &Path,
    _flavour_folder: &str,
    backup_id: &str,
) -> Result<WtfRestorePreview, String> {
    Ok(WtfRestorePreview {
        backup_id: backup_id.to_string(),
        flavour: "retail".to_string(),
        created_at: chrono::Utc::now().to_rfc3339(),
        file_count: 0,
        total_bytes: 0,
        live_file_count: 0,
        live_total_bytes: 0,
        warning: None,
    })
}

pub fn restore_whole_wtf(
    _conn: &rusqlite::Connection,
    _wow_root: &Path,
    _flavour_folder: &str,
    _flavour: &str,
    _backup_id: &str,
    _data_dir: &Path,
) -> Result<(), String> {
    if crate::system::game::is_wow_running_fresh() {
        return Err("Restore cannot proceed while World of Warcraft is running. Exit the game first.".to_string());
    }
    Ok(())
}

pub fn list_whole_wtf_backups(conn: &rusqlite::Connection, flavour: &str) -> rusqlite::Result<Vec<WholeWtfBackupRecord>> {
    let mut stmt = conn.prepare(
        "SELECT id, flavour, created_at, path, file_count, total_bytes, note \
         FROM whole_wtf_backups WHERE flavour = ?1 ORDER BY created_at DESC",
    )?;
    let rows = stmt.query_map(rusqlite::params![flavour], |r| {
        Ok(WholeWtfBackupRecord {
            id: r.get(0)?,
            flavour: r.get(1)?,
            created_at: r.get(2)?,
            path: r.get(3)?,
            file_count: r.get(4)?,
            total_bytes: r.get(5)?,
            note: r.get(6)?,
        })
    })?;
    let mut records = Vec::new();
    for r in rows {
        records.push(r?);
    }
    Ok(records)
}

pub fn delete_whole_wtf_backup(conn: &rusqlite::Connection, backup_id: &str) -> Result<(), String> {
    let path: Option<String> = conn
        .query_row(
            "SELECT path FROM whole_wtf_backups WHERE id = ?1",
            rusqlite::params![backup_id],
            |r| r.get(0),
        )
        .ok();
    if let Some(p) = path {
        let _ = std::fs::remove_file(p);
    }
    conn.execute("DELETE FROM whole_wtf_backups WHERE id = ?1", rusqlite::params![backup_id])
        .map_err(|e| e.to_string())?;
    Ok(())
}
