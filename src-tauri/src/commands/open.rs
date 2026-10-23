use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use reqwest::Url;
use crate::paths::{detect_wow_root, get_data_dir};

pub fn open_url_or_file(target: &str) -> Result<(), String> {
    if std::env::var("FURPHY_TEST_NO_SPAWN").is_ok() {
        return Ok(());
    }
    let wide_target: Vec<u16> = OsStr::new(target).encode_wide().chain(Some(0)).collect();
    let wide_open: Vec<u16> = OsStr::new("open").encode_wide().chain(Some(0)).collect();
    unsafe {
        let ret = windows_sys::Win32::UI::Shell::ShellExecuteW(
            0,
            wide_open.as_ptr(),
            wide_target.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL,
        );
        if (ret as usize) <= 32 {
            std::process::Command::new("rundll32")
                .args(["url.dll,FileProtocolHandler", target])
                .spawn()
                .map_err(|e| format!("Failed to open target (ShellExecute code {}, error {})", ret as usize, e))?;
        }
    }
    Ok(())
}

pub fn open_folder_path(path: &Path) -> Result<(), String> {
    if std::env::var("FURPHY_TEST_NO_SPAWN").is_ok() {
        return Ok(());
    }
    if !path.exists() {
        if let Some(parent) = path.parent() {
            if parent.exists() {
                return open_folder_path(parent);
            }
        }
    }
    let wide_target: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let wide_explore: Vec<u16> = OsStr::new("explore").encode_wide().chain(Some(0)).collect();
    unsafe {
        let ret = windows_sys::Win32::UI::Shell::ShellExecuteW(
            0,
            wide_explore.as_ptr(),
            wide_target.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL,
        );
        if (ret as usize) <= 32 {
            std::process::Command::new("explorer")
                .arg(path)
                .spawn()
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[tauri::command]
pub fn open_target(what: String, args: Option<serde_json::Value>) -> Result<(), String> {
    let arg_str = match args {
        Some(serde_json::Value::String(s)) => Some(s),
        Some(serde_json::Value::Array(ref arr)) => {
            arr.first().and_then(|v| v.as_str().map(|s| s.to_string()))
        }
        _ => None,
    };

    match what.as_str() {
        "url" => {
            let url_str = arg_str.ok_or("URL argument is required")?;
            let parsed = Url::parse(&url_str).map_err(|e| format!("Invalid URL: {}", e))?;
            if parsed.scheme() != "http" && parsed.scheme() != "https" {
                return Err("Only HTTP/HTTPS URLs are allowed".into());
            }
            let host = parsed.host_str().unwrap_or("").to_ascii_lowercase();
            let allowed_hosts = [
                "curseforge.com",
                "www.curseforge.com",
                "addons.wago.io",
                "wago.io",
                "github.com",
                "raw.githubusercontent.com",
            ];
            if !allowed_hosts.contains(&host.as_str())
                && !host.ends_with(".curseforge.com")
                && !host.ends_with(".wago.io")
                && !host.ends_with(".github.com")
            {
                return Err(format!("Host '{}' is not in the allowlist", host));
            }
            open_url_or_file(&url_str)
        }
        "wowfolder" => {
            let wow_root = detect_wow_root(None).map_err(|e| e.to_string())?;
            open_folder_path(&wow_root)
        }
        "addons" => {
            let wow_root = detect_wow_root(None).map_err(|e| e.to_string())?;
            let flv = arg_str.unwrap_or_else(|| "retail".into());
            let flv_folder = if flv.starts_with('_') {
                flv
            } else {
                format!("_{}_", flv)
            };
            let addons_path = wow_root.join(flv_folder).join("Interface").join("AddOns");
            open_folder_path(&addons_path)
        }
        "datafolder" => {
            let data_dir = get_data_dir();
            open_folder_path(&data_dir)
        }
        "logs" | "log" | "serverlog" => {
            let data_dir = get_data_dir();
            let app_log = data_dir.join("app.log");
            if app_log.exists() {
                open_url_or_file(&app_log.to_string_lossy())
            } else {
                open_folder_path(&data_dir)
            }
        }
        "lastrun" => {
            let last_run = get_data_dir().join("last-run.txt");
            if last_run.exists() {
                open_url_or_file(&last_run.to_string_lossy())
            } else {
                open_folder_path(&get_data_dir())
            }
        }
        "backups" => {
            let backups = get_data_dir().join("backups");
            open_folder_path(&backups)
        }
        "snapshots" => {
            let wtf = get_data_dir().join("wtf_snapshots");
            open_folder_path(&wtf)
        }
        "migration-backup" => {
            let mig = get_data_dir().join("migration_backups");
            open_folder_path(&mig)
        }
        _ => Err(format!("Unknown open target: {}", what)),
    }
}
