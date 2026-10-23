use std::fs;
use std::path::PathBuf;
use serde::{Deserialize, Serialize};
use crate::paths::{get_data_dir, is_dev};
use crate::logging::append_app_log;
use crate::system::autostart::{get_current_exe_tray_command, PRODUCTION_RUN_VALUE_NAME};
use crate::system::protocol::{DEV_PROTOCOL, PRODUCTION_PROTOCOL};

#[cfg(windows)]
use winreg::enums::{HKEY_CURRENT_USER, KEY_READ, KEY_SET_VALUE};
#[cfg(windows)]
use winreg::RegKey;

pub const MOVED_NOTICE_FILENAME: &str = "MOVED-TO-V2.txt";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetirementSummary {
    pub v1_found: bool,
    pub v1_path: Option<String>,
    pub stopped_tray: bool,
    pub stopped_server: bool,
    pub replaced_autostart: bool,
    pub replaced_protocol: bool,
    pub replaced_shortcut: bool,
    pub replaced_apps_entry: bool,
    pub notice_written: bool,
    pub errors: Vec<String>,
}

pub struct RetireOptions {
    pub force_test: bool,
    pub custom_v1_path: Option<PathBuf>,
    pub test_run_value: Option<String>,
    pub test_protocol_scheme: Option<String>,
    pub test_desktop_dir: Option<PathBuf>,
    pub test_apps_entry: Option<String>,
}

impl Default for RetireOptions {
    fn default() -> Self {
        Self {
            force_test: false,
            custom_v1_path: None,
            test_run_value: None,
            test_protocol_scheme: None,
            test_desktop_dir: None,
            test_apps_entry: None,
        }
    }
}

pub fn generate_moved_notice_text() -> String {
    let data_dir = get_data_dir();
    format!(
        "Furphy Addon Manager has transitioned to version 2 (Tauri).\r\n\r\n\
        Your addon data, settings, backups, and logs are now stored in:\r\n  \
        {}\r\n\r\n\
        The files in this folder are maintained as a dual-write compatibility mirror\r\n\
        until Furphy v2.1.0.\r\n\r\n\
        How to rollback to v1.27.x:\r\n\
        If you need to return to Furphy v1, run FurphyAddonManager-Setup.exe from the v1.27.x release.\r\n\
        Your addon list and settings have been kept in sync and will load immediately.\r\n",
        data_dir.display()
    )
}

/// Signals the v1 tray to stop via the named Win32 Event 'FurphyAddonManager.TrayStop'
pub fn signal_v1_tray_stop(test_override: bool) -> bool {
    if is_dev() && !test_override && std::env::var("FURPHY_TEST_RETIRE_OVERRIDE").is_err() {
        append_app_log("INFO", "Dev mode: skipped signaling FurphyAddonManager.TrayStop (live-PC safety)");
        return false;
    }

    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Threading::{OpenEventW, SetEvent, EVENT_MODIFY_STATE};
        use std::ffi::OsStr;
        use std::os::windows::ffi::OsStrExt;

        let event_name: Vec<u16> = OsStr::new("FurphyAddonManager.TrayStop")
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();

        unsafe {
            let handle = OpenEventW(EVENT_MODIFY_STATE, 0, event_name.as_ptr());
            if handle != 0 {
                SetEvent(handle);
                windows_sys::Win32::Foundation::CloseHandle(handle);
                append_app_log("INFO", "Signaled v1 FurphyAddonManager.TrayStop event");
                return true;
            }
        }
    }
    false
}

/// Shuts down the v1 server by sending POST /api/shutdown with Origin: http://localhost:<port>
pub async fn send_v1_server_shutdown(port: u16, test_override: bool) -> bool {
    if is_dev() && !test_override && std::env::var("FURPHY_TEST_RETIRE_OVERRIDE").is_err() {
        append_app_log("INFO", "Dev mode: skipped sending POST /api/shutdown to v1 server (live-PC safety)");
        return false;
    }

    let url = format!("http://127.0.0.1:{}/api/shutdown", port);
    let origin = format!("http://localhost:{}", port);

    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(2))
        .build()
    {
        Ok(c) => c,
        Err(_) => return false,
    };

    match client.post(&url).header("Origin", origin).send().await {
        Ok(resp) => {
            append_app_log("INFO", &format!("Sent shutdown to v1 server on port {}, status: {}", port, resp.status()));
            true
        }
        Err(e) => {
            append_app_log("DEBUG", &format!("v1 server on port {} did not respond to shutdown: {}", port, e));
            false
        }
    }
}

