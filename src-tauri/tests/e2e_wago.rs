use std::collections::HashSet;
use std::io::Cursor;
use std::path::PathBuf;
use std::sync::Arc;
use rusqlite::Connection;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

use furphy_lib::db::schema::INITIAL_SCHEMA;
use furphy_lib::jobs::runner::JobRunner;
use furphy_lib::net::policy::NetworkPolicy;
use furphy_lib::net::wago::{
    create_wago_client, get_wago_releases_page, search_wago_addons, verify_wago_filter_echo,
    WagoSession,
};
use furphy_lib::net::wago_query::WagoQueryParams;
use furphy_lib::system::game::TEST_ENV_LOCK;

struct TestGuard {
    wow_path: PathBuf,
    data_path: PathBuf,
    orig_wowroot: Option<String>,
    orig_localappdata: Option<String>,
    orig_wago_baseurl: Option<String>,
}

impl Drop for TestGuard {
    fn drop(&mut self) {
        if let Some(ref w) = self.orig_wowroot {
            std::env::set_var("FURPHY_DEV_WOWROOT", w);
        } else {
            std::env::remove_var("FURPHY_DEV_WOWROOT");
        }
        if let Some(ref l) = self.orig_localappdata {
            std::env::set_var("LOCALAPPDATA", l);
        } else {
            std::env::remove_var("LOCALAPPDATA");
        }
        if let Some(ref b) = self.orig_wago_baseurl {
            std::env::set_var("FURPHY_TEST_WAGO_BASEURL", b);
        } else {
            std::env::remove_var("FURPHY_TEST_WAGO_BASEURL");
        }
        let _ = std::fs::remove_dir_all(&self.wow_path);
        let _ = std::fs::remove_dir_all(&self.data_path);
    }
}

fn build_plater_zip() -> Vec<u8> {
    let mut buf = Cursor::new(Vec::new());
    {
        let mut zip = ZipWriter::new(&mut buf);
        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        zip.start_file("Plater/Plater.toc", options).unwrap();
        std::io::Write::write_all(&mut zip, b"## Interface: 110002\n## Title: Plater\n## Version: 1.0.0\nPlater.lua\n").unwrap();
        zip.start_file("Plater/Plater.lua", options).unwrap();
        std::io::Write::write_all(&mut zip, b"print('Plater Nameplates initialized')\n").unwrap();
        zip.finish().unwrap();
    }
    buf.into_inner()
}

fn build_tomtom_zip() -> Vec<u8> {
    let mut buf = Cursor::new(Vec::new());
    {
        let mut zip = ZipWriter::new(&mut buf);
        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        zip.start_file("TomTom/TomTom.toc", options).unwrap();
        std::io::Write::write_all(&mut zip, b"## Interface: 11502\n## Title: TomTom\n## Version: 1.15.1\nTomTom.lua\n").unwrap();
        zip.start_file("TomTom/TomTom.lua", options).unwrap();
        std::io::Write::write_all(&mut zip, b"print('TomTom Classic initialized')\n").unwrap();
        zip.finish().unwrap();
    }
    buf.into_inner()
}

fn make_card_snippet(slug: &str, name: &str, author: &str, downloads: u64, desc: &str) -> String {
    format!(
        "<a href=\"https://addons.wago.io/addons/{}\" class=\"plain-link\"><div class=\"card\"><img src=\"https://cdn.wago.io/thumbnails/{}.png\" alt=\"\" /><div><h3>{}</h3><p class=\"text-md truncate\">{}</p><div><span><strong>Author:</strong> {}</span><span><strong>Downloads:</strong> {}</span><span><strong>Updated:</strong> Aug 18, 2026</span></div></div></div></a>",
        slug, slug, name, desc, author, downloads
    )
}

