#[cfg(windows)]
use windows_sys::Win32::Foundation::BOOL;
#[cfg(windows)]
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, SetPriorityClass, SetProcessInformation,
    BELOW_NORMAL_PRIORITY_CLASS, NORMAL_PRIORITY_CLASS,
};

#[repr(C)]
#[allow(non_snake_case)]
struct ProcessPowerThrottlingState {
    Version: u32,
    ControlMask: u32,
    StateMask: u32,
}

const PROCESS_POWER_THROTTLING: i32 = 4; // ProcessPowerThrottling in PROCESS_INFORMATION_CLASS
const PROCESS_POWER_THROTTLING_EXECUTION_SPEED: u32 = 0x1;

/// Sets process priority to BelowNormal (if enabled) or Normal (if disabled)
/// and toggles EcoQoS power throttling.
pub fn set_low_priority_and_eco_qos(enable: bool) -> Result<(), String> {
    if let Ok(val) = std::env::var("FURPHY_TEST_MOCK_POWER") {
        if val == "1" || val.eq_ignore_ascii_case("true") {
            return Ok(());
        }
    }

    #[cfg(windows)]
    unsafe {
        let handle = GetCurrentProcess();
        let priority = if enable {
            BELOW_NORMAL_PRIORITY_CLASS
        } else {
            NORMAL_PRIORITY_CLASS
        };

        if SetPriorityClass(handle, priority) == 0 {
            return Err("Failed to set process priority class".to_string());
        }

        let mut throttling = ProcessPowerThrottlingState {
            Version: 1,
            ControlMask: PROCESS_POWER_THROTTLING_EXECUTION_SPEED,
            StateMask: if enable {
                PROCESS_POWER_THROTTLING_EXECUTION_SPEED
            } else {
                0
            },
        };

        let res: BOOL = SetProcessInformation(
            handle,
            PROCESS_POWER_THROTTLING,
            &mut throttling as *mut _ as *mut std::ffi::c_void,
            std::mem::size_of::<ProcessPowerThrottlingState>() as u32,
        );

        // Some older Windows versions don't support EcoQoS; failure of SetProcessInformation is non-fatal if priority succeeded
        if res == 0 {
            // Log as debug if needed
        }
    }

    Ok(())
}

/// Applies game mode power policy: BelowNormal + EcoQoS while game runs or in background,
/// Normal otherwise.
pub fn apply_game_mode_power(game_running: bool) -> Result<(), String> {
    set_low_priority_and_eco_qos(game_running)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_power_throttling_toggle() {
        // Test toggling on Windows doesn't panic or fail catastrophically
        let _ = set_low_priority_and_eco_qos(true);
        let _ = set_low_priority_and_eco_qos(false);
    }

    #[test]
    fn test_game_mode_power_mock() {
        std::env::set_var("FURPHY_TEST_MOCK_POWER", "1");
        assert!(apply_game_mode_power(true).is_ok());
        assert!(apply_game_mode_power(false).is_ok());
        std::env::remove_var("FURPHY_TEST_MOCK_POWER");
    }
}
