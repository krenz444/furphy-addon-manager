use std::sync::atomic::{AtomicBool, Ordering as AtomicOrdering};
use std::sync::{Arc, Mutex as StdMutex, Weak};
use std::time::Duration;
use chrono::{DateTime, Utc};
use rusqlite::Connection;
use serde_json::{json, Value};
use tokio::sync::Mutex;
use crate::db::open_connection;

use crate::db::repo::get_settings_map;
use crate::jobs::runner::JobRunner;
use crate::paths::get_db_path;
use crate::system::game::is_wow_running;
use crate::system::notify::show_cycle_notification;
use crate::system::power::apply_game_mode_power;
use crate::system::tray_status::{
    compute_core, make_tooltip, TrayStateSnapshot, ICON_BUSY, ICON_FAILED, ICON_NORMAL,
    ICON_UPDATED, STATUS_CHECKING, STATUS_DONE_CLEAN, STATUS_DONE_FAILED, STATUS_DONE_UPDATED,
    STATUS_IDLE, STATUS_UNREACHABLE, STATUS_WAITING_BUSY,
};

pub const DEFAULT_INTERVAL_MINUTES: i64 = 120;
pub const MIN_INTERVAL_MINUTES: i64 = 30;
pub const MAX_INTERVAL_MINUTES: i64 = 1440;
pub const RETRY_MINUTES_ON_BUSY: i64 = 5;
pub const FIRST_CYCLE_DELAY_SECS: i64 = 90;
pub const STARTUP_WINDOW_OPEN_FLOOR_SECS: i64 = 300;
pub const POST_WAKE_GRACE_SECS: i64 = 180;
pub const INTERACTIVE_COOLDOWN_SECS: i64 = 60;

static LIVE_SCHEDULER: StdMutex<Option<Weak<Scheduler>>> = StdMutex::new(None);

/// Registers the process-wide `Scheduler` so Tauri commands like
/// `set_background_updates` update live in-memory state and tray UI.
pub fn register_live_scheduler(scheduler: &Arc<Scheduler>) {
    if let Ok(mut guard) = LIVE_SCHEDULER.lock() {
        *guard = Some(Arc::downgrade(scheduler));
    }
}

/// Pushes an updated `TrayStateSnapshot` into the live `Scheduler` (if registered)
/// and updates the tray icon, tooltip, and menu checkmarks immediately.
pub fn sync_live_scheduler_snapshot(new_state: &TrayStateSnapshot) {
    let sched_opt = LIVE_SCHEDULER
        .lock()
        .ok()
        .and_then(|guard| guard.as_ref().and_then(|w| w.upgrade()));

    if let Some(sched) = sched_opt {
        if tokio::runtime::Handle::try_current().is_ok() {
            if let Ok(mut guard) = sched.snapshot.try_lock() {
                *guard = new_state.clone();
            } else {
                let snap_arc = sched.snapshot.clone();
                let st = new_state.clone();
                tokio::spawn(async move {
                    let mut guard = snap_arc.lock().await;
                    *guard = st;
                });
            }
        } else {
            let mut guard = sched.snapshot.blocking_lock();
            *guard = new_state.clone();
        }
        sched.sync_tray_display(new_state);
    }
}

struct CycleLockGuard {
    flag: Arc<AtomicBool>,
}

impl CycleLockGuard {
    fn try_acquire(flag: &Arc<AtomicBool>) -> Option<Self> {
        if flag
            .compare_exchange(
                false,
                true,
                AtomicOrdering::AcqRel,
                AtomicOrdering::Acquire,
            )
            .is_ok()
        {
            Some(Self { flag: flag.clone() })
        } else {
            None
        }
    }
}

impl Drop for CycleLockGuard {
    fn drop(&mut self) {
        self.flag.store(false, AtomicOrdering::Release);
    }
}

/// Computes the initial `next_run_at` deadline at startup or when re-enabling
/// background updates so recent runs wait out their remaining cadence instead
/// of firing unconditionally 90 seconds after every restart.
pub fn compute_initial_next_run_at(
    now: DateTime<Utc>,
    last_run_at: Option<DateTime<Utc>>,
    persisted_next_run_at: Option<DateTime<Utc>>,
    interval_minutes: i64,
    window_open_on_launch: bool,
) -> DateTime<Utc> {
    let clamped_minutes = interval_minutes.clamp(MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES);
    let cadence = chrono::Duration::minutes(clamped_minutes);
    let min_floor_secs = if window_open_on_launch {
        STARTUP_WINDOW_OPEN_FLOOR_SECS
    } else {
        FIRST_CYCLE_DELAY_SECS
    };
    let min_floor = now + chrono::Duration::seconds(min_floor_secs);

    if let Some(last) = last_run_at {
        let elapsed = now - last;
        if elapsed >= chrono::Duration::zero() && elapsed < cadence {
            let target = last + cadence;
            return if target > min_floor { target } else { min_floor };
        }
        if let Some(next_t) = persisted_next_run_at {
            if next_t > now && next_t <= now + cadence {
                return if next_t > min_floor { next_t } else { min_floor };
            }
        }
        return min_floor;
    }

    if let Some(next_t) = persisted_next_run_at {
        if next_t > now && next_t <= now + cadence {
            return if next_t > min_floor { next_t } else { min_floor };
        }
    }

    min_floor
}

