use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use rusqlite::{params, Connection};
use tempfile::tempdir;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

use furphy_lib::db::schema::INITIAL_SCHEMA;
use furphy_lib::engine::rollback::rollback_addon;
use furphy_lib::engine::wtf::{restore_wtf_snapshot, take_wtf_snapshot};
use furphy_lib::system::game::TEST_ENV_LOCK;

struct TestGuard {
    orig_wowroot: Option<String>,
    orig_localappdata: Option<String>,
    orig_wow_running: Option<String>,
    orig_fake_wow: Option<String>,
}

impl Drop for TestGuard {
    fn drop(&mut self) {
        if let Some(ref w) = self.orig_wowroot {
            std::env::set_var("FURPHY_DEV_WOWROOT", w);
        } else {
            std::env::remove_var("FURPHY_DEV_WOWROOT");
        }
        if let Some(ref l) = self.orig_localappdata {
            std::env::set_var("LOCALAPPDATA", l);
        } else {
            std::env::remove_var("LOCALAPPDATA");
        }
        if let Some(ref r) = self.orig_wow_running {
            std::env::set_var("FURPHY_TEST_WOW_RUNNING", r);
        } else {
            std::env::remove_var("FURPHY_TEST_WOW_RUNNING");
        }
        if let Some(ref f) = self.orig_fake_wow {
            std::env::set_var("FURPHY_DEV_FAKE_WOW", f);
        } else {
            std::env::remove_var("FURPHY_DEV_FAKE_WOW");
        }
    }
}

/// Helper to construct a valid zip archive on disk with arbitrary entries
fn create_test_zip(zip_path: &Path, files: &[(&str, &[u8])]) {
    if let Some(parent) = zip_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let file = File::create(zip_path).expect("Failed to create zip file");
    let mut zip = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    for (name, content) in files {
        zip.start_file(*name, options).expect("Failed to start zip file entry");
        zip.write_all(content).expect("Failed to write zip content");
    }
    zip.finish().expect("Failed to finish zip archive");
}

#[tokio::test]
async fn test_e2e_addon_rollback_from_backup() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
    let orig_localappdata = std::env::var("LOCALAPPDATA").ok();
    let orig_wow_running = std::env::var("FURPHY_TEST_WOW_RUNNING").ok();
    let orig_fake_wow = std::env::var("FURPHY_DEV_FAKE_WOW").ok();

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (rollback)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let installed_addon_dir = retail_addons.join("BigWigs");
    fs::create_dir_all(&installed_addon_dir).expect("Failed to create addon dir");

    let data_dir = temp.path().join("furphy_data");
    fs::create_dir_all(&data_dir).expect("Failed to create data dir");

    std::env::set_var("LOCALAPPDATA", data_dir.to_str().unwrap());
    std::env::set_var("FURPHY_DEV_WOWROOT", wow_root.to_str().unwrap());
    let _cleanup = TestGuard {
        orig_wowroot,
        orig_localappdata,
        orig_wow_running,
        orig_fake_wow,
    };

    // 1. Initial State: Addon installed at v2.0
    fs::write(
        installed_addon_dir.join("BigWigs.toc"),
        "## Interface: 110002\n## Title: BigWigs\n## Version: 2.0.0\n",
    )
    .expect("Failed writing v2.0 toc");
    fs::write(
        installed_addon_dir.join("core.lua"),
        "print('BigWigs v2.0 active')",
    )
    .expect("Failed writing v2.0 lua");

    let conn = Connection::open_in_memory().expect("Failed to open sqlite memory conn");
    conn.execute_batch(INITIAL_SCHEMA).expect("Failed initializing schema");

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
        [],
    )
    .expect("Failed inserting flavour");

    conn.execute(
        "INSERT INTO addons (id, flavour, name, version, file_id, file_name, installed_at, adopted, pinned_file_id) \
         VALUES ('bigwigs', 'retail', 'BigWigs', '2.0.0', '20000', 'BigWigs-2.0.0.zip', '2026-10-20T00:00:00Z', 0, NULL)",
        [],
    )
    .expect("Failed inserting addon");

    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'BigWigs', 'bigwigs')",
        [],
    )
    .expect("Failed inserting addon folder");

    // 2. Prepare Backup v1.0 on disk
    let backup_dir = data_dir.join("backups").join("retail").join("bigwigs");
    let backup_v1_path = backup_dir.join("backup_v1.zip");

    create_test_zip(
        &backup_v1_path,
        &[
            (
                "BigWigs/BigWigs.toc",
                b"## Interface: 110002\n## Title: BigWigs\n## Version: 1.0.0\n",
            ),
            (
                "BigWigs/core.lua",
                b"print('BigWigs v1.0 active')",
            ),
        ],
    );

    let backup_size = fs::metadata(&backup_v1_path).unwrap().len() as i64;
    conn.execute(
        "INSERT INTO backups (id, addon_id, kind, file_id, version, path, size, created_at) \
         VALUES ('bk-v1', 'bigwigs', 'update', '10000', '1.0.0', ?1, ?2, '2026-10-19T00:00:00Z')",
        params![backup_v1_path.to_string_lossy().to_string(), backup_size],
    )
    .expect("Failed inserting backup record");

    // 3. Trigger Rollback via furphy_lib::engine::rollback::rollback_addon
    let rollback_res = rollback_addon(
        &conn,
        &wow_root,
        "_retail_",
        "bigwigs",
        "retail",
        &retail_addons,
        &data_dir,
    );
    assert!(rollback_res.is_ok(), "Rollback failed: {:?}", rollback_res);

    // 4. Verify disk files restored to v1.0 contents
    let restored_lua = fs::read_to_string(installed_addon_dir.join("core.lua"))
        .expect("Failed reading restored lua file");
    assert_eq!(restored_lua, "print('BigWigs v1.0 active')", "Lua file content was not restored to v1.0");

    let restored_toc = fs::read_to_string(installed_addon_dir.join("BigWigs.toc"))
        .expect("Failed reading restored toc file");
    assert!(
        restored_toc.contains("Version: 1.0.0"),
        "Toc version was not restored to v1.0"
    );

    // 5. Verify DB file_id and version rolled back to v1.0 and pinned
    let (db_version, db_file_id, db_pinned): (Option<String>, Option<String>, Option<String>) = conn
        .query_row(
            "SELECT version, file_id, pinned_file_id FROM addons WHERE id = 'bigwigs'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .expect("Failed querying addons table");

    assert_eq!(db_version.as_deref(), Some("1.0.0"), "DB version not rolled back to 1.0.0");
    assert_eq!(db_file_id.as_deref(), Some("10000"), "DB file_id not rolled back to 10000");
    assert_eq!(db_pinned.as_deref(), Some("10000"), "Addon was not pinned to prevent overwrite");
}

