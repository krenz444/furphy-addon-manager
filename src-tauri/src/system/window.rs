use std::sync::Mutex;
use std::time::{Duration, Instant};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

#[cfg(windows)]
use windows_sys::Win32::Foundation::{BOOL, HWND};
#[cfg(windows)]
use windows_sys::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
#[cfg(windows)]
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BringWindowToTop, FlashWindowEx, GetForegroundWindow, GetWindowThreadProcessId,
    SetForegroundWindow, ShowWindow, FLASHWINFO, FLASHW_ALL, SW_RESTORE, SW_SHOW,
};

#[cfg(windows)]
pub struct SingleInstanceGuard {
    handle: windows_sys::Win32::Foundation::HANDLE,
}

#[cfg(windows)]
impl Drop for SingleInstanceGuard {
    fn drop(&mut self) {
        if self.handle != 0 {
            unsafe {
                windows_sys::Win32::Foundation::CloseHandle(self.handle);
            }
        }
    }
}

#[cfg(not(windows))]
pub struct SingleInstanceGuard;

pub fn acquire_single_instance_mutex() -> Result<Option<SingleInstanceGuard>, String> {
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS};
        use windows_sys::Win32::System::Threading::CreateMutexW;

        let mutex_name = if crate::paths::is_dev() {
            "Local\\FurphyAddonManager_Dev_SingleInstance\0"
        } else {
            "Local\\FurphyAddonManager_SingleInstance\0"
        };

        let wide_name: Vec<u16> = mutex_name.encode_utf16().collect();
        let handle = unsafe {
            CreateMutexW(std::ptr::null(), 1, wide_name.as_ptr())
        };

        if handle == 0 {
            return Err("Failed to create single-instance mutex".to_string());
        }

        let err = unsafe { GetLastError() };
        if err == ERROR_ALREADY_EXISTS {
            unsafe {
                CloseHandle(handle);
            }
            return Ok(None);
        }

        Ok(Some(SingleInstanceGuard { handle }))
    }

    #[cfg(not(windows))]
    {
        Ok(Some(SingleInstanceGuard))
    }
}

#[cfg(windows)]
pub fn find_furphy_window() -> Option<windows_sys::Win32::Foundation::HWND> {
    use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM};
    use windows_sys::Win32::UI::WindowsAndMessaging::{EnumWindows, FindWindowW, GetWindowTextW};

    let title_str = if crate::paths::is_dev() {
        "Furphy Dev"
    } else {
        "Furphy Addon Manager"
    };

    let wide_title: Vec<u16> = format!("{}\0", title_str).encode_utf16().collect();
    let hwnd = unsafe { FindWindowW(std::ptr::null(), wide_title.as_ptr()) };
    if hwnd != 0 {
        return Some(hwnd);
    }

    struct SearchContext {
        target_prefix: String,
        found_hwnd: Option<HWND>,
    }

    unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let ctx = &mut *(lparam as *mut SearchContext);
        let mut buf = [0u16; 256];
        let len = GetWindowTextW(hwnd, buf.as_mut_ptr(), 256);
        if len > 0 {
            if let Ok(text) = String::from_utf16(&buf[..len as usize]) {
                if text.starts_with(&ctx.target_prefix) {
                    ctx.found_hwnd = Some(hwnd);
                    return 0;
                }
            }
        }
        1
    }

    let mut ctx = SearchContext {
        target_prefix: title_str.to_string(),
        found_hwnd: None,
    };

    unsafe {
        EnumWindows(Some(enum_proc), &mut ctx as *mut _ as LPARAM);
    }

    ctx.found_hwnd
}

pub fn activate_existing_instance() -> bool {
    #[cfg(windows)]
    {
        if let Some(hwnd) = find_furphy_window() {
            unsafe {
                ShowWindow(hwnd, SW_RESTORE);
                ShowWindow(hwnd, SW_SHOW);
            }
            let _ = bring_window_to_front(hwnd as isize);
            return true;
        }
        false
    }

    #[cfg(not(windows))]
    {
        false
    }
}

