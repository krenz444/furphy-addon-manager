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

pub fn get_default_install_dir() -> PathBuf {
    if let Some(local_app_data) = dirs::data_local_dir() {
        local_app_data.join("Programs").join(APP_TITLE)
    } else {
        PathBuf::from(r"C:\Program Files").join(APP_TITLE)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SetupMessageKind {
    Error,
    Warning,
    Question,
}

pub const IDYES: i32 = 6;

#[cfg(windows)]
fn to_wide(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
}

/// Shows a modal message box titled "Furphy Addon Manager Setup" and returns the id of
/// the button pressed (IDYES = 6). The release exe is a GUI-subsystem binary, so this is
/// the only way an installer failure reaches the user.
pub fn show_setup_message(text: &str, kind: SetupMessageKind) -> i32 {
    show_message("Furphy Addon Manager Setup", text, kind)
}

/// Like `show_setup_message` with a caller-chosen title. No MB_SETFOREGROUND or
/// MB_TOPMOST: a box raised by the tray must not take focus from a running game.
pub fn show_message(title: &str, text: &str, kind: SetupMessageKind) -> i32 {
    #[cfg(windows)]
    {
        use windows_sys::Win32::UI::WindowsAndMessaging::{
            MessageBoxW, MB_ICONERROR, MB_ICONQUESTION, MB_ICONWARNING, MB_OK, MB_YESNO,
        };
        let flags = match kind {
            SetupMessageKind::Error => MB_ICONERROR | MB_OK,
            SetupMessageKind::Warning => MB_ICONWARNING | MB_OK,
            SetupMessageKind::Question => MB_ICONQUESTION | MB_YESNO,
        };
        let wtext = to_wide(text);
        let wtitle = to_wide(title);
        unsafe { MessageBoxW(0, wtext.as_ptr(), wtitle.as_ptr(), flags) }
    }

    #[cfg(not(windows))]
    {
        let _ = (title, text, kind);
        0
    }
}

/// A console tool started from this GUI-subsystem exe would otherwise flash a console window.
#[cfg(windows)]
fn hidden_command(program: &str) -> std::process::Command {
    use std::os::windows::process::CommandExt;
    let mut cmd = std::process::Command::new(program);
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    cmd
}

/// Reads the Evergreen WebView2 runtime version using Microsoft's documented registry check.
pub fn webview2_runtime_version() -> Option<String> {
    #[cfg(windows)]
    {
        use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
        const GUID: &str = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
        let candidates = [
            (HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients"),
            (HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\EdgeUpdate\Clients"),
            (HKEY_CURRENT_USER, r"Software\Microsoft\EdgeUpdate\Clients"),
        ];
        for (hive, base) in candidates {
            let root = RegKey::predef(hive);
            if let Ok(key) = root.open_subkey(format!(r"{}\{}", base, GUID)) {
                if let Ok(pv) = key.get_value::<String, _>("pv") {
                    let pv = pv.trim().to_string();
                    if !pv.is_empty() && pv != "0.0.0.0" {
                        return Some(pv);
                    }
                }
            }
        }
        None
    }

    #[cfg(not(windows))]
    {
        None
    }
}

pub const WEBVIEW2_DOWNLOAD_URL: &str = "https://go.microsoft.com/fwlink/p/?LinkId=2124703";

pub fn open_url(url: &str) {
    #[cfg(windows)]
    {
        use windows_sys::Win32::UI::Shell::ShellExecuteW;
        use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
        let verb = to_wide("open");
        let wurl = to_wide(url);
        unsafe {
            ShellExecuteW(
                0,
                verb.as_ptr(),
                wurl.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                SW_SHOWNORMAL,
            );
        }
    }
    #[cfg(not(windows))]
    {
        let _ = url;
    }
}

#[cfg(windows)]
fn create_shortcut_com(target_exe: &Path, shortcut_path: &Path, description: &str) -> Result<(), String> {
    use windows::core::{Interface, HSTRING};
    use windows::Win32::Foundation::{RPC_E_CHANGED_MODE, S_FALSE};
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, IPersistFile, CLSCTX_INPROC_SERVER,
        COINIT_APARTMENTTHREADED,
    };
    use windows::Win32::UI::Shell::{IShellLinkW, ShellLink};

    // S_OK and S_FALSE both add a reference we must release; RPC_E_CHANGED_MODE means
    // the thread already runs in another apartment model and we must not uninitialize.
    let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
    let we_initialized = if hr.is_ok() || hr == S_FALSE {
        true
    } else if hr == RPC_E_CHANGED_MODE {
        false
    } else {
        return Err(format!("CoInitializeEx failed: {}", hr.message()));
    };

    let result = (|| -> windows::core::Result<()> {
        unsafe {
            let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
            link.SetPath(&HSTRING::from(target_exe.as_os_str()))?;
            link.SetDescription(&HSTRING::from(description))?;
            if let Some(dir) = target_exe.parent() {
                link.SetWorkingDirectory(&HSTRING::from(dir.as_os_str()))?;
            }
            link.SetIconLocation(&HSTRING::from(target_exe.as_os_str()), 0)?;
            let file: IPersistFile = link.cast()?;
            file.Save(&HSTRING::from(shortcut_path.as_os_str()), true)?;
        }
        Ok(())
    })();

    if we_initialized {
        unsafe { CoUninitialize() };
    }
    result.map_err(|e| format!("COM shortcut creation failed: {}", e))
}

pub fn create_shortcut(target_exe: &Path, shortcut_path: &Path, description: &str) -> Result<(), String> {
    #[cfg(windows)]
    {
        if let Some(parent) = shortcut_path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        match create_shortcut_com(target_exe, shortcut_path, description) {
            Ok(()) => return Ok(()),
            Err(e) => {
                append_app_log("WARN", &format!("{}; falling back to PowerShell", e));
            }
        }
        create_shortcut_powershell(target_exe, shortcut_path, description)
    }

    #[cfg(not(windows))]
    {
        let _ = (target_exe, shortcut_path, description);
        Ok(())
    }
}

#[cfg(windows)]
fn create_shortcut_powershell(target_exe: &Path, shortcut_path: &Path, description: &str) -> Result<(), String> {
    {
        let working_dir = target_exe.parent().map(|p| p.display().to_string()).unwrap_or_default();
        let p_esc = shortcut_path.to_string_lossy().replace("'", "''");
        let t_esc = target_exe.to_string_lossy().replace("'", "''");
        let d_esc = description.replace("'", "''");
        let w_esc = working_dir.replace("'", "''");

        let script = format!(
            "$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut('{}'); $sc.TargetPath = '{}'; $sc.Description = '{}'; $sc.WorkingDirectory = '{}'; $sc.Save()",
            p_esc, t_esc, d_esc, w_esc
        );

        let output = hidden_command("powershell")
            .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", &script])
            .output()
            .map_err(|e| format!("Failed executing shortcut script: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("Shortcut creation failed: {}", stderr));
        }
        Ok(())
    }
}

/// Desktop and Start Menu shortcut paths. With an install-dir override (tests) they live in
/// a folder beside that install dir and the registry is left alone, so a test run never
/// replaces or deletes the shortcuts and Installed Apps entry of the copy on this PC.
fn shortcut_paths(sandbox_root: Option<&Path>) -> (Option<PathBuf>, Option<PathBuf>) {
    let name = format!("{}.lnk", APP_TITLE);
    if let Some(root) = sandbox_root {
        let base = root.join("test-shortcuts");
        return (
            Some(base.join("Desktop").join(&name)),
            Some(base.join("Start Menu").join(&name)),
        );
    }
    (
        dirs::desktop_dir().map(|d| d.join(&name)),
        dirs::data_dir().map(|d| d.join(r"Microsoft\Windows\Start Menu\Programs").join(&name)),
    )
}

/// Shortcut root for a sandboxed run: the install dir's parent, or the install dir itself
/// when it has none, so a sandboxed run can never fall through to the real profile.
fn sandbox_root(sandboxed: bool, install_dir: &Path) -> Option<&Path> {
    if sandboxed {
        Some(install_dir.parent().unwrap_or(install_dir))
    } else {
        None
    }
}

/// Executes the installer lifecycle (§5.1): copies files, creates shortcuts, registers Apps uninstall entry
pub fn run_install(silent: bool, relaunch_tray: bool, target_dir_override: Option<PathBuf>) -> Result<(), String> {
    let is_test = target_dir_override.is_some() || std::env::var("FURPHY_TEST_SETUP_OVERRIDE").is_ok();
    let install_dir = target_dir_override.clone().unwrap_or_else(get_default_install_dir);

    let result = run_install_steps(silent, target_dir_override);

    // A background update (/S --relaunch-tray) has already closed the running app, so
    // whatever happened, start the version now in place again in the tray: the new one
    // after a success, the old one if the copy failed. If WebView2 is really missing,
    // the app itself explains that on start.
    #[cfg(windows)]
    if silent && relaunch_tray && !is_test && !is_dev() {
        let dest_exe = install_dir.join(format!("{}.exe", APP_TITLE));
        if dest_exe.exists() {
            use std::os::windows::process::CommandExt;
            use std::process::Stdio;
            const DETACHED_PROCESS: u32 = 0x0000_0008;
            const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            match std::process::Command::new(&dest_exe)
                .arg("--tray")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW)
                .spawn()
            {
                Ok(_) if result.is_ok() => append_app_log("INFO", "Restarted Furphy in the tray after the update"),
                Ok(_) => append_app_log("WARN", "Update failed; restarted the installed version in the tray"),
                Err(e) => append_app_log("WARN", &format!("Could not restart Furphy in the tray: {}", e)),
            }
        }
    }
    #[cfg(not(windows))]
    let _ = (relaunch_tray, &install_dir, is_test);

    result
}

fn run_install_steps(silent: bool, target_dir_override: Option<PathBuf>) -> Result<(), String> {
    let dev = is_dev();
    let sandboxed = target_dir_override.is_some();
    let is_test = sandboxed || std::env::var("FURPHY_TEST_SETUP_OVERRIDE").is_ok();
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
        #[cfg(windows)]
        if !is_test {
            // Exclude this process: an installer started as "Furphy Addon Manager.exe"
            // from another folder would otherwise kill itself.
            let _ = hidden_command("taskkill")
                .args([
                    "/F",
                    "/IM",
                    &format!("{}.exe", APP_TITLE),
                    "/FI",
                    &format!("PID ne {}", std::process::id()),
                ])
                .output();
            std::thread::sleep(std::time::Duration::from_millis(300));
        }

        // taskkill only requests termination; the old process can keep the file locked for a moment.
        const COPY_ATTEMPTS: u32 = 20;
        let mut last_err = None;
        for attempt in 1..=COPY_ATTEMPTS {
            match fs::copy(&current_exe, &dest_exe) {
                Ok(_) => {
                    if attempt > 1 {
                        append_app_log("INFO", &format!("Copied binary after {} attempts", attempt));
                    }
                    last_err = None;
                    break;
                }
                Err(e) => {
                    last_err = Some(e);
                    if attempt < COPY_ATTEMPTS {
                        std::thread::sleep(std::time::Duration::from_millis(250));
                    }
                }
            }
        }
        if let Some(e) = last_err {
            return Err(format!(
                "Failed copying binary to '{}' after {} attempts: {}",
                dest_exe.display(), COPY_ATTEMPTS, e
            ));
        }
    }

    // Unpack embedded runtime dependencies alongside the executable
    // The app delay-loads this DLL; without it the window cannot be created, so a failed write is fatal.
    let dest_wv2 = install_dir.join("WebView2Loader.dll");
    let already_current = fs::read(&dest_wv2).map(|b| b == EMBEDDED_WEBVIEW2).unwrap_or(false);
    if !already_current {
        fs::write(&dest_wv2, EMBEDDED_WEBVIEW2)
            .map_err(|e| format!("Failed writing '{}': {}", dest_wv2.display(), e))?;
    }
    // Older versions shipped libunwind.dll next to the exe; it is no longer needed.
    let _ = fs::remove_file(install_dir.join("libunwind.dll"));

    // 1. Desktop and Start Menu shortcuts
    let (desktop_lnk, start_menu_lnk) = shortcut_paths(sandbox_root(sandboxed, &install_dir));
    for (label, sc_path) in [("desktop", desktop_lnk), ("start menu", start_menu_lnk)] {
        if let Some(sc_path) = sc_path {
            if let Err(e) = create_shortcut(&dest_exe, &sc_path, "Furphy Addon Manager v2") {
                append_app_log("WARN", &format!("Failed creating {} shortcut: {}", label, e));
            } else {
                append_app_log("INFO", &format!("Created {} shortcut: {}", label, sc_path.display()));
            }
        }
    }

    // 2. Register Installed-Apps entry in HKCU Uninstall
    #[cfg(windows)]
    if !sandboxed {
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

    let webview2_missing = !is_test && webview2_runtime_version().is_none();
    if webview2_missing {
        append_app_log("WARN", "Microsoft Edge WebView2 Runtime not found; Furphy cannot open until it is installed");
    }

    if !silent {
        // Interactive install: launch installed binary
        #[cfg(windows)]
        {
            let mut launch = true;
            if webview2_missing {
                let answer = show_setup_message(
                    "Furphy needs the Microsoft Edge WebView2 Runtime, which isn't installed on this PC. Furphy is installed, but it can't open until the runtime is installed.\n\nOpen Microsoft's download page now?",
                    SetupMessageKind::Question,
                );
                if answer == IDYES {
                    open_url(WEBVIEW2_DOWNLOAD_URL);
                    launch = false;
                }
            }
            if launch {
                let _ = std::process::Command::new(&dest_exe).spawn();
            }
        }
    }

    Ok(())
}

/// Executes the keep-your-data uninstaller (§5.1): removes shortcuts, binaries, and registry, but leaves data folder intact
pub fn run_uninstall(silent: bool, target_dir_override: Option<PathBuf>) -> Result<(), String> {
    let dev = is_dev();
    let sandboxed = target_dir_override.is_some();
    let is_test = sandboxed || std::env::var("FURPHY_TEST_SETUP_OVERRIDE").is_ok();
    if dev && !is_test {
        append_app_log("INFO", "Dev mode: skipped production uninstallation (live-PC safety)");
        return Ok(());
    }
    let install_dir = target_dir_override.unwrap_or_else(get_default_install_dir);

    // 1. Remove Desktop and Start Menu shortcuts
    let (desktop_lnk, start_menu_lnk) = shortcut_paths(sandbox_root(sandboxed, &install_dir));
    for sc_path in [desktop_lnk, start_menu_lnk].into_iter().flatten() {
        let _ = fs::remove_file(sc_path);
    }

    // 2. Remove HKCU Uninstall registration
    #[cfg(windows)]
    if !sandboxed {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let _ = hkcu.delete_subkey(UNINSTALL_REG_KEY_NAME);
        let _ = hkcu.delete_subkey(LEGACY_SPACED_REG_KEY);
    }

    // 3. Remove binaries in install directory
    if install_dir.exists() {
        let _ = fs::remove_dir_all(&install_dir);
    }

    // 5. User data folder (%LOCALAPPDATA%\krenzcreative.furphy.addonmanager) is KEPT
    let data_dir = get_data_dir();
    append_app_log("INFO", &format!("Uninstalled Furphy v2. Kept user data in '{}'", data_dir.display()));

    let _ = silent;
    Ok(())
}