async fn spawn_mock_wago_server() -> (String, tokio::sync::oneshot::Sender<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("Failed binding mock listener");
    let addr = listener.local_addr().expect("Failed getting local addr");
    let base_url = format!("http://{}", addr);

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::oneshot::channel::<()>();

    let server_base = base_url.clone();
    tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => break,
                res = listener.accept() => {
                    if let Ok((mut socket, _)) = res {
                        let base_clone = server_base.clone();
                        tokio::spawn(async move {
                            let mut buf = [0u8; 4096];
                            let n = match socket.read(&mut buf).await {
                                Ok(n) if n > 0 => n,
                                _ => return,
                            };
                            let req = String::from_utf8_lossy(&buf[..n]);
                            let first_line = req.lines().next().unwrap_or("");
                            let parts: Vec<&str> = first_line.split_whitespace().collect();
                            if parts.len() < 2 {
                                return;
                            }
                            let path = parts[1];

                            if path.ends_with("plater.zip") {
                                let zip_data = build_plater_zip();
                                let resp_header = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                    zip_data.len()
                                );
                                let _ = socket.write_all(resp_header.as_bytes()).await;
                                let _ = socket.write_all(&zip_data).await;
                            } else if path.ends_with("tomtom.zip") {
                                let zip_data = build_tomtom_zip();
                                let resp_header = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                    zip_data.len()
                                );
                                let _ = socket.write_all(resp_header.as_bytes()).await;
                                let _ = socket.write_all(&zip_data).await;
                            } else if path.contains("/addons/tomtom/versions") {
                                if req.contains("X-Inertia") || req.contains("x-inertia") {
                                    let body = serde_json::json!({
                                        "props": {
                                            "releases": {
                                                "data": [
                                                    {
                                                        "id": "rel-tomtom-v1",
                                                        "name": "TomTom",
                                                        "version": "1.15.1",
                                                        "stability": "stable",
                                                        "size": build_tomtom_zip().len() as u64,
                                                        "url": format!("{}/download/tomtom.zip", base_clone),
                                                        "supported_classic_patches": ["1.15.0", "1.15.2"]
                                                    }
                                                ],
                                                "next_page_url": null
                                            }
                                        }
                                    }).to_string();
                                    let resp = format!(
                                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                        body.len(),
                                        body
                                    );
                                    let _ = socket.write_all(resp.as_bytes()).await;
                                } else {
                                    let html = r#"<!DOCTYPE html><html><body><div id="app" data-page="{&quot;version&quot;:&quot;mock-v1&quot;}"></div></body></html>"#;
                                    let resp = format!(
                                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                        html.len(),
                                        html
                                    );
                                    let _ = socket.write_all(resp.as_bytes()).await;
                                }
                            } else if path.contains("/addons/plater-nameplates/versions") {
                                if req.contains("X-Inertia") || req.contains("x-inertia") {
                                    let body = serde_json::json!({
                                        "props": {
                                            "releases": {
                                                "data": [
                                                    {
                                                        "id": "rel-plater-v1",
                                                        "name": "Plater",
                                                        "version": "1.0.0",
                                                        "stability": "stable",
                                                        "size": build_plater_zip().len() as u64,
                                                        "url": format!("{}/download/plater.zip", base_clone),
                                                        "supported_retail_patches": ["11.0.2", "12.1.5"]
                                                    }
                                                ],
                                                "next_page_url": null
                                            }
                                        }
                                    }).to_string();
                                    let resp = format!(
                                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                        body.len(),
                                        body
                                    );
                                    let _ = socket.write_all(resp.as_bytes()).await;
                                } else {
                                    let html = r#"<!DOCTYPE html><html><body><div id="app" data-page="{&quot;version&quot;:&quot;mock-v1&quot;}"></div></body></html>"#;
                                    let resp = format!(
                                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                        html.len(),
                                        html
                                    );
                                    let _ = socket.write_all(resp.as_bytes()).await;
                                }
                            } else if path.starts_with("/addons/") && !path.contains("/versions") {
                                let page_data = serde_json::json!({
                                    "version": "mock_inertia_ver",
                                    "props": {}
                                });
                                let html = format!(
                                    "<!DOCTYPE html><html><body><div id=\"app\" data-page='{}'></div></body></html>",
                                    page_data.to_string().replace('\'', "&#39;")
                                );
                                let resp = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                    html.len(),
                                    html
                                );
                                let _ = socket.write_all(resp.as_bytes()).await;
                            } else if path.starts_with("/?") || path == "/" {
                                // Extract query params
                                let mut page = 1u64;
                                let mut category = String::new();
                                let mut search = String::new();
                                let mut game_version = "retail".to_string();

                                if let Some(q_pos) = path.find('?') {
                                    for pair in path[q_pos + 1..].split('&') {
                                        let mut kv = pair.split('=');
                                        if let (Some(k), Some(v)) = (kv.next(), kv.next()) {
                                            if k == "page" {
                                                page = v.parse::<u64>().unwrap_or(1).max(1);
                                            } else if k == "category" {
                                                category = v.to_string();
                                            } else if k == "search" {
                                                search = v.to_string();
                                            } else if k == "game_version" {
                                                game_version = v.to_string();
                                            }
                                        }
                                    }
                                }

                                // Handle multi-page category "101" (45 items across 3 pages of 15)
                                let (cards, total, last_page, has_more) = if category == "101" || category == "combat" {
                                    let per_page = 15u64;
                                    let total_items = 45u64;
                                    let max_page = 3u64;

                                    if page > max_page {
                                        (Vec::new(), total_items, max_page, false)
                                    } else {
                                        let start = (page - 1) * per_page;
                                        let mut c = Vec::new();
                                        for i in 1..=per_page {
                                            let idx = start + i;
                                            let slug = format!("combat-addon-{:02}", idx);
                                            let name = format!("Combat Addon {:02}", idx);
                                            c.push(make_card_snippet(&slug, &name, "Mock Author", 1000000 - idx * 1000, "Combat tool"));
                                        }
                                        (c, total_items, max_page, page < max_page)
                                    }
                                } else if game_version == "classic" {
                                    (
                                        vec![
                                            make_card_snippet("tomtom", "TomTom (Classic)", "Cladhaire", 2100000, "Navigation assistant"),
                                            make_card_snippet("deadly-boss-mods-dbm", "Deadly Boss Mods (DBM) - Classic", "MysticalOS", 4100000, "Raid alerts"),
                                        ],
                                        2,
                                        1,
                                        false,
                                    )
                                } else {
                                    (
                                        vec![
                                            make_card_snippet("plater-nameplates", "Plater Nameplates", "Terciob", 4500000, "Nameplates addon"),
                                            make_card_snippet("method-raid-tools", "Method Raid Tools", "Exorsus", 3200000, "Raid management"),
                                        ],
                                        2,
                                        1,
                                        false,
                                    )
                                };

                                let next_url = if has_more {
                                    Some(format!("{}&page={}", path, page + 1))
                                } else {
                                    None
                                };

                                let props_json = serde_json::json!({
                                    "props": {
                                        "addons": {
                                            "current_page": page,
                                            "last_page": last_page,
                                            "data": cards,
                                            "total": total,
                                            "next_page_url": next_url
                                        },
                                        "game_version": game_version,
                                        "search": if search.is_empty() { Value::Null } else { Value::String(search) },
                                        "category": if category.is_empty() { Value::Null } else { Value::String(category) },
                                        "sort": Value::Null
                                    }
                                });

                                if req.contains("X-Inertia") || req.contains("x-inertia") {
                                    let body = props_json.to_string();
                                    let resp = format!(
                                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                        body.len(),
                                        body
                                    );
                                    let _ = socket.write_all(resp.as_bytes()).await;
                                } else {
                                    let page_data = serde_json::json!({
                                        "version": "mock_inertia_ver",
                                        "props": props_json["props"]
                                    });
                                    let html = format!(
                                        "<!DOCTYPE html><html><body><div id=\"app\" data-page='{}'></div></body></html>",
                                        page_data.to_string().replace('\'', "&#39;")
                                    );
                                    let resp = format!(
                                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                        html.len(),
                                        html
                                    );
                                    let _ = socket.write_all(resp.as_bytes()).await;
                                }
                            } else {
                                let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                                let _ = socket.write_all(resp.as_bytes()).await;
                            }
                        });
                    }
                }
            }
        }
    });

    (base_url, shutdown_tx)
}

