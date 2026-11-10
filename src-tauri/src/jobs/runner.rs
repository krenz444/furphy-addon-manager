use std::path::PathBuf;
use std::sync::Arc;
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::Mutex;
use uuid::Uuid;
use crate::engine::add::{create_addon_record, parse_addon_target, AddonTarget};
use crate::engine::adopt::adopt_candidate_group;
use crate::engine::check::run_check_for_flavour;
use crate::engine::flavours::detect_all_installed_flavours;
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

fn copy_result(
    item: &crate::engine::copy_addons::CopyPlanItem,
    status: &str,
    message: String,
) -> crate::engine::copy_addons::CopyItemResult {
    crate::engine::copy_addons::CopyItemResult {
        addon_id: item.addon_id.clone(),
        name: item.name.clone(),
        status: status.to_string(),
        message,
    }
}

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
            Ok((results_json, reload_needed, job_error)) => {
                conn.execute(
                    "UPDATE jobs SET state = 'completed', finished_at = ?1, results = ?2, reload_needed = ?3, error = ?4 WHERE id = ?5",
                    params![finished_at, results_json, if reload_needed { 1 } else { 0 }, job_error, job_id],
                )?;

                // Dual-write to v1 if folder exists (ADR-311, D-03)
                let mutating_kinds = [
                    "sync", "install", "update-all-flavours", "adopt", "rollback", "remove",
                    "switch-source", "add-by-slug", "add", "import", "install-deps",
                    "install-zip", "copy-addons",
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
                    error: job_error,
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
    ) -> Result<(String, bool, Option<String>), String> {
        let wow_root = detect_wow_root(None).ok();
        let data_dir = get_data_dir();

        // Helper to get client build/interface and custom roots
        let installed_flavours = detect_all_installed_flavours(conn, wow_root.as_deref());

        let resolve_flavour_root = |flv_info: &crate::engine::flavours::InstalledFlavourInfo| -> Result<PathBuf, String> {
            flv_info.custom_root.clone()
                .or_else(|| wow_root.clone())
                .ok_or_else(|| format!("Could not find WoW installation for game version '{}'. Please configure its path in Settings.", flv_info.id))
        };

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

                let job_error = if report.failed_count > 0 {
                    let failed_msgs: Vec<String> = report.outcomes.iter()
                        .filter(|o| o.status == "Failed")
                        .map(|o| format!("{}: {}", o.name, o.error.as_deref().unwrap_or("Unknown error")))
                        .collect();
                    Some(format!("{} addon(s) failed: {}", report.failed_count, failed_msgs.join("; ")))
                } else {
                    None
                };

                let json = serde_json::to_string(&report).map_err(|e| e.to_string())?;
                Ok((json, false, job_error))
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
                    let target_addon_id: Option<String> = if let Some(aid) = params.get("addon_id").and_then(|v| {
                        if let Some(s) = v.as_str() {
                            Some(s.to_string())
                        } else if let Some(n) = v.as_i64() {
                            Some(n.to_string())
                        } else {
                            None
                        }
                    }) {
                        Some(aid)
                    } else if let Some(ref ids) = only_ids {
                        ids.first().cloned()
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
                        only_ids = Some(vec![aid.clone()]);

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
                            let _ = crate::engine::pin::pin_addon(conn, aid, &fid);
                        }
                    }
                }

                let flv_root = resolve_flavour_root(target_flv)?;
                let origin = match params.get("origin").and_then(|v| v.as_str()) {
                    Some(s) if s.eq_ignore_ascii_case("background") => crate::engine::update_policy::SyncOrigin::Background,
                    _ => crate::engine::update_policy::SyncOrigin::Manual,
                };
                let override_hold = params.get("override_hold").and_then(|v| v.as_bool()).unwrap_or(false);
                let override_modified = params.get("override_modified").and_then(|v| v.as_bool()).unwrap_or(false);
                let backup_modified = params.get("backup_modified").and_then(|v| v.as_bool()).unwrap_or(false);

                let report = crate::engine::sync::run_sync_for_flavour_with_options(
                    conn,
                    &flv_root,
                    flv,
                    &target_flv.folder,
                    &target_flv.addons_path,
                    &data_dir,
                    target_flv.client_interface,
                    self.policy.clone(),
                    github_token.clone(),
                    only_ids.as_deref(),
                    force,
                    origin,
                    override_hold,
                    override_modified,
                    backup_modified,
                )
                .await?;

                if kind == "install" {
                    if let Some(ref ids) = only_ids {
                        for aid in ids {
                            let _ = crate::engine::deps::install_missing_dependencies_for_addon(
                                conn,
                                &flv_root,
                                flv,
                                &target_flv.folder,
                                &target_flv.addons_path,
                                &data_dir,
                                target_flv.client_interface,
                                self.policy.clone(),
                                github_token.clone(),
                                aid,
                            )
                            .await;
                        }
                    }
                }

                let job_error = if report.failed > 0 {
                    let failed_msgs: Vec<String> = report.results.iter()
                        .filter(|r| r.status == "Failed")
                        .map(|r| format!("{}: {}", r.name, r.error.as_deref().unwrap_or("Unknown error")))
                        .collect();
                    Some(format!("{} addon(s) failed: {}", report.failed, failed_msgs.join("; ")))
                } else {
                    None
                };

                let json = serde_json::to_string(&report).map_err(|e| e.to_string())?;
                Ok((json, report.reload_needed, job_error))
            }
            "update-all-flavours" => {
                let mut all_reports = Vec::new();
                let mut any_reload = false;

                let origin = match params.get("origin").and_then(|v| v.as_str()) {
                    Some(s) if s.eq_ignore_ascii_case("background") => crate::engine::update_policy::SyncOrigin::Background,
                    _ => crate::engine::update_policy::SyncOrigin::Manual,
                };

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
                    if !show_test_realms && crate::engine::flavours::is_test_realm(&flv_info.id) {
                        continue;
                    }

                    let flv_root = match resolve_flavour_root(flv_info) {
                        Ok(r) => r,
                        Err(_) => continue,
                    };

                    let update_mode = conn.query_row(
                        "SELECT update_mode FROM flavours WHERE id = ?1",
                        rusqlite::params![flv_info.id],
                        |r| r.get::<_, Option<String>>(0),
                    ).ok().flatten().unwrap_or_else(|| "auto".to_string());

                    if origin == crate::engine::update_policy::SyncOrigin::Background
                        && update_mode.eq_ignore_ascii_case("notify")
                    {
                        let _ = run_check_for_flavour(
                            conn,
                            &flv_info.id,
                            flv_info.client_interface,
                            self.policy.clone(),
                            github_token.clone(),
                        ).await;
                        continue;
                    }

                    let report = crate::engine::sync::run_sync_for_flavour_with_options(
                        conn,
                        &flv_root,
                        &flv_info.id,
                        &flv_info.folder,
                        &flv_info.addons_path,
                        &data_dir,
                        flv_info.client_interface,
                        self.policy.clone(),
                        github_token.clone(),
                        None,
                        false,
                        origin,
                        false,
                        false,
                        false,
                    )
                    .await?;

                    if report.reload_needed {
                        any_reload = true;
                    }
                    all_reports.push(report);
                }

                let total_failed: usize = all_reports.iter().map(|r| r.failed).sum();
                let job_error = if total_failed > 0 {
                    let mut failed_msgs = Vec::new();
                    for r in &all_reports {
                        for res in &r.results {
                            if res.status == "Failed" {
                                failed_msgs.push(format!("{}: {}", res.name, res.error.as_deref().unwrap_or("Unknown error")));
                            }
                        }
                    }
                    Some(format!("{} addon(s) failed: {}", total_failed, failed_msgs.join("; ")))
                } else {
                    None
                };

                let json = serde_json::to_string(&all_reports).map_err(|e| e.to_string())?;
                Ok((json, any_reload, job_error))
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
                Ok((json, false, None))
            }
            "adopt" => {
                let flv = flavour.ok_or("Flavour is required for adopt job")?;
                let candidate: ScannedCandidateGroup = serde_json::from_value(
                    params.get("candidate").cloned().unwrap_or(Value::Null),
                )
                .map_err(|e| format!("Invalid adopt payload: {}", e))?;

                let addon_id = adopt_candidate_group(conn, flv, &candidate).map_err(|e| e.to_string())?;

                let target_flv = installed_flavours.iter().find(|f| f.id == flv);
                if let Some(t_flv) = target_flv {
                    if let Ok(manifest) = crate::engine::integrity::generate_manifest_for_folders(&t_flv.addons_path, &candidate.folders) {
                        let _ = crate::engine::integrity::record_manifest(conn, &addon_id, &manifest);
                    }
                }

                let act = crate::engine::activity::ActivityEntry {
                    id: Uuid::new_v4().to_string(),
                    ts: Utc::now().to_rfc3339(),
                    flavour: flv.to_string(),
                    addon_id: addon_id.clone(),
                    name: candidate.name.clone(),
                    kind: "installed".to_string(),
                    from_version: None,
                    to_version: candidate.version.clone(),
                    source: candidate.source.clone(),
                    job_id: None,
                    error: None,
                };
                let _ = crate::engine::activity::record_activity(conn, &act);

                Ok((serde_json::json!({ "addon_id": addon_id }).to_string(), false, None))
            }
            "rollback" => {
                let flv = flavour.ok_or("Flavour is required for rollback job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;
                let flv_root = resolve_flavour_root(target_flv)?;

                let addon_id = params
                    .get("addon_id")
                    .and_then(|v| v.as_str())
                    .ok_or("Missing addon_id parameter")?;

                let addon_meta: Option<(String, Option<String>, Option<String>)> = conn.query_row(
                    "SELECT name, version, source FROM addons WHERE id = ?1",
                    rusqlite::params![addon_id],
                    |r| Ok((r.get::<_, Option<String>>(0)?.unwrap_or_default(), r.get(1)?, r.get(2)?)),
                ).ok();

                rollback_addon(
                    conn,
                    &flv_root,
                    &target_flv.folder,
                    addon_id,
                    flv,
                    &target_flv.addons_path,
                    &data_dir,
                )?;

                if let Some((name, ver, src)) = addon_meta {
                    let act = crate::engine::activity::ActivityEntry {
                        id: Uuid::new_v4().to_string(),
                        ts: Utc::now().to_rfc3339(),
                        flavour: flv.to_string(),
                        addon_id: addon_id.to_string(),
                        name,
                        kind: "rolled_back".to_string(),
                        from_version: ver,
                        to_version: None,
                        source: src,
                        job_id: None,
                        error: None,
                    };
                    let _ = crate::engine::activity::record_activity(conn, &act);
                }

                Ok((serde_json::json!({ "rolled_back": addon_id }).to_string(), false, None))
            }
            "restore-wtf" => {
                let flv = flavour.ok_or("Flavour is required for restore-wtf job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;
                let flv_root = resolve_flavour_root(target_flv)?;

                let snapshot_id = params
                    .get("snapshot_id")
                    .and_then(|v| v.as_str())
                    .ok_or("Missing snapshot_id parameter")?;

                crate::engine::wtf::restore_wtf_snapshot(
                    conn,
                    &flv_root,
                    &target_flv.folder,
                    snapshot_id,
                    &data_dir,
                )?;
                Ok((serde_json::json!({ "restored": snapshot_id }).to_string(), false, None))
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

                let addon_meta: Option<(String, Option<String>, Option<String>)> = conn.query_row(
                    "SELECT name, version, source FROM addons WHERE id = ?1",
                    rusqlite::params![addon_id],
                    |r| Ok((r.get::<_, Option<String>>(0)?.unwrap_or_default(), r.get(1)?, r.get(2)?)),
                ).ok();

                remove_addon(conn, addon_id, flv, &target_flv.addons_path)?;

                if let Some((name, ver, src)) = addon_meta {
                    let act = crate::engine::activity::ActivityEntry {
                        id: Uuid::new_v4().to_string(),
                        ts: Utc::now().to_rfc3339(),
                        flavour: flv.to_string(),
                        addon_id: addon_id.to_string(),
                        name,
                        kind: "removed".to_string(),
                        from_version: ver,
                        to_version: None,
                        source: src,
                        job_id: None,
                        error: None,
                    };
                    let _ = crate::engine::activity::record_activity(conn, &act);
                }

                Ok((serde_json::json!({ "removed": addon_id }).to_string(), false, None))
            }
            "switch-source" => {
                let addon_id = params.get("addon_id").and_then(|v| v.as_str()).ok_or("Missing addon_id")?;
                let new_source = params.get("source").and_then(|v| v.as_str()).ok_or("Missing source")?;
                let project_id = params.get("project_id").and_then(|v| v.as_i64());
                let wago_id = params.get("wago_id").and_then(|v| v.as_str());
                let wago_slug = params.get("wago_slug").and_then(|v| v.as_str());

                switch_addon_source(conn, addon_id, new_source, project_id, wago_id, wago_slug)?;
                Ok((serde_json::json!({ "switched": addon_id }).to_string(), false, None))
            }
            "add-by-slug" | "add" => {
                let flv = flavour.ok_or("Flavour is required for add job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;

                let raw_target = params
                    .get("target")
                    .or_else(|| params.get("slug"))
                    .or_else(|| params.get("wago_slug"))
                    .and_then(|v| v.as_str())
                    .ok_or("Missing target parameter")?;

                let parsed = if let Some(source) = params.get("source").and_then(|v| v.as_str()) {
                    match source.to_ascii_lowercase().as_str() {
                        "wago" => {
                            let clean = raw_target.strip_prefix("wago:").unwrap_or(raw_target);
                            AddonTarget::Wago(clean.to_string())
                        }
                        "github" => {
                            let clean = raw_target.strip_prefix("github:").unwrap_or(raw_target);
                            AddonTarget::GitHub(clean.to_string())
                        }
                        "curseforge" | "curse" => {
                            let clean = raw_target
                                .strip_prefix("curseforge:")
                                .or_else(|| raw_target.strip_prefix("curse:"))
                                .unwrap_or(raw_target);
                            let cf_client = create_cf_client().map_err(|e| e.to_string())?;
                            let cat = load_or_refresh_catalogue(&self.policy, &cf_client, &data_dir).await.ok();
                            parse_addon_target(clean, cat.as_ref())
                                .ok_or_else(|| format!("Could not parse CurseForge target '{}'", raw_target))?
                        }
                        _ => {
                            let cf_client = create_cf_client().map_err(|e| e.to_string())?;
                            let cat = load_or_refresh_catalogue(&self.policy, &cf_client, &data_dir).await.ok();
                            parse_addon_target(raw_target, cat.as_ref())
                                .ok_or_else(|| format!("Could not parse target '{}'", raw_target))?
                        }
                    }
                } else if let Some(wago_slug) = params.get("wago_slug").and_then(|v| v.as_str()) {
                    AddonTarget::Wago(wago_slug.to_string())
                } else {
                    let cf_client = create_cf_client().map_err(|e| e.to_string())?;
                    let cat = load_or_refresh_catalogue(&self.policy, &cf_client, &data_dir).await.ok();
                    parse_addon_target(raw_target, cat.as_ref())
                        .ok_or_else(|| format!("Could not parse target '{}'", raw_target))?
                };

                let flv_root = resolve_flavour_root(target_flv)?;
                let addon_id = create_addon_record(conn, flv, parsed, None)?;

                // Immediately sync the newly added addon
                let sync_rep = run_sync_for_flavour(
                    conn,
                    &flv_root,
                    flv,
                    &target_flv.folder,
                    &target_flv.addons_path,
                    &data_dir,
                    target_flv.client_interface,
                    self.policy.clone(),
                    github_token.clone(),
                    Some(&[addon_id.clone()]),
                    true,
                )
                .await?;

                // Automatically resolve and install missing dependencies if any
                let _ = crate::engine::deps::install_missing_dependencies_for_addon(
                    conn,
                    &flv_root,
                    flv,
                    &target_flv.folder,
                    &target_flv.addons_path,
                    &data_dir,
                    target_flv.client_interface,
                    self.policy.clone(),
                    github_token,
                    &addon_id,
                )
                .await;

                let job_error = if sync_rep.failed > 0 {
                    let failed_msgs: Vec<String> = sync_rep.results.iter()
                        .filter(|r| r.status == "Failed")
                        .map(|r| format!("{}: {}", r.name, r.error.as_deref().unwrap_or("Unknown error")))
                        .collect();
                    Some(format!("{} addon(s) failed: {}", sync_rep.failed, failed_msgs.join("; ")))
                } else {
                    None
                };

                let json = serde_json::to_string(&sync_rep).map_err(|e| e.to_string())?;
                Ok((json, sync_rep.reload_needed, job_error))
            }
            "install-zip" => {
                let flv = flavour.ok_or("Flavour is required for install-zip job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;
                let raw_source = params
                    .get("source")
                    .and_then(|v| v.as_str())
                    .ok_or("Missing source parameter")?;

                let source = crate::engine::zip_install::parse_zip_source(raw_source)?;
                let report = crate::engine::zip_install::install_from_zip(
                    conn,
                    flv,
                    &target_flv.addons_path,
                    &data_dir,
                    self.policy.clone(),
                    source,
                )
                .await?;

                let json = serde_json::to_string(&report).map_err(|e| e.to_string())?;
                Ok((json, true, None))
            }
            "copy-addons" => {
                let source_flv = flavour.ok_or("Flavour is required for copy-addons job")?;
                let target_id = params
                    .get("target_flavour")
                    .and_then(|v| v.as_str())
                    .ok_or("Missing target_flavour parameter")?;
                if target_id == source_flv {
                    return Err("Choose a different game version to copy to".to_string());
                }
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == target_id)
                    .ok_or_else(|| format!("Game version '{}' is not installed", target_id))?;
                let addon_ids: Vec<String> = params
                    .get("addon_ids")
                    .and_then(|v| v.as_array())
                    .map(|arr| arr.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect())
                    .unwrap_or_default();
                if addon_ids.is_empty() {
                    return Err("Choose at least one addon to copy".to_string());
                }

                let plan = crate::engine::copy_addons::plan_copy(conn, source_flv, target_id, &addon_ids)?;
                let flv_root = resolve_flavour_root(target_flv)?;
                let mut items: Vec<crate::engine::copy_addons::CopyItemResult> = Vec::new();
                let mut any_installed = false;

                // Each addon goes through the same code as the add job, so the target game version's own strict file
                // selection, install, manifest and activity rules apply unchanged. One failure never stops the rest.
                for item in &plan {
                    if let Some(reason) = &item.skip_reason {
                        items.push(copy_result(item, "skipped", reason.clone()));
                        continue;
                    }
                    let Some(add_target) = item.add_target.as_deref() else {
                        items.push(copy_result(item, "failed", "Has no download source Furphy can use".to_string()));
                        continue;
                    };
                    let Some(parsed) = parse_addon_target(add_target, None) else {
                        items.push(copy_result(item, "failed", format!("Could not read the source of {}", item.name)));
                        continue;
                    };
                    if crate::engine::deps::is_target_already_present(conn, target_id, &parsed) {
                        items.push(copy_result(item, "skipped", format!("Already in {}", target_id)));
                        continue;
                    }
                    let new_id = match create_addon_record(conn, target_id, parsed, Some(&item.name)) {
                        Ok(id) => id,
                        Err(e) => {
                            items.push(copy_result(item, "failed", e));
                            continue;
                        }
                    };

                    let outcome = run_sync_for_flavour(
                        conn,
                        &flv_root,
                        target_id,
                        &target_flv.folder,
                        &target_flv.addons_path,
                        &data_dir,
                        target_flv.client_interface,
                        self.policy.clone(),
                        github_token.clone(),
                        Some(&[new_id.clone()]),
                        true,
                    )
                    .await;

                    let failure: Option<String> = match outcome {
                        Ok(report) => match report.results.iter().find(|r| r.addon_id == new_id) {
                            Some(r) if matches!(r.status.as_str(), "Installed" | "Updated" | "Up-to-date") => {
                                any_installed = true;
                                let text = match r.new_version.as_deref() {
                                    Some(v) if !v.is_empty() => format!("Installed {}", v),
                                    _ => "Installed".to_string(),
                                };
                                items.push(copy_result(item, "installed", text));
                                None
                            }
                            Some(r) => Some(r.error.clone().unwrap_or_else(|| format!("Not installed ({})", r.status))),
                            None => Some("Not installed".to_string()),
                        },
                        Err(e) => Some(e),
                    };
                    if let Some(message) = failure {
                        // A copy that did not install leaves no empty row behind in the target game version.
                        let _ = remove_addon(conn, &new_id, target_id, &target_flv.addons_path);
                        items.push(copy_result(item, "failed", message));
                    }
                }

                let json = serde_json::json!({ "items": items }).to_string();
                Ok((json, any_installed, None))
            }
            "install-deps" => {
                let flv = flavour.ok_or("Flavour is required for install-deps job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;
                let flv_root = resolve_flavour_root(target_flv)?;

                let addon_id = params
                    .get("addon_id")
                    .and_then(|v| {
                        if let Some(s) = v.as_str() {
                            Some(s.to_string())
                        } else if let Some(n) = v.as_i64() {
                            Some(n.to_string())
                        } else {
                            None
                        }
                    });

                let deps_result = if let Some(ref aid) = addon_id {
                    crate::engine::deps::install_missing_dependencies_for_addon(
                        conn,
                        &flv_root,
                        flv,
                        &target_flv.folder,
                        &target_flv.addons_path,
                        &data_dir,
                        target_flv.client_interface,
                        self.policy.clone(),
                        github_token,
                        aid,
                    )
                    .await?
                } else {
                    crate::engine::deps::install_all_missing_dependencies_for_flavour(
                        conn,
                        &flv_root,
                        flv,
                        &target_flv.folder,
                        &target_flv.addons_path,
                        &data_dir,
                        target_flv.client_interface,
                        self.policy.clone(),
                        github_token,
                    )
                    .await?
                };

                let count = deps_result.installed_deps.len();
                let reload_needed = count > 0 && crate::system::game::is_wow_running();
                let json = serde_json::json!({
                    "installed_deps": deps_result.installed_deps,
                    "unresolved_deps": deps_result.unresolved_deps,
                    "count": count
                })
                .to_string();

                let job_error = if !deps_result.unresolved_deps.is_empty() {
                    if deps_result.unresolved_deps.len() == 1 {
                        Some(format!("Failed to install dependency '{}'", deps_result.unresolved_deps[0]))
                    } else {
                        Some(format!("Failed to install {} dependency(ies): {}", deps_result.unresolved_deps.len(), deps_result.unresolved_deps.join(", ")))
                    }
                } else {
                    None
                };

                let act = crate::engine::activity::ActivityEntry {
                    id: Uuid::new_v4().to_string(),
                    ts: Utc::now().to_rfc3339(),
                    flavour: flv.to_string(),
                    addon_id: addon_id.clone().unwrap_or_default(),
                    name: "Dependencies".to_string(),
                    kind: "installed".to_string(),
                    from_version: None,
                    to_version: None,
                    source: None,
                    job_id: None,
                    error: job_error.clone(),
                };
                let _ = crate::engine::activity::record_activity(conn, &act);

                Ok((json, reload_needed, job_error))
            }
            "reinstall" => {
                let flv = flavour.ok_or("Flavour is required for reinstall job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;
                let flv_root = resolve_flavour_root(target_flv)?;

                let addon_id = params
                    .get("addon_id")
                    .and_then(|v| v.as_str())
                    .ok_or("Missing addon_id parameter for reinstall")?;

                let report = crate::engine::sync::run_sync_for_flavour_with_options(
                    conn,
                    &flv_root,
                    flv,
                    &target_flv.folder,
                    &target_flv.addons_path,
                    &data_dir,
                    target_flv.client_interface,
                    self.policy.clone(),
                    github_token.clone(),
                    Some(&[addon_id.to_string()]),
                    true,
                    crate::engine::update_policy::SyncOrigin::Manual,
                    true,
                    true,
                    false,
                )
                .await?;

                let json = serde_json::to_string(&report).map_err(|e| e.to_string())?;
                Ok((json, report.reload_needed, None))
            }
            "verify-integrity" => {
                let flv = flavour.ok_or("Flavour is required for verify-integrity job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;

                let addon_id = params.get("addon_id").and_then(|v| v.as_str());
                if let Some(aid) = addon_id {
                    let report = crate::engine::integrity::verify_addon_integrity(conn, &target_flv.addons_path, aid)?;
                    let status_str = match report.status {
                        crate::engine::integrity::IntegrityStatus::Clean => "clean",
                        crate::engine::integrity::IntegrityStatus::Modified => "modified",
                        crate::engine::integrity::IntegrityStatus::Missing => "missing",
                        crate::engine::integrity::IntegrityStatus::Unknown => "unknown",
                    };
                    let _ = conn.execute("UPDATE addons SET integrity_status = ?1 WHERE id = ?2", rusqlite::params![status_str, aid]);
                    let json = serde_json::to_string(&report).map_err(|e| e.to_string())?;
                    Ok((json, false, None))
                } else {
                    let mut reports = Vec::new();
                    let mut stmt = conn.prepare("SELECT id FROM addons WHERE flavour = ?1")
                        .map_err(|e| e.to_string())?;
                    let rows = stmt.query_map(rusqlite::params![flv], |r| r.get::<_, String>(0))
                        .map_err(|e| e.to_string())?;
                    let aids: Vec<String> = rows.filter_map(|r| r.ok()).collect();
                    for aid in aids {
                        if let Ok(rep) = crate::engine::integrity::verify_addon_integrity(conn, &target_flv.addons_path, &aid) {
                            let status_str = match rep.status {
                                crate::engine::integrity::IntegrityStatus::Clean => "clean",
                                crate::engine::integrity::IntegrityStatus::Modified => "modified",
                                crate::engine::integrity::IntegrityStatus::Missing => "missing",
                                crate::engine::integrity::IntegrityStatus::Unknown => "unknown",
                            };
                            let _ = conn.execute("UPDATE addons SET integrity_status = ?1 WHERE id = ?2", rusqlite::params![status_str, aid]);
                            reports.push(rep);
                        }
                    }
                    let json = serde_json::to_string(&reports).map_err(|e| e.to_string())?;
                    Ok((json, false, None))
                }
            }
            "backup-wtf" => {
                let flv = flavour.ok_or("Flavour is required for backup-wtf job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;
                let flv_root = resolve_flavour_root(target_flv)?;

                let note = params.get("note").and_then(|v| v.as_str());
                let retention = params.get("retention").and_then(|v| v.as_u64()).unwrap_or(5) as usize;

                let record = crate::engine::wtf_full::backup_whole_wtf(
                    conn,
                    &flv_root,
                    &target_flv.folder,
                    flv,
                    &data_dir,
                    note,
                    retention,
                )?;

                let json = serde_json::to_string(&record).map_err(|e| e.to_string())?;
                Ok((json, false, None))
            }
            "restore-wtf-all" => {
                let flv = flavour.ok_or("Flavour is required for restore-wtf-all job")?;
                let target_flv = installed_flavours
                    .iter()
                    .find(|f| f.id == flv)
                    .ok_or_else(|| format!("Flavour '{}' is not installed", flv))?;
                let flv_root = resolve_flavour_root(target_flv)?;

                let backup_id = params
                    .get("backup_id")
                    .and_then(|v| v.as_str())
                    .ok_or("Missing backup_id parameter")?;

                crate::engine::wtf_full::restore_whole_wtf(
                    conn,
                    &flv_root,
                    &target_flv.folder,
                    flv,
                    backup_id,
                    &data_dir,
                )?;

                Ok((serde_json::json!({ "restored": backup_id }).to_string(), true, None))
            }
            "import" => {
                let flv = flavour.ok_or("Flavour is required for import job")?;
                let file_path_str = params.get("path").and_then(|v| v.as_str()).ok_or("Missing path parameter")?;
                let import_file = PathBuf::from(file_path_str);

                let count = import_addon_list(conn, flv, &import_file)?;
                Ok((serde_json::json!({ "imported_count": count }).to_string(), false, None))
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

    #[tokio::test]
    async fn test_install_deps_job_execution() {
        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let temp = std::env::temp_dir().join("furphy test wow (install deps)");
        let retail_addons = temp.join("_retail_").join("Interface").join("AddOns");
        let _ = std::fs::create_dir_all(&retail_addons);
        std::env::set_var("FURPHY_DEV_WOWROOT", temp.to_str().unwrap());

        let policy = Arc::new(NetworkPolicy::new());
        let runner = JobRunner::new(policy);

        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        // Insert flavour retail
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
             VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
            [],
        ).unwrap();

        // Insert addon without missing deps
        conn.execute(
            "INSERT INTO addons (id, flavour, name, required_deps) VALUES ('addon-1', 'retail', 'CleanAddon', '[]')",
            [],
        ).unwrap();

        let res = runner.run_job(
            &mut conn,
            "install-deps",
            Some("retail"),
            serde_json::json!({ "addon_id": "addon-1" }),
        ).await;

        assert!(res.is_ok(), "install-deps job failed: {:?}", res);
        let record = res.unwrap();
        assert_eq!(record.kind, "install-deps");
        assert_eq!(record.state, "completed");

        let results_val: serde_json::Value = serde_json::from_str(&record.results.unwrap()).unwrap();
        assert_eq!(results_val["count"], 0);
        assert_eq!(results_val["installed_deps"], serde_json::json!([]));
        assert_eq!(results_val["unresolved_deps"], serde_json::json!([]));

        // Insert addon with unresolvable dependency
        conn.execute(
            "INSERT INTO addons (id, flavour, name, required_deps) VALUES ('addon-2', 'retail', 'NeedyAddon', '[\"TotallyFakeDepThatDoesNotExist\"]')",
            [],
        ).unwrap();

        let res2 = runner.run_job(
            &mut conn,
            "install-deps",
            Some("retail"),
            serde_json::json!({ "addon_id": "addon-2" }),
        ).await;
        assert!(res2.is_ok());
        let record2 = res2.unwrap();
        let results_val2: serde_json::Value = serde_json::from_str(&record2.results.unwrap()).unwrap();
        assert_eq!(results_val2["count"], 0);
        assert_eq!(results_val2["installed_deps"], serde_json::json!([]));
        assert_eq!(results_val2["unresolved_deps"], serde_json::json!(["TotallyFakeDepThatDoesNotExist"]));
        assert_eq!(
            record2.error,
            Some("Failed to install dependency 'TotallyFakeDepThatDoesNotExist'".to_string())
        );

        // Cleanup
        std::env::remove_var("FURPHY_DEV_WOWROOT");
        let _ = std::fs::remove_dir_all(&temp);
    }

    #[tokio::test]
    async fn test_sync_job_failure_pipeline() {
        let _guard = crate::system::game::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let temp = std::env::temp_dir().join("furphy test wow (sync failure pipeline)");
        let retail_addons = temp.join("_retail_").join("Interface").join("AddOns");
        let _ = std::fs::create_dir_all(&retail_addons);
        std::env::set_var("FURPHY_DEV_WOWROOT", temp.to_str().unwrap());

        let policy = Arc::new(NetworkPolicy::new());
        let runner = JobRunner::new(policy);

        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
             VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name, source, project_id, version) VALUES ('failed-addon', 'retail', 'BrokenAddon', 'unknown-src', 12345, '1.0.0')",
            [],
        ).unwrap();

        let res = runner.run_job(
            &mut conn,
            "sync",
            Some("retail"),
            serde_json::json!({ "addon_id": "failed-addon" }),
        ).await;

        assert!(res.is_ok(), "sync job should succeed with completed status even if individual addon failed: {:?}", res);
        let record = res.unwrap();
        assert_eq!(record.state, "completed");
        assert_eq!(
            record.error,
            Some("1 addon(s) failed: BrokenAddon: Unknown source 'unknown-src'".to_string())
        );

        // Verify check_results table in DB
        let (cr_status, cr_err): (String, Option<String>) = conn.query_row(
            "SELECT status, error FROM check_results WHERE addon_id = 'failed-addon'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        ).unwrap();
        assert_eq!(cr_status, "failed");
        assert_eq!(cr_err, Some("Unknown source 'unknown-src'".to_string()));

        // Verify fetch_addons_with_details reflects the error
        let dtos = crate::commands::addons::fetch_addons_with_details(&conn, "retail").unwrap();
        assert_eq!(dtos.len(), 1);
        assert_eq!(dtos[0].id, "failed-addon");
        assert_eq!(dtos[0].error.as_deref(), Some("Unknown source 'unknown-src'"));
        assert_eq!(dtos[0].check_status.as_deref(), Some("failed"));

        // Cleanup
        std::env::remove_var("FURPHY_DEV_WOWROOT");
        let _ = std::fs::remove_dir_all(&temp);
    }
}
