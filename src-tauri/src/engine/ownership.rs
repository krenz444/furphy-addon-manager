use std::collections::HashSet;
use rusqlite::{params, Connection, Result};

pub fn check_folder_ownership_conflicts(
    conn: &Connection,
    flavour: &str,
    candidate_folders: &[String],
    current_addon_id: Option<&str>,
) -> Result<Vec<(String, String)>> {
    let mut conflicts = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT f.folder, a.id, a.name, a.source, a.project_id, a.wago_slug, a.repo \
         FROM addon_folders f \
         JOIN addons a ON f.addon_id = a.id \
         WHERE f.flavour = ?1 AND f.folder = ?2 COLLATE NOCASE",
    )?;

    for folder in candidate_folders {
        let mut rows = stmt.query(params![flavour, folder])?;
        while let Some(row) = rows.next()? {
            let existing_addon_id: String = row.get(1)?;
            if let Some(curr_id) = current_addon_id {
                if existing_addon_id == curr_id {
                    continue;
                }
            }

            let name: Option<String> = row.get(2)?;
            let source: Option<String> = row.get(3)?;
            let project_id: Option<i64> = row.get(4)?;
            let wago_slug: Option<String> = row.get(5)?;
            let repo: Option<String> = row.get(6)?;

            let owner_label = if let Some(n) = name {
                n
            } else if let Some(s) = source {
                match s.as_str() {
                    "curseforge" => format!("CurseForge project {}", project_id.unwrap_or(0)),
                    "wago" => format!("Wago addon {}", wago_slug.unwrap_or_default()),
                    "github" => format!("GitHub repo {}", repo.unwrap_or_default()),
                    _ => existing_addon_id,
                }
            } else {
                existing_addon_id
            };

            conflicts.push((folder.clone(), owner_label));
        }
    }

    Ok(conflicts)
}

pub fn get_protected_folders(
    conn: &Connection,
    flavour: &str,
    current_addon_id: Option<&str>,
) -> Result<HashSet<String>> {
    let mut protected = HashSet::new();
    let mut stmt = conn.prepare(
        "SELECT folder, addon_id FROM addon_folders WHERE flavour = ?1",
    )?;

    let rows = stmt.query_map(params![flavour], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;

    for r in rows {
        let (folder, addon_id) = r?;
        if let Some(curr) = current_addon_id {
            if addon_id == curr {
                continue;
            }
        }
        protected.insert(folder.to_ascii_lowercase());
    }

    Ok(protected)
}