pub const MIN_WIDTH_96_DPI: u32 = 1040;
pub const MIN_HEIGHT_96_DPI: u32 = 660;
pub const ACTIVATION_COOLDOWN_SECS: u64 = 5;

static LAST_ACTIVATION_TIME: Mutex<Option<Instant>> = Mutex::new(None);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WindowBoundsDto {
    pub x: i32,
    pub y: i32,
    #[serde(alias = "w")]
    pub width: u32,
    #[serde(alias = "h")]
    pub height: u32,
    #[serde(default)]
    pub maximized: bool,
}

pub fn save_current_window_bounds(window: &tauri::Window) {
    let maximized = window.is_maximized().unwrap_or(false);
    let (x, y) = if let Ok(pos) = window.outer_position() {
        (pos.x, pos.y)
    } else {
        (0, 0)
    };
    let (width, height) = if let Ok(size) = window.outer_size() {
        (size.width, size.height)
    } else {
        (MIN_WIDTH_96_DPI, MIN_HEIGHT_96_DPI)
    };

    let bounds = WindowBoundsDto {
        x,
        y,
        width,
        height,
        maximized,
    };

    let db_path = crate::paths::get_db_path();
    if let Ok(conn) = crate::db::open_connection(&db_path) {
        let _ = save_window_bounds(&conn, &bounds);
    }
}

pub fn apply_saved_window_bounds(window: &tauri::Window) {
    // 1. Enforce minimum size (1040x660 logical)
    let _ = window.set_min_size(Some(tauri::Size::Logical(tauri::LogicalSize::new(
        MIN_WIDTH_96_DPI as f64,
        MIN_HEIGHT_96_DPI as f64,
    ))));

    // 2. Load and apply persisted bounds if available
    let db_path = crate::paths::get_db_path();
    if let Ok(conn) = crate::db::open_connection(&db_path) {
        if let Some(bounds) = load_window_bounds(&conn) {
            let _ = window.set_position(tauri::Position::Physical(tauri::PhysicalPosition::new(bounds.x, bounds.y)));
            let _ = window.set_size(tauri::Size::Physical(tauri::PhysicalSize::new(bounds.width, bounds.height)));
            if bounds.maximized {
                let _ = window.maximize();
            }
        }
    }
}

pub fn apply_saved_webview_window_bounds(window: &tauri::WebviewWindow) {
    // 1. Enforce minimum size (1040x660 logical)
    let _ = window.set_min_size(Some(tauri::Size::Logical(tauri::LogicalSize::new(
        MIN_WIDTH_96_DPI as f64,
        MIN_HEIGHT_96_DPI as f64,
    ))));

    // 2. Load and apply persisted bounds if available
    let db_path = crate::paths::get_db_path();
    if let Ok(conn) = crate::db::open_connection(&db_path) {
        if let Some(bounds) = load_window_bounds(&conn) {
            let _ = window.set_position(tauri::Position::Physical(tauri::PhysicalPosition::new(bounds.x, bounds.y)));
            let _ = window.set_size(tauri::Size::Physical(tauri::PhysicalSize::new(bounds.width, bounds.height)));
            if bounds.maximized {
                let _ = window.maximize();
            }
        }
    }
}

pub fn minimum_size_for_dpi(dpi: u32) -> (u32, u32) {
    let d = if dpi == 0 { 96 } else { dpi } as f64;
    let w = ((MIN_WIDTH_96_DPI as f64 * d) / 96.0).round() as u32;
    let h = ((MIN_HEIGHT_96_DPI as f64 * d) / 96.0).round() as u32;
    (w, h)
}

pub fn check_activation_cooldown() -> bool {
    let now = Instant::now();
    let mut guard = LAST_ACTIVATION_TIME.lock().unwrap();
    if let Some(last) = *guard {
        if now.duration_since(last) < Duration::from_secs(ACTIVATION_COOLDOWN_SECS) {
            return false; // Cooldown active, reject duplicate click
        }
    }
    *guard = Some(now);
    true
}

pub fn reset_activation_cooldown() {
    let mut guard = LAST_ACTIVATION_TIME.lock().unwrap();
    *guard = None;
}

