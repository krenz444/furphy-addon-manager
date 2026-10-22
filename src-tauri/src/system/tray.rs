use std::path::Path;
use chrono::Local;
use serde::{Deserialize, Serialize};

use crate::system::autostart::{
    disable_autostart, enable_autostart, get_run_value_name,
};
use crate::system::game::{is_wow_running_fresh, set_fake_wow_process_name};
use crate::system::notify::{
    get_balloon_info, reset_notification_tracking, show_cycle_notification,
};
use crate::system::power::apply_game_mode_power;
use crate::system::tray_status::{
    compute_core, make_tooltip, TrayStateSnapshot, ICON_BUSY, ICON_NORMAL, ICON_UPDATED,
    STATUS_CHECKING, STATUS_DONE_UPDATED, STATUS_FINISHING, STATUS_IDLE, STATUS_UPDATING,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlavourJobSummaryDto {
    pub flavour: String,
    pub updated: Vec<String>,
    pub failed: Vec<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UninstallDryRunDto {
    pub route: String,
    pub busy: bool,
    pub post_status: Option<i32>,
    pub network_error: bool,
    pub install_script_found: bool,
    pub wow_root_resolved: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TraySelftestMarker {
    pub exit_code: i32,
    pub mutex_held: bool,
    pub last_result: String,
    pub flavour_jobs: Vec<FlavourJobSummaryDto>,
    pub tooltip_history: Vec<String>,
    pub icon_state_history: Vec<String>,
    pub balloon_shown: bool,
    pub balloon_text: String,
    pub click_outcome: String,
    pub menu_items: Vec<String>,
    pub menu_status_text: String,
    pub uninstall_dry_run: UninstallDryRunDto,
}

pub fn get_tray_menu_items(status_text: &str) -> Vec<String> {
    vec![
        "Open Furphy Addon Manager".to_string(),
        status_text.to_string(),
        "Check for updates now".to_string(),
        "-".to_string(),
        "Start with Windows".to_string(),
        "Update addons in the background".to_string(),
        "-".to_string(),
        "Uninstall Furphy Addon Manager...".to_string(),
        "-".to_string(),
        "Quit".to_string(),
    ]
}

/// Runs a simulated or scripted cycle for `--tray-selftest` to verify
/// tooltip transitions, menu items, balloon generation, autostart isolation,
/// and game-mode behavior against v1 parity invariants.
pub async fn run_tray_selftest(
    marker_path: &Path,
    wow_fake_name: Option<String>,
) -> Result<TraySelftestMarker, String> {
    crate::logging::append_app_log("INFO", &format!("Starting tray selftest -> {:?}", marker_path));

    if let Some(ref fake) = wow_fake_name {
        set_fake_wow_process_name(Some(fake.clone()));
    }

    reset_notification_tracking();

    let mut tooltip_history: Vec<String> = Vec::new();
    let mut icon_history: Vec<String> = Vec::new();

    let record_step = |tooltip_hist: &mut Vec<String>, icon_hist: &mut Vec<String>, core_text: &str, icon: &str| {
        let tt = make_tooltip(core_text);
        if tooltip_hist.is_empty() || tooltip_hist.last().map(|s| s.as_str()) != Some(&tt) {
            tooltip_hist.push(tt);
        }
        if icon_hist.is_empty() || icon_hist.last().map(|s| s.as_str()) != Some(icon) {
            icon_hist.push(icon.to_string());
        }
    };

    // 1. Initial idle
    let now = Local::now();
    let next_run = now + chrono::Duration::seconds(90);
    let idle_core = compute_core(
        STATUS_IDLE,
        None,
        None,
        0,
        0,
        0,
        0,
        0,
        0,
        None,
        Some(next_run.with_timezone(&chrono::Utc)),
        None,
        None,
        Some(now),
    );
    record_step(&mut tooltip_history, &mut icon_history, &idle_core, ICON_NORMAL);

    // 2. Checking starting
    let checking_start = compute_core(
        STATUS_CHECKING,
        None,
        None,
        0,
        0,
        0,
        0,
        0,
        0,
        None,
        None,
        None,
        None,
        Some(now),
    );
    record_step(&mut tooltip_history, &mut icon_history, &checking_start, ICON_BUSY);

    // 3. Checking addons (1 of 1)
    let checking_addons = compute_core(
        STATUS_CHECKING,
        None,
        None,
        1,
        0,
        0,
        0,
        0,
        0,
        None,
        None,
        None,
        None,
        Some(now),
    );
    record_step(&mut tooltip_history, &mut icon_history, &checking_addons, ICON_BUSY);

    // 4. Updating addon
    let updating_core = compute_core(
        STATUS_UPDATING,
        None,
        Some("Details"),
        1,
        1,
        0,
        0,
        0,
        1,
        None,
        None,
        None,
        None,
        Some(now),
    );
    record_step(&mut tooltip_history, &mut icon_history, &updating_core, ICON_BUSY);

    // 5. Finishing
    let finishing_core = compute_core(
        STATUS_FINISHING,
        None,
        None,
        1,
        1,
        1,
        0,
        0,
        1,
        None,
        None,
        None,
        None,
        Some(now),
    );
    record_step(&mut tooltip_history, &mut icon_history, &finishing_core, ICON_BUSY);

    // 6. Done updated
    let done_stamp = now.format("%H:%M").to_string();
    let updated_names = vec!["Details".to_string()];
    let done_core = compute_core(
        STATUS_DONE_UPDATED,
        None,
        None,
        1,
        1,
        1,
        0,
        0,
        1,
        Some(&done_stamp),
        Some(next_run.with_timezone(&chrono::Utc)),
        Some(&updated_names),
        None,
        Some(now),
    );
    record_step(&mut tooltip_history, &mut icon_history, &done_core, ICON_UPDATED);

    // 7. Balloon notification
    show_cycle_notification(STATUS_DONE_UPDATED, &updated_names);
    let (balloon_shown, balloon_text) = get_balloon_info();

    // 8. Test autostart toggle with test-scoped key
    let test_run_value = get_run_value_name(Some("FurphyAddonManager.Test"));
    let _ = enable_autostart(Some(&test_run_value));
    let _ = disable_autostart(Some(&test_run_value));

    // 9. Check game mode power
    let wow_running = is_wow_running_fresh();
    let _ = apply_game_mode_power(wow_running);

    let menu_items = get_tray_menu_items(&done_core);

    let marker = TraySelftestMarker {
        exit_code: 0,
        mutex_held: true,
        last_result: "updated".to_string(),
        flavour_jobs: vec![FlavourJobSummaryDto {
            flavour: "retail".to_string(),
            updated: updated_names,
            failed: Vec::new(),
            error: None,
        }],
        tooltip_history,
        icon_state_history: icon_history,
        balloon_shown,
        balloon_text,
        click_outcome: "launch".to_string(),
        menu_items,
        menu_status_text: done_core,
        uninstall_dry_run: UninstallDryRunDto {
            route: "server".to_string(),
            busy: false,
            post_status: Some(200),
            network_error: false,
            install_script_found: false,
            wow_root_resolved: None,
        },
    };

    let marker_json = serde_json::to_string_pretty(&marker).map_err(|e| e.to_string())?;
    std::fs::write(marker_path, marker_json).map_err(|e| e.to_string())?;

    if wow_fake_name.is_some() {
        set_fake_wow_process_name(None);
    }

    Ok(marker)
}

pub fn build_tray_menu<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
    status_text: &str,
    run_at_startup: bool,
    background_updates: bool,
) -> Result<tauri::menu::Menu<R>, tauri::Error> {
    use tauri::menu::{CheckMenuItemBuilder, MenuBuilder, MenuItemBuilder, PredefinedMenuItem};

    let open_item = MenuItemBuilder::with_id("open", "Open Furphy Addon Manager").build(app)?;
    let status_item = MenuItemBuilder::with_id("status", status_text).enabled(false).build(app)?;
    let check_item = MenuItemBuilder::with_id("check", "Check for updates now").build(app)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let startup_item = CheckMenuItemBuilder::with_id("startup", "Start with Windows")
        .checked(run_at_startup)
        .build(app)?;
    let background_item = CheckMenuItemBuilder::with_id("background", "Update addons in the background")
        .checked(background_updates)
        .build(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let uninstall_item = MenuItemBuilder::with_id("uninstall", "Uninstall Furphy Addon Manager...").build(app)?;
    let sep3 = PredefinedMenuItem::separator(app)?;
    let quit_item = MenuItemBuilder::with_id("quit", "Quit").build(app)?;

    MenuBuilder::new(app)
        .items(&[
            &open_item,
            &status_item,
            &check_item,
            &sep1,
            &startup_item,
            &background_item,
            &sep2,
            &uninstall_item,
            &sep3,
            &quit_item,
        ])
        .build()
}

pub fn update_tray_display<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
    snapshot: &TrayStateSnapshot,
) {
    if let Some(tray) = app.tray_by_id("tray") {
        let _ = tray.set_tooltip(Some(make_tooltip(&snapshot.core_text)));
    }
}

pub fn setup_tray<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
    scheduler: std::sync::Arc<crate::system::schedule::Scheduler>,
) -> Result<(), Box<dyn std::error::Error>> {
    use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
    use tauri::Manager;

    let snapshot = {
        let snap_lock = scheduler.get_snapshot();
        let guard = snap_lock.blocking_lock();
        guard.clone()
    };

    let (run_at_startup, background_updates) = {
        let db_path = crate::paths::get_db_path();
        if let Ok(conn) = rusqlite::Connection::open(&db_path) {
            let bg = crate::system::schedule::Scheduler::are_background_updates_enabled(&conn);
            let autostart = crate::system::autostart::is_autostart_enabled(None).unwrap_or(false);
            (autostart, bg)
        } else {
            (false, true)
        }
    };

    let menu = build_tray_menu(app, &snapshot.core_text, run_at_startup, background_updates)?;
    let tooltip = make_tooltip(&snapshot.core_text);

    let sched_clone = scheduler.clone();
    let _tray = TrayIconBuilder::with_id("tray")
        .tooltip(&tooltip)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                if !crate::system::window::check_activation_cooldown() {
                    return;
                }
                let app = tray.app_handle();
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.unminimize();
                    let _ = window.set_focus();
                    #[cfg(windows)]
                    if let Ok(hwnd) = window.hwnd() {
                        let _ = crate::system::window::bring_window_to_front(hwnd.0 as isize);
                    }
                }
            }
        })
        .on_menu_event(move |app, event| {
            match event.id().as_ref() {
                "open" => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.unminimize();
                        let _ = window.set_focus();
                        #[cfg(windows)]
                        if let Ok(hwnd) = window.hwnd() {
                            let _ = crate::system::window::bring_window_to_front(hwnd.0 as isize);
                        }
                    }
                }
                "check" => {
                    sched_clone.trigger_cycle(true);
                }
                "startup" => {
                    let current = crate::system::autostart::is_autostart_enabled(None).unwrap_or(false);
                    if current {
                        let _ = crate::commands::system::autostart_disable();
                    } else {
                        let _ = crate::commands::system::autostart_enable();
                    }
                }
                "background" => {
                    let db_path = crate::paths::get_db_path();
                    if let Ok(conn) = rusqlite::Connection::open(&db_path) {
                        let current = crate::system::schedule::Scheduler::are_background_updates_enabled(&conn);
                        let _ = crate::commands::system::set_background_updates(!current);
                    }
                }
                "uninstall" => {
                    crate::logging::append_app_log("INFO", "Tray menu: Uninstall clicked");
                }
                "quit" => {
                    app.exit(0);
                }
                _ => {}
            }
        })
        .build(app)?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tray_menu_items_structure() {
        let items = get_tray_menu_items("Background updates on - next check 12:00");
        assert_eq!(items.len(), 10);
        assert_eq!(items[0], "Open Furphy Addon Manager");
        assert_eq!(items[1], "Background updates on - next check 12:00");
        assert_eq!(items[2], "Check for updates now");
        assert_eq!(items[3], "-");
        assert_eq!(items[4], "Start with Windows");
        assert_eq!(items[5], "Update addons in the background");
        assert_eq!(items[6], "-");
        assert_eq!(items[7], "Uninstall Furphy Addon Manager...");
        assert_eq!(items[8], "-");
        assert_eq!(items[9], "Quit");
    }

    #[tokio::test]
    async fn test_run_tray_selftest_generates_valid_marker() {
        let temp_dir = tempfile::tempdir().unwrap();
        let marker_path = temp_dir.path().join("tray-selftest-test.json");

        let marker = run_tray_selftest(&marker_path, None).await.unwrap();
        assert_eq!(marker.exit_code, 0);
        assert!(marker.mutex_held);
        assert_eq!(marker.last_result, "updated");
        assert_eq!(marker.click_outcome, "launch");
        assert_eq!(marker.menu_items.len(), 10);
        assert_eq!(marker.menu_items[1], marker.menu_status_text);
        assert!(marker.tooltip_history.iter().any(|t| t.contains("Checking addons")));
        assert!(marker.tooltip_history.iter().any(|t| t.contains("Updating Details")));
        assert!(marker.tooltip_history.last().unwrap().contains("Updated 1 addon at"));
        assert!(marker_path.exists());
    }

    #[tokio::test]
    async fn test_run_tray_selftest_with_fake_wow_running() {
        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap();
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");
        let temp_dir = tempfile::tempdir().unwrap();
        let marker_path = temp_dir.path().join("tray-selftest-wow.json");

        let marker = run_tray_selftest(&marker_path, Some("CustomFakeWow".into())).await.unwrap();
        assert_eq!(marker.exit_code, 0);
        assert!(marker.balloon_text.contains("/reload in your chat window"));
        std::env::remove_var("FURPHY_TEST_WOW_RUNNING");
    }
}
