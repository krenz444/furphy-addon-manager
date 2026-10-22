use rusqlite::Connection;
use crate::paths::get_db_path;
use crate::system::autostart::{
    disable_autostart, enable_autostart, get_autostart_status, AutostartStatusDto,
};
use crate::system::game::is_wow_running;
use crate::system::protocol::{
    check_protocol_consent, get_protocol_status, parse_protocol_url, register_protocol,
    unregister_protocol, ProtocolConsentInfo, ProtocolStatusDto,
};
use crate::system::schedule::Scheduler;
use crate::system::tray_status::TrayStateSnapshot;

#[tauri::command]
pub fn autostart_enable() -> Result<(), String> {
    enable_autostart(None)
}

#[tauri::command]
pub fn autostart_disable() -> Result<(), String> {
    disable_autostart(None)
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
pub fn protocol_check_consent(
    url: String,
    flavour: Option<String>,
) -> Result<ProtocolConsentInfo, String> {
    let req = parse_protocol_url(&url, None)?;
    let db_path = get_db_path();
    let conn = Connection::open(&db_path).map_err(|e| e.to_string())?;
    let flv = flavour.unwrap_or_else(|| "retail".into());
    check_protocol_consent(&conn, &req, &flv)
}

#[tauri::command]
pub fn get_tray_status() -> Result<TrayStateSnapshot, String> {
    let db_path = get_db_path();
    let conn = Connection::open(&db_path).map_err(|e| e.to_string())?;
    if let Some(state) = Scheduler::load_persisted_tray_state(&conn) {
        Ok(state)
    } else {
        Ok(TrayStateSnapshot::default())
    }
}

#[tauri::command]
pub fn set_background_updates(enabled: bool) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = Connection::open(&db_path).map_err(|e| e.to_string())?;
    let val_json = serde_json::to_string(&enabled).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('backgroundUpdates', ?1) \
         ON CONFLICT(key) DO UPDATE SET value = ?1",
        rusqlite::params![val_json],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn is_game_active() -> Result<bool, String> {
    Ok(is_wow_running())
}