pub fn save_window_bounds(conn: &Connection, bounds: &WindowBoundsDto) -> Result<(), String> {
    let json = serde_json::to_string(bounds).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('hostWindow', ?1) \
         ON CONFLICT(key) DO UPDATE SET value = ?1",
        rusqlite::params![json],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn load_window_bounds(conn: &Connection) -> Option<WindowBoundsDto> {
    let mut stmt = conn
        .prepare("SELECT value FROM settings WHERE key = 'hostWindow'")
        .ok()?;
    let val_str: String = stmt.query_row([], |r| r.get(0)).ok()?;
    serde_json::from_str(&val_str).ok()
}

/// Activates window, restores if minimized, brings to front, sets foreground.
/// Flashes 3 times if Windows foreground lock prevents focus.
pub fn bring_window_to_front(hwnd_raw: isize) -> Result<(), String> {
    #[cfg(windows)]
    unsafe {
        let hwnd = hwnd_raw as HWND;
        if hwnd == 0 {
            return Err("Invalid window handle".to_string());
        }

        // Restore if minimized
        ShowWindow(hwnd, SW_RESTORE);
        BringWindowToTop(hwnd);

        let fore_hwnd = GetForegroundWindow();
        let fore_thread = GetWindowThreadProcessId(fore_hwnd, std::ptr::null_mut());
        let current_thread = GetCurrentThreadId();

        let attached = if fore_thread != 0 && fore_thread != current_thread {
            AttachThreadInput(current_thread, fore_thread, 1) != 0
        } else {
            false
        };

        let set_res: BOOL = SetForegroundWindow(hwnd);

        if attached {
            AttachThreadInput(current_thread, fore_thread, 0);
        }

        // Verify if it actually became foreground; else flash 3 times
        if set_res == 0 || GetForegroundWindow() != hwnd {
            let mut flash_info = FLASHWINFO {
                cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
                hwnd,
                dwFlags: FLASHW_ALL,
                uCount: 3,
                dwTimeout: 0,
            };
            FlashWindowEx(&mut flash_info);
        }
    }

    #[cfg(not(windows))]
    let _ = hwnd_raw;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_minimum_size_scaling_math() {
        assert_eq!(minimum_size_for_dpi(96), (1040, 660));
        assert_eq!(minimum_size_for_dpi(120), (1300, 825));
        assert_eq!(minimum_size_for_dpi(144), (1560, 990));
        assert_eq!(minimum_size_for_dpi(192), (2080, 1320));
    }

    #[test]
    fn test_activation_cooldown() {
        reset_activation_cooldown();
        assert!(check_activation_cooldown());
        // Immediate second click should be rejected by cooldown
        assert!(!check_activation_cooldown());
        reset_activation_cooldown();
        assert!(check_activation_cooldown());
    }

    #[test]
    fn test_window_bounds_db_roundtrip() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)", []).unwrap();

        let bounds = WindowBoundsDto {
            x: 100,
            y: 150,
            width: 1200,
            height: 800,
            maximized: false,
        };

        save_window_bounds(&conn, &bounds).unwrap();
        let loaded = load_window_bounds(&conn).unwrap();
        assert_eq!(loaded, bounds);
    }

    #[test]
    fn test_window_bounds_v1_format_and_corrupt_json() {
        // 1. v1 format uses {"x": 100, "y": 150, "w": 1200, "h": 800} without maximized
        let v1_json = r#"{"x":100,"y":150,"w":1200,"h":800}"#;
        let bounds: WindowBoundsDto = serde_json::from_str(v1_json).unwrap();
        assert_eq!(bounds.x, 100);
        assert_eq!(bounds.y, 150);
        assert_eq!(bounds.width, 1200);
        assert_eq!(bounds.height, 800);
        assert!(!bounds.maximized);

        // 2. Corrupt JSON in DB safely yields None
        let conn = Connection::open_in_memory().unwrap();
        conn.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)", []).unwrap();
        conn.execute("INSERT INTO settings (key, value) VALUES ('hostWindow', '{corrupt-json') ", []).unwrap();
        assert!(load_window_bounds(&conn).is_none());
    }
}
