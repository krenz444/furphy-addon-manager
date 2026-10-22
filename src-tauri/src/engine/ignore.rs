use rusqlite::{params, Connection, Result};

pub fn set_ignore_updates(conn: &Connection, addon_id: &str, ignore: bool) -> Result<()> {
    conn.execute(
        "UPDATE addons SET ignore_updates = ?1 WHERE id = ?2",
        params![if ignore { 1 } else { 0 }, addon_id],
    )?;
    Ok(())
}
