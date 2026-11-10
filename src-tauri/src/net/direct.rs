// Stub, replaced by the feature lane.
use crate::net::policy::NetworkPolicy;

pub const MAX_ZIP_BYTES: u64 = 200 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct DirectDownload {
    pub bytes: u64,
    pub file_name: String,
    pub last_modified: Option<String>,
}

pub fn validate_zip_url(_raw: &str) -> Result<reqwest::Url, String> {
    Err("not implemented yet".to_string())
}

pub fn create_direct_client() -> reqwest::Result<reqwest::Client> {
    crate::net::ip_mode::apply(reqwest::Client::builder()).build()
}

pub async fn download_zip_url(
    _policy: &NetworkPolicy,
    _client: &reqwest::Client,
    _url: &str,
    _dest: &std::path::Path,
) -> Result<DirectDownload, String> {
    Err("not implemented yet".to_string())
}
