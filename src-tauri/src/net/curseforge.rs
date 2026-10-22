use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use std::time::Duration;
use chrono::Utc;
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, REFERER, USER_AGENT};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use crate::logging::append_app_log;
use crate::net::policy::NetworkPolicy;

pub const CF_USER_AGENT: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CfFile {
    pub id: i64,
    pub display_name: Option<String>,
    pub file_name: Option<String>,
    pub file_length: Option<u64>,
    pub release_type: i64,
    pub project_id: Option<i64>,
    #[serde(default)]
    pub game_versions: Vec<String>,
    #[serde(default)]
    pub game_version_type_ids: Vec<i64>,
    pub date_created: Option<String>,
}

pub fn get_cf_base_url() -> String {
    if let Ok(val) = std::env::var("FURPHY_TEST_CF_BASEURL") {
        let trimmed = val.trim();
        if !trimmed.is_empty() {
            return trimmed.trim_end_matches('/').to_string();
        }
    }
    "https://www.curseforge.com".to_string()
}

pub fn create_cf_client() -> reqwest::Result<Client> {
    Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
}

fn build_cf_headers(base_url: &str) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(USER_AGENT, HeaderValue::from_static(CF_USER_AGENT));
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
    if let Ok(ref_val) = HeaderValue::from_str(&format!("{}/", base_url)) {
        headers.insert(REFERER, ref_val);
    }
    headers
}

pub async fn execute_cf_request(
    policy: &NetworkPolicy,
    client: &Client,
    url: &str,
) -> Result<reqwest::Response, String> {
    let base_url = get_cf_base_url();
    let host = reqwest::Url::parse(url)
        .map_err(|e| e.to_string())?
        .host_str()
        .unwrap_or("")
        .to_string();

    let mut attempt = 0;
    let max_attempts = 2;

    loop {
        attempt += 1;
        let _permit = policy.acquire_permit(&host).await?;

        let res = client
            .get(url)
            .headers(build_cf_headers(&base_url))
            .send()
            .await;

        match res {
            Ok(resp) => {
                let status = resp.status();
                policy.breaker.register_http_response(&host);

                if status.is_success() {
                    return Ok(resp);
                }

                if status.as_u16() == 403 || status.as_u16() == 429 {
                    if attempt < max_attempts {
                        append_app_log(
                            "WARN",
                            &format!("HTTP {} from {} - waiting 5 seconds and retrying", status.as_u16(), url),
                        );
                        tokio::time::sleep(Duration::from_secs(5)).await;
                        continue;
                    } else {
                        // ADR-312: Survival of 403/429 switches to 24h fallback
                        let fallback_until = Utc::now() + chrono::Duration::hours(24);
                        policy.set_cf_fallback(fallback_until).await;
                        return Err(format!("CurseForge request failed with HTTP {}", status.as_u16()));
                    }
                }

                if status.is_server_error() && attempt < max_attempts {
                    append_app_log("WARN", &format!("HTTP {} from {} - retrying", status.as_u16(), url));
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }

                return Err(format!("CurseForge HTTP request error: {}", status));
            }
            Err(e) => {
                policy.breaker.register_connectivity_failure(&host);
                if attempt < max_attempts {
                    append_app_log("WARN", &format!("Transport error from {} - retrying: {}", url, e));
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
                return Err(format!("CurseForge connection error: {}", e));
            }
        }
    }
}

pub async fn get_cf_files(
    policy: &NetworkPolicy,
    client: &Client,
    project_id: i64,
    max_release_type: i64,
) -> Result<Vec<CfFile>, String> {
    let base_url = get_cf_base_url();
    let remove_alphas = if max_release_type >= 3 {
        ""
    } else {
        "&removeAlphas=true"
    };

    let url = format!(
        "{}/api/v1/mods/{}/files?pageIndex=0&pageSize=20&sort=dateCreated&sortDescending=true{}",
        base_url, project_id, remove_alphas
    );

    let resp = execute_cf_request(policy, client, &url).await?;
    let text = resp.text().await.map_err(|e| e.to_string())?;

    let root: Value = serde_json::from_str(&text).map_err(|e| format!("Invalid JSON from CurseForge: {}", e))?;
    let data = root
        .get("data")
        .and_then(|v| v.as_array())
        .ok_or_else(|| format!("Empty or invalid file list for project {}", project_id))?;

    let files: Vec<CfFile> = serde_json::from_value(Value::Array(data.clone()))
        .map_err(|e| format!("Failed parsing files for project {}: {}", project_id, e))?;

    Ok(files)
}

pub async fn get_cf_file_by_id(
    policy: &NetworkPolicy,
    client: &Client,
    project_id: i64,
    file_id: i64,
) -> Result<Option<CfFile>, String> {
    let base_url = get_cf_base_url();
    let url = format!("{}/api/v1/mods/{}/files/{}", base_url, project_id, file_id);

    let resp = execute_cf_request(policy, client, &url).await?;
    let text = resp.text().await.map_err(|e| e.to_string())?;

    let root: Value = serde_json::from_str(&text).map_err(|e| format!("Invalid JSON from CurseForge: {}", e))?;
    if let Some(data) = root.get("data") {
        let file: CfFile = serde_json::from_value(data.clone())
            .map_err(|e| format!("Failed parsing file {} for project {}: {}", file_id, project_id, e))?;
        Ok(Some(file))
    } else {
        Ok(None)
    }
}

pub async fn download_cf_file(
    policy: &NetworkPolicy,
    client: &Client,
    project_id: i64,
    file: &CfFile,
    dest_path: &Path,
) -> Result<u64, String> {
    let base_url = get_cf_base_url();
    let download_url = format!("{}/api/v1/mods/{}/files/{}/download", base_url, project_id, file.id);

    if let Some(parent) = dest_path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let resp = execute_cf_request(policy, client, &download_url).await?;
    let bytes = resp.bytes().await.map_err(|e| e.to_string())?;

    if bytes.is_empty() {
        return Err(format!("Downloaded file is zero-length for project {} file {}", project_id, file.id));
    }

    if let Some(expected_len) = file.file_length {
        if expected_len > 0 && (bytes.len() as u64) != expected_len {
            return Err(format!(
                "Downloaded file size mismatch for project {} file {} (expected {}, got {})",
                project_id, file.id, expected_len, bytes.len()
            ));
        }
    }

    let mut out_file = File::create(dest_path).map_err(|e| e.to_string())?;
    out_file.write_all(&bytes).map_err(|e| e.to_string())?;

    Ok(bytes.len() as u64)
}
