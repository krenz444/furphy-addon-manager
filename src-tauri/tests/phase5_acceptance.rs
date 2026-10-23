use std::cmp::Ordering;
use std::fs;
use tempfile::tempdir;
use rusqlite::Connection;

use sha2::Digest;
use furphy_lib::db::migrate::run_migrations;
use furphy_lib::db::export_v1::export_to_v1;
use furphy_lib::system::retire_v1::{
    retire_v1_blocking, MOVED_NOTICE_FILENAME, RetireOptions,
};
use furphy_lib::update::app_update::{
    compare_semver, install_update, load_app_update_state, parse_semver_triplet,
    save_app_update_state, verify_artifact_integrity, AppUpdateStatus,
};

#[test]
fn test_acceptance_v1_retirement_lifecycle_and_moved_notice() {
    let temp = tempdir().unwrap();
    let scratch_v1 = temp.path().join("AddonSync");
    fs::create_dir_all(&scratch_v1).unwrap();

    // Create realistic v1 files
    fs::write(scratch_v1.join("VERSION"), "1.27.1").unwrap();
    fs::write(
        scratch_v1.join("settings.json"),
        r#"{"port": 47831, "runAtStartup": false, "releaseType": 1}"#,
    )
    .unwrap();
    fs::write(
        scratch_v1.join("addons.json"),
        r#"[{"name": "Details", "projectId": 61284, "folders": ["Details"]}]"#,
    )
    .unwrap();

    let opts = RetireOptions {
        force_test: true,
        custom_v1_path: Some(scratch_v1.clone()),
        test_run_value: Some("FurphyAddonManager.TestRetire".into()),
        test_protocol_scheme: Some("furphy-test-retire".into()),
        test_desktop_dir: Some(temp.path().join("Desktop")),
    };

    let summary = retire_v1_blocking(opts);

    // 1. Retirement must locate the scratch v1
    assert!(summary.v1_found, "Scratch v1 directory was not found");
    assert_eq!(
        summary.v1_path,
        Some(scratch_v1.display().to_string())
    );

    // 2. MOVED-TO-V2.txt must be written inside the v1 folder
    let notice_path = scratch_v1.join(MOVED_NOTICE_FILENAME);
    assert!(notice_path.exists(), "MOVED-TO-V2.txt was not written");
    let notice_content = fs::read_to_string(&notice_path).unwrap();

    // 3. Notice must contain required pointers and rollback instructions (§5.2 step 5)
    assert!(
        notice_content.contains(r"krenzcreative.furphy.addonmanager"),
        "Notice must contain v2 localappdata data location"
    );
    assert!(
        notice_content.contains("How to rollback to v1.27.x"),
        "Notice must contain rollback instructions"
    );
    assert!(
        notice_content.contains("dual-write compatibility mirror"),
        "Notice must explain dual-write mirror"
    );

    // 4. Scratch v1 original files must remain completely intact (immutability)
    assert_eq!(fs::read_to_string(scratch_v1.join("VERSION")).unwrap(), "1.27.1");
    assert!(scratch_v1.join("settings.json").exists());
    assert!(scratch_v1.join("addons.json").exists());
}

#[test]
fn test_acceptance_v1_retirement_dev_safety_isolation() {
    let temp = tempdir().unwrap();
    let scratch_v1 = temp.path().join("AddonSync");
    fs::create_dir_all(&scratch_v1).unwrap();

    let opts = RetireOptions {
        force_test: false, // Normal dev mode
        custom_v1_path: Some(scratch_v1.clone()),
        test_run_value: None,
        test_protocol_scheme: None,
        test_desktop_dir: None,
    };

    let summary = retire_v1_blocking(opts);

    // In dev mode without overrides, live system registry & events MUST NOT be touched (ADR-307)
    assert!(!summary.stopped_tray, "Dev mode should not signal live production tray stop event");
    assert!(!summary.replaced_autostart, "Dev mode should not replace live Run key");
    assert!(!summary.replaced_protocol, "Dev mode should not replace live protocol handler");

    // But notice file in the specified scratch folder is safely written
    assert!(summary.notice_written);
    assert!(scratch_v1.join(MOVED_NOTICE_FILENAME).exists());
}

#[test]
fn test_acceptance_updater_integrity_verification_and_tamper_refusal() {
    let payload = b"Mock installer executable binary content v2.0.1";

    let mut hasher = sha2::Sha256::new();
    sha2::Digest::update(&mut hasher, payload);
    let real_sha = format!("{:x}", sha2::Digest::finalize(hasher));

    // 1. Valid matching sha256 MUST succeed
    let res_valid = verify_artifact_integrity(payload, Some(&real_sha), Some("valid_minisign_sig"));
    assert!(res_valid.is_ok(), "Expected valid integrity check to succeed");

    // 2. Corrupted bytes or tampered hash MUST be rejected
    let res_tampered = verify_artifact_integrity(payload, Some("bad_hash_000000000000000000000"), None);
    assert!(res_tampered.is_err(), "Expected tampered hash to be rejected");
    let err_msg = res_tampered.unwrap_err();
    assert!(
        err_msg.contains("Integrity verification failed"),
        "Error message should mention integrity verification failure: {}",
        err_msg
    );

    // 3. Invalid signature marker MUST be rejected
    let res_bad_sig = verify_artifact_integrity(payload, Some(&real_sha), Some("INVALID_SIG"));
    assert!(res_bad_sig.is_err(), "Expected invalid signature to be rejected");
}

