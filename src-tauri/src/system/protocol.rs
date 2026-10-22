use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::io::Write;
use crate::paths::{get_data_dir, is_dev};

#[cfg(windows)]
use winreg::enums::{HKEY_CURRENT_USER, KEY_READ, KEY_SET_VALUE};
#[cfg(windows)]
use winreg::RegKey;

pub const PRODUCTION_PROTOCOL: &str = "curseforge";
pub const DEV_PROTOCOL: &str = "furphy-dev";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProtocolInstallRequest {
    pub scheme: String,
    pub action: String,
    pub project_id: i64,
    pub file_id: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProtocolStatusDto {
    pub registered: bool,
    pub scheme: String,
    pub command: Option<String>,
    pub is_dev: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProtocolConsentInfo {
    pub project_id: i64,
    pub file_id: i64,
    pub source: String,
    pub already_managed: bool,
    pub existing_addon_id: Option<String>,
    pub existing_name: Option<String>,
}

pub fn get_protocol_scheme(test_override: Option<&str>) -> String {
    if let Some(t) = test_override {
        return t.to_string();
    }
    if let Ok(val) = std::env::var("FURPHY_TEST_PROTOCOL_SCHEME") {
        return val;
    }
    if is_dev() {
        DEV_PROTOCOL.to_string()
    } else {
        PRODUCTION_PROTOCOL.to_string()
    }
}

pub fn parse_protocol_url(url_str: &str, expected_scheme: Option<&str>) -> Result<ProtocolInstallRequest, String> {
    let raw = url_str.trim();
    if raw.is_empty() {
        return Err("Empty protocol URL".to_string());
    }

    let colon_pos = raw.find(':').ok_or_else(|| "Missing scheme separator ':'".to_string())?;
    let scheme = &raw[..colon_pos].to_ascii_lowercase();

    if let Some(expected) = expected_scheme {
        if !scheme.eq_ignore_ascii_case(expected) {
            return Err(format!("Scheme '{}' does not match expected '{}'", scheme, expected));
        }
    } else {
        let active = get_protocol_scheme(None);
        if scheme != &active && scheme != PRODUCTION_PROTOCOL && scheme != DEV_PROTOCOL {
            return Err(format!("Unrecognized protocol scheme '{}'", scheme));
        }
    }

    let remainder = &raw[colon_pos + 1..];
    let stripped = remainder.trim_start_matches('/');

    let (path_part, query_part) = if let Some(q_pos) = stripped.find('?') {
        (&stripped[..q_pos], Some(&stripped[q_pos + 1..]))
    } else {
        (stripped, None)
    };

    let action = if path_part.starts_with("install") || path_part.is_empty() {
        "install".to_string()
    } else {
        path_part.split('/').next().unwrap_or("").to_ascii_lowercase()
    };

    if action != "install" {
        return Err(format!("Unsupported protocol action '{}'", action));
    }

    let mut project_id: Option<i64> = None;
    let mut file_id: Option<i64> = None;

    if let Some(query) = query_part {
        for pair in query.split('&') {
            if let Some(eq_pos) = pair.find('=') {
                let key = pair[..eq_pos].trim().to_ascii_lowercase();
                let val = pair[eq_pos + 1..].trim();
                if key == "addonid" || key == "addon_id" || key == "projectid" || key == "project_id" {
                    project_id = val.parse::<i64>().ok();
                } else if key == "fileid" || key == "file_id" {
                    file_id = val.parse::<i64>().ok();
                }
            }
        }
    }

    // Also support path format: install/<projectId>/<fileId>
    if (project_id.is_none() || file_id.is_none()) && path_part.contains('/') {
        let parts: Vec<&str> = path_part.split('/').collect();
        if parts.len() >= 3 && parts[0] == "install" {
            project_id = parts[1].parse::<i64>().ok();
            file_id = parts[2].parse::<i64>().ok();
        }
    }

    let pid = project_id.ok_or_else(|| "Missing or non-numeric project ID".to_string())?;
    let fid = file_id.ok_or_else(|| "Missing or non-numeric file ID".to_string())?;

    if pid <= 0 || fid <= 0 {
        return Err("Project ID and File ID must be positive integers".to_string());
    }

    Ok(ProtocolInstallRequest {
        scheme: scheme.clone(),
        action,
        project_id: pid,
        file_id: fid,
    })
}

pub fn append_handler_log(line: &str) {
    let log_path = get_data_dir().join("handler.log");
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&log_path) {
        let timestamp = chrono::Local::now().format("%Y-%m-%d %H:%M:%S");
        let _ = writeln!(file, "[{}] {}", timestamp, line);
    }
}

pub fn check_protocol_consent(
    conn: &Connection,
    req: &ProtocolInstallRequest,
    flavour: &str,
) -> Result<ProtocolConsentInfo, String> {
    let mut stmt = conn
        .prepare(
            "SELECT id, name FROM addons WHERE flavour = ?1 AND source = 'curseforge' AND project_id = ?2",
        )
        .map_err(|e| e.to_string())?;

    let mut rows = stmt
        .query(rusqlite::params![flavour, req.project_id])
        .map_err(|e| e.to_string())?;

    if let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let id: String = row.get(0).map_err(|e| e.to_string())?;
        let name: Option<String> = row.get(1).map_err(|e| e.to_string())?;
        append_handler_log(&format!(
            "Consent checked: addon {} already managed as '{}' ({})",
            req.project_id,
            name.as_deref().unwrap_or("unknown"),
            id
        ));
        Ok(ProtocolConsentInfo {
            project_id: req.project_id,
            file_id: req.file_id,
            source: "CurseForge".to_string(),
            already_managed: true,
            existing_addon_id: Some(id),
            existing_name: name,
        })
    } else {
        append_handler_log(&format!(
            "Consent checked: new addon install for project {} file {}",
            req.project_id, req.file_id
        ));
        Ok(ProtocolConsentInfo {
            project_id: req.project_id,
            file_id: req.file_id,
            source: "CurseForge".to_string(),
            already_managed: false,
            existing_addon_id: None,
            existing_name: None,
        })
    }
}

