use std::path::PathBuf;
use std::sync::Arc;
use rusqlite::Connection;
use serde_json::Value;
use crate::db::export_v1::export_to_v1;
use crate::db::repo::{get_addons_by_flavour, get_installed_flavours_db};
use crate::jobs::runner::{JobError, JobRunner};
use crate::net::policy::NetworkPolicy;
use crate::paths::{detect_wow_root, get_db_path};

pub async fn handle_cli_args(args: &[String]) -> Result<bool, i32> {
    // If no CLI flags present, return Ok(false) to launch GUI
    let is_cli = args.iter().any(|a| {
        a == "--check"
            || a == "--sync"
            || a == "--status"
            || a == "--export-v1"
            || a == "--selftest"
    });

    if !is_cli {
        return Ok(false);
    }

    let is_json = args.iter().any(|a| a == "--json");
    let is_selftest = args.iter().any(|a| a == "--selftest");
    let mut flavour_filter: Option<String> = None;
    let mut export_dir: Option<PathBuf> = None;

    for i in 0..args.len() {
        if args[i] == "--flavour" && i + 1 < args.len() {
            flavour_filter = Some(args[i + 1].clone());
        } else if args[i] == "--export-v1" && i + 1 < args.len() {
            export_dir = Some(PathBuf::from(&args[i + 1]));
        }
    }

    let db_path = get_db_path();
    let mut conn = Connection::open(&db_path).map_err(|e| {
        eprintln!("[FATAL] Could not open database at {}: {}", db_path.display(), e);
        2
    })?;

    if let Some(exp_path) = export_dir {
        if let Err(e) = export_to_v1(&conn, &exp_path) {
            eprintln!("[ERROR] Export to v1 failed: {}", e);
            return Err(2);
        } else {
            if is_json {
                println!("{}", serde_json::json!({ "exported_to": exp_path.display().to_string() }));
            } else {
                println!("Exported v1 data to: {}", exp_path.display());
            }
            return Ok(true);
        }
    }

    if is_selftest {
        // Runs a self-test: checks DB readability and WoW root detection
        match detect_wow_root(None) {
            Ok(root) => {
                if is_json {
                    println!("{}", serde_json::json!({ "selftest": "ok", "wow_root": root.display().to_string() }));
                } else {
                    println!("Selftest OK (WoW root: {})", root.display());
                }
                return Ok(true);
            }
            Err(e) => {
                eprintln!("Selftest FAILED: {}", e);
                return Err(2);
            }
        }
    }

    // Handle --status (no network)
    if args.iter().any(|a| a == "--status") {
        let flavours = get_installed_flavours_db(&conn).map_err(|_| 2)?;
        let mut status_map = serde_json::Map::new();

        for flv in flavours {
            if let Some(ref filter) = flavour_filter {
                if &flv.id != filter {
                    continue;
                }
            }
            let addons = get_addons_by_flavour(&conn, &flv.id).map_err(|_| 2)?;
            status_map.insert(flv.id, serde_json::to_value(&addons).unwrap());
        }

        if is_json {
            println!("{}", serde_json::to_string_pretty(&Value::Object(status_map)).unwrap());
        } else {
            for (flv_id, addons_val) in &status_map {
                println!("=== Flavour: {} ===", flv_id);
                if let Some(arr) = addons_val.as_array() {
                    for item in arr {
                        let name = item.get("name").and_then(|v| v.as_str()).unwrap_or("Unknown");
                        let ver = item.get("version").and_then(|v| v.as_str()).unwrap_or("?");
                        println!("  {} ({})", name, ver);
                    }
                }
            }
        }
        return Ok(true);
    }

    let policy = Arc::new(NetworkPolicy::new());
    let runner = JobRunner::new(policy);

    // Handle --check
    if args.iter().any(|a| a == "--check") {
        let flavours = get_installed_flavours_db(&conn).map_err(|_| 2)?;
        let mut reports = Vec::new();

        for flv in flavours {
            if let Some(ref filter) = flavour_filter {
                if &flv.id != filter {
                    continue;
                }
            }

            match runner
                .run_job(&mut conn, "check", Some(&flv.id), Value::Null)
                .await
            {
                Ok(rec) => {
                    let val: Value = rec
                        .results
                        .as_deref()
                        .and_then(|s| serde_json::from_str(s).ok())
                        .unwrap_or(Value::Null);
                    reports.push(val);
                }
                Err(JobError::Busy(id)) => {
                    eprintln!("Operation busy: job {} currently running", id);
                    return Err(1);
                }
                Err(e) => {
                    eprintln!("Check failed for flavour {}: {}", flv.id, e);
                    return Err(1);
                }
            }
        }

        if is_json {
            println!("{}", serde_json::to_string_pretty(&reports).unwrap());
        } else {
            for r in &reports {
                println!(
                    "Check for {}: {} updates ready, {} up to date",
                    r.get("flavour").and_then(|v| v.as_str()).unwrap_or("?"),
                    r.get("would_update_count").and_then(|v| v.as_u64()).unwrap_or(0),
                    r.get("up_to_date_count").and_then(|v| v.as_u64()).unwrap_or(0)
                );
            }
        }
        return Ok(true);
    }

    // Handle --sync
    if args.iter().any(|a| a == "--sync") {
        let flavours = get_installed_flavours_db(&conn).map_err(|_| 2)?;
        let mut reports = Vec::new();

        for flv in flavours {
            if let Some(ref filter) = flavour_filter {
                if &flv.id != filter {
                    continue;
                }
            }

            match runner
                .run_job(&mut conn, "sync", Some(&flv.id), Value::Null)
                .await
            {
                Ok(rec) => {
                    let val: Value = rec
                        .results
                        .as_deref()
                        .and_then(|s| serde_json::from_str(s).ok())
                        .unwrap_or(Value::Null);
                    reports.push(val);
                }
                Err(JobError::Busy(id)) => {
                    eprintln!("Operation busy: job {} currently running", id);
                    return Err(1);
                }
                Err(e) => {
                    eprintln!("Sync failed for flavour {}: {}", flv.id, e);
                    return Err(1);
                }
            }
        }

        if is_json {
            println!("{}", serde_json::to_string_pretty(&reports).unwrap());
        } else {
            for r in &reports {
                println!(
                    "Sync for {}: {} updated, {} up to date, {} failed",
                    r.get("flavour").and_then(|v| v.as_str()).unwrap_or("?"),
                    r.get("updated").and_then(|v| v.as_u64()).unwrap_or(0),
                    r.get("up_to_date").and_then(|v| v.as_u64()).unwrap_or(0),
                    r.get("failed").and_then(|v| v.as_u64()).unwrap_or(0)
                );
            }
        }
        return Ok(true);
    }

    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_cli_no_args_returns_false() {
        let args = vec!["furphy.exe".to_string()];
        let res = handle_cli_args(&args).await;
        assert_eq!(res, Ok(false));
    }

    #[tokio::test]
    async fn test_cli_unusable_path_returns_exit_code_2() {
        // If DB cannot be opened or path is invalid, returns Err(2)
        let args = vec![
            "furphy.exe".to_string(),
            "--export-v1".to_string(),
            "Z:\\NonExistentDrive\\sync".to_string(),
        ];
        let res = handle_cli_args(&args).await;
        // Either DB open fails (2) or export fails (2)
        assert_eq!(res, Err(2));
    }
}
