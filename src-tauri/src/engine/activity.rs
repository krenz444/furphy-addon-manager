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

#[derive(Debug, Clone, Serialize, Deserialize)]
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
    let _ = conn.execute(
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
    );
    let _ = prune_activity_retention(conn);
    Ok(())
}

pub fn list_activity_records(
    conn: &rusqlite::Connection,
    flavour: Option<&str>,
    limit: Option<usize>,
) -> rusqlite::Result<Vec<ActivityEntry>> {
    let max_rows = limit.unwrap_or(100);
    let mut entries = Vec::new();
    if let Some(flv) = flavour {
        let mut stmt = conn.prepare(
            "SELECT id, ts, flavour, addon_id, name, kind, from_version, to_version, source, job_id, error \
             FROM activity WHERE flavour = ?1 ORDER BY ts DESC LIMIT ?2",
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
             FROM activity ORDER BY ts DESC LIMIT ?1",
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
    if let Some(flv) = flavour {
        conn.execute("DELETE FROM activity WHERE flavour = ?1", rusqlite::params![flv])?;
    } else {
        conn.execute("DELETE FROM activity", [])?;
    }
    Ok(())
}

pub fn prune_activity_retention(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    let _ = conn.execute(
        "DELETE FROM activity WHERE id NOT IN (SELECT id FROM activity ORDER BY ts DESC LIMIT ?1)",
        rusqlite::params![ACTIVITY_RETENTION_MAX_ROWS as i64],
    );
    Ok(())
}
