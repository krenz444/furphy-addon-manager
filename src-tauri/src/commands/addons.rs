use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use crate::db::repo::{get_addons_by_flavour, get_installed_flavours_db, AddonDto, FlavourDto};
use crate::paths::{get_db_path, is_dev};

#[derive(Debug, Serialize, Deserialize)]
pub struct AppInfoDto {
    pub name: String,
    pub version: String,
    pub is_dev: bool,
    pub identifier: String,
}

#[tauri::command]
pub fn get_addons(flavour: Option<String>) -> Result<Vec<AddonDto>, String> {
    let db_path = get_db_path();
    let conn = Connection::open(&db_path).map_err(|e| e.to_string())?;
    let active_flavour = flavour.unwrap_or_else(|| "retail".into());
    get_addons_by_flavour(&conn, &active_flavour).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_flavours() -> Result<Vec<FlavourDto>, String> {
    let db_path = get_db_path();
    let conn = Connection::open(&db_path).map_err(|e| e.to_string())?;
    get_installed_flavours_db(&conn).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_app_info() -> Result<AppInfoDto, String> {
    let dev = is_dev();
    Ok(AppInfoDto {
        name: if dev { "Furphy Dev".into() } else { "Furphy Addon Manager".into() },
        version: "2.0.0-dev".into(),
        is_dev: dev,
        identifier: if dev {
            "krenzcreative.furphy.addonmanager.dev".into()
        } else {
            "krenzcreative.furphy.addonmanager".into()
        },
    })
}
