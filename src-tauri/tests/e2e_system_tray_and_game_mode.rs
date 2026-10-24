use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use chrono::{Duration, Local, TimeZone, Utc};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

use furphy_lib::db::open_connection;
use furphy_lib::db::schema::INITIAL_SCHEMA;
use furphy_lib::engine::sync::run_sync_for_flavour;
use furphy_lib::jobs::runner::JobRunner;
use furphy_lib::net::policy::NetworkPolicy;
use furphy_lib::paths::get_db_path;
use furphy_lib::system::game::{is_wow_running, is_wow_running_fresh, TEST_ENV_LOCK};
use furphy_lib::system::notify::{
    format_balloon_text, get_balloon_info, is_fullscreen_or_game_foreground,
    reset_notification_tracking, show_cycle_notification,
};
use furphy_lib::system::power::{apply_game_mode_power, set_low_priority_and_eco_qos};
use furphy_lib::system::schedule::Scheduler;
use furphy_lib::system::tray_status::{
    compute_core, icon_variant_for_status, is_cycle_running, make_tooltip, TrayStateSnapshot,
    ICON_BUSY, ICON_FAILED, ICON_NORMAL, ICON_UPDATED, NOTIFY_ICON_SHELL_LIMIT,
    NOTIFY_ICON_TOOLTIP_LIMIT, STATUS_CHECKING, STATUS_DONE_CLEAN, STATUS_DONE_FAILED,
    STATUS_DONE_UPDATED, STATUS_IDLE, STATUS_UPDATING,
};

struct TestContext {
    wow_dir: PathBuf,
    local_data_dir: PathBuf,
    orig_wowroot: Option<String>,
    orig_localappdata: Option<String>,
    orig_cf_baseurl: Option<String>,
    orig_wow_running: Option<String>,
    orig_fake_wow: Option<String>,
    orig_game_fg: Option<String>,
}

impl TestContext {
    fn setup(name: &str) -> Self {
        let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
        let orig_localappdata = std::env::var("LOCALAPPDATA").ok();
        let orig_cf_baseurl = std::env::var("FURPHY_TEST_CF_BASEURL").ok();
        let orig_wow_running = std::env::var("FURPHY_TEST_WOW_RUNNING").ok();
        let orig_fake_wow = std::env::var("FURPHY_DEV_FAKE_WOW").ok();
        let orig_game_fg = std::env::var("FURPHY_TEST_GAME_FOREGROUND").ok();

        let rand_suffix = uuid::Uuid::new_v4().to_string();
        let wow_dir = std::env::temp_dir().join(format!("furphy e2e tray ({}_{})", name, rand_suffix));
        let local_data_dir = std::env::temp_dir().join(format!("furphy_e2e_data_tray_{}_{}", name, rand_suffix));

        let retail_addons = wow_dir.join("_retail_").join("Interface").join("AddOns");
        let retail_wtf = wow_dir.join("_retail_").join("WTF");
        fs::create_dir_all(&retail_addons).unwrap();
        fs::create_dir_all(&retail_wtf).unwrap();
        fs::create_dir_all(&local_data_dir).unwrap();

        std::env::set_var("FURPHY_DEV_WOWROOT", wow_dir.to_str().unwrap());
        std::env::set_var("LOCALAPPDATA", local_data_dir.to_str().unwrap());

        Self {
            wow_dir,
            local_data_dir,
            orig_wowroot,
            orig_localappdata,
            orig_cf_baseurl,
            orig_wow_running,
            orig_fake_wow,
            orig_game_fg,
        }
    }
}

