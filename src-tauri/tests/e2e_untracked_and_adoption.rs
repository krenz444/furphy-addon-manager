use std::fs;
use std::path::PathBuf;

use furphy_lib::commands::addons::{
    delete_untracked_folder, ignore_untracked_addon, list_ignored_untracked,
    unignore_untracked_folder,
};
use furphy_lib::db::open_connection;
use furphy_lib::db::schema::INITIAL_SCHEMA;
use furphy_lib::engine::adopt::adopt_candidate_group;
use furphy_lib::engine::scan::scan_untracked_addons;
use furphy_lib::paths::get_db_path;
use furphy_lib::system::game::TEST_ENV_LOCK;

struct TestContext {
    wow_dir: PathBuf,
    local_data_dir: PathBuf,
    orig_wowroot: Option<String>,
    orig_localappdata: Option<String>,
}

impl TestContext {
    fn setup(name: &str) -> Self {
        let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
        let orig_localappdata = std::env::var("LOCALAPPDATA").ok();

        let rand_suffix = uuid::Uuid::new_v4().to_string();
        // Path MUST contain space and parentheses per ADR-307
        let wow_dir = std::env::temp_dir().join(format!("furphy e2e untracked ({}_{})", name, rand_suffix));
        let local_data_dir = std::env::temp_dir().join(format!("furphy_e2e_data_untracked_{}_{}", name, rand_suffix));

        let retail_addons = wow_dir.join("_retail_").join("Interface").join("AddOns");
        let retail_wtf = wow_dir.join("_retail_").join("WTF");
        fs::create_dir_all(&retail_addons).unwrap();
        fs::create_dir_all(&retail_wtf).unwrap();
        fs::create_dir_all(&local_data_dir).unwrap();

        std::env::set_var("FURPHY_DEV_WOWROOT", wow_dir.to_str().unwrap());
        std::env::set_var("LOCALAPPDATA", local_data_dir.to_str().unwrap());

        Self {
            wow_dir,
            local_data_dir,
            orig_wowroot,
            orig_localappdata,
        }
    }
}

impl Drop for TestContext {
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

        let _ = fs::remove_dir_all(&self.wow_dir);
        let _ = fs::remove_dir_all(&self.local_data_dir);
    }
}

