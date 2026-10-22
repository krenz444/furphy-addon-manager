use rusqlite::{params, Connection, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PatchCompatStatus {
    pub addon_id: String,
    pub name: String,
    pub installed_version: Option<String>,
    pub client_interface: Option<i32>,
    pub toc_interface: Option<i32>,
    pub is_old_patch: bool,
}

pub fn is_addon_built_for_patch(
    client_interface: Option<i32>,
    toc_interface: Option<i32>,
    latest_game_versions: &[String],
    client_build: Option<&str>,
) -> bool {
    let client_int = match client_interface {
        Some(i) => i,
        None => return true, // Can't tell, assume compatible
    };

    // If toc_interface equals client_interface, it is built for this patch
    if let Some(toc_int) = toc_interface {
        if toc_int == client_int {
            return true;
        }
    }

    // Check if client_build prefix (e.g. "11.0") appears in latest_game_versions
    if let Some(build) = client_build {
        let parts: Vec<&str> = build.split('.').collect();
        if parts.len() >= 2 {
            let prefix = format!("{}.{}", parts[0], parts[1]);
            for gv in latest_game_versions {
                if gv.starts_with(&prefix) {
                    return true;
                }
            }
        }
    }

    false
}

pub fn list_not_built_for_patch(
    conn: &Connection,
    flavour: &str,
    client_interface: Option<i32>,
    client_build: Option<&str>,
) -> Result<Vec<PatchCompatStatus>> {
    let mut results = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT id, name, version, latest_game_versions FROM addons WHERE flavour = ?1 ORDER BY name COLLATE NOCASE ASC",
    )?;

    let rows = stmt.query_map(params![flavour], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<String>>(1)?.unwrap_or_default(),
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<String>>(3)?,
        ))
    })?;

    for r in rows {
        let (id, name, version, latest_gv_json) = r?;
        let latest_gv: Vec<String> = latest_gv_json
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();

        let built = is_addon_built_for_patch(client_interface, None, &latest_gv, client_build);
        if !built {
            results.push(PatchCompatStatus {
                addon_id: id,
                name,
                installed_version: version,
                client_interface,
                toc_interface: None,
                is_old_patch: true,
            });
        }
    }

    Ok(results)
}
