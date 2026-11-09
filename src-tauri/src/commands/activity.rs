use crate::db::open_connection;
use crate::engine::activity::{clear_activity_records, list_activity_records, ActivityEntry};
use crate::paths::get_db_path;

#[tauri::command]
pub fn list_activity(flavour: Option<String>, limit: Option<usize>) -> Result<Vec<ActivityEntry>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let flv = flavour.as_deref().filter(|s| !s.trim().is_empty());
    list_activity_records(&conn, flv, limit).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn clear_activity(flavour: Option<String>) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let flv = flavour.as_deref().filter(|s| !s.trim().is_empty());
    clear_activity_records(&conn, flv).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use crate::system::game::TEST_ENV_LOCK;
    use crate::db::schema::INITIAL_SCHEMA;

    #[test]
    fn test_commands_list_and_clear_activity() {
        let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let temp = tempdir().unwrap();
        let fake_data = temp.path().join("AppData").join("Local");
        std::fs::create_dir_all(&fake_data).unwrap();

        let old_appdata = std::env::var_os("LOCALAPPDATA");
        std::env::set_var("LOCALAPPDATA", &fake_data);

        let db_path = get_db_path();
        let conn = open_connection(&db_path).unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        let entry = ActivityEntry {
            id: "cmd-act-1".to_string(),
            ts: "2026-11-08T12:00:00Z".to_string(),
            flavour: "retail".to_string(),
            addon_id: "details".to_string(),
            name: "Details".to_string(),
            kind: "installed".to_string(),
            from_version: None,
            to_version: None,
            source: None,
            job_id: None,
            error: None,
        };
        crate::engine::activity::record_activity(&conn, &entry).unwrap();

        let list = list_activity(Some("retail".to_string()), None).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, "cmd-act-1");

        let empty_list = list_activity(Some("classic_era".to_string()), None).unwrap();
        assert!(empty_list.is_empty());

        clear_activity(Some("retail".to_string())).unwrap();
        let after_clear = list_activity(None, None).unwrap();
        assert!(after_clear.is_empty());

        if let Some(orig) = old_appdata {
            std::env::set_var("LOCALAPPDATA", orig);
        } else {
            std::env::remove_var("LOCALAPPDATA");
        }
    }
}
