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
        current_version = 3;
    }

    if current_version < 4 {
        let tx = conn.transaction()?;

        // Clean up any corrupt addon rows mistakenly created as Wago slugs from CurseForge URLs
        let _ = tx.execute(
            "DELETE FROM addons WHERE source = 'wago' AND (wago_slug LIKE 'http://%' OR wago_slug LIKE 'https://%')",
            [],
        );

        tx.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '4')",
            [],
        )?;

        tx.commit()?;
        current_version = 4;
    }

    if current_version < 5 {
        let tx = conn.transaction()?;

        // 1. Upgrade any existing ExwindCore GitHub records to official CurseForge project 1650514
        let _ = tx.execute(
            "UPDATE addons SET source = 'curseforge', project_id = 1650514, repo = NULL \
             WHERE (LOWER(name) = 'exwindcore' OR repo = 'Ex-wind/EXWINDCORE') AND source = 'github'",
            [],
        );

        // 2. Populate required_deps for ExBoss if missing or empty
        let _ = tx.execute(
            "UPDATE addons SET required_deps = '[\"ExwindCore\"]' \
             WHERE (wago_slug = 'exboss' OR LOWER(name) LIKE '%exboss%') \
               AND (required_deps IS NULL OR required_deps = '[]' OR required_deps = '')",
            [],
        );

        tx.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '5')",
            [],
        )?;

        tx.commit()?;
        current_version = 5;
    }

    if current_version < 6 {
        let tx = conn.transaction()?;

        let has_custom_root: bool = tx
            .prepare("SELECT COUNT(*) FROM pragma_table_info('flavours') WHERE name = 'custom_root'")?
            .query_row([], |r| r.get::<_, i64>(0))
            .map(|c| c > 0)
            .unwrap_or(false);

        if !has_custom_root {
            tx.execute("ALTER TABLE flavours ADD COLUMN custom_root TEXT", [])?;
        }

        tx.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '6')",
            [],
        )?;

        tx.commit()?;
    }

    if current_version < 7 {
        let tx = conn.transaction()?;

        let has_ignored_until_build: bool = tx
            .prepare("SELECT COUNT(*) FROM pragma_table_info('addons') WHERE name = 'ignored_until_build'")?
            .query_row([], |r| r.get::<_, i64>(0))
            .map(|c| c > 0)
            .unwrap_or(false);
        if !has_ignored_until_build {
            tx.execute("ALTER TABLE addons ADD COLUMN ignored_until_build TEXT", [])?;
        }

        let has_auto_update: bool = tx
            .prepare("SELECT COUNT(*) FROM pragma_table_info('addons') WHERE name = 'auto_update'")?
            .query_row([], |r| r.get::<_, i64>(0))
            .map(|c| c > 0)
            .unwrap_or(false);
        if !has_auto_update {
            tx.execute("ALTER TABLE addons ADD COLUMN auto_update INTEGER NOT NULL DEFAULT 1", [])?;
        }

        let has_integrity_status: bool = tx
            .prepare("SELECT COUNT(*) FROM pragma_table_info('addons') WHERE name = 'integrity_status'")?
            .query_row([], |r| r.get::<_, i64>(0))
            .map(|c| c > 0)
            .unwrap_or(false);
        if !has_integrity_status {
            tx.execute("ALTER TABLE addons ADD COLUMN integrity_status TEXT", [])?;
        }

        let has_update_mode: bool = tx
            .prepare("SELECT COUNT(*) FROM pragma_table_info('flavours') WHERE name = 'update_mode'")?
            .query_row([], |r| r.get::<_, i64>(0))
            .map(|c| c > 0)
            .unwrap_or(false);
        if !has_update_mode {
            tx.execute("ALTER TABLE flavours ADD COLUMN update_mode TEXT NOT NULL DEFAULT 'auto'", [])?;
        }

        let has_held: bool = tx
            .prepare("SELECT COUNT(*) FROM pragma_table_info('check_results') WHERE name = 'held'")?
            .query_row([], |r| r.get::<_, i64>(0))
            .map(|c| c > 0)
            .unwrap_or(false);
        if !has_held {
            tx.execute("ALTER TABLE check_results ADD COLUMN held INTEGER NOT NULL DEFAULT 0", [])?;
        }

        let has_held_reason: bool = tx
            .prepare("SELECT COUNT(*) FROM pragma_table_info('check_results') WHERE name = 'held_reason'")?
            .query_row([], |r| r.get::<_, i64>(0))
            .map(|c| c > 0)
            .unwrap_or(false);
        if !has_held_reason {
            tx.execute("ALTER TABLE check_results ADD COLUMN held_reason TEXT", [])?;
        }

        tx.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS addon_manifests (
                addon_id TEXT NOT NULL,
                rel_path TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                PRIMARY KEY (addon_id, rel_path),
                FOREIGN KEY(addon_id) REFERENCES addons(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_addon_manifests_addon_id ON addon_manifests(addon_id);

            CREATE TABLE IF NOT EXISTS activity (
                id TEXT PRIMARY KEY,
                ts TEXT NOT NULL,
                flavour TEXT NOT NULL,
                addon_id TEXT NOT NULL,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                from_version TEXT,
                to_version TEXT,
                source TEXT,
                job_id TEXT,
                error TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_activity_flavour_ts ON activity(flavour, ts DESC);

            CREATE TABLE IF NOT EXISTS whole_wtf_backups (
                id TEXT PRIMARY KEY,
                flavour TEXT NOT NULL,
                created_at TEXT NOT NULL,
                path TEXT NOT NULL,
                file_count INTEGER NOT NULL,
                total_bytes INTEGER NOT NULL,
                note TEXT,
                FOREIGN KEY(flavour) REFERENCES flavours(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_whole_wtf_backups_flavour ON whole_wtf_backups(flavour, created_at DESC);
            "#,
        )?;

        tx.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '7')",
            [],
        )?;

        tx.commit()?;
    }

    // Ensure all predefined flavours exist in flavours table
    for def in FLAVOUR_DEFS {
        conn.execute(
            "INSERT OR IGNORE INTO flavours (id, folder, label, product, installed) VALUES (?1, ?2, ?3, ?4, 0)",
            params![def.id, def.folder, def.label, Option::<String>::None],
        )?;
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
        assert_eq!(version, 7);

        // Verify flavours table
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM flavours", [], |r| r.get(0)).unwrap();
        assert_eq!(count, 7);

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

        // Verify migration 7 columns exist
        let has_auto_update: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('addons') WHERE name = 'auto_update'",
                [],
                |r| r.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .unwrap();
        assert!(has_auto_update);

        let has_update_mode: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('flavours') WHERE name = 'update_mode'",
                [],
                |r| r.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .unwrap();
        assert!(has_update_mode);

        let has_held: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('check_results') WHERE name = 'held'",
                [],
                |r| r.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .unwrap();
        assert!(has_held);

        // Verify migration 7 tables exist
        for table in ["addon_manifests", "activity", "whole_wtf_backups"] {
            let exists: bool = conn
                .query_row(
                    "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name=?1",
                    params![table],
                    |r| r.get(0),
                )
                .unwrap();
            assert!(exists, "Expected table {} to exist", table);
        }

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
