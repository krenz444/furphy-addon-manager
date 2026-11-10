use std::collections::HashMap;
use rusqlite::{params, Connection, OptionalExtension};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupRow {
    pub id: String,
    pub name: String,
    pub sort_order: i64,
    pub member_count: i64,
}

const MAX_NAME_CHARS: usize = 40;

fn clean_name(name: &str) -> Result<String, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("Enter a name".to_string());
    }
    if trimmed.chars().count() > MAX_NAME_CHARS {
        return Err(format!("Use at most {} characters", MAX_NAME_CHARS));
    }
    Ok(trimmed.to_string())
}

fn group_exists(conn: &Connection, group_id: &str) -> Result<bool, String> {
    conn.query_row("SELECT COUNT(*) > 0 FROM addon_groups WHERE id = ?1", params![group_id], |r| r.get::<_, bool>(0))
        .map_err(|e| e.to_string())
}

/// True when another group already has this name, ignoring case. `except` leaves one group out (the one being renamed).
fn name_taken(conn: &Connection, name: &str, except: Option<&str>) -> Result<bool, String> {
    let found: Option<String> = conn
        .query_row(
            "SELECT id FROM addon_groups WHERE name = ?1 COLLATE NOCASE AND (?2 IS NULL OR id <> ?2) LIMIT 1",
            params![name, except],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    Ok(found.is_some())
}

pub fn set_favourite(conn: &Connection, addon_id: &str, favourite: bool) -> rusqlite::Result<()> {
    conn.execute("UPDATE addons SET favourite = ?1 WHERE id = ?2", params![favourite as i64, addon_id])?;
    Ok(())
}

pub fn list_groups(conn: &Connection) -> rusqlite::Result<Vec<GroupRow>> {
    let mut stmt = conn.prepare(
        "SELECT g.id, g.name, g.sort_order, COUNT(m.addon_id) \
         FROM addon_groups g LEFT JOIN addon_group_members m ON m.group_id = g.id \
         GROUP BY g.id ORDER BY g.sort_order ASC, g.name COLLATE NOCASE ASC",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(GroupRow {
            id: r.get(0)?,
            name: r.get(1)?,
            sort_order: r.get(2)?,
            member_count: r.get(3)?,
        })
    })?;
    rows.collect()
}

pub fn create_group(conn: &Connection, name: &str) -> Result<GroupRow, String> {
    let name = clean_name(name)?;
    if name_taken(conn, &name, None)? {
        return Err(format!("A group called {} already exists", name));
    }
    let id = format!("grp_{}", &uuid::Uuid::new_v4().simple().to_string()[..12]);
    let sort_order: i64 = conn
        .query_row("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM addon_groups", [], |r| r.get(0))
        .map_err(|e| e.to_string())?;
    let created_at = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    conn.execute(
        "INSERT INTO addon_groups (id, name, sort_order, created_at) VALUES (?1, ?2, ?3, ?4)",
        params![id, name, sort_order, created_at],
    )
    .map_err(|e| e.to_string())?;
    Ok(GroupRow { id, name, sort_order, member_count: 0 })
}

