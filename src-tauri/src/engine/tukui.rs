// Stub, replaced by the feature lane.
use crate::net::policy::NetworkPolicy;
use crate::net::tukui::TukuiAddon;

pub fn version_prefix_for(_flavour_id: &str, _client_build: Option<&str>) -> Option<String> {
    None
}

pub fn tukui_supports(_addon: &TukuiAddon, _version_prefix: Option<&str>) -> bool {
    true
}

pub fn tukui_unavailable_reason(_addon: &TukuiAddon, _era_label: &str, _version_prefix: Option<&str>) -> Option<String> {
    None
}

#[derive(Debug, Clone)]
pub struct TukuiChoice {
    pub file_id: String,
    pub version: String,
    pub file_name: String,
    pub download_url: String,
    pub released: Option<String>,
}

pub async fn choose_tukui_release(
    _policy: &NetworkPolicy,
    _client: &reqwest::Client,
    _slug: &str,
    _flavour_id: &str,
    _era_label: &str,
    _client_build: Option<&str>,
) -> Result<TukuiChoice, String> {
    Err("not implemented yet".to_string())
}
