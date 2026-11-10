// Stub, replaced by the feature lane.
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BattlenetInstall {
    pub product: String,
    pub uid: String,
    pub install_path: String,
}

pub fn product_db_path() -> PathBuf {
    match std::env::var_os("FURPHY_TEST_PRODUCT_DB") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(std::env::var_os("PROGRAMDATA").unwrap_or_default())
            .join("Battle.net")
            .join("Agent")
            .join("product.db"),
    }
}

pub fn parse_product_db(_bytes: &[u8]) -> Result<Vec<BattlenetInstall>, String> {
    Err("not implemented yet".to_string())
}

pub fn wow_roots_from_product_db() -> Vec<PathBuf> {
    Vec::new()
}
