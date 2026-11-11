use std::cmp::Ordering;
use std::fs;
use std::time::{Duration, Instant};
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

    #[test]
    fn check_result_keeps_installer_failure_only_for_same_version() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute("CREATE TABLE app_update (id INTEGER PRIMARY KEY, data TEXT)", []).unwrap();
        let failed = AppUpdateStatus {
            status: "error".into(),
            update_version: Some("9.9.1".into()),
            has_update: true,
            error: Some(format!("{} (exit code 0xC0000135)", INSTALLER_START_FAILED)),
            ..Default::default()
        };
        save_app_update_state(&conn, &failed).unwrap();

        let same = AppUpdateStatus {
            status: "available".into(),
            update_version: Some("9.9.1".into()),
            has_update: true,
            ..Default::default()
        };
        assert!(save_check_result_keeping_install_failure(&conn, &same));
        let kept = load_app_update_state(&conn).unwrap();
        assert_eq!(kept.status, "error");
        assert!(kept.error.unwrap().starts_with(INSTALLER_START_FAILED));

        let newer = AppUpdateStatus { update_version: Some("9.9.2".into()), ..same.clone() };
        assert!(!save_check_result_keeping_install_failure(&conn, &newer));
        assert_eq!(load_app_update_state(&conn).unwrap().status, "available");

        // A download error is retried, not remembered.
        let download_failed = AppUpdateStatus {
            status: "error".into(),
            error: Some("Download failed with HTTP 503".into()),
            ..newer.clone()
        };
        save_app_update_state(&conn, &download_failed).unwrap();
        assert!(!save_check_result_keeping_install_failure(&conn, &newer));
    }

    #[cfg(windows)]
    fn hidden_cmd(script: &str) -> std::process::Child {
        use std::os::windows::process::CommandExt;
        std::process::Command::new("cmd.exe")
            .args(["/c", script])
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .spawn()
            .expect("spawn cmd.exe")
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn installer_start_reports_early_nonzero_exit() {
        let mut child = hidden_cmd("exit 3");
        let res = wait_for_installer_start(
            &mut child,
            Duration::from_secs(5),
            std::path::Path::new("C:\\fake\\Setup.exe"),
        )
        .await;
        let err = res.expect_err("early non-zero exit must be an error");
        assert!(err.contains("0x00000003"), "unexpected message: {}", err);
        assert!(err.starts_with(INSTALLER_START_FAILED), "unexpected message: {}", err);
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn installer_start_ok_when_child_outlives_window() {
        let mut child = hidden_cmd("ping -n 6 127.0.0.1 >nul");
        let res = wait_for_installer_start(
            &mut child,
            Duration::from_millis(500),
            std::path::Path::new("C:\\fake\\Setup.exe"),
        )
        .await;
        let _ = child.kill();
        let _ = child.wait();
        assert!(res.is_ok(), "{:?}", res);
    }

    #[tokio::test]
    async fn install_update_with_guard_rejects_when_job_starts_during_download() {
        let _lock = crate::system::game::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let old_test_updater = std::env::var_os("FURPHY_TEST_UPDATER");
        std::env::set_var("FURPHY_TEST_UPDATER", "1");

        let status = AppUpdateStatus {
            status: "available".into(),
            current_version: "2.2.0".into(),
            update_version: Some("2.2.1".into()),
            has_update: true,
            download_url: Some("https://example.com/setup.exe".into()),
            ..Default::default()
        };

        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let calls_ref = calls.clone();
        let guard_fn: std::sync::Arc<dyn Fn() -> bool + Send + Sync> = std::sync::Arc::new(move || {
            let n = calls_ref.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            n >= 1 // False before download, true after download
        });

        let res = install_update_with_guard(&status, false, true, Some(guard_fn)).await;

        if let Some(v) = old_test_updater {
            std::env::set_var("FURPHY_TEST_UPDATER", v);
        } else {
            std::env::remove_var("FURPHY_TEST_UPDATER");
        }

        assert!(res.is_err(), "Expected post-download busy check to reject update install");
        assert!(res.unwrap_err().contains("addon job is currently running"));
        assert!(calls.load(std::sync::atomic::Ordering::SeqCst) >= 2);
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

/// Saves a fresh check result without losing an earlier "installer failed to start"
/// for the same version. Returns true when that version's installer already failed,
/// in which case it must not be installed automatically again; Settings can still
/// install it by hand.
pub fn save_check_result_keeping_install_failure(conn: &Connection, fresh: &AppUpdateStatus) -> bool {
    let previous_failure = load_app_update_state(conn)
        .filter(|prev| {
            prev.status == "error"
                && prev.update_version.is_some()
                && prev.update_version == fresh.update_version
                && prev.error.as_deref().map_or(false, |e| e.starts_with(INSTALLER_START_FAILED))
        })
        .and_then(|prev| prev.error);
    let mut saved = fresh.clone();
    if let Some(ref err) = previous_failure {
        saved.status = "error".into();
        saved.error = Some(err.clone());
    }
    if let Err(e) = save_app_update_state(conn, &saved) {
        append_app_log("WARN", &format!("Could not save app update state: {}", e));
    }
    previous_failure.is_some()
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

/// Prefix of the error recorded when the installer dies at start. The hourly check
/// matches on it so that version is not auto-installed again every hour.
pub const INSTALLER_START_FAILED: &str = "The update installer failed to start";

/// How long to watch a freshly spawned installer for an immediate crash.
#[cfg(windows)]
const INSTALLER_START_WINDOW: Duration = Duration::from_secs(4);

/// Polls the installer for `window`. A non-zero exit inside the window means it
/// never got going (for example the loader could not find a DLL), so the caller
/// must keep the app alive. Exit 0 or still running both count as started.
/// When the state cannot be read, staying alive is the safe answer: a working
/// installer closes this process itself.
#[cfg(windows)]
async fn wait_for_installer_start(
    child: &mut std::process::Child,
    window: Duration,
    installer_path: &std::path::Path,
) -> Result<(), String> {
    let deadline = Instant::now() + window;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                if status.success() {
                    return Ok(());
                }
                let code = status.code().unwrap_or(-1) as u32;
                let msg = format!(
                    "{} (exit code 0x{:08X}). Furphy is still running; the installer was saved at {}",
                    INSTALLER_START_FAILED,
                    code,
                    installer_path.display()
                );
                append_app_log("ERROR", &msg);
                return Err(msg);
            }
            Ok(None) => {}
            Err(e) => {
                let msg = format!("Could not check whether the update installer started: {}", e);
                append_app_log("WARN", &msg);
                return Err(msg);
            }
        }
        if Instant::now() >= deadline {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Installs the update if ready and safe to do so
pub async fn install_update(
    status: &AppUpdateStatus,
    is_runner_busy: bool,
    is_window_open: bool,
) -> Result<(), String> {
    install_update_with_guard(status, is_runner_busy, is_window_open, None).await
}

/// Installs the update and re-checks `busy_check` after downloading/verifying
/// so a job started during the download window prevents spawning the installer.
pub async fn install_update_with_guard(
    status: &AppUpdateStatus,
    is_runner_busy: bool,
    is_window_open: bool,
    busy_check: Option<std::sync::Arc<dyn Fn() -> bool + Send + Sync>>,
) -> Result<(), String> {
    let check_busy_now = || -> bool {
        is_runner_busy || busy_check.as_ref().map(|f| f()).unwrap_or(false)
    };

    // 1. Job-running guard (§2.K, §5.4): NEVER install during an active job
    if check_busy_now() {
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
        if busy_check.as_ref().map(|f| f()).unwrap_or(false) {
            return Err("Cannot install app update while an addon job is currently running.".to_string());
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

    // Re-check runner busy state after download & verification to close the TOCTOU window
    if busy_check.as_ref().map(|f| f()).unwrap_or(false) {
        append_app_log("WARN", "Aborted app update install: an addon job started during installer download");
        return Err("Cannot install app update while an addon job is currently running.".to_string());
    }

    // Write temporary installer
    let temp_dir = std::env::temp_dir();
    let installer_path = temp_dir.join(format!(
        "FurphyAddonManager-Setup-{}.exe",
        status.update_version.as_deref().unwrap_or("update")
    ));

    fs::write(&installer_path, &bytes).map_err(|e| format!("Failed saving installer executable: {}", e))?;

    // Final check immediately prior to spawning installer process
    if busy_check.as_ref().map(|f| f()).unwrap_or(false) {
        let _ = fs::remove_file(&installer_path);
        append_app_log("WARN", "Aborted app update install before spawn: an addon job became active");
        return Err("Cannot install app update while an addon job is currently running.".to_string());
    }

    // Execute installer
    #[cfg(windows)]
    {
        let mut cmd = std::process::Command::new(&installer_path);
        if !is_window_open {
            // Tray-only silent install (§2.K, §5.4); the installer restarts the tray itself
            cmd.arg("/S").arg("--relaunch-tray");
            append_app_log("INFO", "Running silent background installer (/S --relaunch-tray)");
        }
        let mut child = cmd
            .spawn()
            .map_err(|e| format!("Failed spawning update installer: {}", e))?;

        // spawn() succeeds even if the loader kills the child at once (missing DLL),
        // so give it a moment and stay alive if it died.
        wait_for_installer_start(&mut child, INSTALLER_START_WINDOW, &installer_path).await?;

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
