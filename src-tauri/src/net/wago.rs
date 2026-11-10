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
use crate::net::wago_query::WagoQueryParams;

pub const WAGO_USER_AGENT: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WagoRelease {
    pub id: String,
    pub name: Option<String>,
    #[serde(alias = "label")]
    pub version: Option<String>,
    pub stability: Option<String>,
    pub size: Option<u64>,
    #[serde(alias = "download_link", alias = "download_url")]
    pub url: Option<String>,
    #[serde(default)]
    pub supported_retail_patches: Option<Vec<String>>,
    #[serde(default)]
    pub supported_classic_patches: Option<Vec<String>>,
    #[serde(default)]
    pub supported_forever_patches: Option<Vec<String>>,
    #[serde(default)]
    pub supported_bc_patches: Option<Vec<String>>,
    #[serde(default)]
    pub supported_wotlk_patches: Option<Vec<String>>,
    #[serde(default)]
    pub supported_cata_patches: Option<Vec<String>>,
    #[serde(default)]
    pub supported_mop_patches: Option<Vec<String>>,
    /// When the release was published (Wago `created_at`, e.g. 2026-11-08T20:38:49.000000Z).
    #[serde(default)]
    pub created_at: Option<String>,
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
    crate::net::ip_mode::apply(Client::builder().timeout(Duration::from_secs(30))).build()
}

