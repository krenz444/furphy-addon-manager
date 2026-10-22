use std::sync::Arc;
use std::time::Duration;
use chrono::Utc;
use rusqlite::Connection;
use serde_json::{json, Value};
use tokio::sync::Mutex;

use crate::db::repo::get_settings_map;
use crate::jobs::runner::{JobError, JobRunner};
use crate::paths::get_db_path;
use crate::system::game::is_wow_running;
use crate::system::notify::show_cycle_notification;
use crate::system::power::apply_game_mode_power;
use crate::system::tray_status::{
    compute_core, make_tooltip, TrayStateSnapshot, STATUS_CHECKING, STATUS_DONE_CLEAN,
    STATUS_DONE_FAILED, STATUS_DONE_UPDATED, STATUS_IDLE, STATUS_UNREACHABLE,
    STATUS_WAITING_BUSY,
};

pub const DEFAULT_INTERVAL_MINUTES: i64 = 120;
pub const MIN_INTERVAL_MINUTES: i64 = 30;
pub const MAX_INTERVAL_MINUTES: i64 = 1440;
pub const RETRY_MINUTES_ON_BUSY: i64 = 5;
pub const FIRST_CYCLE_DELAY_SECS: i64 = 90;

pub struct Scheduler {
    runner: Arc<JobRunner>,
    snapshot: Arc<Mutex<TrayStateSnapshot>>,
    is_running_cycle: Mutex<bool>,
}

impl Scheduler {
    pub fn new(runner: Arc<JobRunner>, initial_snapshot: TrayStateSnapshot) -> Self {
        Self {
            runner,
            snapshot: Arc::new(Mutex::new(initial_snapshot)),
            is_running_cycle: Mutex::new(false),
        }
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
        // Prevent concurrent cycles inside the scheduler
        let mut run_lock = self.is_running_cycle.lock().await;
        if *run_lock {
            return Err("Cycle already in progress".to_string());
        }
        *run_lock = true;

        let db_path = get_db_path();
        let mut conn = Connection::open(&db_path).map_err(|e| e.to_string())?;

        // Check if background updates are enabled (for automatic runs)
        if !is_manual && !Self::are_background_updates_enabled(&conn) {
            *run_lock = false;
            return Err("Background updates disabled in settings".to_string());
        }

        let interval = Self::get_effective_interval_minutes(&conn);
        let game_running = is_wow_running();

        // 1. Set CPU priority per ADR-309
        let _ = apply_game_mode_power(game_running);

        // 2. Transition state to 'checking'
        {
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
            s.icon_variant = "busy".to_string();
            let _ = Self::persist_tray_state(&conn, &s);
        }

        // 3. Execute update-all-flavours job
        let job_res = self
            .runner
            .run_job(&mut conn, "update-all-flavours", None, json!({}))
            .await;

        let now = Utc::now();
        let done_stamp = chrono::Local::now().format("%H:%M").to_string();

        let final_snapshot = match job_res {
            Ok(job) => {
                // Parse results to calculate tallies and addon names
                let mut updated_names: Vec<String> = Vec::new();
                let mut failed_names: Vec<String> = Vec::new();

                if let Some(ref res_str) = job.results {
                    if let Ok(val) = serde_json::from_str::<Value>(res_str) {
                        if let Some(arr) = val.as_array() {
                            for item in arr {
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
                        }
                    }
                }

                let status = if !failed_names.is_empty() {
                    STATUS_DONE_FAILED
                } else if !updated_names.is_empty() {
                    STATUS_DONE_UPDATED
                } else {
                    STATUS_DONE_CLEAN
                };

                let next_run_utc = now + chrono::Duration::minutes(interval);

                let core = compute_core(
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
                    Some(next_run_utc),
                    Some(&updated_names),
                    Some(&failed_names),
                    None,
                );

                let mut s = self.snapshot.lock().await;
                s.status = status.to_string();
                s.core_text = core;
                s.tooltip = make_tooltip(&s.core_text);
                s.icon_variant = match status {
                    STATUS_DONE_FAILED => "failed".to_string(),
                    STATUS_DONE_UPDATED => "updated".to_string(),
                    _ => "normal".to_string(),
                };
                s.last_result = Some(match status {
                    STATUS_DONE_FAILED => "failed".to_string(),
                    STATUS_DONE_UPDATED => "updated".to_string(),
                    _ => "up_to_date".to_string(),
                });
                s.last_run_at = Some(now);
                s.next_run_at = Some(next_run_utc);
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

                s.clone()
            }
            Err(JobError::Busy(_)) => {
                let next_run_utc = now + chrono::Duration::minutes(RETRY_MINUTES_ON_BUSY);
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
                    Some(next_run_utc),
                    None,
                    None,
                    None,
                );

                let mut s = self.snapshot.lock().await;
                s.status = STATUS_WAITING_BUSY.to_string();
                s.core_text = core;
                s.tooltip = make_tooltip(&s.core_text);
                s.icon_variant = "normal".to_string();
                s.next_run_at = Some(next_run_utc);
                let _ = Self::persist_tray_state(&conn, &s);
                s.clone()
            }
            Err(_) => {
                let next_run_utc = now + chrono::Duration::minutes(RETRY_MINUTES_ON_BUSY);
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
                    Some(next_run_utc),
                    None,
                    None,
                    None,
                );

                let mut s = self.snapshot.lock().await;
                s.status = STATUS_UNREACHABLE.to_string();
                s.core_text = core;
                s.tooltip = make_tooltip(&s.core_text);
                s.icon_variant = "normal".to_string();
                s.next_run_at = Some(next_run_utc);
                let _ = Self::persist_tray_state(&conn, &s);
                s.clone()
            }
        };

        // Reset power throttling if game is no longer running
        if !is_wow_running() {
            let _ = apply_game_mode_power(false);
        }

        *run_lock = false;
        Ok(final_snapshot)
    }

    /// Starts the background scheduling loop.
    pub fn start_background_loop(self: Arc<Self>) {
        // Initial setup: set nextRunAt to now + 90 seconds (FIRST_CYCLE_DELAY_SECS)
        let initial_delay = Utc::now() + chrono::Duration::seconds(FIRST_CYCLE_DELAY_SECS);
        {
            let mut s = match self.snapshot.try_lock() {
                Ok(guard) => guard,
                Err(_) => return,
            };
            s.next_run_at = Some(initial_delay);
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
                Some(initial_delay),
                None,
                None,
                None,
            );
            s.tooltip = make_tooltip(&s.core_text);
            if let Ok(conn) = Connection::open(get_db_path()) {
                let _ = Self::persist_tray_state(&conn, &s);
            }
        }

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
                    let mut hourly_ticker = tokio::time::interval(Duration::from_secs(3600));
                    // Check wall clock every 5 seconds to handle sleep / resume gracefully
                    let mut poll_interval = tokio::time::interval(Duration::from_secs(5));

                    loop {
                        tokio::select! {
                            _ = poll_interval.tick() => {
                                let should_run = {
                                    let s = self.snapshot.lock().await;
                                    if let Some(next_t) = s.next_run_at {
                                        Utc::now() >= next_t
                                    } else {
                                        false
                                    }
                                };

                                if should_run {
                                    let _ = self.run_cycle(false).await;
                                }
                            }
                            _ = hourly_ticker.tick() => {
                                // Hourly self-update check and catalogue refresh
                                crate::logging::append_app_log("INFO", "Running hourly maintenance crawl");
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
}
