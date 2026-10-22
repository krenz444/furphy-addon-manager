pub mod commands;
pub mod db;
pub mod logging;
pub mod paths;

use std::path::PathBuf;
use rusqlite::Connection;

pub fn init_app(override_import_path: Option<PathBuf>) -> Result<(), Box<dyn std::error::Error>> {
    // 1. Check dev guard and detect WoW root
    let wow_root_res = paths::detect_wow_root(None);
    if let Err(e) = &wow_root_res {
        eprintln!("[ERROR] WoW detection failed: {}", e);
        if paths::is_dev() {
            // Live-PC safety: dev builds refuse to start without FURPHY_DEV_WOWROOT
            panic!("{}", e);
        }
    }

    // 2. Open DB and run migrations
    let db_path = paths::get_db_path();
    let mut conn = Connection::open(&db_path)?;
    db::migrate::run_migrations(&mut conn)?;

    // 3. Import from v1 if requested or if v1 folder exists
    let v1_dir = if let Some(path) = override_import_path {
        Some(path)
    } else if let Ok(ref root) = wow_root_res {
        let default_v1 = paths::get_v1_sync_folder(root);
        if default_v1.exists() {
            Some(default_v1)
        } else {
            None
        }
    } else {
        None
    };

    if let Some(v1_path) = v1_dir {
        let v2_data_dir = paths::get_data_dir();
        match db::import_v1::import_from_v1(&mut conn, &v1_path, &v2_data_dir, false) {
            Ok(summary) => {
                if !summary.already_imported {
                    logging::append_app_log("INFO", &format!(
                        "Imported from v1: {} addons, {} flavours, {} backups copied",
                        summary.addons_imported, summary.flavours_imported, summary.backups_copied
                    ));
                }
            }
            Err(e) => {
                logging::append_app_log("ERROR", &format!("Import from v1 failed: {}", e));
            }
        }
    }

    Ok(())
}

pub fn run() {
    let args: Vec<String> = std::env::args().collect();
    let mut import_arg: Option<PathBuf> = None;
    let mut export_arg: Option<PathBuf> = None;
    for i in 0..args.len() {
        if args[i] == "--import-v1" && i + 1 < args.len() {
            import_arg = Some(PathBuf::from(&args[i + 1]));
        } else if args[i] == "--export-v1" && i + 1 < args.len() {
            export_arg = Some(PathBuf::from(&args[i + 1]));
        }
    }

    if let Err(e) = init_app(import_arg) {
        eprintln!("[FATAL] App initialization failed: {}", e);
        if paths::is_dev() {
            panic!("Dev startup aborted: {}", e);
        }
        std::process::exit(2);
    }

    if let Some(export_dir) = export_arg {
        let db_path = paths::get_db_path();
        match Connection::open(&db_path) {
            Ok(conn) => {
                if let Err(e) = db::export_v1::export_to_v1(&conn, &export_dir) {
                    eprintln!("[ERROR] Export to v1 failed: {}", e);
                    std::process::exit(1);
                } else {
                    println!("Exported v1 data to: {}", export_dir.display());
                    std::process::exit(0);
                }
            }
            Err(e) => {
                eprintln!("[FATAL] Failed to open database for export: {}", e);
                std::process::exit(1);
            }
        }
    }

    let mut context = tauri::generate_context!();
    if paths::is_dev() {
        context.config_mut().identifier = "krenzcreative.furphy.addonmanager.dev".to_string();
        context.config_mut().product_name = Some("Furphy Dev".to_string());
    }

    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            commands::addons::get_addons,
            commands::addons::get_flavours,
            commands::addons::get_app_info,
        ])
        .run(context)
        .expect("error while running tauri application");
}
