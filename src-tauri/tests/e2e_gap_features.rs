use std::fs;
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
use furphy_lib::engine::activity::list_activity_records;
use furphy_lib::engine::integrity::{generate_manifest_for_folders, record_manifest, verify_addon_integrity, IntegrityStatus};
use furphy_lib::engine::pin::pin_addon;
use furphy_lib::engine::sync::run_sync_for_flavour_with_options;
use furphy_lib::engine::update_control::set_addon_auto_update;
use furphy_lib::engine::update_policy::SyncOrigin;
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

async fn spawn_mock_curseforge_server(
    details_zip: Vec<u8>,
    recount_zip: Vec<u8>,
) -> (String, tokio::sync::oneshot::Sender<()>) {
    spawn_mock_curseforge_server_with_details_gv(details_zip, recount_zip, "11.0.2").await
}

/// The newest Details file declares `details_gv` as its game version, which is the only source the hold-back decision reads.
async fn spawn_mock_curseforge_server_with_details_gv(
    details_zip: Vec<u8>,
    recount_zip: Vec<u8>,
    details_gv: &str,
) -> (String, tokio::sync::oneshot::Sender<()>) {
    let details_gv = details_gv.to_string();
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
                        let details_data = details_zip.clone();
                        let recount_data = recount_zip.clone();
                        let details_gv = details_gv.clone();
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
                                let details_files_body = format!(
                                    r#"{{"data":[{{"id":5002,"displayName":"Details 1.1.0","fileName":"details-1.1.zip","releaseType":1,"projectId":1002,"gameVersions":["{}"],"gameVersionTypeIds":[517]}}]}}"#,
                                    details_gv
                                );
                                let body = if path.contains("/mods/1001/") {
                                    r#"{"data":[{"id":5000,"displayName":"DBM 1.0.0","fileName":"dbm-1.0.zip","releaseType":1,"projectId":1001,"gameVersions":["11.0.2"],"gameVersionTypeIds":[517]}]}"#
                                } else if path.contains("/mods/1003/") {
                                    r#"{"data":[{"id":6002,"displayName":"Recount 1.1.0","fileName":"recount-1.1.zip","releaseType":1,"projectId":1003,"gameVersions":["11.0.2"],"gameVersionTypeIds":[517]}]}"#
                                } else if path.contains("/mods/9999/") {
                                    r#"{"data":[{"id":9999,"displayName":"Failing 1.0.0","fileName":"failing-1.0.zip","releaseType":1,"projectId":9999,"gameVersions":["11.0.2"],"gameVersionTypeIds":[517]}]}"#
                                } else {
                                    details_files_body.as_str()
                                };
                                let resp = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                    body.len(),
                                    body
                                );
                                let _ = socket.write_all(resp.as_bytes()).await;
                            } else if path.contains("/files/5001") {
                                let body = r#"{"data":{"id":5001,"displayName":"Details 1.0.0","fileName":"details-1.0.zip","releaseType":1,"projectId":1002,"gameVersions":["11.0.2"],"gameVersionTypeIds":[517]}}"#;
                                let resp = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                    body.len(),
                                    body
                                );
                                let _ = socket.write_all(resp.as_bytes()).await;
                            } else if path.ends_with("/download") {
                                if path.contains("/mods/9999/") {
                                    let not_found = "HTTP/1.1 404 NOT FOUND\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                                    let _ = socket.write_all(not_found.as_bytes()).await;
                                } else if path.contains("/mods/1003/") {
                                    let resp_header = format!(
                                        "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                        recount_data.len()
                                    );
                                    let _ = socket.write_all(resp_header.as_bytes()).await;
                                    let _ = socket.write_all(&recount_data).await;
                                } else {
                                    let resp_header = format!(
                                        "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                        details_data.len()
                                    );
                                    let _ = socket.write_all(resp_header.as_bytes()).await;
                                    let _ = socket.write_all(&details_data).await;
                                }
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
async fn test_gap_auto_update_control_background_skips_manual_installs() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (auto_update)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let retail_wtf = wow_root.join("_retail_").join("WTF");

    let details_dir = retail_addons.join("Details");
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

    fs::write(
        details_dir.join("Details.toc"),
        "## Interface: 110002\n## Title: Details\n## Version: 1.0.0\n",
    )
    .unwrap();
    fs::write(details_dir.join("Details.lua"), "print('Details v1.0.0 old')").unwrap();

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

    let (cf_base_url, _shutdown) = spawn_mock_curseforge_server(details_v11_zip, Vec::new()).await;
    std::env::set_var("FURPHY_TEST_CF_BASEURL", &cf_base_url);

    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite memory conn");
    conn.execute_batch(INITIAL_SCHEMA).expect("Failed initializing schema");

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    )
    .unwrap();

    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id, version, file_id, file_name, installed_at, adopted, auto_update) \
         VALUES ('addon-details', 'retail', 'Details', 'curseforge', 1002, '1.0.0', '5001', 'details-1.0.zip', '2026-10-20T00:00:00Z', 0, 1)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'Details', 'addon-details')",
        [],
    )
    .unwrap();

    set_addon_auto_update(&conn, "addon-details", false).expect("set_addon_auto_update failed");

    let policy = Arc::new(NetworkPolicy::default());
    let data_dir = get_data_dir();

    // 1. Background sync must skip addon with auto_update = 0
    let bg_report = run_sync_for_flavour_with_options(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        None,
        false,
        SyncOrigin::Background,
        false,
        false,
        false,
    )
    .await
    .expect("Background sync failed");

    assert_eq!(bg_report.updated, 0, "Background sync should not update auto_update=0 addon");
    let bg_result = bg_report
        .results
        .iter()
        .find(|r| r.addon_id == "addon-details")
        .expect("Result row for addon-details missing");
    assert_eq!(bg_result.status, "Skipped", "Background sync should report status 'Skipped'");
    assert_eq!(
        fs::read_to_string(details_dir.join("Details.lua")).unwrap(),
        "print('Details v1.0.0 old')",
        "File should remain untouched after background sync"
    );

    // 2. Manual sync must install addon even when auto_update = 0
    let manual_report = run_sync_for_flavour_with_options(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        None,
        false,
        SyncOrigin::Manual,
        false,
        false,
        false,
    )
    .await
    .expect("Manual sync failed");

    assert_eq!(manual_report.updated, 1, "Manual sync must install auto_update=0 addon");
    let manual_result = manual_report
        .results
        .iter()
        .find(|r| r.addon_id == "addon-details")
        .expect("Result row for addon-details missing");
    assert_eq!(manual_result.status, "Updated", "Manual sync should report status 'Updated'");
    assert_eq!(
        fs::read_to_string(details_dir.join("Details.lua")).unwrap(),
        "print('Details v1.1.0 updated')",
        "File should be updated by manual sync"
    );
}

