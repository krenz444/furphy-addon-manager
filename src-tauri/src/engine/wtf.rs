use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use chrono::Utc;
use rusqlite::{params, Connection, Result};
use uuid::Uuid;
use zip::write::{SimpleFileOptions, ZipWriter};
use crate::engine::archive::is_safe_entry_name;
use crate::logging::append_app_log;
use crate::system::game::is_wow_running_fresh;

pub const MAX_WTF_SNAPSHOT_BYTES: u64 = 50 * 1024 * 1024; // 50 MB size cap per snapshot

#[derive(Debug, Clone)]
pub struct WtfFileInfo {
    pub absolute_path: PathBuf,
    pub relative_to_wtf: String,
    pub account: String,
    pub scope: String, // "account" or "character"
}

pub fn resolve_wtf_root(
    conn: Option<&Connection>,
    wow_root: &Path,
    flavour_folder: &str,
) -> PathBuf {
    // 1. If DB connection is supplied, query flavours.custom_root (ADR-318)
    if let Some(c) = conn {
        if let Ok(Some(cr_str)) = crate::db::repo::get_flavour_custom_root(c, flavour_folder) {
            let cr = PathBuf::from(cr_str);
            let root_dir = if cr
                .file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.eq_ignore_ascii_case("AddOns"))
                .unwrap_or(false)
            {
                cr.parent().and_then(|p| p.parent()).unwrap_or(&cr).to_path_buf()
            } else {
                cr
            };

            if root_dir.join("WTF").is_dir() {
                return root_dir.join("WTF");
            }
            if root_dir.join("Interface").is_dir() {
                return root_dir.join("WTF");
            }
            if root_dir.join(flavour_folder).join("WTF").is_dir() {
                return root_dir.join(flavour_folder).join("WTF");
            }
            let clean_flv = flavour_folder.trim_matches('_');
            if root_dir.join(format!("_{}_", clean_flv)).join("WTF").is_dir() {
                return root_dir.join(format!("_{}_", clean_flv)).join("WTF");
            }
            return root_dir.join("WTF");
        }
    }

    // 2. Direct path inspection on wow_root
    if wow_root.join("WTF").is_dir() {
        return wow_root.join("WTF");
    }
    if wow_root.join("Interface").is_dir() {
        return wow_root.join("WTF");
    }

    let folder_name = wow_root.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let clean_flv = flavour_folder.trim_matches('_');
    if folder_name.eq_ignore_ascii_case(flavour_folder)
        || folder_name.eq_ignore_ascii_case(clean_flv)
        || folder_name.eq_ignore_ascii_case(&format!("_{}_", clean_flv))
    {
        return wow_root.join("WTF");
    }

    let sub = wow_root.join(flavour_folder);
    if sub.join("WTF").is_dir() || sub.is_dir() {
        return sub.join("WTF");
    }

    let clean_sub = wow_root.join(format!("_{}_", clean_flv));
    if clean_sub.join("WTF").is_dir() || clean_sub.is_dir() {
        return clean_sub.join("WTF");
    }

    wow_root.join(flavour_folder).join("WTF")
}

