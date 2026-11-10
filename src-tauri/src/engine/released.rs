// Stub, replaced by the feature lane.

pub fn normalize_release_date(_raw: &str) -> Option<String> {
    None
}

pub fn store_released_at(_conn: &rusqlite::Connection, _addon_id: &str, _raw: Option<&str>) {}
