use rusqlite::{params, Connection, OptionalExtension, Result};

pub fn parse_build_tuple(v: &str) -> Option<Vec<u32>> {
    let chars: Vec<char> = v.chars().collect();
    let n = chars.len();
    let mut i = 0;

    while i < n {
        if chars[i].is_ascii_digit() {
            let mut curr = i;
            let mut parts = Vec::new();

            loop {
                let d_start = curr;
                while curr < n && chars[curr].is_ascii_digit() {
                    curr += 1;
                }
                let segment: String = chars[d_start..curr].iter().collect();
                if let Ok(num) = segment.parse::<u32>() {
                    parts.push(num);
                } else {
                    break;
                }

                if curr < n && chars[curr] == '.' && curr + 1 < n && chars[curr + 1].is_ascii_digit() {
                    curr += 1;
                } else {
                    break;
                }
            }

            if parts.len() >= 2 || (parts.len() == 1 && v.trim().chars().all(|c| c.is_ascii_digit())) {
                return Some(parts);
            }
            i = curr;
        } else {
            i += 1;
        }
    }

    None
}

pub fn is_build_strictly_newer(client: &[u32], target: &[u32]) -> bool {
    target > client
}

pub fn is_update_held_back(
    flavour: &str,
    client_build: Option<&str>,
    target_game_versions: &[String],
    ignored_until_build: Option<&str>,
) -> Option<String> {
    let flv = flavour.trim().to_ascii_lowercase();
    if flv == "ptr" || flv == "xptr" || flv == "beta" {
        return None;
    }

    let client_str = match client_build {
        Some(s) if !s.trim().is_empty() => s.trim(),
        _ => return None,
    };
    let client_tuple = match parse_build_tuple(client_str) {
        Some(t) => t,
        None => return None,
    };

    if target_game_versions.is_empty() {
        return None;
    }

    if let Some(ignored) = ignored_until_build {
        let ignored_trimmed = ignored.trim();
        if !ignored_trimmed.is_empty() {
            if ignored_trimmed == client_str || parse_build_tuple(ignored_trimmed) == Some(client_tuple.clone()) {
                return None;
            }
        }
    }

    let mut numeric_targets = Vec::new();
    for target in target_game_versions {
        if let Some(tuple) = parse_build_tuple(target) {
            numeric_targets.push((target.as_str(), tuple));
        }
    }

    if numeric_targets.is_empty() {
        return None;
    }

    let all_strictly_newer = numeric_targets
        .iter()
        .all(|(_, tuple)| is_build_strictly_newer(&client_tuple, tuple));

    if !all_strictly_newer {
        return None;
    }

    let targets_display = numeric_targets
        .iter()
        .map(|(s, _)| *s)
        .collect::<Vec<_>>()
        .join(", ");

    Some(format!(
        "Built for newer game version ({}, client is {})",
        targets_display, client_str
    ))
}

pub fn set_ignored_until_build(conn: &Connection, addon_id: &str, build: &str) -> Result<()> {
    conn.execute(
        "UPDATE addons SET ignored_until_build = ?1 WHERE id = ?2",
        params![build, addon_id],
    )?;
    Ok(())
}

pub fn get_ignored_until_build(conn: &Connection, addon_id: &str) -> Result<Option<String>> {
    conn.query_row(
        "SELECT ignored_until_build FROM addons WHERE id = ?1",
        params![addon_id],
        |r| r.get(0),
    )
    .optional()
    .map(|opt| opt.flatten())
}

