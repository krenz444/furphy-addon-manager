use serde::{Deserialize, Serialize};
use crate::db::open_connection;
use crate::engine::wtf::{
    preview_wtf_restore as engine_preview, restore_wtf_snapshot as engine_restore,
};
use crate::paths::{detect_wow_root, get_data_dir, get_db_path};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WtfSnapshotDto {
    pub id: String,
    pub addon_id: String,
    pub kind: String,
    pub path: String,
    pub file_count: usize,
    pub total_bytes: u64,
    pub created_at: String,
    pub restored_at: Option<String>,
}

#[tauri::command]
pub fn list_wtf_snapshots(addon_id: String) -> Result<Vec<WtfSnapshotDto>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare(
            "SELECT id, addon_id, kind, path, size, created_at, restored_at \
             FROM wtf_snapshots WHERE addon_id = ?1 ORDER BY created_at DESC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map(rusqlite::params![addon_id], |r| {
            let path_str: String = r.get(3)?;
            let file_count = if let Ok(f) = std::fs::File::open(&path_str) {
                if let Ok(archive) = zip::ZipArchive::new(f) {
                    archive.len()
                } else {
                    0
                }
            } else {
                0
            };
            Ok(WtfSnapshotDto {
                id: r.get(0)?,
                addon_id: r.get(1)?,
                kind: r.get::<_, Option<String>>(2)?.unwrap_or_else(|| "pre-update".into()),
                path: path_str,
                file_count,
                total_bytes: r.get::<_, Option<i64>>(4)?.unwrap_or(0) as u64,
                created_at: r.get(5)?,
                restored_at: r.get(6)?,
            })
        })
        .map_err(|e| e.to_string())?;

    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(|e| e.to_string())?);
    }
    Ok(out)
}

#[tauri::command]
pub fn preview_wtf_restore(
    snapshot_id: String,
    flavour: Option<String>,
) -> Result<Vec<String>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let wow_root = detect_wow_root(None).map_err(|e| e.to_string())?;
    let flv = flavour.unwrap_or_else(|| "retail".into());
    let flv_folder = if flv.starts_with('_') {
        flv
    } else {
        format!("_{}_", flv)
    };
    engine_preview(&conn, &wow_root, &flv_folder, &snapshot_id)
}

#[tauri::command]
pub fn restore_wtf_snapshot(
    snapshot_id: String,
    flavour: Option<String>,
) -> Result<(), String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let wow_root = detect_wow_root(None).map_err(|e| e.to_string())?;
    let data_dir = get_data_dir();
    let flv = flavour.unwrap_or_else(|| "retail".into());
    let flv_folder = if flv.starts_with('_') {
        flv
    } else {
        format!("_{}_", flv)
    };
    engine_restore(&conn, &wow_root, &flv_folder, &snapshot_id, &data_dir)
}
