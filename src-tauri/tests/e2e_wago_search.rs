use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use furphy_lib::net::policy::NetworkPolicy;
use furphy_lib::net::wago::{create_wago_client, search_wago_addons, WagoSession};
use furphy_lib::system::game::TEST_ENV_LOCK;

struct EnvGuard {
    orig_baseurl: Option<String>,
}

impl EnvGuard {
    fn new(base_url: &str) -> Self {
        let orig = std::env::var("FURPHY_TEST_WAGO_BASEURL").ok();
        std::env::set_var("FURPHY_TEST_WAGO_BASEURL", base_url);
        Self { orig_baseurl: orig }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        if let Some(ref val) = self.orig_baseurl {
            std::env::set_var("FURPHY_TEST_WAGO_BASEURL", val);
        } else {
            std::env::remove_var("FURPHY_TEST_WAGO_BASEURL");
        }
    }
}

#[derive(Clone, Debug)]
struct CatalogEntry {
    slug: String,
    name: String,
    description: String,
    author: String,
    downloads: u64,
    updated_at: String,
    retail: bool,
    classic: bool,
}

fn build_catalogue() -> Vec<CatalogEntry> {
    let mut catalogue = Vec::with_capacity(42);

    for i in 0..42 {
        let downloads = 1_000_000 - (i as u64) * 15_000;
        let permuted_idx = (i * 13 + 7) % 42;
        let base_date = chrono::NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
        let date = base_date + chrono::Duration::days(permuted_idx as i64 * 7);
        let updated_at = date.format("%b %d, %Y").to_string();

        let (slug, name, retail, classic) = match i {
            3 => (
                "alpha-dragonflight-tools".to_string(),
                "Alpha Dragonflight Tools".to_string(),
                true,
                false, // Retail only
            ),
            12 => (
                "alpha-unit-frames".to_string(),
                "Alpha Unit Frames".to_string(),
                true,
                true, // Overlap (both retail and classic)
            ),
            35 => (
                "alpha-raid-tools".to_string(),
                "Alpha Raid Tools".to_string(),
                false,
                true, // Classic only
            ),
            38 => (
                "alpha-threat-meter".to_string(),
                "Alpha Threat Meter".to_string(),
                false,
                true, // Classic only
            ),
            _ => {
                let name = format!("Addon {:02}", i);
                let slug = format!("addon-{:02}", i);
                let retail = i < 32;
                let classic = i >= 10;
                (slug, name, retail, classic)
            }
        };

        catalogue.push(CatalogEntry {
            slug,
            name,
            description: format!("Description for addon {}", i),
            author: format!("Author{}", i % 5),
            downloads,
            updated_at,
            retail,
            classic,
        });
    }

    catalogue
}

fn make_card_html(
    slug: &str,
    name: &str,
    description: &str,
    author: &str,
    downloads: u64,
    updated_at: &str,
) -> String {
    format!(
        "<a href=\"https://addons.wago.io/addons/{}\" class=\"plain-link\"><div class=\"card\"><img src=\"https://cdn.wago.io/thumbnails/{}.png\" alt=\"\" /><div><h3>{}</h3><p class=\"text-md truncate\">{}</p><div><span><strong>Updated:</strong> {}</span><span><strong>Downloads:</strong> {}</span><span><strong>Author:</strong> {}</span></div></div></div></a>",
        slug, slug, name, description, updated_at, downloads, author
    )
}

struct MockWagoServer {
    base_url: String,
    recorded_requests: Arc<Mutex<Vec<String>>>,
    hostile: Arc<AtomicBool>,
    shutdown_tx: Option<tokio::sync::oneshot::Sender<()>>,
}

impl Drop for MockWagoServer {
    fn drop(&mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
    }
}

impl MockWagoServer {
    async fn spawn() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("Failed binding mock listener");
        let addr = listener.local_addr().expect("Failed getting local addr");
        let base_url = format!("http://{}", addr);

        let recorded_requests = Arc::new(Mutex::new(Vec::new()));
        let hostile = Arc::new(AtomicBool::new(false));
        let (shutdown_tx, mut shutdown_rx) = tokio::sync::oneshot::channel::<()>();