pub fn clear_ignored_until_build(conn: &Connection, addon_id: &str) -> Result<()> {
    conn.execute(
        "UPDATE addons SET ignored_until_build = NULL WHERE id = ?1",
        params![addon_id],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_numeric_tuple_parsing() {
        assert_eq!(parse_build_tuple("12.1.0.69587"), Some(vec![12, 1, 0, 69587]));
        assert_eq!(parse_build_tuple("1.60.1"), Some(vec![1, 60, 1]));
        assert_eq!(parse_build_tuple("The War Within (11.0.2)"), Some(vec![11, 0, 2]));
        assert_eq!(parse_build_tuple("The War Within"), None);
        assert_eq!(parse_build_tuple("Dragonflight"), None);
        assert_eq!(parse_build_tuple("v11.0.5"), Some(vec![11, 0, 5]));
        assert_eq!(parse_build_tuple(""), None);
    }

    #[test]
    fn test_strict_newer_comparison() {
        assert!(is_build_strictly_newer(&[12, 1, 0], &[12, 1, 5]));
        assert!(!is_build_strictly_newer(&[12, 1, 0], &[12, 1, 0]));
        assert!(!is_build_strictly_newer(&[12, 1, 5], &[12, 1, 0]));
    }

    #[test]
    fn test_holdback_decision_all_newer_held() {
        let targets = vec!["12.1.5".to_string(), "12.2.0".to_string()];
        let res = is_update_held_back("retail", Some("12.1.0"), &targets, None);
        assert!(res.is_some());
    }

    #[test]
    fn test_holdback_decision_mixed_not_held() {
        let targets = vec!["12.1.0".to_string(), "12.1.5".to_string()];
        let res = is_update_held_back("retail", Some("12.1.0"), &targets, None);
        assert_eq!(res, None);
    }

    #[test]
    fn test_holdback_test_realms_never_held() {
        let targets = vec!["12.1.5".to_string(), "12.2.0".to_string()];
        assert_eq!(is_update_held_back("beta", Some("12.1.0"), &targets, None), None);
        assert_eq!(is_update_held_back("ptr", Some("12.1.0"), &targets, None), None);
        assert_eq!(is_update_held_back("xptr", Some("12.1.0"), &targets, None), None);
    }

    #[test]
    fn test_ignore_until_build_lapses() {
        let targets = vec!["12.1.5".to_string(), "12.2.0".to_string()];
        assert_eq!(
            is_update_held_back("retail", Some("12.1.0"), &targets, Some("12.1.0")),
            None
        );
        let res = is_update_held_back("retail", Some("12.1.1"), &targets, Some("12.1.0"));
        assert!(res.is_some());
    }

    #[test]
    fn test_holdback_forever_client_matching() {
        let held_target = vec!["1.60.2".to_string()];
        let not_held_target = vec!["1.60.1".to_string()];
        assert!(is_update_held_back("forever", Some("1.60.1"), &held_target, None).is_some());
        assert_eq!(
            is_update_held_back("forever", Some("1.60.1"), &not_held_target, None),
            None
        );
    }

    #[test]
    fn test_fail_open_edge_cases() {
        let targets = vec!["12.1.5".to_string()];
        assert_eq!(is_update_held_back("retail", None, &targets, None), None);
        assert_eq!(is_update_held_back("retail", Some("not_a_version"), &targets, None), None);
        assert_eq!(is_update_held_back("retail", Some("12.1.0"), &[], None), None);
        let labels_only = vec!["The War Within".to_string(), "Dragonflight".to_string()];
        assert_eq!(is_update_held_back("retail", Some("12.1.0"), &labels_only, None), None);
        let mixed_labels = vec!["The War Within".to_string(), "12.1.5".to_string()];
        assert!(is_update_held_back("retail", Some("12.1.0"), &mixed_labels, None).is_some());
    }

    #[test]
    fn test_db_ignored_until_build() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("
            CREATE TABLE addons (
                id TEXT PRIMARY KEY,
                ignored_until_build TEXT
            );
            INSERT INTO addons (id, ignored_until_build) VALUES ('test-addon', NULL);
        ").unwrap();

        assert_eq!(get_ignored_until_build(&conn, "test-addon").unwrap(), None);

        set_ignored_until_build(&conn, "test-addon", "12.1.0").unwrap();
        assert_eq!(
            get_ignored_until_build(&conn, "test-addon").unwrap(),
            Some("12.1.0".to_string())
        );

        clear_ignored_until_build(&conn, "test-addon").unwrap();
        assert_eq!(get_ignored_until_build(&conn, "test-addon").unwrap(), None);

        assert_eq!(get_ignored_until_build(&conn, "nonexistent").unwrap(), None);
    }
}
