use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::logging::append_app_log;

const CONNECTIVITY_BREAKER_THRESHOLD: u32 = 3;
const DEFAULT_BREAKER_COOLDOWN: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Default)]
struct HostState {
    failure_streak: u32,
    opened_at: Option<Instant>,
}

pub struct HostBreaker {
    hosts: Mutex<HashMap<String, HostState>>,
    cooldown: Duration,
}

impl Default for HostBreaker {
    fn default() -> Self {
        Self::new()
    }
}

impl HostBreaker {
    pub fn new() -> Self {
        Self::with_cooldown(DEFAULT_BREAKER_COOLDOWN)
    }

    pub fn with_cooldown(cooldown: Duration) -> Self {
        Self {
            hosts: Mutex::new(HashMap::new()),
            cooldown,
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

    /// Half-open decay: once the cooldown window elapses after tripping,
    /// lowers the streak to `threshold - 1` so one probe attempt is allowed
    /// and a subsequent failure immediately re-opens the circuit.
    fn apply_cooldown_decay(&self, state: &mut HostState) {
        if state.failure_streak >= CONNECTIVITY_BREAKER_THRESHOLD {
            if let Some(opened_at) = state.opened_at {
                if opened_at.elapsed() >= self.cooldown {
                    state.failure_streak = CONNECTIVITY_BREAKER_THRESHOLD.saturating_sub(1);
                    state.opened_at = None;
                }
            }
        }
    }

    pub fn is_open(&self, host_key: &str) -> bool {
        let key = Self::get_host_key(host_key);
        let mut guard = self.hosts.lock().unwrap_or_else(|e| e.into_inner());
        let Some(state) = guard.get_mut(&key) else {
            return false;
        };
        self.apply_cooldown_decay(state);
        state.failure_streak >= CONNECTIVITY_BREAKER_THRESHOLD
    }

    pub fn assert_reachable(&self, host_key: &str) -> Result<(), String> {
        let key = Self::get_host_key(host_key);
        if self.is_open(&key) {
            Err(format!(
                "Skipped: {} did not answer {} requests in a row (cooldown {}s), so this run temporarily pauses asking it. Check your internet connection.",
                key,
                CONNECTIVITY_BREAKER_THRESHOLD,
                self.cooldown.as_secs()
            ))
        } else {
            Ok(())
        }
    }

    pub fn register_success(&self, host_key: &str) {
        let key = Self::get_host_key(host_key);
        let mut guard = self.hosts.lock().unwrap_or_else(|e| e.into_inner());
        guard.insert(
            key,
            HostState {
                failure_streak: 0,
                opened_at: None,
            },
        );
    }

    pub fn register_connectivity_failure(&self, host_key: &str) {
        let key = Self::get_host_key(host_key);
        let mut guard = self.hosts.lock().unwrap_or_else(|e| e.into_inner());
        let state = guard.entry(key.clone()).or_default();
        self.apply_cooldown_decay(state);

        let was_open = state.failure_streak >= CONNECTIVITY_BREAKER_THRESHOLD;
        state.failure_streak += 1;
        if state.failure_streak >= CONNECTIVITY_BREAKER_THRESHOLD {
            state.opened_at = Some(Instant::now());
            if !was_open {
                append_app_log(
                    "WARN",
                    &format!(
                        "{} did not answer {} requests in a row - skipping it for {}s before retrying",
                        key,
                        state.failure_streak,
                        self.cooldown.as_secs()
                    ),
                );
            }
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

    #[test]
    fn test_host_breaker_half_open_cooldown_decay_and_retrip() {
        let breaker = HostBreaker::with_cooldown(Duration::from_millis(25));
        let host = "https://addons.wago.io/api/test";

        for _ in 0..3 {
            breaker.register_connectivity_failure(host);
        }
        assert!(breaker.is_open(host));
        assert!(breaker.assert_reachable(host).is_err());

        std::thread::sleep(Duration::from_millis(40));

        // Cooldown expired -> transitions to half-open
        assert!(!breaker.is_open(host));
        assert!(breaker.assert_reachable(host).is_ok());

        // A single failed half-open probe immediately re-trips the breaker
        breaker.register_connectivity_failure(host);
        assert!(breaker.is_open(host));
        assert!(breaker.assert_reachable(host).is_err());

        // After another cooldown, a successful response fully resets the streak
        std::thread::sleep(Duration::from_millis(40));
        assert!(!breaker.is_open(host));
        breaker.register_success(host);
        breaker.register_connectivity_failure(host);
        assert!(!breaker.is_open(host));
        breaker.register_connectivity_failure(host);
        assert!(!breaker.is_open(host));
        breaker.register_connectivity_failure(host);
        assert!(breaker.is_open(host));
    }
}
