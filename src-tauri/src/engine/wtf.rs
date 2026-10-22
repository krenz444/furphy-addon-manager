use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use chrono::Utc;
use rusqlite::{params, Connection, Result};
use uuid::Uuid;
use zip::write::{SimpleFileOptions, ZipWriter};
use crate::engine::archive::is_safe_entry_name;
use crate::logging::append_app_log;
use crate::system::game::is_wow_running;

pub const MAX_WTF_SNAPSHOT_BYTES: u64 = 50 * 1024 * 1024; // 50 MB size cap per snapshot

#[derive(Debug, Clone)]
pub struct WtfFileInfo {
    pub absolute_path: PathBuf,
    pub relative_to_wtf: String,
    pub account: String,
    pub scope: String, // "account" or "character"
}

pub fn collect_addon_wtf_files(
    wow_root: &Path,
    flavour_folder: &str,
    folders: &[String],
) -> Vec<WtfFileInfo> {
    let mut files = Vec::new();
    let wtf_root = wow_root.join(flavour_folder).join("WTF");
    let account_root = wtf_root.join("Account");

    if !account_root.is_dir() {
        return files;
    }

    let accounts = match fs::read_dir(&account_root) {
        Ok(entries) => entries,
        Err(_) => return files,
    };

    for acc_entry in accounts.flatten() {
        if !acc_entry.path().is_dir() {
            continue;
        }
        let account_name = acc_entry.file_name().to_string_lossy().to_string();
        if account_name.eq_ignore_ascii_case("SavedVariables") {
            continue;
        }

        let acc_saved_vars = acc_entry.path().join("SavedVariables");
        // 1. Account-level SavedVariables
        if acc_saved_vars.is_dir() {
            for folder in folders {
                for ext in &[".lua", ".lua.bak"] {
                    let file_name = format!("{}{}", folder, ext);
                    let target_file = acc_saved_vars.join(&file_name);
                    if target_file.is_file() {
                        let rel = format!("Account/{}/SavedVariables/{}", account_name, file_name);
                        files.push(WtfFileInfo {
                            absolute_path: target_file,
                            relative_to_wtf: rel,
                            account: account_name.clone(),
                            scope: "account".to_string(),
                        });
                    }
                }
            }
        }

        // 2. Character-level SavedVariables
        // Every directory under Account/<AccountName> except "SavedVariables" is a Realm
        if let Ok(realms) = fs::read_dir(acc_entry.path()) {
            for realm_entry in realms.flatten() {
                if !realm_entry.path().is_dir() {
                    continue;
                }
                let realm_name = realm_entry.file_name().to_string_lossy().to_string();
                if realm_name.eq_ignore_ascii_case("SavedVariables") {
                    continue;
                }

                // Every directory under Realm is a Character
                if let Ok(chars) = fs::read_dir(realm_entry.path()) {
                    for char_entry in chars.flatten() {
                        if !char_entry.path().is_dir() {
                            continue;
                        }
                        let char_name = char_entry.file_name().to_string_lossy().to_string();
                        let char_saved_vars = char_entry.path().join("SavedVariables");
                        if char_saved_vars.is_dir() {
                            for folder in folders {
                                for ext in &[".lua", ".lua.bak"] {
                                    let file_name = format!("{}{}", folder, ext);
                                    let target_file = char_saved_vars.join(&file_name);
                                    if target_file.is_file() {
                                        let rel = format!(
                                            "Account/{}/{}/{}/SavedVariables/{}",
                                            account_name, realm_name, char_name, file_name
                                        );
                                        files.push(WtfFileInfo {
                                            absolute_path: target_file,
                                            relative_to_wtf: rel,
                                            account: account_name.clone(),
                                            scope: "character".to_string(),
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    files
}

pub fn take_wtf_snapshot(
    conn: &Connection,
    wow_root: &Path,
    flavour_folder: &str,
    addon_id: &str,
    folders: &[String],
    data_dir: &Path,
    kind: &str,
) -> Result<Option<String>, String> {
    let files = collect_addon_wtf_files(wow_root, flavour_folder, folders);
    if files.is_empty() {
        return Ok(None);
    }

    // Check total uncompressed size
    let mut total_size: u64 = 0;
    for f in &files {
        if let Ok(meta) = fs::metadata(&f.absolute_path) {
            total_size += meta.len();
        }
    }

    if total_size > MAX_WTF_SNAPSHOT_BYTES {
        append_app_log(
            "WARN",
            &format!(
                "WTF snapshot for addon {} skipped: size {} exceeds 50 MB safety cap",
                addon_id, total_size
            ),
        );
        return Ok(None);
    }

    let snapshots_dir = data_dir.join("wtf_snapshots");
    let _ = fs::create_dir_all(&snapshots_dir);

    let snapshot_id = Uuid::new_v4().to_string();
    let zip_filename = format!("{}_{}_{}.zip", addon_id, Utc::now().format("%Y%m%d_%H%M%S"), &snapshot_id[..8]);
    let zip_path = snapshots_dir.join(&zip_filename);

    let zip_file = File::create(&zip_path).map_err(|e| e.to_string())?;
    let mut zip = ZipWriter::new(zip_file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    for f in &files {
        zip.start_file(&f.relative_to_wtf, options)
            .map_err(|e| e.to_string())?;
        let mut source_file = File::open(&f.absolute_path).map_err(|e| e.to_string())?;
        let mut buf = [0u8; 64 * 1024];
        loop {
            let n = source_file.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            zip.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        }
    }

    zip.finish().map_err(|e| e.to_string())?;
    let final_meta = fs::metadata(&zip_path).map_err(|e| e.to_string())?;
    let now = Utc::now().to_rfc3339();

    let account_summary = files.first().map(|f| f.account.clone()).unwrap_or_default();
    let scope_summary = if files.iter().any(|f| f.scope == "character") {
        "account+character"
    } else {
        "account"
    };

    conn.execute(
        "INSERT INTO wtf_snapshots (id, addon_id, account, scope, path, size, created_at, kind, restored_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL)",
        params![
            snapshot_id,
            addon_id,
            account_summary,
            scope_summary,
            zip_path.to_string_lossy().to_string(),
            final_meta.len() as i64,
            now,
            kind
        ],
    )
    .map_err(|e| e.to_string())?;

    // Retention: keep last 3 pre-update snapshots per addon
    if kind == "pre-update" {
        let mut stmt = conn
            .prepare(
                "SELECT id, path FROM wtf_snapshots WHERE addon_id = ?1 AND kind = 'pre-update' ORDER BY created_at DESC",
            )
            .map_err(|e| e.to_string())?;

        let rows = stmt
            .query_map(params![addon_id], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })
            .map_err(|e| e.to_string())?;

        let mut snapshots = Vec::new();
        for r in rows {
            snapshots.push(r.map_err(|e| e.to_string())?);
        }

        if snapshots.len() > 3 {
            for (old_id, old_path_str) in &snapshots[3..] {
                let _ = fs::remove_file(Path::new(old_path_str));
                let _ = conn.execute("DELETE FROM wtf_snapshots WHERE id = ?1", params![old_id]);
            }
        }
    }

    Ok(Some(snapshot_id))
}

pub fn restore_wtf_snapshot(
    conn: &Connection,
    wow_root: &Path,
    flavour_folder: &str,
    snapshot_id: &str,
    data_dir: &Path,
) -> Result<(), String> {
    // 1. Refusal check: NEVER restore while WoW runs! (ADR-314)
    if is_wow_running() {
        return Err("Cannot restore WTF SavedVariables while World of Warcraft is running.".to_string());
    }

    // 2. Fetch snapshot record
    let (addon_id, path_str): (String, String) = conn
        .query_row(
            "SELECT addon_id, path FROM wtf_snapshots WHERE id = ?1",
            params![snapshot_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(|e| format!("Snapshot {} not found: {}", snapshot_id, e))?;

    let snapshot_zip_path = PathBuf::from(&path_str);
    if !snapshot_zip_path.exists() {
        return Err(format!("Snapshot zip file not found on disk: {}", path_str));
    }

    let wtf_root = wow_root.join(flavour_folder).join("WTF");

    // 3. Inspect entries in the snapshot zip to verify safe relative paths
    let zip_file = File::open(&snapshot_zip_path).map_err(|e| e.to_string())?;
    let mut archive = zip::ZipArchive::new(zip_file).map_err(|e| e.to_string())?;

    for i in 0..archive.len() {
        let entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let name = entry.name();
        if !is_safe_entry_name(name) || !name.starts_with("Account/") {
            return Err(format!("Refusing unsafe entry path in snapshot: {}", name));
        }
    }

    // 4. Retrieve folders for this addon to take pre-restore snapshot
    let mut stmt = conn
        .prepare("SELECT folder FROM addon_folders WHERE addon_id = ?1")
        .map_err(|e| e.to_string())?;
    let frows = stmt
        .query_map(params![addon_id], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?;
    let folders: Vec<String> = frows.flatten().collect();

    // Take pre-restore snapshot of current files
    let _ = take_wtf_snapshot(
        conn,
        wow_root,
        flavour_folder,
        &addon_id,
        &folders,
        data_dir,
        "pre-restore",
    );

    // 5. Restore snapshot files: extract ONLY files in the snapshot
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let entry_name = entry.name().to_string();
        let target_path = wtf_root.join(PathBuf::from(&entry_name));

        if entry.is_dir() {
            let _ = fs::create_dir_all(&target_path);
        } else {
            if let Some(parent) = target_path.parent() {
                let _ = fs::create_dir_all(parent);
            }
            let mut out = File::create(&target_path).map_err(|e| e.to_string())?;
            let mut buf = [0u8; 64 * 1024];
            loop {
                let n = entry.read(&mut buf).map_err(|e| e.to_string())?;
                if n == 0 {
                    break;
                }
                out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
            }
        }
    }

    // 6. Update restored_at timestamp
    let now = Utc::now().to_rfc3339();
    let _ = conn.execute(
        "UPDATE wtf_snapshots SET restored_at = ?1 WHERE id = ?2",
        params![now, snapshot_id],
    );

    append_app_log(
        "INFO",
        &format!("Restored WTF SavedVariables snapshot {} for addon {}", snapshot_id, addon_id),
    );

    Ok(())
}

pub fn preview_wtf_restore(
    conn: &Connection,
    wow_root: &Path,
    flavour_folder: &str,
    snapshot_id: &str,
) -> Result<Vec<String>, String> {
    let (_, path_str): (String, String) = conn
        .query_row(
            "SELECT addon_id, path FROM wtf_snapshots WHERE id = ?1",
            params![snapshot_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(|e| format!("Snapshot {} not found: {}", snapshot_id, e))?;

    let snapshot_zip_path = PathBuf::from(&path_str);
    if !snapshot_zip_path.exists() {
        return Err(format!("Snapshot zip file not found on disk: {}", path_str));
    }

    let wtf_root = wow_root.join(flavour_folder).join("WTF");
    let zip_file = File::open(&snapshot_zip_path).map_err(|e| e.to_string())?;
    let mut archive = zip::ZipArchive::new(zip_file).map_err(|e| e.to_string())?;

    let mut preview_files = Vec::new();
    for i in 0..archive.len() {
        let entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let name = entry.name().to_string();
        if !entry.is_dir() {
            let full_dest = wtf_root.join(PathBuf::from(&name));
            let will_overwrite = full_dest.exists();
            preview_files.push(format!("{} (will overwrite: {})", name, will_overwrite));
        }
    }

    Ok(preview_files)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use crate::db::schema::INITIAL_SCHEMA;

    #[test]
    fn test_wtf_snapshot_and_restore_cycle() {
        let temp = tempfile::tempdir().unwrap();
        let wow_root = temp.path().join("WoW");
        let data_dir = temp.path().join("Data");
        let wtf_acc = wow_root.join("_retail_").join("WTF").join("Account").join("12345#1");
        let acc_sv = wtf_acc.join("SavedVariables");
        let char_sv = wtf_acc.join("Proudmoore").join("Dropsonde").join("SavedVariables");

        fs::create_dir_all(&acc_sv).unwrap();
        fs::create_dir_all(&char_sv).unwrap();
        fs::create_dir_all(&data_dir).unwrap();

        // Write sample SavedVariables
        fs::write(acc_sv.join("MyAddon.lua"), b"account_lua_v1").unwrap();
        fs::write(char_sv.join("MyAddon.lua"), b"char_lua_v1").unwrap();

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO addons (id, flavour, name, adopted) VALUES ('addon-1', 'retail', 'MyAddon', 0)",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'MyAddon', 'addon-1')",
            [],
        ).unwrap();

        // Take snapshot
        let snap_id = take_wtf_snapshot(
            &conn,
            &wow_root,
            "_retail_",
            "addon-1",
            &["MyAddon".to_string()],
            &data_dir,
            "pre-update",
        )
        .unwrap()
        .unwrap();

        // Modify SavedVariables to v2
        fs::write(acc_sv.join("MyAddon.lua"), b"account_lua_v2").unwrap();
        fs::write(char_sv.join("MyAddon.lua"), b"char_lua_v2").unwrap();

        // Refusal test: when fake game runs, restore is refused!
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");
        let refused_res = restore_wtf_snapshot(&conn, &wow_root, "_retail_", &snap_id, &data_dir);
        assert!(refused_res.is_err());
        assert_eq!(fs::read(acc_sv.join("MyAddon.lua")).unwrap(), b"account_lua_v2");

        // When game is closed: restore succeeds!
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "0");
        let restore_res = restore_wtf_snapshot(&conn, &wow_root, "_retail_", &snap_id, &data_dir);
        assert!(restore_res.is_ok());

        // Verified restored to v1
        assert_eq!(fs::read(acc_sv.join("MyAddon.lua")).unwrap(), b"account_lua_v1");
        assert_eq!(fs::read(char_sv.join("MyAddon.lua")).unwrap(), b"char_lua_v1");

        // Verify pre-restore snapshot was created
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM wtf_snapshots WHERE kind = 'pre-restore'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);

        std::env::remove_var("FURPHY_TEST_WOW_RUNNING");
    }
}
