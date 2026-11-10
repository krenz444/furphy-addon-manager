// Stub, replaced by the feature lane.
use std::collections::HashMap;
use rusqlite::Connection;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupRow {
    pub id: String,
    pub name: String,
    pub sort_order: i64,
    pub member_count: i64,
}

pub fn set_favourite(_conn: &Connection, _addon_id: &str, _favourite: bool) -> rusqlite::Result<()> {
    Ok(())
}

pub fn list_groups(_conn: &Connection) -> rusqlite::Result<Vec<GroupRow>> {
    Ok(Vec::new())
}

pub fn create_group(_conn: &Connection, _name: &str) -> Result<GroupRow, String> {
    Err("not implemented yet".to_string())
}

pub fn rename_group(_conn: &Connection, _group_id: &str, _name: &str) -> Result<(), String> {
    Err("not implemented yet".to_string())
}

pub fn delete_group(_conn: &Connection, _group_id: &str) -> Result<(), String> {
    Err("not implemented yet".to_string())
}

pub fn set_addon_group(_conn: &Connection, _addon_id: &str, _group_id: &str, _member: bool) -> Result<(), String> {
    Err("not implemented yet".to_string())
}

pub fn group_ids_by_addon(_conn: &Connection) -> rusqlite::Result<HashMap<String, Vec<String>>> {
    Ok(HashMap::new())
}
