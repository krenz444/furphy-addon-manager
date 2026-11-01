use std::path::PathBuf;
use std::sync::Arc;
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
            || a == "--tray-selftest"
            || a == "--protocol"
            || a == "--sign-file"
            || a == "--add"
    });

    if !is_cli {
        return Ok(false);
    }

    // Handle --sign-file <path>
    for i in 0..args.len() {
        if args[i] == "--sign-file" && i + 1 < args.len() {
            let file_path = PathBuf::from(&args[i + 1]);
            let file_bytes = match std::fs::read(&file_path) {
                Ok(b) => b,
                Err(e) => {
                    eprintln!("[ERROR] Could not read file to sign at {}: {}", file_path.display(), e);
                    return Err(1);
                }
            };

            let priv_key_val = match std::env::var("TAURI_SIGNING_PRIVATE_KEY") {
                Ok(k) if !k.trim().is_empty() => k,
                _ => {
                    eprintln!("[ERROR] TAURI_SIGNING_PRIVATE_KEY environment variable is not set");
                    return Err(1);
                }
            };

            let seed_bytes = match crate::update::app_update::parse_ed25519_pubkey(&priv_key_val) {
                Ok(b) => {
                    if b.len() == 32 {
                        let mut arr = [0u8; 32];
                        arr.copy_from_slice(&b);
                        arr
                    } else {
                        eprintln!("[ERROR] TAURI_SIGNING_PRIVATE_KEY must decode to 32 bytes, got {}", b.len());
                        return Err(1);
                    }
                }
                Err(e) => {
                    eprintln!("[ERROR] Could not decode TAURI_SIGNING_PRIVATE_KEY: {}", e);
                    return Err(1);
                }
            };

            match crate::update::app_update::sign_artifact_with_seed(&file_bytes, &seed_bytes) {
                Ok((sig, _)) => {
                    println!("{}", sig);
                    return Ok(true);
                }
                Err(e) => {
                    eprintln!("[ERROR] Signing failed: {}", e);
                    return Err(1);
                }
            }
        }
    }

    // Handle --tray-selftest <marker_path> [--wow-fake <name>]
    for i in 0..args.len() {
        if args[i] == "--tray-selftest" && i + 1 < args.len() {
            let marker_path = PathBuf::from(&args[i + 1]);
            let mut fake_wow: Option<String> = None;
            for j in 0..args.len() {
                if args[j] == "--wow-fake" && j + 1 < args.len() {
                    fake_wow = Some(args[j + 1].clone());
                }
            }
            match crate::system::tray::run_tray_selftest(&marker_path, fake_wow).await {
                Ok(_) => return Ok(true),
                Err(e) => {
                    eprintln!("[ERROR] Tray selftest failed: {}", e);
                    return Err(2);
                }
            }
        }
    }

    // Handle --protocol <url>
    for i in 0..args.len() {
        if args[i] == "--protocol" && i + 1 < args.len() {
            let url = &args[i + 1];
            match crate::system::protocol::parse_protocol_url(url, None) {
                Ok(req) => {
                    crate::system::protocol::append_handler_log(&format!(
                        "CLI protocol received: scheme={}, action={}, project={}, file={}",
                        req.scheme, req.action, req.project_id, req.file_id
                    ));
                    println!("Protocol install request valid for project {} file {}", req.project_id, req.file_id);
                    return Ok(true);
                }
                Err(e) => {
                    crate::system::protocol::append_handler_log(&format!(
                        "CLI protocol rejected ({}): {}", url, e
                    ));
                    eprintln!("[ERROR] Protocol handling failed: {}", e);
                    return Err(2);
                }
            }
        }
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
    let mut conn = crate::db::open_connection(&db_path).map_err(|e| {
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

    if let Some(ref filter) = flavour_filter {
        let flavours = get_installed_flavours_db(&conn).map_err(|_| 2)?;
        if !flavours.iter().any(|f| &f.id == filter) {
            eprintln!("[ERROR] Unknown or uninstalled flavour: {}", filter);
            return Err(2);
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

    // Handle --add <target>
    for i in 0..args.len() {
        if args[i] == "--add" {
            if i + 1 >= args.len() {
                eprintln!("[ERROR] Missing target for --add");
                return Err(2);
            }
            let target = &args[i + 1];
            let flv = flavour_filter.as_deref().unwrap_or("retail");
            let params = serde_json::json!({ "target": target });

            match runner
                .run_job(&mut conn, "add", Some(flv), params)
                .await
            {
                Ok(rec) => {
                    let val: Value = rec
                        .results
                        .as_deref()
                        .and_then(|s| serde_json::from_str(s).ok())
                        .unwrap_or(Value::Null);

                    if is_json {
                        println!("{}", serde_json::to_string_pretty(&val).unwrap_or_default());
                    } else {
                        let failed = val.get("failed").and_then(|v| v.as_u64()).unwrap_or(0);
                        if failed > 0 {
                            let err_msg = rec.error.as_deref().unwrap_or("Unknown error during add");
                            eprintln!("[ERROR] Add failed: {}", err_msg);
                            return Err(1);
                        } else {
                            let name = val.get("results")
                                .and_then(|r| r.as_array())
                                .and_then(|arr| arr.first())
                                .and_then(|item| item.get("name"))
                                .and_then(|n| n.as_str())
                                .unwrap_or(target);
                            let ver = val.get("results")
                                .and_then(|r| r.as_array())
                                .and_then(|arr| arr.first())
                                .and_then(|item| item.get("version"))
                                .and_then(|n| n.as_str())
                                .unwrap_or("");
                            if ver.is_empty() {
                                println!("Added {} (flavour: {})", name, flv);
                            } else {
                                println!("Added {} ({}) to flavour: {}", name, ver, flv);
                            }
                        }
                    }
                    return Ok(true);
                }
                Err(JobError::Busy(id)) => {
                    eprintln!("Operation busy: job {} currently running", id);
                    return Err(1);
                }
                Err(e) => {
                    eprintln!("Add failed for flavour {}: {}", flv, e);
                    return Err(1);
                }
            }
        }
    }

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

    #[tokio::test]
    async fn test_cli_unknown_flavour_returns_exit_code_2() {
        let args = vec![
            "furphy.exe".to_string(),
            "--status".to_string(),
            "--flavour".to_string(),
            "completely_bogus_flavour_xyz".to_string(),
        ];
        let res = handle_cli_args(&args).await;
        // Either DB open fails or unknown flavour returns Err(2)
        assert_eq!(res, Err(2));
    }

    #[tokio::test]
    async fn test_cli_tray_selftest_executes() {
        let temp_dir = tempfile::tempdir().unwrap();
        let marker = temp_dir.path().join("marker.json");
        let args = vec![
            "furphy.exe".to_string(),
            "--tray-selftest".to_string(),
            marker.to_string_lossy().to_string(),
        ];
        let res = handle_cli_args(&args).await;
        assert_eq!(res, Ok(true));
        assert!(marker.exists());
    }

    #[tokio::test]
    async fn test_cli_protocol_handler_valid_and_invalid() {
        let valid_args = vec![
            "furphy.exe".to_string(),
            "--protocol".to_string(),
            "curseforge://install?addonId=2382&fileId=12345".to_string(),
        ];
        assert_eq!(handle_cli_args(&valid_args).await, Ok(true));

        let invalid_args = vec![
            "furphy.exe".to_string(),
            "--protocol".to_string(),
            "curseforge://install?addonId=bad&fileId=12345".to_string(),
        ];
        assert_eq!(handle_cli_args(&invalid_args).await, Err(2));
    }

    #[tokio::test]
    async fn test_cli_add_missing_target_returns_exit_code_2() {
        let args = vec![
            "furphy.exe".to_string(),
            "--add".to_string(),
        ];
        assert_eq!(handle_cli_args(&args).await, Err(2));
    }
}
