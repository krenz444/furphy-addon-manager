#[cfg(windows)]
pub fn try_activate_existing_instance(args: &[String]) -> bool {
    let pipe_name = if crate::paths::is_dev() {
        r"\\.\pipe\FurphyAddonManager_Dev_SingleInstance"
    } else {
        r"\\.\pipe\FurphyAddonManager_SingleInstance"
    };

    let is_tray = args.iter().any(|a| a == "--tray");
    if !is_tray {
        crate::system::window::allow_set_foreground_window();
    }

    use std::io::Write;
    let msg = if is_tray { "ping\n" } else { "show\n" };

    const ERROR_PIPE_BUSY: i32 = 231;
    for attempt in 0..30 {
        match std::fs::OpenOptions::new().write(true).open(pipe_name) {
            Ok(mut file) => {
                let _ = file.write_all(msg.as_bytes());
                let _ = file.flush();
                return true;
            }
            Err(e) if e.raw_os_error() == Some(ERROR_PIPE_BUSY) && attempt < 29 => {
                std::thread::sleep(std::time::Duration::from_millis(25));
            }
            Err(_) => return false,
        }
    }
    false
}

#[cfg(not(windows))]
pub fn try_activate_existing_instance(_args: &[String]) -> bool {
    false
}

#[cfg(windows)]
pub fn start_single_instance_listener<R: tauri::Runtime>(app_handle: tauri::AppHandle<R>) {
    let pipe_name = if crate::paths::is_dev() {
        r"\\.\pipe\FurphyAddonManager_Dev_SingleInstance"
    } else {
        r"\\.\pipe\FurphyAddonManager_SingleInstance"
    };

    tauri::async_runtime::spawn(async move {
        use tokio::io::AsyncBufReadExt;
        use tokio::net::windows::named_pipe::ServerOptions;

        let server_options = ServerOptions::new();
        loop {
            let server = match server_options.create(pipe_name) {
                Ok(s) => s,
                Err(e) => {
                    crate::logging::append_app_log("ERROR", &format!("Failed creating named pipe server: {}", e));
                    tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
                    continue;
                }
            };

            if server.connect().await.is_ok() {
                let handle = app_handle.clone();
                tauri::async_runtime::spawn(async move {
                    let mut reader = tokio::io::BufReader::new(server);
                    let mut line = String::new();
                    let read_res = tokio::time::timeout(
                        std::time::Duration::from_secs(2),
                        reader.read_line(&mut line),
                    )
                    .await;
                    if let Ok(Ok(_)) = read_res {
                        if line.trim() == "show" {
                            let handle_for_main = handle.clone();
                            let _ = handle.run_on_main_thread(move || {
                                crate::system::window::show_and_focus_main_window(&handle_for_main);
                            });
                        }
                    }
                });
            }
        }
    });
}

#[cfg(not(windows))]
pub fn start_single_instance_listener<R: tauri::Runtime>(_app_handle: tauri::AppHandle<R>) {}