impl Drop for TestContext {
    fn drop(&mut self) {
        if let Some(ref w) = self.orig_wowroot {
            std::env::set_var("FURPHY_DEV_WOWROOT", w);
        } else {
            std::env::remove_var("FURPHY_DEV_WOWROOT");
        }

        if let Some(ref l) = self.orig_localappdata {
            std::env::set_var("LOCALAPPDATA", l);
        } else {
            std::env::remove_var("LOCALAPPDATA");
        }

        if let Some(ref c) = self.orig_cf_baseurl {
            std::env::set_var("FURPHY_TEST_CF_BASEURL", c);
        } else {
            std::env::remove_var("FURPHY_TEST_CF_BASEURL");
        }

        if let Some(ref r) = self.orig_wow_running {
            std::env::set_var("FURPHY_TEST_WOW_RUNNING", r);
        } else {
            std::env::remove_var("FURPHY_TEST_WOW_RUNNING");
        }

        if let Some(ref f) = self.orig_fake_wow {
            std::env::set_var("FURPHY_DEV_FAKE_WOW", f);
        } else {
            std::env::remove_var("FURPHY_DEV_FAKE_WOW");
        }

        if let Some(ref g) = self.orig_game_fg {
            std::env::set_var("FURPHY_TEST_GAME_FOREGROUND", g);
        } else {
            std::env::remove_var("FURPHY_TEST_GAME_FOREGROUND");
        }

        let _ = fs::remove_dir_all(&self.wow_dir);
        let _ = fs::remove_dir_all(&self.local_data_dir);
    }
}

fn create_test_addon_zip(folder_name: &str, toc_name: &str, toc_content: &str) -> Vec<u8> {
    use std::io::Write;
    let mut buf = std::io::Cursor::new(Vec::new());
    {
        let mut zip = ZipWriter::new(&mut buf);
        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        zip.start_file(format!("{}/{}.toc", folder_name, toc_name), options).unwrap();
        zip.write_all(toc_content.as_bytes()).unwrap();
        zip.finish().unwrap();
    }
    buf.into_inner()
}

