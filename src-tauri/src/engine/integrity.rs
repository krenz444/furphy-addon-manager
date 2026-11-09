use serde::{Deserialize, Serialize};
use std::path::Path;

pub const INTEGRITY_HASH_SIZE_LIMIT: u64 = 10 * 1024 * 1024; // 10 MB

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum IntegrityStatus {
    Clean,
    Modified,
    Missing,
    Unknown,
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

pub fn compute_sha256(_path: &Path) -> Result<String, String> {
    Ok(String::new())
}

pub fn generate_manifest_for_folders(
    _addons_root: &Path,
    _folders: &[String],
) -> Result<Vec<(String, i64, String)>, String> {
    Ok(Vec::new())
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
    _conn: &rusqlite::Connection,
    _addons_root: &Path,
    addon_id: &str,
) -> Result<IntegrityReport, String> {
    Ok(IntegrityReport {
        addon_id: addon_id.to_string(),
        status: IntegrityStatus::Clean,
        diffs: Vec::new(),
    })
}

pub fn zip_modified_files_backup(
    _addons_root: &Path,
    _addon_id: &str,
    _diffs: &[FileIntegrityDiff],
    _backup_zip_path: &Path,
) -> Result<u64, String> {
    Ok(0)
}