pub fn collect_addon_wtf_files_at_root(
    wtf_root: &Path,
    folders: &[String],
) -> Vec<WtfFileInfo> {
    let mut files = Vec::new();
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

pub fn collect_addon_wtf_files(
    wow_root: &Path,
    flavour_folder: &str,
    folders: &[String],
) -> Vec<WtfFileInfo> {
    let wtf_root = resolve_wtf_root(None, wow_root, flavour_folder);
    collect_addon_wtf_files_at_root(&wtf_root, folders)
}

pub fn collect_addon_wtf_files_with_conn(
    conn: Option<&Connection>,
    wow_root: &Path,
    flavour_folder: &str,
    folders: &[String],
) -> Vec<WtfFileInfo> {
    let wtf_root = resolve_wtf_root(conn, wow_root, flavour_folder);
    collect_addon_wtf_files_at_root(&wtf_root, folders)
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
    let files = collect_addon_wtf_files_with_conn(Some(conn), wow_root, flavour_folder, folders);
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
    let safe_addon_id = addon_id.replace([':', '/', '\\', '*', '?', '"', '<', '>', '|'], "_");
    let zip_filename = format!("{}_{}_{}.zip", safe_addon_id, Utc::now().format("%Y%m%d_%H%M%S"), &snapshot_id[..8]);
    let zip_path = snapshots_dir.join(&zip_filename);

    let zip_file = File::create(&zip_path).map_err(|e| e.to_string())?;
    let mut zip = ZipWriter::new(zip_file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    let mut write_err = None;
    for f in &files {
        if let Err(e) = zip.start_file(&f.relative_to_wtf, options) {
            write_err = Some(e.to_string());
            break;
        }
        match File::open(&f.absolute_path) {
            Ok(mut source_file) => {
                let mut buf = [0u8; 64 * 1024];
                loop {
                    match source_file.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            if let Err(e) = zip.write_all(&buf[..n]) {
                                write_err = Some(e.to_string());
                                break;
                            }
                        }
                        Err(e) => {
                            write_err = Some(e.to_string());
                            break;
                        }
                    }
                }
            }
            Err(e) => {
                write_err = Some(e.to_string());
                break;
            }
        }
        if write_err.is_some() {
            break;
        }
    }

    if let Some(err) = write_err {
        drop(zip);
        let _ = fs::remove_file(&zip_path);
        return Err(format!("Aborted WTF snapshot due to I/O error: {}", err));
    }

    if let Err(e) = zip.finish() {
        let _ = fs::remove_file(&zip_path);
        return Err(e.to_string());
    }

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

    // Safe retention pruning: keep last 3 snapshots per addon/kind (ADR-314)
    let _ = crate::db::repo::prune_stale_wtf_snapshots(conn, addon_id, Some(kind), 3);

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
    if is_wow_running_fresh() {
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

    // Resolve WTF root accounting for custom root configurations (ADR-318)
    let wtf_root = resolve_wtf_root(Some(conn), wow_root, flavour_folder);

    // 3. Inspect entries in the snapshot zip to verify safe relative paths
    let zip_file = File::open(&snapshot_zip_path).map_err(|e| e.to_string())?;
    let mut archive = zip::ZipArchive::new(zip_file).map_err(|e| e.to_string())?;

    for i in 0..archive.len() {
        let entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let name = entry.name().replace('\\', "/");
        if !is_safe_entry_name(&name) || !name.starts_with("Account/") {
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
        let entry_name = entry.name().replace('\\', "/");
        let target_path = wtf_root.join(PathBuf::from(&entry_name));

        if !target_path.starts_with(&wtf_root) {
            return Err(format!("Restore path resolves outside WTF folder: {}", target_path.display()));
        }

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

    let wtf_root = resolve_wtf_root(Some(conn), wow_root, flavour_folder);
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

pub fn cleanup_orphaned_wtf_snapshots(conn: &Connection, data_dir: &Path) -> Result<usize, String> {
    let snapshots_dir = data_dir.join("wtf_snapshots");
    if !snapshots_dir.is_dir() {
        return Ok(0);
    }

    let mut stmt = conn
        .prepare("SELECT path FROM wtf_snapshots")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?;

    let mut known_paths = std::collections::HashSet::new();
    for r in rows {
        if let Ok(p) = r {
            known_paths.insert(PathBuf::from(p));
        }
    }

    let mut removed = 0;
    if let Ok(entries) = fs::read_dir(&snapshots_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() && path.extension().and_then(|s| s.to_str()) == Some("zip") {
                if !known_paths.contains(&path) {
                    let _ = fs::remove_file(&path);
                    removed += 1;
                }
            }
        }
    }
    Ok(removed)
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

        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // Refusal test: when fake game runs, restore is refused!
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");
        let refused_res = restore_wtf_snapshot(&conn, &wow_root, "_retail_", &snap_id, &data_dir);
        assert!(refused_res.is_err());
        assert_eq!(fs::read(acc_sv.join("MyAddon.lua")).unwrap(), b"account_lua_v2");

        // When game is closed: restore succeeds!
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "0");
        let restore_res = restore_wtf_snapshot(&conn, &wow_root, "_retail_", &snap_id, &data_dir);
        assert!(restore_res.is_ok());
        std::env::remove_var("FURPHY_TEST_WOW_RUNNING");

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

    #[test]
    fn test_wtf_snapshot_with_colon_and_slash_addon_id() {
        let temp = tempfile::tempdir().unwrap();
        let wow_root = temp.path().join("World of Warcraft");
        let acc_sv = wow_root.join("_retail_").join("WTF").join("Account").join("12345#1").join("SavedVariables");
        fs::create_dir_all(&acc_sv).unwrap();
        fs::write(acc_sv.join("MyAddon.lua"), b"account_lua_v1").unwrap();

        let data_dir = temp.path().join("furphy_data");
        fs::create_dir_all(&data_dir).unwrap();

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        let complex_id = "retail:gh:bart-dev-wow/TimelineReminders";
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO addons (id, flavour, name, adopted) VALUES (?1, 'retail', 'TimelineReminders', 0)",
            rusqlite::params![complex_id],
        ).unwrap();
        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'MyAddon', ?1)",
            rusqlite::params![complex_id],
        ).unwrap();

        // Taking snapshot must not fail with os error 123
        let snap_id = take_wtf_snapshot(
            &conn,
            &wow_root,
            "_retail_",
            complex_id,
            &["MyAddon".to_string()],
            &data_dir,
            "pre-update",
        )
        .unwrap()
        .expect("Snapshot should be created");

        let saved_path: String = conn.query_row(
            "SELECT path FROM wtf_snapshots WHERE id = ?1",
            rusqlite::params![snap_id],
            |r| r.get(0),
        ).unwrap();

        assert!(!saved_path.contains(':') || (cfg!(windows) && saved_path.chars().filter(|c| *c == ':').count() <= 1), "No extra colons in path: {}", saved_path);
        assert!(std::path::Path::new(&saved_path).exists(), "Snapshot zip must exist on disk!");
    }

    #[test]
    fn test_wtf_snapshot_and_restore_with_custom_root() {
        let temp = tempfile::tempdir().unwrap();
        // Custom root decoupled from any standard wow_root directory (ADR-318)
        let custom_forever_root = temp.path().join("StandaloneWoWForever");
        let fake_global_wow_root = temp.path().join("GlobalWoW");
        let data_dir = temp.path().join("Data");

        let wtf_acc = custom_forever_root.join("WTF").join("Account").join("99999#1");
        let acc_sv = wtf_acc.join("SavedVariables");
        let char_sv = wtf_acc.join("EmeraldDream").join("Krenz").join("SavedVariables");

        fs::create_dir_all(&acc_sv).unwrap();
        fs::create_dir_all(&char_sv).unwrap();
        fs::create_dir_all(&data_dir).unwrap();
        fs::create_dir_all(&fake_global_wow_root).unwrap();

        fs::write(acc_sv.join("ShaguPlates.lua"), b"shagu_acc_v1").unwrap();
        fs::write(char_sv.join("ShaguPlates.lua"), b"shagu_char_v1").unwrap();

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        // Flavour configured with custom_root
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed, custom_root) \
             VALUES ('forever', '_forever_', 'WoW Forever', 1, ?1)",
            rusqlite::params![custom_forever_root.to_string_lossy()],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name, adopted) VALUES ('forever:shagu', 'forever', 'ShaguPlates', 0)",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('forever', 'ShaguPlates', 'forever:shagu')",
            [],
        ).unwrap();

        // 1. Take snapshot: even when caller passes fake_global_wow_root, custom_root is resolved from DB
        let snap_id = take_wtf_snapshot(
            &conn,
            &fake_global_wow_root,
            "_forever_",
            "forever:shagu",
            &["ShaguPlates".to_string()],
            &data_dir,
            "pre-update",
        )
        .unwrap()
        .expect("Snapshot should be created from custom root");

        // 2. Modify files to v2
        fs::write(acc_sv.join("ShaguPlates.lua"), b"shagu_acc_v2").unwrap();
        fs::write(char_sv.join("ShaguPlates.lua"), b"shagu_char_v2").unwrap();

        // 3. Preview restore
        let previews = preview_wtf_restore(&conn, &fake_global_wow_root, "_forever_", &snap_id).unwrap();
        assert_eq!(previews.len(), 2);
        assert!(previews.iter().any(|p| p.contains("will overwrite: true")));

        // 4. Restore snapshot
        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "0");
        let res = restore_wtf_snapshot(&conn, &fake_global_wow_root, "_forever_", &snap_id, &data_dir);
        assert!(res.is_ok(), "Restore should succeed: {:?}", res.err());
        std::env::remove_var("FURPHY_TEST_WOW_RUNNING");

        // 5. Verify restored to v1 in the custom root directory
        assert_eq!(fs::read(acc_sv.join("ShaguPlates.lua")).unwrap(), b"shagu_acc_v1");
        assert_eq!(fs::read(char_sv.join("ShaguPlates.lua")).unwrap(), b"shagu_char_v1");
    }

    #[test]
    fn test_wtf_snapshot_retention_pruning_pre_update_and_pre_restore() {
        let temp = tempfile::tempdir().unwrap();
        let wow_root = temp.path().join("WoW");
        let data_dir = temp.path().join("Data");
        let acc_sv = wow_root.join("_retail_").join("WTF").join("Account").join("12345#1").join("SavedVariables");

        fs::create_dir_all(&acc_sv).unwrap();
        fs::create_dir_all(&data_dir).unwrap();
        fs::write(acc_sv.join("MyAddon.lua"), b"content").unwrap();

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

        // Create 4 pre-update snapshots
        for _ in 1..=4 {
            take_wtf_snapshot(
                &conn,
                &wow_root,
                "_retail_",
                "addon-1",
                &["MyAddon".to_string()],
                &data_dir,
                "pre-update",
            ).unwrap();
        }

        let pre_update_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM wtf_snapshots WHERE addon_id = 'addon-1' AND kind = 'pre-update'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(pre_update_count, 3, "Only last 3 pre-update snapshots should be kept");

        // Create 4 pre-restore snapshots
        for _ in 1..=4 {
            take_wtf_snapshot(
                &conn,
                &wow_root,
                "_retail_",
                "addon-1",
                &["MyAddon".to_string()],
                &data_dir,
                "pre-restore",
            ).unwrap();
        }

        let pre_restore_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM wtf_snapshots WHERE addon_id = 'addon-1' AND kind = 'pre-restore'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(pre_restore_count, 3, "Only last 3 pre-restore snapshots should be kept");
    }

    #[test]
    fn test_cleanup_orphaned_wtf_snapshots() {
        let temp = tempfile::tempdir().unwrap();
        let data_dir = temp.path().join("Data");
        let snapshots_dir = data_dir.join("wtf_snapshots");
        fs::create_dir_all(&snapshots_dir).unwrap();

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        // 1. Legitimate snapshot
        let legit_path = snapshots_dir.join("legit_snapshot.zip");
        fs::write(&legit_path, b"legit").unwrap();
        conn.execute(
            "INSERT INTO wtf_snapshots (id, path) VALUES ('legit-1', ?1)",
            rusqlite::params![legit_path.to_string_lossy()],
        ).unwrap();

        // 2. Orphaned snapshot (no DB entry)
        let orphan_path = snapshots_dir.join("orphan_snapshot.zip");
        fs::write(&orphan_path, b"orphan").unwrap();

        assert!(orphan_path.exists());
        let cleaned = cleanup_orphaned_wtf_snapshots(&conn, &data_dir).unwrap();
        assert_eq!(cleaned, 1);
        assert!(!orphan_path.exists(), "Orphaned snapshot must be deleted");
        assert!(legit_path.exists(), "Legitimate snapshot must be kept");
    }
}
