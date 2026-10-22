use std::collections::HashMap;
use rusqlite::{params, Connection, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddonDto {
    pub id: String,
    pub flavour: String,
    pub name: Option<String>,
    pub author: Option<String>,
    pub source: Option<String>,
    pub version: Option<String>,
    pub project_id: Option<i64>,
    pub file_id: Option<String>,
    pub file_name: Option<String>,
    pub folders: Vec<String>,
    pub installed_at: Option<String>,
    pub adopted: bool,
    pub ignore_updates: bool,
    pub pinned_file_id: Option<String>,
    pub release_type: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlavourDto {
    pub id: String,
    pub folder: String,
    pub label: String,
    pub product: Option<String>,
    pub installed: bool,
}

pub fn get_installed_flavours_db(conn: &Connection) -> Result<Vec<FlavourDto>> {
    let mut stmt = conn.prepare("SELECT id, folder, label, product, installed FROM flavours WHERE installed = 1")?;
    let rows = stmt.query_map([], |row| {
        Ok(FlavourDto {
            id: row.get(0)?,
            folder: row.get(1)?,
            label: row.get(2)?,
            product: row.get(3)?,
            installed: row.get::<_, i32>(4)? != 0,
        })
    })?;

    let mut result = Vec::new();
    for r in rows {
        result.push(r?);
    }
    Ok(result)
}

pub fn get_addons_by_flavour(conn: &Connection, flavour: &str) -> Result<Vec<AddonDto>> {
    let mut stmt = conn.prepare(
        "SELECT id, flavour, name, author, source, version, project_id, file_id, file_name, \
         installed_at, adopted, ignore_updates, pinned_file_id, release_type \
         FROM addons WHERE flavour = ?1 ORDER BY name COLLATE NOCASE ASC",
    )?;

    let rows = stmt.query_map(params![flavour], |row| {
        let addon_id: String = row.get(0)?;
        let flavour_id: String = row.get(1)?;
        let name: Option<String> = row.get(2)?;
        let author: Option<String> = row.get(3)?;
        let source: Option<String> = row.get(4)?;
        let version: Option<String> = row.get(5)?;
        let project_id: Option<i64> = row.get(6)?;
        let file_id: Option<String> = row.get(7)?;
        let file_name: Option<String> = row.get(8)?;
        let installed_at: Option<String> = row.get(9)?;
        let adopted: bool = row.get::<_, i32>(10)? != 0;
        let ignore_updates: bool = row.get::<_, i32>(11)? != 0;
        let pinned_file_id: Option<String> = row.get(12)?;
        let release_type: Option<i64> = row.get(13)?;

        Ok((
            addon_id, flavour_id, name, author, source, version,
            project_id, file_id, file_name, installed_at, adopted,
            ignore_updates, pinned_file_id, release_type,
        ))
    })?;

    let mut result = Vec::new();
    for r in rows {
        let (
            addon_id, flavour_id, name, author, source, version,
            project_id, file_id, file_name, installed_at, adopted,
            ignore_updates, pinned_file_id, release_type,
        ) = r?;

        // Retrieve folders
        let mut folder_stmt = conn.prepare(
            "SELECT folder FROM addon_folders WHERE flavour = ?1 AND addon_id = ?2 ORDER BY folder COLLATE NOCASE ASC",
        )?;
        let frows = folder_stmt.query_map(params![flavour_id, addon_id], |fr| fr.get::<_, String>(0))?;
        let folders: Vec<String> = frows.flatten().collect();

        result.push(AddonDto {
            id: addon_id,
            flavour: flavour_id,
            name,
            author,
            source,
            version,
            project_id,
            file_id,
            file_name,
            folders,
            installed_at,
            adopted,
            ignore_updates,
            pinned_file_id,
            release_type,
        });
    }

    Ok(result)
}

pub fn get_settings_map(conn: &Connection) -> Result<HashMap<String, Value>> {
    let mut stmt = conn.prepare("SELECT key, value FROM settings")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;

    let mut map = HashMap::new();
    for r in rows {
        let (k, v) = r?;
        if let Ok(val) = serde_json::from_str::<Value>(&v) {
            map.insert(k, val);
        }
    }
    Ok(map)
}
