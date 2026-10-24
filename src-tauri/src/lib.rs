pub mod cli;
pub mod commands;
pub mod db;
pub mod engine;
pub mod jobs;
pub mod logging;
pub mod net;
pub mod paths;
pub mod system;
pub mod update;

use std::path::PathBuf;
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
    let mut conn = db::open_connection(&db_path)?;
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
                    // Section 5.2: First run of v2 on a PC that has v1
                    system::retire_v1::retire_v1_blocking(system::retire_v1::RetireOptions {
                        custom_v1_path: Some(v1_path.clone()),
                        ..Default::default()
                    });
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

    let current_exe = std::env::current_exe().unwrap_or_default();
    let exe_name = current_exe
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default()
        .to_lowercase();
    let is_setup_exe = exe_name.contains("setup");

    // Check for installation lifecycle arguments before init_app
    let is_silent = args.iter().any(|a| a.eq_ignore_ascii_case("/S") || a == "--silent");
    let is_uninstall = args.iter().any(|a| a == "--uninstall");
    let is_install = !is_uninstall && (is_setup_exe || args.iter().any(|a| a == "--install") || is_silent);

    if is_install {
        if let Err(e) = system::setup::run_install(is_silent, None) {
            eprintln!("[FATAL] Installation failed: {}", e);
            std::process::exit(1);
        }
        std::process::exit(0);
    }

    if is_uninstall {
        if let Err(e) = system::setup::run_uninstall(is_silent, None) {
            eprintln!("[FATAL] Uninstallation failed: {}", e);
            std::process::exit(1);
        }
        std::process::exit(0);
    }

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

    // Single-instance enforcement for GUI
    if system::single_instance::try_activate_existing_instance(&args) {
        std::process::exit(0);
    }

    let mut context = tauri::generate_context!();
    if paths::is_dev() {
        context.config_mut().identifier = "krenzcreative.furphy.addonmanager.dev".to_string();
        context.config_mut().product_name = Some("Furphy Dev".to_string());
    }

    use tauri::Manager;

    tauri::Builder::default()
        .setup(|app| {
            let window = app.get_webview_window("main")
                .or_else(|| app.webview_windows().values().next().cloned());
            if let Some(main_window) = window {
                system::window::apply_saved_webview_window_bounds(&main_window);
                // If started with --tray, hide the main window initially
                if std::env::args().any(|a| a == "--tray") {
                    let _ = main_window.hide();
                } else {
                    let _ = main_window.show();
                    let _ = main_window.set_focus();
                }
            } else {
                eprintln!("[WARN] No main webview window found in setup!");
            }

            // Initialize Scheduler, Policy, Runner and Tray
            let policy = std::sync::Arc::new(net::policy::NetworkPolicy::default());
            let db_path = paths::get_db_path();
            if let Ok(conn) = db::open_connection(&db_path) {
                policy.load_fallback_from_db(&conn);
            }
            let runner = std::sync::Arc::new(jobs::runner::JobRunner::new(policy.clone()));
            let initial_state = {
                if let Ok(conn) = db::open_connection(&db_path) {
                    system::schedule::Scheduler::load_persisted_tray_state(&conn).unwrap_or_default()
                } else {
                    system::tray_status::TrayStateSnapshot::default()
                }
            };
            let scheduler = std::sync::Arc::new(system::schedule::Scheduler::new(runner.clone(), initial_state));
            system::single_instance::start_single_instance_listener(app.handle().clone());
            if let Err(e) = system::tray::setup_tray(app.handle(), scheduler.clone()) {
                logging::append_app_log("ERROR", &format!("setup_tray failed: {}", e));
                eprintln!("[ERROR] setup_tray failed: {}", e);
            } else {
                logging::append_app_log("INFO", "setup_tray succeeded");
            }
            scheduler.clone().start_background_loop();
            app.manage(policy);
            app.manage(runner);
            app.manage(scheduler);

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
            commands::addons::get_state,
            commands::addons::set_ignore,
            commands::addons::unpin,
            commands::addons::pin_version,
            commands::addons::list_files,
            commands::addons::scan_untracked,
            commands::addons::delete_untracked_folder,
            commands::addons::delete_untracked_addon,
            commands::addons::ignore_untracked_addon,
            commands::addons::unignore_untracked_folder,
            commands::addons::list_ignored_untracked,
            commands::addons::ignore_dependency,
            commands::addons::unignore_dependency,
            commands::addons::adopt_untracked,
            commands::addons::adopt_all_untracked,
            commands::addons::list_not_built_for_patch,
            commands::addons::install_dependencies,
            commands::jobs::start_job,
            commands::jobs::list_jobs,
            commands::jobs::get_job,
            commands::wtf::list_wtf_snapshots,
            commands::wtf::preview_wtf_restore,
            commands::wtf::restore_wtf_snapshot,
            commands::open::open_target,
            commands::settings::get_settings,
            commands::settings::update_settings,
            commands::settings::export_list,
            commands::settings::import_list,
            commands::settings::run_diagnostics,
            commands::settings::list_migration_backups,
            commands::settings::delete_migration_backups,
            commands::settings::quit_app,
            commands::settings::set_window_theme,
            commands::settings::app_update_check,
            commands::settings::app_update_install,
            commands::settings::app_update_status,
            commands::browse::wago_search,
            commands::browse::wago_categories,
            commands::browse::wago_addon,
            commands::browse::cf_browse,
            commands::browse::cf_enrich,
            commands::system::autostart_enable,
            commands::system::autostart_disable,
            commands::system::autostart_status,
            commands::system::protocol_register,
            commands::system::protocol_unregister,
            commands::system::protocol_status,
            commands::system::get_tray_status,
            commands::system::tray_status,
            commands::system::set_background_updates,
            commands::system::is_game_active,
        ])
        .run(context)
        .expect("error while running tauri application");
}
