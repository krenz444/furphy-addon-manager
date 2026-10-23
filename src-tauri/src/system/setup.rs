use std::fs;
use std::path::{Path, PathBuf};
use crate::paths::{get_data_dir, is_dev};
use crate::logging::append_app_log;

#[cfg(windows)]
use winreg::enums::HKEY_CURRENT_USER;
#[cfg(windows)]
use winreg::RegKey;

pub const UNINSTALL_REG_KEY_NAME: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager";
pub const LEGACY_SPACED_REG_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Furphy Addon Manager";
pub const APP_TITLE: &str = "Furphy Addon Manager";
pub const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

const EMBEDDED_WEBVIEW2: &[u8] = include_bytes!("../../resources/WebView2Loader.dll");
const EMBEDDED_LIBUNWIND: &[u8] = include_bytes!("../../resources/libunwind.dll");

pub fn get_default_install_dir() -> PathBuf {
    if let Some(local_app_data) = dirs::data_local_dir() {
        local_app_data.join("Programs").join(APP_TITLE)
    } else {
        PathBuf::from(r"C:\Program Files").join(APP_TITLE)
    }
}

pub fn create_shortcut(target_exe: &Path, shortcut_path: &Path, description: &str) -> Result<(), String> {
    #[cfg(windows)]
    {
        if let Some(parent) = shortcut_path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let working_dir = target_exe.parent().map(|p| p.display().to_string()).unwrap_or_default();
        let p_esc = shortcut_path.to_string_lossy().replace("'", "''");
        let t_esc = target_exe.to_string_lossy().replace("'", "''");
        let d_esc = description.replace("'", "''");
        let w_esc = working_dir.replace("'", "''");

        let script = format!(
            "$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut('{}'); $sc.TargetPath = '{}'; $sc.Description = '{}'; $sc.WorkingDirectory = '{}'; $sc.Save()",
            p_esc, t_esc, d_esc, w_esc
        );

        let output = std::process::Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", &script])
            .output()
            .map_err(|e| format!("Failed executing shortcut script: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("Shortcut creation failed: {}", stderr));
        }
        Ok(())
    }

    #[cfg(not(windows))]
    {
        let _ = (target_exe, shortcut_path, description);
        Ok(())
    }
}

/// Executes the installer lifecycle (§5.1): copies files, creates shortcuts, registers Apps uninstall entry
pub fn run_install(silent: bool, target_dir_override: Option<PathBuf>) -> Result<(), String> {
    let dev = is_dev();
    let is_test = target_dir_override.is_some() || std::env::var("FURPHY_TEST_SETUP_OVERRIDE").is_ok();
    if dev && !is_test {
        append_app_log("INFO", "Dev mode: skipped production installation (live-PC safety)");
        return Ok(());
    }

    let install_dir = target_dir_override.unwrap_or_else(get_default_install_dir);
    fs::create_dir_all(&install_dir)
        .map_err(|e| format!("Failed creating install directory '{}': {}", install_dir.display(), e))?;

    let current_exe = std::env::current_exe()
        .map_err(|e| format!("Failed determining current executable: {}", e))?;

    let dest_exe = install_dir.join(format!("{}.exe", APP_TITLE));

    // Copy executable if not already running from the destination
    if current_exe != dest_exe {
        fs::copy(&current_exe, &dest_exe)
            .map_err(|e| format!("Failed copying binary to '{}': {}", dest_exe.display(), e))?;
    }

    // Unpack embedded runtime dependencies alongside the executable
    let dest_wv2 = install_dir.join("WebView2Loader.dll");
    let _ = fs::write(&dest_wv2, EMBEDDED_WEBVIEW2);
    let dest_unwind = install_dir.join("libunwind.dll");
    let _ = fs::write(&dest_unwind, EMBEDDED_LIBUNWIND);

    // 1. Create Desktop Shortcut
    if let Some(desktop) = dirs::desktop_dir() {
        let sc_path = desktop.join(format!("{}.lnk", APP_TITLE));
        if let Err(e) = create_shortcut(&dest_exe, &sc_path, "Furphy Addon Manager v2") {
            append_app_log("WARN", &format!("Failed creating desktop shortcut: {}", e));
        } else {
            append_app_log("INFO", &format!("Created desktop shortcut: {}", sc_path.display()));
        }
    }

    // 2. Create Start Menu Shortcut
    if let Some(data_dir) = dirs::data_dir() {
        // %APPDATA%\Microsoft\Windows\Start Menu\Programs\
        let start_menu = data_dir.join(r"Microsoft\Windows\Start Menu\Programs");
        let sc_path = start_menu.join(format!("{}.lnk", APP_TITLE));
        if let Err(e) = create_shortcut(&dest_exe, &sc_path, "Furphy Addon Manager v2") {
            append_app_log("WARN", &format!("Failed creating start menu shortcut: {}", e));
        } else {
            append_app_log("INFO", &format!("Created start menu shortcut: {}", sc_path.display()));
        }
    }

    // 3. Register Installed-Apps entry in HKCU Uninstall
    #[cfg(windows)]
    {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        if let Ok((key, _)) = hkcu.create_subkey(UNINSTALL_REG_KEY_NAME) {
            let _ = key.set_value("DisplayName", &APP_TITLE);
            let _ = key.set_value("DisplayVersion", &CURRENT_VERSION);
            let _ = key.set_value("Publisher", &"Eric Krenz");
            let _ = key.set_value("InstallLocation", &install_dir.to_string_lossy().to_string());
            let icon_str = format!("\"{}\",0", dest_exe.to_string_lossy());
            let _ = key.set_value("DisplayIcon", &icon_str);
            let uninst_cmd = format!("\"{}\" --uninstall", dest_exe.to_string_lossy());
            let _ = key.set_value("UninstallString", &uninst_cmd);
            let quiet_uninst = format!("\"{}\" --uninstall /S", dest_exe.to_string_lossy());
            let _ = key.set_value("QuietUninstallString", &quiet_uninst);
            let dword_one: u32 = 1;
            let _ = key.set_value("NoModify", &dword_one);
            let _ = key.set_value("NoRepair", &dword_one);
        }
        let _ = hkcu.delete_subkey(LEGACY_SPACED_REG_KEY);
    }

    append_app_log("INFO", &format!("Installed Furphy v2 into '{}'", install_dir.display()));

    if !silent {
        // Interactive install: launch installed binary
        #[cfg(windows)]
        {
            let _ = std::process::Command::new(&dest_exe).spawn();
        }
    }

    Ok(())
}

/// Executes the keep-your-data uninstaller (§5.1): removes shortcuts, binaries, and registry, but leaves data folder intact
pub fn run_uninstall(silent: bool, target_dir_override: Option<PathBuf>) -> Result<(), String> {
    let dev = is_dev();
    let is_test = target_dir_override.is_some() || std::env::var("FURPHY_TEST_SETUP_OVERRIDE").is_ok();
    if dev && !is_test {
        append_app_log("INFO", "Dev mode: skipped production uninstallation (live-PC safety)");
        return Ok(());
    }

    // 1. Remove Desktop Shortcut
    if let Some(desktop) = dirs::desktop_dir() {
        let sc_path = desktop.join(format!("{}.lnk", APP_TITLE));
        let _ = fs::remove_file(sc_path);
    }

    // 2. Remove Start Menu Shortcut
    if let Some(data_dir) = dirs::data_dir() {
        let start_menu = data_dir.join(r"Microsoft\Windows\Start Menu\Programs");
        let sc_path = start_menu.join(format!("{}.lnk", APP_TITLE));
        let _ = fs::remove_file(sc_path);
    }

    // 3. Remove HKCU Uninstall registration
    #[cfg(windows)]
    {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let _ = hkcu.delete_subkey(UNINSTALL_REG_KEY_NAME);
        let _ = hkcu.delete_subkey(LEGACY_SPACED_REG_KEY);
    }

    // 4. Remove binaries in install directory
    let install_dir = target_dir_override.unwrap_or_else(get_default_install_dir);
    if install_dir.exists() {
        let _ = fs::remove_dir_all(&install_dir);
    }

    // 5. User data folder (%LOCALAPPDATA%\krenzcreative.furphy.addonmanager) is KEPT
    let data_dir = get_data_dir();
    append_app_log("INFO", &format!("Uninstalled Furphy v2. Kept user data in '{}'", data_dir.display()));

    let _ = silent;
    Ok(())
}