#[tokio::test]
async fn test_e2e_wtf_snapshot_backup_and_restore() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
    let orig_localappdata = std::env::var("LOCALAPPDATA").ok();
    let orig_wow_running = std::env::var("FURPHY_TEST_WOW_RUNNING").ok();
    let orig_fake_wow = std::env::var("FURPHY_DEV_FAKE_WOW").ok();

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (wtf restore)");
    let wtf_root = wow_root.join("_retail_").join("WTF");
    let acc_sv = wtf_root.join("Account").join("TestAcct").join("SavedVariables");
    let char_sv = wtf_root
        .join("Account")
        .join("TestAcct")
        .join("Frostmourne")
        .join("TestPriest")
        .join("SavedVariables");

    fs::create_dir_all(&acc_sv).expect("Failed to create account SavedVariables");
    fs::create_dir_all(&char_sv).expect("Failed to create character SavedVariables");

    let data_dir = temp.path().join("furphy_data");
    fs::create_dir_all(&data_dir).expect("Failed to create data dir");

    std::env::set_var("LOCALAPPDATA", data_dir.to_str().unwrap());
    std::env::set_var("FURPHY_DEV_WOWROOT", wow_root.to_str().unwrap());
    let _cleanup = TestGuard {
        orig_wowroot,
        orig_localappdata,
        orig_wow_running,
        orig_fake_wow,
    };

    // 1. Populate realistic mock WTF files
    let initial_acc_lua = "BigWigsSettings = { profile = 'Default', sound = true }\n";
    let initial_char_lua = "BigWigsCharSettings = { barPosition = 'CENTER', scale = 1.0 }\n";

    fs::write(acc_sv.join("BigWigs.lua"), initial_acc_lua).expect("Failed writing account lua");
    fs::write(char_sv.join("BigWigs.lua"), initial_char_lua).expect("Failed writing character lua");

    let conn = Connection::open_in_memory().expect("Failed opening sqlite conn");
    conn.execute_batch(INITIAL_SCHEMA).expect("Failed initializing schema");

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
        [],
    )
    .expect("Failed inserting flavour");

    conn.execute(
        "INSERT INTO addons (id, flavour, name, version, file_id, adopted) \
         VALUES ('bigwigs', 'retail', 'BigWigs', '1.0.0', '10000', 0)",
        [],
    )
    .expect("Failed inserting addon");

    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'BigWigs', 'bigwigs')",
        [],
    )
    .expect("Failed inserting addon folder");

    // 2. Create WTF backup snapshot
    let snapshot_id = take_wtf_snapshot(
        &conn,
        &wow_root,
        "_retail_",
        "bigwigs",
        &["BigWigs".to_string()],
        &data_dir,
        "pre-update",
    )
    .expect("take_wtf_snapshot returned an error")
    .expect("take_wtf_snapshot returned None when files were present");

    // 3. Verify snapshot zip exists and contains the SavedVariables files
    let snap_path_str: String = conn
        .query_row(
            "SELECT path FROM wtf_snapshots WHERE id = ?1",
            params![&snapshot_id],
            |r| r.get(0),
        )
        .expect("Snapshot not found in database");

    let snap_path = PathBuf::from(&snap_path_str);
    assert!(snap_path.exists(), "Snapshot zip file must exist on disk at {:?}", snap_path);

    let zip_file = File::open(&snap_path).expect("Failed to open snapshot zip");
    let mut archive = zip::ZipArchive::new(zip_file).expect("Failed reading snapshot zip archive");

    let mut entry_names = Vec::new();
    for i in 0..archive.len() {
        let entry = archive.by_index(i).expect("Failed reading zip entry");
        entry_names.push(entry.name().replace('\\', "/"));
    }

    assert!(
        entry_names.iter().any(|e| e == "Account/TestAcct/SavedVariables/BigWigs.lua"),
        "Account SavedVariables missing from snapshot: {:?}",
        entry_names
    );
    assert!(
        entry_names.iter().any(|e| e == "Account/TestAcct/Frostmourne/TestPriest/SavedVariables/BigWigs.lua"),
        "Character SavedVariables missing from snapshot: {:?}",
        entry_names
    );

    // 4. Modify or delete the mock WTF files
    fs::write(
        acc_sv.join("BigWigs.lua"),
        "BigWigsSettings = { CORRUPTED = true }\n",
    )
    .expect("Failed writing corrupted lua");
    fs::remove_file(char_sv.join("BigWigs.lua")).expect("Failed deleting character lua");

    // 5. Test game-running guard: set FURPHY_DEV_FAKE_WOW=1 and FURPHY_TEST_WOW_RUNNING=1
    std::env::set_var("FURPHY_DEV_FAKE_WOW", "1");
    std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");

    let refused_res = restore_wtf_snapshot(&conn, &wow_root, "_retail_", &snapshot_id, &data_dir);
    assert!(
        refused_res.is_err(),
        "Restore must fail when World of Warcraft is running"
    );
    assert!(
        refused_res.unwrap_err().contains("Cannot restore WTF SavedVariables while World of Warcraft is running"),
        "Expected game-running refusal message"
    );

    // Ensure corrupted state remains un-overwritten during refused restore
    assert_eq!(
        fs::read_to_string(acc_sv.join("BigWigs.lua")).unwrap(),
        "BigWigsSettings = { CORRUPTED = true }\n"
    );
    assert!(!char_sv.join("BigWigs.lua").exists());

    // 6. Restore the snapshot when game is stopped
    std::env::set_var("FURPHY_TEST_WOW_RUNNING", "0");
    std::env::remove_var("FURPHY_DEV_FAKE_WOW");

    let restore_res = restore_wtf_snapshot(&conn, &wow_root, "_retail_", &snapshot_id, &data_dir);
    assert!(restore_res.is_ok(), "Restore failed when game closed: {:?}", restore_res);

    // 7. Verify files are restored faithfully
    let restored_acc = fs::read_to_string(acc_sv.join("BigWigs.lua")).expect("Failed reading restored account lua");
    assert_eq!(restored_acc, initial_acc_lua, "Account SavedVariables not faithfully restored");

    let restored_char = fs::read_to_string(char_sv.join("BigWigs.lua")).expect("Failed reading restored char lua");
    assert_eq!(restored_char, initial_char_lua, "Character SavedVariables not faithfully restored");

    // Verify automatic pre-restore safety snapshot was taken
    let pre_restore_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM wtf_snapshots WHERE kind = 'pre-restore'",
            [],
            |r| r.get(0),
        )
        .expect("Failed counting pre-restore snapshots");
    assert_eq!(pre_restore_count, 1, "Expected 1 automatic pre-restore safety snapshot");
}
