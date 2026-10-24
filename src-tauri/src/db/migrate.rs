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

    let mut current_version = get_schema_version(conn)?;

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
        current_version = 1;
    }

    if current_version < 2 {
        let tx = conn.transaction()?;

        let has_ignored_deps: bool = tx
            .prepare("SELECT COUNT(*) FROM pragma_table_info('addons') WHERE name = 'ignored_deps'")?
            .query_row([], |r| r.get::<_, i64>(0))
            .map(|c| c > 0)
            .unwrap_or(false);

        if !has_ignored_deps {
            tx.execute("ALTER TABLE addons ADD COLUMN ignored_deps TEXT", [])?;
        }

        tx.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS ignored_untracked_folders (
                flavour TEXT NOT NULL,
                folder TEXT NOT NULL COLLATE NOCASE,
                PRIMARY KEY (flavour, folder),
                FOREIGN KEY(flavour) REFERENCES flavours(id)
            );
            "#,
        )?;

        tx.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '2')",
            [],
        )?;

        tx.commit()?;
        current_version = 2;
    }

    if current_version < 3 {
        let tx = conn.transaction()?;

        tx.execute_batch(
            r#"
            CREATE INDEX IF NOT EXISTS idx_addons_flavour ON addons(flavour);
            CREATE INDEX IF NOT EXISTS idx_addon_folders_addon_id ON addon_folders(addon_id);
            CREATE INDEX IF NOT EXISTS idx_addon_folders_folder ON addon_folders(folder);
            CREATE INDEX IF NOT EXISTS idx_backups_addon_id ON backups(addon_id);
            CREATE INDEX IF NOT EXISTS idx_check_results_addon_id ON check_results(addon_id);
            CREATE INDEX IF NOT EXISTS idx_wtf_snapshots_addon_id ON wtf_snapshots(addon_id);
            CREATE INDEX IF NOT EXISTS idx_jobs_flavour_state ON jobs(flavour, state);
            "#,
        )?;

        tx.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '3')",
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
        assert_eq!(version, 3);

        // Verify flavours table
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM flavours", [], |r| r.get(0)).unwrap();
        assert_eq!(count, 6);

        // Verify foreign keys enabled
        let fk: i64 = conn.query_row("PRAGMA foreign_keys", [], |r| r.get(0)).unwrap();
        assert_eq!(fk, 1);

        // Verify ignored_deps column exists on addons
        let has_col: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('addons') WHERE name = 'ignored_deps'",
                [],
                |r| r.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .unwrap();
        assert!(has_col);

        // Verify ignored_untracked_folders table exists
        let table_exists: bool = conn
            .query_row(
                "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='ignored_untracked_folders'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(table_exists);

        // Verify all 7 indexes exist
        let expected_indexes = [
            "idx_addons_flavour",
            "idx_addon_folders_addon_id",
            "idx_addon_folders_folder",
            "idx_backups_addon_id",
            "idx_check_results_addon_id",
            "idx_wtf_snapshots_addon_id",
            "idx_jobs_flavour_state",
        ];

        for idx in expected_indexes {
            let index_exists: bool = conn
                .query_row(
                    "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='index' AND name=?1",
                    params![idx],
                    |r| r.get(0),
                )
                .unwrap();
            assert!(index_exists, "Expected index {} to exist", idx);
        }
    }
}