fn unescape_html(s: &str) -> String {
    s.replace("&quot;", "\"")
        .replace("&#34;", "\"")
        .replace("&#x22;", "\"")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&#x27;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
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
                    let mut cursor = 0;
                    while let Some(rel_end) = content_start[cursor..].find(quote_char) {
                        let end = cursor + rel_end;
                        let raw_slice = &content_start[..end];
                        let json_str = unescape_html(raw_slice);
                        if let Ok(parsed) = serde_json::from_str::<Value>(&json_str) {
                            return Some(parsed);
                        }
                        let double_unescaped = unescape_html(&json_str);
                        if let Ok(parsed) = serde_json::from_str::<Value>(&double_unescaped) {
                            return Some(parsed);
                        }
                        cursor = end + quote_char.len_utf8();
                        if raw_slice.contains('>') {
                            break;
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
                let val: Value = match serde_json::from_str::<Value>(&text) {
                    Ok(v) => v,
                    Err(_) => {
                        if let Some(parsed) = extract_data_page_json_from_html(&text) {
                            if let Some(ver) = parsed.get("version").and_then(|v| v.as_str()) {
                                session.set_cached_version(ver.to_string());
                            }
                            parsed
                        } else {
                            return Err(format!("Invalid JSON or data-page from Wago for {}", slug));
                        }
                    }
                };

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
    let status = resp.status();
    if !status.is_success() {
        return Err(format!("Wago download failed with HTTP {}", status));
    }

    let bytes = resp.bytes().await.map_err(|e| e.to_string())?;

    if bytes.len() < 22 || !bytes.starts_with(b"PK") {
        return Err("Downloaded Wago release is not a valid ZIP archive".to_string());
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
    #[serde(default)]
    pub wago_url: Option<String>,
    #[serde(default)]
    pub game_version: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WagoSearchPageResult {
    pub results: Vec<WagoSearchItem>,
    pub total: u64,
    pub page: u32,
    pub has_more: bool,
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

pub fn is_classic_flavour(flavour: &str) -> bool {
    let f = flavour.trim().to_lowercase();
    matches!(
        f.as_str(),
        "classic" | "classic_era" | "forever" | "cata" | "wotlk" | "wrath" | "bc" | "tbc" | "mop" | "mists"
            | "classic_beta" | "classic_ptr" | "classic_era_ptr" | "anniversary"
    )
}

pub fn is_retail_only_wago_addon(slug: &str) -> bool {
    let s = slug.trim().to_lowercase();
    s.starts_with("raiderio")
        || s.starts_with("raider-io")
        || s.contains("raiderio")
        || s.contains("raider-io")
        || s.contains("mythic-plus")
        || s.contains("mythic-dungeon-tools")
        || s == "mdt"
        || s.starts_with("mdt-")
        || s == "astral-keys"
        || s == "keystone-guru"
        || s.contains("great-vault")
}

pub fn parse_wago_card_html(html: &str, game_version: Option<&str>) -> Option<WagoSearchItem> {
    let slug = extract_slug_from_card(html)?;
    let name = extract_name_from_card(html).unwrap_or_else(|| slug.clone());
    let author = extract_author_from_card(html).unwrap_or_else(|| "Unknown".to_string());
    let description = extract_description_from_card(html);
    let avatar_url = extract_avatar_url_from_card(html);
    let updated_at = extract_updated_at_from_card(html);
    let downloads = extract_downloads_from_card(html);
    let wago_url = Some(format!("https://addons.wago.io/addons/{}", slug));
    let game_version = game_version.map(|gv| gv.to_string());

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
        wago_url,
        game_version,
    })
}

/// Wago echoes the filters it actually applied in `props.search`, `props.game_version`,
/// `props.category` and `props.sort`. When it rejects a request (for example an
/// unsupported `sort`) it redirects to `/` and every echo comes back null while the
/// body is still a valid, unfiltered listing, so the caller would present Wago's
/// default list as if it answered the query. Verified live 2026-11-03.
///
/// A key that is absent from `props` (test doubles, a future layout change) is not
/// judged: only a present-but-different echo counts as a dropped filter.
pub fn verify_wago_filter_echo(props: &Value, params: &WagoQueryParams) -> Result<(), String> {
    fn echoed(props: &Value, key: &str) -> Option<Option<String>> {
        props.get(key).map(|v| match v {
            Value::Null => None,
            Value::String(s) => Some(s.trim().to_string()),
            Value::Number(n) => Some(n.to_string()),
            Value::Object(map) => {
                if let Some(id) = map.get("id") {
                    match id {
                        Value::Number(n) => Some(n.to_string()),
                        Value::String(s) => Some(s.trim().to_string()),
                        _ => Some(id.to_string()),
                    }
                } else if let Some(slug) = map.get("slug") {
                    slug.as_str().map(|s| s.trim().to_string())
                } else {
                    Some(Value::Object(map.clone()).to_string())
                }
            }
            other => Some(other.to_string()),
        })
    }
    fn differs(echo: Option<Option<String>>, expected: &str) -> bool {
        match echo {
            None => false,
            Some(None) => true,
            Some(Some(got)) => {
                let norm_got = got.trim().to_lowercase();
                let norm_exp = expected.trim().to_lowercase();
                norm_got != norm_exp && norm_got.replace('+', " ") != norm_exp
            }
        }
    }

    let mut dropped: Vec<&str> = Vec::new();
    if differs(echoed(props, "game_version"), &params.game_version) {
        dropped.push("game_version");
    }
    if let Some(ref s) = params.search {
        if differs(echoed(props, "search"), s) {
            dropped.push("search");
        }
    }
    if let Some(ref c) = params.category {
        if differs(echoed(props, "category"), c) {
            dropped.push("category");
        }
    }
    if let Some(s) = params.upstream_sort() {
        if differs(echoed(props, "sort"), s) {
            dropped.push("sort");
        }
    }

    if dropped.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "Wago did not apply the requested filters ({}). Its default list would be misleading, so no results are shown.",
            dropped.join(", ")
        ))
    }
}

/// Newest first; items without a parseable "Mon D, YYYY" date go last (stable sort).
pub fn sort_by_updated_desc(items: &mut [WagoSearchItem]) {
    let parse = |d: &Option<String>| {
        d.as_ref()
            .and_then(|s| chrono::NaiveDate::parse_from_str(s.trim(), "%b %d, %Y").ok())
    };
    items.sort_by(|a, b| parse(&b.updated_at).cmp(&parse(&a.updated_at)));
}

