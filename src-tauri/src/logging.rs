use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use chrono::{Local, Utc};
use crate::paths::get_data_dir;

const LOG_ROTATION_MAX_BYTES: u64 = 2 * 1024 * 1024; // 2 MB

pub fn redact_text(input: &str) -> String {
    if input.is_empty() {
        return String::new();
    }
    let mut text = input.to_string();

    // Redact github_pat_[A-Za-z0-9_]{8,}
    let mut i = 0;
    while let Some(pos) = text[i..].find("github_pat_") {
        let abs_pos = i + pos;
        let start = abs_pos + "github_pat_".len();
        let end = text[start..]
            .find(|c: char| !c.is_ascii_alphanumeric() && c != '_')
            .map(|offset| start + offset)
            .unwrap_or(text.len());
        if end - start >= 8 {
            text = format!(

                "{}github_pat_***REDACTED***{}",
                &text[..abs_pos],
                &text[end..]
            );
            i = abs_pos + "github_pat_***REDACTED***".len();
        } else {
            i = end;
        }
    }

    // Redact gh[pousr]_[A-Za-z0-9]{8,}
    let prefixes = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"];
    for prefix in &prefixes {
        let mut idx = 0;
        while let Some(pos) = text[idx..].find(prefix) {
            let abs_pos = idx + pos;
            let start = abs_pos + prefix.len();
            let end = text[start..]
                .find(|c: char| !c.is_ascii_alphanumeric())
                .map(|offset| start + offset)
                .unwrap_or(text.len());
            if end - start >= 8 {
                text = format!(
                    "{}gh?_***REDACTED***{}",
                    &text[..abs_pos],
                    &text[end..]
                );
                idx = abs_pos + "gh?_***REDACTED***".len();
            } else {
                idx = end;
            }
        }
    }

    text
}

fn rotate_if_needed(path: &PathBuf) {
    if let Ok(meta) = fs::metadata(path) {
        if meta.len() >= LOG_ROTATION_MAX_BYTES {
            let rotated = path.with_extension(format!(
                "{}.1",
                path.extension().and_then(|s| s.to_str()).unwrap_or("log")
            ));
            let _ = fs::remove_file(&rotated);
            let _ = fs::rename(path, rotated);
        }
    }
}

pub fn append_app_log(level: &str, message: &str) {
    let log_path = get_data_dir().join("app.log");
    rotate_if_needed(&log_path);
    let timestamp = Utc::now().to_rfc3339();
    let redacted = redact_text(message);
    let line = format!("[{}] [{}] {}\n", timestamp, level, redacted);

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&log_path) {
        let _ = file.write_all(line.as_bytes());
    }
}

pub fn append_sync_log(flavour: Option<&str>, level: &str, message: &str) {
    let log_path = get_data_dir().join("sync.log");
    rotate_if_needed(&log_path);
    let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
    let flavour_prefix = match flavour {
        Some(f) if !f.is_empty() => format!("[{}] ", f),
        _ => String::new(),
    };
    let raw_line = format!("{} [{}] {}{}", timestamp, level, flavour_prefix, message);
    let redacted_line = format!("{}\n", redact_text(&raw_line));

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&log_path) {
        let _ = file.write_all(redacted_line.as_bytes());
    }
}

pub fn write_last_run(content: &str) {
    let path = get_data_dir().join("last-run.txt");
    let redacted = redact_text(content);
    let _ = fs::write(&path, redacted);
}

pub fn get_app_log_path() -> PathBuf {
    get_data_dir().join("app.log")
}

pub fn get_sync_log_path() -> PathBuf {
    get_data_dir().join("sync.log")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_redaction_github_pat() {
        let msg = "Config loaded with github_pat_TESTONLY_0000 key";
        let redacted = redact_text(msg);
        assert_eq!(redacted, "Config loaded with github_pat_***REDACTED*** key");
    }

    #[test]
    fn test_redaction_ghp() {
        let msg = "Token ghp_1234567890abcdef is secret";
        let redacted = redact_text(msg);
        assert_eq!(redacted, "Token gh?_***REDACTED*** is secret");
    }

    #[test]
    fn test_short_token_not_redacted() {
        let msg = "Prefix ghp_short is not a real token";
        let redacted = redact_text(msg);
        assert_eq!(redacted, msg);
    }
}
