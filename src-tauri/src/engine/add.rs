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

/// Centralized identifier resolver for CurseForge IDs, slugs, and built-in aliases.
pub fn resolve_cf_identifier(ident: &str, catalogue: Option<&Catalogue>) -> Option<i64> {
    let clean = ident.trim();
    if clean.is_empty() {
        return None;
    }

    // Direct numeric ID
    if let Ok(id) = clean.parse::<i64>() {
        return Some(id);
    }

    // Offline / Instawow catalogue lookup
    if let Some(cat) = catalogue {
        if let Some(id) = cat.get_id_by_slug(clean) {
            return Some(id);
        }
    }

    // Built-in static aliases
    match clean.to_ascii_lowercase().as_str() {
        "excore" | "exwindcore" => Some(1650514),
        "exwindtools" => Some(1450635),
        "details" => Some(61288),
        "ace3" => Some(13345),
        "libsharedmedia-3-0" => Some(13346),
        "callbackhandler-1-0" => Some(13347),
        "libstub" => Some(14410),
        "libdatabroker-1-1" => Some(14197),
        "libdbicon-1-0" => Some(14352),
        "herebedragons" => Some(299236),
        "weakauras-2" | "weakauras" => Some(65375),
        _ => None,
    }
}

/// Validates and cleans owner/repo pairs per GITHUB-SOURCE-SPEC.md 3.1.
pub fn clean_github_repo(owner: &str, repo_raw: &str) -> Option<String> {
    let owner = owner.trim();
    let mut repo = repo_raw.trim();

    // Strip trailing query parameters or fragments
    if let Some(pos) = repo.find(['?', '#']) {
        repo = &repo[..pos];
    }
    // Safely strip .git suffix without char-set trimming bug
    if let Some(stripped) = repo.strip_suffix(".git") {
        repo = stripped;
    }
    repo = repo.trim_end_matches('/');

    // Validate owner: 1-39 chars, alphanumeric or single hyphens, no leading hyphen
    if owner.is_empty() || owner.len() > 39 || owner.starts_with('-') {
        return None;
    }
    if !owner.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return None;
    }

    // Validate repo: 1-100 chars, alphanumeric, ., _, -; cannot be purely dots (., ..)
    if repo.is_empty() || repo.len() > 100 || repo.chars().all(|c| c == '.') {
        return None;
    }
    if !repo.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-') {
        return None;
    }

    Some(format!("{}/{}", owner, repo))
}

