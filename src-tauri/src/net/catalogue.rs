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
            return format!("{}/cf_catalogue.json", trimmed.trim_end_matches('/'));
        }
    }
    "https://raw.githubusercontent.com/layday/instawow-data/master/curseforge.json".to_string()
}

pub struct Catalogue {
    pub slug_to_id: HashMap<String, i64>,
    pub id_to_slug: HashMap<i64, String>,
}

impl Catalogue {
    pub fn new() -> Self {
        Self {
            slug_to_id: HashMap::new(),
            id_to_slug: HashMap::new(),
        }
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
                if let Some(obj) = val.as_object() {
                    for (slug, id_val) in obj {
                        if let Some(id) = id_val.as_i64() {
                            cat.insert(id, slug.clone());
                        }
                    }
                }
            }
        }
    }

    Ok(cat)
}