        let recorded_clone = recorded_requests.clone();
        let hostile_clone = hostile.clone();
        let catalogue = build_catalogue();

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = &mut shutdown_rx => break,
                    res = listener.accept() => {
                        if let Ok((mut socket, _)) = res {
                            let recorded = recorded_clone.clone();
                            let is_hostile = hostile_clone.clone();
                            let cat = catalogue.clone();
                            tokio::spawn(async move {
                                handle_connection(&mut socket, recorded, is_hostile, &cat).await;
                            });
                        }
                    }
                }
            }
        });

        Self {
            base_url,
            recorded_requests,
            hostile,
            shutdown_tx: Some(shutdown_tx),
        }
    }
}

async fn handle_connection(
    socket: &mut tokio::net::TcpStream,
    recorded: Arc<Mutex<Vec<String>>>,
    hostile: Arc<AtomicBool>,
    catalogue: &[CatalogEntry],
) {
    let mut buf = Vec::with_capacity(4096);
    let mut temp = [0u8; 2048];
    loop {
        let n = match socket.read(&mut temp).await {
            Ok(n) if n > 0 => n,
            _ => break,
        };
        buf.extend_from_slice(&temp[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") || buf.len() > 16384 {
            break;
        }
    }

    if buf.is_empty() {
        return;
    }

    let req_str = String::from_utf8_lossy(&buf);
    let first_line = req_str.lines().next().unwrap_or("");
    let parts: Vec<&str> = first_line.split_whitespace().collect();
    if parts.len() < 2 {
        return;
    }
    let target = parts[1];

    recorded.lock().unwrap().push(target.to_string());

    let is_inertia = req_str.lines().any(|l| {
        l.split_once(':')
            .map(|(k, v)| k.trim().eq_ignore_ascii_case("x-inertia") && v.trim().eq_ignore_ascii_case("true"))
            .unwrap_or(false)
    });

    let dummy_url = format!("http://127.0.0.1{}", target);
    let parsed_url = match reqwest::Url::parse(&dummy_url) {
        Ok(u) => u,
        Err(_) => return,
    };
    let query_map: HashMap<String, String> = parsed_url.query_pairs().into_owned().collect();
    let is_hostile_now = hostile.load(Ordering::SeqCst);

    let mut should_redirect = false;
    if is_hostile_now {
        if target != "/" {
            should_redirect = true;
        }
    } else {
        if let Some(gv) = query_map.get("game_version") {
            let valid_gv = matches!(gv.as_str(), "retail" | "classic" | "bc" | "wotlk" | "cata" | "mop");
            if !valid_gv {
                should_redirect = true;
            }
        }
        if let Some(s) = query_map.get("sort") {
            let valid_sort = matches!(s.as_str(), "name" | "updated");
            if !valid_sort {
                should_redirect = true;
            }
        }
    }

    if should_redirect {
        let resp = "HTTP/1.1 302 Found\r\nLocation: /\r\nConnection: close\r\n\r\n";
        let _ = socket.write_all(resp.as_bytes()).await;
        return;
    }

    let is_default_page = target == "/" || (is_hostile_now && target == "/");

    let val = if is_default_page {
        let default_items = catalogue.iter().filter(|i| i.retail).take(14);
        let cards_data: Vec<String> = default_items
            .map(|i| make_card_html(&i.slug, &i.name, &i.description, &i.author, i.downloads, &i.updated_at))
            .collect();

        serde_json::json!({
            "component": "Search",
            "url": "/",
            "version": "fake_inertia_ver",
            "props": {
                "game_version": serde_json::Value::Null,
                "search": serde_json::Value::Null,
                "category": serde_json::Value::Null,
                "sort": serde_json::Value::Null,
                "addons": {
                    "current_page": 1,
                    "last_page": 67,
                    "per_page": 15,
                    "total": 1000,
                    "from": 1,
                    "to": cards_data.len(),
                    "next_page_url": "/?page=2",
                    "data": cards_data
                }
            }
        })
    } else {
        let game_version = query_map.get("game_version").cloned().unwrap_or_else(|| "retail".to_string());
        let search_query = query_map.get("search");
        let sort_param = query_map.get("sort");
        let category_param = query_map.get("category");

        let mut matched: Vec<CatalogEntry> = catalogue
            .iter()
            .filter(|i| match game_version.as_str() {
                "classic" => i.classic,
                _ => i.retail,
            })
            .cloned()
            .collect();

        if let Some(q) = search_query {
            let q_lower = q.to_lowercase();
            matched.retain(|i| i.name.to_lowercase().contains(&q_lower));
        }

        if let Some(s) = sort_param {
            if s == "name" {
                matched.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
            } else if s == "updated" {
                matched.clear();
            }
        } else {
            matched.sort_by(|a, b| b.downloads.cmp(&a.downloads));
        }

        let per_page = 15;
        let page = query_map.get("page").and_then(|p| p.parse::<u32>().ok()).unwrap_or(1).max(1);
        let total = matched.len();
        let last_page = if total == 0 { 1 } else { ((total + per_page - 1) / per_page) as u32 };
        let start = ((page - 1) * per_page as u32) as usize;

        let paged_items: Vec<CatalogEntry> = if start >= total {
            Vec::new()
        } else {
            let end = (start + per_page).min(total);
            matched[start..end].to_vec()
        };

        let cards_data: Vec<String> = paged_items
            .iter()
            .map(|i| make_card_html(&i.slug, &i.name, &i.description, &i.author, i.downloads, &i.updated_at))
            .collect();

        let from_val = if total == 0 { serde_json::Value::Null } else { serde_json::json!(start + 1) };
        let to_val = if total == 0 { serde_json::Value::Null } else { serde_json::json!(start + cards_data.len()) };
        let next_url = if page < last_page {
            serde_json::json!(format!("/?page={}", page + 1))
        } else {
            serde_json::Value::Null
        };

        serde_json::json!({
            "component": "Search",
            "url": target,
            "version": "fake_inertia_ver",
            "props": {
                "game_version": game_version,
                "search": search_query.map(|s| serde_json::json!(s)).unwrap_or(serde_json::Value::Null),
                "category": category_param.and_then(|c| c.parse::<i64>().ok()).map(|n| serde_json::json!(n)).unwrap_or(serde_json::Value::Null),
                "sort": sort_param.map(|s| serde_json::json!(s)).unwrap_or(serde_json::Value::Null),
                "addons": {
                    "current_page": page,
                    "last_page": last_page,
                    "per_page": per_page,
                    "total": total,
                    "from": from_val,
                    "to": to_val,
                    "next_page_url": next_url,
                    "data": cards_data
                }
            }
        })
    };

    let json_text = serde_json::to_string(&val).unwrap();

    let resp_bytes = if is_inertia {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Inertia: true\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            json_text.len(),
            json_text
        )
    } else {
        let html_body = format!(
            "<!DOCTYPE html><html><body><div id=\"app\" data-page='{}'></div></body></html>",
            json_text
        );
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            html_body.len(),
            html_body
        )
    };

    let _ = socket.write_all(resp_bytes.as_bytes()).await;
}

