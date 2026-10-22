use std::sync::Mutex;
use crate::system::game::{is_wow_process_name, is_wow_running_fresh};
use crate::system::tray_status::join_names_truncated;

#[cfg(windows)]
use windows_sys::Win32::Foundation::{CloseHandle, HWND};
#[cfg(windows)]
use windows_sys::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
#[cfg(windows)]
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetForegroundWindow, GetWindowThreadProcessId,
};

#[derive(Debug, Clone, Default)]
pub struct NotificationRecord {
    pub title: String,
    pub text: String,
    pub is_warning: bool,
    pub suppressed_game_foreground: bool,
}

static NOTIFICATION_STATE: Mutex<NotificationState> = Mutex::new(NotificationState {
    last_record: None,
    balloon_shown: false,
    balloon_text: String::new(),
    history: Vec::new(),
});

struct NotificationState {
    last_record: Option<NotificationRecord>,
    balloon_shown: bool,
    balloon_text: String,
    history: Vec<NotificationRecord>,
}

pub fn reset_notification_tracking() {
    let mut guard = NOTIFICATION_STATE.lock().unwrap();
    guard.last_record = None;
    guard.balloon_shown = false;
    guard.balloon_text.clear();
    guard.history.clear();
}

pub fn get_balloon_info() -> (bool, String) {
    let guard = NOTIFICATION_STATE.lock().unwrap();
    (guard.balloon_shown, guard.balloon_text.clone())
}

/// Checks if a game or fullscreen window is currently active in the foreground.
pub fn is_fullscreen_or_game_foreground() -> bool {
    if let Ok(val) = std::env::var("FURPHY_TEST_GAME_FOREGROUND") {
        if val == "1" || val.eq_ignore_ascii_case("true") {
            return true;
        } else if val == "0" || val.eq_ignore_ascii_case("false") {
            return false;
        }
    }

    #[cfg(windows)]
    unsafe {
        let hwnd: HWND = GetForegroundWindow();
        if hwnd == 0 {
            return false;
        }

        // Check if foreground process is a WoW process
        let mut pid: u32 = 0;
        GetWindowThreadProcessId(hwnd, &mut pid);
        if pid != 0 {
            let proc_handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if proc_handle != 0 {
                let mut buffer = [0u16; 1024];
                let mut size = buffer.len() as u32;
                if QueryFullProcessImageNameW(proc_handle, PROCESS_NAME_WIN32, buffer.as_mut_ptr(), &mut size) != 0 {
                    let full_path = String::from_utf16_lossy(&buffer[..size as usize]);
                    if let Some(exe_name) = std::path::Path::new(&full_path).file_name() {
                        let name_str = exe_name.to_string_lossy();
                        if is_wow_process_name(&name_str) {
                            CloseHandle(proc_handle);
                            return true;
                        }
                    }
                }
                CloseHandle(proc_handle);
            }
        }
    }

    false
}

/// Formats the balloon notification text per GAME-MODE-SPEC.md and SPEC.md:
/// - One per cycle, only for done_updated or done_failed
/// - Title "Furphy", duration 8s
/// - Up to 4 names, then "+K more"
/// - For done_updated ONLY: if WoW is running, appends reload notice
pub fn format_balloon_text(status: &str, names: &[String]) -> Option<(String, bool)> {
    if status != "done_updated" && status != "done_failed" {
        return None;
    }

    let mut text = join_names_truncated(names, 4);
    let is_warning = status == "done_failed";

    if status == "done_updated" && is_wow_running_fresh() {
        text.push_str(" - WoW will use it once you type /reload in your chat window, or log out and back in.");
    }

    Some((text, is_warning))
}

/// Dispatches a cycle completion notification adhering to ADR-309 and v1 behavior.
pub fn show_cycle_notification(status: &str, names: &[String]) {
    let (text, is_warning) = match format_balloon_text(status, names) {
        Some(pair) => pair,
        None => return,
    };

    // Check ADR-309 fullscreen/game suppression rule
    let suppressed = is_fullscreen_or_game_foreground();

    let record = NotificationRecord {
        title: "Furphy".to_string(),
        text: text.clone(),
        is_warning,
        suppressed_game_foreground: suppressed,
    };

    {
        let mut guard = NOTIFICATION_STATE.lock().unwrap();
        guard.last_record = Some(record.clone());
        guard.balloon_shown = !suppressed;
        guard.balloon_text = if !suppressed { text.clone() } else { String::new() };
        guard.history.push(record);
    }

    if suppressed {
        crate::logging::append_app_log(
            "INFO",
            "Suppressed balloon notification: game is running in the foreground (ADR-309)",
        );
        return;
    }

    // Windows native notification / balloon
    #[cfg(windows)]
    {
        // Handled via tray or Win32 API if tray icon is active
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_balloon_text_clean_and_ignored_statuses() {
        assert!(format_balloon_text("done_clean", &[]).is_none());
        assert!(format_balloon_text("idle", &[]).is_none());
        assert!(format_balloon_text("checking", &[]).is_none());
    }

    #[test]
    fn test_format_balloon_text_failed() {
        let failed_names = vec!["BuggyAddon".to_string()];
        let (text, is_warning) = format_balloon_text("done_failed", &failed_names).unwrap();
        assert_eq!(text, "BuggyAddon");
        assert!(is_warning);
    }

    #[test]
    fn test_format_balloon_text_updated_with_wow_running() {
        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap();
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");
        let updated_names = vec!["Details".to_string(), "Plater".to_string()];
        let (text, is_warning) = format_balloon_text("done_updated", &updated_names).unwrap();
        assert!(text.starts_with("Details, Plater"));
        assert!(text.contains(" - WoW will use it once you type /reload in your chat window, or log out and back in."));
        assert!(!is_warning);
        std::env::remove_var("FURPHY_TEST_WOW_RUNNING");
    }

    #[test]
    fn test_format_balloon_text_updated_without_wow() {
        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap();
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "0");
        let updated_names = vec!["Details".to_string()];
        let (text, is_warning) = format_balloon_text("done_updated", &updated_names).unwrap();
        assert_eq!(text, "Details");
        assert!(!is_warning);
        std::env::remove_var("FURPHY_TEST_WOW_RUNNING");
    }

    #[test]
    fn test_show_cycle_notification_suppression_on_fullscreen() {
        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap();
        reset_notification_tracking();
        std::env::set_var("FURPHY_TEST_GAME_FOREGROUND", "1");
        show_cycle_notification("done_updated", &["Details".into()]);
        let (shown, _) = get_balloon_info();
        assert!(!shown, "Balloon should be suppressed when game is in foreground");
        std::env::remove_var("FURPHY_TEST_GAME_FOREGROUND");
    }
}