/// Replaces the HKCU Run value if it currently points to v1
pub fn replace_v1_autostart(opts: &RetireOptions) -> Result<bool, String> {
    let dev = is_dev();
    if dev && !opts.force_test && opts.test_run_value.is_none() && std::env::var("FURPHY_TEST_RETIRE_OVERRIDE").is_err() {
        append_app_log("INFO", "Dev mode: skipped replacing HKCU Run value (live-PC safety)");
        return Ok(false);
    }

    let val_name = opts.test_run_value.clone().unwrap_or_else(|| {
        if dev {
            crate::system::autostart::TEST_RUN_VALUE_NAME.to_string()
        } else {
            PRODUCTION_RUN_VALUE_NAME.to_string()
        }
    });

    #[cfg(windows)]
    {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let run_key = hkcu.open_subkey_with_flags(
            r"Software\Microsoft\Windows\CurrentVersion\Run",
            KEY_READ | KEY_SET_VALUE,
        ).map_err(|e| format!("Failed opening Run key: {}", e))?;

        let current_cmd: Result<String, _> = run_key.get_value(&val_name);
        if let Ok(cmd) = current_cmd {
            let cmd_lower = cmd.to_lowercase();
            // Check if it points to v1 (e.g. AddonSync, FurphyHost, addon-server)
            let is_v1 = cmd_lower.contains("addonsync")
                || cmd_lower.contains("furphyhost")
                || cmd_lower.contains("addon-server")
                || opts.force_test;

            if is_v1 {
                let new_cmd = get_current_exe_tray_command()?;
                run_key.set_value(&val_name, &new_cmd)
                    .map_err(|e| format!("Failed updating Run key: {}", e))?;
                append_app_log("INFO", &format!("Replaced v1 autostart command for '{}': {}", val_name, new_cmd));
                return Ok(true);
            }
        }
    }

    #[cfg(not(windows))]
    {
        let _ = val_name;
    }

    Ok(false)
}

/// Replaces the curseforge:// protocol registration if it points to v1
pub fn replace_v1_protocol(opts: &RetireOptions) -> Result<bool, String> {
    let dev = is_dev();
    if dev && !opts.force_test && opts.test_protocol_scheme.is_none() && std::env::var("FURPHY_TEST_RETIRE_OVERRIDE").is_err() {
        append_app_log("INFO", "Dev mode: skipped replacing protocol handler (live-PC safety)");
        return Ok(false);
    }

    let scheme = opts.test_protocol_scheme.clone().unwrap_or_else(|| {
        if dev {
            DEV_PROTOCOL.to_string()
        } else {
            PRODUCTION_PROTOCOL.to_string()
        }
    });

    #[cfg(windows)]
    {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let subkey_path = format!(r"Software\Classes\{}\shell\open\command", scheme);
        if let Ok(cmd_key) = hkcu.open_subkey_with_flags(&subkey_path, KEY_READ | KEY_SET_VALUE) {
            let current_cmd: Result<String, _> = cmd_key.get_value("");
            if let Ok(cmd) = current_cmd {
                let cmd_lower = cmd.to_lowercase();
                let is_v1 = cmd_lower.contains("curseforge-handler")
                    || cmd_lower.contains("addonsync")
                    || cmd_lower.contains(".vbs")
                    || opts.force_test;

                if is_v1 {
                    let current_exe = std::env::current_exe().map_err(|e| e.to_string())?;
                    let new_cmd = format!("\"{}\" --protocol \"%1\"", current_exe.to_string_lossy());
                    cmd_key.set_value("", &new_cmd)
                        .map_err(|e| format!("Failed updating protocol command: {}", e))?;
                    append_app_log("INFO", &format!("Replaced v1 protocol registration for '{}': {}", scheme, new_cmd));
                    return Ok(true);
                }
            }
        }
    }

    #[cfg(not(windows))]
    {
        let _ = scheme;
    }

    Ok(false)
}

