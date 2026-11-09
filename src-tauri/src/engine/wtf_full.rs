use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use zip::write::{SimpleFileOptions, ZipWriter};
use zip::ZipArchive;

use crate::engine::archive::is_safe_entry_name;
use crate::logging::append_app_log;
use crate::system::game::is_wow_running_fresh;

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

fn walk_dir_files(dir: &Path, base: &Path, out: &mut Vec<(PathBuf, String)>) {
    let read_dir = match fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(e) => {
            append_app_log("WARN", &format!("Cannot read directory '{}': {}", dir.display(), e));
            return;
        }
    };
    for entry in read_dir {
        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                append_app_log("WARN", &format!("Cannot read directory entry: {}", e));
                continue;
            }
        };
        let path = entry.path();
        let file_type = match entry.file_type() {
            Ok(ft) => ft,
            Err(e) => {
                append_app_log("WARN", &format!("Cannot get file type for '{}': {}", path.display(), e));
                continue;
            }
        };
        if file_type.is_dir() {
            walk_dir_files(&path, base, out);
        } else if file_type.is_file() {
            if let Ok(rel) = path.strip_prefix(base) {
                let rel_str = rel.to_string_lossy().replace('\\', "/");
                if is_safe_entry_name(&rel_str) {
                    out.push((path, rel_str));
                }
            }
        }
    }
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let ft = entry.file_type()?;
        let from_path = entry.path();
        let to_path = dst.join(entry.file_name());
        if ft.is_dir() {
            copy_dir_recursive(&from_path, &to_path)?;
        } else if ft.is_file() {
            fs::copy(&from_path, &to_path)?;
        }
    }
    Ok(())
}

fn rollback_from_safety(safety_dir: &Path, wtf_root: &Path) -> std::io::Result<()> {
    if wtf_root.exists() {
        fs::remove_dir_all(wtf_root)?;
    }
    copy_dir_recursive(safety_dir, wtf_root)?;
    Ok(())
}

fn extract_archive_over_wtf<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    wtf_root: &Path,
) -> Result<(), String> {
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let entry_name = entry.name().replace('\\', "/");
        if !is_safe_entry_name(&entry_name) {
            return Err(format!("Zip-Slip detected: invalid entry path '{}'", entry_name));
        }

        let out_path = wtf_root.join(PathBuf::from(&entry_name));

        if !out_path.starts_with(wtf_root) {
            return Err(format!("Zip-Slip detected: path escapes WTF root '{}'", entry_name));
        }

        if entry.is_dir() {
            fs::create_dir_all(&out_path).map_err(|e| e.to_string())?;
        } else {
            if let Some(parent) = out_path.parent() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            let mut out_file = File::create(&out_path).map_err(|e| e.to_string())?;
            let mut buf = [0u8; 64 * 1024];
            loop {
                let n = entry.read(&mut buf).map_err(|e| e.to_string())?;
                if n == 0 {
                    break;
                }
                out_file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
            }
        }
    }
    Ok(())
}

