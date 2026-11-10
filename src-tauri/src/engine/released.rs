use chrono::{DateTime, NaiveDate, NaiveDateTime, SecondsFormat, TimeZone, Utc};
use rusqlite::{params, Connection};

fn as_utc_text(naive: NaiveDateTime) -> String {
    Utc.from_utc_datetime(&naive).to_rfc3339_opts(SecondsFormat::Secs, true)
}

/// One release date as RFC 3339 UTC with whole seconds (2026-10-29T22:22:25Z), or None when it cannot be read.
/// Accepts the shapes the providers send: CurseForge 2026-10-29T22:22:25.113Z, Wago 2026-11-08T20:38:49.000000Z,
/// Tukui 2026-11-03, anything RFC 3339 with an offset, and a timestamp without a zone (read as UTC).
pub fn normalize_release_date(raw: &str) -> Option<String> {
    let text = raw.trim();
    if text.is_empty() {
        return None;
    }
    if let Ok(parsed) = DateTime::parse_from_rfc3339(text) {
        return Some(parsed.with_timezone(&Utc).to_rfc3339_opts(SecondsFormat::Secs, true));
    }
    if let Ok(day) = NaiveDate::parse_from_str(text, "%Y-%m-%d") {
        return day.and_hms_opt(0, 0, 0).map(as_utc_text);
    }
    for format in ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M:%S%.f"] {
        if let Ok(naive) = NaiveDateTime::parse_from_str(text, format) {
            return Some(as_utc_text(naive));
        }
    }
    None
}

/// Stores the release date of the INSTALLED file. A date that cannot be read, or none at all, leaves the stored value alone.
pub fn store_released_at(conn: &Connection, addon_id: &str, raw: Option<&str>) {
    let Some(normalized) = raw.and_then(normalize_release_date) else {
        return;
    };
    let _ = conn.execute("UPDATE addons SET released_at = ?1 WHERE id = ?2", params![normalized, addon_id]);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::migrate::run_migrations;

    #[test]
    fn the_provider_shapes_normalize_to_whole_second_utc() {
        assert_eq!(normalize_release_date("2026-10-29T22:22:25.113Z").unwrap(), "2026-10-29T22:22:25Z");
        assert_eq!(normalize_release_date("2026-11-08T20:38:49.000000Z").unwrap(), "2026-11-08T20:38:49Z");
        assert_eq!(normalize_release_date("2026-11-03").unwrap(), "2026-11-03T00:00:00Z");
        assert_eq!(normalize_release_date("  2026-11-03  ").unwrap(), "2026-11-03T00:00:00Z");
    }

    #[test]
    fn an_offset_is_converted_to_utc_and_a_missing_zone_is_read_as_utc() {
        assert_eq!(normalize_release_date("2026-11-08T22:38:49+02:00").unwrap(), "2026-11-08T20:38:49Z");
        assert_eq!(normalize_release_date("2026-11-08T20:38:49-05:00").unwrap(), "2026-11-09T01:38:49Z");
        assert_eq!(normalize_release_date("2026-11-08T20:38:49").unwrap(), "2026-11-08T20:38:49Z");
        assert_eq!(normalize_release_date("2026-11-08 20:38:49.5").unwrap(), "2026-11-08T20:38:49Z");
    }

    #[test]
    fn garbage_gives_none() {
        for text in ["", "   ", "yesterday", "2026-13-45", "11/08/2026", "2026-11"] {
            assert!(normalize_release_date(text).is_none(), "{:?}", text);
        }
    }

    fn db_with_addon() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        run_migrations(&mut conn).unwrap();
        conn.execute("INSERT INTO addons (id, flavour, name) VALUES ('a1', 'retail', 'One')", []).unwrap();
        conn
    }

    fn stored(conn: &Connection) -> Option<String> {
        conn.query_row("SELECT released_at FROM addons WHERE id = 'a1'", [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn store_writes_the_normalized_date() {
        let conn = db_with_addon();
        store_released_at(&conn, "a1", Some("2026-10-29T22:22:25.113Z"));
        assert_eq!(stored(&conn).unwrap(), "2026-10-29T22:22:25Z");
    }

    #[test]
    fn a_stored_value_is_never_replaced_by_nothing_or_by_garbage() {
        let conn = db_with_addon();
        store_released_at(&conn, "a1", Some("2026-10-29T22:22:25Z"));
        store_released_at(&conn, "a1", None);
        store_released_at(&conn, "a1", Some("not a date"));
        assert_eq!(stored(&conn).unwrap(), "2026-10-29T22:22:25Z");
        store_released_at(&conn, "a1", Some("2026-11-08T20:38:49.000000Z"));
        assert_eq!(stored(&conn).unwrap(), "2026-11-08T20:38:49Z");
    }

    #[test]
    fn a_missing_addon_is_not_an_error() {
        let conn = db_with_addon();
        store_released_at(&conn, "ghost", Some("2026-10-29T22:22:25Z"));
        assert_eq!(stored(&conn), None);
    }
}
