pub const INITIAL_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS flavours (
    id TEXT PRIMARY KEY,
    folder TEXT NOT NULL,
    label TEXT NOT NULL,
    product TEXT,
    installed INTEGER NOT NULL DEFAULT 0,
    client_build TEXT,
    client_interface TEXT,
    detected_at TEXT,
    custom_root TEXT,
    update_mode TEXT NOT NULL DEFAULT 'auto'
);

CREATE TABLE IF NOT EXISTS addons (
    id TEXT PRIMARY KEY,
    flavour TEXT NOT NULL,
    source TEXT,
    project_id INTEGER,
    wago_slug TEXT,
    wago_id TEXT,
    curse_id TEXT,
    repo TEXT,
    name TEXT,
    author TEXT,
    version TEXT,
    file_id TEXT,
    file_name TEXT,
    installed_tag TEXT,
    asset_name TEXT,
    installed_at TEXT,
    adopted INTEGER NOT NULL DEFAULT 0,
    pinned_file_id TEXT,
    previous_file_id TEXT,
    previous_version TEXT,
    ignore_updates INTEGER NOT NULL DEFAULT 0,
    release_type INTEGER,
    latest_game_versions TEXT,
    required_deps TEXT,
    github_rate_limited_until TEXT,
    extra TEXT,
    ignored_deps TEXT,
    ignored_until_build TEXT,
    auto_update INTEGER NOT NULL DEFAULT 1,
    integrity_status TEXT,
    released_at TEXT,
    favourite INTEGER NOT NULL DEFAULT 0,
    tukui_slug TEXT,
    FOREIGN KEY(flavour) REFERENCES flavours(id)
);

CREATE TABLE IF NOT EXISTS ignored_untracked_folders (
    flavour TEXT NOT NULL,
    folder TEXT NOT NULL COLLATE NOCASE,
    PRIMARY KEY (flavour, folder),
    FOREIGN KEY(flavour) REFERENCES flavours(id)
);

CREATE TABLE IF NOT EXISTS addon_folders (
    flavour TEXT NOT NULL,
    folder TEXT NOT NULL COLLATE NOCASE,
    addon_id TEXT NOT NULL,
    PRIMARY KEY (flavour, folder),
    FOREIGN KEY(addon_id) REFERENCES addons(id) ON DELETE CASCADE,
    FOREIGN KEY(flavour) REFERENCES flavours(id)
);