fn prune_whole_wtf_backups(
    conn: &Connection,
    flavour: &str,
    retention: usize,
) -> Result<(), String> {
    let mut stmt = conn
        .prepare(
            "SELECT id, path FROM whole_wtf_backups WHERE flavour = ?1 ORDER BY created_at DESC, rowid DESC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map(params![flavour], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })
        .map_err(|e| e.to_string())?;

    let all_backups: Vec<(String, String)> = rows.filter_map(|r| r.ok()).collect();

    if all_backups.len() > retention {
        for (old_id, old_path) in &all_backups[retention..] {
            let _ = fs::remove_file(old_path);
            conn.execute(
                "DELETE FROM whole_wtf_backups WHERE id = ?1",
                params![old_id],
            )
            .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

pub fn backup_whole_wtf(
    conn: &Connection,
    wow_root: &Path,
    flavour_folder: &str,
    flavour: &str,
    data_dir: &Path,
    note: Option<&str>,
    retention: usize,
) -> Result<WholeWtfBackupRecord, String> {
    let wtf_root = crate::engine::wtf::resolve_wtf_root(Some(conn), wow_root, flavour_folder);
    if !wtf_root.exists() || !wtf_root.is_dir() {
        return Err(format!("WTF directory does not exist at '{}'", wtf_root.display()));
    }

    let backups_dir = data_dir.join("backups");
    fs::create_dir_all(&backups_dir)
        .map_err(|e| format!("Failed to create backups directory '{}': {}", backups_dir.display(), e))?;

    let id = Uuid::new_v4().to_string();
    let created_at = Utc::now().to_rfc3339();
    let zip_filename = format!("wtf_{}_{}.zip", flavour, id);
    let zip_path = backups_dir.join(&zip_filename);

    let zip_file = File::create(&zip_path)
        .map_err(|e| format!("Failed to create backup archive '{}': {}", zip_path.display(), e))?;

    let mut zip = ZipWriter::new(zip_file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    let mut files = Vec::new();
    walk_dir_files(&wtf_root, &wtf_root, &mut files);
    files.sort_by(|a, b| a.1.cmp(&b.1));

    let mut file_count: i64 = 0;
    let mut total_bytes: i64 = 0;

    for (abs_path, rel_str) in files {
        let mut source_file = match File::open(&abs_path) {
            Ok(f) => f,
            Err(e) => {
                append_app_log(
                    "WARN",
                    &format!("Skipping locked or unreadable file '{}': {}", abs_path.display(), e),
                );
                continue;
            }
        };

        if let Err(e) = zip.start_file(&rel_str, options) {
            append_app_log(
                "WARN",
                &format!("Failed to start zip entry '{}': {}", rel_str, e),
            );
            continue;
        }

        let mut buf = [0u8; 64 * 1024];
        let mut file_written = 0i64;
        let mut file_ok = true;
        loop {
            match source_file.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if let Err(e) = zip.write_all(&buf[..n]) {
                        append_app_log(
                            "ERROR",
                            &format!("Failed writing zip data for '{}': {}", rel_str, e),
                        );
                        file_ok = false;
                        break;
                    }
                    file_written += n as i64;
                }
                Err(e) => {
                    append_app_log(
                        "WARN",
                        &format!("Read error on '{}': {}", abs_path.display(), e),
                    );
                    file_ok = false;
                    break;
                }
            }
        }

        if file_ok {
            file_count += 1;
            total_bytes += file_written;
        }
    }

    zip.finish().map_err(|e| format!("Failed to finalize backup archive: {}", e))?;

    let path_str = zip_path.to_string_lossy().to_string();

    conn.execute(
        "INSERT INTO whole_wtf_backups (id, flavour, created_at, path, file_count, total_bytes, note) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            &id,
            flavour,
            &created_at,
            &path_str,
            file_count,
            total_bytes,
            note,
        ],
    ).map_err(|e| format!("Failed to record whole WTF backup: {}", e))?;

    let eff_retention = if retention == 0 {
        WTF_DEFAULT_RETENTION
    } else {
        retention
    };
    prune_whole_wtf_backups(conn, flavour, eff_retention)?;

    append_app_log(
        "INFO",
        &format!("Whole-WTF backup completed for flavour '{}': {} files, {} bytes (id: {})", flavour, file_count, total_bytes, id),
    );

    Ok(WholeWtfBackupRecord {
        id,
        flavour: flavour.to_string(),
        created_at,
        path: path_str,
        file_count,
        total_bytes,
        note: note.map(|s| s.to_string()),
    })
}

pub fn preview_restore_whole_wtf(
    conn: &Connection,
    wow_root: &Path,
    flavour_folder: &str,
    backup_id: &str,
) -> Result<WtfRestorePreview, String> {
    let (flavour, created_at, path, file_count, total_bytes): (String, String, String, i64, i64) = conn
        .query_row(
            "SELECT flavour, created_at, path, file_count, total_bytes FROM whole_wtf_backups WHERE id = ?1",
            params![backup_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .map_err(|e| format!("Backup '{}' not found: {}", backup_id, e))?;

    if !Path::new(&path).exists() {
        return Err(format!("Backup archive file does not exist: {}", path));
    }

    let wtf_root = crate::engine::wtf::resolve_wtf_root(Some(conn), wow_root, flavour_folder);
    let mut live_file_count: i64 = 0;
    let mut live_total_bytes: i64 = 0;

    if wtf_root.is_dir() {
        let mut live_files = Vec::new();
        walk_dir_files(&wtf_root, &wtf_root, &mut live_files);
        live_file_count = live_files.len() as i64;
        for (f_path, _) in live_files {
            if let Ok(meta) = fs::metadata(&f_path) {
                live_total_bytes += meta.len() as i64;
            }
        }
    }

    let mut warning = None;
    if is_wow_running_fresh() {
        warning = Some("Cannot restore WTF while World of Warcraft is running. Please exit the game and try again.".to_string());
    } else if (total_bytes as u64) > WTF_ARCHIVE_WARN_BYTES {
        warning = Some(format!(
            "WTF backup archive size is {} MB, exceeding the 500 MB warning threshold.",
            total_bytes / (1024 * 1024)
        ));
    }

    Ok(WtfRestorePreview {
        backup_id: backup_id.to_string(),
        flavour,
        created_at,
        file_count,
        total_bytes,
        live_file_count,
        live_total_bytes,
        warning,
    })
}

pub fn restore_whole_wtf(
    conn: &Connection,
    wow_root: &Path,
    flavour_folder: &str,
    flavour: &str,
    backup_id: &str,
    data_dir: &Path,
) -> Result<(), String> {
    if is_wow_running_fresh() {
        return Err("Cannot restore WTF while World of Warcraft is running. Please exit the game and try again.".to_string());
    }

    let (backup_flavour, zip_path_str): (String, String) = conn
        .query_row(
            "SELECT flavour, path FROM whole_wtf_backups WHERE id = ?1",
            params![backup_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(|e| format!("Backup '{}' not found: {}", backup_id, e))?;

    if backup_flavour != flavour {
        return Err(format!(
            "Backup flavour mismatch: backup belongs to '{}', attempting to restore to '{}'",
            backup_flavour, flavour
        ));
    }

    let zip_path = PathBuf::from(&zip_path_str);
    if !zip_path.exists() {
        return Err(format!("Backup archive file does not exist: {}", zip_path.display()));
    }

    let zip_file = File::open(&zip_path)
        .map_err(|e| format!("Failed to open backup archive: {}", e))?;
    let mut archive = ZipArchive::new(zip_file)
        .map_err(|e| format!("Failed to read backup archive: {}", e))?;

    // Pre-validate all archive entries for Zip-Slip traversal attacks
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|e| format!("Corrupt entry {}: {}", i, e))?;
        let entry_name = entry.name().to_string();
        if !is_safe_entry_name(&entry_name) {
            return Err(format!("Zip-Slip detected: invalid entry path '{}'", entry_name));
        }
        if let Some(mode) = entry.unix_mode() {
            if (mode & 0o170000) == 0o120000 {
                return Err(format!("Zip-Slip detected: symlink entry '{}'", entry_name));
            }
        }
    }

    let wtf_root = crate::engine::wtf::resolve_wtf_root(Some(conn), wow_root, flavour_folder);
    fs::create_dir_all(&wtf_root)
        .map_err(|e| format!("Failed to create WTF root directory '{}': {}", wtf_root.display(), e))?;

    // Pre-safety snapshot: copy live WTF to <data_dir>/backups/wtf_safety_<timestamp>/
    let timestamp = Utc::now().format("%Y%m%d_%H%M%S_%3f").to_string();
    let safety_dir = data_dir.join("backups").join(format!("wtf_safety_{}", timestamp));

    if wtf_root.exists() {
        copy_dir_recursive(&wtf_root, &safety_dir)
            .map_err(|e| format!("Failed to create safety snapshot at '{}': {}", safety_dir.display(), e))?;
    }

    // Extract archive entries over live WTF
    if let Err(extract_err) = extract_archive_over_wtf(&mut archive, &wtf_root) {
        append_app_log("ERROR", &format!("Extraction failed during WTF restore: {}. Rolling back...", extract_err));
        if safety_dir.exists() {
            if let Err(rb_err) = rollback_from_safety(&safety_dir, &wtf_root) {
                append_app_log("ERROR", &format!("Failed to rollback from safety snapshot: {}", rb_err));
                return Err(format!("Extraction error ('{}') and rollback failed ('{}')", extract_err, rb_err));
            }
        }
        return Err(format!("Restore failed and rolled back: {}", extract_err));
    }

    append_app_log(
        "INFO",
        &format!("Successfully restored whole WTF backup '{}' for flavour '{}'", backup_id, flavour),
    );

    Ok(())
}

pub fn list_whole_wtf_backups(conn: &Connection, flavour: &str) -> SqlResult<Vec<WholeWtfBackupRecord>> {
    let mut stmt = conn.prepare(
        "SELECT id, flavour, created_at, path, file_count, total_bytes, note \
         FROM whole_wtf_backups WHERE flavour = ?1 ORDER BY created_at DESC, rowid DESC",
    )?;
    let rows = stmt.query_map(params![flavour], |r| {
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

pub fn delete_whole_wtf_backup(conn: &Connection, backup_id: &str) -> Result<(), String> {
    let path: Option<String> = conn
        .query_row(
            "SELECT path FROM whole_wtf_backups WHERE id = ?1",
            params![backup_id],
            |r| r.get(0),
        )
        .ok();
    if let Some(p) = path {
        let _ = fs::remove_file(p);
    }
    conn.execute("DELETE FROM whole_wtf_backups WHERE id = ?1", params![backup_id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use crate::db::schema::INITIAL_SCHEMA;

    #[test]
    fn test_backup_whole_wtf_creates_valid_zip() {
        let temp = tempfile::tempdir().unwrap();
        let wow_root = temp.path().join("WoW");
        let data_dir = temp.path().join("Data");
        let wtf_root = wow_root.join("_retail_").join("WTF");
        fs::create_dir_all(&wtf_root).unwrap();

        let config_path = wtf_root.join("Config.wtf");
        let sv_path = wtf_root.join("Account").join("12345#1").join("SavedVariables").join("Details.lua");
        let bind_path = wtf_root.join("Account").join("12345#1").join("bindings-cache.wtf");

        fs::create_dir_all(sv_path.parent().unwrap()).unwrap();
        fs::write(&config_path, b"SET portal \"US\"\n").unwrap();
        fs::write(&sv_path, b"DetailsDB = {}\n").unwrap();
        fs::write(&bind_path, b"bind 1 ACTIONBUTTON1\n").unwrap();

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        let record = backup_whole_wtf(
            &conn,
            &wow_root,
            "_retail_",
            "retail",
            &data_dir,
            Some("Initial manual backup"),
            5,
        ).unwrap();

        assert_eq!(record.flavour, "retail");
        assert_eq!(record.file_count, 3);
        assert!(record.total_bytes > 0);
        assert_eq!(record.note, Some("Initial manual backup".to_string()));

        // Verify DB row
        let db_row: (String, i64, i64, Option<String>) = conn.query_row(
            "SELECT flavour, file_count, total_bytes, note FROM whole_wtf_backups WHERE id = ?1",
            params![record.id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        ).unwrap();
        assert_eq!(db_row.0, "retail");
        assert_eq!(db_row.1, 3);
        assert_eq!(db_row.2, record.total_bytes);
        assert_eq!(db_row.3, Some("Initial manual backup".to_string()));

        // Verify zip contents directly
        let zip_file = File::open(&record.path).unwrap();
        let mut archive = ZipArchive::new(zip_file).unwrap();
        assert_eq!(archive.len(), 3);

        let mut names: Vec<String> = (0..archive.len())
            .map(|i| archive.by_index(i).unwrap().name().replace('\\', "/"))
            .collect();
        names.sort();
        assert_eq!(names, vec![
            "Account/12345#1/SavedVariables/Details.lua".to_string(),
            "Account/12345#1/bindings-cache.wtf".to_string(),
            "Config.wtf".to_string(),
        ]);

        let mut config_entry = archive.by_name("Config.wtf").unwrap();
        let mut content = Vec::new();
        config_entry.read_to_end(&mut content).unwrap();
        assert_eq!(content, b"SET portal \"US\"\n");
    }

    #[test]
    fn test_restore_refused_while_wow_running() {
        let temp = tempfile::tempdir().unwrap();
        let wow_root = temp.path().join("WoW");
        let data_dir = temp.path().join("Data");
        let wtf_root = wow_root.join("_retail_").join("WTF");
        fs::create_dir_all(&wtf_root).unwrap();
        fs::write(wtf_root.join("Config.wtf"), b"SET portal \"US\"\n").unwrap();

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        let record = backup_whole_wtf(&conn, &wow_root, "_retail_", "retail", &data_dir, None, 5).unwrap();

        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");
        let res = restore_whole_wtf(&conn, &wow_root, "_retail_", "retail", &record.id, &data_dir);
        std::env::remove_var("FURPHY_TEST_WOW_RUNNING");

        assert!(res.is_err());
        let err = res.unwrap_err();
        assert_eq!(err, "Cannot restore WTF while World of Warcraft is running. Please exit the game and try again.");
    }

    #[test]
    fn test_restore_overwrites_archived_files_only() {
        let temp = tempfile::tempdir().unwrap();
        let wow_root = temp.path().join("WoW");
        let data_dir = temp.path().join("Data");
        let wtf_root = wow_root.join("_retail_").join("WTF");
        fs::create_dir_all(&wtf_root).unwrap();

        let config_path = wtf_root.join("Config.wtf");
        let addon_path = wtf_root.join("Account").join("12345#1").join("SavedVariables").join("Addon1.lua");
        fs::create_dir_all(addon_path.parent().unwrap()).unwrap();
        fs::write(&config_path, b"SET portal \"US\"\n").unwrap();
        fs::write(&addon_path, b"Addon1DB = { v = 1 }\n").unwrap();

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        let record = backup_whole_wtf(&conn, &wow_root, "_retail_", "retail", &data_dir, None, 5).unwrap();

        // Overwrite archived files with v2 in live WTF
        fs::write(&config_path, b"SET portal \"EU\"\n").unwrap();
        fs::write(&addon_path, b"Addon1DB = { v = 2 }\n").unwrap();

        // Create unarchived files in live WTF that must NOT be touched
        let unarchived_sv = wtf_root.join("Account").join("12345#1").join("SavedVariables").join("Unarchived.lua");
        fs::write(&unarchived_sv, b"UnarchivedDB = { keep = true }\n").unwrap();

        let unarchived_root = wtf_root.join("SavedVariables").join("Extra.lua");
        fs::create_dir_all(unarchived_root.parent().unwrap()).unwrap();
        fs::write(&unarchived_root, b"Extra = {}\n").unwrap();

        restore_whole_wtf(&conn, &wow_root, "_retail_", "retail", &record.id, &data_dir).unwrap();

        // Archived files should be restored to v1
        assert_eq!(fs::read(&config_path).unwrap(), b"SET portal \"US\"\n");
        assert_eq!(fs::read(&addon_path).unwrap(), b"Addon1DB = { v = 1 }\n");

        // Unarchived files must remain intact
        assert!(unarchived_sv.exists());
        assert_eq!(fs::read(&unarchived_sv).unwrap(), b"UnarchivedDB = { keep = true }\n");
        assert!(unarchived_root.exists());
        assert_eq!(fs::read(&unarchived_root).unwrap(), b"Extra = {}\n");
    }

    #[test]
    fn test_restore_traversal_path_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let wow_root = temp.path().join("WoW");
        let data_dir = temp.path().join("Data");
        let wtf_root = wow_root.join("_retail_").join("WTF");
        fs::create_dir_all(&wtf_root).unwrap();

        let bad_zip_path = data_dir.join("backups").join("bad_slip.zip");
        fs::create_dir_all(bad_zip_path.parent().unwrap()).unwrap();
        let bad_file = File::create(&bad_zip_path).unwrap();
        let mut zip = ZipWriter::new(bad_file);
        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        zip.start_file("../sneaky.txt", options).unwrap();
        zip.write_all(b"malicious").unwrap();
        zip.finish().unwrap();

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        let bad_path_str = bad_zip_path.to_str().unwrap();
        conn.execute(
            "INSERT INTO whole_wtf_backups (id, flavour, created_at, path, file_count, total_bytes, note) \
             VALUES ('bad-backup', 'retail', '2026-11-08T00:00:00Z', ?1, 1, 9, 'evil')",
            params![bad_path_str],
        ).unwrap();

        let res = restore_whole_wtf(&conn, &wow_root, "_retail_", "retail", "bad-backup", &data_dir);
        assert!(res.is_err());
        let err = res.unwrap_err();
        assert!(err.contains("Zip-Slip"), "Error should mention Zip-Slip: {}", err);
        assert!(!wow_root.join("sneaky.txt").exists(), "Traversed file must not be written");
    }

    #[test]
    fn test_retention_prunes_old_backups() {
        let temp = tempfile::tempdir().unwrap();
        let wow_root = temp.path().join("WoW");
        let data_dir = temp.path().join("Data");
        let wtf_root = wow_root.join("_retail_").join("WTF");
        fs::create_dir_all(&wtf_root).unwrap();
        fs::write(wtf_root.join("Config.wtf"), b"SET portal \"US\"\n").unwrap();

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        let mut paths = Vec::new();
        for i in 1..=7 {
            let record = backup_whole_wtf(
                &conn,
                &wow_root,
                "_retail_",
                "retail",
                &data_dir,
                Some(&format!("Backup {}", i)),
                5,
            ).unwrap();
            paths.push(record.path);
            std::thread::sleep(std::time::Duration::from_millis(15));
        }

        let remaining = list_whole_wtf_backups(&conn, "retail").unwrap();
        assert_eq!(remaining.len(), 5, "Database should retain exactly 5 backups");

        // The 2 oldest backups should have their zip files deleted
        assert!(!Path::new(&paths[0]).exists(), "Oldest backup (0) zip should be deleted");
        assert!(!Path::new(&paths[1]).exists(), "Second oldest backup (1) zip should be deleted");

        // The 5 newest backups should have their zip files present
        for (idx, p) in paths[2..].iter().enumerate() {
            assert!(Path::new(p).exists(), "Backup index {} ({}) should exist", idx + 2, p);
        }
    }
}
