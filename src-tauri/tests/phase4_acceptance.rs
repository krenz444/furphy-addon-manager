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
        let res = open_target("url".to_string(), Some(bad.to_string()));
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
        let res = open_target("url".to_string(), Some(bad.to_string()));
        assert!(res.is_err(), "Expected scheme in '{}' to be rejected", bad);
        let err = res.unwrap_err();
        assert!(
            err.contains("Only HTTP/HTTPS URLs are allowed") || err.contains("Invalid URL"),
            "Unexpected error: {}",
            err
        );
    }
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
    let _lock = TEST_ENV_LOCK.lock().unwrap();

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