#[tokio::test]
async fn test_gap_holdback_background_skips_and_installs_others_manual_override_installs() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (holdback)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let retail_wtf = wow_root.join("_retail_").join("WTF");

    let details_dir = retail_addons.join("Details");
    let recount_dir = retail_addons.join("Recount");
    fs::create_dir_all(&details_dir).expect("Failed creating details dir");
    fs::create_dir_all(&recount_dir).expect("Failed creating recount dir");
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

    fs::write(
        details_dir.join("Details.toc"),
        "## Interface: 110002\n## Title: Details\n## Version: 1.0.0\n",
    )
    .unwrap();
    fs::write(details_dir.join("Details.lua"), "print('Details v1.0.0 old')").unwrap();

    fs::write(
        recount_dir.join("Recount.toc"),
        "## Interface: 110002\n## Title: Recount\n## Version: 1.0.0\n",
    )
    .unwrap();
    fs::write(recount_dir.join("Recount.lua"), "print('Recount v1.0.0 old')").unwrap();

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

    let recount_v11_zip = build_zip_buffer(&[
        (
            "Recount/Recount.toc",
            b"## Interface: 110002\n## Title: Recount\n## Version: 1.1.0\n",
        ),
        (
            "Recount/Recount.lua",
            b"print('Recount v1.1.0 updated')",
        ),
    ]);

    // The newest Details file targets only 12.1.0, strictly newer than the 11.0.2 client (held); Recount's file targets 11.0.2.
    let (cf_base_url, _shutdown) =
        spawn_mock_curseforge_server_with_details_gv(details_v11_zip, recount_v11_zip, "12.1.0").await;
    std::env::set_var("FURPHY_TEST_CF_BASEURL", &cf_base_url);

    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite memory conn");
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

    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id, version, file_id, file_name, installed_at, adopted) \
         VALUES ('addon-recount', 'retail', 'Recount', 'curseforge', 1003, '1.0.0', '6001', 'recount-1.0.zip', '2026-10-20T00:00:00Z', 0)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'Recount', 'addon-recount')",
        [],
    )
    .unwrap();

    let policy = Arc::new(NetworkPolicy::default());
    let data_dir = get_data_dir();

    // 1. Background sync skips held Details and installs Recount
    let bg_report = run_sync_for_flavour_with_options(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        None,
        false,
        SyncOrigin::Background,
        false,
        false,
        false,
    )
    .await
    .expect("Background sync failed");

    assert_eq!(bg_report.updated, 1, "Recount should have updated");
    let bg_details = bg_report
        .results
        .iter()
        .find(|r| r.addon_id == "addon-details")
        .unwrap();
    assert_eq!(bg_details.status, "Skipped");
    assert!(
        bg_details.error.as_deref().unwrap_or("").contains("Held back"),
        "Held addon should note holdback reason in error"
    );

    let bg_recount = bg_report
        .results
        .iter()
        .find(|r| r.addon_id == "addon-recount")
        .unwrap();
    assert_eq!(bg_recount.status, "Updated");

    assert_eq!(
        fs::read_to_string(details_dir.join("Details.lua")).unwrap(),
        "print('Details v1.0.0 old')",
        "Held addon should remain old on disk"
    );
    assert_eq!(
        fs::read_to_string(recount_dir.join("Recount.lua")).unwrap(),
        "print('Recount v1.1.0 updated')",
        "Compatible addon should be updated on disk"
    );

    // 2. Manual sync with override_hold = true installs the held addon
    let manual_report = run_sync_for_flavour_with_options(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        None,
        false,
        SyncOrigin::Manual,
        true,
        false,
        false,
    )
    .await
    .expect("Manual override sync failed");

    assert_eq!(manual_report.updated, 1, "Details should update under manual override_hold");
    let manual_details = manual_report
        .results
        .iter()
        .find(|r| r.addon_id == "addon-details")
        .unwrap();
    assert_eq!(manual_details.status, "Updated");

    assert_eq!(
        fs::read_to_string(details_dir.join("Details.lua")).unwrap(),
        "print('Details v1.1.0 updated')",
        "Held addon should be updated after override"
    );
}

