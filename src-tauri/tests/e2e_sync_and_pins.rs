use std::fs::{self, File};
use std::io::Write;
use std::sync::Arc;
use rusqlite::Connection;
use serde_json::Value;
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

use furphy_lib::db::schema::INITIAL_SCHEMA;
use furphy_lib::engine::ignore::set_ignore_updates;
use furphy_lib::engine::pin::{pin_addon, unpin_addon};
use furphy_lib::jobs::runner::JobRunner;
use furphy_lib::net::policy::NetworkPolicy;
use furphy_lib::paths::get_data_dir;
use furphy_lib::system::game::TEST_ENV_LOCK;

struct TestGuard {
    orig_wowroot: Option<String>,
    orig_localappdata: Option<String>,
    orig_cf_baseurl: Option<String>,
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
        if let Some(ref c) = self.orig_cf_baseurl {
            std::env::set_var("FURPHY_TEST_CF_BASEURL", c);
        } else {
            std::env::remove_var("FURPHY_TEST_CF_BASEURL");
        }
    }
}

/// Builds an in-memory zip archive with the given files
fn build_zip_buffer(files: &[(&str, &[u8])]) -> Vec<u8> {
    let mut buf = std::io::Cursor::new(Vec::new());
    {
        let mut zip = ZipWriter::new(&mut buf);
        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for (name, content) in files {
            zip.start_file(*name, options).expect("Failed starting zip entry");
            zip.write_all(content).expect("Failed writing zip entry");
        }
        zip.finish().expect("Failed finishing zip");
    }
    buf.into_inner()
}

