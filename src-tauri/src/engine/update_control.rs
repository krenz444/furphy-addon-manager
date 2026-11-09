use std::collections::HashMap;
use rusqlite::{params, Connection, Result};

pub fn set_addon_release_channel(conn: &Connection, addon_id: &str, release_type: i64) -> Result<()> {
    if !(1..=3).contains(&release_type) {
        return Err(rusqlite::Error::ToSqlConversionFailure(Box::new(
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Invalid release type: must be 1 (stable), 2 (beta), or 3 (alpha)",
            ),
        )));
    }
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
    let mode_lower = mode.to_ascii_lowercase();
    if mode_lower != "auto" && mode_lower != "notify" {
        return Err(rusqlite::Error::ToSqlConversionFailure(Box::new(
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Invalid update mode: must be 'auto' or 'notify'",
            ),
        )));
    }
    conn.execute(
        "UPDATE flavours SET update_mode = ?1 WHERE id = ?2",
        params![mode_lower, flavour],
    )?;
    Ok(())
}

pub fn get_flavour_update_modes(conn: &Connection) -> Result<HashMap<String, String>> {
    let mut stmt = conn.prepare("SELECT id, update_mode FROM flavours WHERE installed = 1")?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use crate::db::schema::INITIAL_SCHEMA;

    fn setup_test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
            [],
        ).unwrap();
        conn
    }

    #[test]
    fn test_set_addon_release_channel_valid_and_invalid() {
        let conn = setup_test_db();
        conn.execute(
            "INSERT INTO addons (id, flavour, name, release_type) VALUES ('addon-1', 'retail', 'Test Addon', 1)",
            [],
        ).unwrap();

        assert!(set_addon_release_channel(&conn, "addon-1", 1).is_ok());
        let rel: i64 = conn
            .query_row("SELECT release_type FROM addons WHERE id = 'addon-1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rel, 1);

        assert!(set_addon_release_channel(&conn, "addon-1", 2).is_ok());
        let rel: i64 = conn
            .query_row("SELECT release_type FROM addons WHERE id = 'addon-1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rel, 2);

        assert!(set_addon_release_channel(&conn, "addon-1", 3).is_ok());
        let rel: i64 = conn
            .query_row("SELECT release_type FROM addons WHERE id = 'addon-1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rel, 3);

        assert!(set_addon_release_channel(&conn, "addon-1", 0).is_err());
        assert!(set_addon_release_channel(&conn, "addon-1", 4).is_err());
        assert!(set_addon_release_channel(&conn, "addon-1", -1).is_err());
        assert!(set_addon_release_channel(&conn, "addon-1", 100).is_err());
    }

    #[test]
    fn test_set_addon_auto_update() {
        let conn = setup_test_db();
        conn.execute(
            "INSERT INTO addons (id, flavour, name) VALUES ('addon-1', 'retail', 'Test Addon')",
            [],
        ).unwrap();

        let auto: i32 = conn
            .query_row("SELECT auto_update FROM addons WHERE id = 'addon-1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(auto, 1);

        assert!(set_addon_auto_update(&conn, "addon-1", false).is_ok());
        let auto: i32 = conn
            .query_row("SELECT auto_update FROM addons WHERE id = 'addon-1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(auto, 0);

        assert!(set_addon_auto_update(&conn, "addon-1", true).is_ok());
        let auto: i32 = conn
            .query_row("SELECT auto_update FROM addons WHERE id = 'addon-1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(auto, 1);
    }

    #[test]
    fn test_set_flavour_update_mode() {
        let conn = setup_test_db();

        let mode: String = conn
            .query_row("SELECT update_mode FROM flavours WHERE id = 'retail'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mode, "auto");

        assert!(set_flavour_update_mode(&conn, "retail", "notify").is_ok());
        let mode: String = conn
            .query_row("SELECT update_mode FROM flavours WHERE id = 'retail'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mode, "notify");

        assert!(set_flavour_update_mode(&conn, "retail", "auto").is_ok());
        let mode: String = conn
            .query_row("SELECT update_mode FROM flavours WHERE id = 'retail'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mode, "auto");

        assert!(set_flavour_update_mode(&conn, "retail", "invalid").is_err());
        assert!(set_flavour_update_mode(&conn, "retail", "").is_err());
    }

    #[test]
    fn test_get_flavour_update_modes() {
        let conn = setup_test_db();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed, update_mode) VALUES ('classic', '_classic_', 'Classic', 1, 'notify')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed, update_mode) VALUES ('ptr', '_ptr_', 'Public Test Realm', 0, 'auto')",
            [],
        ).unwrap();

        let modes = get_flavour_update_modes(&conn).unwrap();
        assert_eq!(modes.len(), 2);
        assert_eq!(modes.get("retail"), Some(&"auto".to_string()));
        assert_eq!(modes.get("classic"), Some(&"notify".to_string()));
        assert!(!modes.contains_key("ptr"));
    }
}
