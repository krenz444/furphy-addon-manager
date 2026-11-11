use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use furphy_lib::db::migrate::run_migrations;
use furphy_lib::db::open_connection;
use furphy_lib::engine::wtf_full::{backup_whole_wtf, restore_whole_wtf};
use furphy_lib::jobs::runner::{JobError, JobRunner};
use furphy_lib::net::breaker::HostBreaker;
use furphy_lib::net::policy::NetworkPolicy;
use furphy_lib::paths::{get_backups_dir, get_db_path};
use furphy_lib::system::game::TEST_ENV_LOCK;
use furphy_lib::system::schedule::Scheduler;
use furphy_lib::system::tray::get_tray_menu_items;
use furphy_lib::system::tray_status::TrayStateSnapshot;
use rusqlite::params;
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::{Mutex as AsyncMutex, Notify, oneshot};

static E2E_QUEUE_LOCK: AsyncMutex<()> = AsyncMutex::const_new(());

struct SandboxGuard {
    wow_root: PathBuf,
    local_data: PathBuf,
    orig_dev: Option<String>,
    orig_wowroot: Option<String>,
    orig_localappdata: Option<String>,
    orig_wow_running: Option<String>,
    orig_cf_baseurl: Option<String>,
}

impl SandboxGuard {
    fn new(tag: &str) -> Self {
        let _env_lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let id = uuid::Uuid::new_v4();
        let wow_root = std::env::temp_dir().join(format!("furphy test wow ({}-{})", tag, id));
        let local_data = std::env::temp_dir().join(format!("furphy local data ({}-{})", tag, id));

        for flv_dir in ["_retail_", "_classic_", "_forever_"] {
            std::fs::create_dir_all(wow_root.join(flv_dir).join("Interface").join("AddOns")).unwrap();
            std::fs::create_dir_all(wow_root.join(flv_dir).join("WTF")).unwrap();
        }
        std::fs::create_dir_all(&local_data).unwrap();
        std::fs::write(
            wow_root.join(".build.info"),
            "Product|Version\nwow|12.1.0.56819\nwow_classic|4.4.1.57294\n",
        )
        .unwrap();

        let guard = Self {
            wow_root: wow_root.clone(),
            local_data: local_data.clone(),
            orig_dev: std::env::var("FURPHY_DEV").ok(),
            orig_wowroot: std::env::var("FURPHY_DEV_WOWROOT").ok(),
            orig_localappdata: std::env::var("LOCALAPPDATA").ok(),
            orig_wow_running: std::env::var("FURPHY_TEST_WOW_RUNNING").ok(),
            orig_cf_baseurl: std::env::var("FURPHY_TEST_CF_BASEURL").ok(),
        };

        std::env::set_var("FURPHY_DEV", "1");
        std::env::set_var("FURPHY_DEV_WOWROOT", wow_root.to_str().unwrap());
        std::env::set_var("LOCALAPPDATA", local_data.to_str().unwrap());
        std::env::set_var("FURPHY_TEST_WOW_RUNNING", "0");
        guard
    }

    fn set_cf_base_url(&self, url: &str) {
        let _env_lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("FURPHY_TEST_CF_BASEURL", url);
    }

    fn db_path(&self) -> PathBuf {
        get_db_path()
    }
}

impl Drop for SandboxGuard {
    fn drop(&mut self) {
        let _env_lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        restore_env("FURPHY_DEV", self.orig_dev.as_deref());
        restore_env("FURPHY_DEV_WOWROOT", self.orig_wowroot.as_deref());
        restore_env("LOCALAPPDATA", self.orig_localappdata.as_deref());
        restore_env("FURPHY_TEST_WOW_RUNNING", self.orig_wow_running.as_deref());
        restore_env("FURPHY_TEST_CF_BASEURL", self.orig_cf_baseurl.as_deref());

        let _ = std::fs::remove_dir_all(&self.wow_root);
        let _ = std::fs::remove_dir_all(&self.local_data);
    }
}