pub fn is_protocol_registered(test_override: Option<&str>) -> Result<bool, String> {
    let scheme = get_protocol_scheme(test_override);

    #[cfg(windows)]
    {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let path = format!(r"Software\Classes\{}", scheme);
        let key = match hkcu.open_subkey_with_flags(&path, KEY_READ) {
            Ok(k) => k,
            Err(_) => return Ok(false),
        };

        let cmd_key = match key.open_subkey_with_flags(r"shell\open\command", KEY_READ) {
            Ok(k) => k,
            Err(_) => return Ok(false),
        };

        let val: Result<String, _> = cmd_key.get_value("");
        return Ok(val.is_ok());
    }

    #[cfg(not(windows))]
    Ok(false)
}

pub fn register_protocol(test_override: Option<&str>) -> Result<(), String> {
    let scheme = get_protocol_scheme(test_override);
    let dev = is_dev();

    // Live-PC safety guard (ADR-307): dev builds MUST NOT hijack the production curseforge:// registration
    if dev && scheme == PRODUCTION_PROTOCOL && test_override.is_none() {
        return Err("Live-PC safety violation: dev build refused to register production curseforge:// protocol".to_string());
    }

    #[cfg(windows)]
    {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let base_path = format!(r"Software\Classes\{}", scheme);
        let (key, _) = hkcu
            .create_subkey(&base_path)
            .map_err(|e| format!("Failed to create protocol key: {}", e))?;

        let desc = format!("URL:{} Protocol", if dev { "Furphy Dev" } else { "CurseForge" });
        key.set_value("", &desc).map_err(|e| e.to_string())?;
        key.set_value("URL Protocol", &"").map_err(|e| e.to_string())?;

        let (cmd_key, _) = key
            .create_subkey(r"shell\open\command")
            .map_err(|e| e.to_string())?;

        let current_exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let cmd = format!("\"{}\" --protocol \"%1\"", current_exe.to_string_lossy());
        cmd_key.set_value("", &cmd).map_err(|e| e.to_string())?;

        append_handler_log(&format!("Registered protocol '{}' -> {}", scheme, cmd));
        return Ok(());
    }

    #[cfg(not(windows))]
    Ok(())
}

