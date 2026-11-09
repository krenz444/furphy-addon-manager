use serde::{Deserialize, Serialize};

pub const ACTIVITY_RETENTION_MAX_ROWS: usize = 500;
pub const ACTIVITY_RETENTION_DAYS: i64 = 90;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityKind {
    Installed,
    Updated,
    Removed,
    RolledBack,
    Failed,
    Held,
    SwitchedSource,
}

impl ActivityKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            ActivityKind::Installed => "installed",
            ActivityKind::Updated => "updated",
            ActivityKind::Removed => "removed",
            ActivityKind::RolledBack => "rolled_back",
            ActivityKind::Failed => "failed",
            ActivityKind::Held => "held",
            ActivityKind::SwitchedSource => "switched_source",
        }
    }
}

impl std::fmt::Display for ActivityKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivityEntry {
    pub id: String,
    pub ts: String,
    pub flavour: String,
    pub addon_id: String,
    pub name: String,
    pub kind: String, // "installed" | "updated" | "removed" | "rolled_back" | "failed" | "held" | "switched_source"
    pub from_version: Option<String>,
    pub to_version: Option<String>,
    pub source: Option<String>,
    pub job_id: Option<String>,
    pub error: Option<String>,
}

pub fn record_activity(conn: &rusqlite::Connection, entry: &ActivityEntry) -> Result<(), String> {
    match conn.execute(
        "INSERT INTO activity (id, ts, flavour, addon_id, name, kind, from_version, to_version, source, job_id, error) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        rusqlite::params![
            entry.id,
            entry.ts,
            entry.flavour,
            entry.addon_id,
            entry.name,
            entry.kind,
            entry.from_version,
            entry.to_version,
            entry.source,
            entry.job_id,
            entry.error,
        ],
    ) {
        Ok(_) => {
            if let Err(e) = prune_activity_retention(conn) {
                crate::logging::append_app_log("WARN", &format!("Pruning activity retention failed: {}", e));
            }
            Ok(())
        }
        Err(e) => {
            crate::logging::append_app_log("ERROR", &format!("Failed to record activity: {}", e));
            Err(e.to_string())
        }
    }
}

pub fn list_activity_records(
    conn: &rusqlite::Connection,
    flavour: Option<&str>,
    limit: Option<usize>,
) -> rusqlite::Result<Vec<ActivityEntry>> {
    let max_rows = limit.unwrap_or(ACTIVITY_RETENTION_MAX_ROWS);
    let mut entries = Vec::new();
    let flv = flavour.filter(|s| !s.trim().is_empty());

    if let Some(flv) = flv {
        let mut stmt = conn.prepare(
            "SELECT id, ts, flavour, addon_id, name, kind, from_version, to_version, source, job_id, error \
             FROM activity WHERE flavour = ?1 ORDER BY ts DESC, id DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(rusqlite::params![flv, max_rows as i64], |r| {
            Ok(ActivityEntry {
                id: r.get(0)?,
                ts: r.get(1)?,
                flavour: r.get(2)?,
                addon_id: r.get(3)?,
                name: r.get(4)?,
                kind: r.get(5)?,
                from_version: r.get(6)?,
                to_version: r.get(7)?,
                source: r.get(8)?,
                job_id: r.get(9)?,
                error: r.get(10)?,
            })
        })?;
        for r in rows {
            entries.push(r?);
        }
    } else {
        let mut stmt = conn.prepare(
            "SELECT id, ts, flavour, addon_id, name, kind, from_version, to_version, source, job_id, error \
             FROM activity ORDER BY ts DESC, id DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(rusqlite::params![max_rows as i64], |r| {
            Ok(ActivityEntry {
                id: r.get(0)?,
                ts: r.get(1)?,
                flavour: r.get(2)?,
                addon_id: r.get(3)?,
                name: r.get(4)?,
                kind: r.get(5)?,
                from_version: r.get(6)?,
                to_version: r.get(7)?,
                source: r.get(8)?,
                job_id: r.get(9)?,
                error: r.get(10)?,
            })
        })?;
        for r in rows {
            entries.push(r?);
        }
    }
    Ok(entries)
}

pub fn clear_activity_records(conn: &rusqlite::Connection, flavour: Option<&str>) -> rusqlite::Result<()> {
    let flv = flavour.filter(|s| !s.trim().is_empty());
    if let Some(flv) = flv {
        conn.execute("DELETE FROM activity WHERE flavour = ?1", rusqlite::params![flv])?;
    } else {
        conn.execute("DELETE FROM activity", [])?;
    }
    Ok(())
}