#[tokio::test]
async fn test_default_popular_sort_keeps_search_and_flavour() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let server = MockWagoServer::spawn().await;
    let _env = EnvGuard::new(&server.base_url);
    let policy = Arc::new(NetworkPolicy::new());
    let client = create_wago_client().expect("Failed creating reqwest client");
    let session = WagoSession::new();

    let (items, total, has_more) = search_wago_addons(
        &policy,
        &client,
        &session,
        "forever",
        Some("alpha"),
        None,
        Some("popular"),
        1,
    )
    .await
    .expect("search_wago_addons should succeed");

    assert!(!items.is_empty(), "Expected results matching 'alpha'");
    assert_eq!(total, items.len() as u64);
    assert!(!has_more);

    for item in &items {
        assert!(
            item.name.to_lowercase().contains("alpha"),
            "Item '{}' does not match 'alpha'",
            item.name
        );
    }

    let classic_slugs: HashSet<String> = build_catalogue()
        .into_iter()
        .filter(|c| c.classic)
        .map(|c| c.slug)
        .collect();

    for item in &items {
        assert!(
            classic_slugs.contains(&item.slug),
            "Item '{}' is not in classic set",
            item.slug
        );
        assert_ne!(
            item.slug, "alpha-dragonflight-tools",
            "Retail-only addon must not appear in forever results"
        );
    }

    let reqs = server.recorded_requests.lock().unwrap();
    assert!(!reqs.is_empty(), "Server should have received requests");
    for req in reqs.iter() {
        assert!(
            !req.contains("sort="),
            "Recorded request must not contain 'sort=', got: {}",
            req
        );
        assert!(
            req.contains("game_version=classic"),
            "Recorded request must have game_version=classic, got: {}",
            req
        );
        assert!(
            req.contains("search=alpha"),
            "Recorded request must have search=alpha, got: {}",
            req
        );
    }
}