fn restore_env(key: &str, val: Option<&str>) {
    match val {
        Some(v) => std::env::set_var(key, v),
        None => std::env::remove_var(key),
    }
}

fn setup_test_db(db_path: &PathBuf) {
    let mut conn = open_connection(db_path).unwrap();
    run_migrations(&mut conn).unwrap();
    conn.execute(
        "UPDATE flavours SET installed = 1, client_build = '12.1.0', client_interface = 120100 WHERE id = 'retail'",
        [],
    )
    .unwrap();
    conn.execute(
        "UPDATE flavours SET installed = 1, client_build = '4.4.1', client_interface = 40401 WHERE id = 'classic'",
        [],
    )
    .unwrap();
    conn.execute(
        "UPDATE flavours SET installed = 1, client_build = '1.15.4', client_interface = 11504 WHERE id = 'forever'",
        [],
    )
    .unwrap();
}

fn insert_cf_addon(db_path: &PathBuf, id: &str, flavour: &str, project_id: i64, name: &str, folder: &str) {
    let conn = open_connection(db_path).unwrap();
    conn.execute(
        "INSERT INTO addons (id, flavour, source, project_id, name, version, file_id, release_type, ignore_updates) \
         VALUES (?1, ?2, 'curseforge', ?3, ?4, '1.0.0', '10', 1, 0)",
        params![id, flavour, project_id, name],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES (?1, ?2, ?3)",
        params![flavour, folder, id],
    )
    .unwrap();
}

struct GatedCfServer {
    base_url: String,
    gate_started_rx: Option<oneshot::Receiver<()>>,
    gate_release: Arc<Notify>,
    observed_pids: Arc<std::sync::Mutex<Vec<i64>>>,
    handle: tokio::task::JoinHandle<()>,
}

impl Drop for GatedCfServer {
    fn drop(&mut self) {
        self.handle.abort();
    }
}

async fn start_gated_cf_server(gate_pid: Option<i64>) -> GatedCfServer {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let base_url = format!("http://127.0.0.1:{}", addr.port());

    let (started_tx, started_rx) = oneshot::channel::<()>();
    let started_tx = Arc::new(std::sync::Mutex::new(Some(started_tx)));
    let gate_release = Arc::new(Notify::new());
    let gate_fired = Arc::new(AtomicBool::new(false));
    let observed_pids = Arc::new(std::sync::Mutex::new(Vec::new()));

    let release_clone = Arc::clone(&gate_release);
    let pids_clone = Arc::clone(&observed_pids);
    let handle = tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let started_tx = Arc::clone(&started_tx);
            let gate_release = Arc::clone(&release_clone);
            let gate_fired = Arc::clone(&gate_fired);
            let observed_pids = Arc::clone(&pids_clone);

            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                let n = socket.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]);
                let first_line = req.lines().next().unwrap_or("");
                let path = first_line.split_whitespace().nth(1).unwrap_or("");

                // Parse `/api/v1/mods/<pid>/files...`
                let pid = path
                    .split('/')
                    .collect::<Vec<_>>()
                    .windows(2)
                    .find(|w| w[0] == "mods")
                    .and_then(|w| w[1].parse::<i64>().ok())
                    .unwrap_or(0);

                if pid > 0 {
                    observed_pids.lock().unwrap().push(pid);
                }

                if gate_pid == Some(pid) && !gate_fired.swap(true, Ordering::SeqCst) {
                    if let Some(tx) = started_tx.lock().unwrap().take() {
                        let _ = tx.send(());
                    }
                    gate_release.notified().await;
                }

                let body = json!({
                    "data": [{
                        "id": 10,
                        "displayName": "Test Addon 1.0.0",
                        "fileName": "TestAddon-1.0.0.zip",
                        "fileLength": 128,
                        "releaseType": 1,
                        "projectId": pid,
                        "gameVersions": ["12.1.0", "4.4.1"],
                        "gameVersionTypeIds": [517],
                        "dateCreated": "2026-11-10T00:00:00Z"
                    }]
                })
                .to_string();

                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = socket.write_all(resp.as_bytes()).await;
            });
        }
    });

    GatedCfServer {
        base_url,
        gate_started_rx: Some(started_rx),
        gate_release,
        observed_pids,
        handle,
    }
}

