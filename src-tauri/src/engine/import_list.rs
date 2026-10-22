use std::fs;
use std::path::Path;
use chrono::Utc;
use rusqlite::{params, Connection, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;
use crate::logging::append_app_log;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddonExportItemV2 {
    pub name: String,
    pub source: Option<String>,
    pub project_id: Option<i64>,
    pub wago_slug: Option<String>,
    pub wago_id: Option<String>,
    pub repo: Option<String>,
    pub release_type: Option<i64>,
    pub pinned_file_id: Option<String>,
    pub ignore_updates: bool,
    pub folders: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportDocV2 {
    pub format: String, // "wow-addon-manager/2"
    pub version: u32,   // 2
    pub exported_at: String,
    pub flavour: String,
    pub addons: Vec<AddonExportItemV2>,
}

pub fn export_addon_list_v2(
    conn: &Connection,
    flavour: &str,
    dest_path: &Path,
) -> Result<(), String> {
    export_addon_list_v2_with_options(conn, flavour, dest_path, false, None, None)
}

pub fn export_addon_list_v2_with_options(
    conn: &Connection,
    flavour: &str,
    dest_path: &Path,
    include_wtf: bool,
    wow_root: Option<&Path>,
    flavour_folder: Option<&str>,
) -> Result<(), String> {
    let mut stmt = conn
        .prepare(
            "SELECT id, name, source, project_id, wago_slug, wago_id, repo, release_type, pinned_file_id, ignore_updates \
             FROM addons WHERE flavour = ?1 ORDER BY name COLLATE NOCASE ASC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map(params![flavour], |row| {
            let id: String = row.get(0)?;
            let name: String = row.get::<_, Option<String>>(1)?.unwrap_or_default();
            let source: Option<String> = row.get(2)?;
            let project_id: Option<i64> = row.get(3)?;
            let wago_slug: Option<String> = row.get(4)?;
            let wago_id: Option<String> = row.get(5)?;
            let repo: Option<String> = row.get(6)?;
            let release_type: Option<i64> = row.get(7)?;
            let pinned_file_id: Option<String> = row.get(8)?;
            let ignore_updates: bool = row.get::<_, i32>(9)? != 0;

            Ok((
                id,
                name,
                source,
                project_id,
                wago_slug,
                wago_id,
                repo,
                release_type,
                pinned_file_id,
                ignore_updates,
            ))
        })
        .map_err(|e| e.to_string())?;

    let mut items = Vec::new();
    for r in rows {
        let (
            addon_id,
            name,
            source,
            project_id,
            wago_slug,
            wago_id,
            repo,
            release_type,
            pinned_file_id,
            ignore_updates,
        ) = r.map_err(|e| e.to_string())?;

        let mut fstmt = conn
            .prepare("SELECT folder FROM addon_folders WHERE addon_id = ?1 ORDER BY folder ASC")
            .map_err(|e| e.to_string())?;
        let frows = fstmt
            .query_map(params![addon_id], |fr| fr.get::<_, String>(0))
            .map_err(|e| e.to_string())?;
        let folders: Vec<String> = frows.flatten().collect();

        items.push(AddonExportItemV2 {
            name,
            source,
            project_id,
            wago_slug,
            wago_id,
            repo,
            release_type,
            pinned_file_id,
            ignore_updates,
            folders,
        });
    }

    let doc = ExportDocV2 {
        format: "wow-addon-manager/2".to_string(),
        version: 2,
        exported_at: Utc::now().to_rfc3339(),
        flavour: flavour.to_string(),
        addons: items.clone(),
    };

    let json = serde_json::to_string_pretty(&doc).map_err(|e| e.to_string())?;

    if include_wtf && wow_root.is_some() && flavour_folder.is_some() {
        let wow = wow_root.unwrap();
        let flv_fld = flavour_folder.unwrap();
        if let Some(parent) = dest_path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let file = fs::File::create(dest_path).map_err(|e| e.to_string())?;
        let mut zip = zip::write::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);

        zip.start_file("addons.json", options)
            .map_err(|e| e.to_string())?;
        use std::io::Write;
        zip.write_all(json.as_bytes()).map_err(|e| e.to_string())?;

        let all_folders: Vec<String> = items.iter().flat_map(|it| it.folders.clone()).collect();
        let wtf_files = crate::engine::wtf::collect_addon_wtf_files(wow, flv_fld, &all_folders);
        for f in wtf_files {
            let entry_name = format!("wtf/{}", f.relative_to_wtf);
            zip.start_file(&entry_name, options).map_err(|e| e.to_string())?;
            if let Ok(mut src_file) = fs::File::open(&f.absolute_path) {
                use std::io::Read;
                let mut buf = [0u8; 64 * 1024];
                loop {
                    let n = src_file.read(&mut buf).map_err(|e| e.to_string())?;
                    if n == 0 {
                        break;
                    }
                    zip.write_all(&buf[..n]).map_err(|e| e.to_string())?;
                }
            }
        }
        zip.finish().map_err(|e| e.to_string())?;
    } else {
        fs::write(dest_path, json).map_err(|e| e.to_string())?;
    }

    Ok(())
}