#[tokio::test]
async fn test_name_sort_is_forwarded_and_orders_by_name() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let server = MockWagoServer::spawn().await;
    let _env = EnvGuard::new(&server.base_url);
    let policy = Arc::new(NetworkPolicy::new());
    let client = create_wago_client().expect("Failed creating reqwest client");
    let session = WagoSession::new();

    let (items_name, total, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        None,
        Some("name"),
        1,
    )
    .await
    .expect("search_wago_addons should succeed with name sort");

    assert!(!items_name.is_empty(), "Items should not be empty");
    assert_eq!(total, 32);

    // Release the recorder lock before the next request: the fake server takes the same lock
    // to record it, and the test runtime is single-threaded.
    {
        let reqs = server.recorded_requests.lock().unwrap();
        assert!(
            reqs.iter().any(|r| r.contains("sort=name")),
            "Recorded requests must contain 'sort=name', got: {:?}",
            *reqs
        );
    }

    for window in items_name.windows(2) {
        assert!(
            window[0].name.to_lowercase() <= window[1].name.to_lowercase(),
            "Items not ordered by name: '{}' followed by '{}'",
            window[0].name,
            window[1].name
        );
    }

    let (items_default, _, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        None,
        None,
        1,
    )
    .await
    .expect("search_wago_addons should succeed with default sort");

    let slugs_name: Vec<_> = items_name.iter().map(|i| &i.slug).collect();
    let slugs_default: Vec<_> = items_default.iter().map(|i| &i.slug).collect();
    assert_ne!(
        slugs_name, slugs_default,
        "Name-sorted order must differ from default downloads order"
    );
}

#[tokio::test]
async fn test_downloads_rating_gaining_are_never_forwarded() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let server = MockWagoServer::spawn().await;
    let _env = EnvGuard::new(&server.base_url);
    let policy = Arc::new(NetworkPolicy::new());
    let client = create_wago_client().expect("Failed creating reqwest client");
    let session = WagoSession::new();

    let (baseline_items, baseline_total, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        None,
        None,
        1,
    )
    .await
    .expect("search_wago_addons baseline should succeed");

    let baseline_slugs: Vec<_> = baseline_items.iter().map(|i| i.slug.clone()).collect();

    for sort_val in ["popular", "downloads", "rating", "gaining"] {
        server.recorded_requests.lock().unwrap().clear();

        let (items, total, _) = search_wago_addons(
            &policy,
            &client,
            &session,
            "retail",
            None,
            None,
            Some(sort_val),
            1,
        )
        .await
        .unwrap_or_else(|e| panic!("search_wago_addons failed for sort {}: {}", sort_val, e));

        assert_eq!(total, baseline_total);

        let reqs = server.recorded_requests.lock().unwrap();
        assert!(!reqs.is_empty(), "Server should have received requests");
        for r in reqs.iter() {
            assert!(
                !r.contains("sort="),
                "Recorded request for sort '{}' must not contain 'sort=', got: {}",
                sort_val,
                r
            );
        }

        let slugs: Vec<_> = items.iter().map(|i| i.slug.clone()).collect();
        assert_eq!(
            slugs, baseline_slugs,
            "Results for sort '{}' must match no-sort baseline results",
            sort_val
        );
    }
}

#[tokio::test]
async fn test_updated_sort_orders_newest_first_without_sending_sort() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let server = MockWagoServer::spawn().await;
    let _env = EnvGuard::new(&server.base_url);
    let policy = Arc::new(NetworkPolicy::new());
    let client = create_wago_client().expect("Failed creating reqwest client");
    let session = WagoSession::new();

    server.recorded_requests.lock().unwrap().clear();

    let (items, _, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        None,
        Some("updated"),
        1,
    )
    .await
    .expect("search_wago_addons should succeed with updated sort");

    // Release the recorder lock before the next request (see test_name_sort...).
    {
        let reqs = server.recorded_requests.lock().unwrap();
        assert!(!reqs.is_empty(), "Server should have received requests");
        for r in reqs.iter() {
            assert!(
                !r.contains("sort="),
                "Recorded request for updated sort must not contain 'sort=', got: {}",
                r
            );
        }
    }

    assert!(!items.is_empty());
    for window in items.windows(2) {
        let d0 = chrono::NaiveDate::parse_from_str(window[0].updated_at.as_ref().unwrap(), "%b %d, %Y")
            .expect("Valid updated_at date format on window[0]");
        let d1 = chrono::NaiveDate::parse_from_str(window[1].updated_at.as_ref().unwrap(), "%b %d, %Y")
            .expect("Valid updated_at date format on window[1]");
        assert!(
            d0 >= d1,
            "Items not sorted newest first: '{}' ({:?}) vs '{}' ({:?})",
            window[0].slug,
            d0,
            window[1].slug,
            d1
        );
    }

    let (default_items, _, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        None,
        None,
        1,
    )
    .await
    .expect("search_wago_addons should succeed with default sort");

    let updated_slugs: Vec<_> = items.iter().map(|i| &i.slug).collect();
    let default_slugs: Vec<_> = default_items.iter().map(|i| &i.slug).collect();
    assert_ne!(
        updated_slugs, default_slugs,
        "Updated-sorted order must differ from default downloads order"
    );
}