async fn wait_for_queued_len(runner: &JobRunner, expected: usize) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    loop {
        if runner.queue_snapshot().queued_jobs.len() == expected {
            return;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "Timed out waiting for queue length {} (current: {:?})",
            expected,
            runner.queue_snapshot().queued_jobs
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn test_e2e_job_queue_fifo_snapshot_and_coalesce() {
    let _suite_lock = E2E_QUEUE_LOCK.lock().await;
    let sandbox = SandboxGuard::new("fifo");
    let db_path = sandbox.db_path();
    setup_test_db(&db_path);
    insert_cf_addon(&db_path, "retail:cf:1001", "retail", 1001, "AlphaAddon", "AlphaAddon");
    insert_cf_addon(&db_path, "classic:cf:2002", "classic", 2002, "BetaAddon", "BetaAddon");

    let mut server = start_gated_cf_server(Some(1001)).await;
    sandbox.set_cf_base_url(&server.base_url);

    let policy = Arc::new(NetworkPolicy::new());
    let runner = Arc::new(JobRunner::new(policy));
    let exec_order = Arc::new(std::sync::Mutex::new(VecDeque::<&'static str>::new()));

    let local = tokio::task::LocalSet::new();
    local
        .run_until(async {
            // Job 1 occupies the runner and pauses inside CurseForge HTTP check on retail (pid 1001)
            let r1 = Arc::clone(&runner);
            let db1 = db_path.clone();
            let ord1 = Arc::clone(&exec_order);
            let h1 = tokio::task::spawn_local(async move {
                let mut conn = open_connection(&db1).unwrap();
                let res = r1.run_job(&mut conn, "check", Some("retail"), json!({})).await;
                ord1.lock().unwrap().push_back("job1");
                res
            });

            server.gate_started_rx.take().unwrap().await.unwrap();
            assert!(runner.is_busy().await, "runner must be busy while job1 is in-flight");
            assert!(runner.has_pending_kind("check"));

            // Coalesced background job skips cleanly when runner is busy
            {
                let mut conn_coalesce = open_connection(&db_path).unwrap();
                let skipped = runner
                    .run_job_coalesced_if_idle(&mut conn_coalesce, "check", Some("classic"), json!({}))
                    .await
                    .unwrap();
                assert!(skipped.is_none(), "coalesced job must skip cleanly when active job is running");
            }

            // Queue Job 2 (classic check) and wait until registered as position 1
            let r2 = Arc::clone(&runner);
            let db2 = db_path.clone();
            let ord2 = Arc::clone(&exec_order);
            let h2 = tokio::task::spawn_local(async move {
                let mut conn = open_connection(&db2).unwrap();
                let res = r2.run_job(&mut conn, "check", Some("classic"), json!({})).await;
                ord2.lock().unwrap().push_back("job2");
                res
            });
            wait_for_queued_len(&runner, 1).await;

            // Queue Job 3 (retail check) and wait until registered as position 2
            let r3 = Arc::clone(&runner);
            let db3 = db_path.clone();
            let ord3 = Arc::clone(&exec_order);
            let h3 = tokio::task::spawn_local(async move {
                let mut conn = open_connection(&db3).unwrap();
                let res = r3.run_job(&mut conn, "check", Some("retail"), json!({})).await;
                ord3.lock().unwrap().push_back("job3");
                res
            });
            wait_for_queued_len(&runner, 2).await;

            // Verify queue_snapshot accuracy
            let snap = runner.queue_snapshot();
            assert_eq!(snap.active_job.as_ref().map(|j| j.kind.as_str()), Some("check"));
            assert_eq!(
                snap.active_job.as_ref().and_then(|j| j.flavour.as_deref()),
                Some("retail")
            );
            assert_eq!(snap.queued_jobs.len(), 2);
            assert_eq!(snap.queued_jobs[0].position, 1);
            assert_eq!(snap.queued_jobs[0].flavour.as_deref(), Some("classic"));
            assert_eq!(snap.queued_jobs[1].position, 2);
            assert_eq!(snap.queued_jobs[1].flavour.as_deref(), Some("retail"));

            // Coalesced job still skips while jobs are queued
            {
                let mut conn_coalesce = open_connection(&db_path).unwrap();
                let skipped = runner
                    .run_job_coalesced_if_idle(&mut conn_coalesce, "sync", Some("classic"), json!({}))
                    .await
                    .unwrap();
                assert!(skipped.is_none());
            }

            // Release gate -> Job 1 completes, then Job 2 executes before Job 3 (FIFO)
            server.gate_release.notify_one();

            let res1 = h1.await.unwrap().expect("job1 should succeed without JobError::Busy");
            let res2 = h2.await.unwrap().expect("job2 should queue and succeed cleanly");
            let res3 = h3.await.unwrap().expect("job3 should queue behind job2 and succeed");
            assert_eq!(res1.state, "completed");
            assert_eq!(res2.state, "completed");
            assert_eq!(res3.state, "completed");
        })
        .await;

    let order: Vec<&'static str> = exec_order.lock().unwrap().iter().copied().collect();
    assert_eq!(order, vec!["job1", "job2", "job3"]);

    let pids = server.observed_pids.lock().unwrap().clone();
    assert_eq!(pids, vec![1001, 2002, 1001], "queued jobs must hit server strictly in FIFO order");

    assert!(!runner.is_busy().await);
    assert!(runner.queue_snapshot().active_job.is_none());
    assert!(runner.queue_snapshot().queued_jobs.is_empty());
}

#[tokio::test]
async fn test_e2e_job_queue_raii_recovery_on_error_and_abort() {
    let _suite_lock = E2E_QUEUE_LOCK.lock().await;
    let sandbox = SandboxGuard::new("raii");
    let db_path = sandbox.db_path();
    setup_test_db(&db_path);
    insert_cf_addon(&db_path, "retail:cf:1001", "retail", 1001, "AlphaAddon", "AlphaAddon");
    insert_cf_addon(&db_path, "classic:cf:2002", "classic", 2002, "BetaAddon", "BetaAddon");

    let mut server = start_gated_cf_server(Some(1001)).await;
    sandbox.set_cf_base_url(&server.base_url);

    let policy = Arc::new(NetworkPolicy::new());
    let runner = Arc::new(JobRunner::new(policy));

    let local = tokio::task::LocalSet::new();
    local
        .run_until(async {
            // Part A: Failing job in the queue returns Err(JobError::Execution) without leaking slot
            let r1 = Arc::clone(&runner);
            let db1 = db_path.clone();
            let h1 = tokio::task::spawn_local(async move {
                let mut conn = open_connection(&db1).unwrap();
                r1.run_job(&mut conn, "check", Some("retail"), json!({})).await
            });
            server.gate_started_rx.take().unwrap().await.unwrap();

            let r_fail = Arc::clone(&runner);
            let db_fail = db_path.clone();
            let h_fail = tokio::task::spawn_local(async move {
                let mut conn = open_connection(&db_fail).unwrap();
                r_fail.run_job(&mut conn, "check", Some("missing_flavour"), json!({})).await
            });
            wait_for_queued_len(&runner, 1).await;

            let r_ok = Arc::clone(&runner);
            let db_ok = db_path.clone();
            let h_ok = tokio::task::spawn_local(async move {
                let mut conn = open_connection(&db_ok).unwrap();
                r_ok.run_job(&mut conn, "check", Some("classic"), json!({})).await
            });
            wait_for_queued_len(&runner, 2).await;

            server.gate_release.notify_one();

            assert!(h1.await.unwrap().is_ok());
            let fail_res = h_fail.await.unwrap();
            assert!(matches!(fail_res, Err(JobError::Execution(_))));
            let ok_res = h_ok.await.unwrap().expect("subsequent queued job must recover and succeed");
            assert_eq!(ok_res.state, "completed");
            assert!(!runner.is_busy().await);

            // Part B: Aborting an in-flight future drops ActiveJobGuard and wakes the next queued job
            let mut server2 = start_gated_cf_server(Some(1001)).await;
            sandbox.set_cf_base_url(&server2.base_url);

            let r_abort = Arc::clone(&runner);
            let db_abort = db_path.clone();
            let h_abort = tokio::task::spawn_local(async move {
                let mut conn = open_connection(&db_abort).unwrap();
                r_abort.run_job(&mut conn, "check", Some("retail"), json!({})).await
            });
            server2.gate_started_rx.take().unwrap().await.unwrap();

            let r_after_abort = Arc::clone(&runner);
            let db_after_abort = db_path.clone();
            let h_after_abort = tokio::task::spawn_local(async move {
                let mut conn = open_connection(&db_after_abort).unwrap();
                r_after_abort.run_job(&mut conn, "check", Some("classic"), json!({})).await
            });
            wait_for_queued_len(&runner, 1).await;

            // Cancel in-flight task cleanly (simulating drop / panic unwind)
            h_abort.abort();
            let join_err = h_abort.await.unwrap_err();
            assert!(join_err.is_cancelled());

            let recovered = h_after_abort
                .await
                .unwrap()
                .expect("queued job must acquire released slot when active task is dropped/aborted");
            assert_eq!(recovered.state, "completed");
        })
        .await;

    assert!(!runner.is_busy().await);
    assert!(runner.queue_snapshot().active_job.is_none());
}

#[tokio::test]
async fn test_e2e_tray_update_all_now_and_manual_cycle() {
    let _suite_lock = E2E_QUEUE_LOCK.lock().await;
    let items = get_tray_menu_items("Checking Retail addons");
    assert_eq!(items.get(2).map(String::as_str), Some("Update all now"));

    let sandbox = SandboxGuard::new("tray");
    let db_path = sandbox.db_path();
    setup_test_db(&db_path);

    // Disable automatic background updates and simulate GUI window open
    {
        let conn = open_connection(&db_path).unwrap();
        conn.execute(
            "INSERT INTO settings (key, value) VALUES ('backgroundUpdates', 'false') \
             ON CONFLICT(key) DO UPDATE SET value = 'false'",
            [],
        )
        .unwrap();
    }

    let policy = Arc::new(NetworkPolicy::new());
    let runner = Arc::new(JobRunner::new(policy));
    let sched = Arc::new(
        Scheduler::new(Arc::clone(&runner), TrayStateSnapshot::default()).with_window_probe(|| true),
    );

    // Automatic cycle respects backgroundUpdates = false
    let auto_err = sched.run_cycle(false).await.unwrap_err();
    assert!(
        auto_err.contains("Background updates disabled"),
        "expected disabled error, got: {}",
        auto_err
    );

    // Manual cycle (tray "Update all now") runs regardless of backgroundUpdates = false and open window
    let manual_snap = sched.run_cycle(true).await.expect("manual cycle should succeed");
    assert_ne!(manual_snap.core_text, "Background updates off");

    // Verify trigger_cycle(true) drives the background loop manually too
    Arc::clone(&sched).start_background_loop();
    sched.trigger_cycle(true);

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let count: i64 = {
            let conn = open_connection(&db_path).unwrap();
            conn.query_row(
                "SELECT COUNT(*) FROM jobs WHERE kind = 'update-all-flavours' AND state = 'completed'",
                [],
                |r| r.get(0),
            )
            .unwrap()
        };
        if count >= 2 {
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "trigger_cycle(true) did not execute second manual update-all-flavours cycle (count={})",
            count
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

#[tokio::test]
async fn test_e2e_wtf_full_flavour_safety_prefix() {
    let _suite_lock = E2E_QUEUE_LOCK.lock().await;
    let sandbox = SandboxGuard::new("wtf");
    let db_path = sandbox.db_path();
    setup_test_db(&db_path);

    let wow_root = sandbox.wow_root.clone();
    let data_dir = get_backups_dir().parent().unwrap().to_path_buf();
    let backups_dir = get_backups_dir();

    std::fs::write(wow_root.join("_retail_").join("WTF").join("Config.wtf"), b"retail-v1\n").unwrap();
    std::fs::write(wow_root.join("_forever_").join("WTF").join("Config.wtf"), b"forever-v1\n").unwrap();

    let conn = open_connection(&db_path).unwrap();
    let retail_backup =
        backup_whole_wtf(&conn, &wow_root, "_retail_", "retail", &data_dir, Some("r1"), 5).unwrap();
    let forever_backup =
        backup_whole_wtf(&conn, &wow_root, "_forever_", "forever", &data_dir, Some("f1"), 5).unwrap();

    // Mutate live Config.wtf files before restore
    std::fs::write(wow_root.join("_retail_").join("WTF").join("Config.wtf"), b"retail-v2\n").unwrap();
    std::fs::write(wow_root.join("_forever_").join("WTF").join("Config.wtf"), b"forever-v2\n").unwrap();

    restore_whole_wtf(&conn, &wow_root, "_retail_", "retail", &retail_backup.id, &data_dir).unwrap();
    restore_whole_wtf(&conn, &wow_root, "_forever_", "forever", &forever_backup.id, &data_dir).unwrap();

    assert_eq!(
        std::fs::read_to_string(wow_root.join("_retail_").join("WTF").join("Config.wtf")).unwrap(),
        "retail-v1\n"
    );
    assert_eq!(
        std::fs::read_to_string(wow_root.join("_forever_").join("WTF").join("Config.wtf")).unwrap(),
        "forever-v1\n"
    );

    let folder_names: Vec<String> = std::fs::read_dir(&backups_dir)
        .unwrap()
        .flatten()
        .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();

    assert!(
        folder_names.iter().any(|n| n.starts_with("wtf_safety_retail_")),
        "missing retail-prefixed safety snapshot in {:?}",
        folder_names
    );
    assert!(
        folder_names.iter().any(|n| n.starts_with("wtf_safety_forever_")),
        "missing forever-prefixed safety snapshot in {:?}",
        folder_names
    );
    assert!(
        !folder_names
            .iter()
            .any(|n| n.starts_with("wtf_safety_") && !n.starts_with("wtf_safety_retail_") && !n.starts_with("wtf_safety_forever_")),
        "unexpected unprefixed safety folder in {:?}",
        folder_names
    );
}

#[test]
fn test_e2e_host_breaker_cooldown_decay() {
    let breaker = HostBreaker::with_cooldown(Duration::from_millis(45));
    let host = "api.curseforge.com";

    assert!(!breaker.is_open(host));
    assert!(breaker.assert_reachable(host).is_ok());

    breaker.register_connectivity_failure(host);
    breaker.register_connectivity_failure(host);
    assert!(!breaker.is_open(host), "should not trip before 3 failures");

    breaker.register_connectivity_failure(host);
    assert!(breaker.is_open(host), "must open on 3rd connectivity failure");
    assert!(breaker.assert_reachable(host).is_err());

    // Wait beyond cooldown -> breaker closes half-open for probe
    std::thread::sleep(Duration::from_millis(65));
    assert!(!breaker.is_open(host), "breaker must decay after cooldown");
    assert!(breaker.assert_reachable(host).is_ok());

    // Single failure while decayed (count was clamped, not reset) trips immediately again
    breaker.register_connectivity_failure(host);
    assert!(breaker.is_open(host));

    // Cooldown + register_success clears failure streak completely
    std::thread::sleep(Duration::from_millis(65));
    breaker.register_success(host);
    assert!(!breaker.is_open(host));

    breaker.register_connectivity_failure(host);
    breaker.register_connectivity_failure(host);
    assert!(!breaker.is_open(host), "success reset must require 3 fresh failures");
}
