use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

use furphy_lib::commands::addons::{ignore_dependency, unignore_dependency};
use furphy_lib::db::open_connection;
use furphy_lib::db::schema::INITIAL_SCHEMA;
use furphy_lib::engine::add::AddonTarget;
use furphy_lib::engine::deps::{
    check_missing_dependencies, get_dependency_alias, get_dependency_alias_target,
    install_missing_dependencies_for_addon, resolve_dependency_target,
};
use furphy_lib::net::policy::NetworkPolicy;
use furphy_lib::paths::get_db_path;
use furphy_lib::system::game::TEST_ENV_LOCK;

struct TestContext {
    wow_dir: PathBuf,
    local_data_dir: PathBuf,
    orig_wowroot: Option<String>,
    orig_localappdata: Option<String>,
    orig_cf_baseurl: Option<String>,
}

impl TestContext {
    fn setup(name: &str) -> Self {
        let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
        let orig_localappdata = std::env::var("LOCALAPPDATA").ok();
        let orig_cf_baseurl = std::env::var("FURPHY_TEST_CF_BASEURL").ok();

        let rand_suffix = uuid::Uuid::new_v4().to_string();
        // Path MUST contain space and parentheses per ADR-307
        let wow_dir = std::env::temp_dir().join(format!("furphy e2e deps ({}_{})", name, rand_suffix));
        let local_data_dir = std::env::temp_dir().join(format!("furphy_e2e_data_{}_{}", name, rand_suffix));

        let retail_addons = wow_dir.join("_retail_").join("Interface").join("AddOns");
        let retail_wtf = wow_dir.join("_retail_").join("WTF");
        fs::create_dir_all(&retail_addons).unwrap();
        fs::create_dir_all(&retail_wtf).unwrap();
        fs::create_dir_all(&local_data_dir).unwrap();

        std::env::set_var("FURPHY_DEV_WOWROOT", wow_dir.to_str().unwrap());
        std::env::set_var("LOCALAPPDATA", local_data_dir.to_str().unwrap());

        Self {
            wow_dir,
            local_data_dir,
            orig_wowroot,
            orig_localappdata,
            orig_cf_baseurl,
        }
    }
}

impl Drop for TestContext {
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

        let _ = fs::remove_dir_all(&self.wow_dir);
        let _ = fs::remove_dir_all(&self.local_data_dir);
    }
}

fn create_test_addon_zip(folder_name: &str, toc_name: &str, toc_content: &str) -> Vec<u8> {
    let mut buf = std::io::Cursor::new(Vec::new());
    {
        let mut zip = ZipWriter::new(&mut buf);
        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        zip.start_file(format!("{}/{}.toc", folder_name, toc_name), options).unwrap();
        zip.write_all(toc_content.as_bytes()).unwrap();
        zip.start_file(format!("{}/{}.lua", folder_name, toc_name), options).unwrap();
        zip.write_all(b"-- Lua script content").unwrap();
        zip.finish().unwrap();
    }
    buf.into_inner()
}