pub fn parse_addon_target(target: &str, catalogue: Option<&Catalogue>) -> Option<AddonTarget> {
    let t = target.trim();
    if t.is_empty() {
        return None;
    }

    let lower = t.to_ascii_lowercase();

    // 1. Direct numeric ID -> CurseForge
    if let Ok(id) = t.parse::<i64>() {
        return Some(AddonTarget::CurseForge(id));
    }

    // 2. CurseForge deep links: curseforge://install?addonId=61288 or curseforge://addons/<slug_or_id>
    if lower.starts_with("curseforge://") {
        if let Ok(url) = reqwest::Url::parse(t) {
            for (k, v) in url.query_pairs() {
                if k.eq_ignore_ascii_case("addonid") || k.eq_ignore_ascii_case("projectid") {
                    if let Ok(id) = v.parse::<i64>() {
                        return Some(AddonTarget::CurseForge(id));
                    }
                }
            }
            let path_seg = url.path().trim_matches('/');
            let seg = path_seg.split(['/', '?', '#']).next().unwrap_or(path_seg);
            if let Some(id) = resolve_cf_identifier(seg, catalogue) {
                return Some(AddonTarget::CurseForge(id));
            }
        }
    }

    // 3. HTTP URL parsing: CurseForge (www.curseforge.com, wow.curseforge.com)
    if lower.contains("curseforge.com") {
        if let Some(pos) = lower.find("/addons/") {
            let rest = &t[pos + "/addons/".len()..];
            let seg = rest.split(['/', '?', '#']).next().unwrap_or(rest);
            if let Some(id) = resolve_cf_identifier(seg, catalogue) {
                return Some(AddonTarget::CurseForge(id));
            }
            return None;
        }

        if let Some(pos) = lower.find("/projects/") {
            let rest = &t[pos + "/projects/".len()..];
            let seg = rest.split(['/', '?', '#']).next().unwrap_or(rest);
            if let Some(id) = resolve_cf_identifier(seg, catalogue) {
                return Some(AddonTarget::CurseForge(id));
            }
            return None;
        }

        return None;
    }

    // 4. HTTP URL parsing: Wago
    if lower.contains("wago.io") {
        if let Some(pos) = lower.find("/addons/") {
            let rest = &t[pos + "/addons/".len()..];
            let slug = rest.split(['/', '?', '#', ' ']).next().unwrap_or(rest);
            if !slug.is_empty() {
                return Some(AddonTarget::Wago(slug.to_string()));
            }
        }
        return None;
    }

    // 5. HTTP URL parsing: GitHub (https://github.com/owner/repo...)
    if let Some(pos) = lower.find("github.com/") {
        let rest = &t[pos + "github.com/".len()..];
        let parts: Vec<&str> = rest.split('/').filter(|s| !s.is_empty()).collect();
        if parts.len() >= 2 {
            if let Some(cleaned) = clean_github_repo(parts[0], parts[1]) {
                return Some(AddonTarget::GitHub(cleaned));
            }
        }
        return None;
    }

    // 6. Explicit prefix matching: curse:, curseforge:, wago:, github:
    if let Some(stripped) = lower.strip_prefix("curse:").or_else(|| lower.strip_prefix("curseforge:")) {
        let clean = stripped.trim();
        if let Some(id) = resolve_cf_identifier(clean, catalogue) {
            return Some(AddonTarget::CurseForge(id));
        }
        return None;
    }

    if let Some(stripped) = t.strip_prefix("wago:") {
        let trimmed = stripped.trim();
        if !trimmed.is_empty() {
            let clean_slug = if let Some(pos) = trimmed.find("/addons/") {
                let rest = &trimmed[pos + "/addons/".len()..];
                rest.split(['/', '?', '#', ' ']).next().unwrap_or(rest)
            } else {
                trimmed.split(['/', '?', '#', ' ']).next().unwrap_or(trimmed)
            };
            if !clean_slug.is_empty() {
                return Some(AddonTarget::Wago(clean_slug.to_string()));
            }
        }
        return None;
    }

    if let Some(stripped) = t.strip_prefix("github:") {
        let trimmed = stripped.trim();
        let parts: Vec<&str> = trimmed.split('/').filter(|s| !s.is_empty()).collect();
        if parts.len() >= 2 {
            if let Some(cleaned) = clean_github_repo(parts[0], parts[1]) {
                return Some(AddonTarget::GitHub(cleaned));
            }
        }
        return None;
    }

    // 7. "owner/repo" shape -> GitHub
    if t.contains('/') && !t.contains(' ') && !t.starts_with("http") {
        let parts: Vec<&str> = t.split('/').collect();
        if parts.len() == 2 {
            if let Some(cleaned) = clean_github_repo(parts[0], parts[1]) {
                return Some(AddonTarget::GitHub(cleaned));
            }
        }
    }

    // 8. Plain slug resolution against CurseForge catalogue / aliases
    if let Some(id) = resolve_cf_identifier(t, catalogue) {
        return Some(AddonTarget::CurseForge(id));
    }

    // 9. Fallback: assume Wago slug ONLY if it is a valid, clean ASCII slug identifier
    if !t.is_empty()
        && t.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        && !t.chars().all(|c| c.is_ascii_digit())
    {
        return Some(AddonTarget::Wago(t.to_string()));
    }

    None
}

