use std::collections::HashMap;
use rusqlite::{params, Connection, Result};

pub fn set_addon_release_channel(conn: &Connection, addon_id: &str, release_type: i64) -> Result<()> {
    conn.execute(
        "UPDATE addons SET release_type = ?1 WHERE id = ?2",
        params![release_type, addon_id],
    )?;
    Ok(())
}

pub fn set_addon_auto_update(conn: &Connection, addon_id: &str, auto_update: bool) -> Result<()> {
    conn.execute(
        "UPDATE addons SET auto_update = ?1 WHERE id = ?2",
        params![if auto_update { 1 } else { 0 }, addon_id],
    )?;
    Ok(())
}

pub fn set_flavour_update_mode(conn: &Connection, flavour: &str, mode: &str) -> Result<()> {
    conn.execute(
        "UPDATE flavours SET update_mode = ?1 WHERE id = ?2",
        params![mode, flavour],
    )?;
    Ok(())
}

pub fn get_flavour_update_modes(conn: &Connection) -> Result<HashMap<String, String>> {
    let mut stmt = conn.prepare("SELECT id, update_mode FROM flavours")?;
    let rows = stmt.query_map([], |row| {
        let id: String = row.get(0)?;
        let mode: String = row.get::<_, Option<String>>(1)?.unwrap_or_else(|| "auto".to_string());
        Ok((id, mode))
    })?;
    let mut map = HashMap::new();
    for r in rows {
        let (id, mode) = r?;
        map.insert(id, mode);
    }
    Ok(map)
}
