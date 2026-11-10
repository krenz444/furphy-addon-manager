use std::fs::File;
use std::io::Write;
use std::path::Path;
use std::time::Duration;
use crate::net::policy::NetworkPolicy;

pub const MAX_ZIP_BYTES: u64 = 200 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct DirectDownload {
    pub bytes: u64,
    pub file_name: String,
    pub last_modified: Option<String>,
}

pub fn allow_loopback_urls() -> bool {
    std::env::var("FURPHY_TEST_ALLOW_LOOPBACK_URLS")
        .map(|v| v.trim() == "1")
        .unwrap_or(false)
}

pub fn max_zip_bytes() -> u64 {
    if let Ok(val) = std::env::var("FURPHY_TEST_MAX_ZIP_BYTES") {
        if let Ok(bytes) = val.trim().parse::<u64>() {
            return bytes;
        }
    }
    MAX_ZIP_BYTES
}

pub fn is_loopback_host(host_opt: Option<&str>) -> bool {
    match host_opt {
        Some(h) => {
            if h.eq_ignore_ascii_case("localhost") {
                return true;
            }
            if let Ok(ip) = h.parse::<std::net::IpAddr>() {
                return ip.is_loopback();
            }
            false
        }
        None => false,
    }
}

pub fn validate_zip_url(raw: &str) -> Result<reqwest::Url, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("URL cannot be empty".to_string());
    }
    if trimmed.len() > 2048 {
        return Err("The URL exceeds the 2048 character limit.".to_string());
    }

    let url = reqwest::Url::parse(trimmed).map_err(|e| format!("Invalid URL: {}", e))?;

    let allow_loopback = allow_loopback_urls();

    // Scheme check: https only, unless loopback test override
    if url.scheme() != "https" {
        let is_loopback = allow_loopback && url.scheme() == "http" && is_loopback_host(url.host_str());
        if !is_loopback {
            return Err("Only https links are allowed.".to_string());
        }
    }

    // No user info
    if !url.username().is_empty() || url.password().is_some() {
        return Err("URLs with user credentials are not allowed.".to_string());
    }

    // Host check: host not an IP literal or localhost unless env FURPHY_TEST_ALLOW_LOOPBACK_URLS=1
    let host = match url.host_str() {
        Some(h) => h,
        None => return Err("URL has no host".to_string()),
    };
    // An IPv6 literal comes back in brackets.
    let bare_host = host.trim_start_matches('[').trim_end_matches(']');
    if let Ok(ip) = bare_host.parse::<std::net::IpAddr>() {
        if !(allow_loopback && ip.is_loopback()) {
            return Err("IP address literals are not allowed in URLs.".to_string());
        }
    } else if bare_host.eq_ignore_ascii_case("localhost") && !allow_loopback {
        return Err("Localhost URLs are not allowed.".to_string());
    }

    Ok(url)
}

pub fn create_direct_client() -> reqwest::Result<reqwest::Client> {
    let mut builder = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(300))
        .redirect(reqwest::redirect::Policy::limited(5));

    if !allow_loopback_urls() {
        builder = builder.https_only(true);
    }

    crate::net::ip_mode::apply(builder).build()
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let h1 = bytes[i + 1];
            let h2 = bytes[i + 2];
            if let (Some(v1), Some(v2)) = (from_hex_digit(h1), from_hex_digit(h2)) {
                decoded.push((v1 << 4) | v2);
                i += 3;
                continue;
            }
        }
        decoded.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(decoded).unwrap_or_else(|_| s.to_string())
}

fn from_hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

pub async fn download_zip_url(
    policy: &NetworkPolicy,
    client: &reqwest::Client,
    url: &str,
    dest: &Path,
) -> Result<DirectDownload, String> {
    let parsed_url = validate_zip_url(url)?;
    let host = parsed_url.host_str().unwrap_or("").to_string();

    let raw_name = parsed_url
        .path_segments()
        .and_then(|mut segs| segs.next_back())
        .filter(|s| !s.is_empty())
        .unwrap_or("download.zip");

    let decoded_name = percent_decode(raw_name);
    let file_name = if decoded_name.is_empty() {
        "download.zip".to_string()
    } else {
        decoded_name
    };

    let _permit = policy.acquire_permit_user_url(&host).await?;

    let max_bytes = max_zip_bytes();

    let resp_res = client.get(parsed_url).send().await;
    let resp = match resp_res {
        Ok(r) => {
            policy.breaker.register_http_response(&host);
            r
        }
        Err(e) => {
            policy.breaker.register_connectivity_failure(&host);
            return Err(format!("Failed to download zip: {}", e));
        }
    };

    let status = resp.status();
    if !status.is_success() {
        return Err(format!("Download failed with HTTP status {}", status));
    }

    if let Some(content_len) = resp.content_length() {
        if content_len > max_bytes {
            return Err(format!(
                "Download exceeds the maximum allowed size of {} bytes",
                max_bytes
            ));
        }
    }

    let last_modified = resp
        .headers()
        .get(reqwest::header::LAST_MODIFIED)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    if let Some(parent) = dest.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let stream_res = stream_response_to_file(resp, dest, max_bytes).await;
    match stream_res {
        Ok(bytes) => Ok(DirectDownload {
            bytes,
            file_name,
            last_modified,
        }),
        Err(err) => {
            if dest.exists() {
                let _ = std::fs::remove_file(dest);
            }
            Err(err)
        }
    }
}

