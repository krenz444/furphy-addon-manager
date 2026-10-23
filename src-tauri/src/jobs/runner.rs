use std::path::PathBuf;
use std::sync::Arc;
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::Mutex;
use uuid::Uuid;
use crate::engine::add::{create_addon_record, parse_addon_target};
use crate::engine::adopt::adopt_candidate_group;
use crate::engine::check::run_check_for_flavour;
use crate::engine::flavours::detect_installed_flavours_in_root;
use crate::engine::import_list::import_addon_list;
use crate::engine::remove::remove_addon;
use crate::engine::rollback::rollback_addon;
use crate::engine::scan::{scan_untracked_addons, ScannedCandidateGroup};
use crate::engine::switch_source::switch_addon_source;
use crate::engine::sync::run_sync_for_flavour;
use crate::net::catalogue::load_or_refresh_catalogue;
use crate::net::curseforge::create_cf_client;
use crate::net::policy::NetworkPolicy;
use crate::paths::{get_data_dir, detect_wow_root};


#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobRecord {
    pub id: String,
    pub kind: String,
    pub flavour: Option<String>,
    pub params: Option<String>,
    pub state: String, // "running", "completed", "failed"
    pub started_at: String,
    pub finished_at: Option<String>,
    pub error: Option<String>,
    pub results: Option<String>,
    pub reload_needed: bool,
    pub log_path: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum JobError {
    #[error("Another job ({0}) is currently running")]
    Busy(String),
    #[error("Job failed: {0}")]
    Execution(String),
    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),
}

pub struct JobRunner {
    active_job_id: Mutex<Option<String>>,
    policy: Arc<NetworkPolicy>,
}

impl JobRunner {
    pub fn new(policy: Arc<NetworkPolicy>) -> Self {
        Self {
            active_job_id: Mutex::new(None),
            policy,
        }
    }

    pub async fn is_busy(&self) -> bool {
        self.active_job_id.lock().await.is_some()
    }

    pub fn is_busy_sync(&self) -> bool {
        if let Ok(guard) = self.active_job_id.try_lock() {
            guard.is_some()
        } else {
            true
        }
    }

    pub fn recover_unfinished_jobs(conn: &Connection) -> SqlResult<()> {
        let now = Utc::now().to_rfc3339();
        conn.execute(
            "UPDATE jobs SET state = 'failed', finished_at = ?1, error = 'Furphy closed during this task' WHERE state = 'running'",
            params![now],
        )?;
        Ok(())
    }

