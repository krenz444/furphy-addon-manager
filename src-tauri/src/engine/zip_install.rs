// Stub, replaced by the feature lane.
use std::path::{Path, PathBuf};
use std::sync::Arc;
use crate::net::policy::NetworkPolicy;

#[derive(Debug, Clone)]
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

pub fn parse_zip_source(_raw: &str) -> Result<ZipSource, String> {
    Err("not implemented yet".to_string())
}

pub async fn install_from_zip(
    _conn: &mut rusqlite::Connection,
    _flavour: &str,
    _addons_path: &Path,
    _data_dir: &Path,
    _policy: Arc<NetworkPolicy>,
    _source: ZipSource,
) -> Result<ZipInstallReport, String> {
    Err("not implemented yet".to_string())
}
