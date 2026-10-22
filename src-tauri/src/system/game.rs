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

pub fn is_wow_process_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    let stem = if lower.ends_with(".exe") {
        &lower[..lower.len() - 4]
    } else {
        &lower
    };

    WOW_EXE_NAMES.iter().any(|&target| stem == target)
}

pub fn is_wow_running() -> bool {
    if let Ok(val) = std::env::var("FURPHY_TEST_WOW_RUNNING") {
        let v = val.trim();
        if v == "1" || v.eq_ignore_ascii_case("true") {
            return true;
        } else if v == "0" || v.eq_ignore_ascii_case("false") {
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
                    return true;
                }

                if Process32NextW(snapshot, &mut entry) == 0 {
                    break;
                }
            }
        }

        CloseHandle(snapshot);
    }

    false
}

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
    fn test_is_wow_running_env_override() {
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");
        assert!(is_wow_running());
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "0");
        assert!(!is_wow_running());
        std::env::remove_var("FURPHY_TEST_WOW_RUNNING");
    }
}
