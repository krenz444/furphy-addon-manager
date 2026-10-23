use chrono::Utc;
use rusqlite::{params, Connection, Result};
use uuid::Uuid;
use crate::net::catalogue::Catalogue;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AddonTarget {
    CurseForge(i64),
    Wago(String),      // slug or id
    GitHub(String),    // "owner/repo"
}

pub fn parse_addon_target(target: &str, catalogue: Option<&Catalogue>) -> Option<AddonTarget> {
    let t = target.trim();
    if t.is_empty() {
        return None;
    }

    // 1. Direct numeric ID -> CurseForge
    if let Ok(id) = t.parse::<i64>() {
        return Some(AddonTarget::CurseForge(id));
    }

    // 2. URL parsing
    if t.contains("curseforge.com") {
        // e.g. https://www.curseforge.com/wow/addons/deadly-boss-mods
        if let Some(pos) = t.find("/addons/") {
            let rest = &t[pos + "/addons/".len()..];
            let slug = rest.split(['/', '?', '#']).next().unwrap_or(rest);
            if let Some(cat) = catalogue {
                if let Some(id) = cat.get_id_by_slug(slug) {
                    return Some(AddonTarget::CurseForge(id));
                }
            }
        }
    }

    if t.contains("wago.io") {
        // e.g. https://addons.wago.io/addons/weakauras-2
        if let Some(pos) = t.find("/addons/") {
            let rest = &t[pos + "/addons/".len()..];
            let slug = rest.split(['/', '?', '#']).next().unwrap_or(rest);
            return Some(AddonTarget::Wago(slug.to_string()));
        }
    }

    if t.contains("github.com") {
        // e.g. https://github.com/owner/repo
        if let Some(pos) = t.find("github.com/") {
            let rest = &t[pos + "github.com/".len()..];
            let parts: Vec<&str> = rest.split('/').filter(|s| !s.is_empty()).collect();
            if parts.len() >= 2 {
                let repo = format!("{}/{}", parts[0], parts[1].trim_end_matches(".git"));
                return Some(AddonTarget::GitHub(repo));
            }
        }
    }

    // 3. Prefix matching: wago:slug, github:owner/repo, curse:id, curseforge:id
    if let Some(stripped) = t.strip_prefix("curse:") {
        if let Ok(id) = stripped.trim().parse::<i64>() {
            return Some(AddonTarget::CurseForge(id));
        }
    }

    if let Some(stripped) = t.strip_prefix("curseforge:") {
        if let Ok(id) = stripped.trim().parse::<i64>() {
            return Some(AddonTarget::CurseForge(id));
        }
    }

    if let Some(stripped) = t.strip_prefix("wago:") {
        return Some(AddonTarget::Wago(stripped.trim().to_string()));
    }

    if let Some(stripped) = t.strip_prefix("github:") {
        return Some(AddonTarget::GitHub(stripped.trim().to_string()));
    }

    // 4. "owner/repo" shape
    if t.contains('/') && !t.contains(' ') {
        let parts: Vec<&str> = t.split('/').collect();
        if parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty() {
            return Some(AddonTarget::GitHub(t.to_string()));
        }
    }

    // 5. Slug lookup in catalogue
    if let Some(cat) = catalogue {
        if let Some(id) = cat.get_id_by_slug(t) {
            return Some(AddonTarget::CurseForge(id));
        }
    }

    // Fallback: assume Wago slug if not numeric
    Some(AddonTarget::Wago(t.to_string()))
}

pub fn create_addon_record(
    conn: &Connection,
    flavour: &str,
    target: AddonTarget,
    name: Option<&str>,
) -> Result<String, String> {
    let id = Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    match target {
        AddonTarget::CurseForge(pid) => {
            let default_name = name.unwrap_or("CurseForge Addon");
            conn.execute(
                "INSERT INTO addons (id, flavour, source, project_id, name, installed_at, release_type, ignore_updates) \
                 VALUES (?1, ?2, 'curseforge', ?3, ?4, ?5, 1, 0)",
                params![id, flavour, pid, default_name, now],
            )
            .map_err(|e| e.to_string())?;
        }
        AddonTarget::Wago(slug) => {
            let default_name = name.unwrap_or(&slug);
            conn.execute(
                "INSERT INTO addons (id, flavour, source, wago_slug, name, installed_at, release_type, ignore_updates) \
                 VALUES (?1, ?2, 'wago', ?3, ?4, ?5, 1, 0)",
                params![id, flavour, slug, default_name, now],
            )
            .map_err(|e| e.to_string())?;
        }
        AddonTarget::GitHub(repo) => {
            let default_name = name.unwrap_or(&repo);
            conn.execute(
                "INSERT INTO addons (id, flavour, source, repo, name, installed_at, release_type, ignore_updates) \
                 VALUES (?1, ?2, 'github', ?3, ?4, ?5, 1, 0)",
                params![id, flavour, repo, default_name, now],
            )
            .map_err(|e| e.to_string())?;
        }
    }

    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_addon_target_variants() {
        // Direct numeric ID
        match parse_addon_target("2382", None) {
            Some(AddonTarget::CurseForge(id)) => assert_eq!(id, 2382),
            other => panic!("Expected CurseForge(2382), got {:?}", other),
        }

        // Curse prefix
        match parse_addon_target("curse:2382", None) {
            Some(AddonTarget::CurseForge(id)) => assert_eq!(id, 2382),
            other => panic!("Expected CurseForge(2382), got {:?}", other),
        }

        // Wago prefix
        match parse_addon_target("wago:weakauras-2", None) {
            Some(AddonTarget::Wago(slug)) => assert_eq!(slug, "weakauras-2"),
            other => panic!("Expected Wago(weakauras-2), got {:?}", other),
        }

        // GitHub prefix
        match parse_addon_target("github:Tukui-Org/ElvUI", None) {
            Some(AddonTarget::GitHub(repo)) => assert_eq!(repo, "Tukui-Org/ElvUI"),
            other => panic!("Expected GitHub(Tukui-Org/ElvUI), got {:?}", other),
        }

        // GitHub URL
        match parse_addon_target("https://github.com/Tukui-Org/ElvUI.git", None) {
            Some(AddonTarget::GitHub(repo)) => assert_eq!(repo, "Tukui-Org/ElvUI"),
            other => panic!("Expected GitHub(Tukui-Org/ElvUI), got {:?}", other),
        }

        // Wago URL
        match parse_addon_target("https://addons.wago.io/addons/talentloadoutex", None) {
            Some(AddonTarget::Wago(slug)) => assert_eq!(slug, "talentloadoutex"),
            other => panic!("Expected Wago(talentloadoutex), got {:?}", other),
        }

        // Empty string
        assert!(parse_addon_target("   ", None).is_none());
    }
}
