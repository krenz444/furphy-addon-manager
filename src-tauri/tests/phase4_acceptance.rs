use chrono::{Duration, Utc};
use tempfile::tempdir;
use rusqlite::Connection;
use furphy_lib::commands::open::open_target;
use furphy_lib::commands::addons::delete_untracked_folder;
use furphy_lib::engine::wtf::restore_wtf_snapshot;
use furphy_lib::system::game::TEST_ENV_LOCK;
use furphy_lib::net::policy::NetworkPolicy;
use furphy_lib::net::breaker::HostBreaker;

#[test]
fn test_acceptance_open_target_host_allowlist_security() {
    // 1. Disallowed hosts MUST be rejected
    let bad_hosts = [
        "https://evil.com/malware.zip",
        "https://phishing-curseforge.com/login",
        "http://attacker.org/script.lua",
        "https://google.com/search?q=wow",
    ];

    for bad in bad_hosts {
        let res = open_target("url".to_string(), Some(serde_json::json!(bad)));
        assert!(res.is_err(), "Expected url '{}' to be rejected", bad);
        let err = res.unwrap_err();
        assert!(
            err.contains("is not in the allowlist"),
            "Error '{}' should specify host allowlist rejection for {}",
            err,
            bad
        );
    }

    // 2. Non-HTTP/HTTPS schemes MUST be rejected
    let bad_schemes = [
        "javascript:alert(1)",
        "file:///C:/Windows/System32/cmd.exe",
        "data:text/html,<html>",
    ];

    for bad in bad_schemes {
        let res = open_target("url".to_string(), Some(serde_json::json!(bad)));
        assert!(res.is_err(), "Expected scheme in '{}' to be rejected", bad);
        let err = res.unwrap_err();
        assert!(
            err.contains("Only HTTP/HTTPS URLs are allowed") || err.contains("Invalid URL"),
            "Unexpected error: {}",
            err
        );
    }

    // 3. Valid URLs with complex query parameters (& ampersands) and array args MUST succeed
    std::env::set_var("FURPHY_TEST_NO_SPAWN", "1");
    let allowed_urls = [
        "https://curseforge.com/wow/addons/search?class=1&search=details",
        "https://www.curseforge.com/wow/addons/details?category=combat&sort=popular",
        "https://addons.wago.io/addons/plater?tab=description&view=grid",
        "https://github.com/Terciob/Details-Damage-Meter?tab=readme-ov-file&branch=main",
    ];
    for good in allowed_urls {
        // Test as string JSON value
        let res_str = open_target("url".to_string(), Some(serde_json::json!(good)));
        assert!(res_str.is_ok(), "Expected valid URL '{}' to succeed, got: {:?}", good, res_str);

        // Test as array JSON value
        let res_arr = open_target("url".to_string(), Some(serde_json::json!([good])));
        assert!(res_arr.is_ok(), "Expected valid array URL '{}' to succeed, got: {:?}", good, res_arr);
    }
    std::env::remove_var("FURPHY_TEST_NO_SPAWN");
}

#[test]
fn test_acceptance_untracked_folder_path_traversal_refusal() {
    let bad_folders = [
        "../SavedVariables",
        "../../Windows",
        "folder/subfolder",
        "folder\\subfolder",
        "C:AddOns",
        "..",
        ".",
    ];

    for folder in bad_folders {
        let res = delete_untracked_folder("retail".to_string(), folder.to_string());
        assert!(res.is_err(), "Expected traversal '{}' to be rejected", folder);
        let err = res.unwrap_err();
        assert!(
            err.contains("path separators and directory traversal are rejected")
                || err.contains("Invalid folder name"),
            "Unexpected error message: {}",
            err
        );
    }
}

#[test]
fn test_acceptance_wtf_restore_game_running_refusal_guard() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let temp = tempdir().unwrap();
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(
        r#"
        CREATE TABLE wtf_snapshots (
            id TEXT PRIMARY KEY,
            addon_id TEXT NOT NULL,
            account TEXT NOT NULL,
            scope TEXT NOT NULL,
            path TEXT NOT NULL,
            size INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            kind TEXT NOT NULL,
            restored_at TEXT
        );
        "#,
    ).unwrap();

    let wow_root = temp.path().join("WoW");
    let data_dir = temp.path().join("data");
    std::fs::create_dir_all(&wow_root).unwrap();
    std::fs::create_dir_all(&data_dir).unwrap();

    conn.execute(
        "INSERT INTO wtf_snapshots (id, addon_id, account, scope, path, size, created_at, kind) \
         VALUES ('snap-1', 'details', 'ACC1', 'account', 'C:\\dummy.zip', 100, '2026-10-22T00:00:00Z', 'pre-update')",
        [],
    ).unwrap();

    // 1. Simulate WoW running
    std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");
    let res = restore_wtf_snapshot(&conn, &wow_root, "_retail_", "snap-1", &data_dir);
    std::env::remove_var("FURPHY_TEST_WOW_RUNNING");

    // 2. Invariant: MUST return Err with plain explanation and write nothing!
    assert!(res.is_err());
    let err = res.unwrap_err();
    assert_eq!(
        err,
        "Cannot restore WTF SavedVariables while World of Warcraft is running."
    );
}