/// Replaces desktop shortcut if it points to v1 (§5.2 step 4)
pub fn replace_v1_desktop_shortcut(opts: &RetireOptions) -> Result<bool, String> {
    let desktop_dir = if let Some(ref d) = opts.test_desktop_dir {
        d.clone()
    } else {
        match dirs::desktop_dir() {
            Some(d) => d,
            None => return Ok(false),
        }
    };

    let shortcut_path = desktop_dir.join("Furphy Addon Manager.lnk");
    if !shortcut_path.exists() {
        return Ok(false);
    }

    let dev = is_dev();
    if dev && !opts.force_test && opts.test_desktop_dir.is_none() && std::env::var("FURPHY_TEST_RETIRE_OVERRIDE").is_err() {
        append_app_log("INFO", "Dev mode: skipped replacing desktop shortcut (live-PC safety)");
        return Ok(false);
    }

    let is_v1 = if opts.force_test {
        true
    } else {
        #[cfg(windows)]
        {
            let ps_check = format!(
                "$ws = New-Object -ComObject WScript.Shell; \
                 $sc = $ws.CreateShortcut('{}'); \
                 $sc.TargetPath",
                shortcut_path.display()
            );
            if let Ok(out) = std::process::Command::new("powershell")
                .args(["-NoProfile", "-NonInteractive", "-Command", &ps_check])
                .output()
            {
                let target = String::from_utf8_lossy(&out.stdout).to_lowercase();
                target.contains("addonsync") || target.contains("furphyhost") || target.contains(".vbs")
            } else {
                false
            }
        }
        #[cfg(not(windows))]
        {
            false
        }
    };

    if !is_v1 {
        append_app_log("INFO", &format!("Desktop shortcut '{}' does not point to v1; leaving untouched", shortcut_path.display()));
        return Ok(false);
    }

    // Replace shortcut target with current exe
    if let Ok(current_exe) = std::env::current_exe() {
        #[cfg(windows)]
        {
            let ps_script = format!(
                "$ws = New-Object -ComObject WScript.Shell; \
                 $sc = $ws.CreateShortcut('{}'); \
                 $sc.TargetPath = '{}'; \
                 $sc.Description = 'Furphy Addon Manager v2'; \
                 $sc.WorkingDirectory = '{}'; \
                 $sc.Save()",
                shortcut_path.display(),
                current_exe.display(),
                current_exe.parent().map(|p| p.display().to_string()).unwrap_or_default()
            );
            let _ = std::process::Command::new("powershell")
                .args(["-NoProfile", "-NonInteractive", "-Command", &ps_script])
                .output();
            append_app_log("INFO", &format!("Updated desktop shortcut at: {}", shortcut_path.display()));
            return Ok(true);
        }
    }

    Ok(false)
}

/// Replaces the v1 Installed-Apps registration if it points to v1 (§5.2 step 4)
pub fn replace_v1_apps_entry(opts: &RetireOptions) -> Result<bool, String> {
    let dev = is_dev();
    if dev && !opts.force_test && opts.test_apps_entry.is_none() && std::env::var("FURPHY_TEST_RETIRE_OVERRIDE").is_err() {
        append_app_log("INFO", "Dev mode: skipped replacing Apps uninstall entry (live-PC safety)");
        return Ok(false);
    }

    let subkey_name = opts.test_apps_entry.clone().unwrap_or_else(|| {
        r"Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager".to_string()
    });

    #[cfg(windows)]
    {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        if let Ok(entry_key) = hkcu.open_subkey_with_flags(&subkey_name, KEY_READ | KEY_SET_VALUE) {
            let install_loc: String = entry_key.get_value("InstallLocation").unwrap_or_default();
            let uninst_str: String = entry_key.get_value("UninstallString").unwrap_or_default();
            let is_v1 = install_loc.to_lowercase().contains("addonsync")
                || uninst_str.to_lowercase().contains("addonsync")
                || install_loc.to_lowercase().contains("furphyhost")
                || opts.force_test;

            if is_v1 {
                if let Ok(current_exe) = std::env::current_exe() {
                    let install_dir = current_exe.parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
                    let _ = entry_key.set_value("DisplayName", &crate::system::setup::APP_TITLE);
                    let _ = entry_key.set_value("DisplayVersion", &crate::system::setup::CURRENT_VERSION);
                    let _ = entry_key.set_value("Publisher", &"Eric Krenz");
                    let _ = entry_key.set_value("InstallLocation", &install_dir);
                    let _ = entry_key.set_value("DisplayIcon", &format!("\"{}\",0", current_exe.to_string_lossy()));
                    let _ = entry_key.set_value("UninstallString", &format!("\"{}\" --uninstall", current_exe.to_string_lossy()));
                    let _ = entry_key.set_value("QuietUninstallString", &format!("\"{}\" --uninstall /S", current_exe.to_string_lossy()));
                    append_app_log("INFO", &format!("Replaced v1 Apps uninstall entry at '{}'", subkey_name));
                    return Ok(true);
                }
            }
        }
    }

    #[cfg(not(windows))]
    {
        let _ = subkey_name;
    }

    Ok(false)
}

