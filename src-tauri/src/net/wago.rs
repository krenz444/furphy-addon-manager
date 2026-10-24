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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WagoSearchItem {
    pub id: String,
    pub slug: String,
    pub name: String,
    pub description: Option<String>,
    pub author: String,
    pub version: Option<String>,
    pub downloads: Option<u64>,
    pub updated_at: Option<String>,
    pub avatar_url: Option<String>,
}

pub fn extract_slug_from_card(html: &str) -> Option<String> {
    let pos = html.find("/addons/")?;
    let after = &html[pos + "/addons/".len()..];
    let slug: String = after
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    if slug.is_empty() {
        None
    } else {
        Some(slug)
    }
}

pub fn extract_name_from_card(html: &str) -> Option<String> {
    let h3_start = html.find("<h3")?;
    let tag_end = html[h3_start..].find('>')?;
    let content_start = h3_start + tag_end + 1;
    let h3_end = html[content_start..].find("</h3>")?;
    let raw = &html[content_start..content_start + h3_end];
    let decoded = unescape_html(raw).trim().to_string();
    if decoded.is_empty() {
        None
    } else {
        Some(decoded)
    }
}

pub fn extract_author_from_card(html: &str) -> Option<String> {
    let marker = "<strong>Author:</strong>";
    let pos = html.find(marker)?;
    let after = &html[pos + marker.len()..];
    let end = after.find("</span>").unwrap_or_else(|| after.find('<').unwrap_or(after.len()));
    let raw = &after[..end];
    let decoded = unescape_html(raw).trim().to_string();
    if decoded.is_empty() {
        None
    } else {
        Some(decoded)
    }
}

pub fn extract_downloads_from_card(html: &str) -> Option<u64> {
    let marker = "<strong>Downloads:</strong>";
    let pos = html.find(marker)?;
    let after = &html[pos + marker.len()..];
    let end = after.find("</span>").unwrap_or_else(|| after.find('<').unwrap_or(after.len()));
    let digits: String = after[..end].chars().filter(|c| c.is_ascii_digit()).collect();
    digits.parse::<u64>().ok()
}

pub fn extract_updated_at_from_card(html: &str) -> Option<String> {
    let marker = "<strong>Updated:</strong>";
    let pos = html.find(marker)?;
    let after = &html[pos + marker.len()..];
    let end = after.find("</span>").unwrap_or_else(|| after.find('<').unwrap_or(after.len()));
    let raw = &after[..end];
    let decoded = unescape_html(raw).trim().to_string();
    if decoded.is_empty() {
        None
    } else {
        Some(decoded)
    }
}

pub fn extract_description_from_card(html: &str) -> Option<String> {
    let p_start = html.find("<p")?;
    let tag_end = html[p_start..].find('>')?;
    let content_start = p_start + tag_end + 1;
    let p_end = html[content_start..].find("</p>")?;
    let raw = &html[content_start..content_start + p_end];
    let decoded = unescape_html(raw).trim().to_string();
    if decoded.is_empty() {
        None
    } else {
        Some(decoded)
    }
}

pub fn extract_avatar_url_from_card(html: &str) -> Option<String> {
    let mut search_from = 0;
    while let Some(pos) = html[search_from..].find("src=") {
        let abs_pos = search_from + pos + 4;
        let rest = html[abs_pos..].trim_start();
        let (url_str, next_pos) = if rest.starts_with('"') || rest.starts_with('\'') {
            let quote = rest.chars().next().unwrap();
            let after_quote = &rest[quote.len_utf8()..];
            if let Some(end) = after_quote.find(quote) {
                (&after_quote[..end], abs_pos + quote.len_utf8() + end + 1)
            } else {
                ("", html.len())
            }
        } else {
            let end = rest.find(|c: char| c.is_whitespace() || c == '>').unwrap_or(rest.len());
            let val = rest[..end].trim_end_matches('/');
            (val, abs_pos + end)
        };

        if url_str.contains("cdn.wago.io/thumbnails/") || (url_str.starts_with("http") && !url_str.contains("placeholder")) {
            return Some(url_str.to_string());
        }
        search_from = next_pos.max(abs_pos + 1);
    }
    None
}

