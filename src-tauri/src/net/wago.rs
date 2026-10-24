use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, USER_AGENT};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use crate::logging::append_app_log;
use crate::net::policy::NetworkPolicy;

pub const WAGO_USER_AGENT: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WagoRelease {
    pub id: String,
    pub name: Option<String>,
    pub version: Option<String>,
    pub stability: Option<String>,
    pub size: Option<u64>,
    pub url: Option<String>,
    #[serde(default)]
    pub supported_retail_patches: Option<Vec<String>>,
    #[serde(default)]
    pub supported_classic_patches: Option<Vec<String>>,
    #[serde(default)]
    pub supported_bc_patches: Option<Vec<String>>,
    #[serde(default)]
    pub supported_wotlk_patches: Option<Vec<String>>,
    #[serde(default)]
    pub supported_cata_patches: Option<Vec<String>>,
    #[serde(default)]
    pub supported_mop_patches: Option<Vec<String>>,
}

pub struct WagoSession {
    cached_inertia_version: Mutex<Option<String>>,
}

impl Default for WagoSession {
    fn default() -> Self {
        Self::new()
    }
}

impl WagoSession {
    pub fn new() -> Self {
        Self {
            cached_inertia_version: Mutex::new(None),
        }
    }

    pub fn get_cached_version(&self) -> Option<String> {
        self.cached_inertia_version.lock().unwrap().clone()
    }

    pub fn set_cached_version(&self, ver: String) {
        *self.cached_inertia_version.lock().unwrap() = Some(ver);
    }

    pub fn clear_cached_version(&self) {
        *self.cached_inertia_version.lock().unwrap() = None;
    }
}

pub fn get_wago_base_url() -> String {
    if let Ok(val) = std::env::var("FURPHY_TEST_WAGO_BASEURL") {
        let trimmed = val.trim();
        if !trimmed.is_empty() {
            return trimmed.trim_end_matches('/').to_string();
        }
    }
    "https://addons.wago.io".to_string()
}

pub fn create_wago_client() -> reqwest::Result<Client> {
    Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
}

fn unescape_html(s: &str) -> String {
    s.replace("&quot;", "\"")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#039;", "'")
        .replace("&apos;", "'")
        .replace("&nbsp;", " ")
}

pub fn extract_data_page_json_from_html(html: &str) -> Option<Value> {
    let marker = "data-page";
    let mut search_start = 0;
    while let Some(pos) = html[search_start..].find(marker) {
        let abs_pos = search_start + pos;
        let rest = &html[abs_pos + marker.len()..];
        let trimmed_rest = rest.trim_start();
        if trimmed_rest.starts_with('=') {
            let after_eq = trimmed_rest[1..].trim_start();
            if let Some(quote_char) = after_eq.chars().next() {
                if quote_char == '"' || quote_char == '\'' {
                    let content_start = &after_eq[quote_char.len_utf8()..];
                    if let Some(end) = content_start.find(quote_char) {
                        let json_str = unescape_html(&content_start[..end]);
                        if let Ok(parsed) = serde_json::from_str::<Value>(&json_str) {
                            return Some(parsed);
                        }
                    }
                }
            }
        }
        search_start = abs_pos + marker.len();
    }
    None
}

pub fn extract_inertia_version_from_html(html: &str) -> Option<String> {
    extract_data_page_json_from_html(html)
        .and_then(|v| v.get("version").and_then(|ver| ver.as_str().map(|s| s.to_string())))
}

