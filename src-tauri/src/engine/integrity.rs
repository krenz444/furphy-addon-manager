use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use zip::write::{SimpleFileOptions, ZipWriter};
use zip::CompressionMethod;

pub const INTEGRITY_HASH_SIZE_LIMIT: u64 = 10 * 1024 * 1024; // 10 MB

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum IntegrityStatus {
    Clean,
    Modified,
    Missing,
    Unknown,
}

impl IntegrityStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            IntegrityStatus::Clean => "clean",
            IntegrityStatus::Modified => "modified",
            IntegrityStatus::Missing => "missing",
            IntegrityStatus::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileIntegrityDiff {
    pub rel_path: String,
    pub expected_hash: Option<String>,
    pub actual_hash: Option<String>,
    pub reason: String, // "hash_mismatch" | "file_missing" | "extra_file"
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntegrityReport {
    pub addon_id: String,
    pub status: IntegrityStatus,
    pub diffs: Vec<FileIntegrityDiff>,
}

pub fn should_hash_file(path: &Path) -> bool {
    let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("").to_ascii_lowercase();
    matches!(ext.as_str(), "lua" | "xml" | "toc")
}

pub fn compute_sha256(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    let hash = hasher.finalize();
    Ok(format!("{:x}", hash))
}

fn collect_hashable_files(dir: &Path, out: &mut Vec<PathBuf>) -> Result<(), String> {
    if !dir.is_dir() {
        return Ok(());
    }
    let entries = std::fs::read_dir(dir).map_err(|e| e.to_string())?;
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        if path.is_dir() {
            collect_hashable_files(&path, out)?;
        } else if path.is_file() && should_hash_file(&path) {
            out.push(path);
        }
    }
    Ok(())
}

pub fn generate_manifest_for_folders(
    addons_root: &Path,
    folders: &[String],
) -> Result<Vec<(String, i64, String)>, String> {
    let mut manifest = Vec::new();
    for folder in folders {
        let folder_path = addons_root.join(folder);
        let mut files = Vec::new();
        collect_hashable_files(&folder_path, &mut files)?;
        for file_path in files {
            let rel = file_path
                .strip_prefix(addons_root)
                .map_err(|e| e.to_string())?;
            let rel_str = rel.to_string_lossy().replace('\\', "/");
            let meta = std::fs::metadata(&file_path).map_err(|e| e.to_string())?;
            let size = meta.len();
            let hash = if size > INTEGRITY_HASH_SIZE_LIMIT {
                "LARGE_FILE_SKIPPED".to_string()
            } else {
                compute_sha256(&file_path)?
            };
            manifest.push((rel_str, size as i64, hash));
        }
    }
    manifest.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(manifest)
}

pub fn record_manifest(
    conn: &rusqlite::Connection,
    addon_id: &str,
    manifest: &[(String, i64, String)],
) -> rusqlite::Result<()> {
    conn.execute(
        "DELETE FROM addon_manifests WHERE addon_id = ?1",
        rusqlite::params![addon_id],
    )?;
    let mut stmt = conn.prepare(
        "INSERT INTO addon_manifests (addon_id, rel_path, file_size, sha256) VALUES (?1, ?2, ?3, ?4)",
    )?;
    for (rel_path, file_size, sha256) in manifest {
        stmt.execute(rusqlite::params![addon_id, rel_path, file_size, sha256])?;
    }
    Ok(())
}