pub fn parse_wago_card_html(html: &str) -> Option<WagoSearchItem> {
    let slug = extract_slug_from_card(html)?;
    let name = extract_name_from_card(html).unwrap_or_else(|| slug.clone());
    let author = extract_author_from_card(html).unwrap_or_else(|| "Unknown".to_string());
    let description = extract_description_from_card(html);
    let avatar_url = extract_avatar_url_from_card(html);
    let updated_at = extract_updated_at_from_card(html);
    let downloads = extract_downloads_from_card(html);

    Some(WagoSearchItem {
        id: slug.clone(),
        slug,
        name,
        description,
        author,
        version: None,
        downloads,
        updated_at,
        avatar_url,
    })
}

pub async fn search_wago_addons(
    policy: &NetworkPolicy,
    client: &Client,
    session: &WagoSession,
    flavour: &str,
    query: Option<&str>,
    category: Option<&str>,
    sort: Option<&str>,
    page: u32,
) -> Result<(Vec<WagoSearchItem>, u64), String> {
    let base_url = get_wago_base_url();
    let wago_game_version = match flavour {
        "classic_era" => "classic",
        "classic" => "classic",
        _ => "retail",
    };

    let mut parsed_url = reqwest::Url::parse(&format!("{}/", base_url.trim_end_matches('/')))
        .map_err(|e| e.to_string())?;
    {
        let mut qp = parsed_url.query_pairs_mut();
        qp.append_pair("game_version", wago_game_version);
        qp.append_pair("page", &page.to_string());
        if let Some(q) = query {
            let trimmed = q.trim();
            if !trimmed.is_empty() {
                qp.append_pair("search", trimmed);
            }
        }
        if let Some(cat) = category {
            let trimmed = cat.trim();
            if !trimmed.is_empty() && trimmed.chars().all(|c| c.is_ascii_digit()) {
                qp.append_pair("category", trimmed);
            }
        }
        if sort == Some("name") {
            qp.append_pair("sort", "name");
        }
    }
    let url = parsed_url.to_string();
    let host = parsed_url.host_str().unwrap_or("").to_string();

    let mut attempt = 0;
    while attempt < 2 {
        attempt += 1;
        let _permit = policy.acquire_permit(&host).await?;
        let cached_ver = session.get_cached_version();

        let resp_res = if let Some(ref ver_str) = cached_ver {
            let mut headers = HeaderMap::new();
            headers.insert(USER_AGENT, HeaderValue::from_static(WAGO_USER_AGENT));
            headers.insert(ACCEPT, HeaderValue::from_static("text/html, application/xhtml+xml"));
            headers.insert("X-Inertia", HeaderValue::from_static("true"));
            if let Ok(v) = HeaderValue::from_str(ver_str) {
                headers.insert("X-Inertia-Version", v);
            }
            headers.insert("X-Requested-With", HeaderValue::from_static("XMLHttpRequest"));
            client.get(&url).headers(headers).send().await
        } else {
            client
                .get(&url)
                .header(USER_AGENT, WAGO_USER_AGENT)
                .header(ACCEPT, "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
                .send()
                .await
        };

        match resp_res {
            Ok(r) => {
                let status = r.status();
                policy.breaker.register_http_response(&host);

                if status.as_u16() == 409 {
                    append_app_log("INFO", "Wago search Inertia 409 mismatch, refreshing");
                    session.clear_cached_version();
                    continue;
                }

                if status.as_u16() == 429 || status.as_u16() == 503 {
                    append_app_log("WARN", &format!("Wago HTTP {} during search - retrying", status.as_u16()));
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }

                if !status.is_success() {
                    return Err(format!("Wago search returned HTTP {}", status));
                }

                let text = r.text().await.map_err(|e| e.to_string())?;
                let val: Value = if cached_ver.is_some() {
                    match serde_json::from_str::<Value>(&text) {
                        Ok(v) => v,
                        Err(_) => {
                            if let Some(parsed) = extract_data_page_json_from_html(&text) {
                                if let Some(ver) = parsed.get("version").and_then(|v| v.as_str()) {
                                    session.set_cached_version(ver.to_string());
                                }
                                parsed
                            } else {
                                return Err("Invalid JSON from Wago search".to_string());
                            }
                        }
                    }
                } else {
                    if let Some(parsed) = extract_data_page_json_from_html(&text) {
                        if let Some(ver) = parsed.get("version").and_then(|v| v.as_str()) {
                            session.set_cached_version(ver.to_string());
                        }
                        parsed
                    } else {
                        return Err("Failed to extract data-page from Wago HTML".to_string());
                    }
                };

                let props = val.get("props").unwrap_or(&val);
                let addons_obj = match props.get("addons") {
                    Some(a) => a,
                    None => return Ok((Vec::new(), 0)),
                };

                let total = addons_obj.get("total").and_then(|t| t.as_u64()).unwrap_or(0);
                let mut results = Vec::new();

                if let Some(cards_array) = addons_obj.get("data").and_then(|d| d.as_array()) {
                    for card_val in cards_array {
                        if let Some(card_html) = card_val.as_str() {
                            if let Some(item) = parse_wago_card_html(card_html) {
                                results.push(item);
                            }
                        }
                    }
                }

                if sort == Some("updated") {
                    results.sort_by(|a, b| {
                        let parse_date = |d: &Option<String>| {
                            d.as_ref().and_then(|s| {
                                chrono::NaiveDate::parse_from_str(s.trim(), "%b %d, %Y").ok()
                            })
                        };
                        let da = parse_date(&a.updated_at);
                        let db = parse_date(&b.updated_at);
                        db.cmp(&da)
                    });
                }

                return Ok((results, total));
            }
            Err(e) => {
                policy.breaker.register_connectivity_failure(&host);
                if attempt < 2 {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
                return Err(format!("Wago search connection error: {}", e));
            }
        }
    }

    Err("Wago search failed after retries".to_string())
}

pub async fn fetch_wago_addon_details(
    policy: &NetworkPolicy,
    client: &Client,
    session: &WagoSession,
    slug: &str,
) -> Result<Value, String> {
    let base_url = get_wago_base_url();
    let url = format!("{}/addons/{}", base_url.trim_end_matches('/'), slug.trim());
    let host = reqwest::Url::parse(&url)
        .map_err(|e| e.to_string())?
        .host_str()
        .unwrap_or("")
        .to_string();

    let mut attempt = 0;
    while attempt < 2 {
        attempt += 1;
        let _permit = policy.acquire_permit(&host).await?;
        let cached_ver = session.get_cached_version();

        let resp_res = if let Some(ref ver_str) = cached_ver {
            let mut headers = HeaderMap::new();
            headers.insert(USER_AGENT, HeaderValue::from_static(WAGO_USER_AGENT));
            headers.insert(ACCEPT, HeaderValue::from_static("text/html, application/xhtml+xml"));
            headers.insert("X-Inertia", HeaderValue::from_static("true"));
            if let Ok(v) = HeaderValue::from_str(ver_str) {
                headers.insert("X-Inertia-Version", v);
            }
            headers.insert("X-Requested-With", HeaderValue::from_static("XMLHttpRequest"));
            client.get(&url).headers(headers).send().await
        } else {
            client
                .get(&url)
                .header(USER_AGENT, WAGO_USER_AGENT)
                .header(ACCEPT, "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
                .send()
                .await
        };

        match resp_res {
            Ok(r) => {
                let status = r.status();
                policy.breaker.register_http_response(&host);

                if status.as_u16() == 409 {
                    session.clear_cached_version();
                    continue;
                }
                if status.as_u16() == 429 || status.as_u16() == 503 {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
                if !status.is_success() {
                    return Ok(serde_json::json!({ "id": slug, "name": slug }));
                }

                let text = r.text().await.map_err(|e| e.to_string())?;
                if cached_ver.is_some() {
                    if let Ok(parsed) = serde_json::from_str::<Value>(&text) {
                        let props = parsed.get("props").unwrap_or(&parsed);
                        return Ok(serde_json::json!({
                            "addon": props.get("addon"),
                            "description": props.get("description"),
                            "metadata": props.get("metadata")
                        }));
                    }
                }
                if let Some(parsed) = extract_data_page_json_from_html(&text) {
                    if let Some(ver) = parsed.get("version").and_then(|v| v.as_str()) {
                        session.set_cached_version(ver.to_string());
                    }
                    let props = parsed.get("props").unwrap_or(&parsed);
                    return Ok(serde_json::json!({
                        "addon": props.get("addon"),
                        "description": props.get("description"),
                        "metadata": props.get("metadata")
                    }));
                }
                return Ok(serde_json::json!({ "id": slug, "name": slug }));
            }
            Err(e) => {
                policy.breaker.register_connectivity_failure(&host);
                if attempt < 2 {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
                return Err(format!("Wago addon details error: {}", e));
            }
        }
    }

    Ok(serde_json::json!({ "id": slug, "name": slug }))
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

    #[test]
    fn test_parse_wago_card_html() {
        let card_html = r#"<a href="https://addons.wago.io/addons/details-damage-meter-standalone" class="plain-link transition shadow-md block bg-background-600 rounded-md hover:bg-background-500">
    <div class="flex items-center px-4 py-4 sm:px-4">
        <div class="min-w-0 flex-1 flex items-center">
            <div class="flex-shrink-0">
                <img
                    class="bg-background-700 h-16 w-16 shadow-sm rounded-md border-2 border-background-200"
                    alt=""
                    src=https://cdn.wago.io/thumbnails/vaG3R9SlPb9XIVqDg6k2IfWGpKyBUPjnFKGf9A9V.png
                />
            </div>
            <div class="min-w-0 flex-1 px-4 flex flex-col">
                <h3 class="-mt-px md:text-xl text-lg font-bold truncate leading-snug">Details! Damage Meter</h3>
                <p class="text-md truncate">Famous Combat Analizys addon, compute all sorts of information related to combat, now in a standalone version (without plugins).</p>
                <div class="flex items-center flex-wrap md:flex-nowrap">
                    <span class="text-sm text-muted mr-2"><strong>Updated:</strong> Oct 16, 2026</span>
                    <span class="text-sm text-muted mr-2"><strong>Downloads:</strong> 7707383</span>
                    <span class="text-sm text-muted"><strong>Author:</strong> Terciob</span>
                </div>
            </div>
        </div>
    </div>
</a>"#;

        let item = parse_wago_card_html(card_html).expect("Expected card to parse successfully");
        assert_eq!(item.slug, "details-damage-meter-standalone");
        assert_eq!(item.id, "details-damage-meter-standalone");
        assert_eq!(item.name, "Details! Damage Meter");
        assert_eq!(item.author, "Terciob");
        assert_eq!(item.downloads, Some(7707383));
        assert_eq!(item.updated_at.as_deref(), Some("Oct 16, 2026"));
        assert_eq!(
            item.avatar_url.as_deref(),
            Some("https://cdn.wago.io/thumbnails/vaG3R9SlPb9XIVqDg6k2IfWGpKyBUPjnFKGf9A9V.png")
        );
        assert!(item.description.unwrap().contains("Famous Combat Analizys addon"));
    }

    #[test]
    fn test_parse_wago_card_html_entities_and_placeholders() {
        let card_html = r#"<a href="/addons/my-cool-addon">
            <img src="/images/thumbnail-placeholder.png" />
            <h3>My Cool Addon &amp; More &#039;Stuff&#039;</h3>
            <p>A description with &quot;quotes&quot; &amp; stuff.</p>
            <div>
                <span><strong>Author:</strong> John &amp; Jane</span>
                <span><strong>Updated:</strong> Jan 01, 2026</span>
                <span><strong>Downloads:</strong> 12,345</span>
            </div>
        </a>"#;

        let item = parse_wago_card_html(card_html).expect("Expected card to parse");
        assert_eq!(item.slug, "my-cool-addon");
        assert_eq!(item.name, "My Cool Addon & More 'Stuff'");
        assert_eq!(item.author, "John & Jane");
        assert_eq!(item.description.as_deref(), Some("A description with \"quotes\" & stuff."));
        assert_eq!(item.downloads, Some(12345));
        assert_eq!(item.avatar_url, None); // Placeholder should be ignored
    }
}
