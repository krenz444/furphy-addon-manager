use rusqlite::{params, Connection, Result};
use crate::logging::append_app_log;

pub fn switch_addon_source(
    conn: &Connection,
    addon_id: &str,
    new_source: &str,
    project_id: Option<i64>,
    wago_id: Option<&str>,
    wago_slug: Option<&str>,
) -> Result<(), String> {
    conn.execute(
        "UPDATE addons SET source = ?1, project_id = ?2, wago_id = ?3, wago_slug = ?4 WHERE id = ?5",
        params![new_source, project_id, wago_id, wago_slug, addon_id],
    )
    .map_err(|e| e.to_string())?;

    append_app_log(
        "INFO",
        &format!("Switched addon {} source to {}", addon_id, new_source),
    );

    Ok(())
}