#[tokio::test]
async fn test_e2e_wago_full_lifecycle() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
    let orig_localappdata = std::env::var("LOCALAPPDATA").ok();
    let orig_wago_baseurl = std::env::var("FURPHY_TEST_WAGO_BASEURL").ok();

    // 1. Create tempdir sandbox with spaces and parentheses per ADR-307
    let temp = std::env::temp_dir().join(format!("furphy test wow (wago-{})", uuid::Uuid::new_v4()));
    let local_data = std::env::temp_dir().join(format!("furphy_wago_data_{}", uuid::Uuid::new_v4()));
    let retail_addons = temp.join("_retail_").join("Interface").join("AddOns");
    let retail_wtf = temp.join("_retail_").join("WTF");
    std::fs::create_dir_all(&retail_addons).unwrap();
    std::fs::create_dir_all(&retail_wtf).unwrap();
    std::fs::create_dir_all(&local_data).unwrap();
    std::fs::write(temp.join(".build.info"), "Product|Version\nwow|11.0.2.56819\n").unwrap();

    // Spawn mock Wago server first so all releases & search calls are 100% offline
    let (mock_base_url, _shutdown) = spawn_mock_wago_server().await;
    std::env::set_var("FURPHY_DEV_WOWROOT", temp.to_str().unwrap());
    std::env::set_var("LOCALAPPDATA", local_data.to_str().unwrap());
    std::env::set_var("FURPHY_TEST_WAGO_BASEURL", &mock_base_url);

    let _cleanup = TestGuard {
        wow_path: temp.clone(),
        data_path: local_data.clone(),
        orig_wowroot,
        orig_localappdata,
        orig_wago_baseurl,
    };

    // 2. Create in-memory DB with INITIAL_SCHEMA and retail flavour
    let mut conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(INITIAL_SCHEMA).unwrap();

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    ).unwrap();

    // 3. Instantiate JobRunner
    let policy = Arc::new(NetworkPolicy::new());
    let runner = JobRunner::new(policy.clone());

    // 4. Query Wago API for "plater-nameplates" releases against mock server
    let wago_client = create_wago_client().unwrap();
    let wago_session = WagoSession::new();
    let (releases, _) = get_wago_releases_page(
        &policy,
        &wago_client,
        &wago_session,
        "plater-nameplates",
        1,
    )
    .await
    .expect("Failed to query Wago releases for plater-nameplates");
    assert!(!releases.is_empty(), "Wago releases should return at least one release for plater-nameplates");

    // Verify Wago browse & search works against the mock server
    let (search_items, total, _has_more) = search_wago_addons(
        &policy,
        &wago_client,
        &wago_session,
        "retail",
        Some("plater"),
        None,
        Some("popular"),
        1,
    ).await.expect("search_wago_addons should succeed");
    assert_eq!(total, 2);
    assert!(!search_items.is_empty());
    assert_eq!(search_items[0].slug, "plater-nameplates");
    assert_eq!(search_items[0].name, "Plater Nameplates");
    assert_eq!(search_items[0].author, "Terciob");

    // 5. Run install/add job for Wago addon (slug: "plater-nameplates")
    let res = runner.run_job(
        &mut conn,
        "add",
        Some("retail"),
        json!({ "target": "plater-nameplates", "slug": "plater-nameplates", "source": "wago" }),
    ).await;

    // 6. Verify job succeeds, DB record created with wago_slug, files extracted into AddOns/Plater
    assert!(res.is_ok(), "Wago add job failed: {:?}", res);
    let record = res.unwrap();
    assert_eq!(record.state, "completed");
    assert!(record.error.is_none(), "Job reported error: {:?}", record.error);

    let (addon_id, db_slug, db_ver, inst_at): (String, String, Option<String>, Option<String>) = conn.query_row(
        "SELECT id, wago_slug, version, installed_at FROM addons WHERE flavour = 'retail' AND wago_slug = 'plater-nameplates'",
        [],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
    ).expect("DB record must be created with wago_slug");

    assert_eq!(db_slug, "plater-nameplates");
    assert!(db_ver.is_some() && !db_ver.as_ref().unwrap().is_empty(), "version must be populated");
    assert!(inst_at.is_some() && !inst_at.as_ref().unwrap().is_empty(), "installed_at must be populated");

    let plater_dir = retail_addons.join("Plater");
    assert!(plater_dir.is_dir(), "Plater directory must exist at {:?}", plater_dir);

    // 7. Verify TOC metadata read and Plater.toc exists on disk
    let plater_toc = plater_dir.join("Plater.toc");
    assert!(plater_toc.is_file(), "Plater.toc must exist on disk at {:?}", plater_toc);

    // Verify addon_folders contains Plater
    let folders: Vec<String> = {
        let mut stmt = conn.prepare("SELECT folder FROM addon_folders WHERE addon_id = ?1").unwrap();
        stmt.query_map([&addon_id], |r| r.get(0)).unwrap().flatten().collect()
    };
    assert!(folders.iter().any(|f| f.eq_ignore_ascii_case("Plater")), "addon_folders must track Plater");

    // 8. Run remove job, verify disk folder removed and DB row purged
    let rem_res = runner.run_job(
        &mut conn,
        "remove",
        Some("retail"),
        json!({ "addon_id": addon_id }),
    ).await;
    assert!(rem_res.is_ok(), "remove job failed: {:?}", rem_res);

    assert!(!plater_dir.exists(), "Plater directory should be removed from disk");

    let count_addons: i64 = conn.query_row(
        "SELECT COUNT(*) FROM addons WHERE id = ?1",
        [&addon_id],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(count_addons, 0, "addons record should be purged from DB");

    let count_folders: i64 = conn.query_row(
        "SELECT COUNT(*) FROM addon_folders WHERE addon_id = ?1",
        [&addon_id],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(count_folders, 0, "addon_folders records should be purged from DB");
}

#[tokio::test]
async fn test_e2e_wago_pagination_edge_cases_and_sentinel() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let (mock_base_url, _shutdown) = spawn_mock_wago_server().await;
    let orig_wago_baseurl = std::env::var("FURPHY_TEST_WAGO_BASEURL").ok();
    std::env::set_var("FURPHY_TEST_WAGO_BASEURL", &mock_base_url);

    struct EnvRestore(Option<String>);
    impl Drop for EnvRestore {
        fn drop(&mut self) {
            if let Some(ref b) = self.0 {
                std::env::set_var("FURPHY_TEST_WAGO_BASEURL", b);
            } else {
                std::env::remove_var("FURPHY_TEST_WAGO_BASEURL");
            }
        }
    }
    let _restore = EnvRestore(orig_wago_baseurl);

    let policy = Arc::new(NetworkPolicy::new());
    let client = create_wago_client().expect("Failed creating reqwest client");
    let session = WagoSession::new();

    // 1. Page 1 returns first 15 items of 45 with has_more = true
    let (p1_items, p1_total, p1_more) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        Some("101"),
        Some("popular"),
        1,
    ).await.expect("page 1 should succeed");

    assert_eq!(p1_items.len(), 15, "page 1 must contain 15 items");
    assert_eq!(p1_total, 45, "total must be 45");
    assert!(p1_more, "page 1 has_more must be true");
    assert_eq!(p1_items[0].slug, "combat-addon-01");

    // 2. Page 2 returns next 15 items with has_more = true
    let (p2_items, p2_total, p2_more) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        Some("101"),
        Some("popular"),
        2,
    ).await.expect("page 2 should succeed");

    assert_eq!(p2_items.len(), 15, "page 2 must contain 15 items");
    assert_eq!(p2_total, 45);
    assert!(p2_more, "page 2 has_more must be true");
    assert_eq!(p2_items[0].slug, "combat-addon-16");

    // 3. Page 3 returns final 15 items with has_more = false
    let (p3_items, p3_total, p3_more) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        Some("101"),
        Some("popular"),
        3,
    ).await.expect("page 3 should succeed");

    assert_eq!(p3_items.len(), 15, "page 3 must contain 15 items");
    assert_eq!(p3_total, 45);
    assert!(!p3_more, "page 3 has_more must be false (terminal page)");
    assert_eq!(p3_items[14].slug, "combat-addon-45");

    // 4. Verify all items across pages 1..3 are completely distinct (no duplication)
    let mut all_slugs: HashSet<String> = HashSet::new();
    for item in p1_items.iter().chain(p2_items.iter()).chain(p3_items.iter()) {
        assert!(all_slugs.insert(item.slug.clone()), "Duplicate addon slug found across pages: {}", item.slug);
    }
    assert_eq!(all_slugs.len(), 45, "Must have exactly 45 unique addons across 3 pages");

    // 5. Page 4 (out-of-bounds) returns empty items and has_more = false
    let (p4_items, p4_total, p4_more) = search_wago_addons(
        &policy,
        &client,
        &session,
        "retail",
        None,
        Some("101"),
        Some("popular"),
        4,
    ).await.expect("page 4 beyond end should succeed");

    assert!(p4_items.is_empty(), "out-of-bounds page 4 must be empty");
    assert_eq!(p4_total, 45);
    assert!(!p4_more, "out-of-bounds page has_more must be false");
}

