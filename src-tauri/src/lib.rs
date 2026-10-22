pub mod cli;
pub mod commands;
pub mod db;
pub mod engine;
pub mod jobs;
pub mod logging;
pub mod net;
pub mod paths;
pub mod system;

use std::path::PathBuf;
use rusqlite::Connection;
use crate::engine::flavours::detect_installed_flavours_in_root;
use crate::engine::swap::restore_interrupted_folder_swaps;
use crate::jobs::runner::JobRunner;

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

    // 3. Crash recovery: recover interrupted folder swaps & unfinished jobs
    if let Ok(ref root) = wow_root_res {
        let installed = detect_installed_flavours_in_root(root);
        for flv in installed {
            restore_interrupted_folder_swaps(&flv.addons_path);
        }
    }
    let _ = JobRunner::recover_unfinished_jobs(&conn);

    // 4. Import from v1 if requested or if v1 folder exists
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
    for i in 0..args.len() {
        if args[i] == "--import-v1" && i + 1 < args.len() {
            import_arg = Some(PathBuf::from(&args[i + 1]));
        }
    }

    if let Err(e) = init_app(import_arg) {
        eprintln!("[FATAL] App initialization failed: {}", e);
        if paths::is_dev() {
            panic!("Dev startup aborted: {}", e);
        }
        std::process::exit(2);
    }

    // Handle CLI arguments
    let rt = tokio::runtime::Runtime::new().expect("Failed creating Tokio runtime");
    match rt.block_on(cli::handle_cli_args(&args)) {
        Ok(true) => {
            // CLI command completed
            std::process::exit(0);
        }
        Err(code) => {
            std::process::exit(code);
        }
        Ok(false) => {
            // Proceed to GUI
        }
    }

    let mut context = tauri::generate_context!();
    if paths::is_dev() {
        context.config_mut().identifier = "krenzcreative.furphy.addonmanager.dev".to_string();
        context.config_mut().product_name = Some("Furphy Dev".to_string());
    }

    use tauri::Manager;

    tauri::Builder::default()
        .setup(|app| {
            if let Some(main_window) = app.get_webview_window("main") {
                system::window::apply_saved_webview_window_bounds(&main_window);
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            match event {
                tauri::WindowEvent::CloseRequested { api, .. } => {
                    api.prevent_close();
                    system::window::save_current_window_bounds(window);
                    let _ = window.hide();
                }
                _ => {}
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::addons::get_addons,
            commands::addons::get_flavours,
            commands::addons::get_app_info,
            commands::system::autostart_enable,
            commands::system::autostart_disable,
            commands::system::autostart_status,
            commands::system::protocol_register,
            commands::system::protocol_unregister,
            commands::system::protocol_status,
            commands::system::protocol_check_consent,
            commands::system::get_tray_status,
            commands::system::set_background_updates,
            commands::system::is_game_active,
        ])
        .run(context)
        .expect("error while running tauri application");
}
