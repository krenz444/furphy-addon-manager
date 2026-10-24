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
    detected_at TEXT
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

CREATE INDEX IF NOT EXISTS idx_addons_flavour ON addons(flavour);
CREATE INDEX IF NOT EXISTS idx_addon_folders_addon_id ON addon_folders(addon_id);
CREATE INDEX IF NOT EXISTS idx_addon_folders_folder ON addon_folders(folder);
CREATE INDEX IF NOT EXISTS idx_backups_addon_id ON backups(addon_id);
CREATE INDEX IF NOT EXISTS idx_check_results_addon_id ON check_results(addon_id);
CREATE INDEX IF NOT EXISTS idx_wtf_snapshots_addon_id ON wtf_snapshots(addon_id);
CREATE INDEX IF NOT EXISTS idx_jobs_flavour_state ON jobs(flavour, state);
"#;
