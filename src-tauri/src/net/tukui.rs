use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use std::time::Duration;
use reqwest::header::ACCEPT;
use reqwest::Client;
use serde::{Deserialize, Deserializer, Serialize};
use crate::net::policy::NetworkPolicy;

pub const MAX_ZIP_BYTES: u64 = 200 * 1024 * 1024;

fn deserialize_id<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let v = serde_json::Value::deserialize(deserializer)?;
    match v {
        serde_json::Value::String(s) => Ok(s),
        serde_json::Value::Number(n) => Ok(n.to_string()),
        serde_json::Value::Null => Ok(String::new()),
        _ => Err(serde::de::Error::custom("expected string or number for id")),
    }
}

fn deserialize_vec_lenient<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: Deserializer<'de>,
{
    let opt = Option::<Vec<String>>::deserialize(deserializer)?;
    Ok(opt.unwrap_or_default())
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct TukuiAddon {
    #[serde(default, deserialize_with = "deserialize_id")]
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
    #[serde(default, deserialize_with = "deserialize_vec_lenient")]
    pub patch: Vec<String>,
    #[serde(default)]
    pub last_update: Option<String>,
    #[serde(default)]
    pub web_url: Option<String>,
    #[serde(default)]
    pub small_desc: Option<String>,
    #[serde(default, deserialize_with = "deserialize_vec_lenient")]
    pub directories: Vec<String>,
}

pub fn get_tukui_base_url() -> String {
    if let Ok(val) = std::env::var("FURPHY_TEST_TUKUI_BASEURL") {
        let trimmed = val.trim();
        if !trimmed.is_empty() {
            return trimmed.trim_end_matches('/').to_string();
        }
    }
    "https://api.tukui.org".to_string()
}

pub fn create_tukui_client() -> reqwest::Result<Client> {
    let builder = Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(300));
    crate::net::ip_mode::apply(builder).build()
}

pub async fn get_tukui_addons(policy: &NetworkPolicy, client: &Client) -> Result<Vec<TukuiAddon>, String> {
    let base_url = get_tukui_base_url();
    let url = format!("{}/v1/addons", base_url.trim_end_matches('/'));

    let parsed = reqwest::Url::parse(&url).map_err(|e| format!("Invalid Tukui API URL: {}", e))?;
    let host = parsed.host_str().unwrap_or("api.tukui.org");

    let _permit = policy.acquire_permit(host).await.map_err(|e| format!("Network policy permit rejected: {}", e))?;

    let resp = match client
        .get(&url)
        .header(ACCEPT, "application/json")
        .timeout(Duration::from_secs(20))
        .send()
        .await
    {
        Ok(r) => {
            policy.breaker.register_http_response(host);
            r
        }
        Err(e) => {
            policy.breaker.register_connectivity_failure(host);
            return Err(format!("Failed to connect to Tukui API: {}", e));
        }
    };

    if !resp.status().is_success() {
        return Err(format!("Tukui API returned HTTP {}", resp.status()));
    }

    let text = resp.text().await.map_err(|e| format!("Failed to read Tukui API response text: {}", e))?;
    let addons: Vec<TukuiAddon> = serde_json::from_str(&text).map_err(|e| format!("Failed to parse Tukui API response: {}", e))?;

    Ok(addons)
}

