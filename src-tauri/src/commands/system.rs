use crate::db::open_connection;
use crate::paths::get_db_path;
use crate::system::autostart::{
    disable_autostart, enable_autostart, get_autostart_status, AutostartStatusDto,
};
use crate::system::game::is_wow_running;
use crate::system::protocol::{
    get_protocol_status, register_protocol, unregister_protocol, ProtocolStatusDto,
};
use crate::system::schedule::Scheduler;
use crate::system::tray_status::TrayStateSnapshot;

#[tauri::command]
pub fn autostart_enable() -> Result<(), String> {
    enable_autostart(None)?;
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let true_val = serde_json::to_string(&true).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('runAtStartup', ?1) \
         ON CONFLICT(key) DO UPDATE SET value = ?1",
        rusqlite::params![true_val],
    ).map_err(|e| e.to_string())?;
    // Turning it on in the UI also turns background updates on (SPA rule §2.H)
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('backgroundUpdates', ?1) \
         ON CONFLICT(key) DO UPDATE SET value = ?1",
        rusqlite::params![true_val],
    ).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn autostart_disable() -> Result<(), String> {
    disable_autostart(None)?;
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let false_val = serde_json::to_string(&false).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('runAtStartup', ?1) \
         ON CONFLICT(key) DO UPDATE SET value = ?1",
        rusqlite::params![false_val],
    ).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn autostart_status() -> Result<AutostartStatusDto, String> {
    get_autostart_status(None)
}

#[tauri::command]
pub fn protocol_register() -> Result<(), String> {
    register_protocol(None)
}

#[tauri::command]
pub fn protocol_unregister() -> Result<(), String> {
    unregister_protocol(None)
}

#[tauri::command]
pub fn protocol_status() -> Result<ProtocolStatusDto, String> {
    get_protocol_status(None)
}

#[tauri::command]
pub fn get_tray_status() -> Result<TrayStateSnapshot, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    if let Some(state) = Scheduler::load_persisted_tray_state(&conn) {
        Ok(state)
    } else {
        Ok(TrayStateSnapshot::default())
    }
}

#[tauri::command]
pub fn tray_status() -> Result<TrayStateSnapshot, String> {
    get_tray_status()
}

#[tauri::command]
pub fn set_background_updates(enabled: bool) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let val_json = serde_json::to_string(&enabled).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('backgroundUpdates', ?1) \
         ON CONFLICT(key) DO UPDATE SET value = ?1",
        rusqlite::params![val_json],
    )
    .map_err(|e| e.to_string())?;

    let mut state = Scheduler::load_persisted_tray_state(&conn).unwrap_or_default();
    if enabled {
        let next_run = chrono::Utc::now() + chrono::Duration::seconds(crate::system::schedule::FIRST_CYCLE_DELAY_SECS);
        state.next_run_at = Some(next_run);
        state.core_text = crate::system::tray_status::compute_core(
            crate::system::tray_status::STATUS_IDLE,
            None,
            None,
            0,
            0,
            0,
            0,
            0,
            0,
            None,
            Some(next_run),
            None,
            None,
            None,
        );
    } else {
        state.next_run_at = None;
        state.core_text = "Background updates off".to_string();
    }
    state.tooltip = crate::system::tray_status::make_tooltip(&state.core_text);
    let _ = Scheduler::persist_tray_state(&conn, &state);

    Ok(())
}

#[tauri::command]
pub fn is_game_active() -> Result<bool, String> {
    Ok(is_wow_running())
}
