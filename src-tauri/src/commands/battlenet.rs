// Stub, replaced by the feature lane.

#[derive(Debug, Clone, serde::Serialize)]
pub struct BattlenetInstallDto {
    pub product: String,
    pub install_path: String,
    pub flavour: Option<String>,
    pub flavour_folder_exists: bool,
    pub current_path: Option<String>,
}

#[tauri::command]
pub fn detect_battlenet_installs() -> Result<Vec<BattlenetInstallDto>, String> {
    Ok(Vec::new())
}
