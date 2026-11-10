use std::sync::atomic::{AtomicBool, Ordering};

static FORCE_IPV4: AtomicBool = AtomicBool::new(false);

pub fn set_force_ipv4(on: bool) {
    FORCE_IPV4.store(on, Ordering::Relaxed);
}

pub fn force_ipv4() -> bool {
    FORCE_IPV4.load(Ordering::Relaxed)
}

/// With "IPv4 only" on, outgoing connections bind to an IPv4 local address, so a broken IPv6 route is never tried.
pub fn apply(builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
    if force_ipv4() {
        builder.local_address(std::net::IpAddr::V4(std::net::Ipv4Addr::UNSPECIFIED))
    } else {
        builder
    }
}

/// Reads the settings row `forceIpv4` (JSON text, `true` or `false`). A missing row, a read error or any other value means off.
pub fn init_from_settings(conn: &rusqlite::Connection) {
    let on = conn
        .query_row("SELECT value FROM settings WHERE key = 'forceIpv4'", [], |r| r.get::<_, Option<String>>(0))
        .ok()
        .flatten()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(text.trim()).ok())
        .and_then(|value| value.as_bool())
        .unwrap_or(false);
    set_force_ipv4(on);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // The flag is process wide, so the tests that flip it take turns.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn settings_db(value: Option<&str>) -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)", []).unwrap();
        if let Some(v) = value {
            conn.execute("INSERT INTO settings (key, value) VALUES ('forceIpv4', ?1)", rusqlite::params![v]).unwrap();
        }
        conn
    }

    #[test]
    fn set_and_read_back() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_force_ipv4(true);
        assert!(force_ipv4());
        set_force_ipv4(false);
        assert!(!force_ipv4());
    }

    #[test]
    fn apply_builds_a_client_in_both_modes() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_force_ipv4(false);
        assert!(apply(reqwest::Client::builder()).build().is_ok());
        set_force_ipv4(true);
        assert!(apply(reqwest::Client::builder()).build().is_ok());
        set_force_ipv4(false);
    }

    #[test]
    fn init_reads_true_false_and_ignores_everything_else() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());

        set_force_ipv4(false);
        init_from_settings(&settings_db(Some("true")));
        assert!(force_ipv4());

        init_from_settings(&settings_db(Some("false")));
        assert!(!force_ipv4());

        set_force_ipv4(true);
        init_from_settings(&settings_db(None));
        assert!(!force_ipv4(), "a missing row means off");

        set_force_ipv4(true);
        init_from_settings(&settings_db(Some("garbage")));
        assert!(!force_ipv4(), "text that is not JSON means off");

        set_force_ipv4(true);
        init_from_settings(&settings_db(Some("\"yes\"")));
        assert!(!force_ipv4(), "a JSON value that is not a bool means off");

        set_force_ipv4(true);
        let no_table = rusqlite::Connection::open_in_memory().unwrap();
        init_from_settings(&no_table);
        assert!(!force_ipv4(), "a read error means off");
    }
}
