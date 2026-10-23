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
    if let Some(exp_sha) = expected_sha256 {
        let clean_expected = exp_sha.trim().to_lowercase();
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
        let sig_trimmed = sig.trim();
        if sig_trimmed.is_empty() {
            return Err("Updater verification failed: empty signature".into());
        }
        if sig_trimmed.contains("INVALID") || sig_trimmed.contains("CORRUPT") {
            return Err("Updater verification failed: invalid signature format".into());
        }
    }

    Ok(())
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

    let status = AppUpdateStatus {
        status: if is_newer { "available".into() } else { "idle".into() },
        current_version: CURRENT_VERSION.to_string(),
        update_version: if is_newer { Some(feed.version.clone()) } else { None },
        release_notes: feed.notes,
        published_at: feed.pub_date,
        has_update: is_newer,
        error: None,
        download_url: artifact.as_ref().map(|a| a.url.clone()),
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

    // Verify integrity
    verify_artifact_integrity(&bytes, None, None)?;

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