pub fn rename_group(conn: &Connection, group_id: &str, name: &str) -> Result<(), String> {
    let name = clean_name(name)?;
    if !group_exists(conn, group_id)? {
        return Err("That group no longer exists".to_string());
    }
    if name_taken(conn, &name, Some(group_id))? {
        return Err(format!("A group called {} already exists", name));
    }
    conn.execute("UPDATE addon_groups SET name = ?1 WHERE id = ?2", params![name, group_id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Removes the group and its memberships; the addons stay.
pub fn delete_group(conn: &Connection, group_id: &str) -> Result<(), String> {
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    tx.execute("DELETE FROM addon_group_members WHERE group_id = ?1", params![group_id])
        .map_err(|e| e.to_string())?;
    let removed = tx
        .execute("DELETE FROM addon_groups WHERE id = ?1", params![group_id])
        .map_err(|e| e.to_string())?;
    if removed == 0 {
        return Err("That group no longer exists".to_string());
    }
    tx.commit().map_err(|e| e.to_string())
}

pub fn set_addon_group(conn: &Connection, addon_id: &str, group_id: &str, member: bool) -> Result<(), String> {
    if !member {
        conn.execute(
            "DELETE FROM addon_group_members WHERE group_id = ?1 AND addon_id = ?2",
            params![group_id, addon_id],
        )
        .map_err(|e| e.to_string())?;
        return Ok(());
    }
    if !group_exists(conn, group_id)? {
        return Err("That group no longer exists".to_string());
    }
    let addon_exists: bool = conn
        .query_row("SELECT COUNT(*) > 0 FROM addons WHERE id = ?1", params![addon_id], |r| r.get(0))
        .map_err(|e| e.to_string())?;
    if !addon_exists {
        return Err("That addon no longer exists".to_string());
    }
    conn.execute(
        "INSERT OR IGNORE INTO addon_group_members (group_id, addon_id) VALUES (?1, ?2)",
        params![group_id, addon_id],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// Group ids per addon id, in the order the groups are listed.
pub fn group_ids_by_addon(conn: &Connection) -> rusqlite::Result<HashMap<String, Vec<String>>> {
    let mut stmt = conn.prepare(
        "SELECT m.addon_id, m.group_id FROM addon_group_members m \
         JOIN addon_groups g ON g.id = m.group_id \
         ORDER BY g.sort_order ASC, g.name COLLATE NOCASE ASC",
    )?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
    let mut map: HashMap<String, Vec<String>> = HashMap::new();
    for row in rows {
        let (addon_id, group_id) = row?;
        map.entry(addon_id).or_default().push(group_id);
    }
    Ok(map)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::migrate::run_migrations;

    fn db() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        run_migrations(&mut conn).unwrap();
        for (id, name) in [("a1", "One"), ("a2", "Two"), ("a3", "Three")] {
            conn.execute("INSERT INTO addons (id, flavour, name) VALUES (?1, 'retail', ?2)", params![id, name]).unwrap();
        }
        conn
    }

    #[test]
    fn favourite_toggles_and_a_missing_addon_is_not_an_error() {
        let conn = db();
        set_favourite(&conn, "a1", true).unwrap();
        let value: i64 = conn.query_row("SELECT favourite FROM addons WHERE id = 'a1'", [], |r| r.get(0)).unwrap();
        assert_eq!(value, 1);
        set_favourite(&conn, "a1", false).unwrap();
        let value: i64 = conn.query_row("SELECT favourite FROM addons WHERE id = 'a1'", [], |r| r.get(0)).unwrap();
        assert_eq!(value, 0);
        assert!(set_favourite(&conn, "nope", true).is_ok());
    }

    #[test]
    fn create_trims_numbers_and_lists_in_order() {
        let conn = db();
        let raid = create_group(&conn, "  Raid  ").unwrap();
        assert_eq!(raid.name, "Raid");
        assert!(raid.id.starts_with("grp_") && raid.id.len() == 16);
        let ui = create_group(&conn, "Interface").unwrap();
        assert_eq!(raid.sort_order, 0);
        assert_eq!(ui.sort_order, 1);
        let listed = list_groups(&conn).unwrap();
        assert_eq!(listed.iter().map(|g| g.name.as_str()).collect::<Vec<_>>(), vec!["Raid", "Interface"]);
        assert!(listed.iter().all(|g| g.member_count == 0));
    }

    #[test]
    fn create_refuses_blank_long_and_duplicate_names_ignoring_case() {
        let conn = db();
        assert_eq!(create_group(&conn, "   ").unwrap_err(), "Enter a name");
        assert!(create_group(&conn, &"x".repeat(41)).unwrap_err().contains("at most 40"));
        assert!(create_group(&conn, &"x".repeat(40)).is_ok());
        create_group(&conn, "Raid").unwrap();
        assert_eq!(create_group(&conn, "RAID").unwrap_err(), "A group called RAID already exists");
    }

    #[test]
    fn rename_checks_conflicts_but_allows_a_case_only_change() {
        let conn = db();
        let raid = create_group(&conn, "Raid").unwrap();
        let ui = create_group(&conn, "Interface").unwrap();
        rename_group(&conn, &raid.id, "RAID").unwrap();
        assert_eq!(list_groups(&conn).unwrap()[0].name, "RAID");
        assert_eq!(rename_group(&conn, &ui.id, "raid").unwrap_err(), "A group called raid already exists");
        assert_eq!(rename_group(&conn, "grp_missing", "Anything").unwrap_err(), "That group no longer exists");
        assert_eq!(rename_group(&conn, &ui.id, "  ").unwrap_err(), "Enter a name");
    }

    #[test]
    fn membership_is_idempotent_counted_and_removed_with_the_group() {
        let conn = db();
        let raid = create_group(&conn, "Raid").unwrap();
        set_addon_group(&conn, "a1", &raid.id, true).unwrap();
        set_addon_group(&conn, "a1", &raid.id, true).unwrap();
        set_addon_group(&conn, "a2", &raid.id, true).unwrap();
        assert_eq!(list_groups(&conn).unwrap()[0].member_count, 2);

        set_addon_group(&conn, "a2", &raid.id, false).unwrap();
        set_addon_group(&conn, "a2", &raid.id, false).unwrap();
        assert_eq!(list_groups(&conn).unwrap()[0].member_count, 1);

        assert_eq!(set_addon_group(&conn, "a1", "grp_missing", true).unwrap_err(), "That group no longer exists");
        assert_eq!(set_addon_group(&conn, "missing", &raid.id, true).unwrap_err(), "That addon no longer exists");

        delete_group(&conn, &raid.id).unwrap();
        let left: i64 = conn.query_row("SELECT COUNT(*) FROM addon_group_members", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 0);
        let addons: i64 = conn.query_row("SELECT COUNT(*) FROM addons", [], |r| r.get(0)).unwrap();
        assert_eq!(addons, 3, "deleting a group never deletes addons");
        assert_eq!(delete_group(&conn, &raid.id).unwrap_err(), "That group no longer exists");
    }

    #[test]
    fn group_ids_by_addon_follow_the_group_order() {
        let conn = db();
        let raid = create_group(&conn, "Raid").unwrap();
        let ui = create_group(&conn, "Interface").unwrap();
        set_addon_group(&conn, "a1", &ui.id, true).unwrap();
        set_addon_group(&conn, "a1", &raid.id, true).unwrap();
        set_addon_group(&conn, "a3", &ui.id, true).unwrap();
        let map = group_ids_by_addon(&conn).unwrap();
        assert_eq!(map.get("a1").unwrap(), &vec![raid.id.clone(), ui.id.clone()]);
        assert_eq!(map.get("a3").unwrap(), &vec![ui.id.clone()]);
        assert!(!map.contains_key("a2"));
    }
}