#[tokio::test]
async fn test_e2e_wago_echo_filter_verification_rules() {
    // 1. Valid matching echo succeeds
    let params_retail = WagoQueryParams::new(
        Some("retail"),
        Some(1),
        Some("plater"),
        Some("4"),
        Some("name"),
    );
    let valid_props = json!({
        "game_version": "retail",
        "search": "plater",
        "category": "4",
        "sort": "name"
    });
    assert!(
        verify_wago_filter_echo(&valid_props, &params_retail).is_ok(),
        "Matching props echo must succeed"
    );

    // 2. Dropped game_version (Wago redirected to default listing) returns Err
    let params_classic = WagoQueryParams::new(
        Some("classic_era"),
        Some(1),
        None,
        None,
        None,
    );
    let dropped_gv_props = json!({
        "game_version": Value::Null
    });
    let err = verify_wago_filter_echo(&dropped_gv_props, &params_classic).unwrap_err();
    assert!(err.contains("game_version"), "Must identify dropped game_version: {}", err);

    // 3. Dropped search query returns Err
    let params_search = WagoQueryParams::new(
        Some("retail"),
        Some(1),
        Some("details"),
        None,
        None,
    );
    let dropped_search_props = json!({
        "game_version": "retail",
        "search": Value::Null
    });
    let err = verify_wago_filter_echo(&dropped_search_props, &params_search).unwrap_err();
    assert!(err.contains("search"), "Must identify dropped search filter: {}", err);

    // 4. Dropped category returns Err
    let params_cat = WagoQueryParams::new(
        Some("retail"),
        Some(1),
        None,
        Some("12"),
        None,
    );
    let dropped_cat_props = json!({
        "game_version": "retail",
        "category": Value::Null
    });
    let err = verify_wago_filter_echo(&dropped_cat_props, &params_cat).unwrap_err();
    assert!(err.contains("category"), "Must identify dropped category filter: {}", err);

    // 5. Test doubles (absent keys in props) are permitted per spec
    let sparse_props = json!({});
    assert!(
        verify_wago_filter_echo(&sparse_props, &params_retail).is_ok(),
        "Absent echo keys in test doubles must not fail verification"
    );
}