/// Uses Wago's own pagination metadata: `last_page`, else a non-empty `next_page_url`
/// (null on the final page). Without either (test doubles) it compares the reported total
/// with what has been returned so far. It does not depend on how many cards survived
/// client-side filtering, so an emptied page cannot end paging early.
pub fn compute_has_more(addons_obj: &Value, current_page: u64, total: u64, raw_returned: usize) -> bool {
    if let Some(next) = addons_obj.get("next_page_url") {
        if next.is_null() {
            return false;
        }
        if let Some(s) = next.as_str() {
            return !s.trim().is_empty();
        }
    }

    let last_page = addons_obj.get("last_page").and_then(|v| match v {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.trim().parse::<u64>().ok(),
        _ => None,
    });
    if let Some(last) = last_page {
        return current_page < last;
    }

    let per_page = addons_obj
        .get("per_page")
        .and_then(|v| match v {
            Value::Number(n) => n.as_u64(),
            Value::String(s) => s.trim().parse::<u64>().ok(),
            _ => None,
        })
        .unwrap_or(15);

    let seen = current_page.saturating_sub(1).saturating_mul(per_page) + raw_returned as u64;
    raw_returned > 0 && total > seen
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
) -> Result<(Vec<WagoSearchItem>, u64, bool), String> {
    let base_url = get_wago_base_url();
    let query_params = crate::net::wago_query::WagoQueryParams::new(
        Some(flavour),
        Some(page),
        query,
        category,
        sort,
    );

    let mut parsed_url = reqwest::Url::parse(&format!("{}/", base_url.trim_end_matches('/')))
        .map_err(|e| e.to_string())?;
    query_params.apply_to_url(&mut parsed_url);
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
                let val: Value = match serde_json::from_str::<Value>(&text) {
                    Ok(v) => v,
                    Err(_) => {
                        if let Some(parsed) = extract_data_page_json_from_html(&text) {
                            if let Some(ver) = parsed.get("version").and_then(|v| v.as_str()) {
                                session.set_cached_version(ver.to_string());
                            }
                            parsed
                        } else {
                            return Err("Failed to parse JSON or extract data-page from Wago search response".to_string());
                        }
                    }
                };

                let props = val.get("props").unwrap_or(&val);
                if let Err(msg) = verify_wago_filter_echo(props, &query_params) {
                    append_app_log("WARN", &format!("{} [{}]", msg, url));
                    return Err(msg);
                }
                let addons_obj = match props.get("addons") {
                    Some(a) => a,
                    None => return Ok((Vec::new(), 0, false)),
                };

                let total = addons_obj
                    .get("total")
                    .and_then(|t| match t {
                        Value::Number(n) => n.as_u64(),
                        Value::String(s) => s.trim().parse::<u64>().ok(),
                        _ => None,
                    })
                    .unwrap_or(0);
                let mut results = Vec::new();
                let mut raw_cards_count = 0;

                if let Some(cards_array) = addons_obj.get("data").and_then(|d| d.as_array()) {
                    raw_cards_count = cards_array.len();
                    for card_val in cards_array {
                        if let Some(card_html) = card_val.as_str() {
                            if let Some(item) = parse_wago_card_html(card_html, Some(flavour)) {
                                if is_classic_flavour(flavour) && is_retail_only_wago_addon(&item.slug) {
                                    continue;
                                }
                                results.push(item);
                            }
                        }
                    }
                }

                // "updated" is never sent upstream (see WagoQueryParams::upstream_sort), so the
                // page Wago returned is in its popularity order; order it here.
                if query_params.sort.as_deref() == Some("updated") {
                    sort_by_updated_desc(&mut results);
                }

                let current_page = addons_obj
                    .get("current_page")
                    .and_then(|v| match v {
                        Value::Number(n) => n.as_u64(),
                        Value::String(s) => s.trim().parse::<u64>().ok(),
                        _ => None,
                    })
                    .unwrap_or(page as u64);
                let has_more = compute_has_more(addons_obj, current_page, total, raw_cards_count);

                return Ok((results, total, has_more));
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

    fn echo_params(flavour: &str, q: Option<&str>, cat: Option<&str>, sort: Option<&str>) -> WagoQueryParams {
        WagoQueryParams::new(Some(flavour), Some(1), q, cat, sort)
    }

    #[test]
    fn test_filter_echo_accepts_applied_filters() {
        let props = serde_json::json!({ "game_version": "classic", "search": "details", "category": 16, "sort": "name" });
        let p = echo_params("forever", Some("details"), Some("16"), Some("name"));
        assert!(verify_wago_filter_echo(&props, &p).is_ok());

        // Supports category echoed as an object with id
        let props_obj = serde_json::json!({ "game_version": "retail", "category": { "id": 18 } });
        let p_obj = echo_params("retail", None, Some("18"), None);
        assert!(verify_wago_filter_echo(&props_obj, &p_obj).is_ok());

        // Supports space URL-encoded as '+' in search echo
        let props_plus = serde_json::json!({ "game_version": "retail", "search": "Boss+Mods" });
        let p_plus = echo_params("retail", Some("Boss Mods"), None, None);
        assert!(verify_wago_filter_echo(&props_plus, &p_plus).is_ok());
    }

    #[test]
    fn test_filter_echo_detects_wago_dropping_every_filter() {
        // Shape observed live when sort=popular was sent: every echo is null.
        let props = serde_json::json!({ "game_version": null, "search": null, "category": null, "sort": null });
        let p = echo_params("retail", Some("plater"), Some("16"), Some("name"));
        let err = verify_wago_filter_echo(&props, &p).unwrap_err();
        for key in ["game_version", "search", "category", "sort"] {
            assert!(err.contains(key), "{err}");
        }
    }

    #[test]
    fn test_filter_echo_ignores_absent_keys_and_unrequested_filters() {
        let p = echo_params("retail", None, None, None);
        assert!(verify_wago_filter_echo(&serde_json::json!({}), &p).is_ok());
        assert!(verify_wago_filter_echo(&serde_json::json!({ "game_version": "retail", "search": null }), &p).is_ok());
    }

    #[test]
    fn test_filter_echo_is_case_insensitive_and_catches_wrong_game_version() {
        let props = serde_json::json!({ "game_version": "retail", "search": "DETAILS" });
        assert!(verify_wago_filter_echo(&props, &echo_params("retail", Some("details"), None, None)).is_ok());
        let err = verify_wago_filter_echo(&props, &echo_params("forever", Some("details"), None, None)).unwrap_err();
        assert!(err.contains("game_version"), "{err}");
    }

    fn item(slug: &str, updated: Option<&str>) -> WagoSearchItem {
        WagoSearchItem {
            id: slug.into(),
            slug: slug.into(),
            name: slug.into(),
            description: None,
            author: "author".into(),
            version: None,
            downloads: None,
            updated_at: updated.map(String::from),
            avatar_url: None,
            wago_url: None,
            game_version: None,
        }
    }

    #[test]
    fn test_sort_by_updated_desc_newest_first_undated_last() {
        let mut v = vec![
            item("old", Some("Oct 16, 2026")),
            item("none", None),
            item("new", Some("Nov 3, 2026")),
            item("mid", Some("Oct 30, 2026")),
        ];
        sort_by_updated_desc(&mut v);
        let order: Vec<&str> = v.iter().map(|i| i.slug.as_str()).collect();
        assert_eq!(order, vec!["new", "mid", "old", "none"]);
    }

    #[test]
    fn test_is_classic_flavour() {
        for flv in [
            "classic", "classic_era", "forever", "cata", "wotlk", "wrath", "bc", "tbc", "mop", "mists",
            "classic_beta", "classic_ptr", "classic_era_ptr", "anniversary",
        ] {
            assert!(is_classic_flavour(flv), "{flv} should be recognized as classic");
            assert!(is_classic_flavour(&flv.to_uppercase()), "uppercase {flv} should match");
        }
        for flv in ["retail", "ptr", "xptr", "beta"] {
            assert!(!is_classic_flavour(flv), "{flv} must not be classic");
        }
    }

    #[test]
    fn test_is_retail_only_wago_addon() {
        for slug in [
            "raiderio",
            "raider-io",
            "raiderio-mythic-plus-raid-progress-and-recruitment",
            "raider-io-addon",
            "mythic-plus",
            "mythic-dungeon-tools",
            "mdt",
            "mdt-dungeon-guide",
            "astral-keys",
            "keystone-guru",
            "great-vault-tracker",
        ] {
            assert!(is_retail_only_wago_addon(slug), "{slug} must be detected as retail-only");
        }
        for slug in [
            "details-damage-meter-standalone",
            "plater-nameplates",
            "dbm-deadly-boss-mods",
            "bagnon",
            "questie",
        ] {
            assert!(!is_retail_only_wago_addon(slug), "{slug} is compatible with classic");
        }
    }

    #[test]
    fn test_compute_has_more_prefers_wago_pagination_meta() {
        let meta = serde_json::json!({ "current_page": 2, "last_page": 3 });
        assert!(compute_has_more(&meta, 2, 1000, 14));
        assert!(!compute_has_more(&meta, 3, 1000, 14));
        // 30 results are 2 pages: the final page must not claim there is more.
        let last = serde_json::json!({ "current_page": 2, "last_page": 2 });
        assert!(!compute_has_more(&last, 2, 30, 15));
        // next_page_url is authoritative: non-empty string means more, null means none.
        let next_only = serde_json::json!({ "next_page_url": "https://addons.wago.io?page=3" });
        assert!(compute_has_more(&next_only, 2, 0, 0));
        let final_page = serde_json::json!({ "next_page_url": null });
        assert!(!compute_has_more(&final_page, 3, 1000, 14));
        // When next_page_url is explicitly null, it overrides current_page < last_page.
        let final_page_with_last = serde_json::json!({ "current_page": 2, "last_page": 3, "next_page_url": null });
        assert!(!compute_has_more(&final_page_with_last, 2, 1000, 14));
        // Without metadata (test doubles) fall back to total versus what was returned.
        let none = serde_json::json!({});
        assert!(compute_has_more(&none, 1, 40, 14));
        assert!(!compute_has_more(&none, 1, 14, 14));
        assert!(!compute_has_more(&none, 1, 0, 0));
        // Emptied page by client-side filters does not terminate paging when raw cards were returned:
        assert!(compute_has_more(&none, 1, 40, 14));
        // A short final page: 20 results at 15 per page, page 2 returned only 5.
        let paged = serde_json::json!({ "per_page": 15 });
        assert!(compute_has_more(&paged, 1, 20, 15));
        assert!(!compute_has_more(&paged, 2, 20, 5));
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

        let item = parse_wago_card_html(card_html, Some("retail")).expect("Expected card to parse successfully");
        assert_eq!(item.slug, "details-damage-meter-standalone");
        assert_eq!(item.id, "details-damage-meter-standalone");
        assert_eq!(item.name, "Details! Damage Meter");
        assert_eq!(item.author, "Terciob");
        assert_eq!(item.downloads, Some(7707383));
        assert_eq!(item.updated_at.as_deref(), Some("Oct 16, 2026"));
        assert_eq!(item.wago_url.as_deref(), Some("https://addons.wago.io/addons/details-damage-meter-standalone"));
        assert_eq!(item.game_version.as_deref(), Some("retail"));
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

        let item = parse_wago_card_html(card_html, None).expect("Expected card to parse");
        assert_eq!(item.slug, "my-cool-addon");
        assert_eq!(item.name, "My Cool Addon & More 'Stuff'");
        assert_eq!(item.author, "John & Jane");
        assert_eq!(item.description.as_deref(), Some("A description with \"quotes\" & stuff."));
        assert_eq!(item.downloads, Some(12345));
        assert_eq!(item.avatar_url, None); // Placeholder should be ignored
    }

    #[test]
    fn test_wago_release_deserialization_with_aliases() {
        let json_data = r#"{
            "id": "vd7JX1NQ",
            "addon_id": 5082,
            "size": 4928372,
            "label": "EXBoss-v26.10.28.2259",
            "stability": "stable",
            "download_link": "https://addons.wago.io/download/vd7JX1NQ?signature=xyz",
            "supported_retail_patches": ["12.1.5"]
        }"#;

        let release: WagoRelease = serde_json::from_str(json_data).expect("Failed to deserialize WagoRelease");
        assert_eq!(release.id, "vd7JX1NQ");
        assert_eq!(release.version.as_deref(), Some("EXBoss-v26.10.28.2259"));
        assert_eq!(release.url.as_deref(), Some("https://addons.wago.io/download/vd7JX1NQ?signature=xyz"));
        assert_eq!(release.size, Some(4928372));
        assert_eq!(release.stability.as_deref(), Some("stable"));
        assert_eq!(release.supported_retail_patches.as_deref(), Some(&vec!["12.1.5".to_string()][..]));
    }
}
