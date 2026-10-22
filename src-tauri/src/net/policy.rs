use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, Instant};
use chrono::{DateTime, Utc};
use tokio::sync::{Mutex, Semaphore};
use crate::logging::append_app_log;
use crate::net::breaker::HostBreaker;

pub const DEFAULT_ALLOWED_HOSTS: &[&str] = &[
    "www.curseforge.com",
    "curseforge.com",
    "edge.forgecdn.net",
    "media.forgecdn.net",
    "addons.wago.io",
    "media.wago.io",
    "wago.io",
    "api.github.com",
    "github.com",
    "objects.githubusercontent.com",
    "raw.githubusercontent.com",
    "codeload.github.com",
    "addon-radar.com",
    "localhost",
    "127.0.0.1",
    "::1",
];

pub struct HostRateLimiter {
    semaphore: Arc<Semaphore>,
    last_start: Mutex<Option<Instant>>,
    min_interval: Duration,
}

impl HostRateLimiter {
    pub fn new(max_concurrent: usize, min_interval_ms: u64) -> Self {
        Self {
            semaphore: Arc::new(Semaphore::new(max_concurrent)),
            last_start: Mutex::new(None),
            min_interval: Duration::from_millis(min_interval_ms),
        }
    }

    pub async fn acquire(&self) -> tokio::sync::OwnedSemaphorePermit {
        let permit = self.semaphore.clone().acquire_owned().await.unwrap();

        // Enforce spacing between request starts
        let mut last = self.last_start.lock().await;
        if let Some(prev) = *last {
            let elapsed = prev.elapsed();
            if elapsed < self.min_interval {
                tokio::time::sleep(self.min_interval - elapsed).await;
            }
        }
        *last = Some(Instant::now());

        permit
    }
}

pub struct NetworkPolicy {
    allowed_hosts: HashSet<String>,
    pub breaker: HostBreaker,
    // Normal CurseForge: 2 concurrent, 100ms
    cf_limiter_normal: HostRateLimiter,
    // Fallback CurseForge: 1 concurrent, 300ms
    cf_limiter_fallback: HostRateLimiter,
    // Wago & GitHub: 1 concurrent, 300ms
    wago_limiter: HostRateLimiter,
    github_limiter: HostRateLimiter,
    other_limiter: HostRateLimiter,
    cf_fallback_until: Mutex<Option<DateTime<Utc>>>,
}

impl Default for NetworkPolicy {
    fn default() -> Self {
        Self::new()
    }
}

impl NetworkPolicy {
    pub fn new() -> Self {
        let mut allowed = HashSet::new();
        for h in DEFAULT_ALLOWED_HOSTS {
            allowed.insert(h.to_ascii_lowercase());
        }

        // Add test override hosts if defined
        let test_envs = [
            "FURPHY_TEST_CF_BASEURL",
            "FURPHY_TEST_WAGO_BASEURL",
            "FURPHY_TEST_GITHUB_BASEURL",
            "FURPHY_TEST_CF_CATALOGUE_BASEURL",
        ];
        for env_var in &test_envs {
            if let Ok(val) = std::env::var(env_var) {
                if let Ok(parsed) = reqwest::Url::parse(&val) {
                    if let Some(h) = parsed.host_str() {
                        allowed.insert(h.to_ascii_lowercase());
                    }
                }
            }
        }

        Self {
            allowed_hosts: allowed,
            breaker: HostBreaker::new(),
            cf_limiter_normal: HostRateLimiter::new(2, 100),
            cf_limiter_fallback: HostRateLimiter::new(1, 300),
            wago_limiter: HostRateLimiter::new(1, 300),
            github_limiter: HostRateLimiter::new(1, 300),
            other_limiter: HostRateLimiter::new(1, 100),
            cf_fallback_until: Mutex::new(None),
        }
    }

    pub fn check_host_allowed(&self, host: &str) -> Result<(), String> {
        let clean_host = HostBreaker::get_host_key(host);
        if self.allowed_hosts.contains(&clean_host) || clean_host == "127.0.0.1" || clean_host == "localhost" {
            Ok(())
        } else {
            Err(format!("Host '{}' is not in the network allow-list", clean_host))
        }
    }

    pub async fn is_cf_fallback_active(&self) -> bool {
        let guard = self.cf_fallback_until.lock().await;
        if let Some(until) = *guard {
            Utc::now() < until
        } else {
            false
        }
    }

    pub async fn set_cf_fallback(&self, until: DateTime<Utc>) {
        let mut guard = self.cf_fallback_until.lock().await;
        *guard = Some(until);
        append_app_log(
            "WARN",
            &format!("CurseForge switched to 24h fallback rule (1 in flight, 300ms) until {}", until.to_rfc3339()),
        );
    }

    pub async fn acquire_permit(&self, host_key: &str) -> Result<tokio::sync::OwnedSemaphorePermit, String> {
        self.check_host_allowed(host_key)?;
        self.breaker.assert_reachable(host_key)?;

        let key = HostBreaker::get_host_key(host_key);
        if key.contains("curseforge") {
            if self.is_cf_fallback_active().await {
                Ok(self.cf_limiter_fallback.acquire().await)
            } else {
                Ok(self.cf_limiter_normal.acquire().await)
            }
        } else if key.contains("wago") {
            Ok(self.wago_limiter.acquire().await)
        } else if key.contains("github") {
            Ok(self.github_limiter.acquire().await)
        } else {
            Ok(self.other_limiter.acquire().await)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_host_allowlist_enforcement() {
        let policy = NetworkPolicy::new();
        assert!(policy.check_host_allowed("www.curseforge.com").is_ok());
        assert!(policy.check_host_allowed("addons.wago.io").is_ok());
        assert!(policy.check_host_allowed("api.github.com").is_ok());
        assert!(policy.check_host_allowed("raw.githubusercontent.com").is_ok());
        assert!(policy.check_host_allowed("addon-radar.com").is_ok());
        assert!(policy.check_host_allowed("localhost").is_ok());

        // Disallowed host
        assert!(policy.check_host_allowed("malicious.example.com").is_err());
        assert!(policy.check_host_allowed("api.curseforge.com").is_err()); // Never keyed API!
    }

    #[tokio::test]
    async fn test_cf_fallback_toggle() {
        let policy = NetworkPolicy::new();
        assert!(!policy.is_cf_fallback_active().await);

        let future = Utc::now() + chrono::Duration::hours(24);
        policy.set_cf_fallback(future).await;
        assert!(policy.is_cf_fallback_active().await);
    }
}
