use chrono::Utc;
use rusqlite::{params, Connection, Result};
use uuid::Uuid;
use crate::net::catalogue::Catalogue;

#[derive(Debug, Clone)]
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

    // 3. Prefix matching: wago:slug, github:owner/repo
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
