use rusqlite::{params, Connection, Result};
use crate::paths::FLAVOUR_DEFS;
use super::schema::INITIAL_SCHEMA;

pub fn initialize_connection(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        r#"
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        PRAGMA busy_timeout = 5000;
        "#,
    )?;
    Ok(())
}

pub fn get_schema_version(conn: &Connection) -> Result<i32> {
    let table_exists: bool = conn.query_row(
        "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='meta'",
        [],
        |row| row.get(0),
    )?;

    if !table_exists {
        return Ok(0);
    }

    let version_str: Option<String> = conn.query_row(
        "SELECT value FROM meta WHERE key = 'schema_version'",
        [],
        |row| row.get(0),
    ).ok();

    match version_str {
        Some(v) => Ok(v.parse::<i32>().unwrap_or(0)),
        None => Ok(0),
    }
}

pub fn run_migrations(conn: &mut Connection) -> Result<()> {
    initialize_connection(conn)?;

    let current_version = get_schema_version(conn)?;

    if current_version < 1 {
        let tx = conn.transaction()?;

        tx.execute_batch(INITIAL_SCHEMA)?;

        for def in FLAVOUR_DEFS {
            tx.execute(
                "INSERT OR IGNORE INTO flavours (id, folder, label, product, installed) VALUES (?1, ?2, ?3, ?4, 0)",
                params![def.id, def.folder, def.label, Option::<String>::None],
            )?;
        }

        tx.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '1')",
            [],
        )?;

        tx.commit()?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_migrations_create_tables_and_sets_version() {
        let mut conn = Connection::open_in_memory().unwrap();
        run_migrations(&mut conn).unwrap();

        let version = get_schema_version(&conn).unwrap();
        assert_eq!(version, 1);

        // Verify flavours table
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM flavours", [], |r| r.get(0)).unwrap();
        assert_eq!(count, 6);

        // Verify foreign keys enabled
        let fk: i64 = conn.query_row("PRAGMA foreign_keys", [], |r| r.get(0)).unwrap();
        assert_eq!(fk, 1);
    }
}
