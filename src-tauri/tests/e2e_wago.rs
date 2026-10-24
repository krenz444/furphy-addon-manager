use std::io::Cursor;
use std::path::PathBuf;
use std::sync::Arc;
use rusqlite::Connection;
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

use furphy_lib::db::schema::INITIAL_SCHEMA;
use furphy_lib::jobs::runner::JobRunner;
use furphy_lib::net::policy::NetworkPolicy;
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

async fn spawn_mock_wago_server(zip_bytes: Vec<u8>) -> (String, tokio::sync::oneshot::Sender<()>) {
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
                        let zip_data = zip_bytes.clone();
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

                            if path.ends_with(".zip") {
                                let resp_header = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                    zip_data.len()
                                );
                                let _ = socket.write_all(resp_header.as_bytes()).await;
                                let _ = socket.write_all(&zip_data).await;
                            } else if req.contains("X-Inertia") || req.contains("x-inertia") {
                                let body = if path.starts_with("/?") || path == "/" {
                                    serde_json::json!({
                                        "props": {
                                            "addons": {
                                                "current_page": 1,
                                                "data": [
                                                    "<a href=\"https://addons.wago.io/addons/plater-nameplates\"><h3>Plater Nameplates</h3><p>Nameplates addon</p><strong>Author:</strong> Terciob</span><strong>Downloads:</strong> 1000</span></a>"
                                                ],
                                                "total": 1
                                            }
                                        }
                                    }).to_string()
                                } else {
                                    serde_json::json!({
                                        "props": {
                                            "releases": {
                                                "data": [
                                                    {
                                                        "id": "rel-plater-v1",
                                                        "name": "Plater",
                                                        "version": "1.0.0",
                                                        "stability": "stable",
                                                        "size": zip_data.len(),
                                                        "url": format!("{}/download/plater.zip", base_clone),
                                                        "supported_retail_patches": ["11.0.2", "12.1.5"]
                                                    }
                                                ],
                                                "next_page_url": null
                                            }
                                        }
                                    }).to_string()
                                };
                                let resp = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                    body.len(),
                                    body
                                );
                                let _ = socket.write_all(resp.as_bytes()).await;
                            } else {
                                let body = if path.starts_with("/?") || path == "/" {
                                    r#"<!DOCTYPE html><html><body><div id="app" data-page='{"version":"mock_inertia_ver","props":{"addons":{"data":["<a href=\"https://addons.wago.io/addons/plater-nameplates\"><h3>Plater Nameplates</h3><p>Nameplates addon</p><strong>Author:</strong> Terciob</span><strong>Downloads:</strong> 1000</span></a>"],"total":1}}}'></div></body></html>"#
                                } else {
                                    r#"<!DOCTYPE html><html><body><div id="app" data-page='{"version":"mock_inertia_ver"}'></div></body></html>"#
                                };
                                let resp = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                    body.len(),
                                    body
                                );
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

    std::env::set_var("FURPHY_DEV_WOWROOT", temp.to_str().unwrap());
    std::env::set_var("LOCALAPPDATA", local_data.to_str().unwrap());
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

    // 4. Query live Wago API for "plater-nameplates" releases
    let wago_client = furphy_lib::net::wago::create_wago_client().unwrap();
    let wago_session = furphy_lib::net::wago::WagoSession::new();
    let (releases, _) = furphy_lib::net::wago::get_wago_releases_page(
        &policy,
        &wago_client,
        &wago_session,
        "plater-nameplates",
        1,
    )
    .await
    .expect("Failed to query Wago releases for plater-nameplates");
    assert!(!releases.is_empty(), "Wago releases should return at least one release for plater-nameplates");

    // Start local test server for install workflow
    let zip_bytes = build_plater_zip();
    let (mock_base_url, _shutdown) = spawn_mock_wago_server(zip_bytes).await;
    std::env::set_var("FURPHY_TEST_WAGO_BASEURL", &mock_base_url);

    // Verify Wago browse & search works against the mock server
    let wago_client = furphy_lib::net::wago::create_wago_client().unwrap();
    let wago_session = furphy_lib::net::wago::WagoSession::new();
    let (search_items, total) = furphy_lib::net::wago::search_wago_addons(
        &policy,
        &wago_client,
        &wago_session,
        "retail",
        Some("plater"),
        None,
        Some("popular"),
        1,
    ).await.expect("search_wago_addons should succeed");
    assert_eq!(total, 1);
    assert_eq!(search_items.len(), 1);
    assert_eq!(search_items[0].slug, "plater-nameplates");
    assert_eq!(search_items[0].name, "Plater Nameplates");
    assert_eq!(search_items[0].author, "Terciob");

    // 5. Run install/add job for Wago addon (slug: "plater-nameplates")
    let res = runner.run_job(
        &mut conn,
        "add",
        Some("retail"),
        json!({ "target": "plater-nameplates", "slug": "plater-nameplates" }),
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

    // 9. Teardown via TestGuard Drop
}