pub async fn refresh_inertia_version(
    policy: &NetworkPolicy,
    client: &Client,
    session: &WagoSession,
    slug: &str,
) -> Result<String, String> {
    let base_url = get_wago_base_url();
    let url = if slug.trim().is_empty() {
        format!("{}/?game_version=retail", base_url)
    } else {
        format!("{}/addons/{}/versions?page=1", base_url, slug.trim())
    };
    let host = reqwest::Url::parse(&url)
        .map_err(|e| e.to_string())?
        .host_str()
        .unwrap_or("")
        .to_string();

    let _permit = policy.acquire_permit(&host).await?;

    let resp = client
        .get(&url)
        .header(USER_AGENT, WAGO_USER_AGENT)
        .header(ACCEPT, "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        .send()
        .await
        .map_err(|e| e.to_string())?;

    policy.breaker.register_http_response(&host);
    let html = resp.text().await.map_err(|e| e.to_string())?;

    if let Some(ver) = extract_inertia_version_from_html(&html) {
        session.set_cached_version(ver.clone());
        Ok(ver)
    } else {
        Err(format!("Could not extract Inertia version for Wago addon {}", slug))
    }
}

pub async fn get_wago_releases_page(
    policy: &NetworkPolicy,
    client: &Client,
    session: &WagoSession,
    slug: &str,
    page: u32,
) -> Result<(Vec<WagoRelease>, bool), String> {
    let base_url = get_wago_base_url();
    let url = format!("{}/addons/{}/versions?page={}", base_url, slug, page);
    let host = reqwest::Url::parse(&url)
        .map_err(|e| e.to_string())?
        .host_str()
        .unwrap_or("")
        .to_string();

    let mut attempt = 0;
    while attempt < 2 {
        attempt += 1;
        let mut version = session.get_cached_version();
        if version.is_none() {
            version = Some(refresh_inertia_version(policy, client, session, slug).await?);
        }

        let ver_str = version.unwrap();
        let _permit = policy.acquire_permit(&host).await?;

        let mut headers = HeaderMap::new();
        headers.insert(USER_AGENT, HeaderValue::from_static(WAGO_USER_AGENT));
        headers.insert(ACCEPT, HeaderValue::from_static("text/html, application/xhtml+xml"));
        headers.insert("X-Inertia", HeaderValue::from_static("true"));
        if let Ok(v) = HeaderValue::from_str(&ver_str) {
            headers.insert("X-Inertia-Version", v);
        }
        headers.insert("X-Requested-With", HeaderValue::from_static("XMLHttpRequest"));

        let resp = client.get(&url).headers(headers).send().await;

        match resp {
            Ok(r) => {
                let status = r.status();
                policy.breaker.register_http_response(&host);

                if status.as_u16() == 409 {
                    // Inertia version mismatch, refresh and retry
                    append_app_log("INFO", &format!("Wago Inertia version mismatch (409) for {}, refreshing", slug));
                    session.clear_cached_version();
                    continue;
                }

                if status.as_u16() == 429 || status.as_u16() == 503 {
                    append_app_log("WARN", &format!("Wago HTTP {} - retrying after 5 seconds", status.as_u16()));
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }

                if !status.is_success() {
                    return Err(format!("Wago returned HTTP {}", status));
                }

                let text = r.text().await.map_err(|e| e.to_string())?;
                let val: Value = serde_json::from_str(&text).map_err(|e| format!("Invalid JSON from Wago: {}", e))?;

                let releases_obj = val
                    .get("props")
                    .and_then(|p| p.get("releases"))
                    .ok_or_else(|| format!("Missing releases in Wago response for {}", slug))?;

                let data = releases_obj
                    .get("data")
                    .and_then(|d| d.as_array())
                    .ok_or_else(|| format!("Missing releases.data array for {}", slug))?;

                let has_next = releases_obj.get("next_page_url").and_then(|u| u.as_str()).is_some();
                let releases: Vec<WagoRelease> = serde_json::from_value(Value::Array(data.clone()))
                    .map_err(|e| format!("Failed parsing Wago releases: {}", e))?;

                return Ok((releases, has_next));
            }
            Err(e) => {
                policy.breaker.register_connectivity_failure(&host);
                if attempt < 2 {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
                return Err(format!("Wago connection error: {}", e));
            }
        }
    }

    Err(format!("Wago request failed for {} after retries", slug))
}

pub async fn download_wago_release(
    policy: &NetworkPolicy,
    client: &Client,
    download_url: &str,
    expected_size: Option<u64>,
    dest_path: &Path,
) -> Result<u64, String> {
    let host = reqwest::Url::parse(download_url)
        .map_err(|e| e.to_string())?
        .host_str()
        .unwrap_or("")
        .to_string();

    let _permit = policy.acquire_permit(&host).await?;

    if let Some(parent) = dest_path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let resp = client
        .get(download_url)
        .header(USER_AGENT, WAGO_USER_AGENT)
        .send()
        .await
        .map_err(|e| e.to_string())?;

    policy.breaker.register_http_response(&host);
    let bytes = resp.bytes().await.map_err(|e| e.to_string())?;

    if bytes.is_empty() {
        return Err("Downloaded Wago release is zero-length".to_string());
    }

    if let Some(expected) = expected_size {
        if expected > 0 && (bytes.len() as u64) != expected {
            return Err(format!(
                "Downloaded file size mismatch (expected {}, got {})",
                expected,
                bytes.len()
            ));
        }
    }

    let mut out_file = File::create(dest_path).map_err(|e| e.to_string())?;
    out_file.write_all(&bytes).map_err(|e| e.to_string())?;

    Ok(bytes.len() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_inertia_version_variants() {
        // Standard double quotes with &quot; entities
        let html1 = r#"<div id="app" data-page="{&quot;component&quot;:&quot;Versions&quot;,&quot;version&quot;:&quot;v1.2.3&quot;}"></div>"#;
        assert_eq!(extract_inertia_version_from_html(html1), Some("v1.2.3".to_string()));

        // Single quotes
        let html2 = r#"<div id='app' data-page='{"component":"Versions","version":"v2.0.0"}'></div>"#;
        assert_eq!(extract_inertia_version_from_html(html2), Some("v2.0.0".to_string()));

        // Spaces around equals sign with HTML entities
        let html3 = r#"<div id="app" data-page = "{&quot;version&quot;:&quot;v3.1.4&quot;}"></div>"#;
        assert_eq!(extract_inertia_version_from_html(html3), Some("v3.1.4".to_string()));

        // Missing version
        let html4 = r#"<div id="app" data-page='{"component":"Versions"}'></div>"#;
        assert_eq!(extract_inertia_version_from_html(html4), None);
    }
}
