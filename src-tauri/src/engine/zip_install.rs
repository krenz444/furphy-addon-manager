use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use rusqlite::params;
use crate::net::policy::NetworkPolicy;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ZipSource {
    Path(PathBuf),
    Url(String),
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ZipInstallReport {
    pub addon_id: String,
    pub name: String,
    pub version: Option<String>,
    pub folders: Vec<String>,
    pub replaced: bool,
}

pub fn parse_zip_source(raw: &str) -> Result<ZipSource, String> {
    let mut s = raw.trim();
    if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        s = &s[1..s.len() - 1];
    }
    let clean = s.trim();

    if clean.is_empty() {
        return Err("Enter a path or an https link to a .zip file.".to_string());
    }

    let lower = clean.to_ascii_lowercase();
    let allow_loopback = crate::net::direct::allow_loopback_urls();
    let is_https = lower.starts_with("https://");
    let is_test_http_loopback = allow_loopback && lower.starts_with("http://") && {
        if let Ok(u) = reqwest::Url::parse(clean) {
            crate::net::direct::is_loopback_host(u.host_str())
        } else {
            false
        }
    };

    if is_https || is_test_http_loopback {
        crate::net::direct::validate_zip_url(clean)?;
        return Ok(ZipSource::Url(clean.to_string()));
    }

    if let Some(pos) = clean.find("://") {
        let scheme = &clean[..pos];
        if scheme.chars().all(|c| c.is_ascii_alphabetic()) {
            return Err("Only https links are allowed.".to_string());
        }
    }

    if !lower.ends_with(".zip") {
        return Err("That is not a .zip file.".to_string());
    }

    let path = PathBuf::from(clean);
    if !path.is_file() {
        return Err(format!("That file does not exist: {}", clean));
    }

    Ok(ZipSource::Path(path))
}

pub fn strip_wow_colour_codes(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '|' && i + 1 < chars.len() {
            let next = chars[i + 1];
            if (next == 'c' || next == 'C') && i + 9 < chars.len() {
                let is_hex = chars[i + 2..i + 10].iter().all(|c| c.is_ascii_hexdigit());
                if is_hex {
                    i += 10;
                    continue;
                }
            } else if next == 'r' || next == 'R' {
                i += 2;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out.trim().to_string()
}

fn extract_toc_field<'a>(rest: &'a str, field_name: &str) -> Option<&'a str> {
    let lower = rest.to_ascii_lowercase();
    let field_lower = field_name.to_ascii_lowercase();
    if lower.starts_with(&field_lower) {
        let after_field = &rest[field_name.len()..];
        let after_spaces = after_field.trim_start();
        if after_spaces.starts_with(':') {
            return Some(after_spaces[1..].trim());
        }
    }
    None
}

struct TocMetadata {
    name: String,
    version: Option<String>,
    author: Option<String>,
}

