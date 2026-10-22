use std::collections::HashMap;
use std::sync::Mutex;
use crate::logging::append_app_log;

const CONNECTIVITY_BREAKER_THRESHOLD: u32 = 3;

#[derive(Default)]
pub struct HostBreaker {
    failure_streak: Mutex<HashMap<String, u32>>,
}

impl HostBreaker {
    pub fn new() -> Self {
        Self {
            failure_streak: Mutex::new(HashMap::new()),
        }
    }

    pub fn get_host_key(host_or_url: &str) -> String {
        if host_or_url.contains("://") {
            if let Ok(parsed) = reqwest::Url::parse(host_or_url) {
                if let Some(h) = parsed.host_str() {
                    return h.to_ascii_lowercase();
                }
            }
        }
        host_or_url.to_ascii_lowercase()
    }

    pub fn is_open(&self, host_key: &str) -> bool {
        let key = Self::get_host_key(host_key);
        let guard = self.failure_streak.lock().unwrap();
        guard.get(&key).copied().unwrap_or(0) >= CONNECTIVITY_BREAKER_THRESHOLD
    }

    pub fn assert_reachable(&self, host_key: &str) -> Result<(), String> {
        let key = Self::get_host_key(host_key);
        if self.is_open(&key) {
            Err(format!(
                "Skipped: {} did not answer {} requests in a row, so this run stops asking it. Check your internet connection.",
                key, CONNECTIVITY_BREAKER_THRESHOLD
            ))
        } else {
            Ok(())
        }
    }

    pub fn register_success(&self, host_key: &str) {
        let key = Self::get_host_key(host_key);
        let mut guard = self.failure_streak.lock().unwrap();
        guard.insert(key, 0);
    }

    pub fn register_connectivity_failure(&self, host_key: &str) {
        let key = Self::get_host_key(host_key);
        let mut guard = self.failure_streak.lock().unwrap();
        let current = guard.entry(key.clone()).or_insert(0);
        *current += 1;
        let streak = *current;
        if streak == CONNECTIVITY_BREAKER_THRESHOLD {
            append_app_log(
                "WARN",
                &format!(
                    "{} did not answer {} requests in a row - skipping it for the rest of this run (it is tried again on the next run)",
                    key, streak
                ),
            );
        }
    }

    pub fn register_http_response(&self, host_key: &str) {
        // Any HTTP response (even 4xx/5xx) means host is reachable
        self.register_success(host_key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_host_breaker_trips_after_3_failures_and_resets() {
        let breaker = HostBreaker::new();
        let host = "https://www.curseforge.com/api/test";

        assert!(!breaker.is_open(host));
        assert!(breaker.assert_reachable(host).is_ok());

        breaker.register_connectivity_failure(host);
        assert!(!breaker.is_open(host));

        breaker.register_connectivity_failure(host);
        assert!(!breaker.is_open(host));

        breaker.register_connectivity_failure(host);
        assert!(breaker.is_open(host));
        assert!(breaker.assert_reachable(host).is_err());

        // HTTP response resets
        breaker.register_http_response(host);
        assert!(!breaker.is_open(host));
        assert!(breaker.assert_reachable(host).is_ok());
    }
}