#[test]
fn test_e2e_system_tray_status_and_scheduler() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _ctx = TestContext::setup("tray_status");

    let now = Local.with_ymd_and_hms(2026, 10, 23, 20, 0, 0).unwrap();
    let next_run = (now + Duration::hours(2)).with_timezone(&Utc);

    // 1. Verify tray status formatting across all states (clean, updates_ready, failed, running)
    // Clean state
    let clean_text = compute_core(
        STATUS_DONE_CLEAN,
        None,
        None,
        20,
        20,
        0,
        0,
        20,
        0,
        Some("20:00"),
        Some(next_run),
        None,
        None,
        Some(now),
    );
    assert!(
        clean_text.starts_with("Everything's up to date - checked 20:00 - next 22:00"),
        "Unexpected clean text: {}",
        clean_text
    );
    assert_eq!(icon_variant_for_status(STATUS_DONE_CLEAN), ICON_NORMAL);

    let clean_tooltip = make_tooltip(&clean_text);
    assert!(clean_tooltip.len() <= NOTIFY_ICON_TOOLTIP_LIMIT);
    assert!(clean_tooltip.len() <= NOTIFY_ICON_SHELL_LIMIT);

    // Updates ready / updated state
    let updated_names = vec!["Details".to_string(), "Plater".to_string()];
    let updated_text = compute_core(
        STATUS_DONE_UPDATED,
        None,
        None,
        20,
        20,
        2,
        0,
        18,
        2,
        Some("20:00"),
        Some(next_run),
        Some(&updated_names),
        None,
        Some(now),
    );
    assert_eq!(updated_text, "Updated 2 addons at 20:00: Details, Plater");
    assert_eq!(icon_variant_for_status(STATUS_DONE_UPDATED), ICON_UPDATED);

    // Failed state
    let failed_names = vec!["BrokenAddon".to_string()];
    let failed_text = compute_core(
        STATUS_DONE_FAILED,
        None,
        None,
        20,
        20,
        0,
        1,
        19,
        0,
        Some("20:00"),
        Some(next_run),
        None,
        Some(&failed_names),
        Some(now),
    );
    assert_eq!(failed_text, "1 addon couldn't update at 20:00 - open Furphy for details");
    assert_eq!(icon_variant_for_status(STATUS_DONE_FAILED), ICON_FAILED);

    // Running states (checking & updating)
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
    assert_eq!(checking_start, "Starting the updater...");
    assert!(is_cycle_running(STATUS_CHECKING));
    assert_eq!(icon_variant_for_status(STATUS_CHECKING), ICON_BUSY);

    let checking_progress = compute_core(
        STATUS_CHECKING,
        None,
        None,
        15,
        5,
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
    assert_eq!(checking_progress, "Checking addons (6 of 15)...");

    let updating_text = compute_core(
        STATUS_UPDATING,
        None,
        Some("BigWigs"),
        15,
        15,
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
    assert_eq!(updating_text, "Updating BigWigs (1 of 3 updates)...");
    assert!(is_cycle_running(STATUS_UPDATING));
    assert_eq!(icon_variant_for_status(STATUS_UPDATING), ICON_BUSY);

    // Idle state
    assert!(!is_cycle_running(STATUS_IDLE));
    assert_eq!(icon_variant_for_status(STATUS_IDLE), ICON_NORMAL);

    // 2. Verify scheduler cycle lock and wake triggers
    let policy = Arc::new(NetworkPolicy::default());
    let runner = Arc::new(JobRunner::new(policy));
    let scheduler = Scheduler::new(runner, TrayStateSnapshot::default());

    // Verify wake triggers don't panic and send wake signals
    scheduler.trigger_cycle(true);
    scheduler.trigger_cycle(false);
    scheduler.notify_resume();

    // Verify snapshot access
    let snapshot_arc = scheduler.get_snapshot();
    let initial_status = {
        let s = tokio::runtime::Runtime::new().unwrap().block_on(snapshot_arc.lock());
        s.status.clone()
    };
    assert_eq!(initial_status, STATUS_IDLE);

    // 3. Verify power throttling (EcoQoS) helper execution
    let power_on = set_low_priority_and_eco_qos(true);
    assert!(power_on.is_ok(), "Setting EcoQoS on must succeed: {:?}", power_on);

    let power_off = set_low_priority_and_eco_qos(false);
    assert!(power_off.is_ok(), "Setting EcoQoS off must succeed: {:?}", power_off);

    let game_power_on = apply_game_mode_power(true);
    assert!(game_power_on.is_ok(), "apply_game_mode_power(true) must succeed: {:?}", game_power_on);

    let game_power_off = apply_game_mode_power(false);
    assert!(game_power_off.is_ok(), "apply_game_mode_power(false) must succeed: {:?}", game_power_off);
}

#[tokio::test]
async fn test_e2e_game_mode_detection_and_safeguards() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let ctx = TestContext::setup("game_mode");
    let wow_root = ctx.wow_dir.clone();
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let data_dir = furphy_lib::paths::get_data_dir();
    fs::create_dir_all(&data_dir).unwrap();

    let db_path = get_db_path();
    let mut conn = open_connection(&db_path).unwrap();
    conn.execute_batch(INITIAL_SCHEMA).unwrap();

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', 110002)",
        [],
    ).unwrap();

    // 1. Set FURPHY_DEV_FAKE_WOW=1. Verify is_wow_running() reports true.
    std::env::set_var("FURPHY_DEV_FAKE_WOW", "1");
    std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");
    assert!(is_wow_running(), "is_wow_running() must report true when FURPHY_TEST_WOW_RUNNING=1");
    assert!(is_wow_running_fresh(), "is_wow_running_fresh() must report true");

    // 2. Run sync with game running: verify reload_needed flag set on report
    // Set up mock HTTP server for sync
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mock_addr = listener.local_addr().unwrap();
    let mock_url = format!("http://{}", mock_addr);
    std::env::set_var("FURPHY_TEST_CF_BASEURL", &mock_url);

    let addon_zip = Arc::new(create_test_addon_zip(
        "GameModeAddon",
        "GameModeAddon",
        "## Interface: 110002\n## Title: Game Mode Addon\n## Version: 2.0.0\n",
    ));

    let server_zip = addon_zip.clone();
    let server_handle = tokio::spawn(async move {
        loop {
            let (mut socket, _) = match listener.accept().await {
                Ok(s) => s,
                Err(_) => break,
            };

            let zip_data = server_zip.clone();
            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                let n = match socket.read(&mut buf).await {
                    Ok(n) if n > 0 => n,
                    _ => return,
                };
                let req_str = String::from_utf8_lossy(&buf[..n]);
                let first_line = req_str.lines().next().unwrap_or("");
                let parts: Vec<&str> = first_line.split_whitespace().collect();
                if parts.len() < 2 {
                    return;
                }
                let path = parts[1];

                if path.contains("/files?") || path.ends_with("/files") {
                    let json = serde_json::json!({
                        "data": [{
                            "id": 50001,
                            "displayName": "GameModeAddon-2.0.0",
                            "fileName": "GameModeAddon-2.0.0.zip",
                            "fileLength": zip_data.len() as u64,
                            "releaseType": 1,
                            "projectId": 8888,
                            "gameVersions": ["11.0.2"],
                            "gameVersionTypeIds": [517],
                            "dateCreated": "2026-10-23T00:00:00Z"
                        }]
                    }).to_string();
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        json.len(),
                        json
                    );
                    let _ = socket.write_all(resp.as_bytes()).await;
                } else if path.contains("/download") {
                    let header = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        zip_data.len()
                    );
                    let _ = socket.write_all(header.as_bytes()).await;
                    let _ = socket.write_all(&zip_data).await;
                } else {
                    let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    let _ = socket.write_all(resp.as_bytes()).await;
                }
            });
        }
    });

    // Insert addon record requiring update
    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id, version, file_id) \
         VALUES ('gm-addon', 'retail', 'GameModeAddon', 'curseforge', 8888, '1.0.0', '50000')",
        [],
    ).unwrap();

    let policy = Arc::new(NetworkPolicy::default());

    // Game is running during sync
    let report_game_running = run_sync_for_flavour(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        Some(&["gm-addon".to_string()]),
        true,
    )
    .await
    .unwrap();

    assert_eq!(report_game_running.updated, 1);
    assert!(
        report_game_running.reload_needed,
        "reload_needed flag MUST be true when addon was installed/updated while WoW is running"
    );

    // When game is NOT running, reload_needed must be false
    std::env::set_var("FURPHY_TEST_WOW_RUNNING", "0");
    assert!(!is_wow_running_fresh());

    let report_game_stopped = run_sync_for_flavour(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        Some(&["gm-addon".to_string()]),
        true,
    )
    .await
    .unwrap();

    assert_eq!(report_game_stopped.updated, 1);
    assert!(
        !report_game_stopped.reload_needed,
        "reload_needed flag MUST be false when WoW is not running"
    );

    // 3. Verify balloon / notification formatting when game is active vs inactive
    // Case A: Game is running -> reload notice appended for done_updated
    std::env::set_var("FURPHY_TEST_WOW_RUNNING", "1");
    let (active_text, active_is_warn) = format_balloon_text("done_updated", &["BigWigs".to_string()]).unwrap();
    assert_eq!(active_is_warn, false);
    assert!(active_text.starts_with("BigWigs"));
    assert!(
        active_text.contains(" - WoW will use it once you type /reload in your chat window, or log out and back in."),
        "Active game balloon text must include reload notice: {}",
        active_text
    );

    // Case B: Game is inactive -> reload notice omitted for done_updated
    std::env::set_var("FURPHY_TEST_WOW_RUNNING", "0");
    let (inactive_text, inactive_is_warn) = format_balloon_text("done_updated", &["BigWigs".to_string()]).unwrap();
    assert_eq!(inactive_is_warn, false);
    assert_eq!(inactive_text, "BigWigs");
    assert!(
        !inactive_text.contains("/reload"),
        "Inactive game balloon text must NOT include reload notice"
    );

    // Case C: Notification suppression when game is in foreground (fullscreen / active game)
    reset_notification_tracking();
    std::env::set_var("FURPHY_TEST_GAME_FOREGROUND", "1");
    assert!(is_fullscreen_or_game_foreground());

    show_cycle_notification("done_updated", &["Details".to_string()]);
    let (balloon_shown_suppressed, text_suppressed) = get_balloon_info();
    assert!(
        !balloon_shown_suppressed,
        "Balloon notification must be suppressed when game is in foreground"
    );
    assert!(text_suppressed.is_empty());

    // When game is not in foreground -> notification shows
    reset_notification_tracking();
    std::env::set_var("FURPHY_TEST_GAME_FOREGROUND", "0");
    assert!(!is_fullscreen_or_game_foreground());

    show_cycle_notification("done_updated", &["Details".to_string()]);
    let (balloon_shown, text_shown) = get_balloon_info();
    assert!(
        balloon_shown,
        "Balloon notification must be shown when game is not in foreground"
    );
    assert_eq!(text_shown, "Details");

    server_handle.abort();
}