async fn run_mock_cf_server(
    listener: TcpListener,
    ace3_zip: Arc<Vec<u8>>,
    lsm_zip: Arc<Vec<u8>>,
) {
    loop {
        let (mut socket, _) = match listener.accept().await {
            Ok(s) => s,
            Err(_) => break,
        };

        let ace3 = ace3_zip.clone();
        let lsm = lsm_zip.clone();

        tokio::spawn(async move {
            let mut buf = [0u8; 4096];
            let n = match socket.read(&mut buf).await {
                Ok(n) if n > 0 => n,
                _ => return,
            };

            let req_str = String::from_utf8_lossy(&buf[..n]);
            let first_line = req_str.lines().next().unwrap_or("");
            let parts: Vec<&str> = first_line.split_whitespace().collect();
            if parts.len() < 2 {
                return;
            }
            let path = parts[1];

            if path.starts_with("/api/v1/mods/13345/files?") || path == "/api/v1/mods/13345/files" {
                let json = serde_json::json!({
                    "data": [{
                        "id": 10001,
                        "displayName": "Ace3-Release",
                        "fileName": "Ace3-1.0.0.zip",
                        "fileLength": ace3.len() as u64,
                        "releaseType": 1,
                        "projectId": 13345,
                        "gameVersions": ["11.0.2"],
                        "gameVersionTypeIds": [517],
                        "dateCreated": "2026-10-22T00:00:00Z"
                    }]
                }).to_string();

                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    json.len(),
                    json
                );
                let _ = socket.write_all(resp.as_bytes()).await;
            } else if path.contains("/api/v1/mods/13345/files/10001/download") {
                let header = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    ace3.len()
                );
                let _ = socket.write_all(header.as_bytes()).await;
                let _ = socket.write_all(&ace3).await;
            } else if path.starts_with("/api/v1/mods/13346/files?") || path == "/api/v1/mods/13346/files" {
                let json = serde_json::json!({
                    "data": [{
                        "id": 10002,
                        "displayName": "LibSharedMedia-Release",
                        "fileName": "LibSharedMedia-3.0.zip",
                        "fileLength": lsm.len() as u64,
                        "releaseType": 1,
                        "projectId": 13346,
                        "gameVersions": ["11.0.2"],
                        "gameVersionTypeIds": [517],
                        "dateCreated": "2026-10-22T00:00:00Z"
                    }]
                }).to_string();

                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    json.len(),
                    json
                );
                let _ = socket.write_all(resp.as_bytes()).await;
            } else if path.contains("/api/v1/mods/13346/files/10002/download") {
                let header = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    lsm.len()
                );
                let _ = socket.write_all(header.as_bytes()).await;
                let _ = socket.write_all(&lsm).await;
            } else {
                let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                let _ = socket.write_all(resp.as_bytes()).await;
            }
        });
    }
}

