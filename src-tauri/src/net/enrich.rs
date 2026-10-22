use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use crate::net::policy::NetworkPolicy;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct EnrichmentData {
    pub website_url: Option<String>,
    pub summary: Option<String>,
    pub wago_id: Option<String>,
}

pub async fn get_enrichment(
    policy: &NetworkPolicy,
    client: &Client,
    project_id: i64,
) -> Result<EnrichmentData, String> {
    let url = format!("https://addon-radar.com/api/v1/addons/{}", project_id);
    let host = "addon-radar.com";

    let mut data = EnrichmentData::default();
    if policy.check_host_allowed(host).is_ok() {
        if let Ok(_permit) = policy.acquire_permit(host).await {
            if let Ok(resp) = client.get(&url).send().await {
                if resp.status().is_success() {
                    if let Ok(json) = resp.json::<Value>().await {
                        data.summary = json.get("summary").and_then(|v| v.as_str()).map(|s| s.to_string());
                        data.website_url = json.get("websiteUrl").and_then(|v| v.as_str()).map(|s| s.to_string());
                    }
                }
            }
        }
    }

    Ok(data)
}
