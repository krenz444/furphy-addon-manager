// Stub, replaced by the feature lane.
use std::sync::Arc;
use crate::net::policy::NetworkPolicy;

#[derive(Debug, Clone, serde::Serialize)]
pub struct TukuiAddonDto {
    pub slug: String,
    pub name: String,
    pub author: String,
    pub version: String,
    pub last_update: Option<String>,
    pub supported_patches: Vec<String>,
    pub summary: Option<String>,
    pub web_url: Option<String>,
    pub compatible: bool,
    pub reason: Option<String>,
    pub installed: bool,
}

#[tauri::command]
pub async fn tukui_addons(
    _policy: tauri::State<'_, Arc<NetworkPolicy>>,
    _flavour: Option<String>,
) -> Result<Vec<TukuiAddonDto>, String> {
    Ok(Vec::new())
}
