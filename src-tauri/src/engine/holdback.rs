use rusqlite::{params, Connection, Result};

pub fn parse_build_tuple(v: &str) -> Option<Vec<u32>> {
    let parts: Vec<u32> = v
        .split('.')
        .filter_map(|p| {
            let digits: String = p.chars().take_while(|c| c.is_ascii_digit()).collect();
            digits.parse::<u32>().ok()
        })
        .collect();
    if parts.is_empty() {
        None
    } else {
        Some(parts)
    }
}

pub fn is_build_strictly_newer(client: &[u32], target: &[u32]) -> bool {
    target > client
}

pub fn is_update_held_back(
    _flavour: &str,
    _client_build: Option<&str>,
    _target_game_versions: &[String],
    _ignored_until_build: Option<&str>,
) -> Option<String> {
    None
}

pub fn set_ignored_until_build(conn: &Connection, addon_id: &str, build: &str) -> Result<()> {
    conn.execute(
        "UPDATE addons SET ignored_until_build = ?1 WHERE id = ?2",
        params![build, addon_id],
    )?;
    Ok(())
}

pub fn get_ignored_until_build(conn: &Connection, addon_id: &str) -> Result<Option<String>> {
    conn.query_row(
        "SELECT ignored_until_build FROM addons WHERE id = ?1",
        params![addon_id],
        |r| r.get(0),
    )
}

pub fn clear_ignored_until_build(conn: &Connection, addon_id: &str) -> Result<()> {
    conn.execute(
        "UPDATE addons SET ignored_until_build = NULL WHERE id = ?1",
        params![addon_id],
    )?;
    Ok(())
}
