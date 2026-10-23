use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use rusqlite::{params, Connection, Result};
use serde::{Deserialize, Serialize};
use crate::engine::toc::{find_primary_toc, parse_toc_file};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScannedUntrackedFolder {
    pub folder_name: String,
    pub title: Option<String>,
    pub version: Option<String>,
    pub author: Option<String>,
    pub curse_project_id: Option<i64>,
    pub wago_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScannedCandidateGroup {
    pub name: String,
    pub source: Option<String>,
    pub project_id: Option<i64>,
    pub wago_id: Option<String>,
    pub version: Option<String>,
    pub author: Option<String>,
    pub folders: Vec<String>,
}

pub fn scan_untracked_addons(
    conn: &Connection,
    addons_path: &Path,
    flavour: &str,
    client_interface: Option<i32>,
) -> Result<Vec<ScannedCandidateGroup>> {
    if !addons_path.is_dir() {
        return Ok(Vec::new());
    }

    // 1. Get already managed folders from DB
    let mut stmt = conn.prepare("SELECT folder FROM addon_folders WHERE flavour = ?1")?;
    let rows = stmt.query_map(params![flavour], |r| r.get::<_, String>(0))?;
    let managed_folders: HashSet<String> = rows.flatten().map(|f| f.to_ascii_lowercase()).collect();

    // 2. Get ignored untracked folders from DB
    let ignored_folders: HashSet<String> = if let Ok(mut stmt) = conn.prepare("SELECT folder FROM ignored_untracked_folders WHERE flavour = ?1") {
        if let Ok(rows) = stmt.query_map(params![flavour], |r| r.get::<_, String>(0)) {
            rows.flatten().map(|f| f.to_ascii_lowercase()).collect()
        } else {
            HashSet::new()
        }
    } else {
        HashSet::new()
    };

    // 3. Scan disk for unmanaged folders
    let entries = fs::read_dir(addons_path).map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    let mut unmanaged = Vec::new();

    for entry_res in entries.flatten() {
        let path = entry_res.path();
        if path.is_dir() {
            let name = entry_res.file_name().to_string_lossy().to_string();
            let name_lower = name.to_ascii_lowercase();
            if managed_folders.contains(&name_lower) || ignored_folders.contains(&name_lower) {
                continue;
            }

            // Find primary toc
            if let Some(toc_path) = find_primary_toc(&path, flavour, client_interface) {
                let meta = parse_toc_file(&toc_path);
                unmanaged.push(ScannedUntrackedFolder {
                    folder_name: name.clone(),
                    title: meta.title,
                    version: meta.version,
                    author: meta.author,
                    curse_project_id: meta.curse_project_id,
                    wago_id: meta.wago_id,
                });
            }
        }
    }

    // 3. Group by CurseForge project ID or Wago ID
    let mut grouped_by_cf: HashMap<i64, Vec<ScannedUntrackedFolder>> = HashMap::new();
    let mut grouped_by_wago: HashMap<String, Vec<ScannedUntrackedFolder>> = HashMap::new();
    let mut ungrouped: Vec<ScannedUntrackedFolder> = Vec::new();

    for item in unmanaged {
        if let Some(pid) = item.curse_project_id {
            grouped_by_cf.entry(pid).or_default().push(item);
        } else if let Some(ref wid) = item.wago_id {
            grouped_by_wago.entry(wid.clone()).or_default().push(item);
        } else {
            ungrouped.push(item);
        }
    }

    let mut result = Vec::new();

    for (pid, list) in grouped_by_cf {
        let first = &list[0];
        let folders = list.iter().map(|f| f.folder_name.clone()).collect();
        result.push(ScannedCandidateGroup {
            name: first.title.clone().unwrap_or_else(|| first.folder_name.clone()),
            source: Some("curseforge".to_string()),
            project_id: Some(pid),
            wago_id: None,
            version: first.version.clone(),
            author: first.author.clone(),
            folders,
        });
    }

    for (wid, list) in grouped_by_wago {
        let first = &list[0];
        let folders = list.iter().map(|f| f.folder_name.clone()).collect();
        result.push(ScannedCandidateGroup {
            name: first.title.clone().unwrap_or_else(|| first.folder_name.clone()),
            source: Some("wago".to_string()),
            project_id: None,
            wago_id: Some(wid),
            version: first.version.clone(),
            author: first.author.clone(),
            folders,
        });
    }

    for item in ungrouped {
        result.push(ScannedCandidateGroup {
            name: item.title.unwrap_or_else(|| item.folder_name.clone()),
            source: None,
            project_id: None,
            wago_id: None,
            version: item.version,
            author: item.author,
            folders: vec![item.folder_name],
        });
    }

    result.sort_by(|a, b| a.name.to_ascii_lowercase().cmp(&b.name.to_ascii_lowercase()));
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use tempfile::tempdir;
    use crate::db::schema::INITIAL_SCHEMA;

    #[test]
    fn test_scan_untracked_addons_filters_ignored_folders() {
        let temp = tempdir().unwrap();
        let addons_dir = temp.path().join("Interface").join("AddOns");
        fs::create_dir_all(&addons_dir).unwrap();

        let addon_a = addons_dir.join("AddonA");
        fs::create_dir_all(&addon_a).unwrap();
        fs::write(addon_a.join("AddonA.toc"), "## Title: Addon A\n## Version: 1.0.0\n").unwrap();

        let addon_b = addons_dir.join("AddonB");
        fs::create_dir_all(&addon_b).unwrap();
        fs::write(addon_b.join("AddonB.toc"), "## Title: Addon B\n## Version: 1.0.0\n").unwrap();

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        // Initially both are found
        let scanned = scan_untracked_addons(&conn, &addons_dir, "retail", None).unwrap();
        assert_eq!(scanned.len(), 2);

        // Add AddonB to ignored_untracked_folders
        conn.execute(
            "INSERT INTO ignored_untracked_folders (flavour, folder) VALUES ('retail', 'AddonB')",
            [],
        ).unwrap();

        // Now only AddonA should be scanned
        let scanned_after = scan_untracked_addons(&conn, &addons_dir, "retail", None).unwrap();
        assert_eq!(scanned_after.len(), 1);
        assert_eq!(scanned_after[0].folders, vec!["AddonA".to_string()]);
    }
}
