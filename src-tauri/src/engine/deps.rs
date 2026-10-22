use std::collections::HashSet;
use rusqlite::{params, Connection, Result};

pub fn check_missing_dependencies(
    conn: &Connection,
    flavour: &str,
    addon_id: &str,
) -> Result<Vec<String>> {
    // 1. Get required deps for this addon
    let required_deps_json: Option<String> = conn
        .query_row(
            "SELECT required_deps FROM addons WHERE id = ?1 AND flavour = ?2",
            params![addon_id, flavour],
            |r| r.get(0),
        )
        .unwrap_or(None);

    let required: Vec<String> = required_deps_json
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    if required.is_empty() {
        return Ok(Vec::new());
    }

    // 2. Get all installed folders in this flavour
    let mut stmt = conn.prepare("SELECT folder FROM addon_folders WHERE flavour = ?1")?;
    let rows = stmt.query_map(params![flavour], |r| r.get::<_, String>(0))?;
    let installed_folders: HashSet<String> = rows.flatten().map(|f| f.to_ascii_lowercase()).collect();

    // 3. Find missing
    let mut missing = Vec::new();
    for dep in required {
        if !installed_folders.contains(&dep.to_ascii_lowercase()) {
            missing.push(dep);
        }
    }

    Ok(missing)
}