    pub async fn run_job(
        &self,
        conn: &mut Connection,
        kind: &str,
        flavour: Option<&str>,
        params_val: Value,
    ) -> Result<JobRecord, JobError> {
        let job_id = Uuid::new_v4().to_string();

        // 1. Acquire lock
        {
            let mut guard = self.active_job_id.lock().await;
            if let Some(ref running_id) = *guard {
                return Err(JobError::Busy(running_id.clone()));
            }
            *guard = Some(job_id.clone());
        }

        let started_at = Utc::now().to_rfc3339();
        let params_json = serde_json::to_string(&params_val).ok();
        let log_path = get_data_dir().join("sync.log").to_string_lossy().to_string();

        conn.execute(
            "INSERT INTO jobs (id, kind, flavour, params, state, started_at, reload_needed, log_path) \
             VALUES (?1, ?2, ?3, ?4, 'running', ?5, 0, ?6)",
            params![job_id, kind, flavour, params_json, started_at, log_path],
        )?;

        // 2. Execute job
        let exec_res = self.execute_internal(conn, kind, flavour, &params_val).await;

        // 3. Release lock and finalize DB
        {
            let mut guard = self.active_job_id.lock().await;
            *guard = None;
        }

        let finished_at = Utc::now().to_rfc3339();
        match exec_res {
            Ok((results_json, reload_needed)) => {
                conn.execute(
                    "UPDATE jobs SET state = 'completed', finished_at = ?1, results = ?2, reload_needed = ?3 WHERE id = ?4",
                    params![finished_at, results_json, if reload_needed { 1 } else { 0 }, job_id],
                )?;

                // Dual-write to v1 if folder exists (ADR-311, D-03)
                let mutating_kinds = [
                    "sync", "install", "update-all-flavours", "adopt", "rollback", "remove",
                    "switch-source", "add-by-slug", "add", "import",
                ];
                if mutating_kinds.contains(&kind) {
                    if let Ok(wow_root) = detect_wow_root(None) {
                        let v1_dir = crate::paths::get_v1_sync_folder(&wow_root);
                        if v1_dir.exists() {
                            let _ = crate::db::export_v1::export_to_v1(conn, &v1_dir);
                        }
                    }
                }

                // Prune jobs table to keep last 20
                let _ = conn.execute(
                    "DELETE FROM jobs WHERE id NOT IN (SELECT id FROM jobs ORDER BY started_at DESC LIMIT 20)",
                    [],
                );

                Ok(JobRecord {
                    id: job_id,
                    kind: kind.to_string(),
                    flavour: flavour.map(|s| s.to_string()),
                    params: params_json,
                    state: "completed".to_string(),
                    started_at,
                    finished_at: Some(finished_at),
                    error: None,
                    results: Some(results_json),
                    reload_needed,
                    log_path: Some(log_path),
                })
            }
            Err(e) => {
                conn.execute(
                    "UPDATE jobs SET state = 'failed', finished_at = ?1, error = ?2 WHERE id = ?3",
                    params![finished_at, e, job_id],
                )?;

                let _ = conn.execute(
                    "DELETE FROM jobs WHERE id NOT IN (SELECT id FROM jobs ORDER BY started_at DESC LIMIT 20)",
                    [],
                );

                Err(JobError::Execution(e))
            }
        }
    }

    async fn execute_internal(
        &self,
        conn: &mut Connection,
        kind: &str,
        flavour: Option<&str>,
        params: &Value,
    ) -> Result<(String, bool), String> {
        let wow_root = detect_wow_root(None).map_err(|e| e.to_string())?;
        let data_dir = get_data_dir();

        // Helper to get client build/interface
        let installed_flavours = detect_installed_flavours_in_root(&wow_root);

        // Fetch settings for github token
        let github_token: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = 'githubToken'",
                [],
                |r| r.get(0),
            )
            .ok()
            .and_then(|v: String| serde_json::from_str(&v).ok());