async fn stream_response_to_file(
    mut resp: reqwest::Response,
    dest: &Path,
    max_bytes: u64,
) -> Result<u64, String> {
    let mut out_file = File::create(dest).map_err(|e| format!("Failed to create destination file: {}", e))?;

    let mut total_written: u64 = 0;
    let mut magic_checked = false;
    let mut magic_buf = Vec::with_capacity(4);

    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|e| format!("Network error while streaming zip: {}", e))?
    {
        if !magic_checked {
            magic_buf.extend_from_slice(&chunk);
            if magic_buf.len() >= 4 {
                if &magic_buf[..4] != b"PK\x03\x04" {
                    return Err("The link did not return a zip file.".to_string());
                }
                magic_checked = true;
            }
        }

        total_written += chunk.len() as u64;
        if total_written > max_bytes {
            return Err(format!(
                "Download exceeds the maximum allowed size of {} bytes",
                max_bytes
            ));
        }

        out_file
            .write_all(&chunk)
            .map_err(|e| format!("Failed to write to file: {}", e))?;
    }

    if !magic_checked {
        return Err("The link did not return a zip file.".to_string());
    }

    out_file
        .flush()
        .map_err(|e| format!("Failed to flush destination file: {}", e))?;

    Ok(total_written)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn test_validate_zip_url_variants() {
        let _guard = ENV_LOCK.lock().unwrap();
        std::env::remove_var("FURPHY_TEST_ALLOW_LOOPBACK_URLS");

        // Valid https url
        let ok_url = validate_zip_url("https://example.com/addon.zip");
        assert!(ok_url.is_ok());

        // http is rejected
        let err_http = validate_zip_url("http://example.com/addon.zip");
        assert!(err_http.is_err());
        assert_eq!(err_http.unwrap_err(), "Only https links are allowed.");

        // user info rejected
        let err_user = validate_zip_url("https://user:pass@example.com/addon.zip");
        assert!(err_user.is_err());
        assert_eq!(err_user.unwrap_err(), "URLs with user credentials are not allowed.");

        // IP literal rejected
        let err_ip = validate_zip_url("https://1.2.3.4/addon.zip");
        assert!(err_ip.is_err());
        assert_eq!(err_ip.unwrap_err(), "IP address literals are not allowed in URLs.");

        // localhost rejected
        let err_lh = validate_zip_url("https://localhost/addon.zip");
        assert!(err_lh.is_err());
        assert_eq!(err_lh.unwrap_err(), "Localhost URLs are not allowed.");

        // Too long rejected
        let long_path = "a".repeat(2050);
        let err_len = validate_zip_url(&format!("https://example.com/{}", long_path));
        assert!(err_len.is_err());
        assert_eq!(err_len.unwrap_err(), "The URL exceeds the 2048 character limit.");

        // Test override allows loopback
        std::env::set_var("FURPHY_TEST_ALLOW_LOOPBACK_URLS", "1");
        let ok_loopback_ip = validate_zip_url("https://127.0.0.1/addon.zip");
        assert!(ok_loopback_ip.is_ok());

        let ok_loopback_lh = validate_zip_url("https://localhost/addon.zip");
        assert!(ok_loopback_lh.is_ok());

        let ok_loopback_http = validate_zip_url("http://127.0.0.1:8080/addon.zip");
        assert!(ok_loopback_http.is_ok());

        // Non-loopback IP still rejected with override
        let err_ip_override = validate_zip_url("https://192.168.1.1/addon.zip");
        assert!(err_ip_override.is_err());

        std::env::remove_var("FURPHY_TEST_ALLOW_LOOPBACK_URLS");
    }

    #[test]
    fn test_percent_decode_filename() {
        assert_eq!(percent_decode("My%20Addon%201.0.zip"), "My Addon 1.0.zip");
        assert_eq!(percent_decode("plain.zip"), "plain.zip");
        assert_eq!(percent_decode("hello%21world.zip"), "hello!world.zip");
    }

    #[test]
    fn test_max_zip_bytes_override() {
        let _guard = ENV_LOCK.lock().unwrap();
        std::env::remove_var("FURPHY_TEST_MAX_ZIP_BYTES");
        assert_eq!(max_zip_bytes(), MAX_ZIP_BYTES);

        std::env::set_var("FURPHY_TEST_MAX_ZIP_BYTES", "1048576");
        assert_eq!(max_zip_bytes(), 1048576);

        std::env::set_var("FURPHY_TEST_MAX_ZIP_BYTES", "not_a_number");
        assert_eq!(max_zip_bytes(), MAX_ZIP_BYTES);

        std::env::remove_var("FURPHY_TEST_MAX_ZIP_BYTES");
    }

    #[tokio::test]
    async fn test_download_zip_url_server_checks() {
        let _guard = ENV_LOCK.lock().unwrap();
        std::env::set_var("FURPHY_TEST_ALLOW_LOOPBACK_URLS", "1");

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        // 1. Success download with valid magic bytes
        tokio::spawn(async move {
            if let Ok((mut socket, _)) = listener.accept().await {
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                let mut buf = [0u8; 1024];
                let _ = socket.read(&mut buf).await;
                let body = b"PK\x03\x04validzipbyteshere";
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nLast-Modified: Mon, 10 Nov 2026 00:00:00 GMT\r\n\r\n",
                    body.len()
                );
                let _ = socket.write_all(resp.as_bytes()).await;
                let _ = socket.write_all(body).await;
            }
        });

        let policy = NetworkPolicy::new();
        let client = create_direct_client().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let dest = temp.path().join("addon.zip");

        let url = format!("http://127.0.0.1:{}/My%20Addon-1.0.zip", port);
        let res = download_zip_url(&policy, &client, &url, &dest).await;
        assert!(res.is_ok());
        let dl = res.unwrap();
        assert_eq!(dl.file_name, "My Addon-1.0.zip");
        assert_eq!(dl.bytes, 21);
        assert_eq!(dl.last_modified.as_deref(), Some("Mon, 10 Nov 2026 00:00:00 GMT"));
        assert!(dest.exists());

        // 2. Invalid magic bytes rejected and partial file removed
        let listener_bad = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port_bad = listener_bad.local_addr().unwrap().port();
        tokio::spawn(async move {
            if let Ok((mut socket, _)) = listener_bad.accept().await {
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                let mut buf = [0u8; 1024];
                let _ = socket.read(&mut buf).await;
                let body = b"HTMLNOTAZIPFILE";
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
                    body.len()
                );
                let _ = socket.write_all(resp.as_bytes()).await;
                let _ = socket.write_all(body).await;
            }
        });

        let dest_bad = temp.path().join("bad.zip");
        let url_bad = format!("http://127.0.0.1:{}/bad.zip", port_bad);
        let res_bad = download_zip_url(&policy, &client, &url_bad, &dest_bad).await;
        assert!(res_bad.is_err());
        assert_eq!(res_bad.unwrap_err(), "The link did not return a zip file.");
        assert!(!dest_bad.exists(), "Partial file must be deleted on failure");

        // 3. Exceeds max zip bytes rejected and partial file removed
        std::env::set_var("FURPHY_TEST_MAX_ZIP_BYTES", "10");
        let listener_big = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port_big = listener_big.local_addr().unwrap().port();
        tokio::spawn(async move {
            if let Ok((mut socket, _)) = listener_big.accept().await {
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                let mut buf = [0u8; 1024];
                let _ = socket.read(&mut buf).await;
                let body = b"PK\x03\x04thisistoolongforlimit";
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
                    body.len()
                );
                let _ = socket.write_all(resp.as_bytes()).await;
                let _ = socket.write_all(body).await;
            }
        });

        let dest_big = temp.path().join("big.zip");
        let url_big = format!("http://127.0.0.1:{}/big.zip", port_big);
        let res_big = download_zip_url(&policy, &client, &url_big, &dest_big).await;
        assert!(res_big.is_err());
        assert!(!dest_big.exists(), "Partial file must be deleted when size cap exceeded");

        std::env::remove_var("FURPHY_TEST_ALLOW_LOOPBACK_URLS");
        std::env::remove_var("FURPHY_TEST_MAX_ZIP_BYTES");
    }
}
