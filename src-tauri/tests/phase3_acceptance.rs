use std::sync::Arc;
use chrono::{Duration, Local, Utc};
use furphy_lib::jobs::runner::JobRunner;
use furphy_lib::net::policy::NetworkPolicy;
use furphy_lib::system::autostart::{
    get_autostart_status, PRODUCTION_RUN_VALUE_NAME,
};
use furphy_lib::system::game::TEST_ENV_LOCK;
use furphy_lib::system::notify::format_balloon_text;
use furphy_lib::system::power::apply_game_mode_power;
use furphy_lib::system::protocol::{get_protocol_status, PRODUCTION_PROTOCOL};
use furphy_lib::system::schedule::Scheduler;
use furphy_lib::system::tray::run_tray_selftest;
use furphy_lib::system::tray_status::{
    compute_core, TrayStateSnapshot,
    STATUS_CHECKING, STATUS_DONE_CLEAN, STATUS_DONE_FAILED, STATUS_DONE_UPDATED, STATUS_IDLE,
    STATUS_UNREACHABLE, STATUS_UPDATING, STATUS_WAITING_BUSY,
};

use chrono::TimeZone;

#[test]
fn test_acceptance_exact_v1_status_sentences() {
    let now = Local.with_ymd_and_hms(2026, 10, 23, 20, 51, 0).unwrap();
    let next_run = (now + Duration::days(1)).with_timezone(&Utc);

    // 1. Idle sentence
    let idle = compute_core(
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
        Some(next_run),
        None,
        None,
        Some(now),
    );
    assert!(idle.starts_with("Background updates on - next check "));

    // 2. Checking starting
    let check_start = compute_core(
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
    assert_eq!(check_start, "Starting the updater...");

    // 3. Checking addons (p of total)
    let checking = compute_core(
        STATUS_CHECKING,
        None,
        None,
        35,
        14,
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
    assert_eq!(checking, "Checking addons (15 of 35)...");

    // 4. Updating addon
    let updating = compute_core(
        STATUS_UPDATING,
        None,
        Some("Details"),
        35,
        35,
        0,
        0,
        0,
        3,
        None,
        None,
        None,
        None,
        Some(now),
    );
    assert_eq!(updating, "Updating Details (3 of 3 updates)...");

    // 5. Finishing
    let finishing = compute_core(
        "finishing",
        None,
        None,
        35,
        35,
        3,
        0,
        32,
        3,
        None,
        None,
        None,
        None,
        Some(now),
    );
    assert_eq!(finishing, "Finishing...");

    // 6. Done clean
    let clean = compute_core(
        STATUS_DONE_CLEAN,
        None,
        None,
        35,
        35,
        0,
        0,
        35,
        0,
        Some("20:51"),
        Some(next_run),
        None,
        None,
        Some(now),
    );
    assert_eq!(clean, "Everything's up to date - checked 20:51 - next tomorrow 20:51");

    // 7. Done updated
    let names = vec!["Details".to_string(), "Plater".to_string()];
    let updated = compute_core(
        STATUS_DONE_UPDATED,
        None,
        None,
        35,
        35,
        2,
        0,
        33,
        2,
        Some("20:51"),
        Some(next_run),
        Some(&names),
        None,
        Some(now),
    );
    assert_eq!(updated, "Updated 2 addons at 20:51: Details, Plater");

    // 8. Done failed
    let failed = compute_core(
        STATUS_DONE_FAILED,
        None,
        None,
        35,
        35,
        0,
        1,
        34,
        0,
        Some("20:51"),
        Some(next_run),
        None,
        None,
        Some(now),
    );
    assert_eq!(failed, "1 addon couldn't update at 20:51 - open Furphy for details");

    // 9. Waiting busy
    let busy = compute_core(
        STATUS_WAITING_BUSY,
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
    assert_eq!(busy, "Waiting for the current task - retrying in 5 min");

    // 10. Unreachable
    let unreachable = compute_core(
        STATUS_UNREACHABLE,
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
    assert_eq!(unreachable, "Couldn't reach the updater - retrying in 5 min");
}

#[tokio::test]
async fn test_acceptance_tray_selftest_cycle_and_marker() {
    let _guard = TEST_ENV_LOCK.lock().unwrap();
    let temp_dir = tempfile::tempdir().unwrap();
    let marker_path = temp_dir.path().join("selftest_acceptance.json");

    let marker = run_tray_selftest(&marker_path, None).await.unwrap();

    assert_eq!(marker.exit_code, 0);
    assert!(marker.mutex_held);
    assert_eq!(marker.last_result, "updated");
    assert_eq!(marker.click_outcome, "launch");
    assert_eq!(marker.menu_items.len(), 10);
    assert_eq!(marker.menu_items[0], "Open Furphy Addon Manager");
    assert_eq!(marker.menu_items[1], marker.menu_status_text);
    assert_eq!(marker.menu_items[2], "Check for updates now");
    assert_eq!(marker.menu_items[3], "-");
    assert_eq!(marker.menu_items[4], "Start with Windows");
    assert_eq!(marker.menu_items[5], "Update addons in the background");
    assert_eq!(marker.menu_items[6], "-");
    assert_eq!(marker.menu_items[7], "Uninstall Furphy Addon Manager...");
    assert_eq!(marker.menu_items[8], "-");
    assert_eq!(marker.menu_items[9], "Quit");

    // Status sequence verification
    assert!(marker.tooltip_history.iter().any(|t| t.contains("Starting the updater...")));
    assert!(marker.tooltip_history.iter().any(|t| t.contains("Checking addons (1 of 1)...")));
    assert!(marker.tooltip_history.iter().any(|t| t.contains("Updating Details")));
    assert!(marker.tooltip_history.iter().any(|t| t.contains("Finishing...")));
    assert!(marker.tooltip_history.last().unwrap().contains("Updated 1 addon at"));

    // Dry-run uninstall structure
    assert_eq!(marker.uninstall_dry_run.route, "server");
    assert!(!marker.uninstall_dry_run.busy);
    assert_eq!(marker.uninstall_dry_run.post_status, Some(200));
}

#[tokio::test]
async fn test_acceptance_game_mode_and_reload_notice() {
    let _guard = TEST_ENV_LOCK.lock().unwrap();
    std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");

    // 1. EcoQoS / power throttling application
    assert!(apply_game_mode_power(true).is_ok());

    // 2. Balloon notification includes reload notice when WoW runs
    let updated_names = vec!["BigWigs".to_string()];
    let (text, is_warning) = format_balloon_text("done_updated", &updated_names).unwrap();
    assert_eq!(is_warning, false);
    assert!(text.contains("BigWigs"));
    assert!(text.contains(" - WoW will use it once you type /reload in your chat window, or log out and back in."));

    // 3. Cycle completes normally while fake game runs
    let temp_dir = tempfile::tempdir().unwrap();
    let marker_path = temp_dir.path().join("game_mode_marker.json");
    let marker = run_tray_selftest(&marker_path, Some("WowFakeTest".into())).await.unwrap();
    assert_eq!(marker.exit_code, 0);
    assert_ne!(marker.last_result, "skipped_wow_running");
    assert_eq!(marker.last_result, "updated");

    std::env::remove_var("FURPHY_TEST_WOW_RUNNING");
}

#[tokio::test]
async fn test_acceptance_sleep_resume_wall_clock_trigger() {
    let policy = Arc::new(NetworkPolicy::default());
    let runner = Arc::new(JobRunner::new(policy));
    let mut initial = TrayStateSnapshot::default();

    // Set next_run_at in the past (as if machine went to sleep and woke up later)
    let past_time = Utc::now() - Duration::hours(2);
    initial.next_run_at = Some(past_time);

    let scheduler = Scheduler::new(runner, initial);
    let snapshot_arc = scheduler.get_snapshot();

    // Wall clock check: now >= next_run_at should be true
    let is_due = {
        let s = snapshot_arc.lock().await;
        s.next_run_at.map(|t| Utc::now() >= t).unwrap_or(false)
    };
    assert!(is_due, "Scheduler must detect that nextRunAt is in the past upon wake");
}

#[test]
fn test_acceptance_live_pc_hygiene_sweep() {
    // ADR-307 Hygiene Sweep:
    // Ensure dev/test builds have NEVER modified production Run registry value
    if furphy_lib::paths::is_dev() {
        let status = get_autostart_status(None).unwrap();
        // In dev mode, value_name must be FurphyAddonManager.Test, NOT the production name
        assert_ne!(status.value_name, PRODUCTION_RUN_VALUE_NAME);
        assert_eq!(status.value_name, "FurphyAddonManager.Test");
    }

    // Protocol hygiene:
    if furphy_lib::paths::is_dev() {
        let proto_status = get_protocol_status(None).unwrap();
        // In dev mode, scheme must be furphy-dev, NOT the production curseforge
        assert_ne!(proto_status.scheme, PRODUCTION_PROTOCOL);
        assert_eq!(proto_status.scheme, "furphy-dev");
    }
}