pub fn verify_addon_integrity(
    conn: &rusqlite::Connection,
    addons_root: &Path,
    addon_id: &str,
) -> Result<IntegrityReport, String> {
    let mut stmt = conn
        .prepare("SELECT rel_path, file_size, sha256 FROM addon_manifests WHERE addon_id = ?1 ORDER BY rel_path ASC")
        .map_err(|e| e.to_string())?;
    let manifest_rows = stmt
        .query_map(rusqlite::params![addon_id], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
            ))
        })
        .map_err(|e| e.to_string())?;

    let mut manifest = Vec::new();
    for row in manifest_rows {
        manifest.push(row.map_err(|e| e.to_string())?);
    }

    if manifest.is_empty() {
        return Ok(IntegrityReport {
            addon_id: addon_id.to_string(),
            status: IntegrityStatus::Unknown,
            diffs: Vec::new(),
        });
    }

    let mut stmt = conn
        .prepare("SELECT folder FROM addon_folders WHERE addon_id = ?1 ORDER BY folder ASC")
        .map_err(|e| e.to_string())?;
    let folder_rows = stmt
        .query_map(rusqlite::params![addon_id], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?;
    let mut folders = Vec::new();
    for f in folder_rows {
        folders.push(f.map_err(|e| e.to_string())?);
    }

    let mut diffs = Vec::new();
    let mut manifest_paths = HashSet::new();

    for (rel_path, expected_size, expected_hash) in &manifest {
        manifest_paths.insert(rel_path.clone());
        let file_path = addons_root.join(rel_path);

        if !file_path.is_file() {
            diffs.push(FileIntegrityDiff {
                rel_path: rel_path.clone(),
                expected_hash: Some(expected_hash.clone()),
                actual_hash: None,
                reason: "file_missing".to_string(),
            });
            continue;
        }

        let meta = match std::fs::metadata(&file_path) {
            Ok(m) => m,
            Err(_) => {
                diffs.push(FileIntegrityDiff {
                    rel_path: rel_path.clone(),
                    expected_hash: Some(expected_hash.clone()),
                    actual_hash: None,
                    reason: "file_missing".to_string(),
                });
                continue;
            }
        };

        let actual_size = meta.len() as i64;
        let actual_hash = if meta.len() > INTEGRITY_HASH_SIZE_LIMIT {
            "LARGE_FILE_SKIPPED".to_string()
        } else {
            match compute_sha256(&file_path) {
                Ok(h) => h,
                Err(e) => return Err(e),
            }
        };

        if actual_size != *expected_size || &actual_hash != expected_hash {
            diffs.push(FileIntegrityDiff {
                rel_path: rel_path.clone(),
                expected_hash: Some(expected_hash.clone()),
                actual_hash: Some(actual_hash),
                reason: "hash_mismatch".to_string(),
            });
        }
    }

    for folder in &folders {
        let folder_path = addons_root.join(folder);
        let mut files = Vec::new();
        collect_hashable_files(&folder_path, &mut files)?;
        for file_path in files {
            let rel = match file_path.strip_prefix(addons_root) {
                Ok(r) => r,
                Err(_) => continue,
            };
            let rel_str = rel.to_string_lossy().replace('\\', "/");
            if !manifest_paths.contains(&rel_str) {
                let meta = match std::fs::metadata(&file_path) {
                    Ok(m) => m,
                    Err(_) => continue,
                };
                let actual_hash = if meta.len() > INTEGRITY_HASH_SIZE_LIMIT {
                    "LARGE_FILE_SKIPPED".to_string()
                } else {
                    match compute_sha256(&file_path) {
                        Ok(h) => h,
                        Err(e) => return Err(e),
                    }
                };
                diffs.push(FileIntegrityDiff {
                    rel_path: rel_str,
                    expected_hash: None,
                    actual_hash: Some(actual_hash),
                    reason: "extra_file".to_string(),
                });
            }
        }
    }

    let has_modified = diffs.iter().any(|d| d.reason == "hash_mismatch");
    let has_missing = diffs.iter().any(|d| d.reason == "file_missing");

    let status = if has_modified {
        IntegrityStatus::Modified
    } else if has_missing {
        IntegrityStatus::Missing
    } else {
        IntegrityStatus::Clean
    };

    diffs.sort_by(|a, b| a.rel_path.cmp(&b.rel_path));

    Ok(IntegrityReport {
        addon_id: addon_id.to_string(),
        status,
        diffs,
    })
}