fn read_toc_metadata(primary_dir: &Path, primary_folder_name: &str) -> TocMetadata {
    let mut chosen_toc_path = None;

    if let Ok(entries) = fs::read_dir(primary_dir) {
        let mut all_tocs = Vec::new();
        let expected_primary_toc = format!("{}.toc", primary_folder_name);
        for entry in entries.flatten() {
            if let Ok(ft) = entry.file_type() {
                if ft.is_file() {
                    let name = entry.file_name().to_string_lossy().to_string();
                    if name.to_ascii_lowercase().ends_with(".toc") {
                        if name.eq_ignore_ascii_case(&expected_primary_toc) {
                            chosen_toc_path = Some(entry.path());
                            break;
                        }
                        all_tocs.push((name, entry.path()));
                    }
                }
            }
        }

        if chosen_toc_path.is_none() {
            all_tocs.sort_by(|a, b| a.0.cmp(&b.0));
            if let Some((_, p)) = all_tocs.into_iter().next() {
                chosen_toc_path = Some(p);
            }
        }
    }

    let mut name = None;
    let mut version = None;
    let mut author = None;

    if let Some(toc_path) = chosen_toc_path {
        let content = fs::read_to_string(&toc_path).unwrap_or_else(|_| {
            String::from_utf8_lossy(&fs::read(&toc_path).unwrap_or_default()).into_owned()
        });

        for line in content.lines() {
            let trimmed = line.trim();
            if !trimmed.starts_with("##") {
                continue;
            }
            let rest = trimmed[2..].trim_start();

            if name.is_none() {
                if let Some(raw_val) = extract_toc_field(rest, "Title") {
                    let cleaned = strip_wow_colour_codes(raw_val);
                    if !cleaned.is_empty() {
                        name = Some(cleaned);
                    }
                }
            }

            if version.is_none() {
                if let Some(raw_val) = extract_toc_field(rest, "Version") {
                    let cleaned = strip_wow_colour_codes(raw_val);
                    if !cleaned.is_empty() {
                        version = Some(cleaned);
                    }
                }
            }

            if author.is_none() {
                if let Some(raw_val) = extract_toc_field(rest, "Author") {
                    let cleaned = strip_wow_colour_codes(raw_val);
                    if !cleaned.is_empty() {
                        author = Some(cleaned);
                    }
                }
            }
        }
    }

    let final_name = name.unwrap_or_else(|| primary_folder_name.to_string());

    TocMetadata {
        name: final_name,
        version,
        author,
    }
}

pub async fn install_from_zip(
    conn: &mut rusqlite::Connection,
    flavour: &str,
    addons_path: &Path,
    data_dir: &Path,
    policy: Arc<NetworkPolicy>,
    source: ZipSource,
) -> Result<ZipInstallReport, String> {
    let flavour_staging = crate::engine::staging::prepare_flavour_staging_dir(data_dir, flavour)
        .map_err(|e| format!("Failed to prepare staging directory: {}", e))?;
    let staging_dir = crate::engine::staging::create_unique_staging_subfolder(&flavour_staging, "zip_install")
        .map_err(|e| format!("Failed to create staging subfolder: {}", e))?;

    let res = install_from_zip_inner(conn, flavour, addons_path, &staging_dir, policy, source).await;

    let _ = crate::engine::swap::remove_dir_all_safe(&staging_dir);
    res
}