pub fn import_addon_list(
    conn: &mut Connection,
    flavour: &str,
    import_path: &Path,
) -> Result<usize, String> {
    let content = if import_path
        .extension()
        .map_or(false, |ext| ext.eq_ignore_ascii_case("zip"))
    {
        let file = fs::File::open(import_path).map_err(|e| e.to_string())?;
        let mut archive = zip::ZipArchive::new(file).map_err(|e| e.to_string())?;
        let mut json_str = None;
        for i in 0..archive.len() {
            let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
            if entry.name() == "addons.json" {
                use std::io::Read;
                let mut s = String::new();
                entry.read_to_string(&mut s).map_err(|e| e.to_string())?;
                json_str = Some(s);
                break;
            }
        }
        json_str.ok_or_else(|| "Missing addons.json inside zip bundle".to_string())?
    } else {
        fs::read_to_string(import_path).map_err(|e| e.to_string())?
    };

    let root: Value = serde_json::from_str(&content).map_err(|e| e.to_string())?;

    let format_str = root
        .get("format")
        .and_then(|v| v.as_str())
        .unwrap_or("wow-addon-manager/1");

    let tx = conn.transaction().map_err(|e| e.to_string())?;
    let mut imported_count = 0;
    let now = Utc::now().to_rfc3339();

    if format_str.ends_with("/2") {
        if let Some(addons) = root.get("addons").and_then(|v| v.as_array()) {
            for a in addons {
                let name = a.get("name").and_then(|v| v.as_str()).unwrap_or("Unknown");
                let source = a.get("source").and_then(|v| v.as_str()).unwrap_or("curseforge");
                let project_id = a.get("project_id").or_else(|| a.get("projectId")).and_then(|v| v.as_i64());
                let wago_slug = a.get("wago_slug").or_else(|| a.get("wagoSlug")).and_then(|v| v.as_str());
                let wago_id = a.get("wago_id").or_else(|| a.get("wagoId")).and_then(|v| v.as_str());
                let repo = a.get("repo").and_then(|v| v.as_str());
                let release_type = a.get("release_type").or_else(|| a.get("releaseType")).and_then(|v| v.as_i64()).unwrap_or(1);
                let pinned = a.get("pinned_file_id").or_else(|| a.get("pinnedFileId")).and_then(|v| v.as_str());
                let ignore = a.get("ignore_updates").or_else(|| a.get("ignoreUpdates")).and_then(|v| v.as_bool()).unwrap_or(false);

                let id = Uuid::new_v4().to_string();
                tx.execute(
                    "INSERT INTO addons (id, flavour, name, source, project_id, wago_slug, wago_id, repo, release_type, pinned_file_id, ignore_updates, installed_at) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                    params![
                        id,
                        flavour,
                        name,
                        source,
                        project_id,
                        wago_slug,
                        wago_id,
                        repo,
                        release_type,
                        pinned,
                        if ignore { 1 } else { 0 },
                        now
                    ],
                )
                .map_err(|e| e.to_string())?;

                if let Some(folders) = a.get("folders").and_then(|v| v.as_array()) {
                    for f in folders {
                        if let Some(folder_str) = f.as_str() {
                            let _ = tx.execute(
                                "INSERT OR IGNORE INTO addon_folders (flavour, folder, addon_id) VALUES (?1, ?2, ?3)",
                                params![flavour, folder_str, id],
                            );
                        }
                    }
                }

                imported_count += 1;
            }
        }
    } else {
        // Format /1
        let addons_arr = if let Some(arr) = root.as_array() {
            arr
        } else if let Some(arr) = root.get("addons").and_then(|v| v.as_array()) {
            arr
        } else {
            return Err("Unrecognized wow-addon-manager/1 format".to_string());
        };

        for a in addons_arr {
            let name = a.get("name").and_then(|v| v.as_str()).unwrap_or("Unknown");
            let project_id = a.get("projectId").and_then(|v| v.as_i64());
            let source = a.get("source").and_then(|v| v.as_str()).unwrap_or("curseforge");
            let slug = a.get("slug").or_else(|| a.get("wagoSlug")).and_then(|v| v.as_str());

            let id = Uuid::new_v4().to_string();
            tx.execute(
                "INSERT INTO addons (id, flavour, name, source, project_id, wago_slug, installed_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![id, flavour, name, source, project_id, slug, now],
            )
            .map_err(|e| e.to_string())?;

            if let Some(folders) = a.get("folders").and_then(|v| v.as_array()) {
                for f in folders {
                    if let Some(folder_str) = f.as_str() {
                        let _ = tx.execute(
                            "INSERT OR IGNORE INTO addon_folders (flavour, folder, addon_id) VALUES (?1, ?2, ?3)",
                            params![flavour, folder_str, id],
                        );
                    }
                }
            }

            imported_count += 1;
        }
    }

    tx.commit().map_err(|e| e.to_string())?;
    append_app_log("INFO", &format!("Imported {} addons from {}", imported_count, import_path.display()));
    Ok(imported_count)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::schema::INITIAL_SCHEMA;

    #[test]
    fn test_export_and_import_v2_roundtrip() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name, source, project_id, release_type, ignore_updates) \
             VALUES ('a1', 'retail', 'Deadly Boss Mods', 'curseforge', 3358, 2, 0)",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'DBM-Core', 'a1')",
            [],
        ).unwrap();

        let temp = tempfile::tempdir().unwrap();
        let export_path = temp.path().join("export_v2.json");

        export_addon_list_v2(&conn, "retail", &export_path).unwrap();
        assert!(export_path.exists());

        let mut dest_conn = Connection::open_in_memory().unwrap();
        dest_conn.execute_batch(INITIAL_SCHEMA).unwrap();
        dest_conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        let imported = import_addon_list(&mut dest_conn, "retail", &export_path).unwrap();
        assert_eq!(imported, 1);

        let imported_name: String = dest_conn
            .query_row("SELECT name FROM addons WHERE flavour = 'retail'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(imported_name, "Deadly Boss Mods");
    }

    #[test]
    fn test_export_and_import_v2_bundle_roundtrip() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name, source, project_id, release_type, ignore_updates) \
             VALUES ('a1', 'retail', 'Details! Damage Meter', 'curseforge', 61288, 1, 0)",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'Details', 'a1')",
            [],
        ).unwrap();

        let temp = tempfile::tempdir().unwrap();
        let wow_root = temp.path().join("WoW");
        let wtf_saved = wow_root.join("_retail_").join("WTF").join("Account").join("ACCOUNT1").join("SavedVariables");
        fs::create_dir_all(&wtf_saved).unwrap();
        fs::write(wtf_saved.join("Details.lua"), b"DetailsDB = {}").unwrap();

        let export_zip = temp.path().join("bundle.zip");

        export_addon_list_v2_with_options(
            &conn,
            "retail",
            &export_zip,
            true,
            Some(&wow_root),
            Some("_retail_"),
        ).unwrap();
        assert!(export_zip.exists());

        let mut dest_conn = Connection::open_in_memory().unwrap();
        dest_conn.execute_batch(INITIAL_SCHEMA).unwrap();
        dest_conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();

        let count = import_addon_list(&mut dest_conn, "retail", &export_zip).unwrap();
        assert_eq!(count, 1);

        let name: String = dest_conn
            .query_row("SELECT name FROM addons WHERE flavour = 'retail'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(name, "Details! Damage Meter");
    }
}
