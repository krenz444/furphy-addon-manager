use std::sync::Arc;
use serde_json::Value;
use tauri::State;
use crate::net::curseforge::execute_cf_request;
use crate::net::policy::NetworkPolicy;

#[tauri::command]
pub async fn wago_search(
    policy: State<'_, Arc<NetworkPolicy>>,
    session: State<'_, Arc<crate::net::wago::WagoSession>>,
    query: Option<String>,
    sort: Option<String>,
    category: Option<String>,
    page: Option<u32>,
    flavour: Option<String>,
) -> Result<Value, String> {
    let client = crate::net::wago::create_wago_client().map_err(|e| e.to_string())?;
    let page_num = page.unwrap_or(1);
    let flv = flavour.unwrap_or_else(|| "retail".into());

    let (items, total) = crate::net::wago::search_wago_addons(
        &policy,
        &client,
        &session,
        &flv,
        query.as_deref(),
        category.as_deref(),
        sort.as_deref(),
        page_num,
    )
    .await?;

    Ok(serde_json::json!({
        "results": items,
        "total": total
    }))
}

#[tauri::command]
pub fn wago_categories() -> Result<Value, String> {
    Ok(serde_json::json!([
        { "id": "18", "label": "Action Bars" },
        { "id": "26", "label": "Achievements" },
        { "id": "6", "label": "Artwork" },
        { "id": "2", "label": "Auction & Economy" },
        { "id": "3", "label": "Audio & Video" },
        { "id": "9", "label": "Bags & Inventory" },
        { "id": "14", "label": "Boss Encounters" },
        { "id": "5", "label": "Buffs & Debuffs" },
        { "id": "1", "label": "Chat & Communication" },
        { "id": "20", "label": "Class" },
        { "id": "19", "label": "Combat" },
        { "id": "27", "label": "Companions" },
        { "id": "7", "label": "Data Export" },
        { "id": "21", "label": "Development Tools" },
        { "id": "28", "label": "Garrison" },
        { "id": "8", "label": "Guild" },
        { "id": "10", "label": "Libraries" },
        { "id": "12", "label": "Mail" },
        { "id": "11", "label": "Map & Minimap" },
        { "id": "22", "label": "Minigames" },
        { "id": "17", "label": "Miscellaneous" },
        { "id": "25", "label": "Plugins" },
        { "id": "15", "label": "Professions" },
        { "id": "4", "label": "PvP" },
        { "id": "13", "label": "Quests & Leveling" },
        { "id": "24", "label": "Roleplay" },
        { "id": "23", "label": "Tooltip" },
        { "id": "29", "label": "Transmog" },
        { "id": "16", "label": "Unit Frames" }
    ]))
}

#[tauri::command]
pub async fn wago_addon(
    policy: State<'_, Arc<NetworkPolicy>>,
    session: State<'_, Arc<crate::net::wago::WagoSession>>,
    slug_or_id: String,
) -> Result<Value, String> {
    let client = crate::net::wago::create_wago_client().map_err(|e| e.to_string())?;
    crate::net::wago::fetch_wago_addon_details(&policy, &client, &session, &slug_or_id).await
}

#[tauri::command]
pub async fn cf_browse(
    policy: State<'_, Arc<NetworkPolicy>>,
    category: Option<String>,
    sort: Option<String>,
    page: Option<u32>,
    search: Option<String>,
) -> Result<Value, String> {
    let client = crate::net::curseforge::create_cf_client().map_err(|e| e.to_string())?;
    let base = crate::net::curseforge::get_cf_base_url();
    let page_num = page.unwrap_or(1).max(1);
    let page_index = (page_num - 1) * 20;

    let mut url = reqwest::Url::parse(&format!("{}/api/v1/mods/search", base.trim_end_matches('/')))
        .map_err(|e| format!("Malformed CurseForge base URL: {}", e))?;

    {
        let mut pairs = url.query_pairs_mut();
        pairs.append_pair("gameId", "1");
        pairs.append_pair("pageSize", "20");
        pairs.append_pair("index", &page_index.to_string());

        if let Some(ref q) = search {
            let trimmed = q.trim();
            if !trimmed.is_empty() {
                pairs.append_pair("searchFilter", trimmed);
            }
        }
        if let Some(ref cat) = category {
            let trimmed = cat.trim();
            if !trimmed.is_empty() && trimmed != "0" {
                pairs.append_pair("categoryId", trimmed);
            }
        }
        if let Some(ref s) = sort {
            let trimmed = s.trim();
            if !trimmed.is_empty() {
                pairs.append_pair("sortField", trimmed);
            }
        }
    }

    let resp = execute_cf_request(&policy, &client, url.as_str()).await?;
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