#[tokio::test]
async fn test_gap_integrity_modified_background_skips_manual_override_updates() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (integrity)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let retail_wtf = wow_root.join("_retail_").join("WTF");

    let details_dir = retail_addons.join("Details");
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

    let (cf_base_url, _shutdown) = spawn_mock_curseforge_server(details_v11_zip, Vec::new()).await;
    std::env::set_var("FURPHY_TEST_CF_BASEURL", &cf_base_url);

    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite memory conn");
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

    // Baseline manifest generated and recorded
    let baseline_manifest = generate_manifest_for_folders(&retail_addons, &["Details".to_string()]).unwrap();
    record_manifest(&conn, "addon-details", &baseline_manifest).unwrap();

    // User modifies file on disk
    fs::write(details_dir.join("Details.lua"), "print('Details v1.0.0 user modified')").unwrap();

    let integrity_report = verify_addon_integrity(&conn, &retail_addons, "addon-details").unwrap();
    assert_eq!(integrity_report.status, IntegrityStatus::Modified);

    // Nothing has stored the status. The sync itself has to notice the edit before it replaces anything.
    let stored_before: Option<String> = conn
        .query_row("SELECT integrity_status FROM addons WHERE id = 'addon-details'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(stored_before, None);

    let policy = Arc::new(NetworkPolicy::default());
    let data_dir = get_data_dir();

    // 1. Background sync skips modified addon
    let bg_report = run_sync_for_flavour_with_options(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        None,
        false,
        SyncOrigin::Background,
        false,
        false,
        false,
    )
    .await
    .expect("Background sync failed");

    assert_eq!(bg_report.updated, 0);
    let bg_res = bg_report.results.iter().find(|r| r.addon_id == "addon-details").unwrap();
    assert_eq!(bg_res.status, "Skipped");
    assert_eq!(
        fs::read_to_string(details_dir.join("Details.lua")).unwrap(),
        "print('Details v1.0.0 user modified')",
        "Modified file must not be overwritten by background sync"
    );
    let stored_after: Option<String> = conn
        .query_row("SELECT integrity_status FROM addons WHERE id = 'addon-details'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(stored_after.as_deref(), Some("modified"), "the sync must record the edit it found");

    // 2. Manual sync with override_modified updates the addon
    let manual_report = run_sync_for_flavour_with_options(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        None,
        false,
        SyncOrigin::Manual,
        false,
        true,
        false,
    )
    .await
    .expect("Manual override sync failed");

    assert_eq!(manual_report.updated, 1);
    let manual_res = manual_report.results.iter().find(|r| r.addon_id == "addon-details").unwrap();
    assert_eq!(manual_res.status, "Updated");
    assert_eq!(
        fs::read_to_string(details_dir.join("Details.lua")).unwrap(),
        "print('Details v1.1.0 updated')",
        "File should be updated after manual override_modified"
    );
}

#[tokio::test]
async fn test_gap_manifest_and_activity_recorded_on_success_and_failure_non_aborting() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (manifest & activity)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let retail_wtf = wow_root.join("_retail_").join("WTF");

    let details_dir = retail_addons.join("Details");
    let failing_dir = retail_addons.join("FailingAddon");
    fs::create_dir_all(&details_dir).expect("Failed creating details dir");
    fs::create_dir_all(&failing_dir).expect("Failed creating failing dir");
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

    fs::write(
        details_dir.join("Details.toc"),
        "## Interface: 110002\n## Title: Details\n## Version: 1.0.0\n",
    )
    .unwrap();
    fs::write(details_dir.join("Details.lua"), "print('Details v1.0.0')").unwrap();

    fs::write(
        failing_dir.join("FailingAddon.toc"),
        "## Interface: 110002\n## Title: Failing Addon\n## Version: 0.9.0\n",
    )
    .unwrap();
    fs::write(failing_dir.join("FailingAddon.lua"), "print('Failing v0.9.0')").unwrap();

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

    // Mod 9999 has no valid zip; download endpoint returns 404
    let (cf_base_url, _shutdown) = spawn_mock_curseforge_server(details_v11_zip, Vec::new()).await;
    std::env::set_var("FURPHY_TEST_CF_BASEURL", &cf_base_url);

    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite memory conn");
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

    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id, version, file_id, file_name, installed_at, adopted) \
         VALUES ('addon-failing', 'retail', 'Failing Addon', 'curseforge', 9999, '0.9.0', '9998', 'fail-0.9.zip', '2026-10-20T00:00:00Z', 0)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES ('retail', 'FailingAddon', 'addon-failing')",
        [],
    )
    .unwrap();

    let policy = Arc::new(NetworkPolicy::default());
    let data_dir = get_data_dir();

    let sync_report = run_sync_for_flavour_with_options(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        None,
        false,
        SyncOrigin::Manual,
        false,
        false,
        false,
    )
    .await
    .expect("Sync must complete without aborting on individual addon error");

    assert_eq!(sync_report.updated, 1, "Successful addon should update");
    assert_eq!(sync_report.failed, 1, "Failing addon should be marked failed");

    // 1. addon_manifests table has rows for successfully installed addon
    let manifest_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM addon_manifests WHERE addon_id = 'addon-details'",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    assert!(manifest_count > 0, "addon_manifests table must have rows for updated addon");

    // 2. Activity records exist for success and failure
    let activities = list_activity_records(&conn, Some("retail"), None).expect("list_activity_records failed");

    let details_activity = activities
        .iter()
        .find(|a| a.addon_id == "addon-details")
        .expect("Activity record for Details must exist");
    assert!(
        details_activity.kind == "updated" || details_activity.kind == "installed",
        "Details activity kind must be updated or installed, got {}",
        details_activity.kind
    );

    let failing_activity = activities
        .iter()
        .find(|a| a.addon_id == "addon-failing")
        .expect("Activity record for failing addon must exist");
    assert_eq!(failing_activity.kind, "failed", "Failing addon activity kind must be failed");
    assert!(failing_activity.error.is_some(), "Failing activity record must contain error text");
}