pub fn zip_modified_files_backup(
    addons_root: &Path,
    _addon_id: &str,
    diffs: &[FileIntegrityDiff],
    backup_zip_path: &Path,
) -> Result<u64, String> {
    if let Some(parent) = backup_zip_path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }

    let file = File::create(backup_zip_path).map_err(|e| e.to_string())?;
    let mut writer = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);

    let mut added = HashSet::new();

    for diff in diffs {
        if diff.reason != "hash_mismatch" && diff.reason != "extra_file" {
            continue;
        }

        let rel = &diff.rel_path;
        let normalized = rel.replace('\\', "/");
        if normalized.starts_with('/')
            || normalized.contains(':')
            || normalized.split('/').any(|part| part == "..")
            || Path::new(rel).is_absolute()
        {
            return Err(format!("Unsafe rel_path in diff: {}", rel));
        }

        if !added.insert(normalized.clone()) {
            continue;
        }

        let file_path = addons_root.join(&normalized);
        if !file_path.is_file() {
            continue;
        }

        writer
            .start_file(&normalized, options)
            .map_err(|e| e.to_string())?;
        let mut in_file = File::open(&file_path).map_err(|e| e.to_string())?;
        std::io::copy(&mut in_file, &mut writer).map_err(|e| e.to_string())?;
    }

    writer.finish().map_err(|e| e.to_string())?;

    let meta = std::fs::metadata(backup_zip_path).map_err(|e| e.to_string())?;
    Ok(meta.len())
}