#[tokio::test]
async fn test_acceptance_network_policy_breakers_and_cf_fallback() {
    let policy = NetworkPolicy::new();

    // Default: cf fallback inactive
    assert!(!policy.is_cf_fallback_active().await);

    // Trip fallback: set fallback until 24h in future
    policy.set_cf_fallback(Utc::now() + Duration::hours(24)).await;
    assert!(policy.is_cf_fallback_active().await);

    // Breakers: after 3 consecutive failures, host marked offline
    let breaker = HostBreaker::new();
    assert!(!breaker.is_open("api.curseforge.com"));

    breaker.register_connectivity_failure("api.curseforge.com");
    assert!(!breaker.is_open("api.curseforge.com"));

    breaker.register_connectivity_failure("api.curseforge.com");
    assert!(!breaker.is_open("api.curseforge.com"));

    breaker.register_connectivity_failure("api.curseforge.com");
    assert!(breaker.is_open("api.curseforge.com"));

    // Success resets breaker
    breaker.register_success("api.curseforge.com");
    assert!(!breaker.is_open("api.curseforge.com"));
}

#[test]
fn test_acceptance_fetch_addons_with_details_patch_and_deps() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(furphy_lib::db::schema::INITIAL_SCHEMA).unwrap();

    // Insert flavour retail with client interface 110002
    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    ).unwrap();

    // 1. Compatible addon
    conn.execute(
        "INSERT INTO addons (id, flavour, name, author, version, installed_at, latest_game_versions, required_deps) \
         VALUES ('addon-ok', 'retail', 'Addon OK', 'Author', '1.0.0', '2026-10-22', '[\"11.0.2\", \"110002\"]', '[]')",
        [],
    ).unwrap();

    // 2. Old patch addon (interface 100207 != 110002)
    conn.execute(
        "INSERT INTO addons (id, flavour, name, author, version, installed_at, latest_game_versions, required_deps) \
         VALUES ('addon-old', 'retail', 'Addon Old', 'Author', '0.9.0', '2026-10-22', '[\"10.2.7\", \"100207\"]', '[]')",
        [],
    ).unwrap();

    // 3. Addon with missing dependency "Ace3"
    conn.execute(
        "INSERT INTO addons (id, flavour, name, author, version, installed_at, latest_game_versions, required_deps) \
         VALUES ('addon-missing-dep', 'retail', 'Addon Missing Dep', 'Author', '1.0.0', '2026-10-22', '[\"11.0.2\"]', '[\"Ace3\"]')",
        [],
    ).unwrap();

    let addons = furphy_lib::commands::addons::fetch_addons_with_details(&conn, "retail").unwrap();
    assert_eq!(addons.len(), 3);

    let a_ok = addons.iter().find(|a| a.id == "addon-ok").unwrap();
    assert!(!a_ok.is_old_patch, "addon-ok should NOT be marked old patch");
    assert!(a_ok.missing_deps.is_empty(), "addon-ok should have no missing deps");

    let a_old = addons.iter().find(|a| a.id == "addon-old").unwrap();
    assert!(a_old.is_old_patch, "addon-old MUST be marked old patch");

    let a_dep = addons.iter().find(|a| a.id == "addon-missing-dep").unwrap();
    assert_eq!(a_dep.missing_deps, vec!["Ace3".to_string()], "addon-missing-dep must list Ace3 as missing");
}

#[tokio::test]
async fn test_acceptance_job_runner_params_and_pinning() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(furphy_lib::db::schema::INITIAL_SCHEMA).unwrap();

    // Insert flavour retail
    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    ).unwrap();

    // Insert addon with initial file_id 'file_1'
    conn.execute(
        "INSERT INTO addons (id, flavour, name, author, version, file_id, installed_at) \
         VALUES ('details', 'retail', 'Details', 'Terciob', '1.0.0', 'file_1', '2026-10-22')",
        [],
    ).unwrap();

    // Verify initially unpinned
    let pinned: Option<String> = conn.query_row(
        "SELECT pinned_file_id FROM addons WHERE id = 'details'",
        [],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(pinned, None);

    // Call pin_addon directly (as runner install job does)
    furphy_lib::engine::pin::pin_addon(&conn, "details", "file_2").unwrap();

    let pinned_after: Option<String> = conn.query_row(
        "SELECT pinned_file_id FROM addons WHERE id = 'details'",
        [],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(pinned_after, Some("file_2".to_string()));

    // Unpin restores null
    furphy_lib::engine::pin::unpin_addon(&conn, "details").unwrap();
    let unpinned: Option<String> = conn.query_row(
        "SELECT pinned_file_id FROM addons WHERE id = 'details'",
        [],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(unpinned, None);
}