#[tokio::test]
async fn test_retail_and_forever_return_different_results() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let server = MockWagoServer::spawn().await;
    let _env = EnvGuard::new(&server.base_url);
    let policy = Arc::new(NetworkPolicy::new());
    let client = create_wago_client().expect("Failed creating reqwest client");
    let session = WagoSession::new();

    let (retail_items, retail_total, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        None,
        None,
        1,
    )
    .await
    .expect("retail search should succeed");

    let (forever_items, forever_total, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "forever",
        None,
        None,
        None,
        1,
    )
    .await
    .expect("forever search should succeed");

    assert_eq!(retail_total, 32);
    assert_eq!(forever_total, 32);

    let retail_slugs: Vec<_> = retail_items.iter().map(|i| i.slug.clone()).collect();
    let forever_slugs: Vec<_> = forever_items.iter().map(|i| i.slug.clone()).collect();

    assert_ne!(
        retail_slugs, forever_slugs,
        "Retail and forever must return different results"
    );

    assert!(
        retail_slugs.iter().any(|s| s == "addon-00"),
        "Retail results must contain retail-only addon-00"
    );
    assert!(
        !forever_slugs.iter().any(|s| s == "addon-00"),
        "Forever results must not contain retail-only addon-00"
    );

    let (forever_p3, _, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "forever",
        None,
        None,
        None,
        3,
    )
    .await
    .expect("forever page 3 should succeed");
    let all_forever_slugs: Vec<_> = forever_items
        .iter()
        .chain(forever_p3.iter())
        .map(|i| i.slug.as_str())
        .collect();
    assert!(
        all_forever_slugs.contains(&"addon-41"),
        "Forever catalogue must include classic-only addon-41"
    );
}

#[tokio::test]
async fn test_pagination_has_more_follows_last_page() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let server = MockWagoServer::spawn().await;
    let _env = EnvGuard::new(&server.base_url);
    let policy = Arc::new(NetworkPolicy::new());
    let client = create_wago_client().expect("Failed creating reqwest client");
    let session = WagoSession::new();

    let (p1, total, has_more_1) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        None,
        None,
        1,
    )
    .await
    .expect("Page 1 should succeed");

    assert_eq!(total, 32);
    assert_eq!(p1.len(), 15);
    assert!(has_more_1, "Page 1 has_more must be true");

    let (p2, _, has_more_2) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        None,
        None,
        2,
    )
    .await
    .expect("Page 2 should succeed");

    assert_eq!(p2.len(), 15);
    assert!(has_more_2, "Page 2 has_more must be true");

    let (p3, _, has_more_3) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        None,
        None,
        3,
    )
    .await
    .expect("Page 3 should succeed");

    assert_eq!(p3.len(), 2);
    assert!(!has_more_3, "Last page (page 3) has_more must be false");

    let mut seen_slugs = HashSet::new();
    for item in p1.iter().chain(p2.iter()).chain(p3.iter()) {
        assert!(
            seen_slugs.insert(item.slug.clone()),
            "Duplicate slug found across pages: {}",
            item.slug
        );
    }
    assert_eq!(seen_slugs.len(), 32, "All 32 items should be distinct across pages");
}

#[tokio::test]
async fn test_hostile_upstream_dropping_filters_is_reported_as_error() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let server = MockWagoServer::spawn().await;
    let _env = EnvGuard::new(&server.base_url);
    let policy = Arc::new(NetworkPolicy::new());
    let client = create_wago_client().expect("Failed creating reqwest client");
    let session = WagoSession::new();

    server.hostile.store(true, Ordering::SeqCst);

    let res = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        Some("alpha"),
        None,
        Some("popular"),
        1,
    )
    .await;

    assert!(res.is_err(), "Hostile upstream dropping filters must return Err");
    let err = res.unwrap_err();
    assert!(
        err.contains("did not apply"),
        "Error message must contain 'did not apply', got: {}",
        err
    );
}