pub fn refresh_integrity_status(
    conn: &rusqlite::Connection,
    addons_path: &Path,
    addon_id: &str,
) -> Option<String> {
    let report = verify_addon_integrity(conn, addons_path, addon_id).ok()?;
    match report.status {
        IntegrityStatus::Clean | IntegrityStatus::Modified | IntegrityStatus::Missing => {
            let status_str = report.status.as_str();
            let _ = conn.execute(
                "UPDATE addons SET integrity_status = ?1 WHERE id = ?2",
                rusqlite::params![status_str, addon_id],
            );
            Some(status_str.to_string())
        }
        IntegrityStatus::Unknown => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn setup_test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        conn.execute_batch(crate::db::schema::INITIAL_SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO addons (id, flavour, name) VALUES ('test-addon', 'retail', 'Test Addon')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'TestAddon', 'test-addon')",
            [],
        ).unwrap();
        conn
    }

    #[test]
    fn test_should_hash_file_filter() {
        assert!(should_hash_file(Path::new("test.lua")));
        assert!(should_hash_file(Path::new("test.TOC")));
        assert!(should_hash_file(Path::new("test.xml")));
        assert!(should_hash_file(Path::new("dir/sub.LUA")));

        assert!(!should_hash_file(Path::new("test.tga")));
        assert!(!should_hash_file(Path::new("test.blp")));
        assert!(!should_hash_file(Path::new("test.png")));
        assert!(!should_hash_file(Path::new("test.txt")));
        assert!(!should_hash_file(Path::new("test")));
    }

    #[test]
    fn test_compute_sha256_known_content() {
        let temp = tempfile::tempdir().unwrap();
        let file_path = temp.path().join("test.txt");
        std::fs::write(&file_path, b"hello world").unwrap();
        let hash = compute_sha256(&file_path).unwrap();
        assert_eq!(hash, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9");
    }

    #[test]
    fn test_generate_manifest_and_verify_clean() {
        let temp = tempfile::tempdir().unwrap();
        let addons_root = temp.path();
        let addon_folder = addons_root.join("TestAddon");
        std::fs::create_dir_all(&addon_folder).unwrap();

        std::fs::write(addon_folder.join("TestAddon.toc"), b"## Interface: 110000").unwrap();
        std::fs::write(addon_folder.join("Core.lua"), b"print('init')").unwrap();
        std::fs::write(addon_folder.join("icon.png"), b"image bytes").unwrap();

        let conn = setup_test_db();
        let manifest = generate_manifest_for_folders(addons_root, &["TestAddon".to_string()]).unwrap();
        assert_eq!(manifest.len(), 2);
        assert_eq!(manifest[0].0, "TestAddon/Core.lua");
        assert_eq!(manifest[1].0, "TestAddon/TestAddon.toc");

        record_manifest(&conn, "test-addon", &manifest).unwrap();

        let report = verify_addon_integrity(&conn, addons_root, "test-addon").unwrap();
        assert_eq!(report.status, IntegrityStatus::Clean);
        assert!(report.diffs.is_empty());

        // Extra hashable file on disk adds an extra_file diff without changing status to Modified
        std::fs::write(addon_folder.join("Extra.lua"), b"print('extra')").unwrap();
        let report_extra = verify_addon_integrity(&conn, addons_root, "test-addon").unwrap();
        assert_eq!(report_extra.status, IntegrityStatus::Clean);
        assert_eq!(report_extra.diffs.len(), 1);
        assert_eq!(report_extra.diffs[0].reason, "extra_file");
        assert_eq!(report_extra.diffs[0].rel_path, "TestAddon/Extra.lua");
    }

    #[test]
    fn test_verify_detects_modified_file() {
        let temp = tempfile::tempdir().unwrap();
        let addons_root = temp.path();
        let addon_folder = addons_root.join("TestAddon");
        std::fs::create_dir_all(&addon_folder).unwrap();

        let lua_file = addon_folder.join("Core.lua");
        let other_file = addon_folder.join("Utils.lua");
        std::fs::write(&lua_file, b"print('original')").unwrap();
        std::fs::write(&other_file, b"print('utils')").unwrap();

        let conn = setup_test_db();
        let manifest = generate_manifest_for_folders(addons_root, &["TestAddon".to_string()]).unwrap();
        record_manifest(&conn, "test-addon", &manifest).unwrap();

        // Edit the lua file
        std::fs::write(&lua_file, b"print('modified')").unwrap();

        let report = verify_addon_integrity(&conn, addons_root, "test-addon").unwrap();
        assert_eq!(report.status, IntegrityStatus::Modified);
        assert_eq!(report.diffs.len(), 1);
        assert_eq!(report.diffs[0].rel_path, "TestAddon/Core.lua");
        assert_eq!(report.diffs[0].reason, "hash_mismatch");
        assert!(report.diffs[0].expected_hash.is_some());
        assert!(report.diffs[0].actual_hash.is_some());
        assert_ne!(report.diffs[0].expected_hash, report.diffs[0].actual_hash);

        // If both missing and modified files exist, status remains Modified
        std::fs::remove_file(&other_file).unwrap();
        let report_both = verify_addon_integrity(&conn, addons_root, "test-addon").unwrap();
        assert_eq!(report_both.status, IntegrityStatus::Modified);
        assert_eq!(report_both.diffs.len(), 2);
    }

    #[test]
    fn test_verify_detects_missing_file() {
        let temp = tempfile::tempdir().unwrap();
        let addons_root = temp.path();
        let addon_folder = addons_root.join("TestAddon");
        std::fs::create_dir_all(&addon_folder).unwrap();

        let lua_file = addon_folder.join("Core.lua");
        std::fs::write(&lua_file, b"print('hello')").unwrap();

        let conn = setup_test_db();
        let manifest = generate_manifest_for_folders(addons_root, &["TestAddon".to_string()]).unwrap();
        record_manifest(&conn, "test-addon", &manifest).unwrap();

        // Delete the lua file
        std::fs::remove_file(&lua_file).unwrap();

        let report = verify_addon_integrity(&conn, addons_root, "test-addon").unwrap();
        assert_eq!(report.status, IntegrityStatus::Missing);
        assert_eq!(report.diffs.len(), 1);
        assert_eq!(report.diffs[0].rel_path, "TestAddon/Core.lua");
        assert_eq!(report.diffs[0].reason, "file_missing");
        assert!(report.diffs[0].expected_hash.is_some());
        assert!(report.diffs[0].actual_hash.is_none());
    }

    #[test]
    fn test_large_file_skipped() {
        let temp = tempfile::tempdir().unwrap();
        let addons_root = temp.path();
        let addon_folder = addons_root.join("TestAddon");
        std::fs::create_dir_all(&addon_folder).unwrap();

        let large_file = addon_folder.join("huge.lua");
        let f = File::create(&large_file).unwrap();
        f.set_len(INTEGRITY_HASH_SIZE_LIMIT + 1).unwrap();
        drop(f);

        let manifest = generate_manifest_for_folders(addons_root, &["TestAddon".to_string()]).unwrap();
        assert_eq!(manifest.len(), 1);
        assert_eq!(manifest[0].0, "TestAddon/huge.lua");
        assert_eq!(manifest[0].1, (INTEGRITY_HASH_SIZE_LIMIT + 1) as i64);
        assert_eq!(manifest[0].2, "LARGE_FILE_SKIPPED");

        let conn = setup_test_db();
        record_manifest(&conn, "test-addon", &manifest).unwrap();

        let report = verify_addon_integrity(&conn, addons_root, "test-addon").unwrap();
        assert_eq!(report.status, IntegrityStatus::Clean);
        assert!(report.diffs.is_empty());
    }

    #[test]
    fn test_zip_modified_files_backup() {
        let temp = tempfile::tempdir().unwrap();
        let addons_root = temp.path();
        let addon_folder = addons_root.join("TestAddon");
        std::fs::create_dir_all(&addon_folder).unwrap();

        let file_path = addon_folder.join("Core.lua");
        std::fs::write(&file_path, b"print('user modified')").unwrap();

        let diffs = vec![FileIntegrityDiff {
            rel_path: "TestAddon/Core.lua".to_string(),
            expected_hash: Some("expected".to_string()),
            actual_hash: Some("actual".to_string()),
            reason: "hash_mismatch".to_string(),
        }];

        let backup_zip = temp.path().join("backups").join("backup.zip");
        let zip_size = zip_modified_files_backup(addons_root, "test-addon", &diffs, &backup_zip).unwrap();
        assert!(zip_size > 0);
        assert!(backup_zip.exists());

        let zip_file = File::open(&backup_zip).unwrap();
        let mut archive = zip::ZipArchive::new(zip_file).unwrap();
        assert_eq!(archive.len(), 1);
        let mut entry = archive.by_name("TestAddon/Core.lua").unwrap();
        let mut content = String::new();
        entry.read_to_string(&mut content).unwrap();
        assert_eq!(content, "print('user modified')");

        let unsafe_diff = vec![FileIntegrityDiff {
            rel_path: "../outside.lua".to_string(),
            expected_hash: None,
            actual_hash: Some("abc".to_string()),
            reason: "extra_file".to_string(),
        }];
        assert!(zip_modified_files_backup(addons_root, "test-addon", &unsafe_diff, &backup_zip).is_err());
    }

    #[test]
    fn test_refresh_integrity_status() {
        let temp = tempfile::tempdir().unwrap();
        let addons_root = temp.path();
        let addon_folder = addons_root.join("TestAddon");
        std::fs::create_dir_all(&addon_folder).unwrap();

        let lua_file = addon_folder.join("Core.lua");
        std::fs::write(&lua_file, b"print('hello')").unwrap();

        let conn = setup_test_db();

        let unrecorded = refresh_integrity_status(&conn, addons_root, "test-addon");
        assert_eq!(unrecorded, None);
        let col: Option<String> = conn
            .query_row(
                "SELECT integrity_status FROM addons WHERE id = 'test-addon'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(col, None);

        let manifest = generate_manifest_for_folders(addons_root, &["TestAddon".to_string()]).unwrap();
        record_manifest(&conn, "test-addon", &manifest).unwrap();

        let clean = refresh_integrity_status(&conn, addons_root, "test-addon");
        assert_eq!(clean, Some("clean".to_string()));
        let col: Option<String> = conn
            .query_row(
                "SELECT integrity_status FROM addons WHERE id = 'test-addon'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(col.as_deref(), Some("clean"));

        std::fs::write(&lua_file, b"print('changed')").unwrap();

        let modified = refresh_integrity_status(&conn, addons_root, "test-addon");
        assert_eq!(modified, Some("modified".to_string()));
        let col: Option<String> = conn
            .query_row(
                "SELECT integrity_status FROM addons WHERE id = 'test-addon'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(col.as_deref(), Some("modified"));

        std::fs::remove_file(&lua_file).unwrap();

        let missing = refresh_integrity_status(&conn, addons_root, "test-addon");
        assert_eq!(missing, Some("missing".to_string()));
        let col: Option<String> = conn
            .query_row(
                "SELECT integrity_status FROM addons WHERE id = 'test-addon'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(col.as_deref(), Some("missing"));
    }
}
