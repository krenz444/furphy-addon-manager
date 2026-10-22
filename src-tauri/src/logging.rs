use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use chrono::Utc;
use crate::paths::get_data_dir;

pub fn redact_text(input: &str, sensitive_tokens: &[&str]) -> String {
    let mut result = input.to_string();
    for token in sensitive_tokens {
        if !token.trim().is_empty() {
            result = result.replace(token, "[REDACTED]");
        }
    }
    // Also scrub standard ghp_ pattern if present
    if let Some(start) = result.find("ghp_") {
        let remainder = &result[start..];
        let token_len = remainder.find(|c: char| !c.is_alphanumeric()).unwrap_or(remainder.len());
        let full_token = &remainder[..token_len];
        result = result.replace(full_token, "[REDACTED_GH_TOKEN]");
    }
    result
}

pub fn append_app_log(level: &str, message: &str) {
    let log_path = get_data_dir().join("app.log");
    let timestamp = Utc::now().to_rfc3339();
    let redacted = redact_text(message, &[]);
    let line = format!("[{}] [{}] {}\n", timestamp, level, redacted);

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&log_path) {
        let _ = file.write_all(line.as_bytes());
    }
}

pub fn get_app_log_path() -> PathBuf {
    get_data_dir().join("app.log")
}
