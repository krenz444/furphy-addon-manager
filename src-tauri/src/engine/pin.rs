use rusqlite::{params, Connection, Result};

pub fn pin_addon(conn: &Connection, addon_id: &str, file_id: &str) -> Result<()> {
    conn.execute(
        "UPDATE addons SET pinned_file_id = ?1 WHERE id = ?2",
        params![file_id, addon_id],
    )?;
    Ok(())
}

pub fn unpin_addon(conn: &Connection, addon_id: &str) -> Result<()> {
    conn.execute(
        "UPDATE addons SET pinned_file_id = NULL WHERE id = ?1",
        params![addon_id],
    )?;
    Ok(())
}
