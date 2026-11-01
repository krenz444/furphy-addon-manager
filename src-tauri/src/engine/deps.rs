use std::collections::{HashSet, VecDeque};
use std::path::Path;
use std::sync::Arc;
use rusqlite::{params, Connection, Result};
use crate::engine::add::{create_addon_record, AddonTarget};
use crate::engine::sync::run_sync_for_flavour;
use crate::net::policy::NetworkPolicy;

pub const MAX_RECURSION_DEPTH: usize = 5;

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct InstallDepsResult {
    pub installed_deps: Vec<String>,
    pub unresolved_deps: Vec<String>,
}

pub fn normalize_dep_slug(dep_name: &str) -> String {
    dep_name
        .trim()
        .to_ascii_lowercase()
        .replace(['.', '_', ' '], "-")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
        .collect::<String>()
}

pub fn get_dependency_alias(dep_name: &str) -> Option<&'static str> {
    let norm = normalize_dep_slug(dep_name);
    match norm.as_str() {
        "exwindcore" | "exwind-core" | "exwind" => Some("excore"),
        "excore" => Some("exwindcore"),
        "exwind-tools" => Some("exwindtools"),
        "ace-3-0" | "ace-3" | "ace3-3-0" | "acegui-3-0" | "acedb-3-0" => Some("ace3"),
        "libsharedmedia" | "lsm30" | "libsharedmedia30" => Some("libsharedmedia-3-0"),
        "callbackhandler" => Some("callbackhandler-1-0"),
        "libdatabroker" | "ldb" => Some("libdatabroker-1-1"),
        "libdbicon" => Some("libdbicon-1-0"),
        "herebedragons-2-0" | "herebedragons-1-0" | "hbd" => Some("herebedragons"),
        "weakauras2" | "weakauras" => Some("weakauras-2"),
        "details-damage-meter" => Some("details"),
        _ => None,
    }
}

pub fn get_dependency_alias_target(dep_name: &str) -> Option<AddonTarget> {
    let norm = normalize_dep_slug(dep_name);
    match norm.as_str() {
        "exwindcore" | "exwind-core" | "exwind" | "excore" => Some(AddonTarget::CurseForge(1650514)),
        "exwindtools" | "exwind-tools" => Some(AddonTarget::CurseForge(1450635)),
        _ => None,
    }
}

pub fn check_missing_dependencies(
    conn: &Connection,
    flavour: &str,
    addon_id: &str,
) -> Result<Vec<String>> {
    // 1. Get required deps and ignored deps for this addon
    let (required_deps_json, ignored_deps_json): (Option<String>, Option<String>) = conn
        .query_row(
            "SELECT required_deps, ignored_deps FROM addons WHERE id = ?1 AND flavour = ?2",
            params![addon_id, flavour],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap_or((None, None));

    let required: Vec<String> = required_deps_json
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    if required.is_empty() {
        return Ok(Vec::new());
    }

    let ignored_set: HashSet<String> = ignored_deps_json
        .and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok())
        .unwrap_or_default()
        .into_iter()
        .map(|s| s.to_ascii_lowercase())
        .collect();

    // 2. Find missing by checking presence across installed folders and registered addons
    let mut missing = Vec::new();
    for dep in required {
        let dep_lower = dep.to_ascii_lowercase();
        let dep_norm = normalize_dep_slug(&dep);
        if ignored_set.contains(&dep_lower) || ignored_set.contains(&dep) || ignored_set.contains(&dep_norm) {
            continue;
        }
        if !is_dependency_already_present(conn, flavour, &dep) {
            missing.push(dep);
        }
    }

    Ok(missing)
}