pub fn prune_activity_retention(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    let cutoff = chrono::Utc::now() - chrono::Duration::days(ACTIVITY_RETENTION_DAYS);
    let cutoff_str = cutoff.to_rfc3339();

    conn.execute(
        "DELETE FROM activity WHERE ts < ?1 OR (datetime(ts) IS NOT NULL AND datetime(ts) < datetime(?1))",
        rusqlite::params![cutoff_str],
    )?;

    conn.execute(
        "DELETE FROM activity WHERE id NOT IN (SELECT id FROM activity ORDER BY ts DESC, id DESC LIMIT ?1)",
        rusqlite::params![ACTIVITY_RETENTION_MAX_ROWS as i64],
    )?;

    Ok(())
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
        conn
    }

    #[test]
    fn test_record_and_list_activity() {
        let conn = setup_test_db();
        let entry = ActivityEntry {
            id: "act-1".to_string(),
            ts: "2026-11-08T12:00:00Z".to_string(),
            flavour: "retail".to_string(),
            addon_id: "details".to_string(),
            name: "Details! Damage Meter".to_string(),
            kind: ActivityKind::Installed.as_str().to_string(),
            from_version: None,
            to_version: Some("11.0.2.12840".to_string()),
            source: Some("curseforge".to_string()),
            job_id: Some("job-1".to_string()),
            error: None,
        };

        record_activity(&conn, &entry).expect("record_activity should succeed");

        let records = list_activity_records(&conn, None, None).expect("list_activity_records should succeed");
        assert_eq!(records.len(), 1);
        let r = &records[0];
        assert_eq!(r.id, "act-1");
        assert_eq!(r.ts, "2026-11-08T12:00:00Z");
        assert_eq!(r.flavour, "retail");
        assert_eq!(r.addon_id, "details");
        assert_eq!(r.name, "Details! Damage Meter");
        assert_eq!(r.kind, "installed");
        assert_eq!(r.from_version, None);
        assert_eq!(r.to_version.as_deref(), Some("11.0.2.12840"));
        assert_eq!(r.source.as_deref(), Some("curseforge"));
        assert_eq!(r.job_id.as_deref(), Some("job-1"));
        assert_eq!(r.error, None);
    }

    #[test]
    fn test_filter_activity_by_flavour() {
        let conn = setup_test_db();
        let retail_entry = ActivityEntry {
            id: "act-retail".to_string(),
            ts: "2026-11-08T12:00:00Z".to_string(),
            flavour: "retail".to_string(),
            addon_id: "details".to_string(),
            name: "Details".to_string(),
            kind: "installed".to_string(),
            from_version: None,
            to_version: Some("1.0".to_string()),
            source: Some("curseforge".to_string()),
            job_id: None,
            error: None,
        };
        let classic_entry = ActivityEntry {
            id: "act-classic".to_string(),
            ts: "2026-11-08T13:00:00Z".to_string(),
            flavour: "classic_era".to_string(),
            addon_id: "questie".to_string(),
            name: "Questie".to_string(),
            kind: "updated".to_string(),
            from_version: Some("1.0".to_string()),
            to_version: Some("2.0".to_string()),
            source: Some("github".to_string()),
            job_id: None,
            error: None,
        };

        record_activity(&conn, &retail_entry).unwrap();
        record_activity(&conn, &classic_entry).unwrap();

        let all = list_activity_records(&conn, None, None).unwrap();
        assert_eq!(all.len(), 2);

        let retail_list = list_activity_records(&conn, Some("retail"), None).unwrap();
        assert_eq!(retail_list.len(), 1);
        assert_eq!(retail_list[0].id, "act-retail");
        assert_eq!(retail_list[0].flavour, "retail");

        let classic_list = list_activity_records(&conn, Some("classic_era"), None).unwrap();
        assert_eq!(classic_list.len(), 1);
        assert_eq!(classic_list[0].id, "act-classic");
        assert_eq!(classic_list[0].flavour, "classic_era");
    }

    #[test]
    fn test_clear_activity_records() {
        let conn = setup_test_db();
        let retail_entry = ActivityEntry {
            id: "act-1".to_string(),
            ts: "2026-11-08T12:00:00Z".to_string(),
            flavour: "retail".to_string(),
            addon_id: "details".to_string(),
            name: "Details".to_string(),
            kind: "installed".to_string(),
            from_version: None,
            to_version: None,
            source: None,
            job_id: None,
            error: None,
        };
        let classic_entry = ActivityEntry {
            id: "act-2".to_string(),
            ts: "2026-11-08T12:05:00Z".to_string(),
            flavour: "classic_era".to_string(),
            addon_id: "questie".to_string(),
            name: "Questie".to_string(),
            kind: "installed".to_string(),
            from_version: None,
            to_version: None,
            source: None,
            job_id: None,
            error: None,
        };

        record_activity(&conn, &retail_entry).unwrap();
        record_activity(&conn, &classic_entry).unwrap();

        clear_activity_records(&conn, Some("retail")).unwrap();
        let retail_list = list_activity_records(&conn, Some("retail"), None).unwrap();
        assert!(retail_list.is_empty());
        let classic_list = list_activity_records(&conn, Some("classic_era"), None).unwrap();
        assert_eq!(classic_list.len(), 1);

        clear_activity_records(&conn, None).unwrap();
        let all = list_activity_records(&conn, None, None).unwrap();
        assert!(all.is_empty());
    }

    #[test]
    fn test_prune_retention_row_limit() {
        let conn = setup_test_db();
        let now = chrono::Utc::now();

        conn.execute_batch("BEGIN;").unwrap();
        for i in 0..550 {
            let ts = (now - chrono::Duration::seconds(550 - i as i64)).to_rfc3339();
            conn.execute(
                "INSERT INTO activity (id, ts, flavour, addon_id, name, kind) VALUES (?1, ?2, 'retail', 'addon-1', 'Addon', 'installed')",
                rusqlite::params![format!("act-{:04}", i), ts],
            ).unwrap();
        }
        conn.execute_batch("COMMIT;").unwrap();

        let count_before: i64 = conn.query_row("SELECT COUNT(*) FROM activity", [], |r| r.get(0)).unwrap();
        assert_eq!(count_before, 550);

        prune_activity_retention(&conn).expect("prune_activity_retention should succeed");

        let count_after: i64 = conn.query_row("SELECT COUNT(*) FROM activity", [], |r| r.get(0)).unwrap();
        assert_eq!(count_after, 500);

        let remaining = list_activity_records(&conn, None, Some(600)).unwrap();
        assert_eq!(remaining.len(), 500);
        assert_eq!(remaining.first().unwrap().id, "act-0549");
        assert_eq!(remaining.last().unwrap().id, "act-0050");
    }

    #[test]
    fn test_prune_retention_days_limit() {
        let conn = setup_test_db();
        let now = chrono::Utc::now();

        let old_ts = (now - chrono::Duration::days(100)).to_rfc3339();
        let recent_ts = (now - chrono::Duration::days(10)).to_rfc3339();

        let old_entry = ActivityEntry {
            id: "act-old".to_string(),
            ts: old_ts,
            flavour: "retail".to_string(),
            addon_id: "details".to_string(),
            name: "Details".to_string(),
            kind: "installed".to_string(),
            from_version: None,
            to_version: None,
            source: None,
            job_id: None,
            error: None,
        };
        let recent_entry = ActivityEntry {
            id: "act-recent".to_string(),
            ts: recent_ts,
            flavour: "retail".to_string(),
            addon_id: "details".to_string(),
            name: "Details".to_string(),
            kind: "updated".to_string(),
            from_version: None,
            to_version: None,
            source: None,
            job_id: None,
            error: None,
        };

        conn.execute(
            "INSERT INTO activity (id, ts, flavour, addon_id, name, kind) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![old_entry.id, old_entry.ts, old_entry.flavour, old_entry.addon_id, old_entry.name, old_entry.kind],
        ).unwrap();
        conn.execute(
            "INSERT INTO activity (id, ts, flavour, addon_id, name, kind) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![recent_entry.id, recent_entry.ts, recent_entry.flavour, recent_entry.addon_id, recent_entry.name, recent_entry.kind],
        ).unwrap();

        let count_before: i64 = conn.query_row("SELECT COUNT(*) FROM activity", [], |r| r.get(0)).unwrap();
        assert_eq!(count_before, 2);

        prune_activity_retention(&conn).expect("prune_activity_retention should succeed");

        let remaining = list_activity_records(&conn, None, None).unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].id, "act-recent");
    }
}
