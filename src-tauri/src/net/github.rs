use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use std::time::Duration;
use chrono::{DateTime, Utc};
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, USER_AGENT};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use crate::logging::append_app_log;
use crate::net::policy::NetworkPolicy;

pub const GITHUB_USER_AGENT: &str = "FurphyAddonManager-AddonSync";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GithubAsset {
    pub id: i64,
    pub name: String,
    pub size: Option<u64>,
    pub digest: Option<String>,
    pub url: String,
    pub browser_download_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GithubRelease {
    pub id: i64,
    pub tag_name: String,
    pub name: Option<String>,
    pub prerelease: bool,
    pub published_at: Option<String>,
    #[serde(default)]
    pub assets: Vec<GithubAsset>,
    pub zipball_url: Option<String>,
}

pub fn get_github_base_url() -> String {
    if let Ok(val) = std::env::var("FURPHY_TEST_GITHUB_BASEURL") {
        let trimmed = val.trim();
        if !trimmed.is_empty() {
            return trimmed.trim_end_matches('/').to_string();
        }
    }
    "https://api.github.com".to_string()
}

pub fn create_github_client() -> reqwest::Result<Client> {
    Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
}

fn build_github_headers(token: Option<&str>, is_api_github: bool, is_asset_stream: bool) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(USER_AGENT, HeaderValue::from_static(GITHUB_USER_AGENT));

    if is_asset_stream {
        headers.insert(ACCEPT, HeaderValue::from_static("application/octet-stream"));
    } else {
        headers.insert(ACCEPT, HeaderValue::from_static("application/vnd.github+json"));
    }

    // CRITICAL: Token is ONLY sent to api.github.com, never on redirects
    if is_api_github {
        if let Some(t) = token {
            let trimmed = t.trim();
            if !trimmed.is_empty() {
                if let Ok(val) = HeaderValue::from_str(&format!("Bearer {}", trimmed)) {
                    headers.insert(AUTHORIZATION, val);
                }
            }
        }
    }

    headers
}

