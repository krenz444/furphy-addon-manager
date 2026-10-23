use std::sync::Arc;
use serde_json::Value;
use tauri::State;
use crate::net::curseforge::execute_cf_request;
use crate::net::policy::NetworkPolicy;

#[tauri::command]
pub async fn wago_search(
    policy: State<'_, Arc<NetworkPolicy>>,
    query: String,
    sort: Option<String>,
    _category: Option<String>,
    page: Option<u32>,
) -> Result<Value, String> {
    let client = crate::net::wago::create_wago_client().map_err(|e| e.to_string())?;
    let base = crate::net::wago::get_wago_base_url();
    let page_num = page.unwrap_or(1);
    let sort_order = sort.unwrap_or_else(|| "popular".into());
    let url = format!("{}/api/search?q={}&sort={}&page={}", base, query, sort_order, page_num);
    let host = reqwest::Url::parse(&url)
        .map_err(|e| e.to_string())?
        .host_str()
        .unwrap_or("")
        .to_string();

    let _permit = policy.acquire_permit(&host).await?;
    let res = client.get(&url).send().await;
    policy.breaker.register_http_response(&host);
    match res {
        Ok(resp) => {
            if resp.status().is_success() {
                resp.json::<Value>().await.map_err(|e| e.to_string())
            } else {
                Ok(serde_json::json!({ "results": [], "total": 0 }))
            }
        }
        Err(_) => Ok(serde_json::json!({ "results": [], "total": 0 })),
    }
}

#[tauri::command]
pub fn wago_categories() -> Result<Value, String> {
    Ok(serde_json::json!([
        { "id": "action-bars", "label": "Action Bars" },
        { "id": "auction-economy", "label": "Auction & Economy" },
        { "id": "bags-inventory", "label": "Bags & Inventory" },
        { "id": "boss-encounters", "label": "Boss Encounters" },
        { "id": "chat-communication", "label": "Chat & Communication" },
        { "id": "class", "label": "Class" },
        { "id": "combat", "label": "Combat" },
        { "id": "map-minimap", "label": "Map & Minimap" },
        { "id": "professions", "label": "Professions" },
        { "id": "quests-leveling", "label": "Quests & Leveling" },
        { "id": "unit-frames", "label": "Unit Frames" }
    ]))
}

#[tauri::command]
pub async fn wago_addon(
    policy: State<'_, Arc<NetworkPolicy>>,
    slug_or_id: String,
) -> Result<Value, String> {
    let client = crate::net::wago::create_wago_client().map_err(|e| e.to_string())?;
    let base = crate::net::wago::get_wago_base_url();
    let url = format!("{}/api/addons/{}", base, slug_or_id);
    let host = reqwest::Url::parse(&url)
        .map_err(|e| e.to_string())?
        .host_str()
        .unwrap_or("")
        .to_string();

    let _permit = policy.acquire_permit(&host).await?;
    let res = client.get(&url).send().await;
    policy.breaker.register_http_response(&host);
    if let Ok(resp) = res {
        if resp.status().is_success() {
            return resp.json::<Value>().await.map_err(|e| e.to_string());
        }
    }
    Ok(serde_json::json!({ "id": slug_or_id, "name": slug_or_id }))
}

#[tauri::command]
pub async fn cf_browse(
    policy: State<'_, Arc<NetworkPolicy>>,
    _category: Option<String>,
    _sort: Option<String>,
    page: Option<u32>,
    search: Option<String>,
) -> Result<Value, String> {
    let client = crate::net::curseforge::create_cf_client().map_err(|e| e.to_string())?;
    let base = crate::net::curseforge::get_cf_base_url();
    let page_num = page.unwrap_or(1);
    let q = search.unwrap_or_default();
    let url = format!(
        "{}/api/v1/mods/search?gameId=1&pageSize=20&index={}&searchFilter={}",
        base,
        (page_num - 1) * 20,
        q
    );
    let resp = execute_cf_request(&policy, &client, &url).await?;
    if resp.status().is_success() {
        return resp.json::<Value>().await.map_err(|e| e.to_string());
    }
    Ok(serde_json::json!({ "data": [], "pagination": { "totalCount": 0 } }))
}

#[tauri::command]
pub async fn cf_enrich(
    policy: State<'_, Arc<NetworkPolicy>>,
    addon_id: i64,
) -> Result<Value, String> {
    let client = crate::net::curseforge::create_cf_client().map_err(|e| e.to_string())?;
    let base = crate::net::curseforge::get_cf_base_url();
    let url = format!("{}/api/v1/mods/{}", base, addon_id);
    let resp = execute_cf_request(&policy, &client, &url).await?;
    if resp.status().is_success() {
        return resp.json::<Value>().await.map_err(|e| e.to_string());
    }
    Ok(serde_json::json!({ "id": addon_id }))
}