CREATE TABLE IF NOT EXISTS backups (
    id TEXT PRIMARY KEY,
    addon_id TEXT,
    kind TEXT NOT NULL,
    file_id TEXT,
    version TEXT,
    path TEXT NOT NULL,
    size INTEGER,
    created_at TEXT,
    FOREIGN KEY(addon_id) REFERENCES addons(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS check_results (
    addon_id TEXT PRIMARY KEY,
    checked_at TEXT,
    update_file_id TEXT,
    update_version TEXT,
    status TEXT,
    error TEXT,
    held INTEGER NOT NULL DEFAULT 0,
    held_reason TEXT,
    FOREIGN KEY(addon_id) REFERENCES addons(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS freshness (
    flavour TEXT PRIMARY KEY,
    state TEXT NOT NULL,
    checked_at TEXT,
    last_success_at TEXT,
    last_error TEXT,
    FOREIGN KEY(flavour) REFERENCES flavours(id)
);

CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    flavour TEXT,
    params TEXT,
    state TEXT NOT NULL,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    error TEXT,
    results TEXT,
    reload_needed INTEGER NOT NULL DEFAULT 0,
    log_path TEXT
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS ui_prefs (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS tray_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    data TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS app_update (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    data TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS wtf_snapshots (
    id TEXT PRIMARY KEY,
    addon_id TEXT,
    account TEXT,
    scope TEXT,
    path TEXT,
    size INTEGER,
    created_at TEXT,
    kind TEXT,
    restored_at TEXT,
    FOREIGN KEY(addon_id) REFERENCES addons(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS addon_manifests (
    addon_id TEXT NOT NULL,
    rel_path TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    PRIMARY KEY (addon_id, rel_path),
    FOREIGN KEY(addon_id) REFERENCES addons(id) ON DELETE CASCADE
);

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

CREATE TABLE IF NOT EXISTS addon_groups (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS addon_group_members (
    group_id TEXT NOT NULL,
    addon_id TEXT NOT NULL,
    PRIMARY KEY (group_id, addon_id),
    FOREIGN KEY(group_id) REFERENCES addon_groups(id) ON DELETE CASCADE,
    FOREIGN KEY(addon_id) REFERENCES addons(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_addons_flavour ON addons(flavour);
CREATE INDEX IF NOT EXISTS idx_addon_folders_addon_id ON addon_folders(addon_id);
CREATE INDEX IF NOT EXISTS idx_addon_folders_folder ON addon_folders(folder);
CREATE INDEX IF NOT EXISTS idx_addon_folders_flavour_addon ON addon_folders(flavour, addon_id);
CREATE INDEX IF NOT EXISTS idx_backups_addon_id ON backups(addon_id);
CREATE INDEX IF NOT EXISTS idx_backups_addon_kind_created ON backups(addon_id, kind, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_check_results_addon_id ON check_results(addon_id);
CREATE INDEX IF NOT EXISTS idx_wtf_snapshots_addon_id ON wtf_snapshots(addon_id);
CREATE INDEX IF NOT EXISTS idx_wtf_snapshots_addon_created ON wtf_snapshots(addon_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_flavour_state ON jobs(flavour, state);
CREATE INDEX IF NOT EXISTS idx_addon_manifests_addon_id ON addon_manifests(addon_id);
CREATE INDEX IF NOT EXISTS idx_activity_flavour_ts ON activity(flavour, ts DESC);
CREATE INDEX IF NOT EXISTS idx_whole_wtf_backups_flavour ON whole_wtf_backups(flavour, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_addon_groups_name ON addon_groups(name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_group_members_addon ON addon_group_members(addon_id);
"#;

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    #[test]
    fn test_initial_schema_validity_and_tables() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        let expected_tables = [
            "meta",
            "flavours",
            "addons",
            "ignored_untracked_folders",
            "addon_folders",
            "backups",
            "check_results",
            "freshness",
            "jobs",
            "settings",
            "ui_prefs",
            "tray_state",
            "app_update",
            "wtf_snapshots",
            "addon_manifests",
            "activity",
            "whole_wtf_backups",
            "addon_groups",
            "addon_group_members",
        ];

        for table in expected_tables {
            let exists: bool = conn
                .query_row(
                    "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name=?1",
                    rusqlite::params![table],
                    |r| r.get(0),
                )
                .unwrap();
            assert!(exists, "Table '{}' should exist in INITIAL_SCHEMA", table);
        }

        let expected_indexes = [
            "idx_addons_flavour",
            "idx_addon_folders_addon_id",
            "idx_addon_folders_folder",
            "idx_addon_folders_flavour_addon",
            "idx_backups_addon_id",
            "idx_backups_addon_kind_created",
            "idx_check_results_addon_id",
            "idx_wtf_snapshots_addon_id",
            "idx_wtf_snapshots_addon_created",
            "idx_jobs_flavour_state",
            "idx_addon_manifests_addon_id",
            "idx_activity_flavour_ts",
            "idx_whole_wtf_backups_flavour",
            "idx_addon_groups_name",
            "idx_group_members_addon",
        ];

        for idx in expected_indexes {
            let exists: bool = conn
                .query_row(
                    "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='index' AND name=?1",
                    rusqlite::params![idx],
                    |r| r.get(0),
                )
                .unwrap();
            assert!(exists, "Index '{}' should exist in INITIAL_SCHEMA", idx);
        }
    }

    #[test]
    fn test_foreign_key_cascades_and_constraints() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute(
            "INSERT INTO flavours (id, folder, label) VALUES ('retail', '_retail_', 'Retail')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addons (id, flavour, name) VALUES ('addon-1', 'retail', 'TestAddon')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'TestFolder', 'addon-1')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO wtf_snapshots (id, addon_id, path, created_at) VALUES ('snap-1', 'addon-1', 'path.zip', '2026-11-03T00:00:00Z')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO backups (id, addon_id, kind, path) VALUES ('bk-1', 'addon-1', 'rollback', 'bk.zip')",
            [],
        ).unwrap();

        let folders_cnt: i64 = conn.query_row("SELECT COUNT(*) FROM addon_folders", [], |r| r.get(0)).unwrap();
        assert_eq!(folders_cnt, 1);
        let snaps_cnt: i64 = conn.query_row("SELECT COUNT(*) FROM wtf_snapshots", [], |r| r.get(0)).unwrap();
        assert_eq!(snaps_cnt, 1);

        // Delete addon
        conn.execute("DELETE FROM addons WHERE id = 'addon-1'", []).unwrap();

        // addon_folders and wtf_snapshots must be CASCADE deleted
        let folders_after: i64 = conn.query_row("SELECT COUNT(*) FROM addon_folders", [], |r| r.get(0)).unwrap();
        assert_eq!(folders_after, 0);
        let snaps_after: i64 = conn.query_row("SELECT COUNT(*) FROM wtf_snapshots", [], |r| r.get(0)).unwrap();
        assert_eq!(snaps_after, 0);

        // backups addon_id must be SET NULL
        let bk_addon_id: Option<String> = conn.query_row("SELECT addon_id FROM backups WHERE id = 'bk-1'", [], |r| r.get(0)).unwrap();
        assert!(bk_addon_id.is_none());
    }

    #[test]
    fn test_group_membership_cascades_and_unique_names() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();

        conn.execute("INSERT INTO flavours (id, folder, label) VALUES ('retail', '_retail_', 'Retail')", []).unwrap();
        conn.execute("INSERT INTO addons (id, flavour, name) VALUES ('a1', 'retail', 'One')", []).unwrap();
        conn.execute("INSERT INTO addons (id, flavour, name) VALUES ('a2', 'retail', 'Two')", []).unwrap();
        conn.execute("INSERT INTO addon_groups (id, name, created_at) VALUES ('g1', 'Raid', '2026-11-10T00:00:00Z')", []).unwrap();
        conn.execute("INSERT INTO addon_group_members (group_id, addon_id) VALUES ('g1', 'a1')", []).unwrap();
        conn.execute("INSERT INTO addon_group_members (group_id, addon_id) VALUES ('g1', 'a2')", []).unwrap();

        let duplicate = conn.execute("INSERT INTO addon_groups (id, name, created_at) VALUES ('g2', 'RAID', '2026-11-10T00:00:00Z')", []);
        assert!(duplicate.is_err(), "group names must be unique ignoring case");

        conn.execute("DELETE FROM addons WHERE id = 'a1'", []).unwrap();
        let left: i64 = conn.query_row("SELECT COUNT(*) FROM addon_group_members", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 1, "deleting an addon removes its memberships");

        conn.execute("DELETE FROM addon_groups WHERE id = 'g1'", []).unwrap();
        let left: i64 = conn.query_row("SELECT COUNT(*) FROM addon_group_members", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 0, "deleting a group removes its memberships");
    }
}
