#[cfg(windows)]
pub fn try_activate_existing_instance(args: &[String]) -> bool {
    let pipe_name = if crate::paths::is_dev() {
        r"\\.\pipe\FurphyAddonManager_Dev_SingleInstance"
    } else {
        r"\\.\pipe\FurphyAddonManager_SingleInstance"
    };

    use std::io::Write;
    let msg = if args.iter().any(|a| a == "--tray") {
        "ping\n"
    } else {
        "show\n"
    };

    if let Ok(mut file) = std::fs::OpenOptions::new().write(true).open(pipe_name) {
        let _ = file.write_all(msg.as_bytes());
        let _ = file.flush();
        return true;
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
                let mut reader = tokio::io::BufReader::new(server);
                let mut line = String::new();
                if reader.read_line(&mut line).await.is_ok() {
                    let cmd = line.trim();
                    if cmd == "show" {
                        use tauri::Manager;
                        if let Some(window) = app_handle.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.unminimize();
                            let _ = window.set_focus();
                            if let Ok(hwnd) = window.hwnd() {
                                let _ = crate::system::window::bring_window_to_front(hwnd.0 as isize);
                            }
                        }
                    }
                }
            }
        }
    });
}

#[cfg(not(windows))]
pub fn start_single_instance_listener<R: tauri::Runtime>(_app_handle: tauri::AppHandle<R>) {}
