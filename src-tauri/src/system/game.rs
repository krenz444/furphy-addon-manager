use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[cfg(windows)]
use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
#[cfg(windows)]
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};

pub const WOW_EXE_NAMES: &[&str] = &[
    "wow",
    "wow-64",
    "wowclassic",
    "wowclassict",
    "wowclassicb",
    "wowt",
    "wowb",
    "fake-wow",
];

static FAKE_WOW_NAME: Mutex<Option<String>> = Mutex::new(None);
static CACHED_WOW_RUNNING: AtomicBool = AtomicBool::new(false);
static LAST_CHECK_TIME: Mutex<Option<Instant>> = Mutex::new(None);

pub fn set_fake_wow_process_name(name: Option<String>) {
    let mut guard = FAKE_WOW_NAME.lock().unwrap();
    *guard = name;
    // Invalidate cache
    let mut last = LAST_CHECK_TIME.lock().unwrap();
    *last = None;
}

pub fn is_wow_process_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    let stem = if lower.ends_with(".exe") {
        &lower[..lower.len() - 4]
    } else {
        &lower
    };

    if WOW_EXE_NAMES.iter().any(|&target| stem == target) {
        return true;
    }

    if let Ok(guard) = FAKE_WOW_NAME.lock() {
        if let Some(ref fake) = *guard {
            let fake_lower = fake.to_ascii_lowercase();
            let fake_stem = if fake_lower.ends_with(".exe") {
                &fake_lower[..fake_lower.len() - 4]
            } else {
                &fake_lower
            };
            if stem == fake_stem {
                return true;
            }
        }
    }

    false
}

pub fn is_wow_running_fresh() -> bool {
    if let Ok(val) = std::env::var("FURPHY_TEST_WOW_RUNNING") {
        let v = val.trim();
        if v == "1" || v.eq_ignore_ascii_case("true") {
            CACHED_WOW_RUNNING.store(true, Ordering::SeqCst);
            return true;
        } else if v == "0" || v.eq_ignore_ascii_case("false") {
            CACHED_WOW_RUNNING.store(false, Ordering::SeqCst);
            return false;
        }
    }

    #[cfg(windows)]
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return false;
        }

        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;

        if Process32FirstW(snapshot, &mut entry) != 0 {
            loop {
                let null_pos = entry
                    .szExeFile
                    .iter()
                    .position(|&c| c == 0)
                    .unwrap_or(entry.szExeFile.len());
                let exe_name = String::from_utf16_lossy(&entry.szExeFile[..null_pos]);
                if is_wow_process_name(&exe_name) {
                    CloseHandle(snapshot);
                    CACHED_WOW_RUNNING.store(true, Ordering::SeqCst);
                    return true;
                }

                if Process32NextW(snapshot, &mut entry) == 0 {
                    break;
                }
            }
        }

        CloseHandle(snapshot);
    }

    CACHED_WOW_RUNNING.store(false, Ordering::SeqCst);
    false
}

/// Checks if WoW is running, using a 30-second cache per plan section 2.I.
pub fn is_wow_running() -> bool {
    if std::env::var("FURPHY_TEST_WOW_RUNNING").is_ok() {
        return is_wow_running_fresh();
    }

    let now = Instant::now();
    let mut last = LAST_CHECK_TIME.lock().unwrap();
    if let Some(t) = *last {
        if now.duration_since(t) < Duration::from_secs(30) {
            return CACHED_WOW_RUNNING.load(Ordering::SeqCst);
        }
    }

    let running = is_wow_running_fresh();
    *last = Some(now);
    running
}

pub static TEST_ENV_LOCK: Mutex<()> = Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_wow_process_name_matches() {
        assert!(is_wow_process_name("Wow.exe"));
        assert!(is_wow_process_name("wow-64.exe"));
        assert!(is_wow_process_name("WowClassic.exe"));
        assert!(is_wow_process_name("WowClassicT.exe"));
        assert!(is_wow_process_name("WowClassicB.exe"));
        assert!(is_wow_process_name("WowT.exe"));
        assert!(is_wow_process_name("WowB.exe"));
        assert!(is_wow_process_name("fake-wow.exe"));
        assert!(is_wow_process_name("WOW"));
        assert!(!is_wow_process_name("explorer.exe"));
        assert!(!is_wow_process_name("notepad.exe"));
    }

    #[test]
    fn test_fake_wow_name_dynamic() {
        let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_fake_wow_process_name(Some("CustomFakeGame".into()));
        assert!(is_wow_process_name("CustomFakeGame.exe"));
        assert!(is_wow_process_name("customfakegame"));
        set_fake_wow_process_name(None);
        assert!(!is_wow_process_name("CustomFakeGame.exe"));
    }

    #[test]
    fn test_is_wow_running_env_override() {
        let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");
        assert!(is_wow_running_fresh());
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "0");
        assert!(!is_wow_running_fresh());
        std::env::remove_var("FURPHY_TEST_WOW_RUNNING");
    }
}