async fn install_from_zip_inner(
    conn: &mut rusqlite::Connection,
    flavour: &str,
    addons_path: &Path,
    staging_dir: &Path,
    policy: Arc<NetworkPolicy>,
    source: ZipSource,
) -> Result<ZipInstallReport, String> {
    // (1) Prepare source
    let (zip_path, zip_file_stem) = match source {
        ZipSource::Path(p) => {
            let stem = p
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            (p, stem)
        }
        ZipSource::Url(url) => {
            let client = crate::net::direct::create_direct_client()
                .map_err(|e| format!("Failed to create direct network client: {}", e))?;
            let dest_zip = staging_dir.join("download.zip");
            let dl = crate::net::direct::download_zip_url(&policy, &client, &url, &dest_zip).await?;
            let stem = Path::new(&dl.file_name)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            (dest_zip, stem)
        }
    };

    // (2) Extract package
    let extract_dir = staging_dir.join("extracted");
    crate::engine::archive::extract_addon_archive(&zip_path, &extract_dir).map_err(|e| match e {
        crate::engine::archive::ArchiveError::NoValidAddonFolders => {
            "This zip does not contain a World of Warcraft addon: no folder with a .toc file was found.".to_string()
        }
        crate::engine::archive::ArchiveError::ZipRead(_) => "That file could not be read as a zip archive.".to_string(),
        other => format!("The zip could not be installed: {}", other),
    })?;

    // (3) Keep only top-level folders that directly contain a file ending in .toc (any case)
    let mut kept_folders = Vec::new();
    if let Ok(entries) = fs::read_dir(&extract_dir) {
        for entry in entries.flatten() {
            if let Ok(ft) = entry.file_type() {
                if ft.is_dir() {
                    let folder_name = entry.file_name().to_string_lossy().to_string();
                    let mut has_toc = false;
                    if let Ok(sub_entries) = fs::read_dir(entry.path()) {
                        for sub in sub_entries.flatten() {
                            if let Ok(sft) = sub.file_type() {
                                if sft.is_file() {
                                    let sub_name = sub.file_name().to_string_lossy().to_string();
                                    if sub_name.to_ascii_lowercase().ends_with(".toc") {
                                        has_toc = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if has_toc {
                        kept_folders.push(folder_name);
                    }
                }
            }
        }
    }

    if kept_folders.is_empty() {
        return Err("This zip does not contain a World of Warcraft addon: no folder with a .toc file was found.".to_string());
    }

    kept_folders.sort();

    // (5) Determine primary folder, addon_id, replaced flag, previous folders
    let primary = kept_folders
        .iter()
        .find(|f| f.eq_ignore_ascii_case(&zip_file_stem))
        .unwrap_or(&kept_folders[0])
        .clone();

    let addon_id = format!("zip:{}:{}", flavour, primary.to_ascii_lowercase());

    let existing_addon_row: Option<(String, Option<String>)> = {
        let mut stmt = conn
            .prepare("SELECT id, version FROM addons WHERE id = ?1")
            .map_err(|e| format!("Database error: {}", e))?;
        let mut rows = stmt
            .query(params![addon_id])
            .map_err(|e| format!("Database error: {}", e))?;
        if let Some(row) = rows.next().map_err(|e| format!("Database error: {}", e))? {
            Some((row.get(0).map_err(|e| format!("Database error: {}", e))?, row.get(1).ok()))
        } else {
            None
        }
    };

    let replaced = existing_addon_row.is_some();
    let previous_version = existing_addon_row.and_then(|(_, v)| v);

    let previous_folders: Vec<String> = if replaced {
        let mut stmt = conn
            .prepare("SELECT folder FROM addon_folders WHERE addon_id = ?1 AND flavour = ?2")
            .map_err(|e| format!("Database error: {}", e))?;
        let rows = stmt
            .query_map(params![addon_id, flavour], |r| r.get::<_, String>(0))
            .map_err(|e| format!("Database error: {}", e))?;
        rows.flatten().collect()
    } else {
        Vec::new()
    };

    // (4) Folder ownership and disk conflict checks
    for f in &kept_folders {
        let owner_query: Option<(String, Option<String>)> = {
            let mut stmt = conn
                .prepare(
                    "SELECT a.id, a.name \
                     FROM addon_folders f \
                     JOIN addons a ON f.addon_id = a.id \
                     WHERE f.flavour = ?1 AND f.folder = ?2 COLLATE NOCASE",
                )
                .map_err(|e| format!("Database error: {}", e))?;
            let mut rows = stmt
                .query(params![flavour, f])
                .map_err(|e| format!("Database error: {}", e))?;
            if let Some(row) = rows.next().map_err(|e| format!("Database error: {}", e))? {
                Some((
                    row.get(0).map_err(|e| format!("Database error: {}", e))?,
                    row.get(1).ok(),
                ))
            } else {
                None
            }
        };

        if let Some((owner_id, owner_name)) = owner_query {
            if owner_id != addon_id {
                let display_name = owner_name.unwrap_or(owner_id);
                return Err(format!(
                    "The folder {} already belongs to {}. Remove that addon first.",
                    f, display_name
                ));
            }
            // Same zip addon -> replacement, permitted
        } else {
            // Not tracked in DB: check if present on disk
            let on_disk = addons_path.join(f);
            if on_disk.exists() {
                return Err(format!(
                    "A folder named {} already exists in your AddOns folder and is not managed by Furphy. Remove or adopt it first.",
                    f
                ));
            }
        }
    }

    // (6) Name and version from TOC
    let primary_dir = extract_dir.join(&primary);
    let toc_meta = read_toc_metadata(&primary_dir, &primary);

    // (7) Atomic swap
    let protected_folders = crate::engine::ownership::get_protected_folders(conn, flavour, Some(&addon_id))
        .map_err(|e| format!("Failed to get protected folders: {}", e))?;

    crate::engine::swap::execute_atomic_swap(
        addons_path,
        &extract_dir,
        &kept_folders,
        &previous_folders,
        &protected_folders,
    )?;

    // (8) Database updates in one transaction
    let now = chrono::Utc::now().to_rfc3339();
    let tx = conn.transaction().map_err(|e| format!("Failed to begin transaction: {}", e))?;

    // An upsert, not INSERT OR REPLACE: a replace would delete the old row and, through the foreign keys, the
    // favourite flag, the group memberships and the stored release date of an addon that is only being reinstalled.
    tx.execute(
        "INSERT INTO addons (id, flavour, source, project_id, wago_id, name, author, version, installed_at, adopted, release_type, ignore_updates) \
         VALUES (?1, ?2, 'zip', NULL, NULL, ?3, ?4, ?5, ?6, 0, 1, 0) \
         ON CONFLICT(id) DO UPDATE SET name = excluded.name, author = excluded.author, version = excluded.version, \
         installed_at = excluded.installed_at, source = 'zip'",
        params![
            addon_id,
            flavour,
            toc_meta.name,
            toc_meta.author,
            toc_meta.version,
            now,
        ],
    ).map_err(|e| format!("Database error inserting addon record: {}", e))?;

    tx.execute(
        "DELETE FROM addon_folders WHERE addon_id = ?1 AND flavour = ?2",
        params![addon_id, flavour],
    ).map_err(|e| format!("Database error clearing addon folders: {}", e))?;

    for folder in &kept_folders {
        tx.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES (?1, ?2, ?3)",
            params![flavour, folder, addon_id],
        ).map_err(|e| format!("Database error inserting addon folder: {}", e))?;
    }

    let manifest = crate::engine::integrity::generate_manifest_for_folders(addons_path, &kept_folders)?;
    crate::engine::integrity::record_manifest(&tx, &addon_id, &manifest)
        .map_err(|e| format!("Failed to record manifest: {}", e))?;

    let activity_kind = if replaced { "updated" } else { "installed" };
    let activity = crate::engine::activity::ActivityEntry {
        id: uuid::Uuid::new_v4().to_string(),
        ts: now,
        flavour: flavour.to_string(),
        addon_id: addon_id.clone(),
        name: toc_meta.name.clone(),
        kind: activity_kind.to_string(),
        from_version: previous_version,
        to_version: toc_meta.version.clone(),
        source: Some("zip".to_string()),
        job_id: None,
        error: None,
    };
    crate::engine::activity::record_activity(&tx, &activity)?;

    tx.commit().map_err(|e| format!("Failed to commit database transaction: {}", e))?;

    Ok(ZipInstallReport {
        addon_id,
        name: toc_meta.name,
        version: toc_meta.version,
        folders: kept_folders,
        replaced,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use zip::write::{SimpleFileOptions, ZipWriter};
    use std::io::Write;

    fn create_test_zip(path: &Path, files: &[(&str, &[u8])]) {
        let f = fs::File::create(path).unwrap();
        let mut zip = ZipWriter::new(f);
        let options = SimpleFileOptions::default();
        for (name, content) in files {
            zip.start_file(*name, options).unwrap();
            zip.write_all(content).unwrap();
        }
        zip.finish().unwrap();
    }

    #[test]
    fn test_parse_zip_source_validation() {
        assert_eq!(
            parse_zip_source("").unwrap_err(),
            "Enter a path or an https link to a .zip file."
        );
        assert_eq!(
            parse_zip_source("   ").unwrap_err(),
            "Enter a path or an https link to a .zip file."
        );
        assert_eq!(
            parse_zip_source("\"\"").unwrap_err(),
            "Enter a path or an https link to a .zip file."
        );

        // Disallowed scheme
        assert_eq!(
            parse_zip_source("http://example.com/file.zip").unwrap_err(),
            "Only https links are allowed."
        );
        assert_eq!(
            parse_zip_source("ftp://example.com/file.zip").unwrap_err(),
            "Only https links are allowed."
        );

        // Valid https url
        let url_res = parse_zip_source("https://example.com/file.zip");
        assert!(url_res.is_ok());
        assert_eq!(url_res.unwrap(), ZipSource::Url("https://example.com/file.zip".to_string()));

        // Surrounding quotes stripped
        let url_quoted = parse_zip_source("\"https://example.com/file.zip\"");
        assert!(url_quoted.is_ok());
        assert_eq!(url_quoted.unwrap(), ZipSource::Url("https://example.com/file.zip".to_string()));

        // Non-zip file path
        let temp = tempfile::tempdir().unwrap();
        let txt_file = temp.path().join("readme.txt");
        fs::write(&txt_file, b"test").unwrap();
        let err_not_zip = parse_zip_source(&txt_file.to_string_lossy());
        assert_eq!(err_not_zip.unwrap_err(), "That is not a .zip file.");

        // Nonexistent zip file path
        let fake_path = temp.path().join("nonexistent.zip");
        let err_missing = parse_zip_source(&fake_path.to_string_lossy());
        assert!(err_missing.unwrap_err().starts_with("That file does not exist:"));

        // Valid zip file path
        let zip_file = temp.path().join("valid.zip");
        create_test_zip(&zip_file, &[("MyAddon/MyAddon.toc", b"## Title: MyAddon")]);
        let ok_path = parse_zip_source(&zip_file.to_string_lossy());
        assert!(ok_path.is_ok());
        assert_eq!(ok_path.unwrap(), ZipSource::Path(zip_file));
    }

    #[test]
    fn test_strip_wow_colour_codes() {
        assert_eq!(strip_wow_colour_codes("|cff00ff00My Addon|r"), "My Addon");
        assert_eq!(strip_wow_colour_codes("|cff112233Title|r"), "Title");
        assert_eq!(strip_wow_colour_codes("|cffff8000Deadly Boss Mods|r |cff69ccf0Core|r"), "Deadly Boss Mods Core");
        assert_eq!(strip_wow_colour_codes("Clean Title"), "Clean Title");
    }

    #[test]
    fn test_toc_metadata_reading() {
        let temp = tempfile::tempdir().unwrap();
        let addon_dir = temp.path().join("SuperAddon");
        fs::create_dir_all(&addon_dir).unwrap();

        let toc_content = "## Interface: 110000\n## Title: |cff112233Super Addon|r\n## Version: 2.3.4\n## Author: DevPerson\n";
        fs::write(addon_dir.join("SuperAddon.toc"), toc_content).unwrap();

        let meta = read_toc_metadata(&addon_dir, "SuperAddon");
        assert_eq!(meta.name, "Super Addon");
        assert_eq!(meta.version.as_deref(), Some("2.3.4"));
        assert_eq!(meta.author.as_deref(), Some("DevPerson"));

        // Fallback when Title missing
        let addon_dir2 = temp.path().join("FallbackAddon");
        fs::create_dir_all(&addon_dir2).unwrap();
        fs::write(addon_dir2.join("FallbackAddon.toc"), "## Interface: 110000\n").unwrap();
        let meta2 = read_toc_metadata(&addon_dir2, "FallbackAddon");
        assert_eq!(meta2.name, "FallbackAddon");
        assert_eq!(meta2.version, None);
    }

    #[tokio::test]
    async fn test_install_from_zip_lifecycle_and_conflicts() {
        let temp = tempfile::tempdir().unwrap();
        let addons_path = temp.path().join("AddOns");
        let data_dir = temp.path().join("data");
        fs::create_dir_all(&addons_path).unwrap();
        fs::create_dir_all(&data_dir).unwrap();

        let mut conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::db::migrate::run_migrations(&mut conn).unwrap();

        let policy = Arc::new(NetworkPolicy::new());

        // 1. Zip without .toc rejected
        let no_toc_zip = temp.path().join("notoc.zip");
        create_test_zip(&no_toc_zip, &[("RandomFolder/test.lua", b"print('hello')")]);
        let err_no_toc = install_from_zip(
            &mut conn,
            "retail",
            &addons_path,
            &data_dir,
            policy.clone(),
            ZipSource::Path(no_toc_zip),
        ).await;
        assert!(err_no_toc.is_err());
        assert_eq!(
            err_no_toc.unwrap_err(),
            "This zip does not contain a World of Warcraft addon: no folder with a .toc file was found."
        );

        // 2. Unmanaged folder on disk causes conflict
        let unmanaged = addons_path.join("UnmanagedAddon");
        fs::create_dir_all(&unmanaged).unwrap();
        let unmanaged_zip = temp.path().join("UnmanagedAddon.zip");
        create_test_zip(&unmanaged_zip, &[
            ("UnmanagedAddon/UnmanagedAddon.toc", b"## Title: Unmanaged"),
            ("UnmanagedAddon/Core.lua", b"print(1)"),
        ]);
        let err_unmanaged = install_from_zip(
            &mut conn,
            "retail",
            &addons_path,
            &data_dir,
            policy.clone(),
            ZipSource::Path(unmanaged_zip),
        ).await;
        assert!(err_unmanaged.is_err());
        assert!(err_unmanaged.unwrap_err().contains("already exists in your AddOns folder and is not managed by Furphy"));

        // Clean unmanaged
        fs::remove_dir_all(&unmanaged).unwrap();

        // 3. Successful clean install from zip
        let good_zip = temp.path().join("GoodAddon-1.0.zip");
        create_test_zip(&good_zip, &[
            ("GoodAddon/GoodAddon.toc", b"## Title: |cff00ff00Good Addon|r\n## Version: 1.0\n## Author: AuthorX"),
            ("GoodAddon/Core.lua", b"print('good addon')"),
        ]);

        let report = install_from_zip(
            &mut conn,
            "retail",
            &addons_path,
            &data_dir,
            policy.clone(),
            ZipSource::Path(good_zip.clone()),
        ).await.unwrap();

        assert_eq!(report.addon_id, "zip:retail:goodaddon");
        assert_eq!(report.name, "Good Addon");
        assert_eq!(report.version.as_deref(), Some("1.0"));
        assert_eq!(report.folders, vec!["GoodAddon".to_string()]);
        assert!(!report.replaced);

        // Verify disk contents
        assert!(addons_path.join("GoodAddon").join("GoodAddon.toc").exists());
        assert!(addons_path.join("GoodAddon").join("Core.lua").exists());

        // Verify DB row
        let (source, version, name): (String, Option<String>, String) = conn.query_row(
            "SELECT source, version, name FROM addons WHERE id = 'zip:retail:goodaddon'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        ).unwrap();
        assert_eq!(source, "zip");
        assert_eq!(version.as_deref(), Some("1.0"));
        assert_eq!(name, "Good Addon");

        // Verify manifest recorded
        let manifest_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM addon_manifests WHERE addon_id = 'zip:retail:goodaddon'",
            [],
            |r| r.get(0),
        ).unwrap();
        assert_eq!(manifest_count, 2);

        // Verify activity recorded
        let (act_kind, act_to): (String, Option<String>) = conn.query_row(
            "SELECT kind, to_version FROM activity WHERE addon_id = 'zip:retail:goodaddon'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        ).unwrap();
        assert_eq!(act_kind, "installed");
        assert_eq!(act_to.as_deref(), Some("1.0"));

        // 4. Successful replacement update
        let update_zip = temp.path().join("GoodAddon-2.0.zip");
        create_test_zip(&update_zip, &[
            ("GoodAddon/GoodAddon.toc", b"## Title: Good Addon\n## Version: 2.0"),
            ("GoodAddon/Core.lua", b"print('updated')"),
        ]);

        let report2 = install_from_zip(
            &mut conn,
            "retail",
            &addons_path,
            &data_dir,
            policy.clone(),
            ZipSource::Path(update_zip),
        ).await.unwrap();

        assert!(report2.replaced);
        assert_eq!(report2.version.as_deref(), Some("2.0"));

        let updated_content = fs::read_to_string(addons_path.join("GoodAddon").join("Core.lua")).unwrap();
        assert_eq!(updated_content, "print('updated')");

        // 5. Conflict with another addon owning the folder
        conn.execute(
            "INSERT INTO addons (id, flavour, name, source) VALUES ('other-addon', 'retail', 'Existing Other', 'curseforge')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'ExistingFolder', 'other-addon')",
            [],
        ).unwrap();

        let conflict_zip = temp.path().join("Conflict.zip");
        create_test_zip(&conflict_zip, &[
            ("ExistingFolder/ExistingFolder.toc", b"## Title: Conflict Addon"),
        ]);

        let err_conflict = install_from_zip(
            &mut conn,
            "retail",
            &addons_path,
            &data_dir,
            policy.clone(),
            ZipSource::Path(conflict_zip),
        ).await;

        assert!(err_conflict.is_err());
        assert_eq!(
            err_conflict.unwrap_err(),
            "The folder ExistingFolder already belongs to Existing Other. Remove that addon first."
        );
    }

    #[tokio::test]
    async fn reinstalling_a_zip_addon_keeps_its_favourite_flag_and_group_memberships() {
        let temp = tempfile::tempdir().unwrap();
        let addons_path = temp.path().join("AddOns");
        let data_dir = temp.path().join("data");
        fs::create_dir_all(&addons_path).unwrap();
        fs::create_dir_all(&data_dir).unwrap();
        let mut conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::db::migrate::run_migrations(&mut conn).unwrap();
        let policy = Arc::new(NetworkPolicy::new());

        let first_zip = temp.path().join("Keeper.zip");
        create_test_zip(&first_zip, &[("Keeper/Keeper.toc", b"## Title: Keeper\n## Version: 1.0\n"), ("Keeper/Core.lua", b"print(1)")]);
        let first = install_from_zip(&mut conn, "retail", &addons_path, &data_dir, policy.clone(), ZipSource::Path(first_zip)).await.unwrap();
        assert!(!first.replaced);

        crate::engine::groups::set_favourite(&conn, &first.addon_id, true).unwrap();
        let group = crate::engine::groups::create_group(&conn, "Raid").unwrap();
        crate::engine::groups::set_addon_group(&conn, &first.addon_id, &group.id, true).unwrap();

        let second_zip = temp.path().join("Keeper2.zip");
        create_test_zip(&second_zip, &[("Keeper/Keeper.toc", b"## Title: Keeper\n## Version: 2.0\n"), ("Keeper/Core.lua", b"print(2)")]);
        let second = install_from_zip(&mut conn, "retail", &addons_path, &data_dir, policy.clone(), ZipSource::Path(second_zip)).await.unwrap();
        assert!(second.replaced);
        assert_eq!(second.version.as_deref(), Some("2.0"));

        let favourite: i64 = conn.query_row("SELECT favourite FROM addons WHERE id = ?1", params![second.addon_id], |r| r.get(0)).unwrap();
        assert_eq!(favourite, 1, "a reinstall keeps the favourite flag");
        let groups = crate::engine::groups::group_ids_by_addon(&conn).unwrap();
        assert_eq!(groups.get(&second.addon_id), Some(&vec![group.id.clone()]), "a reinstall keeps the group memberships");
        let folders: i64 = conn.query_row("SELECT COUNT(*) FROM addon_folders WHERE addon_id = ?1", params![second.addon_id], |r| r.get(0)).unwrap();
        assert_eq!(folders, 1);
    }
}
