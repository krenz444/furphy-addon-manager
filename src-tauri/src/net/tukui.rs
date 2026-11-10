// Stub, replaced by the feature lane.
use crate::net::policy::NetworkPolicy;

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct TukuiAddon {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub slug: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub patch: Vec<String>,
    #[serde(default)]
    pub last_update: Option<String>,
    #[serde(default)]
    pub web_url: Option<String>,
    #[serde(default)]
    pub small_desc: Option<String>,
    #[serde(default)]
    pub directories: Vec<String>,
}

pub fn get_tukui_base_url() -> String {
    std::env::var("FURPHY_TEST_TUKUI_BASEURL").unwrap_or_else(|_| "https://api.tukui.org".to_string())
}

pub fn create_tukui_client() -> reqwest::Result<reqwest::Client> {
    crate::net::ip_mode::apply(reqwest::Client::builder()).build()
}

pub async fn get_tukui_addons(_policy: &NetworkPolicy, _client: &reqwest::Client) -> Result<Vec<TukuiAddon>, String> {
    Err("not implemented yet".to_string())
}

pub async fn download_tukui_zip(
    _policy: &NetworkPolicy,
    _client: &reqwest::Client,
    _url: &str,
    _dest: &std::path::Path,
) -> Result<u64, String> {
    Err("not implemented yet".to_string())
}