#[tokio::test]
async fn test_e2e_wago_client_switching_and_isolated_spaces_paths() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
    let orig_localappdata = std::env::var("LOCALAPPDATA").ok();
    let orig_wago_baseurl = std::env::var("FURPHY_TEST_WAGO_BASEURL").ok();

    // 1. Sandbox with spaces, parentheses, and brackets per ADR-307
    let temp = std::env::temp_dir().join(format!(
        "furphy test wow (client switch) [Retail & Classic {}]",
        uuid::Uuid::new_v4()
    ));
    let local_data = std::env::temp_dir().join(format!("furphy_switch_data_{}", uuid::Uuid::new_v4()));

    let retail_addons = temp.join("_retail_").join("Interface").join("AddOns");
    let classic_addons = temp.join("_classic_era_").join("Interface").join("AddOns");
    std::fs::create_dir_all(&retail_addons).unwrap();
    std::fs::create_dir_all(&classic_addons).unwrap();
    std::fs::create_dir_all(&local_data).unwrap();
    std::fs::write(temp.join(".build.info"), "Product|Version\nwow|11.0.2.56819\nwow_classic_era|1.15.2.54321\n").unwrap();

    let (mock_base_url, _shutdown) = spawn_mock_wago_server().await;
    std::env::set_var("FURPHY_DEV_WOWROOT", temp.to_str().unwrap());
    std::env::set_var("LOCALAPPDATA", local_data.to_str().unwrap());
    std::env::set_var("FURPHY_TEST_WAGO_BASEURL", &mock_base_url);

    let _cleanup = TestGuard {
        wow_path: temp.clone(),
        data_path: local_data.clone(),
        orig_wowroot,
        orig_localappdata,
        orig_wago_baseurl,
    };

    // 2. Set up DB with multiple flavours
    let mut conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(INITIAL_SCHEMA).unwrap();

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    ).unwrap();
    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('classic_era', '_classic_era_', 'Classic Era', 1, '1.15.2', '11502')",
        [],
    ).unwrap();

    let policy = Arc::new(NetworkPolicy::new());
    let runner = JobRunner::new(policy.clone());

    // 3. Install Plater into Retail flavour
    let retail_job = runner.run_job(
        &mut conn,
        "add",
        Some("retail"),
        json!({ "target": "plater-nameplates", "slug": "plater-nameplates", "source": "wago" }),
    ).await.expect("Retail add job must succeed");
    assert_eq!(retail_job.state, "completed");

    let plater_retail_toc = retail_addons.join("Plater").join("Plater.toc");
    assert!(plater_retail_toc.is_file(), "Plater.toc must exist in retail folder");
    let plater_classic_toc = classic_addons.join("Plater").join("Plater.toc");
    assert!(!plater_classic_toc.exists(), "Plater must NOT bleed into classic folder");

    // 4. Switch client context: Install TomTom into Classic Era flavour
    let classic_job = runner.run_job(
        &mut conn,
        "add",
        Some("classic_era"),
        json!({ "target": "tomtom", "slug": "tomtom", "source": "wago" }),
    ).await.expect("Classic Era add job must succeed");
    assert_eq!(classic_job.state, "completed");

    let tomtom_classic_toc = classic_addons.join("TomTom").join("TomTom.toc");
    assert!(tomtom_classic_toc.is_file(), "TomTom.toc must exist in classic_era folder");
    let tomtom_retail_toc = retail_addons.join("TomTom").join("TomTom.toc");
    assert!(!tomtom_retail_toc.exists(), "TomTom must NOT bleed into retail folder");

    // 5. Verify database isolation across flavours
    let retail_addons_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM addons WHERE flavour = 'retail' AND wago_slug = 'plater-nameplates'",
        [],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(retail_addons_count, 1, "Retail must track plater-nameplates");

    let classic_addons_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM addons WHERE flavour = 'classic_era' AND wago_slug = 'tomtom'",
        [],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(classic_addons_count, 1, "Classic Era must track tomtom");

    // 6. Remove Plater from Retail, assert Classic TomTom is completely unaffected
    let retail_addon_id: String = conn.query_row(
        "SELECT id FROM addons WHERE flavour = 'retail' AND wago_slug = 'plater-nameplates'",
        [],
        |r| r.get(0),
    ).expect("Retail addon ID must exist");

    let rem_retail = runner.run_job(
        &mut conn,
        "remove",
        Some("retail"),
        json!({ "addon_id": retail_addon_id }),
    ).await.expect("Remove plater job must succeed");
    assert_eq!(rem_retail.state, "completed");

    assert!(!plater_retail_toc.exists(), "Plater folder must be removed from retail disk");
    assert!(tomtom_classic_toc.is_file(), "TomTom folder in Classic Era must remain intact");

    let classic_remaining: i64 = conn.query_row(
        "SELECT COUNT(*) FROM addons WHERE flavour = 'classic_era'",
        [],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(classic_remaining, 1, "Classic Era addon must still be in DB");
}
