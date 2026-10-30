use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::time::SystemTime;

use reqwest::Client;
use serde_json::Value;
use crate::net::policy::NetworkPolicy;

pub fn get_catalogue_url() -> String {
    if let Ok(val) = std::env::var("FURPHY_TEST_CF_CATALOGUE_BASEURL") {
        let trimmed = val.trim();
        if !trimmed.is_empty() {
            if trimmed.ends_with(".json") {
                return trimmed.to_string();
            }
            return format!("{}/layday/instawow-data/data/base-catalogue-v8.compact.json", trimmed.trim_end_matches('/'));
        }
    }
    "https://raw.githubusercontent.com/layday/instawow-data/data/base-catalogue-v8.compact.json".to_string()
}

pub struct Catalogue {
    pub slug_to_id: HashMap<String, i64>,
    pub id_to_slug: HashMap<i64, String>,
}

impl Catalogue {
    pub fn new() -> Self {
        let mut cat = Self {
            slug_to_id: HashMap::new(),
            id_to_slug: HashMap::new(),
        };

        // Static built-in fallback mappings for core/critical libraries
        cat.insert(1650514, "excore".to_string());
        cat.insert(1650514, "exwindcore".to_string());
        cat.insert(61288, "details".to_string());
        cat.insert(13345, "ace3".to_string());
        cat.insert(13346, "libsharedmedia-3-0".to_string());
        cat.insert(13347, "callbackhandler-1-0".to_string());

        cat
    }

    pub fn insert(&mut self, id: i64, slug: String) {
        self.slug_to_id.insert(slug.to_ascii_lowercase(), id);
        self.id_to_slug.insert(id, slug);
    }

    pub fn get_id_by_slug(&self, slug: &str) -> Option<i64> {
        self.slug_to_id.get(&slug.to_ascii_lowercase()).copied()
    }

    pub fn get_slug_by_id(&self, id: i64) -> Option<&str> {
        self.id_to_slug.get(&id).map(|s| s.as_str())
    }
}

pub async fn load_or_refresh_catalogue(
    policy: &NetworkPolicy,
    client: &Client,
    data_dir: &Path,
) -> Result<Catalogue, String> {
    let cache_dir = data_dir.join("cache");
    let cache_file = cache_dir.join("cf_catalogue.json");

    let needs_download = if cache_file.exists() {
        if let Ok(meta) = fs::metadata(&cache_file) {
            if let Ok(mod_time) = meta.modified() {
                if let Ok(elapsed) = SystemTime::now().duration_since(mod_time) {
                    elapsed.as_secs() > 86400 // Older than 24 hours
                } else {
                    true
                }
            } else {
                true
            }
        } else {
            true
        }
    } else {
        true
    };

    if needs_download {
        let url = get_catalogue_url();
        let host = reqwest::Url::parse(&url)
            .map_err(|e| e.to_string())?
            .host_str()
            .unwrap_or("")
            .to_string();

        if let Ok(_permit) = policy.acquire_permit(&host).await {
            if let Ok(resp) = client.get(&url).send().await {
                if resp.status().is_success() {
                    if let Ok(bytes) = resp.bytes().await {
                        let _ = fs::create_dir_all(&cache_dir);
                        let _ = fs::write(&cache_file, &bytes);
                    }
                }
            }
        }
    }

    let mut cat = Catalogue::new();
    if cache_file.exists() {
        if let Ok(content) = fs::read_to_string(&cache_file) {
            if let Ok(val) = serde_json::from_str::<Value>(&content) {
                // Format 1: instawow-data compact format { "entries": [ { "id": "1650514", "slug": "excore", "source": "curse" } ] }
                if let Some(entries) = val.get("entries").and_then(|v| v.as_array()) {
                    for entry in entries {
                        let source = entry.get("source").and_then(|v| v.as_str()).unwrap_or("");
                        if source == "curse" || source == "curseforge" || source.is_empty() {
                            let slug = entry.get("slug").and_then(|v| v.as_str());
                            let id = entry.get("id").and_then(|v| {
                                if let Some(n) = v.as_i64() {
                                    Some(n)
                                } else if let Some(s) = v.as_str() {
                                    s.parse::<i64>().ok()
                                } else {
                                    None
                                }
                            });
                            if let (Some(s), Some(i)) = (slug, id) {
                                cat.insert(i, s.to_string());
                            }
                        }
                    }
                }
                // Format 2: direct map { "slug": id } (used in unit tests and compact cache fixtures)
                else if let Some(obj) = val.as_object() {
                    for (slug, id_val) in obj {
                        let id = if let Some(n) = id_val.as_i64() {
                            Some(n)
                        } else if let Some(s) = id_val.as_str() {
                            s.parse::<i64>().ok()
                        } else {
                            None
                        };
                        if let Some(i) = id {
                            cat.insert(i, slug.clone());
                        }
                    }
                }
            }
        }
    }

    Ok(cat)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_catalogue_built_in_fallbacks() {
        let cat = Catalogue::new();
        assert_eq!(cat.get_id_by_slug("excore"), Some(1650514));
        assert_eq!(cat.get_id_by_slug("exwindcore"), Some(1650514));
        assert_eq!(cat.get_id_by_slug("details"), Some(61288));
        assert_eq!(cat.get_id_by_slug("ace3"), Some(13345));
    }

    #[tokio::test]
    async fn test_catalogue_parse_instawow_entries() {
        let temp = tempfile::tempdir().unwrap();
        let cache_dir = temp.path().join("cache");
        fs::create_dir_all(&cache_dir).unwrap();
        let cache_file = cache_dir.join("cf_catalogue.json");

        let json = serde_json::json!({
            "version": 8,
            "entries": [
                {
                    "source": "curse",
                    "slug": "excore",
                    "id": "1650514",
                    "name": "EXCore"
                },
                {
                    "source": "curse",
                    "slug": "details",
                    "id": 61288,
                    "name": "Details! Damage Meter"
                },
                {
                    "source": "wago",
                    "slug": "weakauras",
                    "id": "12345"
                }
            ]
        });
        fs::write(&cache_file, json.to_string()).unwrap();

        let policy = NetworkPolicy::new();
        let client = Client::new();
        let cat = load_or_refresh_catalogue(&policy, &client, temp.path()).await.unwrap();

        assert_eq!(cat.get_id_by_slug("excore"), Some(1650514));
        assert_eq!(cat.get_id_by_slug("details"), Some(61288));
        // Wago entry must not be loaded into CurseForge catalogue
        assert_eq!(cat.get_id_by_slug("weakauras"), None);
    }
}