pub fn create_addon_record(
    conn: &Connection,
    flavour: &str,
    target: AddonTarget,
    name: Option<&str>,
) -> Result<String, String> {
    let now = Utc::now().to_rfc3339();

    match target {
        AddonTarget::CurseForge(pid) => {
            if let Ok(existing_id) = conn.query_row(
                "SELECT id FROM addons WHERE flavour = ?1 AND project_id = ?2",
                params![flavour, pid],
                |r| r.get::<_, String>(0),
            ) {
                return Ok(existing_id);
            }

            let id = Uuid::new_v4().to_string();
            let default_name = name.unwrap_or(if pid == 1650514 {
                "EXCore"
            } else if pid == 1450635 {
                "ExwindTools"
            } else {
                "CurseForge Addon"
            });
            conn.execute(
                "INSERT INTO addons (id, flavour, source, project_id, name, installed_at, release_type, ignore_updates) \
                 VALUES (?1, ?2, 'curseforge', ?3, ?4, ?5, 1, 0)",
                params![id, flavour, pid, default_name, now],
            )
            .map_err(|e| e.to_string())?;
            Ok(id)
        }
        AddonTarget::Wago(slug) => {
            if let Ok(existing_id) = conn.query_row(
                "SELECT id FROM addons WHERE flavour = ?1 AND wago_slug = ?2 COLLATE NOCASE",
                params![flavour, slug],
                |r| r.get::<_, String>(0),
            ) {
                return Ok(existing_id);
            }

            let id = Uuid::new_v4().to_string();
            let default_name = name.unwrap_or(&slug);
            conn.execute(
                "INSERT INTO addons (id, flavour, source, wago_slug, name, installed_at, release_type, ignore_updates) \
                 VALUES (?1, ?2, 'wago', ?3, ?4, ?5, 1, 0)",
                params![id, flavour, slug, default_name, now],
            )
            .map_err(|e| e.to_string())?;
            Ok(id)
        }
        AddonTarget::GitHub(repo) => {
            if let Ok(existing_id) = conn.query_row(
                "SELECT id FROM addons WHERE flavour = ?1 AND repo = ?2 COLLATE NOCASE",
                params![flavour, repo],
                |r| r.get::<_, String>(0),
            ) {
                return Ok(existing_id);
            }

            let id = Uuid::new_v4().to_string();
            let default_name = name.unwrap_or(&repo);
            conn.execute(
                "INSERT INTO addons (id, flavour, source, repo, name, installed_at, release_type, ignore_updates) \
                 VALUES (?1, ?2, 'github', ?3, ?4, ?5, 1, 0)",
                params![id, flavour, repo, default_name, now],
            )
            .map_err(|e| e.to_string())?;
            Ok(id)
        }
    }
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

        // CurseForge excore URL (slug resolution / alias)
        match parse_addon_target("https://www.curseforge.com/wow/addons/excore", None) {
            Some(AddonTarget::CurseForge(id)) => assert_eq!(id, 1650514),
            other => panic!("Expected CurseForge(1650514), got {:?}", other),
        }

        // CurseForge exwindtools URL (slug resolution / alias)
        match parse_addon_target("https://www.curseforge.com/wow/addons/exwindtools", None) {
            Some(AddonTarget::CurseForge(id)) => assert_eq!(id, 1450635),
            other => panic!("Expected CurseForge(1450635), got {:?}", other),
        }

        // CurseForge numeric addon URL
        match parse_addon_target("https://www.curseforge.com/wow/addons/1650514", None) {
            Some(AddonTarget::CurseForge(id)) => assert_eq!(id, 1650514),
            other => panic!("Expected CurseForge(1650514), got {:?}", other),
        }

        // CurseForge projects URL
        match parse_addon_target("https://www.curseforge.com/projects/1650514", None) {
            Some(AddonTarget::CurseForge(id)) => assert_eq!(id, 1650514),
            other => panic!("Expected CurseForge(1650514), got {:?}", other),
        }

        // Plain excore slug
        match parse_addon_target("excore", None) {
            Some(AddonTarget::CurseForge(id)) => assert_eq!(id, 1650514),
            other => panic!("Expected CurseForge(1650514), got {:?}", other),
        }

        // Unresolvable CurseForge URL must return None (not fall through to Wago)
        assert!(parse_addon_target("https://www.curseforge.com/wow/addons/unknown-nonexistent-123456", None).is_none());

        // Arbitrary web URL must return None (not fall through to Wago)
        assert!(parse_addon_target("https://example.com/not-an-addon", None).is_none());

        // Empty string
        assert!(parse_addon_target("   ", None).is_none());
    }
}
