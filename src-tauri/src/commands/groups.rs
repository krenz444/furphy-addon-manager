use crate::db::open_connection;
use crate::engine::groups::{self, GroupRow};
use crate::paths::get_db_path;

#[derive(Debug, Clone, serde::Serialize)]
pub struct GroupDto {
    pub id: String,
    pub name: String,
    pub sort_order: i64,
    pub member_count: i64,
}

impl From<GroupRow> for GroupDto {
    fn from(row: GroupRow) -> Self {
        GroupDto {
            id: row.id,
            name: row.name,
            sort_order: row.sort_order,
            member_count: row.member_count,
        }
    }
}

fn open() -> Result<rusqlite::Connection, String> {
    open_connection(&get_db_path()).map_err(|e| format!("Database error: {}", e))
}

#[tauri::command]
pub fn set_favourite(addon_id: String, favourite: bool) -> Result<(), String> {
    let conn = open()?;
    groups::set_favourite(&conn, &addon_id, favourite).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn list_groups() -> Result<Vec<GroupDto>, String> {
    let conn = open()?;
    let rows = groups::list_groups(&conn).map_err(|e| e.to_string())?;
    Ok(rows.into_iter().map(GroupDto::from).collect())
}

#[tauri::command]
pub fn create_group(name: String) -> Result<GroupDto, String> {
    let conn = open()?;
    groups::create_group(&conn, &name).map(GroupDto::from)
}

#[tauri::command]
pub fn rename_group(group_id: String, name: String) -> Result<(), String> {
    let conn = open()?;
    groups::rename_group(&conn, &group_id, &name)
}

#[tauri::command]
pub fn delete_group(group_id: String) -> Result<(), String> {
    let conn = open()?;
    groups::delete_group(&conn, &group_id)
}

#[tauri::command]
pub fn set_addon_group(addon_id: String, group_id: String, member: bool) -> Result<(), String> {
    let conn = open()?;
    groups::set_addon_group(&conn, &addon_id, &group_id, member)
}
