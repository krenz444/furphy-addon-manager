use std::fs;
use std::path::PathBuf;
use tempfile::tempdir;

use furphy_lib::commands::settings::*;
use furphy_lib::db::open_connection;
use furphy_lib::net::policy::NetworkPolicy;
use furphy_lib::paths::*;
use furphy_lib::system::game::TEST_ENV_LOCK;

struct TestSandbox {
    _temp: tempfile::TempDir,
    _wow_path: PathBuf,
    _data_path: PathBuf,
    orig_wowroot: Option<String>,
    orig_localappdata: Option<String>,
}

impl TestSandbox {
    fn setup(label: &str) -> Self {
        let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
        let orig_localappdata = std::env::var("LOCALAPPDATA").ok();

        let temp = tempdir().unwrap();
        // Spaces and parentheses required by ADR-307
        let wow_path = temp.path().join(format!("World of Warcraft ({})", label));
        let retail_addons = wow_path.join("_retail_").join("Interface").join("AddOns");
        let retail_wtf = wow_path.join("_retail_").join("WTF");
        fs::create_dir_all(&retail_addons).unwrap();
        fs::create_dir_all(&retail_wtf).unwrap();

        let data_path = temp.path().join(format!("AppData (Test {})", label)).join("Local");
        fs::create_dir_all(&data_path).unwrap();

        std::env::set_var("FURPHY_DEV_WOWROOT", &wow_path);
        std::env::set_var("LOCALAPPDATA", &data_path);

        Self {
            _temp: temp,
            _wow_path: wow_path,
            _data_path: data_path,
            orig_wowroot,
            orig_localappdata,
        }
    }
}

impl Drop for TestSandbox {
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
    }
}

#[test]
fn test_e2e_settings_roundtrip_and_token_isolation() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _sandbox = TestSandbox::setup("settings_roundtrip");

    // Initialize fresh database with schema
    let db_path = get_db_path();
    let mut conn = open_connection(&db_path).expect("Failed to open connection to test db");
    furphy_lib::db::migrate::run_migrations(&mut conn).expect("Failed to run migrations");

    // 1. Initial roundtrip for releaseType
    update_settings("releaseType".into(), serde_json::json!(2))
        .expect("Failed to update releaseType");
    let settings = get_settings().expect("Failed to get settings");
    assert_eq!(
        settings.get("releaseType"),
        Some(&serde_json::json!(2)),
        "releaseType should be updated to 2"
    );

    // 2. Token write-only isolation test
    update_settings("githubToken".into(), serde_json::json!("ghp_Secret1234567890"))
        .expect("Failed to update githubToken");
    let settings_with_token = get_settings().expect("Failed to get settings after token write");
    assert_eq!(
        settings_with_token.get("hasGithubToken"),
        Some(&serde_json::json!(true)),
        "hasGithubToken must be true when token is set"
    );
    assert!(
        !settings_with_token.contains_key("githubToken"),
        "githubToken must NOT be leaked in get_settings"
    );

    // 3. Clear token and ensure hasGithubToken reflects false
    update_settings("githubToken".into(), serde_json::json!(""))
        .expect("Failed to clear githubToken");
    let settings_cleared = get_settings().expect("Failed to get settings after token clear");
    assert_eq!(
        settings_cleared.get("hasGithubToken"),
        Some(&serde_json::json!(false)),
        "hasGithubToken must be false when token is empty string"
    );
    assert!(
        !settings_cleared.contains_key("githubToken"),
        "githubToken must NOT be leaked after clearing"
    );
}

#[test]
fn test_e2e_migration_backups_lifecycle() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _sandbox = TestSandbox::setup("backups_lifecycle");

    let data_dir = get_data_dir();
    let mig_dir = data_dir.join("migration_backups");
    fs::create_dir_all(&mig_dir).expect("Failed to create migration_backups folder");

    // Initially should be empty
    let initial_backups = list_migration_backups().expect("Failed to list migration backups");
    assert!(initial_backups.is_empty(), "Initial migration backups should be empty");

    // Create mock backup files in migration_backups folder
    let backup1_path = mig_dir.join("mock_v1_backup_retail.zip");
    let backup2_path = mig_dir.join("mock_v1_backup_classic.zip");
    let data1 = b"PK\x03\x04mock_retail_archive_data";
    let data2 = b"PK\x03\x04mock_classic_archive_data_extended_payload";

    fs::write(&backup1_path, data1).expect("Failed to write mock backup 1");
    fs::write(&backup2_path, data2).expect("Failed to write mock backup 2");

    // Verify list_migration_backups returns both with correct names and sizes
    let backups = list_migration_backups().expect("Failed to list migration backups");
    assert_eq!(backups.len(), 2, "Expected exactly 2 migration backups");

    let b1 = backups
        .iter()
        .find(|b| b.name == "mock_v1_backup_retail.zip")
        .expect("mock_v1_backup_retail.zip not found in list");
    assert_eq!(b1.size_bytes, data1.len() as u64);
    assert_eq!(b1.path, backup1_path.to_string_lossy().to_string());

    let b2 = backups
        .iter()
        .find(|b| b.name == "mock_v1_backup_classic.zip")
        .expect("mock_v1_backup_classic.zip not found in list");
    assert_eq!(b2.size_bytes, data2.len() as u64);
    assert_eq!(b2.path, backup2_path.to_string_lossy().to_string());

    // Call delete_migration_backups and verify list is empty
    delete_migration_backups().expect("Failed to delete migration backups");
    let backups_after = list_migration_backups().expect("Failed to list migration backups after deletion");
    assert!(
        backups_after.is_empty(),
        "Migration backups should be empty after delete_migration_backups"
    );
    assert!(
        mig_dir.is_dir(),
        "migration_backups directory should exist after deletion"
    );
}

#[tokio::test]
async fn test_e2e_diagnostics_all_pass_on_fresh_environment() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _sandbox = TestSandbox::setup("diagnostics_fresh");

    // Initialize fresh database with schema
    let db_path = get_db_path();
    let mut conn = open_connection(&db_path).expect("Failed to open connection to test db");
    furphy_lib::db::migrate::run_migrations(&mut conn).expect("Failed to run migrations");

    let policy = NetworkPolicy::new();
    let items = execute_diagnostics(&policy)
        .await
        .expect("execute_diagnostics failed on fresh environment");

    assert!(!items.is_empty(), "Diagnostics returned no items");

    // Every diagnostic item must be OK
    for item in &items {
        assert!(
            item.ok,
            "Diagnostic item '{}' failed: detail='{}'",
            item.name, item.detail
        );
    }

    // Explicitly verify each expected diagnostic check is present and passed
    let required_diagnostics = [
        "World of Warcraft Root",
        "Data Directory",
        "SQLite Database",
        "CurseForge Policy",
        "Host Breakers",
        "Application Mode",
    ];

    for name in required_diagnostics {
        let found = items.iter().find(|i| i.name == name);
        assert!(
            found.is_some(),
            "Required diagnostic item '{}' missing from results",
            name
        );
        let item = found.unwrap();
        assert!(
            item.ok,
            "Diagnostic item '{}' was not ok: {}",
            name, item.detail
        );
    }
}