pub async fn execute_github_request(
    policy: &NetworkPolicy,
    client: &Client,
    url: &str,
    token: Option<&str>,
    is_asset_stream: bool,
) -> Result<reqwest::Response, (String, Option<DateTime<Utc>>)> {
    let host = reqwest::Url::parse(url)
        .map_err(|e| (e.to_string(), None))?
        .host_str()
        .unwrap_or("")
        .to_string();

    let is_api_github = host == "api.github.com" || host == "localhost" || host == "127.0.0.1";

    let mut attempt = 0;
    while attempt < 2 {
        attempt += 1;
        let _permit = policy
            .acquire_permit(&host)
            .await
            .map_err(|e| (e, None))?;

        let headers = build_github_headers(token, is_api_github, is_asset_stream);
        let resp = client.get(url).headers(headers).send().await;

        match resp {
            Ok(r) => {
                let status = r.status();
                policy.breaker.register_http_response(&host);

                if status.is_success() {
                    return Ok(r);
                }

                if status.as_u16() == 404 {
                    // 404 means no access or repo not found - NEVER retry
                    return Err(("HTTP 404: Not Found or no access".to_string(), None));
                }

                if status.as_u16() == 403 || status.as_u16() == 429 {
                    let mut wait_secs = 5;
                    if let Some(retry_after) = r.headers().get("Retry-After") {
                        if let Ok(s) = retry_after.to_str() {
                            if let Ok(parsed) = s.parse::<u64>() {
                                wait_secs = parsed.clamp(5, 10);
                            }
                        }
                    }

                    if attempt < 2 {
                        append_app_log(
                            "WARN",
                            &format!("GitHub rate limit ({}) - waiting {} seconds and retrying", status.as_u16(), wait_secs),
                        );
                        tokio::time::sleep(Duration::from_secs(wait_secs)).await;
                        continue;
                    } else {
                        let limited_until = Utc::now() + chrono::Duration::seconds(wait_secs as i64);
                        return Err((
                            format!("GitHub rate limited ({})", status.as_u16()),
                            Some(limited_until),
                        ));
                    }
                }

                if status.is_server_error() && attempt < 2 {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }

                return Err((format!("GitHub HTTP {}", status), None));
            }
            Err(e) => {
                policy.breaker.register_connectivity_failure(&host);
                if attempt < 2 {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
                return Err((format!("GitHub connection error: {}", e), None));
            }
        }
    }

    Err(("GitHub request failed after retries".to_string(), None))
}

pub async fn get_github_latest_release(
    policy: &NetworkPolicy,
    client: &Client,
    owner: &str,
    repo: &str,
    token: Option<&str>,
) -> Result<GithubRelease, (String, Option<DateTime<Utc>>)> {
    let base_url = get_github_base_url();
    let url = format!("{}/repos/{}/{}/releases/latest", base_url, owner, repo);

    let resp = execute_github_request(policy, client, &url, token, false).await?;
    let text = resp.text().await.map_err(|e| (e.to_string(), None))?;
    let release: GithubRelease =
        serde_json::from_str(&text).map_err(|e| (format!("Invalid release JSON: {}", e), None))?;

    Ok(release)
}

pub async fn get_github_releases(
    policy: &NetworkPolicy,
    client: &Client,
    owner: &str,
    repo: &str,
    token: Option<&str>,
) -> Result<Vec<GithubRelease>, (String, Option<DateTime<Utc>>)> {
    let base_url = get_github_base_url();
    let url = format!("{}/repos/{}/{}/releases?per_page=20", base_url, owner, repo);

    let resp = execute_github_request(policy, client, &url, token, false).await?;
    let text = resp.text().await.map_err(|e| (e.to_string(), None))?;
    let releases: Vec<GithubRelease> =
        serde_json::from_str(&text).map_err(|e| (format!("Invalid releases list JSON: {}", e), None))?;

    Ok(releases)
}

pub async fn download_github_asset(
    policy: &NetworkPolicy,
    client: &Client,
    download_url: &str,
    token: Option<&str>,
    expected_digest: Option<&str>,
    dest_path: &Path,
) -> Result<u64, String> {
    if let Some(parent) = dest_path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let resp = execute_github_request(policy, client, download_url, token, true)
        .await
        .map_err(|(e, _)| e)?;

    let bytes = resp.bytes().await.map_err(|e| e.to_string())?;
    if bytes.is_empty() {
        return Err("Downloaded GitHub release asset is zero-length".to_string());
    }

    if let Some(expected) = expected_digest {
        let trimmed = expected.trim();
        if !trimmed.is_empty() {
            let clean_expected = trimmed.strip_prefix("sha256:").unwrap_or(trimmed).to_ascii_lowercase();
            use sha2::{Digest, Sha256};
            let mut hasher = Sha256::new();
            hasher.update(&bytes);
            let computed = format!("{:x}", hasher.finalize());
            if computed != clean_expected {
                return Err(format!(
                    "GitHub release asset digest mismatch (expected {}, got {})",
                    clean_expected, computed
                ));
            }
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
    fn test_github_token_isolation() {
        let token = "github_pat_11AAAAAAA_test_token_1234567890";

        // When sending to api.github.com: Authorization header is included
        let headers_api = build_github_headers(Some(token), true, false);
        assert!(headers_api.contains_key(AUTHORIZATION));
        assert_eq!(
            headers_api.get(AUTHORIZATION).unwrap().to_str().unwrap(),
            format!("Bearer {}", token)
        );

        // When redirecting or sending to another host: Authorization header is NEVER included
        let headers_redirect = build_github_headers(Some(token), false, false);
        assert!(!headers_redirect.contains_key(AUTHORIZATION));

        // When token is None: Authorization header is not included
        let headers_none = build_github_headers(None, true, false);
        assert!(!headers_none.contains_key(AUTHORIZATION));
    }

    #[test]
    fn test_github_asset_digest_calculation() {
        use sha2::{Digest, Sha256};
        let sample_bytes = b"sample addon zip bytes";
        let mut hasher = Sha256::new();
        hasher.update(sample_bytes);
        let hash = format!("{:x}", hasher.finalize());
        assert_eq!(hash.len(), 64);
    }
}