/// Executes the full Section 5.2 v1 retirement sequence on a detected or specified v1 installation
pub async fn retire_v1(opts: RetireOptions) -> RetirementSummary {
    let mut summary = RetirementSummary {
        v1_found: false,
        v1_path: None,
        stopped_tray: false,
        stopped_server: false,
        replaced_autostart: false,
        replaced_protocol: false,
        replaced_shortcut: false,
        replaced_apps_entry: false,
        notice_written: false,
        errors: Vec::new(),
    };

    // 1. Locate v1 folder
    let v1_dir = if let Some(ref p) = opts.custom_v1_path {
        Some(p.clone())
    } else if let Ok(wow_root) = crate::paths::detect_wow_root(None) {
        let default_v1 = crate::paths::get_v1_sync_folder(&wow_root);
        if default_v1.exists() {
            Some(default_v1)
        } else {
            None
        }
    } else {
        None
    };

    let v1_dir = match v1_dir {
        Some(d) if d.is_dir() => d,
        _ => {
            append_app_log("INFO", "Retire v1: No existing v1 installation found to retire");
            return summary;
        }
    };

    summary.v1_found = true;
    summary.v1_path = Some(v1_dir.display().to_string());
    append_app_log("INFO", &format!("Beginning v1 retirement sequence for: {}", v1_dir.display()));

    // 2. Stop v1 tray and server
    summary.stopped_tray = signal_v1_tray_stop(opts.force_test);

    // Read port from settings.json if present (default 47831)
    let port = {
        let settings_file = v1_dir.join("settings.json");
        let mut p = 47831u16;
        if let Ok(content) = fs::read_to_string(&settings_file) {
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                if let Some(port_num) = val.get("port").and_then(|v| v.as_u64()) {
                    p = port_num as u16;
                }
            }
        }
        p
    };

    summary.stopped_server = send_v1_server_shutdown(port, opts.force_test).await;

    // 3. Replace registrations
    match replace_v1_autostart(&opts) {
        Ok(replaced) => summary.replaced_autostart = replaced,
        Err(e) => {
            append_app_log("ERROR", &format!("Retire v1 autostart replacement failed: {}", e));
            summary.errors.push(e);
        }
    }

    match replace_v1_protocol(&opts) {
        Ok(replaced) => summary.replaced_protocol = replaced,
        Err(e) => {
            append_app_log("ERROR", &format!("Retire v1 protocol replacement failed: {}", e));
            summary.errors.push(e);
        }
    }

    match replace_v1_desktop_shortcut(&opts) {
        Ok(replaced) => summary.replaced_shortcut = replaced,
        Err(e) => {
            append_app_log("ERROR", &format!("Retire v1 desktop shortcut replacement failed: {}", e));
            summary.errors.push(e);
        }
    }

    match replace_v1_apps_entry(&opts) {
        Ok(replaced) => summary.replaced_apps_entry = replaced,
        Err(e) => {
            append_app_log("ERROR", &format!("Retire v1 apps entry replacement failed: {}", e));
            summary.errors.push(e);
        }
    }

    // 4. Write MOVED-TO-V2.txt into the v1 folder
    let notice_file = v1_dir.join(MOVED_NOTICE_FILENAME);
    let notice_text = generate_moved_notice_text();
    match fs::write(&notice_file, notice_text) {
        Ok(_) => {
            summary.notice_written = true;
            append_app_log("INFO", &format!("Wrote {}", notice_file.display()));
        }
        Err(e) => {
            let msg = format!("Failed writing MOVED-TO-V2.txt: {}", e);
            append_app_log("ERROR", &msg);
            summary.errors.push(msg);
        }
    }

    append_app_log("INFO", "v1 retirement sequence completed successfully");
    summary
}

pub fn retire_v1_blocking(opts: RetireOptions) -> RetirementSummary {
    if let Ok(rt) = tokio::runtime::Runtime::new() {
        rt.block_on(retire_v1(opts))
    } else {
        RetirementSummary {
            v1_found: false,
            v1_path: None,
            stopped_tray: false,
            stopped_server: false,
            replaced_autostart: false,
            replaced_protocol: false,
            replaced_shortcut: false,
            replaced_apps_entry: false,
            notice_written: false,
            errors: vec!["Failed creating Tokio runtime for retire_v1".to_string()],
        }
    }
}
