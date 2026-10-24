use std::cmp::Ordering;
use std::fs;
use rusqlite::Connection;
use sha2::{Digest, Sha256};
use tempfile::tempdir;

use furphy_lib::db::schema::INITIAL_SCHEMA;
use furphy_lib::system::game::TEST_ENV_LOCK;

struct TestGuard {
    orig_pubkey: Option<String>,
}

impl Drop for TestGuard {
    fn drop(&mut self) {
        if let Some(ref p) = self.orig_pubkey {
            std::env::set_var("FURPHY_UPDATER_PUBKEY", p);
        } else {
            std::env::remove_var("FURPHY_UPDATER_PUBKEY");
        }
    }
}
use furphy_lib::update::app_update::{
    compare_semver, load_app_update_state, parse_ed25519_pubkey, parse_ed25519_signature,
    parse_semver_triplet, save_app_update_state, sign_artifact_with_seed,
    verify_artifact_integrity, AppUpdateStatus, CURRENT_VERSION,
};

#[test]
fn test_e2e_app_updater_channel_and_signature_integrity() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    // -------------------------------------------------------------
    // 1. Semver Comparisons: patch, minor, major, prerelease, downgrades
    // -------------------------------------------------------------
    assert_eq!(parse_semver_triplet("2.0.1"), (2, 0, 1));
    assert_eq!(parse_semver_triplet("v2.12.4"), (2, 12, 4));
    assert_eq!(parse_semver_triplet("2.0.0-dev"), (2, 0, 0));
    assert_eq!(parse_semver_triplet("1.27.1"), (1, 27, 1));
    assert_eq!(parse_semver_triplet("v3.0.0-beta.1"), (3, 0, 0));

    // Patch upgrade
    assert_eq!(compare_semver("2.0.2", "2.0.1"), Ordering::Greater);
    assert_eq!(compare_semver("2.0.1", "2.0.2"), Ordering::Less);

    // Minor upgrade
    assert_eq!(compare_semver("2.1.0", "2.0.1"), Ordering::Greater);
    assert_eq!(compare_semver("2.0.1", "2.1.0"), Ordering::Less);

    // Major upgrade
    assert_eq!(compare_semver("3.0.0", "2.99.99"), Ordering::Greater);
    assert_eq!(compare_semver("2.99.99", "3.0.0"), Ordering::Less);

    // Prerelease tags (normalized base comparison)
    assert_eq!(compare_semver("2.1.0-beta.1", "2.0.1"), Ordering::Greater);
    assert_eq!(compare_semver("2.0.1-rc1", "2.0.1"), Ordering::Equal);

    // Identity / Same version
    assert_eq!(compare_semver("2.0.1", "2.0.1"), Ordering::Equal);
    assert_eq!(compare_semver(CURRENT_VERSION, CURRENT_VERSION), Ordering::Equal);

    // Downgrade rejection (e.g. attempting to install v1.27.1 over v2.0.1)
    assert_eq!(compare_semver("1.27.1", "2.0.1"), Ordering::Less);
    assert_eq!(compare_semver("2.0.0", "2.0.1"), Ordering::Less);

    // -------------------------------------------------------------
    // 2. Integrity Verification: Sha256 + Ed25519 signatures
    // -------------------------------------------------------------
    let temp = tempdir().expect("Failed to create tempdir");
    let payload = b"Mock Furphy v2.1.0 installer executable content for testing.";

    let mut hasher = Sha256::new();
    hasher.update(payload);
    let expected_sha256 = format!("{:x}", hasher.finalize());

    let ed25519_seed = [0x55u8; 32];
    let (valid_sig_b64, valid_pubkey_b64) =
        sign_artifact_with_seed(payload, &ed25519_seed).expect("Failed signing payload");

    // Verify key and signature parsing
    let parsed_pub = parse_ed25519_pubkey(&valid_pubkey_b64).expect("Failed parsing valid pubkey");
    assert_eq!(parsed_pub.len(), 32);

    let parsed_sig = parse_ed25519_signature(&valid_sig_b64).expect("Failed parsing valid sig");
    assert_eq!(parsed_sig.len(), 64);

    // Set updater public key override in env
    let orig_pubkey = std::env::var("FURPHY_UPDATER_PUBKEY").ok();
    std::env::set_var("FURPHY_UPDATER_PUBKEY", &valid_pubkey_b64);
    let _cleanup = TestGuard { orig_pubkey };

    // Combined sha256 + Ed25519 signature verification MUST pass
    let valid_check = verify_artifact_integrity(
        payload,
        Some(&expected_sha256),
        Some(&valid_sig_b64),
    );
    assert!(valid_check.is_ok(), "Valid integrity verification failed: {:?}", valid_check);

    // Signature alone MUST pass
    let sig_only_check = verify_artifact_integrity(payload, None, Some(&valid_sig_b64));
    assert!(sig_only_check.is_ok(), "Valid signature check failed: {:?}", sig_only_check);

    // Sha256 alone MUST pass
    let sha_only_check = verify_artifact_integrity(payload, Some(&expected_sha256), None);
    assert!(sha_only_check.is_ok(), "Valid sha check failed: {:?}", sha_only_check);

    // Missing both hash and signature MUST fail
    let missing_both = verify_artifact_integrity(payload, None, None);
    assert!(missing_both.is_err(), "Expected failure when both sha and sig are missing");

    // Empty sha256 string MUST fail
    let empty_sha = verify_artifact_integrity(payload, Some("   "), None);
    assert!(empty_sha.is_err(), "Expected failure on empty sha256");

    // Corrupt / bad signature format MUST fail
    let corrupt_sig = verify_artifact_integrity(payload, None, Some("INVALID_CORRUPT_BASE64"));
    assert!(corrupt_sig.is_err(), "Expected failure on corrupt signature");

    // -------------------------------------------------------------
    // 3. Tamper Refusal: Modified payload MUST be refused
    // -------------------------------------------------------------
    let mut tampered_payload = payload.to_vec();
    tampered_payload[0] ^= 0xFF; // Flip byte

    let tamper_sha_res = verify_artifact_integrity(
        &tampered_payload,
        Some(&expected_sha256),
        None,
    );
    assert!(
        tamper_sha_res.is_err(),
        "Tampered payload must fail sha256 verification"
    );
    assert!(
        tamper_sha_res.unwrap_err().contains("Integrity verification failed"),
        "Expected checksum mismatch error"
    );

    let tamper_sig_res = verify_artifact_integrity(
        &tampered_payload,
        None,
        Some(&valid_sig_b64),
    );
    assert!(
        tamper_sig_res.is_err(),
        "Tampered payload must fail Ed25519 signature verification"
    );
    assert!(
        tamper_sig_res.unwrap_err().contains("Ed25519 cryptographic signature verification failed"),
        "Expected signature failure error"
    );

    let tamper_both_res = verify_artifact_integrity(
        &tampered_payload,
        Some(&expected_sha256),
        Some(&valid_sig_b64),
    );
    assert!(
        tamper_both_res.is_err(),
        "Tampered payload must fail combined verification"
    );

    // -------------------------------------------------------------
    // 4. Staging Update File Creation & State Persistence
    // -------------------------------------------------------------
    let staging_dir = temp.path().join("staging");
    fs::create_dir_all(&staging_dir).expect("Failed creating staging dir");

    let target_update_version = "2.1.0";
    let staged_installer_path = staging_dir.join(format!("FurphyAddonManager-Setup-{}.exe", target_update_version));

    // Staging requires passing integrity verification first
    let staged_bytes = payload;
    let verify_staging = verify_artifact_integrity(
        staged_bytes,
        Some(&expected_sha256),
        Some(&valid_sig_b64),
    );
    assert!(verify_staging.is_ok(), "Pre-staging verification must pass");

    fs::write(&staged_installer_path, staged_bytes).expect("Failed writing staged installer");
    assert!(staged_installer_path.exists(), "Staged installer must exist on disk");
    assert_eq!(
        fs::read(&staged_installer_path).unwrap(),
        staged_bytes,
        "Staged installer bytes must match exact payload"
    );

    // Persist updater state in SQLite database
    let conn = Connection::open_in_memory().expect("Failed opening sqlite conn");
    conn.execute_batch(INITIAL_SCHEMA).expect("Failed initializing schema");

    let status = AppUpdateStatus {
        status: "ready".to_string(),
        current_version: CURRENT_VERSION.to_string(),
        update_version: Some(target_update_version.to_string()),
        release_notes: Some("## What's new in v2.1.0\n- Faster sync\n- Rollback hardening".to_string()),
        published_at: Some("2026-10-24T00:00:00Z".to_string()),
        has_update: true,
        error: None,
        download_url: Some("https://github.com/krenz444/furphy-addon-manager/releases/download/v2.1.0/Setup.exe".to_string()),
        sha256: Some(expected_sha256.clone()),
        signature: Some(valid_sig_b64.clone()),
    };

    save_app_update_state(&conn, &status).expect("Failed saving app update state");

    let loaded_status = load_app_update_state(&conn).expect("Failed loading app update state");
    assert_eq!(loaded_status.status, "ready");
    assert_eq!(loaded_status.update_version.as_deref(), Some("2.1.0"));
    assert!(loaded_status.has_update);
    assert_eq!(loaded_status.sha256.as_deref(), Some(expected_sha256.as_str()));
    assert_eq!(loaded_status.signature.as_deref(), Some(valid_sig_b64.as_str()));
}