#[tokio::test]
async fn test_e2e_dependency_resolution_and_lifecycle() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    // 1. Set up sandbox WoW root with TEST_ENV_LOCK
    let ctx = TestContext::setup("lifecycle");
    let wow_root = ctx.wow_dir.clone();
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let data_dir = furphy_lib::paths::get_data_dir();
    fs::create_dir_all(&data_dir).unwrap();

    let db_path = get_db_path();
    let mut conn = open_connection(&db_path).unwrap();
    conn.execute_batch(INITIAL_SCHEMA).unwrap();

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', 110002)",
        [],
    ).unwrap();

    // Set up local catalogue cache mapping slugs to project IDs
    let cache_dir = data_dir.join("cache");
    fs::create_dir_all(&cache_dir).unwrap();
    let cat_content = serde_json::json!({
        "ace3": 13345,
        "libsharedmedia-3-0": 13346,
        "excore": 99999
    });
    fs::write(cache_dir.join("cf_catalogue.json"), cat_content.to_string()).unwrap();

    // 2. Create an addon with .toc containing ## Dependencies: Ace3, LibSharedMedia-3.0
    let main_addon_dir = retail_addons.join("MainAddon");
    fs::create_dir_all(&main_addon_dir).unwrap();
    let toc_content = "## Interface: 110002\n## Title: Main Addon\n## Version: 1.0.0\n## Dependencies: Ace3, LibSharedMedia-3.0\n";
    fs::write(main_addon_dir.join("MainAddon.toc"), toc_content).unwrap();

    conn.execute(
        "INSERT INTO addons (id, flavour, name, version, required_deps) \
         VALUES ('main-addon', 'retail', 'Main Addon', '1.0.0', '[\"Ace3\", \"LibSharedMedia-3.0\"]')",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) \
         VALUES ('retail', 'MainAddon', 'main-addon')",
        [],
    ).unwrap();

    // 3. Run check_missing_dependencies: verify it returns ["Ace3", "LibSharedMedia-3.0"]
    let missing_initial = check_missing_dependencies(&conn, "retail", "main-addon").unwrap();
    assert_eq!(missing_initial.len(), 2, "Must return exactly 2 missing dependencies");
    assert!(missing_initial.contains(&"Ace3".to_string()));
    assert!(missing_initial.contains(&"LibSharedMedia-3.0".to_string()));

    // Verify alias resolution logic directly
    assert_eq!(get_dependency_alias("exwindcore"), Some("excore"));
    assert_eq!(get_dependency_alias("exwind-core"), Some("excore"));
    assert_eq!(
        get_dependency_alias_target("exwindcore"),
        Some(AddonTarget::CurseForge(1650514))
    );

    let policy = Arc::new(NetworkPolicy::new());
    let resolved_alias = resolve_dependency_target("exwindcore", &policy, &data_dir).await;
    assert_eq!(resolved_alias, Some(AddonTarget::CurseForge(99999)));

    // 4. Trigger install_missing_dependencies: verify dependency download and installation into AddOns/Ace3
    // Set up mock HTTP server for CurseForge file query and download
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mock_addr = listener.local_addr().unwrap();
    let mock_url = format!("http://{}", mock_addr);
    std::env::set_var("FURPHY_TEST_CF_BASEURL", &mock_url);

    let ace3_zip = Arc::new(create_test_addon_zip(
        "Ace3",
        "Ace3",
        "## Interface: 110002\n## Title: Ace3\n## Version: 1.0.0\n",
    ));
    let lsm_zip = Arc::new(create_test_addon_zip(
        "LibSharedMedia-3.0",
        "LibSharedMedia-3.0",
        "## Interface: 110002\n## Title: LibSharedMedia-3.0\n## Version: 3.0.0\n",
    ));

    let server_handle = tokio::spawn(run_mock_cf_server(listener, ace3_zip, lsm_zip));

    let install_res = install_missing_dependencies_for_addon(
        &mut conn,
        &wow_root,
        "retail",
        "_retail_",
        &retail_addons,
        &data_dir,
        Some(110002),
        policy.clone(),
        None,
        "main-addon",
    )
    .await;

    assert!(install_res.is_ok(), "Dependency installation must succeed: {:?}", install_res);
    let install_summary = install_res.unwrap();
    assert_eq!(install_summary.installed_deps.len(), 2);
    assert!(install_summary.unresolved_deps.is_empty());
    assert!(install_summary.installed_deps.contains(&"Ace3".to_string()));
    assert!(install_summary.installed_deps.contains(&"LibSharedMedia-3.0".to_string()));

    // Verify Ace3 was installed into AddOns/Ace3 on disk
    let ace3_dir = retail_addons.join("Ace3");
    assert!(ace3_dir.is_dir(), "AddOns/Ace3 must be installed on disk");
    assert!(ace3_dir.join("Ace3.toc").is_file(), "Ace3.toc must exist");

    // Verify LibSharedMedia was installed on disk
    let lsm_dir = retail_addons.join("LibSharedMedia-3.0");
    assert!(lsm_dir.is_dir(), "AddOns/LibSharedMedia-3.0 must be installed on disk");

    // 5. Re-check dependencies: verify missing list is now empty
    let missing_after = check_missing_dependencies(&conn, "retail", "main-addon").unwrap();
    assert!(
        missing_after.is_empty(),
        "Missing dependencies list must be empty after installation, got: {:?}",
        missing_after
    );

    // 6. Test ignoring a dependency via ignore_dependency: verify it is filtered out of check_missing_dependencies
    // Add a new unsatisfied required dependency
    conn.execute(
        "UPDATE addons SET required_deps = '[\"Ace3\", \"LibSharedMedia-3.0\", \"OptionalExtraLib\"]' \
         WHERE id = 'main-addon'",
        [],
    ).unwrap();

    let missing_with_extra = check_missing_dependencies(&conn, "retail", "main-addon").unwrap();
    assert_eq!(missing_with_extra, vec!["OptionalExtraLib".to_string()]);

    // Ignore the extra dependency
    ignore_dependency("main-addon".to_string(), "OptionalExtraLib".to_string()).unwrap();

    // Verify that it is filtered out
    let missing_ignored = check_missing_dependencies(&conn, "retail", "main-addon").unwrap();
    assert!(
        missing_ignored.is_empty(),
        "Ignored dependency must not appear in missing dependencies list"
    );

    // Unignore and verify it appears again
    unignore_dependency("main-addon".to_string(), "OptionalExtraLib".to_string()).unwrap();
    let missing_restored = check_missing_dependencies(&conn, "retail", "main-addon").unwrap();
    assert_eq!(missing_restored, vec!["OptionalExtraLib".to_string()]);

    server_handle.abort();
}