        match kind {
            "check" => {
                let flv = flavour.ok_or("Flavour is required for check job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;

                let report = run_check_for_flavour(
                    conn,
                    flv,
                    target_flv.client_interface,
                    self.policy.clone(),
                    github_token,
                )
                .await?;

                let json = serde_json::to_string(&report).map_err(|e| e.to_string())?;
                Ok((json, false))
            }
            "sync" | "install" => {
                let flv = flavour.ok_or("Flavour is required for sync job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;

                let force = params.get("force").and_then(|v| v.as_bool()).unwrap_or(false);
                let mut only_ids: Option<Vec<String>> = params
                    .get("only")
                    .or_else(|| params.get("addon_ids"))
                    .and_then(|v| v.as_array())
                    .map(|arr| arr.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect());

                if only_ids.is_none() {
                    if let Some(single_id) = params.get("addon_id").and_then(|v| v.as_str()) {
                        only_ids = Some(vec![single_id.to_string()]);
                    }
                }

                if kind == "install" {
                    let file_id_str = params
                        .get("file_id")
                        .and_then(|v| {
                            if let Some(s) = v.as_str() {
                                Some(s.to_string())
                            } else if let Some(n) = v.as_i64() {
                                Some(n.to_string())
                            } else {
                                None
                            }
                        });

                    if let Some(fid) = file_id_str {
                        let target_addon_id: Option<String> = if let Some(ref ids) = only_ids {
                            ids.first().cloned()
                        } else if let Some(aid) = params.get("addon_id").and_then(|v| v.as_str()) {
                            Some(aid.to_string())
                        } else if let Some(pid) = params.get("project_id").and_then(|v| v.as_i64()) {
                            conn.query_row(
                                "SELECT id FROM addons WHERE flavour = ?1 AND project_id = ?2",
                                rusqlite::params![flv, pid],
                                |r| r.get(0),
                            ).ok()
                        } else {
                            None
                        };

                        if let Some(ref aid) = target_addon_id {
                            let _ = crate::engine::pin::pin_addon(conn, aid, &fid);
                            only_ids = Some(vec![aid.clone()]);
                        }
                    }
                }

                let report = run_sync_for_flavour(
                    conn,
                    &wow_root,
                    flv,
                    &target_flv.folder,
                    &target_flv.addons_path,
                    &data_dir,
                    target_flv.client_interface,
                    self.policy.clone(),
                    github_token,
                    only_ids.as_deref(),
                    force,
                )
                .await?;

                let json = serde_json::to_string(&report).map_err(|e| e.to_string())?;
                Ok((json, report.reload_needed))
            }
            "update-all-flavours" => {
                let mut all_reports = Vec::new();
                let mut any_reload = false;

                let show_test_realms: bool = conn
                    .query_row(
                        "SELECT value FROM settings WHERE key = 'showTestRealms'",
                        [],
                        |r| r.get(0),
                    )
                    .ok()
                    .and_then(|v: String| serde_json::from_str(&v).ok())
                    .unwrap_or(false);

                for flv_info in &installed_flavours {
                    if !show_test_realms && matches!(flv_info.id.as_str(), "ptr" | "xptr" | "beta") {
                        continue;
                    }

                    let report = run_sync_for_flavour(
                        conn,
                        &wow_root,
                        &flv_info.id,
                        &flv_info.folder,
                        &flv_info.addons_path,
                        &data_dir,
                        flv_info.client_interface,
                        self.policy.clone(),
                        github_token.clone(),
                        None,
                        false,
                    )
                    .await?;

                    if report.reload_needed {
                        any_reload = true;
                    }
                    all_reports.push(report);
                }

                let json = serde_json::to_string(&all_reports).map_err(|e| e.to_string())?;
                Ok((json, any_reload))
            }
            "scan" => {
                let flv = flavour.ok_or("Flavour is required for scan job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;

                let candidates = scan_untracked_addons(
                    conn,
                    &target_flv.addons_path,
                    flv,
                    target_flv.client_interface,
                )
                .map_err(|e| e.to_string())?;

                let json = serde_json::to_string(&candidates).map_err(|e| e.to_string())?;
                Ok((json, false))
            }
            "adopt" => {
                let flv = flavour.ok_or("Flavour is required for adopt job")?;
                let candidate: ScannedCandidateGroup = serde_json::from_value(
                    params.get("candidate").cloned().unwrap_or(Value::Null),
                )
                .map_err(|e| format!("Invalid adopt payload: {}", e))?;

                let addon_id = adopt_candidate_group(conn, flv, &candidate).map_err(|e| e.to_string())?;
                Ok((serde_json::json!({ "addon_id": addon_id }).to_string(), false))
            }
            "rollback" => {
                let flv = flavour.ok_or("Flavour is required for rollback job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;

                let addon_id = params
                    .get("addon_id")
                    .and_then(|v| v.as_str())
                    .ok_or("Missing addon_id parameter")?;

                rollback_addon(
                    conn,
                    &wow_root,
                    &target_flv.folder,
                    addon_id,
                    flv,
                    &target_flv.addons_path,
                    &data_dir,
                )?;
                Ok((serde_json::json!({ "rolled_back": addon_id }).to_string(), false))
            }
            "restore-wtf" => {
                let flv = flavour.ok_or("Flavour is required for restore-wtf job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;

                let snapshot_id = params
                    .get("snapshot_id")
                    .and_then(|v| v.as_str())
                    .ok_or("Missing snapshot_id parameter")?;

                crate::engine::wtf::restore_wtf_snapshot(
                    conn,
                    &wow_root,
                    &target_flv.folder,
                    snapshot_id,
                    &data_dir,
                )?;
                Ok((serde_json::json!({ "restored": snapshot_id }).to_string(), false))
            }
            "remove" => {
                let flv = flavour.ok_or("Flavour is required for remove job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;

                let addon_id = params
                    .get("addon_id")
                    .and_then(|v| v.as_str())
                    .ok_or("Missing addon_id parameter")?;

                remove_addon(conn, addon_id, flv, &target_flv.addons_path)?;
                Ok((serde_json::json!({ "removed": addon_id }).to_string(), false))
            }
            "switch-source" => {
                let addon_id = params.get("addon_id").and_then(|v| v.as_str()).ok_or("Missing addon_id")?;
                let new_source = params.get("source").and_then(|v| v.as_str()).ok_or("Missing source")?;
                let project_id = params.get("project_id").and_then(|v| v.as_i64());
                let wago_id = params.get("wago_id").and_then(|v| v.as_str());
                let wago_slug = params.get("wago_slug").and_then(|v| v.as_str());

                switch_addon_source(conn, addon_id, new_source, project_id, wago_id, wago_slug)?;
                Ok((serde_json::json!({ "switched": addon_id }).to_string(), false))
            }
            "add-by-slug" | "add" => {
                let flv = flavour.ok_or("Flavour is required for add job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;

                let raw_target = params
                    .get("target")
                    .and_then(|v| v.as_str())
                    .ok_or("Missing target parameter")?;

                let cf_client = create_cf_client().map_err(|e| e.to_string())?;
                let cat = load_or_refresh_catalogue(&self.policy, &cf_client, &data_dir).await.ok();
                let parsed = parse_addon_target(raw_target, cat.as_ref())
                    .ok_or_else(|| format!("Could not parse target '{}'", raw_target))?;

                let addon_id = create_addon_record(conn, flv, parsed, None)?;

                // Immediately sync the newly added addon
                let sync_rep = run_sync_for_flavour(
                    conn,
                    &wow_root,
                    flv,
                    &target_flv.folder,
                    &target_flv.addons_path,
                    &data_dir,
                    target_flv.client_interface,
                    self.policy.clone(),
                    github_token,
                    Some(&[addon_id.clone()]),
                    true,
                )
                .await?;

                let json = serde_json::to_string(&sync_rep).map_err(|e| e.to_string())?;
                Ok((json, sync_rep.reload_needed))
            }
            "import" => {
                let flv = flavour.ok_or("Flavour is required for import job")?;
                let file_path_str = params.get("path").and_then(|v| v.as_str()).ok_or("Missing path parameter")?;
                let import_file = PathBuf::from(file_path_str);

                let count = import_addon_list(conn, flv, &import_file)?;
                Ok((serde_json::json!({ "imported_count": count }).to_string(), false))
            }
            _ => Err(format!("Unrecognized job kind '{}'", kind)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use crate::db::schema::INITIAL_SCHEMA;

    #[test]
    fn test_recover_unfinished_jobs() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        // Insert a running job
        let now = Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO jobs (id, kind, flavour, state, started_at, reload_needed) VALUES ('job-1', 'check', 'retail', 'running', ?1, 0)",
            params![now],
        ).unwrap();

        JobRunner::recover_unfinished_jobs(&conn).unwrap();

        let (state, err): (String, Option<String>) = conn
            .query_row(
                "SELECT state, error FROM jobs WHERE id = 'job-1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();

        assert_eq!(state, "failed");
        assert_eq!(err, Some("Furphy closed during this task".to_string()));
    }

    #[tokio::test]
    async fn test_job_lock_busy() {
        let policy = Arc::new(NetworkPolicy::new());
        let runner = JobRunner::new(policy);

        // Simulate an active job lock
        {
            let mut guard = runner.active_job_id.lock().await;
            *guard = Some("running-job-123".to_string());
        }

        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        let res = runner.run_job(&mut conn, "check", Some("retail"), Value::Null).await;
        match res {
            Err(JobError::Busy(id)) => assert_eq!(id, "running-job-123"),
            other => panic!("Expected JobError::Busy, got {:?}", other),
        }
    }
}