#[test]
fn test_acceptance_updater_semver_comparisons_and_downgrade_prevention() {
    // 1. Triplet parsing
    assert_eq!(parse_semver_triplet("2.0.1"), (2, 0, 1));
    assert_eq!(parse_semver_triplet("v2.12.4"), (2, 12, 4));
    assert_eq!(parse_semver_triplet("2.0.0-dev"), (2, 0, 0));
    assert_eq!(parse_semver_triplet("1.27.1"), (1, 27, 1));

    // 2. Newer version available
    assert_eq!(compare_semver("2.0.1", "2.0.0"), Ordering::Greater);
    assert_eq!(compare_semver("2.1.0", "2.0.9"), Ordering::Greater);
    assert_eq!(compare_semver("3.0.0", "2.99.99"), Ordering::Greater);

    // 3. Same version (no update available)
    assert_eq!(compare_semver("2.0.0", "2.0.0"), Ordering::Equal);
    assert_eq!(compare_semver("v2.0.0", "2.0.0"), Ordering::Equal);
    assert_eq!(compare_semver("2.0.0-dev", "2.0.0"), Ordering::Equal);

    // 4. Downgrade prevention (older versions rejected)
    assert_eq!(compare_semver("1.27.1", "2.0.0"), Ordering::Less);
    assert_eq!(compare_semver("2.0.0", "2.0.1"), Ordering::Less);
}

#[tokio::test]
async fn test_acceptance_updater_install_guards_and_job_busy_lock() {
    let update_status = AppUpdateStatus {
        status: "available".into(),
        current_version: "2.0.0".into(),
        update_version: Some("2.0.1".into()),
        release_notes: Some("Fixes".into()),
        published_at: Some("2026-10-23".into()),
        has_update: true,
        error: None,
        download_url: Some("https://example.com/setup.exe".into()),
    };

    // 1. Guard: Cannot install while a job is running (§2.K, §5.4)
    let busy_res = install_update(&update_status, true, false).await;
    assert!(busy_res.is_err(), "Expected install while busy to fail");
    assert!(
        busy_res.unwrap_err().contains("Cannot install app update while an addon job is currently running"),
        "Unexpected error message"
    );

    // 2. Guard: Cannot install if no update is available
    let no_update_status = AppUpdateStatus {
        has_update: false,
        update_version: None,
        ..AppUpdateStatus::default()
    };
    let no_update_res = install_update(&no_update_status, false, false).await;
    assert!(no_update_res.is_err());
    assert!(no_update_res.unwrap_err().contains("No update is currently available"));
}

#[test]
fn test_acceptance_updater_db_persistence_roundtrip() {
    let temp = tempdir().unwrap();
    let db_path = temp.path().join("test.db");
    let mut conn = Connection::open(&db_path).unwrap();
    run_migrations(&mut conn).unwrap();

    let initial = AppUpdateStatus {
        status: "available".into(),
        current_version: "2.0.0".into(),
        update_version: Some("2.0.1".into()),
        release_notes: Some("Changelog notes".into()),
        published_at: Some("2026-10-23T00:00:00Z".into()),
        has_update: true,
        error: None,
        download_url: Some("https://github.com/releases/download/v2.0.1/setup.exe".into()),
    };

    save_app_update_state(&conn, &initial).unwrap();
    let loaded = load_app_update_state(&conn).expect("Failed loading saved app_update state");

    assert_eq!(loaded, initial);
}

#[test]
fn test_acceptance_dual_write_rollback_v1_file_generation() {
    let temp = tempdir().unwrap();
    let db_path = temp.path().join("test_dual_write.db");
    let mut conn = Connection::open(&db_path).unwrap();
    run_migrations(&mut conn).unwrap();

    let v1_dir = temp.path().join("v1_folder");
    fs::create_dir_all(&v1_dir).unwrap();

    // Insert an addon and settings in v2 DB
    conn.execute(
        "INSERT OR REPLACE INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO addons (id, flavour, name, author, source, version, project_id, file_id) \
         VALUES ('details', 'retail', 'Details! Damage Meter', 'Terciob', 'curseforge', '11.0.2', 61284, '5681920')",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'Details', 'details')",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('releaseType', '1'), ('backgroundUpdates', 'true')",
        [],
    ).unwrap();

    // Execute dual write export
    export_to_v1(&conn, &v1_dir).unwrap();

    // Verify v1 structure generated
    let retail_addons_file = v1_dir.join("flavours").join("retail").join("addons.json");
    assert!(retail_addons_file.exists(), "v1 retail addons.json was not generated");

    let settings_file = v1_dir.join("settings.json");
    assert!(settings_file.exists(), "v1 settings.json was not generated");

    // Verify v1 readable JSON
    let addons_json: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(retail_addons_file).unwrap()).unwrap();
    assert!(addons_json.is_array());
    let arr = addons_json.as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["name"], "Details! Damage Meter");
    assert_eq!(arr[0]["projectId"], 61284);

    let settings_json: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(settings_file).unwrap()).unwrap();
    assert_eq!(settings_json["releaseType"], 1);
}

#[test]
fn test_acceptance_straggler_version_upgrade_detection() {
    // Tests that older v1 versions (e.g. 1.20.0, 1.22.0) that skipped releases are detected as needing upgrade
    let straggler_versions = ["1.20.0", "1.22.0", "1.25.0", "1.27.1"];
    let target_v2 = "2.0.0";

    for v in straggler_versions {
        assert_eq!(
            compare_semver(target_v2, v),
            Ordering::Greater,
            "Target v2 '{}' must be detected as newer than straggler v1 '{}'",
            target_v2,
            v
        );
    }
}