#[tokio::test]
async fn test_name_sort_combined_with_search_keeps_both_filters() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let server = MockWagoServer::spawn().await;
    let _env = EnvGuard::new(&server.base_url);
    let policy = Arc::new(NetworkPolicy::new());
    let client = create_wago_client().expect("Failed creating reqwest client");
    let session = WagoSession::new();

    let (items, total, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "forever",
        Some("alpha"),
        None,
        Some("name"),
        1,
    )
    .await
    .expect("sort=name with a search must succeed");

    assert!(!items.is_empty(), "Expected results matching 'alpha'");
    assert_eq!(total, items.len() as u64);
    for item in &items {
        assert!(
            item.name.to_lowercase().contains("alpha"),
            "'{}' does not match 'alpha'",
            item.name
        );
    }
    for window in items.windows(2) {
        assert!(window[0].name.to_lowercase() <= window[1].name.to_lowercase());
    }

    let reqs = server.recorded_requests.lock().unwrap();
    assert!(
        reqs.iter().any(|r| r.contains("sort=name")
            && r.contains("search=alpha")
            && r.contains("game_version=classic")),
        "sort=name, search and game_version must travel together, got: {:?}",
        *reqs
    );
}

#[tokio::test]
async fn test_search_with_no_matches_returns_empty_without_error() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let server = MockWagoServer::spawn().await;
    let _env = EnvGuard::new(&server.base_url);
    let policy = Arc::new(NetworkPolicy::new());
    let client = create_wago_client().expect("Failed creating reqwest client");
    let session = WagoSession::new();

    let (items, total, has_more) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        Some("zzzz-no-such-addon"),
        None,
        Some("popular"),
        1,
    )
    .await
    .expect("a search without matches is not an error");

    assert!(items.is_empty());
    assert_eq!(total, 0);
    assert!(!has_more);
}

/// Manual live canary hitting the real https://addons.wago.io.
/// Run explicitly with: cargo test --test e2e_wago_search -- --ignored
#[tokio::test]
#[ignore]
async fn live_canary_wago_real_upstream() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let orig_baseurl = std::env::var("FURPHY_TEST_WAGO_BASEURL").ok();
    std::env::remove_var("FURPHY_TEST_WAGO_BASEURL");

    struct RestoreGuard(Option<String>);
    impl Drop for RestoreGuard {
        fn drop(&mut self) {
            if let Some(ref val) = self.0 {
                std::env::set_var("FURPHY_TEST_WAGO_BASEURL", val);
            } else {
                std::env::remove_var("FURPHY_TEST_WAGO_BASEURL");
            }
        }
    }
    let _restore = RestoreGuard(orig_baseurl);

    let policy = Arc::new(NetworkPolicy::new());
    let client = create_wago_client().expect("Failed creating reqwest client");
    let session = WagoSession::new();

    let (retail_items, retail_total, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        Some("plater"),
        None,
        Some("popular"),
        1,
    )
    .await
    .expect("Live Wago search for plater on retail must succeed");

    assert!(
        retail_total < 100,
        "Live plater search total must be < 100 (filters preserved), got: {}",
        retail_total
    );
    assert!(
        retail_items.iter().any(|i| i.slug == "plater-nameplates"),
        "Live retail results must include 'plater-nameplates'"
    );

    let (forever_items, _, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "forever",
        Some("details"),
        None,
        Some("popular"),
        1,
    )
    .await
    .expect("Live Wago search for details on forever must succeed");

    assert!(
        forever_items.iter().any(|i| i.slug.contains("details")),
        "Live forever results must include a Details slug"
    );

    let (retail_details, _, _) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        Some("details"),
        None,
        Some("popular"),
        1,
    )
    .await
    .expect("Live Wago search for details on retail must succeed");

    let forever_slugs: Vec<_> = forever_items.iter().map(|i| &i.slug).collect();
    let retail_slugs: Vec<_> = retail_details.iter().map(|i| &i.slug).collect();
    assert_ne!(
        forever_slugs, retail_slugs,
        "Live forever and retail queries for 'details' must return different lists"
    );
}