async fn resolve_dependency_target_direct(
    dep_name: &str,
    policy: &Arc<NetworkPolicy>,
    data_dir: &Path,
) -> Option<AddonTarget> {
    let dep_trimmed = dep_name.trim();
    if dep_trimmed.is_empty() {
        return None;
    }
    let norm = normalize_dep_slug(dep_trimmed);

    // 1. Check Catalogue (load_or_refresh_catalogue in crate::net::catalogue)
    if let Ok(cf_client) = crate::net::curseforge::create_cf_client() {
        if let Ok(cat) = crate::net::catalogue::load_or_refresh_catalogue(policy, &cf_client, data_dir).await {
            // Exact slug match
            if let Some(id) = cat.get_id_by_slug(dep_trimmed) {
                return Some(AddonTarget::CurseForge(id));
            }
            // Normalized slug match
            if let Some(id) = cat.get_id_by_slug(&norm) {
                return Some(AddonTarget::CurseForge(id));
            }
        }

        // 2. Fallback to CurseForge search via create_cf_client and query /api/v1/mods/search?gameId=1&searchFilter={dep_name}
        let base_cf_url = crate::net::curseforge::get_cf_base_url();
        let cf_search_url = reqwest::Url::parse_with_params(
            &format!("{}/api/v1/mods/search", base_cf_url),
            &[
                ("gameId", "1"),
                ("pageSize", "20"),
                ("index", "0"),
                ("searchFilter", dep_trimmed),
            ],
        )
        .map(|u| u.to_string())
        .unwrap_or_else(|_| {
            format!("{}/api/v1/mods/search?gameId=1&pageSize=20&index=0", base_cf_url)
        });

        if let Ok(resp) = crate::net::curseforge::execute_cf_request(policy, &cf_client, &cf_search_url).await {
            if resp.status().is_success() {
                if let Ok(json) = resp.json::<serde_json::Value>().await {
                    if let Some(items) = json.get("data").and_then(|v| v.as_array()) {
                        if !items.is_empty() {
                            let matched = items.iter().find(|item| {
                                let slug = item.get("slug").and_then(|s| s.as_str()).unwrap_or("");
                                let name = item.get("name").and_then(|s| s.as_str()).unwrap_or("");
                                slug.eq_ignore_ascii_case(dep_trimmed)
                                    || slug.eq_ignore_ascii_case(&norm)
                                    || name.eq_ignore_ascii_case(dep_trimmed)
                            }).or_else(|| items.first());

                            if let Some(item) = matched {
                                if let Some(id) = item.get("id").and_then(|v| v.as_i64()) {
                                    return Some(AddonTarget::CurseForge(id));
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 3. Fallback: Search Wago via WagoSession + search_wago_addons (addons.wago.io Inertia protocol)
    if let Ok(wago_client) = crate::net::wago::create_wago_client() {
        let wago_session = crate::net::wago::WagoSession::new();
        if let Ok((items, _total)) = crate::net::wago::search_wago_addons(
            policy,
            &wago_client,
            &wago_session,
            "retail",
            Some(dep_trimmed),
            None,
            Some("name"),
            1,
        ).await {
            let matched = items.iter().find(|item| {
                item.slug.eq_ignore_ascii_case(dep_trimmed)
                    || item.slug.eq_ignore_ascii_case(&norm)
                    || item.name.eq_ignore_ascii_case(dep_trimmed)
                    || normalize_dep_slug(&item.slug) == norm
                    || normalize_dep_slug(&item.name) == norm
            });

            if let Some(item) = matched {
                return Some(AddonTarget::Wago(item.slug.clone()));
            }
        }

        // Direct slug verification fallback if search yielded no hits
        if !norm.contains('/') && !norm.contains(' ') {
            if let Ok((releases, _)) = crate::net::wago::get_wago_releases_page(
                policy,
                &wago_client,
                &wago_session,
                &norm,
                1,
            ).await {
                if !releases.is_empty() {
                    return Some(AddonTarget::Wago(norm));
                }
            }
        }
    }

    None
}

pub async fn resolve_dependency_target(
    dep_name: &str,
    policy: &Arc<NetworkPolicy>,
    data_dir: &Path,
) -> Option<AddonTarget> {
    let dep_trimmed = dep_name.trim();
    if dep_trimmed.is_empty() {
        return None;
    }

    if let Some(alias) = get_dependency_alias(dep_trimmed) {
        if let Some(target) = resolve_dependency_target_direct(alias, policy, data_dir).await {
            return Some(target);
        }
    }

    if let Some(target) = resolve_dependency_target_direct(dep_trimmed, policy, data_dir).await {
        return Some(target);
    }

    get_dependency_alias_target(dep_trimmed)
}

fn is_dependency_already_present_direct(conn: &Connection, flavour: &str, dep_name: &str) -> bool {
    let dep_trimmed = dep_name.trim();
    if dep_trimmed.is_empty() {
        return false;
    }
    let dep_lower = dep_trimmed.to_ascii_lowercase();
    let norm = normalize_dep_slug(dep_trimmed);

    // 1. Fast check against addon_folders table
    let fast_folder_match = conn.query_row(
        "SELECT 1 FROM addon_folders WHERE flavour = ?1 AND (
            LOWER(folder) = ?2 OR LOWER(folder) = ?3
        ) LIMIT 1",
        params![flavour, dep_lower, norm],
        |_| Ok(true),
    ).unwrap_or(false);

    if fast_folder_match {
        return true;
    }

    if let Ok(mut stmt) = conn.prepare("SELECT folder FROM addon_folders WHERE flavour = ?1") {
        if let Ok(rows) = stmt.query_map(params![flavour], |r| r.get::<_, String>(0)) {
            for f in rows.flatten() {
                let f_lower = f.to_ascii_lowercase();
                if f_lower == dep_lower || f_lower == norm || normalize_dep_slug(&f) == norm {
                    return true;
                }
            }
        }
    }

    // 2. Check addons table
    conn.query_row(
        "SELECT 1 FROM addons WHERE flavour = ?1 AND (
            LOWER(name) = ?2 OR LOWER(name) = ?3 OR
            LOWER(wago_slug) = ?2 OR LOWER(wago_slug) = ?3 OR
            LOWER(wago_id) = ?2 OR
            LOWER(curse_id) = ?2 OR LOWER(curse_id) = ?3 OR
            LOWER(id) = ?2 OR
            LOWER(repo) = ?2 OR LOWER(repo) LIKE '%/' || ?2
        ) LIMIT 1",
        params![flavour, dep_lower, norm],
        |_| Ok(true),
    )
    .unwrap_or(false)
}

pub fn is_dependency_already_present(conn: &Connection, flavour: &str, dep_name: &str) -> bool {
    let dep_trimmed = dep_name.trim();
    if dep_trimmed.is_empty() {
        return false;
    }

    if is_dependency_already_present_direct(conn, flavour, dep_trimmed) {
        return true;
    }
    if let Some(target) = get_dependency_alias_target(dep_trimmed) {
        if is_target_already_present(conn, flavour, &target) {
            return true;
        }
    }
    if let Some(alias) = get_dependency_alias(dep_trimmed) {
        if is_dependency_already_present_direct(conn, flavour, alias) {
            return true;
        }
    }
    false
}

pub fn is_target_already_present(conn: &Connection, flavour: &str, target: &AddonTarget) -> bool {
    match target {
        AddonTarget::CurseForge(pid) => conn
            .query_row(
                "SELECT 1 FROM addons WHERE flavour = ?1 AND project_id = ?2 LIMIT 1",
                params![flavour, pid],
                |_| Ok(true),
            )
            .unwrap_or(false),
        AddonTarget::Wago(slug) => conn
            .query_row(
                "SELECT 1 FROM addons WHERE flavour = ?1 AND (LOWER(wago_slug) = LOWER(?2) OR wago_id = ?2) LIMIT 1",
                params![flavour, slug],
                |_| Ok(true),
            )
            .unwrap_or(false),
        AddonTarget::GitHub(repo) => conn
            .query_row(
                "SELECT 1 FROM addons WHERE flavour = ?1 AND LOWER(repo) = LOWER(?2) LIMIT 1",
                params![flavour, repo],
                |_| Ok(true),
            )
            .unwrap_or(false),
    }
}

pub async fn install_missing_dependencies_for_addon(
    conn: &mut Connection,
    wow_root: &Path,
    flavour: &str,
    flavour_folder: &str,
    addons_path: &Path,
    data_dir: &Path,
    client_interface: Option<i32>,
    policy: Arc<NetworkPolicy>,
    github_token: Option<String>,
    addon_id: &str,
) -> Result<InstallDepsResult, String> {
    let mut visited = HashSet::new();
    let mut installed = Vec::new();
    let mut unresolved = Vec::new();

    visited.insert(addon_id.to_ascii_lowercase());
    if let Ok(name) = conn.query_row(
        "SELECT name FROM addons WHERE id = ?1",
        params![addon_id],
        |r| r.get::<_, Option<String>>(0),
    ) {
        if let Some(n) = name {
            visited.insert(n.to_ascii_lowercase());
            visited.insert(normalize_dep_slug(&n));
        }
    }

    let mut queue: VecDeque<(String, usize)> = VecDeque::new();
    queue.push_back((addon_id.to_string(), 0));

    while let Some((current_id, depth)) = queue.pop_front() {
        if depth >= MAX_RECURSION_DEPTH {
            continue;
        }

        let missing = check_missing_dependencies(conn, flavour, &current_id)
            .map_err(|e| e.to_string())?;

        for dep in missing {
            let dep_lower = dep.to_ascii_lowercase();
            let dep_norm = normalize_dep_slug(&dep);

            if !visited.insert(dep_lower.clone()) {
                continue;
            }
            visited.insert(dep_norm.clone());

            if is_dependency_already_present(conn, flavour, &dep) {
                continue;
            }

            if let Some(target) = resolve_dependency_target(&dep, &policy, data_dir).await {
                if is_target_already_present(conn, flavour, &target) {
                    continue;
                }

                let new_addon_id = match create_addon_record(conn, flavour, target, Some(&dep)) {
                    Ok(id) => id,
                    Err(e) => {
                        crate::logging::append_sync_log(
                            Some(flavour),
                            "WARN",
                            &format!("Failed to create addon record for dep '{}': {}", dep, e),
                        );
                        if !unresolved.contains(&dep) {
                            unresolved.push(dep.clone());
                        }
                        continue;
                    }
                };

                let sync_res = run_sync_for_flavour(
                    conn,
                    wow_root,
                    flavour,
                    flavour_folder,
                    addons_path,
                    data_dir,
                    client_interface,
                    policy.clone(),
                    github_token.clone(),
                    Some(&[new_addon_id.clone()]),
                    true,
                )
                .await;

                match sync_res {
                    Ok(ref rep) if rep.failed == 0 && rep.results.iter().any(|r| r.status == "Updated" || r.status == "Up-to-date" || r.status == "Installed") => {
                        if !installed.contains(&dep) {
                            installed.push(dep.clone());
                        }
                        queue.push_back((new_addon_id, depth + 1));
                    }
                    Ok(rep) => {
                        let _ = conn.execute("DELETE FROM addon_folders WHERE addon_id = ?1", rusqlite::params![new_addon_id]);
                        let _ = conn.execute("DELETE FROM addons WHERE id = ?1", rusqlite::params![new_addon_id]);
                        crate::logging::append_sync_log(
                            Some(flavour),
                            "WARN",
                            &format!("Failed to sync dependency '{}' (failed count: {}), rolled back addon stub", dep, rep.failed),
                        );
                        if !installed.contains(&dep) && !unresolved.contains(&dep) {
                            unresolved.push(dep.clone());
                        }
                    }
                    Err(e) => {
                        let _ = conn.execute("DELETE FROM addon_folders WHERE addon_id = ?1", rusqlite::params![new_addon_id]);
                        let _ = conn.execute("DELETE FROM addons WHERE id = ?1", rusqlite::params![new_addon_id]);
                        crate::logging::append_sync_log(
                            Some(flavour),
                            "WARN",
                            &format!("Failed to sync dependency '{}': {}, rolled back addon stub", dep, e),
                        );
                        if !installed.contains(&dep) && !unresolved.contains(&dep) {
                            unresolved.push(dep.clone());
                        }
                    }
                }
            } else {
                if !unresolved.contains(&dep) {
                    unresolved.push(dep.clone());
                }
            }
        }
    }

    Ok(InstallDepsResult {
        installed_deps: installed,
        unresolved_deps: unresolved,
    })
}

pub async fn install_all_missing_dependencies_for_flavour(
    conn: &mut Connection,
    wow_root: &Path,
    flavour: &str,
    flavour_folder: &str,
    addons_path: &Path,
    data_dir: &Path,
    client_interface: Option<i32>,
    policy: Arc<NetworkPolicy>,
    github_token: Option<String>,
) -> Result<InstallDepsResult, String> {
    let addon_ids: Vec<String> = {
        let mut stmt = conn
            .prepare("SELECT id FROM addons WHERE flavour = ?1")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![flavour], |r| r.get::<_, String>(0))
            .map_err(|e| e.to_string())?;
        rows.flatten().collect()
    };

    let mut visited = HashSet::new();
    let mut total_installed = Vec::new();
    let mut total_unresolved = Vec::new();

    for aid in &addon_ids {
        visited.insert(aid.to_ascii_lowercase());
        if let Ok(name) = conn.query_row(
            "SELECT name FROM addons WHERE id = ?1",
            params![aid],
            |r| r.get::<_, Option<String>>(0),
        ) {
            if let Some(n) = name {
                visited.insert(n.to_ascii_lowercase());
                visited.insert(normalize_dep_slug(&n));
            }
        }
    }

    let mut queue: VecDeque<(String, usize)> = VecDeque::new();
    for aid in addon_ids {
        queue.push_back((aid, 0));
    }

    while let Some((current_id, depth)) = queue.pop_front() {
        if depth >= MAX_RECURSION_DEPTH {
            continue;
        }

        let missing = match check_missing_dependencies(conn, flavour, &current_id) {
            Ok(m) => m,
            Err(_) => continue,
        };

        for dep in missing {
            let dep_lower = dep.to_ascii_lowercase();
            let dep_norm = normalize_dep_slug(&dep);

            if !visited.insert(dep_lower.clone()) {
                continue;
            }
            visited.insert(dep_norm.clone());

            if is_dependency_already_present(conn, flavour, &dep) {
                continue;
            }

            if let Some(target) = resolve_dependency_target(&dep, &policy, data_dir).await {
                if is_target_already_present(conn, flavour, &target) {
                    continue;
                }

                let new_addon_id = match create_addon_record(conn, flavour, target, Some(&dep)) {
                    Ok(id) => id,
                    Err(e) => {
                        crate::logging::append_sync_log(
                            Some(flavour),
                            "WARN",
                            &format!("Failed to create addon record for dep '{}': {}", dep, e),
                        );
                        if !total_unresolved.contains(&dep) {
                            total_unresolved.push(dep.clone());
                        }
                        continue;
                    }
                };

                let sync_res = run_sync_for_flavour(
                    conn,
                    wow_root,
                    flavour,
                    flavour_folder,
                    addons_path,
                    data_dir,
                    client_interface,
                    policy.clone(),
                    github_token.clone(),
                    Some(&[new_addon_id.clone()]),
                    true,
                )
                .await;

                match sync_res {
                    Ok(ref rep) if rep.failed == 0 && rep.results.iter().any(|r| r.status == "Updated" || r.status == "Up-to-date" || r.status == "Installed") => {
                        if !total_installed.contains(&dep) {
                            total_installed.push(dep.clone());
                        }
                        queue.push_back((new_addon_id, depth + 1));
                    }
                    Ok(rep) => {
                        let _ = conn.execute("DELETE FROM addon_folders WHERE addon_id = ?1", rusqlite::params![new_addon_id]);
                        let _ = conn.execute("DELETE FROM addons WHERE id = ?1", rusqlite::params![new_addon_id]);
                        crate::logging::append_sync_log(
                            Some(flavour),
                            "WARN",
                            &format!("Failed to sync dependency '{}' (failed count: {}), rolled back addon stub", dep, rep.failed),
                        );
                        if !total_installed.contains(&dep) && !total_unresolved.contains(&dep) {
                            total_unresolved.push(dep.clone());
                        }
                    }
                    Err(e) => {
                        let _ = conn.execute("DELETE FROM addon_folders WHERE addon_id = ?1", rusqlite::params![new_addon_id]);
                        let _ = conn.execute("DELETE FROM addons WHERE id = ?1", rusqlite::params![new_addon_id]);
                        crate::logging::append_sync_log(
                            Some(flavour),
                            "WARN",
                            &format!("Failed to sync dependency '{}': {}, rolled back addon stub", dep, e),
                        );
                        if !total_installed.contains(&dep) && !total_unresolved.contains(&dep) {
                            total_unresolved.push(dep.clone());
                        }
                    }
                }
            } else {
                if !total_unresolved.contains(&dep) {
                    total_unresolved.push(dep.clone());
                }
            }
        }
    }

    Ok(InstallDepsResult {
        installed_deps: total_installed,
        unresolved_deps: total_unresolved,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use rusqlite::Connection;
    use crate::db::schema::INITIAL_SCHEMA;

    #[test]
    fn test_normalize_dep_slug() {
        assert_eq!(normalize_dep_slug("LibSharedMedia-3.0"), "libsharedmedia-3-0");
        assert_eq!(normalize_dep_slug("CallbackHandler-1.0"), "callbackhandler-1-0");
        assert_eq!(normalize_dep_slug("AceGUI-3.0_SharedMediaWidgets"), "acegui-3-0-sharedmediawidgets");
        assert_eq!(normalize_dep_slug("Ace3"), "ace3");
    }

    #[test]
    fn test_dependency_alias_mapping() {
        assert_eq!(get_dependency_alias("exwindcore"), Some("excore"));
        assert_eq!(get_dependency_alias("exwind-core"), Some("excore"));
        assert_eq!(get_dependency_alias("exwind"), Some("excore"));
        assert_eq!(get_dependency_alias("ExWindCore"), Some("excore"));
        assert_eq!(get_dependency_alias("ExWind"), Some("excore"));
        assert_eq!(get_dependency_alias("Ace3"), None);
        assert_eq!(get_dependency_alias("details"), None);

        assert_eq!(
            get_dependency_alias_target("ExwindCore"),
            Some(AddonTarget::CurseForge(1650514))
        );
        assert_eq!(
            get_dependency_alias_target("exwind"),
            Some(AddonTarget::CurseForge(1650514))
        );
        assert_eq!(
            get_dependency_alias_target("excore"),
            Some(AddonTarget::CurseForge(1650514))
        );
        assert_eq!(get_dependency_alias_target("Ace3"), None);
    }

    #[tokio::test]
    async fn test_resolve_dependency_target_catalogue_lookup() {
        let temp_dir = tempfile::tempdir().unwrap();
        let cache_dir = temp_dir.path().join("cache");
        fs::create_dir_all(&cache_dir).unwrap();
        let catalogue_file = cache_dir.join("cf_catalogue.json");

        // Write sample catalogue JSON with both standard and normalized slugs
        let sample_catalogue = serde_json::json!({
            "details": 61288,
            "libsharedmedia-3-0": 13346,
            "callbackhandler-1-0": 13347,
            "ace3": 13345,
            "excore": 99999
        });
        fs::write(&catalogue_file, sample_catalogue.to_string()).unwrap();

        let policy = Arc::new(NetworkPolicy::new());

        // Exact match
        let res_details = resolve_dependency_target("details", &policy, temp_dir.path()).await;
        match res_details {
            Some(AddonTarget::CurseForge(id)) => assert_eq!(id, 61288),
            other => panic!("Expected CurseForge(61288), got {:?}", other),
        }

        // Normalized match: LibSharedMedia-3.0 -> libsharedmedia-3-0
        let res_lsm = resolve_dependency_target("LibSharedMedia-3.0", &policy, temp_dir.path()).await;
        match res_lsm {
            Some(AddonTarget::CurseForge(id)) => assert_eq!(id, 13346),
            other => panic!("Expected CurseForge(13346), got {:?}", other),
        }

        // Normalized match: CallbackHandler-1.0 -> callbackhandler-1-0
        let res_cbh = resolve_dependency_target("CallbackHandler-1.0", &policy, temp_dir.path()).await;
        match res_cbh {
            Some(AddonTarget::CurseForge(id)) => assert_eq!(id, 13347),
            other => panic!("Expected CurseForge(13347), got {:?}", other),
        }

        // Alias match: exwindcore -> excore (99999)
        let res_alias = resolve_dependency_target("exwindcore", &policy, temp_dir.path()).await;
        match res_alias {
            Some(AddonTarget::CurseForge(id)) => assert_eq!(id, 99999),
            other => panic!("Expected CurseForge(99999) for exwindcore via alias excore, got {:?}", other),
        }

        // Whitespace/empty
        assert!(resolve_dependency_target("   ", &policy, temp_dir.path()).await.is_none());
    }

    #[test]
    fn test_cycle_detection_visited_set() {
        let mut visited = HashSet::new();
        visited.insert("addon_a".to_string());

        let dep = "addon_b";
        let inserted = visited.insert(dep.to_string());
        assert!(inserted, "First visit of addon_b should succeed");

        // Now addon_b requires addon_a
        let cycle_dep = "addon_a";
        let cycle_inserted = visited.insert(cycle_dep.to_string());
        assert!(!cycle_inserted, "Second visit of addon_a should be rejected by cycle detection");
    }

    #[test]
    fn test_is_dependency_already_present() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name) VALUES ('addon-1', 'retail', 'Ace3')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'LibSharedMedia-3.0', 'addon-1')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'ExCore', 'addon-1')",
            [],
        ).unwrap();

        // 1. Matched by addon name
        assert!(is_dependency_already_present(&conn, "retail", "Ace3"));
        assert!(is_dependency_already_present(&conn, "retail", "ace3"));

        // 2. Matched by addon_folder
        assert!(is_dependency_already_present(&conn, "retail", "LibSharedMedia-3.0"));
        assert!(is_dependency_already_present(&conn, "retail", "libsharedmedia-3.0"));
        assert!(is_dependency_already_present(&conn, "retail", "libsharedmedia-3-0"));

        // 3. Matched via alias (exwindcore / exwind -> excore)
        assert!(is_dependency_already_present(&conn, "retail", "exwindcore"));
        assert!(is_dependency_already_present(&conn, "retail", "exwind"));

        // 4. Not present
        assert!(!is_dependency_already_present(&conn, "retail", "NonExistentLib"));
    }

    #[test]
    fn test_check_missing_dependencies_harmonized() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name, required_deps) VALUES ('addon-parent', 'retail', 'ParentAddon', '[\"Ace3\", \"LibSharedMedia-3.0\", \"MissingLib-1.0\"]')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name) VALUES ('addon-ace', 'retail', 'Ace3')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name) VALUES ('addon-lsm', 'retail', 'LibSharedMedia')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'LibSharedMedia-3.0', 'addon-lsm')",
            [],
        ).unwrap();

        let missing = check_missing_dependencies(&conn, "retail", "addon-parent").unwrap();
        assert_eq!(missing, vec!["MissingLib-1.0".to_string()]);
    }

    #[test]
    fn test_check_missing_dependencies_filters_ignored_deps() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name, required_deps, ignored_deps) VALUES ('addon-parent', 'retail', 'ParentAddon', '[\"Ace3\", \"MissingLib-1.0\", \"exwindcore\"]', '[\"exwindcore\"]')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name) VALUES ('addon-ace', 'retail', 'Ace3')",
            [],
        ).unwrap();

        let missing = check_missing_dependencies(&conn, "retail", "addon-parent").unwrap();
        // exwindcore was ignored, Ace3 is present, so only MissingLib-1.0 remains
        assert_eq!(missing, vec!["MissingLib-1.0".to_string()]);
    }

    #[test]
    fn test_exboss_dependency_resolution_target() {
        let target = get_dependency_alias_target("ExwindCore");
        assert_eq!(target, Some(AddonTarget::CurseForge(1650514)));

        let alias = get_dependency_alias("ExwindCore");
        assert_eq!(alias, Some("excore"));
    }
}