#[tokio::test]
async fn test_e2e_untracked_scan_adopt_and_delete() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    // 1. Set up sandbox WoW root with TEST_ENV_LOCK
    let ctx = TestContext::setup("scan_adopt_delete");
    let wow_root = ctx.wow_dir.clone();
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");

    let db_path = get_db_path();
    let mut conn = open_connection(&db_path).unwrap();
    conn.execute_batch(INITIAL_SCHEMA).unwrap();

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', 110002)",
        [],
    ).unwrap();

    // 2. Drop an unmanaged addon folder TestAddon into _retail_/Interface/AddOns/ with a valid .toc
    let test_addon_dir = retail_addons.join("TestAddon");
    fs::create_dir_all(&test_addon_dir).unwrap();
    let toc_content = "## Interface: 110002\n## Title: Test Addon Title\n## Version: 1.2.3\n## Author: TestAuthor\n";
    fs::write(test_addon_dir.join("TestAddon.toc"), toc_content).unwrap();

    // 3. Run untracked scan: verify TestAddon detected as untracked
    let scanned_candidates = scan_untracked_addons(&conn, &retail_addons, "retail", Some(110002)).unwrap();
    assert_eq!(scanned_candidates.len(), 1, "Expected exactly 1 untracked candidate");
    let candidate = &scanned_candidates[0];
    assert_eq!(candidate.name, "Test Addon Title");
    assert_eq!(candidate.version, Some("1.2.3".to_string()));
    assert_eq!(candidate.author, Some("TestAuthor".to_string()));
    assert_eq!(candidate.folders, vec!["TestAddon".to_string()]);

    // 4. Test 1: Adopt TestAddon as a managed addon in SQLite (via adopt_addon / adopt_candidate_group)
    let adopted_id = adopt_candidate_group(&mut conn, "retail", candidate).unwrap();
    assert!(!adopted_id.is_empty(), "Adopted addon must receive a valid UUID");

    // Verify it transitions to managed in DB
    let is_adopted: i32 = conn.query_row(
        "SELECT adopted FROM addons WHERE id = ?1",
        rusqlite::params![adopted_id],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(is_adopted, 1, "Addon record in SQLite must have adopted = 1");

    let folder_tracked: String = conn.query_row(
        "SELECT folder FROM addon_folders WHERE addon_id = ?1",
        rusqlite::params![adopted_id],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(folder_tracked, "TestAddon");

    // Verify it vanishes from untracked list
    let scanned_after_adopt = scan_untracked_addons(&conn, &retail_addons, "retail", Some(110002)).unwrap();
    assert!(
        scanned_after_adopt.is_empty(),
        "Adopted addon must vanish from untracked list, found: {:?}",
        scanned_after_adopt
    );

    // 5. Drop a second unmanaged folder DecoyAddon
    let decoy_addon_dir = retail_addons.join("DecoyAddon");
    fs::create_dir_all(&decoy_addon_dir).unwrap();
    fs::write(
        decoy_addon_dir.join("DecoyAddon.toc"),
        "## Interface: 110002\n## Title: Decoy Addon\n## Version: 0.9.0\n",
    ).unwrap();

    let scanned_with_decoy = scan_untracked_addons(&conn, &retail_addons, "retail", Some(110002)).unwrap();
    assert_eq!(scanned_with_decoy.len(), 1);
    assert_eq!(scanned_with_decoy[0].folders, vec!["DecoyAddon".to_string()]);

    // 6. Test 2: Permanently ignore DecoyAddon via ignore_untracked_folder / ignore_untracked_addon
    ignore_untracked_addon("retail".to_string(), vec!["DecoyAddon".to_string()]).unwrap();

    let ignored_list = list_ignored_untracked("retail".to_string()).unwrap();
    assert!(ignored_list.contains(&"DecoyAddon".to_string()));

    // Re-scan: verify ignored
    let scanned_after_ignore = scan_untracked_addons(&conn, &retail_addons, "retail", Some(110002)).unwrap();
    assert!(
        scanned_after_ignore.is_empty(),
        "Ignored DecoyAddon must not appear in untracked list"
    );

    // Verify unignore restores it
    unignore_untracked_folder("retail".to_string(), "DecoyAddon".to_string()).unwrap();
    let scanned_restored = scan_untracked_addons(&conn, &retail_addons, "retail", Some(110002)).unwrap();
    assert_eq!(scanned_restored.len(), 1);
    assert_eq!(scanned_restored[0].folders, vec!["DecoyAddon".to_string()]);

    // Re-ignore for remaining lifecycle
    ignore_untracked_addon("retail".to_string(), vec!["DecoyAddon".to_string()]).unwrap();

    // 7. Drop a third unmanaged folder JunkAddon
    let junk_addon_dir = retail_addons.join("JunkAddon");
    fs::create_dir_all(&junk_addon_dir).unwrap();
    fs::write(
        junk_addon_dir.join("JunkAddon.toc"),
        "## Interface: 110002\n## Title: Junk Addon\n## Version: 0.0.1\n",
    ).unwrap();
    fs::write(junk_addon_dir.join("JunkScript.lua"), "-- junk script").unwrap();
    assert!(junk_addon_dir.exists(), "JunkAddon directory must exist before deletion");

    // 8. Test 3: Delete JunkAddon via delete_untracked_folder
    let del_res = delete_untracked_folder("retail".to_string(), "JunkAddon".to_string());
    assert!(del_res.is_ok(), "delete_untracked_folder must succeed: {:?}", del_res);
    assert!(
        !junk_addon_dir.exists(),
        "JunkAddon directory must be completely removed from disk"
    );

    // Verify path traversal attempts are strictly rejected
    let traversal_payloads = [
        "../../Windows",
        "../SavedVariables",
        "folder/subfolder",
        "folder\\subfolder",
        "C:AddOns",
        "..",
        ".",
    ];

    for bad in traversal_payloads {
        let res = delete_untracked_folder("retail".to_string(), bad.to_string());
        assert!(
            res.is_err(),
            "Path traversal payload '{}' MUST be rejected",
            bad
        );
        let err = res.unwrap_err();
        assert!(
            err.contains("path separators and directory traversal are rejected")
                || err.contains("Invalid folder name"),
            "Unexpected error message for '{}': {}",
            bad,
            err
        );
    }

    // Verify tracked addon guard: deleting an addon that is tracked MUST be refused
    let tracked_delete_res = delete_untracked_folder("retail".to_string(), "TestAddon".to_string());
    assert!(
        tracked_delete_res.is_err(),
        "Deleting a tracked addon folder must be refused"
    );
    assert!(
        tracked_delete_res.unwrap_err().contains("is tracked by an existing addon"),
        "Error must clearly indicate folder is tracked"
    );
    assert!(
        test_addon_dir.exists(),
        "Tracked addon folder must remain safe and intact on disk"
    );
}