/// Spawns a lightweight mock HTTP server handling CurseForge API endpoints:
/// - GET /api/v1/mods/1001/files... (up-to-date mod)
/// - GET /api/v1/mods/1002/files... (outdated mod with update 5002)
/// - GET /api/v1/mods/1002/files/5001 (pinned query for file 5001)
/// - GET /api/v1/mods/1002/files/5002/download (binary zip download)
async fn spawn_mock_curseforge_server(zip_bytes: Vec<u8>) -> (String, tokio::sync::oneshot::Sender<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("Failed binding mock listener");
    let addr = listener.local_addr().expect("Failed getting local addr");
    let base_url = format!("http://{}", addr);

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::oneshot::channel::<()>();

    tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => break,
                res = listener.accept() => {
                    if let Ok((mut socket, _)) = res {
                        let zip_data = zip_bytes.clone();
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

                            if path.contains("/files?") {
                                let body = if path.contains("/mods/1001/") {
                                    // Addon 1001 is already at file 5000
                                    r#"{"data":[{"id":5000,"displayName":"DBM 1.0.0","fileName":"dbm-1.0.zip","releaseType":1,"projectId":1001,"gameVersions":["11.0.2"],"gameVersionTypeIds":[517]}]}"#
                                } else {
                                    // Addon 1002 has newer file 5002
                                    r#"{"data":[{"id":5002,"displayName":"Details 1.1.0","fileName":"details-1.1.zip","releaseType":1,"projectId":1002,"gameVersions":["11.0.2"],"gameVersionTypeIds":[517]}]}"#
                                };
                                let resp = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                    body.len(),
                                    body
                                );
                                let _ = socket.write_all(resp.as_bytes()).await;
                            } else if path.contains("/files/5001") {
                                // Pinned file query for 5001
                                let body = r#"{"data":{"id":5001,"displayName":"Details 1.0.0","fileName":"details-1.0.zip","releaseType":1,"projectId":1002,"gameVersions":["11.0.2"],"gameVersionTypeIds":[517]}}"#;
                                let resp = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                    body.len(),
                                    body
                                );
                                let _ = socket.write_all(resp.as_bytes()).await;
                            } else if path.ends_with("/download") {
                                let resp_header = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                    zip_data.len()
                                );
                                let _ = socket.write_all(resp_header.as_bytes()).await;
                                let _ = socket.write_all(&zip_data).await;
                            } else {
                                let not_found = "HTTP/1.1 404 NOT FOUND\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                                let _ = socket.write_all(not_found.as_bytes()).await;
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
async fn test_e2e_sync_bulk_update_and_freshness_lifecycle() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (sync bulk update)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let retail_wtf = wow_root.join("_retail_").join("WTF");

    let dbm_dir = retail_addons.join("DBM-Core");
    let details_dir = retail_addons.join("Details");
    fs::create_dir_all(&dbm_dir).expect("Failed creating dbm dir");
    fs::create_dir_all(&details_dir).expect("Failed creating details dir");
    fs::create_dir_all(&retail_wtf).expect("Failed creating wtf dir");

    let local_app_data = temp.path().join("local_app_data");
    fs::create_dir_all(&local_app_data).expect("Failed creating local_app_data");

    let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
    let orig_localappdata = std::env::var("LOCALAPPDATA").ok();
    let orig_cf_baseurl = std::env::var("FURPHY_TEST_CF_BASEURL").ok();

    std::env::set_var("LOCALAPPDATA", local_app_data.to_str().unwrap());
    std::env::set_var("FURPHY_DEV_WOWROOT", wow_root.to_str().unwrap());
    let _cleanup = TestGuard {
        orig_wowroot,
        orig_localappdata,
        orig_cf_baseurl,
    };

    // 1. Initial on-disk files
    // DBM-Core is current (v1.0.0, file_id: 5000)
    fs::write(
        dbm_dir.join("DBM-Core.toc"),
        "## Interface: 110002\n## Title: DBM\n## Version: 1.0.0\n",
    )
    .unwrap();
    fs::write(dbm_dir.join("DBM-Core.lua"), "print('DBM v1.0.0')").unwrap();

    // Details is outdated (v1.0.0, file_id: 5001; update 5002 available)
    fs::write(
        details_dir.join("Details.toc"),
        "## Interface: 110002\n## Title: Details\n## Version: 1.0.0\n",
    )
    .unwrap();
    fs::write(details_dir.join("Details.lua"), "print('Details v1.0.0 old')").unwrap();

    // Prepare updated zip payload for Details v1.1.0 (file 5002)
    let details_v11_zip = build_zip_buffer(&[
        (
            "Details/Details.toc",
            b"## Interface: 110002\n## Title: Details\n## Version: 1.1.0\n",
        ),
        (
            "Details/Details.lua",
            b"print('Details v1.1.0 updated')",
        ),
    ]);

    // Start mock server
    let (cf_base_url, _shutdown) = spawn_mock_curseforge_server(details_v11_zip).await;
    std::env::set_var("FURPHY_TEST_CF_BASEURL", &cf_base_url);

    // 2. Populate SQLite DB
    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite memory conn");
    conn.execute_batch(INITIAL_SCHEMA).expect("Failed initializing schema");

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    )
    .unwrap();

    // DBM is up-to-date (file_id 5000)
    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id, version, file_id, file_name, installed_at, adopted) \
         VALUES ('addon-dbm', 'retail', 'DBM', 'curseforge', 1001, '1.0.0', '5000', 'dbm-1.0.zip', '2026-10-20T00:00:00Z', 0)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'DBM-Core', 'addon-dbm')",
        [],
    )
    .unwrap();

    // Details is outdated (file_id 5001)
    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id, version, file_id, file_name, installed_at, adopted) \
         VALUES ('addon-details', 'retail', 'Details', 'curseforge', 1002, '1.0.0', '5001', 'details-1.0.zip', '2026-10-20T00:00:00Z', 0)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'Details', 'addon-details')",
        [],
    )
    .unwrap();

    // Insert initial "Would-update" status in check_results to simulate pending update
    conn.execute(
        "INSERT INTO check_results (addon_id, checked_at, update_file_id, update_version, status, error) \
         VALUES ('addon-details', '2026-10-23T00:00:00Z', '5002', '1.1.0', 'Would-update', NULL)",
        [],
    )
    .unwrap();

    // 3. Run sync job via runner.run_job
    let policy = Arc::new(NetworkPolicy::default());
    let runner = Arc::new(JobRunner::new(policy));

    let job_record = runner
        .run_job(&mut conn, "sync", Some("retail"), Value::Null)
        .await
        .expect("Sync job failed to execute");

    assert_eq!(job_record.state, "completed", "Job state must be completed");
    assert!(job_record.error.is_none(), "Sync job reported errors: {:?}", job_record.error);

    // 4. Verify updated addon files replaced atomically on disk
    let updated_lua = fs::read_to_string(details_dir.join("Details.lua"))
        .expect("Failed reading updated Details lua");
    assert_eq!(updated_lua, "print('Details v1.1.0 updated')", "Disk file was not replaced atomically");

    let updated_toc = fs::read_to_string(details_dir.join("Details.toc"))
        .expect("Failed reading updated Details toc");
    assert!(updated_toc.contains("Version: 1.1.0"), "TOC version was not updated");

    // DBM files should remain untouched
    let dbm_lua = fs::read_to_string(dbm_dir.join("DBM-Core.lua")).unwrap();
    assert_eq!(dbm_lua, "print('DBM v1.0.0')");

    // 5. Verify backup zip created in <data_dir>/backups/retail/<addon_id>/
    let data_dir = get_data_dir();
    let expected_backup = data_dir.join("backups").join("retail").join("addon-details").join("5001.zip");
    assert!(
        expected_backup.exists(),
        "Expected backup zip not found at {:?}",
        expected_backup
    );

    let backup_file = File::open(&expected_backup).expect("Failed opening backup zip");
    let backup_zip = zip::ZipArchive::new(backup_file).expect("Failed parsing backup zip");
    assert!(backup_zip.len() > 0, "Backup zip should contain outgoing files");

    // 6. Verify freshness table updated to "clean"
    let freshness_state: String = conn
        .query_row(
            "SELECT state FROM freshness WHERE flavour = 'retail'",
            [],
            |r| r.get(0),
        )
        .expect("Freshness row not found");
    assert_eq!(freshness_state, "clean", "Freshness state was not set to clean");

    // 7. Verify check_results cleared to up_to_date
    let details_cr_status: String = conn
        .query_row(
            "SELECT status FROM check_results WHERE addon_id = 'addon-details'",
            [],
            |r| r.get(0),
        )
        .expect("check_results row for details not found");
    assert_eq!(details_cr_status, "up_to_date", "Details status was not cleared to up_to_date");

    let dbm_cr_status: String = conn
        .query_row(
            "SELECT status FROM check_results WHERE addon_id = 'addon-dbm'",
            [],
            |r| r.get(0),
        )
        .expect("check_results row for dbm not found");
    assert_eq!(dbm_cr_status, "up_to_date", "DBM status was not cleared to up_to_date");
}