#[tokio::test]
async fn test_gap_modified_files_backup_keeps_user_edits_and_a_failed_backup_blocks_the_update() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (modified backup)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let retail_wtf = wow_root.join("_retail_").join("WTF");
    let details_dir = retail_addons.join("Details");
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

    let (cf_base_url, _shutdown) = spawn_mock_curseforge_server(details_v11_zip, Vec::new()).await;
    std::env::set_var("FURPHY_TEST_CF_BASEURL", &cf_base_url);

    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite memory conn");
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

    let baseline_manifest = generate_manifest_for_folders(&retail_addons, &["Details".to_string()]).unwrap();
    record_manifest(&conn, "addon-details", &baseline_manifest).unwrap();
    fs::write(details_dir.join("Details.lua"), "print('Details v1.0.0 user modified')").unwrap();

    let policy = Arc::new(NetworkPolicy::default());
    let data_dir = get_data_dir();
    let addon_backup_dir = data_dir.join("backups").join("retail").join("addon-details");

    // A regular file where the backup folder belongs makes the requested backup impossible.
    fs::create_dir_all(addon_backup_dir.parent().unwrap()).unwrap();
    fs::write(&addon_backup_dir, "not a folder").unwrap();

    let blocked = run_sync_for_flavour_with_options(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        None,
        false,
        SyncOrigin::Manual,
        false,
        true,
        true,
    )
    .await
    .expect("Sync must complete even when the backup fails");

    assert_eq!(blocked.updated, 0);
    assert_eq!(blocked.failed, 1);
    let blocked_res = blocked.results.iter().find(|r| r.addon_id == "addon-details").unwrap();
    assert_eq!(blocked_res.status, "Failed");
    assert!(
        blocked_res.error.as_deref().unwrap_or("").starts_with("Could not back up your modified files"),
        "unexpected error: {:?}",
        blocked_res.error
    );
    assert_eq!(
        fs::read_to_string(details_dir.join("Details.lua")).unwrap(),
        "print('Details v1.0.0 user modified')",
        "A failed backup must leave the user's edit in place"
    );

    // With the folder available the backup is written, holds the user's edit, and the update goes through.
    fs::remove_file(&addon_backup_dir).unwrap();
    let done = run_sync_for_flavour_with_options(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        None,
        false,
        SyncOrigin::Manual,
        false,
        true,
        true,
    )
    .await
    .expect("Sync with a working backup failed");

    assert_eq!(done.updated, 1);
    assert_eq!(
        fs::read_to_string(details_dir.join("Details.lua")).unwrap(),
        "print('Details v1.1.0 updated')"
    );

    let zips: Vec<_> = fs::read_dir(&addon_backup_dir)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.file_name().and_then(|n| n.to_str()).map(|n| n.ends_with("_modified.zip")).unwrap_or(false))
        .collect();
    assert_eq!(zips.len(), 1, "exactly one modified-files backup is expected");

    let mut archive = zip::ZipArchive::new(fs::File::open(&zips[0]).unwrap()).unwrap();
    let mut saved = None;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).unwrap();
        if entry.name().ends_with("Details.lua") {
            let mut text = String::new();
            std::io::Read::read_to_string(&mut entry, &mut text).unwrap();
            saved = Some(text);
        }
    }
    assert_eq!(
        saved.as_deref(),
        Some("print('Details v1.0.0 user modified')"),
        "the backup must hold the user's edited file"
    );
}

#[tokio::test]
async fn test_gap_pinned_addon_reports_up_to_date() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (pinned unchanged)");
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

    let (cf_base_url, _shutdown) = spawn_mock_curseforge_server(details_v11_zip, Vec::new()).await;
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

    pin_addon(&conn, "addon-details", "5001").expect("pin_addon failed");

    let policy = Arc::new(NetworkPolicy::default());
    let runner = Arc::new(JobRunner::new(policy.clone()));

    // Verify existing JobRunner sync behaves identically
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

    assert_eq!(
        fs::read_to_string(details_dir.join("Details.lua")).unwrap(),
        "print('Details v1.0.0 initial')",
        "Pinned addon must remain untouched on disk"
    );
}