pub async fn download_tukui_zip(
    policy: &NetworkPolicy,
    client: &Client,
    url: &str,
    dest: &Path,
) -> Result<u64, String> {
    let full_url = if url.starts_with('/') {
        format!("{}{}", get_tukui_base_url().trim_end_matches('/'), url)
    } else {
        url.to_string()
    };

    let parsed = reqwest::Url::parse(&full_url).map_err(|e| format!("Invalid download URL: {}", e))?;
    let host = parsed.host_str().unwrap_or("api.tukui.org");

    let _permit = policy.acquire_permit(host).await.map_err(|e| format!("Network policy permit rejected: {}", e))?;

    let resp = match client.get(&full_url).send().await {
        Ok(r) => {
            policy.breaker.register_http_response(host);
            r
        }
        Err(e) => {
            policy.breaker.register_connectivity_failure(host);
            return Err(format!("Download request failed: {}", e));
        }
    };

    if !resp.status().is_success() {
        return Err(format!("Download failed with HTTP {}", resp.status()));
    }

    if let Some(cl) = resp.content_length() {
        if cl > MAX_ZIP_BYTES {
            return Err(format!("Download size {} exceeds maximum allowed size of {} bytes", cl, MAX_ZIP_BYTES));
        }
    }

    if let Some(parent) = dest.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let mut file = File::create(dest).map_err(|e| format!("Failed to create destination file: {}", e))?;
    let mut total_bytes: u64 = 0;
    let mut checked_magic = false;
    let mut magic_buf = Vec::with_capacity(4);

    let mut resp = resp;
    while let Some(chunk) = resp.chunk().await.map_err(|e| format!("Error downloading chunk: {}", e))? {
        total_bytes += chunk.len() as u64;
        if total_bytes > MAX_ZIP_BYTES {
            drop(file);
            let _ = fs::remove_file(dest);
            return Err(format!("Download exceeded maximum allowed size of {} bytes", MAX_ZIP_BYTES));
        }

        if !checked_magic {
            magic_buf.extend_from_slice(&chunk);
            if magic_buf.len() >= 4 {
                if &magic_buf[0..4] != b"PK\x03\x04" {
                    drop(file);
                    let _ = fs::remove_file(dest);
                    return Err("Downloaded file is not a valid zip archive (invalid magic header)".to_string());
                }
                checked_magic = true;
            }
        }

        file.write_all(&chunk).map_err(|e| format!("Failed to write chunk to disk: {}", e))?;
    }

    if !checked_magic || total_bytes < 4 {
        drop(file);
        let _ = fs::remove_file(dest);
        return Err("Downloaded file is too small to be a valid zip archive".to_string());
    }

    file.sync_all().map_err(|e| format!("Failed to flush downloaded file: {}", e))?;
    Ok(total_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deserialize_real_tukui_json() {
        let json = r#"[
            {
                "id": "-2",
                "slug": "elvui",
                "author": "Elv, Simpy",
                "name": "ElvUI",
                "url": "https://api.tukui.org/v1/download/elvui/12.1.5",
                "version": "12.1.5",
                "changelog_url": "https://www.tukui.org/changelog.php?id=-2",
                "ticket_url": "https://git.tukui.org/elvui/elvui/-/issues",
                "git_url": "https://git.tukui.org/elvui/elvui",
                "patch": ["12.1.5", "1.60.1", "5.5.4", "1.15.9", "2.5.6"],
                "last_update": "2026-11-09",
                "web_url": "https://www.tukui.org/addons.php?id=-2",
                "donate_url": "https://www.patreon.com/tukui",
                "small_desc": "A complete UI overhaul",
                "desc": "Long description here",
                "screenshot_url": "https://www.tukui.org/images/elvui.png",
                "gallery_url": [],
                "logo_url": "https://www.tukui.org/images/logo.png",
                "logo_square_url": "https://www.tukui.org/images/square.png",
                "directories": ["ElvUI", "ElvUI_Libraries", "ElvUI_Options"]
            },
            {
                "id": -1,
                "slug": "tukui",
                "author": "Tukz",
                "name": "Tukui",
                "url": "https://api.tukui.org/v1/download/tukui/11.1.7",
                "version": "11.1.7",
                "patch": ["11.1.7", "5.5.0", "1.15.7"],
                "last_update": "2026-10-15",
                "directories": ["Tukui"]
            }
        ]"#;

        let addons: Vec<TukuiAddon> = serde_json::from_str(json).unwrap();
        assert_eq!(addons.len(), 2);

        let elvui = &addons[0];
        assert_eq!(elvui.id, "-2");
        assert_eq!(elvui.slug, "elvui");
        assert_eq!(elvui.name, "ElvUI");
        assert_eq!(elvui.author, "Elv, Simpy");
        assert_eq!(elvui.version, "12.1.5");
        assert_eq!(elvui.last_update.as_deref(), Some("2026-11-09"));
        assert_eq!(elvui.patch, vec!["12.1.5", "1.60.1", "5.5.4", "1.15.9", "2.5.6"]);
        assert_eq!(elvui.directories, vec!["ElvUI", "ElvUI_Libraries", "ElvUI_Options"]);
        assert_eq!(elvui.small_desc.as_deref(), Some("A complete UI overhaul"));

        let tukui = &addons[1];
        assert_eq!(tukui.id, "-1");
        assert_eq!(tukui.slug, "tukui");
        assert_eq!(tukui.name, "Tukui");
        assert_eq!(tukui.version, "11.1.7");
        assert_eq!(tukui.directories, vec!["Tukui"]);
        assert_eq!(tukui.small_desc, None);
    }

    #[test]
    fn test_deserialize_tolerant_missing_keys_and_nulls() {
        let json = r#"[
            {
                "slug": "minimal",
                "name": "Minimal",
                "author": "Unknown",
                "version": "1.0",
                "patch": null,
                "directories": null
            }
        ]"#;
        let addons: Vec<TukuiAddon> = serde_json::from_str(json).unwrap();
        assert_eq!(addons.len(), 1);
        let a = &addons[0];
        assert_eq!(a.id, "");
        assert_eq!(a.slug, "minimal");
        assert_eq!(a.patch, Vec::<String>::new());
        assert_eq!(a.directories, Vec::<String>::new());
        assert_eq!(a.last_update, None);
    }

    #[test]
    fn test_get_tukui_base_url_default_and_override() {
        std::env::remove_var("FURPHY_TEST_TUKUI_BASEURL");
        assert_eq!(get_tukui_base_url(), "https://api.tukui.org");

        std::env::set_var("FURPHY_TEST_TUKUI_BASEURL", "http://127.0.0.1:9999/");
        assert_eq!(get_tukui_base_url(), "http://127.0.0.1:9999");
        std::env::remove_var("FURPHY_TEST_TUKUI_BASEURL");
    }

    #[test]
    fn test_create_tukui_client() {
        let client = create_tukui_client();
        assert!(client.is_ok());
    }

    #[test]
    fn test_zip_magic_rejection() {
        let temp_dir = tempfile::tempdir().unwrap();
        let dest = temp_dir.path().join("test.zip");

        fs::write(&dest, b"HTML not a zip").unwrap();
        assert!(dest.exists());
    }
}
