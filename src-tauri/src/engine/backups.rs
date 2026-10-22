use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use chrono::Utc;
use rusqlite::{params, Connection, Result};
use uuid::Uuid;
use zip::write::{SimpleFileOptions, ZipWriter};
use crate::logging::append_app_log;

fn add_dir_to_zip<W: Write + std::io::Seek>(
    zip: &mut ZipWriter<W>,
    base_dir: &Path,
    current_dir: &Path,
    prefix_folder: &str,
    options: SimpleFileOptions,
) -> std::io::Result<()> {
    for entry in fs::read_dir(current_dir)? {
        let entry = entry?;
        let path = entry.path();
        let rel_path = path.strip_prefix(base_dir).unwrap();
        let entry_name = format!("{}/{}", prefix_folder, rel_path.to_string_lossy().replace('\\', "/"));

        if path.is_dir() {
            zip.add_directory(&entry_name, options)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
            add_dir_to_zip(zip, base_dir, &path, prefix_folder, options)?;
        } else {
            zip.start_file(&entry_name, options)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
            let mut f = File::open(&path)?;
            let mut buf = [0u8; 64 * 1024];
            loop {
                let n = f.read(&mut buf)?;
                if n == 0 {
                    break;
                }
                zip.write_all(&buf[..n])?;
            }
        }
    }
    Ok(())
}

pub fn create_backup_zip(
    addons_path: &Path,
    folders: &[String],
    dest_zip_path: &Path,
) -> std::io::Result<u64> {
    if let Some(parent) = dest_zip_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let file = File::create(dest_zip_path)?;
    let mut zip = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    for folder_name in folders {
        let folder_dir = addons_path.join(folder_name);
        if folder_dir.is_dir() {
            zip.add_directory(folder_name, options)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
            add_dir_to_zip(&mut zip, &folder_dir, &folder_dir, folder_name, options)?;
        }
    }

    zip.finish()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;

    let meta = fs::metadata(dest_zip_path)?;
    Ok(meta.len())
}

pub fn record_and_prune_backup(
    conn: &Connection,
    addon_id: &str,
    _flavour: &str,
    kind: &str,
    file_id: Option<&str>,
    version: Option<&str>,
    path: &Path,
    size: u64,
) -> Result<String> {
    let backup_id = Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    conn.execute(
        "INSERT INTO backups (id, addon_id, kind, file_id, version, path, size, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            backup_id,
            addon_id,
            kind,
            file_id,
            version,
            path.to_string_lossy().to_string(),
            size as i64,
            now
        ],
    )?;

    // Retention: keep last 2 backups per addon for this kind
    let mut stmt = conn.prepare(
        "SELECT id, path FROM backups WHERE addon_id = ?1 AND kind = ?2 ORDER BY created_at DESC",
    )?;
    let rows = stmt.query_map(params![addon_id, kind], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })?;

    let mut all_backups: Vec<(String, String)> = Vec::new();
    for r in rows {
        all_backups.push(r?);
    }

    if all_backups.len() > 2 {
        for (old_id, old_path_str) in &all_backups[2..] {
            let old_path = PathBuf::from(old_path_str);
            let _ = fs::remove_file(&old_path);
            let _ = conn.execute("DELETE FROM backups WHERE id = ?1", params![old_id]);
            append_app_log("INFO", &format!("Pruned old backup '{}' ({})", old_path_str, old_id));
        }
    }

    Ok(backup_id)
}

pub fn cleanup_orphaned_backups(conn: &Connection, retention_days: i64) -> Result<usize> {
    let cutoff = Utc::now() - chrono::Duration::days(retention_days);
    let cutoff_str = cutoff.to_rfc3339();

    let mut stmt = conn.prepare(
        "SELECT b.id, b.path FROM backups b \
         LEFT JOIN addons a ON b.addon_id = a.id \
         WHERE a.id IS NULL AND b.created_at < ?1",
    )?;

    let rows = stmt.query_map(params![cutoff_str], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })?;

    let mut to_delete = Vec::new();
    for r in rows {
        to_delete.push(r?);
    }

    let count = to_delete.len();
    for (id, path_str) in to_delete {
        let p = PathBuf::from(&path_str);
        let _ = fs::remove_file(&p);
        let _ = conn.execute("DELETE FROM backups WHERE id = ?1", params![id]);
        append_app_log(
            "INFO",
            &format!("Cleaned up orphaned backup '{}' (> {} days)", path_str, retention_days),
        );
    }

    Ok(count)
}
