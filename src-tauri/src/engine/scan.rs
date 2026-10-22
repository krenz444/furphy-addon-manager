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

    // 2. Scan disk for unmanaged folders
    let entries = fs::read_dir(addons_path).map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    let mut unmanaged = Vec::new();

    for entry_res in entries.flatten() {
        let path = entry_res.path();
        if path.is_dir() {
            let name = entry_res.file_name().to_string_lossy().to_string();
            if managed_folders.contains(&name.to_ascii_lowercase()) {
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
