// Stub, replaced by the feature lane.
use rusqlite::Connection;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopyPlanItem {
    pub addon_id: String,
    pub name: String,
    pub add_target: Option<String>,
    pub skip_reason: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct CopyItemResult {
    pub addon_id: String,
    pub name: String,
    pub status: String,
    pub message: String,
}

pub fn plan_copy(
    _conn: &Connection,
    _source_flavour: &str,
    _target_flavour: &str,
    _addon_ids: &[String],
) -> Result<Vec<CopyPlanItem>, String> {
    Err("not implemented yet".to_string())
}
