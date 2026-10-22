use serde::{Deserialize, Serialize};
use crate::paths::is_dev;

#[cfg(windows)]
use winreg::enums::{HKEY_CURRENT_USER, KEY_READ, KEY_SET_VALUE};
#[cfg(windows)]
use winreg::RegKey;

pub const PRODUCTION_RUN_VALUE_NAME: &str = "FurphyAddonManager";
pub const TEST_RUN_VALUE_NAME: &str = "FurphyAddonManager.Test";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutostartStatusDto {
    pub enabled: bool,
    pub value_name: String,
    pub command: Option<String>,
    pub is_dev: bool,
}

pub fn get_run_value_name(test_override: Option<&str>) -> String {
    if let Some(t) = test_override {
        return t.to_string();
    }
    if let Ok(val) = std::env::var("FURPHY_TEST_RUN_VALUE_NAME") {
        return val;
    }
    if is_dev() {
        TEST_RUN_VALUE_NAME.to_string()
    } else {
        PRODUCTION_RUN_VALUE_NAME.to_string()
    }
}

pub fn get_current_exe_tray_command() -> Result<String, String> {
    let current_exe = std::env::current_exe().map_err(|e| e.to_string())?;
    Ok(format!("\"{}\" --tray", current_exe.to_string_lossy()))
}

pub fn is_autostart_enabled(test_override: Option<&str>) -> Result<bool, String> {
    // Strict dev safety (Phase 3.4): dev builds write no Run value unless an explicit test override is provided
    if is_dev() && test_override.is_none() && std::env::var("FURPHY_TEST_RUN_VALUE_NAME").is_err() {
        return Ok(false);
    }

    let val_name = get_run_value_name(test_override);

    #[cfg(windows)]
    {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let run_key = match hkcu.open_subkey_with_flags(
            r"Software\Microsoft\Windows\CurrentVersion\Run",
            KEY_READ,
        ) {
            Ok(k) => k,
            Err(_) => return Ok(false),
        };

        let cmd: Result<String, _> = run_key.get_value(&val_name);
        return Ok(cmd.is_ok());
    }

    #[cfg(not(windows))]
    Ok(false)
}

pub fn enable_autostart(test_override: Option<&str>) -> Result<(), String> {
    let dev = is_dev();
    let val_name = get_run_value_name(test_override);

    // Live-PC safety guard (ADR-307): dev builds MUST NEVER touch production Run value
    if dev && val_name == PRODUCTION_RUN_VALUE_NAME {
        return Err("Live-PC safety violation: dev build refused to write production Run value (ADR-307)".to_string());
    }

    // Strict dev safety (Phase 3.4): dev builds write no Run value unless an explicit test override is provided
    if dev && test_override.is_none() && std::env::var("FURPHY_TEST_RUN_VALUE_NAME").is_err() {
        crate::logging::append_app_log(
            "INFO",
            "Dev build: autostart registry write skipped (strict dev isolation)",
        );
        return Ok(());
    }

    #[cfg(windows)]
    {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let (run_key, _) = hkcu
            .create_subkey(r"Software\Microsoft\Windows\CurrentVersion\Run")
            .map_err(|e| format!("Failed to open Run registry key: {}", e))?;

        let cmd = get_current_exe_tray_command()?;
        run_key
            .set_value(&val_name, &cmd)
            .map_err(|e| format!("Failed to write Run value '{}': {}", val_name, e))?;

        crate::logging::append_app_log(
            "INFO",
            &format!("Autostart enabled for '{}': {}", val_name, cmd),
        );
        return Ok(());
    }

    #[cfg(not(windows))]
    Ok(())
}

pub fn disable_autostart(test_override: Option<&str>) -> Result<(), String> {
    let dev = is_dev();
    let val_name = get_run_value_name(test_override);

    // Live-PC safety guard (ADR-307)
    if dev && val_name == PRODUCTION_RUN_VALUE_NAME {
        return Err("Live-PC safety violation: dev build refused to delete production Run value (ADR-307)".to_string());
    }

    // Strict dev safety (Phase 3.4): dev builds touch no Run value unless an explicit test override is provided
    if dev && test_override.is_none() && std::env::var("FURPHY_TEST_RUN_VALUE_NAME").is_err() {
        crate::logging::append_app_log(
            "INFO",
            "Dev build: autostart registry delete skipped (strict dev isolation)",
        );
        return Ok(());
    }

    #[cfg(windows)]
    {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let run_key = match hkcu.open_subkey_with_flags(
            r"Software\Microsoft\Windows\CurrentVersion\Run",
            KEY_SET_VALUE,
        ) {
            Ok(k) => k,
            Err(_) => return Ok(()), // Key doesn't exist, nothing to disable
        };

        let _ = run_key.delete_value(&val_name);
        crate::logging::append_app_log("INFO", &format!("Autostart disabled for '{}'", val_name));
        return Ok(());
    }

    #[cfg(not(windows))]
    Ok(())
}

pub fn get_autostart_status(test_override: Option<&str>) -> Result<AutostartStatusDto, String> {
    let val_name = get_run_value_name(test_override);
    let enabled = is_autostart_enabled(test_override)?;

    #[cfg(windows)]
    let command = if enabled {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        if let Ok(run_key) = hkcu.open_subkey_with_flags(
            r"Software\Microsoft\Windows\CurrentVersion\Run",
            KEY_READ,
        ) {
            run_key.get_value::<String, _>(&val_name).ok()
        } else {
            None
        }
    } else {
        None
    };

    #[cfg(not(windows))]
    let command = None;

    Ok(AutostartStatusDto {
        enabled,
        value_name: val_name,
        command,
        is_dev: is_dev(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_autostart_value_name_isolation() {
        // In dev or test mode, value name should never be the production name
        let val_name = get_run_value_name(None);
        if is_dev() {
            assert_ne!(val_name, PRODUCTION_RUN_VALUE_NAME);
            assert_eq!(val_name, TEST_RUN_VALUE_NAME);
        }

        let custom = get_run_value_name(Some("FurphyCustomTest"));
        assert_eq!(custom, "FurphyCustomTest");
    }

    #[test]
    fn test_autostart_dev_safety_guard_blocks_production_tampering() {
        if is_dev() {
            let res = enable_autostart(Some(PRODUCTION_RUN_VALUE_NAME));
            assert!(res.is_err());
            assert!(res.unwrap_err().contains("Live-PC safety violation"));
        }
    }

    #[test]
    fn test_autostart_test_key_lifecycle() {
        let test_name = "FurphyTestLifecycleOnly";
        // Ensure clean before
        let _ = disable_autostart(Some(test_name));
        assert!(!is_autostart_enabled(Some(test_name)).unwrap());

        // Enable
        enable_autostart(Some(test_name)).unwrap();
        assert!(is_autostart_enabled(Some(test_name)).unwrap());

        // Disable
        disable_autostart(Some(test_name)).unwrap();
        assert!(!is_autostart_enabled(Some(test_name)).unwrap());
    }

    #[test]
    fn test_autostart_dev_skips_write_without_override() {
        if is_dev() {
            // Without test override or FURPHY_TEST_RUN_VALUE_NAME, enable_autostart must succeed without writing key
            let res = enable_autostart(None);
            assert!(res.is_ok());
            // Should report not enabled
            assert!(!is_autostart_enabled(None).unwrap());
            let status = get_autostart_status(None).unwrap();
            assert!(!status.enabled);
            assert!(status.command.is_none());
        }
    }
}