/// Returns the most recent timestamp between `tray_state.last_run_at` and the
/// latest completed `check`, `sync`, or `update-all-flavours` job in SQLite.
pub fn effective_last_run_at(
    conn: &Connection,
    snapshot: &TrayStateSnapshot,
) -> Option<DateTime<Utc>> {
    let db_last: Option<DateTime<Utc>> = conn
        .query_row(
            "SELECT finished_at FROM jobs \
             WHERE state = 'completed' \
               AND kind IN ('check', 'sync', 'update-all-flavours') \
               AND finished_at IS NOT NULL \
             ORDER BY finished_at DESC LIMIT 1",
            [],
            |r| r.get::<_, String>(0),
        )
        .ok()
        .and_then(|s| DateTime::parse_from_rfc3339(&s).ok())
        .map(|dt| dt.with_timezone(&Utc));

    match (snapshot.last_run_at, db_last) {
        (Some(a), Some(b)) => Some(if a >= b { a } else { b }),
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (None, None) => None,
    }
}

fn extract_cycle_job_names(results_json: Option<&str>) -> (Vec<String>, Vec<String>) {
    let mut updated_names = Vec::new();
    let mut failed_names = Vec::new();

    let Some(res_str) = results_json else {
        return (updated_names, failed_names);
    };
    let Ok(val) = serde_json::from_str::<Value>(res_str) else {
        return (updated_names, failed_names);
    };
    let Some(arr) = val.as_array() else {
        return (updated_names, failed_names);
    };

    for item in arr {
        if let Some(results) = item.get("results").and_then(|r| r.as_array()) {
            for r in results {
                let status = r.get("status").and_then(|s| s.as_str()).unwrap_or("");
                let Some(name) = r.get("name").and_then(|n| n.as_str()) else {
                    continue;
                };
                if status == "Updated" || status == "Installed" {
                    updated_names.push(name.to_string());
                } else if status == "Failed" {
                    failed_names.push(name.to_string());
                }
            }
        }
        if let Some(up_arr) = item.get("updated").and_then(|u| u.as_array()) {
            for n in up_arr {
                if let Some(ns) = n.as_str() {
                    updated_names.push(ns.to_string());
                }
            }
        }
        if let Some(fail_arr) = item.get("failed").and_then(|f| f.as_array()) {
            for n in fail_arr {
                if let Some(ns) = n.as_str() {
                    failed_names.push(ns.to_string());
                }
            }
        }
    }

    (updated_names, failed_names)
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum AutoInstallDecision {
    NoUpdate,
    SkipInstallerFailedBefore,
    SkipWindowOpen,
    SkipRunnerBusy,
    Install,
}

pub fn auto_install_decision(
    auto_install: bool,
    has_update: bool,
    installer_failed_before: bool,
    window_open: bool,
    runner_busy: bool,
) -> AutoInstallDecision {
    if !auto_install || !has_update {
        AutoInstallDecision::NoUpdate
    } else if installer_failed_before {
        AutoInstallDecision::SkipInstallerFailedBefore
    } else if window_open {
        AutoInstallDecision::SkipWindowOpen
    } else if runner_busy {
        AutoInstallDecision::SkipRunnerBusy
    } else {
        AutoInstallDecision::Install
    }
}

#[cfg(test)]
mod install_decision_tests {
    use super::*;

    #[test]
    fn test_no_update() {
        assert_eq!(
            auto_install_decision(false, true, false, false, false),
            AutoInstallDecision::NoUpdate
        );
        assert_eq!(
            auto_install_decision(true, false, false, false, false),
            AutoInstallDecision::NoUpdate
        );
        assert_eq!(
            auto_install_decision(false, false, false, false, false),
            AutoInstallDecision::NoUpdate
        );
    }

    #[test]
    fn test_skip_installer_failed_before() {
        assert_eq!(
            auto_install_decision(true, true, true, false, false),
            AutoInstallDecision::SkipInstallerFailedBefore
        );
    }

    #[test]
    fn test_skip_window_open() {
        assert_eq!(
            auto_install_decision(true, true, false, true, false),
            AutoInstallDecision::SkipWindowOpen
        );
    }

    #[test]
    fn test_skip_runner_busy() {
        assert_eq!(
            auto_install_decision(true, true, false, false, true),
            AutoInstallDecision::SkipRunnerBusy
        );
    }

    #[test]
    fn test_install() {
        assert_eq!(
            auto_install_decision(true, true, false, false, false),
            AutoInstallDecision::Install
        );
    }

    #[test]
    fn test_window_open_wins_over_runner_busy() {
        assert_eq!(
            auto_install_decision(true, true, false, true, true),
            AutoInstallDecision::SkipWindowOpen
        );
    }

    #[test]
    fn test_installer_failed_before_wins_over_window_open() {
        assert_eq!(
            auto_install_decision(true, true, true, true, false),
            AutoInstallDecision::SkipInstallerFailedBefore
        );
    }
}

pub type TrayUpdater = Arc<dyn Fn(&TrayStateSnapshot) + Send + Sync>;

pub struct Scheduler {
    runner: Arc<JobRunner>,
    snapshot: Arc<Mutex<TrayStateSnapshot>>,
    is_running_cycle: Arc<AtomicBool>,
    trigger_tx: tokio::sync::mpsc::UnboundedSender<bool>,
    trigger_rx: Mutex<Option<tokio::sync::mpsc::UnboundedReceiver<bool>>>,
    window_probe: Option<Arc<dyn Fn() -> bool + Send + Sync>>,
    tray_updater: StdMutex<Option<TrayUpdater>>,
    last_notified_held_ids: Mutex<std::collections::HashSet<String>>,
}

impl Scheduler {
    pub fn new(runner: Arc<JobRunner>, initial_snapshot: TrayStateSnapshot) -> Self {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        Self {
            runner,
            snapshot: Arc::new(Mutex::new(initial_snapshot)),
            is_running_cycle: Arc::new(AtomicBool::new(false)),
            trigger_tx: tx,
            trigger_rx: Mutex::new(Some(rx)),
            window_probe: None,
            tray_updater: StdMutex::new(None),
            last_notified_held_ids: Mutex::new(std::collections::HashSet::new()),
        }
    }

    pub fn with_window_probe(mut self, probe: impl Fn() -> bool + Send + Sync + 'static) -> Self {
        self.window_probe = Some(Arc::new(probe));
        self
    }

    pub fn with_tray_updater(
        self,
        updater: impl Fn(&TrayStateSnapshot) + Send + Sync + 'static,
    ) -> Self {
        self.set_tray_updater(Arc::new(updater));
        self
    }

    pub fn set_tray_updater(&self, updater: TrayUpdater) {
        if let Ok(mut guard) = self.tray_updater.lock() {
            *guard = Some(updater);
        }
    }

    fn sync_tray_display(&self, snapshot: &TrayStateSnapshot) {
        let updater_opt = self.tray_updater.lock().ok().and_then(|g| g.clone());
        if let Some(updater) = updater_opt {
            updater(snapshot);
        }
    }

    pub fn is_window_open(&self) -> bool {
        match self.window_probe.as_deref() {
            Some(probe) => probe(),
            None => false,
        }
    }

    pub fn trigger_cycle(&self, is_manual: bool) {
        let _ = self.trigger_tx.send(is_manual);
    }

    pub fn notify_resume(&self) {
        self.trigger_cycle(false);
    }

    pub fn get_snapshot(&self) -> Arc<Mutex<TrayStateSnapshot>> {
        self.snapshot.clone()
    }

    pub fn get_effective_interval_minutes(conn: &Connection) -> i64 {
        let settings = get_settings_map(conn).unwrap_or_default();
        let raw = settings
            .get("backgroundIntervalMinutes")
            .and_then(|v| v.as_i64())
            .unwrap_or(DEFAULT_INTERVAL_MINUTES);

        raw.clamp(MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES)
    }

    pub fn are_background_updates_enabled(conn: &Connection) -> bool {
        let settings = get_settings_map(conn).unwrap_or_default();
        settings
            .get("backgroundUpdates")
            .and_then(|v| v.as_bool())
            .unwrap_or(true)
    }

    pub fn persist_tray_state(conn: &Connection, state: &TrayStateSnapshot) -> Result<(), String> {
        let json = serde_json::to_string(state).map_err(|e| e.to_string())?;
        conn.execute(
            "INSERT INTO tray_state (id, data) VALUES (1, ?1) \
             ON CONFLICT(id) DO UPDATE SET data = ?1",
            rusqlite::params![json],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn load_persisted_tray_state(conn: &Connection) -> Option<TrayStateSnapshot> {
        let mut stmt = conn.prepare("SELECT data FROM tray_state WHERE id = 1").ok()?;
        let data_str: String = stmt.query_row([], |r| r.get(0)).ok()?;
        serde_json::from_str(&data_str).ok()
    }

    /// Executes one full background update cycle across all flavours.
    pub async fn run_cycle(&self, is_manual: bool) -> Result<TrayStateSnapshot, String> {
        // Prevent concurrent cycles inside the scheduler; RAII guard ensures release on error or panic.
        let _cycle_guard = CycleLockGuard::try_acquire(&self.is_running_cycle)
            .ok_or_else(|| "Cycle already in progress".to_string())?;

        if is_manual && self.runner.has_pending_kind("update-all-flavours") {
            crate::logging::append_app_log(
                "INFO",
                "Manual tray Update all now skipped: update-all-flavours is already running or queued",
            );
            return Err("Update all is already running or queued".to_string());
        }

        let db_path = get_db_path();
        let mut conn = open_connection(&db_path).map_err(|e| e.to_string())?;

        let bg_enabled = Self::are_background_updates_enabled(&conn);

        // Check if background updates are enabled (for automatic runs)
        if !is_manual && !bg_enabled {
            let off_snapshot = {
                let mut s = self.snapshot.lock().await;
                s.status = STATUS_IDLE.to_string();
                s.core_text = "Background updates off".to_string();
                s.tooltip = make_tooltip(&s.core_text);
                s.icon_variant = ICON_NORMAL.to_string();
                s.next_run_at = None;
                let _ = Self::persist_tray_state(&conn, &s);
                s.clone()
            };
            self.sync_tray_display(&off_snapshot);
            return Err("Background updates disabled in settings".to_string());
        }

        // Automatic background cycles defer cleanly while the GUI is open, another job
        // is running/queued, or an interactive user job finished recently.
        if !is_manual {
            let window_open = self.is_window_open();
            let runner_busy = self.runner.is_busy().await;
            let interactive_recent = self
                .runner
                .last_interactive_finished_at()
                .map(|finished| Utc::now() - finished < chrono::Duration::seconds(INTERACTIVE_COOLDOWN_SECS))
                .unwrap_or(false);

            if window_open || runner_busy || interactive_recent {
                let reason = if runner_busy {
                    "runner busy"
                } else if window_open {
                    "window open"
                } else {
                    "recent interactive job"
                };
                crate::logging::append_app_log(
                    "INFO",
                    &format!(
                        "Deferring background update cycle ({}) for {} minutes",
                        reason, RETRY_MINUTES_ON_BUSY
                    ),
                );
                let defer_until = Utc::now() + chrono::Duration::minutes(RETRY_MINUTES_ON_BUSY);
                let deferred_snapshot = {
                    let mut s = self.snapshot.lock().await;
                    s.next_run_at = Some(defer_until);
                    if runner_busy {
                        s.status = STATUS_WAITING_BUSY.to_string();
                        s.core_text = compute_core(
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
                            Some(defer_until),
                            None,
                            None,
                            None,
                        );
                    } else if s.status == STATUS_IDLE
                        || s.status == STATUS_WAITING_BUSY
                        || s.status == STATUS_CHECKING
                    {
                        s.status = STATUS_IDLE.to_string();
                        s.core_text = compute_core(
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
                            Some(defer_until),
                            None,
                            None,
                            None,
                        );
                    }
                    s.icon_variant = ICON_NORMAL.to_string();
                    s.tooltip = make_tooltip(&s.core_text);
                    let _ = Self::persist_tray_state(&conn, &s);
                    s.clone()
                };
                self.sync_tray_display(&deferred_snapshot);
                return Ok(deferred_snapshot);
            }
        }

        let interval = Self::get_effective_interval_minutes(&conn);
        let game_running = is_wow_running();

        // 1. Set CPU priority per ADR-309
        let _ = apply_game_mode_power(game_running);

        // 2. Transition state to 'checking'
        let checking_snapshot = {
            let mut s = self.snapshot.lock().await;
            s.status = STATUS_CHECKING.to_string();
            s.core_text = compute_core(
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
                None,
            );
            s.tooltip = make_tooltip(&s.core_text);
            s.icon_variant = ICON_BUSY.to_string();
            let _ = Self::persist_tray_state(&conn, &s);
            s.clone()
        };
        self.sync_tray_display(&checking_snapshot);

        // 3. Execute update-all-flavours job:
        //    - Manual tray click ("Update all now") queues cleanly behind any active job.
        //    - Automatic background cycle skips cleanly if another job became active.
        let job_res = if is_manual {
            self.runner
                .run_job(&mut conn, "update-all-flavours", None, json!({"origin": "manual"}))
                .await
                .map(Some)
        } else {
            self.runner
                .run_job_coalesced_if_idle(
                    &mut conn,
                    "update-all-flavours",
                    None,
                    json!({"origin": "background"}),
                )
                .await
        };

        let now = Utc::now();
        let done_stamp = chrono::Local::now().format("%H:%M").to_string();

        let final_snapshot = match job_res {
            Ok(Some(job)) => {
                let (updated_names, failed_names) = extract_cycle_job_names(job.results.as_deref());

                let status = if !failed_names.is_empty() {
                    STATUS_DONE_FAILED
                } else if !updated_names.is_empty() {
                    STATUS_DONE_UPDATED
                } else {
                    STATUS_DONE_CLEAN
                };

                let next_run_utc = if bg_enabled {
                    Some(now + chrono::Duration::minutes(interval))
                } else {
                    None
                };

                let core = if !bg_enabled && status == STATUS_DONE_CLEAN {
                    format!(
                        "Everything's up to date - checked {} - background updates off",
                        done_stamp
                    )
                } else {
                    compute_core(
                        status,
                        None,
                        None,
                        0,
                        0,
                        updated_names.len(),
                        failed_names.len(),
                        0,
                        updated_names.len(),
                        Some(&done_stamp),
                        next_run_utc,
                        Some(&updated_names),
                        Some(&failed_names),
                        None,
                    )
                };

                let mut s = self.snapshot.lock().await;
                s.status = status.to_string();
                s.core_text = core;
                s.tooltip = make_tooltip(&s.core_text);
                s.icon_variant = match status {
                    STATUS_DONE_FAILED => ICON_FAILED.to_string(),
                    STATUS_DONE_UPDATED => ICON_UPDATED.to_string(),
                    _ => ICON_NORMAL.to_string(),
                };
                s.last_result = Some(match status {
                    STATUS_DONE_FAILED => "failed".to_string(),
                    STATUS_DONE_UPDATED => "updated".to_string(),
                    _ => "up_to_date".to_string(),
                });
                s.last_run_at = Some(now);
                s.next_run_at = next_run_utc;
                s.updated = updated_names.len();
                s.failed = failed_names.len();
                s.updated_names = updated_names.clone();
                s.failed_names = failed_names.clone();
                s.reload_needed = job.reload_needed;

                let _ = Self::persist_tray_state(&conn, &s);

                // Notification
                let notify_names = if status == STATUS_DONE_FAILED {
                    &failed_names
                } else {
                    &updated_names
                };
                show_cycle_notification(status, notify_names);

                // Held addons notification: notify only when set of held addon IDs changes
                let held_addon_ids: std::collections::HashSet<String> = {
                    let mut stmt = conn.prepare("SELECT addon_id FROM check_results WHERE held = 1").ok();
                    if let Some(ref mut st) = stmt {
                        st.query_map([], |r| r.get::<_, String>(0))
                            .ok()
                            .map(|rows| rows.filter_map(|r| r.ok()).collect())
                            .unwrap_or_default()
                    } else {
                        std::collections::HashSet::new()
                    }
                };

                if !held_addon_ids.is_empty() {
                    let mut cache = self.last_notified_held_ids.lock().await;
                    if *cache != held_addon_ids {
                        *cache = held_addon_ids.clone();
                        crate::system::notify::show_notification(
                            "Furphy",
                            &format!("{} addon update(s) held back for newer WoW version", held_addon_ids.len()),
                            false,
                        );
                    }
                } else {
                    let mut cache = self.last_notified_held_ids.lock().await;
                    cache.clear();
                }

                s.clone()
            }
            Ok(None) => {
                crate::logging::append_app_log(
                    "INFO",
                    "Background update cycle skipped cleanly: JobRunner became busy",
                );
                let next_run_utc = if bg_enabled {
                    Some(now + chrono::Duration::minutes(RETRY_MINUTES_ON_BUSY))
                } else {
                    None
                };
                let core = compute_core(
                    STATUS_WAITING_BUSY,
                    None,
                    None,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    Some(&done_stamp),
                    next_run_utc,
                    None,
                    None,
                    None,
                );

                let mut s = self.snapshot.lock().await;
                s.status = STATUS_WAITING_BUSY.to_string();
                s.core_text = core;
                s.tooltip = make_tooltip(&s.core_text);
                s.icon_variant = ICON_NORMAL.to_string();
                s.next_run_at = next_run_utc;
                let _ = Self::persist_tray_state(&conn, &s);
                s.clone()
            }
            Err(e) => {
                crate::logging::append_app_log(
                    "ERROR",
                    &format!("Update cycle failed: {}", e),
                );
                let next_run_utc = if bg_enabled {
                    Some(now + chrono::Duration::minutes(RETRY_MINUTES_ON_BUSY))
                } else {
                    None
                };
                let core = compute_core(
                    STATUS_UNREACHABLE,
                    None,
                    None,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    Some(&done_stamp),
                    next_run_utc,
                    None,
                    None,
                    None,
                );

                let mut s = self.snapshot.lock().await;
                s.status = STATUS_UNREACHABLE.to_string();
                s.core_text = core;
                s.tooltip = make_tooltip(&s.core_text);
                s.icon_variant = ICON_NORMAL.to_string();
                s.last_run_at = Some(now);
                s.next_run_at = next_run_utc;
                let _ = Self::persist_tray_state(&conn, &s);
                s.clone()
            }
        };

        self.sync_tray_display(&final_snapshot);

        // Reset power throttling if game is no longer running
        if !is_wow_running() {
            let _ = apply_game_mode_power(false);
        }

        Ok(final_snapshot)
    }

    /// Starts the background scheduling loop.
    pub fn start_background_loop(self: Arc<Self>) {
        let window_open_on_launch = self.is_window_open();
        let (initial_delay, is_enabled) = {
            let db_path = get_db_path();
            if let Ok(conn) = open_connection(&db_path) {
                let enabled = Self::are_background_updates_enabled(&conn);
                if enabled {
                    let interval = Self::get_effective_interval_minutes(&conn);
                    let snap_copy = self.snapshot.try_lock().map(|g| g.clone()).unwrap_or_default();
                    let last_run = effective_last_run_at(&conn, &snap_copy);
                    let next_run = compute_initial_next_run_at(
                        Utc::now(),
                        last_run,
                        snap_copy.next_run_at,
                        interval,
                        window_open_on_launch,
                    );
                    (Some(next_run), true)
                } else {
                    (None, false)
                }
            } else {
                let fallback_secs = if window_open_on_launch {
                    STARTUP_WINDOW_OPEN_FLOOR_SECS
                } else {
                    FIRST_CYCLE_DELAY_SECS
                };
                (Some(Utc::now() + chrono::Duration::seconds(fallback_secs)), true)
            }
        };

        let startup_snapshot = {
            let mut s = match self.snapshot.try_lock() {
                Ok(guard) => guard,
                Err(_) => return,
            };
            s.status = STATUS_IDLE.to_string();
            s.icon_variant = ICON_NORMAL.to_string();
            s.next_run_at = initial_delay;
            s.core_text = if is_enabled {
                compute_core(
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
                    initial_delay,
                    None,
                    None,
                    None,
                )
            } else {
                "Background updates off".to_string()
            };
            s.tooltip = make_tooltip(&s.core_text);
            if let Ok(conn) = open_connection(get_db_path()) {
                let _ = Self::persist_tray_state(&conn, &s);
            }
            s.clone()
        };
        self.sync_tray_display(&startup_snapshot);

        let sched = self.clone();
        std::thread::Builder::new()
            .name("furphy-scheduler".into())
            .spawn(move || {
                let rt = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(r) => r,
                    Err(e) => {
                        crate::logging::append_app_log("ERROR", &format!("Failed to start scheduler runtime: {}", e));
                        return;
                    }
                };

                rt.block_on(async move {
                    let mut rx = {
                        let mut guard = sched.trigger_rx.lock().await;
                        guard.take()
                    };

                    let mut hourly_ticker = tokio::time::interval(Duration::from_secs(3600));
                    // Skip the immediate first tick of hourly_ticker so it doesn't fire at startup
                    hourly_ticker.tick().await;

                    // Check wall clock every 5 seconds to handle sleep / resume gracefully
                    let mut poll_interval = tokio::time::interval(Duration::from_secs(5));
                    let mut last_poll_wall = Utc::now();

                    loop {
                        tokio::select! {
                            Some(manual) = async {
                                if let Some(ref mut r) = rx {
                                    r.recv().await
                                } else {
                                    std::future::pending().await
                                }
                            } => {
                                let _ = sched.run_cycle(manual).await;
                            }
                            _ = poll_interval.tick() => {
                                let now = Utc::now();
                                let wall_gap = now - last_poll_wall;
                                last_poll_wall = now;

                                // Detect sleep/hibernate jump (>60s elapsed on a 5s timer) and apply
                                // post-wake grace instead of immediately ambushing network/UI.
                                if wall_gap > chrono::Duration::seconds(60) {
                                    let grace_deadline = now + chrono::Duration::seconds(POST_WAKE_GRACE_SECS);
                                    let wake_snapshot = {
                                        let mut s = sched.snapshot.lock().await;
                                        if let Some(next_t) = s.next_run_at {
                                            if next_t < grace_deadline {
                                                crate::logging::append_app_log(
                                                    "INFO",
                                                    &format!(
                                                        "System resume detected ({}s gap); deferring due check for {}s",
                                                        wall_gap.num_seconds(),
                                                        POST_WAKE_GRACE_SECS
                                                    ),
                                                );
                                                s.next_run_at = Some(grace_deadline);
                                                if s.status == STATUS_IDLE || s.status == STATUS_WAITING_BUSY {
                                                    s.status = STATUS_IDLE.to_string();
                                                    s.core_text = compute_core(
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
                                                        Some(grace_deadline),
                                                        None,
                                                        None,
                                                        None,
                                                    );
                                                    s.tooltip = make_tooltip(&s.core_text);
                                                }
                                                if let Ok(conn) = open_connection(get_db_path()) {
                                                    let _ = Self::persist_tray_state(&conn, &s);
                                                }
                                                Some(s.clone())
                                            } else {
                                                None
                                            }
                                        } else {
                                            None
                                        }
                                    };
                                    if let Some(snap) = wake_snapshot {
                                        sched.sync_tray_display(&snap);
                                    }
                                    continue;
                                }

                                let should_run = {
                                    let s = sched.snapshot.lock().await;
                                    if let Some(next_t) = s.next_run_at {
                                        now >= next_t
                                    } else {
                                        false
                                    }
                                };

                                if should_run {
                                    let _ = sched.run_cycle(false).await;
                                }
                            }
                            _ = hourly_ticker.tick() => {
                                // Hourly self-update check and catalogue refresh (§2.H, §2.K, §5.4)
                                crate::logging::append_app_log("INFO", "Running hourly maintenance crawl");
                                if let Ok(status) = crate::update::app_update::check_for_updates(None).await {
                                    if let Ok(conn) = open_connection(get_db_path()) {
                                        // A version whose installer already failed is not retried every
                                        // hour: the error stays visible and Settings can still install it.
                                        let failed_before =
                                            crate::update::app_update::save_check_result_keeping_install_failure(&conn, &status);
                                        let auto_install = {
                                            let settings = get_settings_map(&conn).unwrap_or_default();
                                            settings.get("appUpdateAutoInstall").and_then(|v| v.as_bool()).unwrap_or(true)
                                        };
                                        match auto_install_decision(
                                            auto_install,
                                            status.has_update,
                                            failed_before,
                                            sched.is_window_open(),
                                            sched.runner.is_busy().await,
                                        ) {
                                            AutoInstallDecision::Install => {
                                                let runner_ref = sched.runner.clone();
                                                let busy_check: Arc<dyn Fn() -> bool + Send + Sync> =
                                                    Arc::new(move || runner_ref.is_busy_sync());
                                                if let Err(e) = crate::update::app_update::install_update_with_guard(
                                                    &status,
                                                    false,
                                                    false,
                                                    Some(busy_check),
                                                ).await {
                                                    crate::logging::append_app_log("ERROR", &format!("Automatic app update failed: {}", e));
                                                    let mut err_status = status.clone();
                                                    err_status.status = "error".into();
                                                    err_status.error = Some(e);
                                                    if let Err(se) = crate::update::app_update::save_app_update_state(&conn, &err_status) {
                                                        crate::logging::append_app_log("WARN", &format!("Could not save app update state: {}", se));
                                                    }
                                                }
                                            }
                                            AutoInstallDecision::SkipInstallerFailedBefore => {
                                                crate::logging::append_app_log(
                                                    "INFO",
                                                    &format!(
                                                        "Skipping automatic install of v{}: its installer failed before",
                                                        status.update_version.as_deref().unwrap_or("?")
                                                    ),
                                                );
                                            }
                                            AutoInstallDecision::SkipWindowOpen => {
                                                crate::logging::append_app_log(
                                                    "INFO",
                                                    &format!(
                                                        "Not installing v{} automatically: the Furphy window is open. The update stays available.",
                                                        status.update_version.as_deref().unwrap_or("?")
                                                    ),
                                                );
                                            }
                                            AutoInstallDecision::NoUpdate | AutoInstallDecision::SkipRunnerBusy => {}
                                        }
                                    }
                                }
                            }
                        }
                    }
                });
            })
            .expect("Failed to spawn scheduler thread");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::policy::NetworkPolicy;
    use crate::system::game::TEST_ENV_LOCK;

    #[tokio::test]
    async fn test_scheduler_cycle_lock_and_interval() {
        let policy = Arc::new(NetworkPolicy::default());
        let runner = Arc::new(JobRunner::new(policy));
        let scheduler = Scheduler::new(runner, TrayStateSnapshot::default());

        let snap_lock = scheduler.get_snapshot();
        {
            let s = snap_lock.lock().await;
            assert_eq!(s.status, STATUS_IDLE);
        }
    }

    #[test]
    fn test_cycle_lock_guard_releases_on_drop_and_panic() {
        let flag = Arc::new(AtomicBool::new(false));
        {
            let guard = CycleLockGuard::try_acquire(&flag);
            assert!(guard.is_some());
            assert!(flag.load(AtomicOrdering::Acquire));
            assert!(CycleLockGuard::try_acquire(&flag).is_none());
        }
        assert!(!flag.load(AtomicOrdering::Acquire));

        let flag_clone = flag.clone();
        let panic_res = std::panic::catch_unwind(move || {
            let _guard = CycleLockGuard::try_acquire(&flag_clone).unwrap();
            panic!("simulated panic while holding cycle lock");
        });
        assert!(panic_res.is_err());
        assert!(!flag.load(AtomicOrdering::Acquire));
        assert!(CycleLockGuard::try_acquire(&flag).is_some());
    }

    #[test]
    fn test_compute_initial_next_run_at_respects_recent_run_and_overdue() {
        let now = Utc::now();

        // 1. Recent run 20 minutes ago with 120m cadence -> waits remaining 100 minutes (no 90s hijack!)
        let recent = now - chrono::Duration::minutes(20);
        let next_recent = compute_initial_next_run_at(now, Some(recent), None, 120, true);
        let remaining_secs = (next_recent - now).num_seconds();
        assert!(remaining_secs >= 5990 && remaining_secs <= 6005, "Expected ~6000s, got {}", remaining_secs);

        // 2. Overdue run (3h ago) when window is open -> 300s startup floor
        let overdue = now - chrono::Duration::hours(3);
        let next_open = compute_initial_next_run_at(now, Some(overdue), None, 120, true);
        let open_secs = (next_open - now).num_seconds();
        assert!(open_secs >= 295 && open_secs <= 305, "Expected ~300s, got {}", open_secs);

        // 3. Overdue run when launched headless (--tray) -> 90s floor
        let next_tray = compute_initial_next_run_at(now, Some(overdue), None, 120, false);
        let tray_secs = (next_tray - now).num_seconds();
        assert!(tray_secs >= 85 && tray_secs <= 95, "Expected ~90s, got {}", tray_secs);
    }

    #[test]
    fn test_extract_cycle_job_names_parses_sync_reports() {
        let json = serde_json::json!([
            {
                "flavour": "retail",
                "updated": 1,
                "failed": 1,
                "results": [
                    { "addon_id": "a1", "name": "Details", "status": "Updated" },
                    { "addon_id": "a2", "name": "WeakAuras", "status": "Up-to-date" },
                    { "addon_id": "a3", "name": "BrokenAddon", "status": "Failed" }
                ]
            }
        ])
        .to_string();
        let (up, fail) = extract_cycle_job_names(Some(&json));
        assert_eq!(up, vec!["Details".to_string()]);
        assert_eq!(fail, vec!["BrokenAddon".to_string()]);
    }

    #[tokio::test]
    async fn test_run_cycle_auto_defers_when_window_open() {
        let _env_lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let temp = tempfile::tempdir().unwrap();
        let old_appdata = std::env::var_os("LOCALAPPDATA");
        std::env::set_var("LOCALAPPDATA", temp.path());

        let db_path = get_db_path();
        if let Some(p) = db_path.parent() {
            let _ = std::fs::create_dir_all(p);
        }
        let mut conn = open_connection(&db_path).unwrap();
        crate::db::migrate::run_migrations(&mut conn).unwrap();
        drop(conn);

        let policy = Arc::new(NetworkPolicy::default());
        let runner = Arc::new(JobRunner::new(policy));
        let scheduler = Scheduler::new(runner, TrayStateSnapshot::default()).with_window_probe(|| true);

        let res = scheduler.run_cycle(false).await;

        if let Some(v) = old_appdata {
            std::env::set_var("LOCALAPPDATA", v);
        } else {
            std::env::remove_var("LOCALAPPDATA");
        }

        let snap = res.expect("Expected deferred Ok snapshot when window open");
        assert_eq!(snap.status, STATUS_IDLE);
        assert!(snap.next_run_at.unwrap() > Utc::now() + chrono::Duration::minutes(RETRY_MINUTES_ON_BUSY - 1));
    }
}