#[tokio::test]
async fn test_e2e_pinning_and_ignore_updates() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (pinning and ignore)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let details_dir = retail_addons.join("Details");
    fs::create_dir_all(&details_dir).expect("Failed creating details dir");

    let local_app_data = temp.path().join("local_app_data");
    fs::create_dir_all(&local_app_data).expect("Failed creating local_app_data");

    let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
    let orig_localappdata = std::env::var("LOCALAPPDATA").ok();
    let orig_cf_baseurl = std::env::var("FURPHY_TEST_CF_BASEURL").ok();

    std::env::set_var("LOCALAPPDATA", local_app_data.to_str().unwrap());
    std::env::set_var("FURPHY_DEV_WOWROOT", wow_root.to_str().unwrap());
    let _cleanup = TestGuard {
        orig_wowroot,
        orig_localappdata,
        orig_cf_baseurl,
    };

    // Initial files on disk at version 1.0.0
    fs::write(
        details_dir.join("Details.toc"),
        "## Interface: 110002\n## Title: Details\n## Version: 1.0.0\n",
    )
    .unwrap();
    fs::write(details_dir.join("Details.lua"), "print('Details v1.0.0 initial')").unwrap();

    let details_v11_zip = build_zip_buffer(&[
        (
            "Details/Details.toc",
            b"## Interface: 110002\n## Title: Details\n## Version: 1.1.0\n",
        ),
        (
            "Details/Details.lua",
            b"print('Details v1.1.0 updated')",
        ),
    ]);

    let (cf_base_url, _shutdown) = spawn_mock_curseforge_server(details_v11_zip).await;
    std::env::set_var("FURPHY_TEST_CF_BASEURL", &cf_base_url);

    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite conn");
    conn.execute_batch(INITIAL_SCHEMA).expect("Failed initializing schema");

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    )
    .unwrap();

    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id, version, file_id, file_name, installed_at, adopted) \
         VALUES ('addon-details', 'retail', 'Details', 'curseforge', 1002, '1.0.0', '5001', 'details-1.0.zip', '2026-10-20T00:00:00Z', 0)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'Details', 'addon-details')",
        [],
    )
    .unwrap();

    let policy = Arc::new(NetworkPolicy::default());
    let runner = Arc::new(JobRunner::new(policy));

    // 1. Pin addon to current file_id "5001" via furphy_lib::engine::pin::pin_addon
    pin_addon(&conn, "addon-details", "5001").expect("pin_addon failed");

    let pinned_id: Option<String> = conn
        .query_row(
            "SELECT pinned_file_id FROM addons WHERE id = 'addon-details'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(pinned_id.as_deref(), Some("5001"), "Addon was not pinned");

    // 2. Run sync job: pinned addon must be reported Up-to-date and NOT overwritten
    let pin_job = runner
        .run_job(&mut conn, "sync", Some("retail"), Value::Null)
        .await
        .expect("Sync job failed");
    assert_eq!(pin_job.state, "completed");

    let pin_results: Value = serde_json::from_str(pin_job.results.as_ref().unwrap()).unwrap();
    let details_pin_status = pin_results["results"]
        .as_array()
        .and_then(|arr| arr.iter().find(|x| x["addon_id"] == "addon-details"))
        .and_then(|x| x["status"].as_str())
        .unwrap();
    assert_eq!(details_pin_status, "Up-to-date", "Pinned addon should be marked Up-to-date");

    // Disk content must remain v1.0.0 initial
    assert_eq!(
        fs::read_to_string(details_dir.join("Details.lua")).unwrap(),
        "print('Details v1.0.0 initial')",
        "Pinned addon was modified on disk"
    );

    // 3. Unpin addon via unpin_addon
    unpin_addon(&conn, "addon-details").expect("unpin_addon failed");
    let unpinned_id: Option<String> = conn
        .query_row(
            "SELECT pinned_file_id FROM addons WHERE id = 'addon-details'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(unpinned_id, None, "Addon was not unpinned");

    // 4. Toggle ignore_updates via furphy_lib::engine::ignore::set_ignore_updates
    set_ignore_updates(&conn, "addon-details", true).expect("set_ignore_updates failed");

    let ignored_flag: i32 = conn
        .query_row(
            "SELECT ignore_updates FROM addons WHERE id = 'addon-details'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(ignored_flag, 1, "ignore_updates flag was not set to 1");

    // 5. Run sync job: ignored addon must be skipped and logged as "Ignored"
    let ignore_job = runner
        .run_job(&mut conn, "sync", Some("retail"), Value::Null)
        .await
        .expect("Sync job failed");
    assert_eq!(ignore_job.state, "completed");

    let ignore_results: Value = serde_json::from_str(ignore_job.results.as_ref().unwrap()).unwrap();
    let details_ignore_status = ignore_results["results"]
        .as_array()
        .and_then(|arr| arr.iter().find(|x| x["addon_id"] == "addon-details"))
        .and_then(|x| x["status"].as_str())
        .unwrap();
    assert_eq!(details_ignore_status, "Ignored", "Ignored addon status should be 'Ignored'");

    // Verify disk remains untouched
    assert_eq!(
        fs::read_to_string(details_dir.join("Details.lua")).unwrap(),
        "print('Details v1.0.0 initial')",
        "Ignored addon was modified on disk"
    );
}