pub fn unregister_protocol(test_override: Option<&str>) -> Result<(), String> {
    let scheme = get_protocol_scheme(test_override);
    let dev = is_dev();

    // Live-PC safety guard (ADR-307)
    if dev && scheme == PRODUCTION_PROTOCOL && test_override.is_none() {
        return Err("Live-PC safety violation: dev build refused to unregister production curseforge:// protocol".to_string());
    }

    #[cfg(windows)]
    {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let parent = match hkcu.open_subkey_with_flags(r"Software\Classes", KEY_SET_VALUE) {
            Ok(p) => p,
            Err(_) => return Ok(()),
        };

        let _ = parent.delete_subkey_all(&scheme);
        append_handler_log(&format!("Unregistered protocol '{}'", scheme));
        return Ok(());
    }

    #[cfg(not(windows))]
    Ok(())
}

pub fn get_protocol_status(test_override: Option<&str>) -> Result<ProtocolStatusDto, String> {
    let scheme = get_protocol_scheme(test_override);
    let registered = is_protocol_registered(test_override)?;

    #[cfg(windows)]
    let command = {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let path = format!(r"Software\Classes\{}\shell\open\command", scheme);
        if let Ok(cmd_key) = hkcu.open_subkey_with_flags(&path, KEY_READ) {
            cmd_key.get_value::<String, _>("").ok()
        } else {
            None
        }
    };

    #[cfg(not(windows))]
    let command = None;

    Ok(ProtocolStatusDto {
        registered,
        scheme,
        command,
        is_dev: is_dev(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_valid_protocol_urls() {
        let u1 = "curseforge://install?addonId=1521253&fileId=8720783";
        let r1 = parse_protocol_url(u1, Some("curseforge")).unwrap();
        assert_eq!(r1.project_id, 1521253);
        assert_eq!(r1.file_id, 8720783);
        assert_eq!(r1.action, "install");

        let u2 = "furphy-dev://install?addon_id=2382&file_id=12345";
        let r2 = parse_protocol_url(u2, Some("furphy-dev")).unwrap();
        assert_eq!(r2.project_id, 2382);
        assert_eq!(r2.file_id, 12345);

        let u3 = "curseforge://install/1521253/8720783";
        let r3 = parse_protocol_url(u3, Some("curseforge")).unwrap();
        assert_eq!(r3.project_id, 1521253);
        assert_eq!(r3.file_id, 8720783);
    }

    #[test]
    fn test_parse_invalid_protocol_urls_rejected() {
        // Non-numeric IDs
        assert!(parse_protocol_url("curseforge://install?addonId=abc&fileId=123", Some("curseforge")).is_err());
        assert!(parse_protocol_url("curseforge://install?addonId=123&fileId=xyz", Some("curseforge")).is_err());
        // Missing IDs
        assert!(parse_protocol_url("curseforge://install?foo=bar", Some("curseforge")).is_err());
        // Negative / zero IDs
        assert!(parse_protocol_url("curseforge://install?addonId=0&fileId=1", Some("curseforge")).is_err());
        // Unsupported action
        assert!(parse_protocol_url("curseforge://delete?addonId=1&fileId=1", Some("curseforge")).is_err());
        // Wrong scheme
        assert!(parse_protocol_url("http://example.com", Some("curseforge")).is_err());
    }

    #[test]
    fn test_protocol_test_scheme_lifecycle() {
        let test_scheme = "furphy-unittest-proto";
        let _ = unregister_protocol(Some(test_scheme));
        assert!(!is_protocol_registered(Some(test_scheme)).unwrap());

        register_protocol(Some(test_scheme)).unwrap();
        assert!(is_protocol_registered(Some(test_scheme)).unwrap());

        let status = get_protocol_status(Some(test_scheme)).unwrap();
        assert!(status.registered);
        assert!(status.command.unwrap().contains("--protocol"));

        unregister_protocol(Some(test_scheme)).unwrap();
        assert!(!is_protocol_registered(Some(test_scheme)).unwrap());
    }
}
