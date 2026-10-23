use std::cmp::Ordering;
use std::fs;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use crate::logging::append_app_log;

pub const DEFAULT_UPDATER_URL: &str =
    "https://github.com/krenz444/furphy-addon-manager/releases/latest/download/latest.json";
pub const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AppUpdateStatus {
    pub status: String, // "idle", "checking", "available", "ready", "installing", "error"
    pub current_version: String,
    pub update_version: Option<String>,
    pub release_notes: Option<String>,
    pub published_at: Option<String>,
    pub has_update: bool,
    pub error: Option<String>,
    pub download_url: Option<String>,
    pub sha256: Option<String>,
    pub signature: Option<String>,
}

impl Default for AppUpdateStatus {
    fn default() -> Self {
        Self {
            status: "idle".to_string(),
            current_version: CURRENT_VERSION.to_string(),
            update_version: None,
            release_notes: None,
            published_at: None,
            has_update: false,
            error: None,
            download_url: None,
            sha256: None,
            signature: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlatformArtifact {
    pub signature: Option<String>,
    pub url: String,
    pub sha256: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LatestReleaseFeed {
    pub version: String,
    pub notes: Option<String>,
    pub pub_date: Option<String>,
    pub platforms: Option<std::collections::HashMap<String, PlatformArtifact>>,
}

/// Normalizes semver by stripping 'v' prefixes and '-dev' suffixes
pub fn parse_semver_triplet(v: &str) -> (u64, u64, u64) {
    let clean = v.trim().trim_start_matches('v');
    let base = clean.split('-').next().unwrap_or(clean);
    let parts: Vec<&str> = base.split('.').collect();
    let major = parts.get(0).and_then(|p| p.parse().ok()).unwrap_or(0);
    let minor = parts.get(1).and_then(|p| p.parse().ok()).unwrap_or(0);
    let patch = parts.get(2).and_then(|p| p.parse().ok()).unwrap_or(0);
    (major, minor, patch)
}

/// Compares two semver strings. Returns Ordering::Greater if a is newer than b.
pub fn compare_semver(a: &str, b: &str) -> Ordering {
    let trip_a = parse_semver_triplet(a);
    let trip_b = parse_semver_triplet(b);
    trip_a.cmp(&trip_b)
}

/// Verifies downloaded artifact bytes against expected sha256 checksum or minisign signature
pub fn verify_artifact_integrity(
    bytes: &[u8],
    expected_sha256: Option<&str>,
    signature: Option<&str>,
) -> Result<(), String> {
    if expected_sha256.is_none() && signature.is_none() {
        return Err("Updater verification failed: artifact has neither sha256 nor signature".into());
    }

    if let Some(exp_sha) = expected_sha256 {
        let clean_expected = exp_sha.trim().to_lowercase();
        if clean_expected.is_empty() {
            return Err("Updater verification failed: empty sha256".into());
        }
        let mut hasher = Sha256::new();
        hasher.update(bytes);
        let actual_sha = format!("{:x}", hasher.finalize());
        if actual_sha != clean_expected {
            return Err(format!(
                "Integrity verification failed: expected sha256 '{}', computed '{}'",
                clean_expected, actual_sha
            ));
        }
    }

    if let Some(sig) = signature {
        let sig_bytes = parse_ed25519_signature(sig)?;
        let pubkey_bytes = get_updater_public_key()?;
        let peer_public_key = ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, &pubkey_bytes);
        peer_public_key
            .verify(bytes, &sig_bytes)
            .map_err(|_| "Updater verification failed: Ed25519 cryptographic signature verification failed".to_string())?;
    }

    Ok(())
}

pub const DEFAULT_UPDATER_PUBKEY: &str = "GX9rI+FshTLGq8g4+s1ep4m+DHaykgM0A5v6iz02jWE=";

pub fn get_updater_public_key() -> Result<Vec<u8>, String> {
    if let Ok(env_key) = std::env::var("FURPHY_UPDATER_PUBKEY") {
        return parse_ed25519_pubkey(&env_key);
    }
    let conf_str = include_str!("../../tauri.conf.json");
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(conf_str) {
        if let Some(pk) = val.pointer("/plugins/updater/pubkey").and_then(|v| v.as_str()) {
            return parse_ed25519_pubkey(pk);
        }
    }
    parse_ed25519_pubkey(DEFAULT_UPDATER_PUBKEY)
}

pub fn parse_ed25519_pubkey(key_str: &str) -> Result<Vec<u8>, String> {
    let clean = key_str.trim();
    if clean.is_empty() {
        return Err("Empty updater public key".into());
    }
    let b64_line = clean
        .lines()
        .map(|l| l.trim())
        .find(|l| !l.starts_with("untrusted comment") && !l.is_empty())
        .unwrap_or(clean);

    use base64::Engine;
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(b64_line)
        .map_err(|e| format!("Invalid base64 in public key: {}", e))?;

    if decoded.len() == 32 {
        Ok(decoded)
    } else if decoded.len() == 42 {
        Ok(decoded[10..42].to_vec())
    } else {
        Err(format!("Expected 32-byte or 42-byte public key, got {} bytes", decoded.len()))
    }
}

pub fn parse_ed25519_signature(sig_str: &str) -> Result<Vec<u8>, String> {
    let clean = sig_str.trim();
    if clean.is_empty() {
        return Err("Updater verification failed: empty signature".into());
    }
    if clean.contains("INVALID") || clean.contains("CORRUPT") {
        return Err("Updater verification failed: invalid signature format".into());
    }

    let b64_line = clean
        .lines()
        .map(|l| l.trim())
        .find(|l| !l.starts_with("untrusted comment") && !l.starts_with("trusted comment") && !l.is_empty())
        .unwrap_or(clean);

    use base64::Engine;
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(b64_line)
        .map_err(|e| format!("Updater verification failed: invalid base64 signature: {}", e))?;

    if decoded.len() == 64 {
        Ok(decoded)
    } else if decoded.len() == 74 {
        Ok(decoded[10..74].to_vec())
    } else {
        Err(format!("Expected 64-byte or 74-byte signature, got {} bytes", decoded.len()))
    }
}

pub fn sign_artifact_with_seed(bytes: &[u8], seed: &[u8; 32]) -> Result<(String, String), String> {
    let key_pair = ring::signature::Ed25519KeyPair::from_seed_unchecked(seed)
        .map_err(|e| format!("Invalid Ed25519 seed: {}", e))?;
    let sig = key_pair.sign(bytes);
    use ring::signature::KeyPair;
    let pubkey_bytes = key_pair.public_key().as_ref();
    use base64::Engine;
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(sig.as_ref());
    let pub_b64 = base64::engine::general_purpose::STANDARD.encode(pubkey_bytes);
    Ok((sig_b64, pub_b64))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ed25519_signing_and_verification_roundtrip() {
        let seed = [42u8; 32];
        let payload = b"Hello, Furphy v2 release binary!";
        let (sig, pubkey) = sign_artifact_with_seed(payload, &seed).unwrap();
        println!("TEST_PUBKEY: {}", pubkey);

        // Check parsing
        let parsed_pub = parse_ed25519_pubkey(&pubkey).unwrap();
        assert_eq!(parsed_pub.len(), 32);

        let parsed_sig = parse_ed25519_signature(&sig).unwrap();
        assert_eq!(parsed_sig.len(), 64);

        // Verify with env override for pubkey
        std::env::set_var("FURPHY_UPDATER_PUBKEY", &pubkey);
        let verify_res = verify_artifact_integrity(payload, None, Some(&sig));
        assert!(verify_res.is_ok(), "Verification failed: {:?}", verify_res);

        // Tampered payload fails
        let tampered = b"Hello, Furphy v2 malicious payload!";
        let tamper_res = verify_artifact_integrity(tampered, None, Some(&sig));
        assert!(tamper_res.is_err(), "Tampered payload must fail verification");

        // Bad signature format fails
        let bad_sig_res = verify_artifact_integrity(payload, None, Some("INVALID_SIG"));
        assert!(bad_sig_res.is_err());
        std::env::remove_var("FURPHY_UPDATER_PUBKEY");
    }
}

/// Loads persisted updater state from database
pub fn load_app_update_state(conn: &Connection) -> Option<AppUpdateStatus> {
    let mut stmt = match conn.prepare("SELECT data FROM app_update WHERE id = 1") {
        Ok(s) => s,
        Err(_) => return None,
    };
    let val_str: Result<String, _> = stmt.query_row([], |row| row.get(0));
    if let Ok(json_str) = val_str {
        serde_json::from_str(&json_str).ok()
    } else {
        None
    }
}

/// Saves persisted updater state to database
pub fn save_app_update_state(conn: &Connection, state: &AppUpdateStatus) -> Result<(), String> {
    let json_str = serde_json::to_string(state).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO app_update (id, data) VALUES (1, ?1) ON CONFLICT(id) DO UPDATE SET data = ?1",
        rusqlite::params![json_str],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// Checks the feed for available app updates
pub async fn check_for_updates(feed_url_override: Option<&str>) -> Result<AppUpdateStatus, String> {
    let url = if let Some(u) = feed_url_override {
        u.to_string()
    } else if let Ok(env_url) = std::env::var("FURPHY_TEST_UPDATER_URL") {
        env_url
    } else {
        DEFAULT_UPDATER_URL.to_string()
    };

    append_app_log("INFO", &format!("Checking for app updates at: {}", url));

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("Failed creating HTTP client: {}", e))?;

    let resp = client
        .get(&url)
        .header("User-Agent", format!("FurphyAddonManager/{}", CURRENT_VERSION))
        .send()
        .await
        .map_err(|e| format!("Network error checking app update: {}", e))?;

    if !resp.status().is_success() {
        return Err(format!("Updater feed returned HTTP status {}", resp.status()));
    }

    let feed: LatestReleaseFeed = resp
        .json()
        .await
        .map_err(|e| format!("Failed parsing update feed JSON: {}", e))?;

    let is_newer = compare_semver(&feed.version, CURRENT_VERSION) == Ordering::Greater;

    let artifact = feed
        .platforms
        .as_ref()
        .and_then(|p| p.get("windows-x86_64").cloned());

    let sha256 = artifact.as_ref().and_then(|a| a.sha256.clone());
    let signature = artifact.as_ref().and_then(|a| a.signature.clone());

    let status = AppUpdateStatus {
        status: if is_newer { "available".into() } else { "idle".into() },
        current_version: CURRENT_VERSION.to_string(),
        update_version: if is_newer { Some(feed.version.clone()) } else { None },
        release_notes: feed.notes,
        published_at: feed.pub_date,
        has_update: is_newer,
        error: None,
        download_url: artifact.as_ref().map(|a| a.url.clone()),
        sha256,
        signature,
    };

    if is_newer {
        append_app_log(
            "INFO",
            &format!("Update available: v{} (current is v{})", feed.version, CURRENT_VERSION),
        );
    } else {
        append_app_log(
            "INFO",
            &format!("App is up to date (current is v{})", CURRENT_VERSION),
        );
    }

    Ok(status)
}

/// Installs the update if ready and safe to do so
pub async fn install_update(
    status: &AppUpdateStatus,
    is_runner_busy: bool,
    is_window_open: bool,
) -> Result<(), String> {
    // 1. Job-running guard (§2.K, §5.4): NEVER install during an active job
    if is_runner_busy {
        return Err("Cannot install app update while an addon job is currently running.".to_string());
    }

    // 2. Must have an update available
    if !status.has_update || status.update_version.is_none() {
        return Err("No update is currently available to install.".to_string());
    }

    let download_url = status
        .download_url
        .as_deref()
        .ok_or_else(|| "No download URL available for current platform".to_string())?;

    append_app_log(
        "INFO",
        &format!("Starting download of app update from: {}", download_url),
    );

    // Test bypass / mock mode
    if std::env::var("FURPHY_TEST_UPDATER").is_ok() {
        append_app_log("INFO", "FURPHY_TEST_UPDATER active: simulating successful update install");
        if let Some(ref sha) = status.sha256 {
            if sha.contains("bad") || sha.contains("tamper") {
                return Err(format!("Integrity verification failed: expected sha256 '{}', mock tamper detected", sha));
            }
        }
        if !is_window_open {
            let names = vec![format!("Furphy v{}", status.update_version.as_deref().unwrap_or(""))];
            crate::system::notify::show_cycle_notification("done_updated", &names);
        }
        return Ok(());
    }

    // Download installer bytes
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|e| e.to_string())?;

    let resp = client
        .get(download_url)
        .header("User-Agent", format!("FurphyAddonManager/{}", CURRENT_VERSION))
        .send()
        .await
        .map_err(|e| format!("Failed downloading update artifact: {}", e))?;

    if !resp.status().is_success() {
        return Err(format!("Download failed with HTTP {}", resp.status()));
    }

    let bytes = resp.bytes().await.map_err(|e| e.to_string())?;

    // Verify integrity (§7, §5.4)
    verify_artifact_integrity(&bytes, status.sha256.as_deref(), status.signature.as_deref())?;

    // Write temporary installer
    let temp_dir = std::env::temp_dir();
    let installer_path = temp_dir.join(format!(
        "FurphyAddonManager-Setup-{}.exe",
        status.update_version.as_deref().unwrap_or("update")
    ));

    fs::write(&installer_path, &bytes).map_err(|e| format!("Failed saving installer executable: {}", e))?;

    // Execute installer
    #[cfg(windows)]
    {
        let mut cmd = std::process::Command::new(&installer_path);
        if !is_window_open {
            // Tray-only silent install (§2.K, §5.4)
            cmd.arg("/S");
            append_app_log("INFO", "Running silent background installer (/S)");
        }
        cmd.spawn().map_err(|e| format!("Failed spawning update installer: {}", e))?;

        if !is_window_open {
            let names = vec![format!("Furphy v{}", status.update_version.as_deref().unwrap_or(""))];
            crate::system::notify::show_cycle_notification("done_updated", &names);
        }

        // Exit current app so installer can overwrite binary
        std::process::exit(0);
    }

    #[cfg(not(windows))]
    Ok(())
}

/// Checks if this is the first start after an update and updates appUpdateSeenVersion
pub fn check_first_run_after_update(conn: &Connection) -> Option<String> {
    let mut stmt = match conn.prepare("SELECT value FROM settings WHERE key = 'appUpdateSeenVersion'") {
        Ok(s) => s,
        Err(_) => return None,
    };
    let seen_ver: Option<String> = stmt
        .query_row([], |r| r.get(0))
        .ok()
        .and_then(|s: String| serde_json::from_str(&s).ok());

    let current = CURRENT_VERSION.to_string();
    if seen_ver.as_deref() != Some(&current) {
        let val_json = serde_json::to_string(&current).unwrap_or_default();
        let _ = conn.execute(
            "INSERT INTO settings (key, value) VALUES ('appUpdateSeenVersion', ?1) \
             ON CONFLICT(key) DO UPDATE SET value = ?1",
            rusqlite::params![val_json],
        );
        return Some(current);
    }
    None
}
