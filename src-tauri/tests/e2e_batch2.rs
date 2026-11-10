use std::fs;
use std::io::Write;
use std::sync::Arc;
use rusqlite::Connection;
use serde_json::{json, Value};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

use furphy_lib::db::schema::INITIAL_SCHEMA;
use furphy_lib::jobs::runner::{JobError, JobRunner};
use furphy_lib::net::policy::NetworkPolicy;
use furphy_lib::paths::get_data_dir;
use furphy_lib::system::game::TEST_ENV_LOCK;

struct TestGuard {
    orig_wowroot: Option<String>,
    orig_localappdata: Option<String>,
    orig_cf_baseurl: Option<String>,
    orig_allow_loopback: Option<String>,
    orig_max_zip_bytes: Option<String>,
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
        if let Some(ref a) = self.orig_allow_loopback {
            std::env::set_var("FURPHY_TEST_ALLOW_LOOPBACK_URLS", a);
        } else {
            std::env::remove_var("FURPHY_TEST_ALLOW_LOOPBACK_URLS");
        }
        if let Some(ref m) = self.orig_max_zip_bytes {
            std::env::set_var("FURPHY_TEST_MAX_ZIP_BYTES", m);
        } else {
            std::env::remove_var("FURPHY_TEST_MAX_ZIP_BYTES");
        }
    }
}

impl TestGuard {
    fn new() -> Self {
        Self {
            orig_wowroot: std::env::var("FURPHY_DEV_WOWROOT").ok(),
            orig_localappdata: std::env::var("LOCALAPPDATA").ok(),
            orig_cf_baseurl: std::env::var("FURPHY_TEST_CF_BASEURL").ok(),
            orig_allow_loopback: std::env::var("FURPHY_TEST_ALLOW_LOOPBACK_URLS").ok(),
            orig_max_zip_bytes: std::env::var("FURPHY_TEST_MAX_ZIP_BYTES").ok(),
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

async fn run_failing_install_zip(
    runner: &JobRunner,
    conn: &mut Connection,
    source: &str,
) -> String {
    match runner
        .run_job(
            conn,
            "install-zip",
            Some("retail"),
            json!({ "source": source }),
        )
        .await
    {
        Ok(rec) => {
            assert_eq!(rec.state, "failed");
            rec.error.unwrap_or_default()
        }
        Err(JobError::Execution(e)) => e,
        Err(e) => panic!("Unexpected error type: {:?}", e),
    }
}

async fn spawn_zip_mock_server(zip_data: Vec<u8>) -> (String, tokio::sync::oneshot::Sender<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("Failed binding zip mock listener");
    let addr = listener.local_addr().expect("Failed getting local addr");
    let base_url = format!("http://{}", addr);

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::oneshot::channel::<()>();

    tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => break,
                res = listener.accept() => {
                    if let Ok((mut socket, _)) = res {
                        let data = zip_data.clone();
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
                            if path == "/Furphy2B.zip" || path.ends_with(".zip") {
                                let resp_header = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                    data.len()
                                );
                                let _ = socket.write_all(resp_header.as_bytes()).await;
                                let _ = socket.write_all(&data).await;
                                let _ = socket.flush().await;
                            } else {
                                let not_found = "HTTP/1.1 404 NOT FOUND\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                                let _ = socket.write_all(not_found.as_bytes()).await;
                                let _ = socket.flush().await;
                            }
                        });
                    }
                }
            }
        }
    });

    (base_url, shutdown_tx)
}

async fn spawn_copy_curseforge_server(alpha_zip: Vec<u8>) -> (String, tokio::sync::oneshot::Sender<()>) {
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
                        let alpha_data = alpha_zip.clone();
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

                            if path.contains("/mods/1001/files/7001/download") || (path.contains("/mods/1001/") && path.ends_with("/download")) {
                                let resp_header = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                    alpha_data.len()
                                );
                                let _ = socket.write_all(resp_header.as_bytes()).await;
                                let _ = socket.write_all(&alpha_data).await;
                                let _ = socket.flush().await;
                            } else if path.contains("/mods/1001/files/7001") {
                                let body = format!(
                                    r#"{{"data":{{"id":7001,"displayName":"Alpha 1.60.1","fileName":"alpha-1.60.1.zip","fileLength":{},"releaseType":1,"projectId":1001,"gameVersions":["1.60.1"],"gameVersionTypeIds":[88568],"dateCreated":"2026-11-01T00:00:00Z"}}}}"#,
                                    alpha_data.len()
                                );
                                let resp = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                    body.len(),
                                    body
                                );
                                let _ = socket.write_all(resp.as_bytes()).await;
                                let _ = socket.flush().await;
                            } else if path.contains("/mods/1001/files") {
                                let body = if path.contains("gameVersionTypeId=517") {
                                    r#"{"data":[{"id":7002,"displayName":"Alpha 11.0.2","fileName":"alpha-11.0.2.zip","releaseType":1,"projectId":1001,"gameVersions":["11.0.2"],"gameVersionTypeIds":[517],"dateCreated":"2026-10-15T00:00:00Z"}]}"#.to_string()
                                } else if path.contains("gameVersionTypeId=88568") {
                                    format!(
                                        r#"{{"data":[{{"id":7001,"displayName":"Alpha 1.60.1","fileName":"alpha-1.60.1.zip","fileLength":{},"releaseType":1,"projectId":1001,"gameVersions":["1.60.1"],"gameVersionTypeIds":[88568],"dateCreated":"2026-11-01T00:00:00Z"}}]}}"#,
                                        alpha_data.len()
                                    )
                                } else {
                                    format!(
                                        r#"{{"data":[{{"id":7001,"displayName":"Alpha 1.60.1","fileName":"alpha-1.60.1.zip","fileLength":{},"releaseType":1,"projectId":1001,"gameVersions":["1.60.1"],"gameVersionTypeIds":[88568],"dateCreated":"2026-11-01T00:00:00Z"}},{{"id":7002,"displayName":"Alpha 11.0.2","fileName":"alpha-11.0.2.zip","releaseType":1,"projectId":1001,"gameVersions":["11.0.2"],"gameVersionTypeIds":[517],"dateCreated":"2026-10-15T00:00:00Z"}}]}}"#,
                                        alpha_data.len()
                                    )
                                };
                                let resp = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                    body.len(),
                                    body
                                );
                                let _ = socket.write_all(resp.as_bytes()).await;
                                let _ = socket.flush().await;
                            } else if path.contains("/mods/1002/files") {
                                let body = if path.contains("gameVersionTypeId=88568") {
                                    r#"{"data":[]}"#
                                } else {
                                    r#"{"data":[{"id":8001,"displayName":"Beta 11.0.2","fileName":"beta-11.0.2.zip","releaseType":1,"projectId":1002,"gameVersions":["11.0.2"],"gameVersionTypeIds":[517],"dateCreated":"2026-10-15T00:00:00Z"}]}"#
                                };
                                let resp = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                    body.len(),
                                    body
                                );
                                let _ = socket.write_all(resp.as_bytes()).await;
                                let _ = socket.flush().await;
                            } else {
                                let not_found = "HTTP/1.1 404 NOT FOUND\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                                let _ = socket.write_all(not_found.as_bytes()).await;
                                let _ = socket.flush().await;
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
async fn test_batch2_install_zip_from_file() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _cleanup = TestGuard::new();

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (batch2 zip)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    fs::create_dir_all(&retail_addons).expect("Failed creating retail addons dir");

    let local_app_data = temp.path().join("local_app_data");
    fs::create_dir_all(&local_app_data).expect("Failed creating local_app_data");

    std::env::set_var("LOCALAPPDATA", local_app_data.to_str().unwrap());
    std::env::set_var("FURPHY_DEV_WOWROOT", wow_root.to_str().unwrap());

    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite memory conn");
    conn.execute_batch(INITIAL_SCHEMA).expect("Failed initializing schema");

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    )
    .expect("Failed inserting flavour");

    let zip_bytes = build_zip_buffer(&[
        (
            "Furphy2A/Furphy2A.toc",
            b"## Interface: 110002\n## Title: |cff00ff00Furphy2A|r\n## Version: 1.0.0\n",
        ),
        (
            "Furphy2A/Furphy2A.lua",
            b"print('Furphy2A main')",
        ),
        (
            "Furphy2A_Options/Furphy2A_Options.toc",
            b"## Interface: 110002\n## Title: Furphy2A Options\n## Version: 1.0.0\n",
        ),
        (
            "Furphy2A_Options/Furphy2A_Options.lua",
            b"print('Furphy2A options')",
        ),
        (
            "Doc/readme.txt",
            b"Documentation file without toc",
        ),
    ]);

    let zip_path = temp.path().join("Furphy2A.zip");
    fs::write(&zip_path, &zip_bytes).expect("Failed writing Furphy2A.zip");

    let policy = Arc::new(NetworkPolicy::default());
    let runner = JobRunner::new(policy.clone());

    let rec1 = runner
        .run_job(
            &mut conn,
            "install-zip",
            Some("retail"),
            json!({ "source": zip_path.to_str().unwrap() }),
        )
        .await
        .expect("install-zip job failed");

    assert_eq!(rec1.state, "completed");
    assert!(rec1.reload_needed);

    let res1: Value = serde_json::from_str(&rec1.results.expect("Missing results"))
        .expect("Failed parsing results JSON");
    assert_eq!(res1["addon_id"], "zip:retail:furphy2a");
    assert_eq!(res1["name"], "Furphy2A");
    assert_eq!(res1["version"], "1.0.0");
    assert_eq!(res1["replaced"], false);

    let mut folders1: Vec<String> = res1["folders"]
        .as_array()
        .expect("folders should be array")
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    folders1.sort();
    assert_eq!(folders1, vec!["Furphy2A".to_string(), "Furphy2A_Options".to_string()]);

    assert!(retail_addons.join("Furphy2A").is_dir());
    assert!(retail_addons.join("Furphy2A_Options").is_dir());
    assert!(!retail_addons.join("Doc").exists());

    let (src, name, ver): (String, String, Option<String>) = conn
        .query_row(
            "SELECT source, name, version FROM addons WHERE id = 'zip:retail:furphy2a'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .expect("addons row missing");
    assert_eq!(src, "zip");
    assert_eq!(name, "Furphy2A");
    assert_eq!(ver.as_deref(), Some("1.0.0"));

    let db_folders: Vec<String> = {
        let mut stmt = conn
            .prepare("SELECT folder FROM addon_folders WHERE addon_id = 'zip:retail:furphy2a' ORDER BY folder")
            .unwrap();
        stmt.query_map([], |r| r.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
    };
    assert_eq!(db_folders, vec!["Furphy2A", "Furphy2A_Options"]);

    let manifest_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM addon_manifests WHERE addon_id = 'zip:retail:furphy2a'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(manifest_count > 0, "addon_manifests rows must exist");

    let acts1: Vec<String> = conn
        .prepare("SELECT kind FROM activity WHERE addon_id = 'zip:retail:furphy2a'")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    assert_eq!(acts1, vec!["installed"]);

    let rec2 = runner
        .run_job(
            &mut conn,
            "install-zip",
            Some("retail"),
            json!({ "source": zip_path.to_str().unwrap() }),
        )
        .await
        .expect("reinstall job failed");

    assert_eq!(rec2.state, "completed");
    assert!(rec2.reload_needed);
    let res2: Value = serde_json::from_str(&rec2.results.expect("Missing results"))
        .expect("Failed parsing results JSON");
    assert_eq!(res2["replaced"], true);

    let acts2: Vec<String> = conn
        .prepare("SELECT kind FROM activity WHERE addon_id = 'zip:retail:furphy2a' ORDER BY rowid ASC")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    assert_eq!(acts2, vec!["installed", "updated"]);

    let rec_rem = runner
        .run_job(
            &mut conn,
            "remove",
            Some("retail"),
            json!({ "addon_id": "zip:retail:furphy2a" }),
        )
        .await
        .expect("remove job failed");
    assert_eq!(rec_rem.state, "completed");

    assert!(!retail_addons.join("Furphy2A").exists());
    assert!(!retail_addons.join("Furphy2A_Options").exists());

    let folder_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM addon_folders WHERE addon_id = 'zip:retail:furphy2a'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(folder_count, 0);

    let addon_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM addons WHERE id = 'zip:retail:furphy2a'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(addon_count, 0);
}

#[tokio::test]
async fn test_batch2_install_zip_refusals() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _cleanup = TestGuard::new();

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (batch2 refusals)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    fs::create_dir_all(&retail_addons).expect("Failed creating retail addons dir");

    let local_app_data = temp.path().join("local_app_data");
    fs::create_dir_all(&local_app_data).expect("Failed creating local_app_data");

    std::env::set_var("LOCALAPPDATA", local_app_data.to_str().unwrap());
    std::env::set_var("FURPHY_DEV_WOWROOT", wow_root.to_str().unwrap());

    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite memory conn");
    conn.execute_batch(INITIAL_SCHEMA).expect("Failed initializing schema");

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    )
    .expect("Failed inserting flavour");

    let policy = Arc::new(NetworkPolicy::default());
    let runner = JobRunner::new(policy.clone());

    let notes_path = temp.path().join("notes.txt");
    fs::write(&notes_path, "not a zip file").unwrap();
    let err1 = run_failing_install_zip(&runner, &mut conn, notes_path.to_str().unwrap()).await;
    assert!(err1.contains("That is not a .zip file."));
    assert_eq!(fs::read_dir(&retail_addons).unwrap().count(), 0);

    let nonexistent = temp.path().join("nonexistent_addon.zip");
    let err2 = run_failing_install_zip(&runner, &mut conn, nonexistent.to_str().unwrap()).await;
    assert!(err2.contains("That file does not exist:"));
    assert_eq!(fs::read_dir(&retail_addons).unwrap().count(), 0);

    let err3 = run_failing_install_zip(&runner, &mut conn, "http://example.com/addon.zip").await;
    assert!(err3.contains("Only https links are allowed."));
    assert_eq!(fs::read_dir(&retail_addons).unwrap().count(), 0);

    let err4 = run_failing_install_zip(&runner, &mut conn, "https://192.168.1.1/addon.zip").await;
    assert!(!err4.is_empty());
    assert_eq!(fs::read_dir(&retail_addons).unwrap().count(), 0);

    let no_toc_bytes = build_zip_buffer(&[
        ("NoTocFolder/readme.txt", b"plain text without any toc file"),
    ]);
    let no_toc_path = temp.path().join("NoToc.zip");
    fs::write(&no_toc_path, &no_toc_bytes).unwrap();
    let err5 = run_failing_install_zip(&runner, &mut conn, no_toc_path.to_str().unwrap()).await;
    assert!(err5.contains("This zip does not contain a World of Warcraft addon: no folder with a .toc file was found."));
    assert_eq!(fs::read_dir(&retail_addons).unwrap().count(), 0);

    // The game version's staging folder itself stays, but a refused zip leaves nothing inside it.
    let staging_retail = get_data_dir().join("staging").join("retail");
    if staging_retail.exists() {
        assert_eq!(fs::read_dir(&staging_retail).unwrap().count(), 0, "a refused zip must leave no staging folder behind");
    }
}

#[tokio::test]
async fn test_batch2_install_zip_from_link() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _cleanup = TestGuard::new();

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (batch2 link)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    fs::create_dir_all(&retail_addons).expect("Failed creating retail addons dir");

    let local_app_data = temp.path().join("local_app_data");
    fs::create_dir_all(&local_app_data).expect("Failed creating local_app_data");

    std::env::set_var("LOCALAPPDATA", local_app_data.to_str().unwrap());
    std::env::set_var("FURPHY_DEV_WOWROOT", wow_root.to_str().unwrap());
    std::env::set_var("FURPHY_TEST_ALLOW_LOOPBACK_URLS", "1");

    let zip_bytes = build_zip_buffer(&[
        (
            "Furphy2B/Furphy2B.toc",
            b"## Interface: 110002\n## Title: Furphy2B\n## Version: 1.0.0\n",
        ),
        (
            "Furphy2B/Furphy2B.lua",
            b"print('Furphy2B from URL')",
        ),
    ]);

    let (base_url, _shutdown) = spawn_zip_mock_server(zip_bytes).await;
    let zip_url = format!("{}/Furphy2B.zip", base_url);

    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite memory conn");
    conn.execute_batch(INITIAL_SCHEMA).expect("Failed initializing schema");

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    )
    .expect("Failed inserting flavour");

    let policy = Arc::new(NetworkPolicy::default());
    let runner = JobRunner::new(policy.clone());

    let rec1 = runner
        .run_job(
            &mut conn,
            "install-zip",
            Some("retail"),
            json!({ "source": &zip_url }),
        )
        .await
        .expect("URL install-zip failed");

    assert_eq!(rec1.state, "completed");
    assert!(rec1.reload_needed);
    assert!(retail_addons.join("Furphy2B").is_dir());
    assert!(retail_addons.join("Furphy2B").join("Furphy2B.toc").exists());

    let (src, name): (String, String) = conn
        .query_row(
            "SELECT source, name FROM addons WHERE id = 'zip:retail:furphy2b'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .expect("addons row missing");
    assert_eq!(src, "zip");
    assert_eq!(name, "Furphy2B");

    runner
        .run_job(
            &mut conn,
            "remove",
            Some("retail"),
            json!({ "addon_id": "zip:retail:furphy2b" }),
        )
        .await
        .expect("remove failed");
    assert!(!retail_addons.join("Furphy2B").exists());

    std::env::set_var("FURPHY_TEST_MAX_ZIP_BYTES", "100");

    let err = run_failing_install_zip(&runner, &mut conn, &zip_url).await;
    let lower_err = err.to_lowercase();
    assert!(
        lower_err.contains("size")
            || lower_err.contains("byte")
            || lower_err.contains("limit")
            || lower_err.contains("cap")
            || lower_err.contains("large")
            || lower_err.contains("exceed"),
        "Error should describe size violation, got: {}",
        err
    );

    assert!(!retail_addons.join("Furphy2B").exists(), "Addon folder should not exist");
    let addon_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM addons WHERE id = 'zip:retail:furphy2b'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(addon_count, 0, "No addons row should exist");
}

#[tokio::test]
async fn test_batch2_copy_addons() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _cleanup = TestGuard::new();

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (batch2 copy)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let forever_addons = wow_root.join("_forever_").join("Interface").join("AddOns");
    fs::create_dir_all(&retail_addons).expect("Failed creating retail addons dir");
    fs::create_dir_all(&forever_addons).expect("Failed creating forever addons dir");

    fs::create_dir_all(retail_addons.join("Alpha")).unwrap();
    fs::write(retail_addons.join("Alpha").join("Alpha.toc"), "## Interface: 110002\n## Title: Alpha\n").unwrap();
    fs::create_dir_all(retail_addons.join("Beta")).unwrap();
    fs::write(retail_addons.join("Beta").join("Beta.toc"), "## Interface: 110002\n## Title: Beta\n").unwrap();
    fs::create_dir_all(retail_addons.join("Gamma")).unwrap();
    fs::write(retail_addons.join("Gamma").join("Gamma.toc"), "## Interface: 110002\n## Title: Gamma\n").unwrap();
    fs::create_dir_all(retail_addons.join("Delta")).unwrap();
    fs::write(retail_addons.join("Delta").join("Delta.toc"), "## Interface: 110002\n## Title: Delta\n").unwrap();

    let local_app_data = temp.path().join("local_app_data");
    fs::create_dir_all(&local_app_data).expect("Failed creating local_app_data");

    std::env::set_var("LOCALAPPDATA", local_app_data.to_str().unwrap());
    std::env::set_var("FURPHY_DEV_WOWROOT", wow_root.to_str().unwrap());

    let alpha_zip = build_zip_buffer(&[
        (
            "Alpha/Alpha.toc",
            b"## Interface: 16001\n## Title: Alpha\n## Version: 1.60.1\n",
        ),
        (
            "Alpha/Alpha.lua",
            b"print('Alpha Forever')",
        ),
    ]);

    let (cf_base_url, _shutdown) = spawn_copy_curseforge_server(alpha_zip).await;
    std::env::set_var("FURPHY_TEST_CF_BASEURL", &cf_base_url);

    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite memory conn");
    conn.execute_batch(INITIAL_SCHEMA).expect("Failed initializing schema");

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    )
    .expect("Failed inserting retail flavour");

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('forever', '_forever_', 'WoW Forever', 1, '1.60.1', '16001')",
        [],
    )
    .expect("Failed inserting forever flavour");

    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id) VALUES ('addon-alpha', 'retail', 'Alpha', 'curseforge', 1001)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id) VALUES ('addon-beta', 'retail', 'Beta', 'curseforge', 1002)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id) VALUES ('addon-gamma', 'retail', 'Gamma', 'curseforge', 1003)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO addons (id, flavour, name, source) VALUES ('zip:retail:delta', 'retail', 'Delta', 'zip')",
        [],
    )
    .unwrap();

    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id) VALUES ('forever-gamma', 'forever', 'Gamma', 'curseforge', 1003)",
        [],
    )
    .unwrap();

    let policy = Arc::new(NetworkPolicy::default());
    let runner = JobRunner::new(policy.clone());

    let rec = runner
        .run_job(
            &mut conn,
            "copy-addons",
            Some("retail"),
            json!({
                "target_flavour": "forever",
                "addon_ids": ["addon-alpha", "addon-beta", "addon-gamma", "zip:retail:delta"]
            }),
        )
        .await
        .expect("copy-addons job failed");

    assert_eq!(rec.state, "completed");

    let res_val: Value = serde_json::from_str(&rec.results.expect("Missing results"))
        .expect("Failed parsing copy-addons results");
    let items = res_val["items"]
        .as_array()
        .expect("items should be an array");

    assert_eq!(items.len(), 4);

    assert_eq!(items[0]["addon_id"], "addon-alpha");
    assert_eq!(items[0]["status"], "installed");
    assert!(forever_addons.join("Alpha").is_dir());
    assert!(forever_addons.join("Alpha").join("Alpha.toc").exists());
    let forever_alpha_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM addons WHERE flavour = 'forever' AND project_id = 1001",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(forever_alpha_count, 1);

    // The release date of the file that was installed comes from the install itself, never from the test.
    let alpha_released: Option<String> = conn
        .query_row(
            "SELECT released_at FROM addons WHERE flavour = 'forever' AND project_id = 1001",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(alpha_released.as_deref(), Some("2026-11-01T00:00:00Z"));

    assert_eq!(items[1]["addon_id"], "addon-beta");
    assert_eq!(items[1]["status"], "failed");
    let beta_msg = items[1]["message"].as_str().unwrap_or("");
    assert!(
        beta_msg.contains("WoW Forever"),
        "Beta error should name WoW Forever, got: {}",
        beta_msg
    );
    assert!(!forever_addons.join("Beta").exists());
    let forever_beta_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM addons WHERE flavour = 'forever' AND project_id = 1002",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(forever_beta_count, 0);

    assert_eq!(items[2]["addon_id"], "addon-gamma");
    assert_eq!(items[2]["status"], "skipped");
    let gamma_msg = items[2]["message"].as_str().unwrap_or("");
    assert!(
        gamma_msg.contains("Already in forever"),
        "Gamma message should say 'Already in forever', got: {}",
        gamma_msg
    );

    assert_eq!(items[3]["addon_id"], "zip:retail:delta");
    assert_eq!(items[3]["status"], "skipped");
    let delta_msg = items[3]["message"].as_str().unwrap_or("");
    assert!(
        delta_msg.to_lowercase().contains("zip"),
        "Delta message should contain zip text, got: {}",
        delta_msg
    );

    assert!(retail_addons.join("Alpha").exists());
    assert!(retail_addons.join("Beta").exists());
    assert!(retail_addons.join("Gamma").exists());
    assert!(retail_addons.join("Delta").exists());

    let retail_addon_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM addons WHERE flavour = 'retail'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(retail_addon_count, 4);

    assert!(!wow_root.join("_retail_").join("WTF").exists());
    assert!(!wow_root.join("_forever_").join("WTF").exists());
}

#[tokio::test]
async fn test_batch2_groups_round_trip() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _cleanup = TestGuard::new();

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (batch2 groups)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    fs::create_dir_all(&retail_addons).expect("Failed creating retail addons dir");

    let local_app_data = temp.path().join("local_app_data");
    fs::create_dir_all(&local_app_data).expect("Failed creating local_app_data");

    std::env::set_var("LOCALAPPDATA", local_app_data.to_str().unwrap());
    std::env::set_var("FURPHY_DEV_WOWROOT", wow_root.to_str().unwrap());

    let mut conn = Connection::open_in_memory().expect("Failed opening sqlite memory conn");
    conn.execute_batch(INITIAL_SCHEMA).expect("Failed initializing schema");

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    )
    .expect("Failed inserting flavour");

    let zip_bytes = build_zip_buffer(&[
        (
            "Furphy2A/Furphy2A.toc",
            b"## Interface: 110002\n## Title: |cff00ff00Furphy2A|r\n## Version: 1.0.0\n",
        ),
        (
            "Furphy2A/Furphy2A.lua",
            b"print('Furphy2A main')",
        ),
        (
            "Furphy2A_Options/Furphy2A_Options.toc",
            b"## Interface: 110002\n## Title: Furphy2A Options\n## Version: 1.0.0\n",
        ),
    ]);

    let zip_path = temp.path().join("Furphy2A.zip");
    fs::write(&zip_path, &zip_bytes).expect("Failed writing Furphy2A.zip");

    let policy = Arc::new(NetworkPolicy::default());
    let runner = JobRunner::new(policy.clone());

    let rec1 = runner
        .run_job(
            &mut conn,
            "install-zip",
            Some("retail"),
            json!({ "source": zip_path.to_str().unwrap() }),
        )
        .await
        .expect("install-zip job failed");
    assert_eq!(rec1.state, "completed");

    furphy_lib::engine::groups::set_favourite(&conn, "zip:retail:furphy2a", true)
        .expect("set_favourite failed");

    let group = furphy_lib::engine::groups::create_group(&conn, "Essential Addons")
        .expect("create_group failed");
    furphy_lib::engine::groups::set_addon_group(&conn, "zip:retail:furphy2a", &group.id, true)
        .expect("set_addon_group failed");

    let fav_before: i64 = conn
        .query_row(
            "SELECT favourite FROM addons WHERE id = 'zip:retail:furphy2a'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(fav_before, 1);

    let map_before = furphy_lib::engine::groups::group_ids_by_addon(&conn).unwrap();
    assert!(map_before.get("zip:retail:furphy2a").unwrap().contains(&group.id));

    let rec2 = runner
        .run_job(
            &mut conn,
            "install-zip",
            Some("retail"),
            json!({ "source": zip_path.to_str().unwrap() }),
        )
        .await
        .expect("reinstall job failed");
    assert_eq!(rec2.state, "completed");

    let res2: Value = serde_json::from_str(&rec2.results.expect("Missing results")).unwrap();
    assert_eq!(res2["replaced"], true);

    let fav_after: i64 = conn
        .query_row(
            "SELECT favourite FROM addons WHERE id = 'zip:retail:furphy2a'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(fav_after, 1, "favourite flag must survive reinstall");

    let map_after = furphy_lib::engine::groups::group_ids_by_addon(&conn).unwrap();
    let member_groups = map_after
        .get("zip:retail:furphy2a")
        .expect("addon should have group memberships");
    assert!(
        member_groups.contains(&group.id),
        "group membership must survive reinstall"
    );

    let groups_list = furphy_lib::engine::groups::list_groups(&conn).unwrap();
    let found_group = groups_list.iter().find(|g| g.id == group.id).unwrap();
    assert_eq!(found_group.member_count, 1);
}

struct EnvVarGuard {
    key: &'static str,
    previous: Option<String>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let previous = std::env::var(key).ok();
        std::env::set_var(key, value);
        Self { key, previous }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        match &self.previous {
            Some(v) => std::env::set_var(self.key, v),
            None => std::env::remove_var(self.key),
        }
    }
}

/// Serves Tukui's addon list (ElvUI and Tukui with the game versions the live API lists today) and the ElvUI zip.
async fn spawn_tukui_server(elvui_zip: Vec<u8>) -> (String, tokio::sync::oneshot::Sender<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("Failed binding mock listener");
    let addr = listener.local_addr().expect("Failed getting local addr");
    let base_url = format!("http://{}", addr);
    let list_body = format!(
        r#"[{{"id":"-2","slug":"elvui","author":"Elv","name":"ElvUI","url":"{base}/v1/download/elvui/12.1.5","version":"12.1.5","patch":["12.1.5","1.60.1","5.5.4","1.15.9","2.5.6"],"last_update":"2026-11-09","web_url":"https://www.tukui.org/addons.php?id=-2","small_desc":"A complete UI","directories":["ElvUI","ElvUI_Libraries","ElvUI_Options"]}},{{"id":-1,"slug":"tukui","author":"Tukz","name":"Tukui","url":"{base}/v1/download/tukui/11.1.7","version":"11.1.7","patch":["11.1.7","5.5.0","1.15.7"],"last_update":"2026-10-15","directories":["Tukui"]}}]"#,
        base = base_url
    );

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => break,
                res = listener.accept() => {
                    if let Ok((mut socket, _)) = res {
                        let zip_data = elvui_zip.clone();
                        let list = list_body.clone();
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
                            if path == "/v1/addons" {
                                let resp = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                    list.len(),
                                    list
                                );
                                let _ = socket.write_all(resp.as_bytes()).await;
                            } else if path.starts_with("/v1/download/elvui/") {
                                let header = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                    zip_data.len()
                                );
                                let _ = socket.write_all(header.as_bytes()).await;
                                let _ = socket.write_all(&zip_data).await;
                            } else {
                                let _ = socket.write_all(b"HTTP/1.1 404 NOT FOUND\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
                            }
                            let _ = socket.flush().await;
                        });
                    }
                }
            }
        }
    });
    (base_url, shutdown_tx)
}

#[tokio::test]
async fn test_batch2_tukui_add_installs_for_a_listed_game_version_and_refuses_an_unlisted_one() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _cleanup = TestGuard::new();

    let temp = tempdir().expect("Failed to create tempdir");
    let wow_root = temp.path().join("furphy test wow (batch2 tukui)");
    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let forever_addons = wow_root.join("_forever_").join("Interface").join("AddOns");
    fs::create_dir_all(&retail_addons).unwrap();
    fs::create_dir_all(&forever_addons).unwrap();
    let local_app_data = temp.path().join("local_app_data");
    fs::create_dir_all(&local_app_data).unwrap();
    std::env::set_var("LOCALAPPDATA", local_app_data.to_str().unwrap());
    std::env::set_var("FURPHY_DEV_WOWROOT", wow_root.to_str().unwrap());

    let elvui_zip = build_zip_buffer(&[
        ("ElvUI/ElvUI.toc", b"## Interface: 120105\n## Title: ElvUI\n## Version: 12.1.5\n"),
        ("ElvUI/Core.lua", b"print('ElvUI')"),
        ("ElvUI_Libraries/ElvUI_Libraries.toc", b"## Interface: 120105\n## Title: ElvUI Libraries\n"),
        ("ElvUI_Options/ElvUI_Options.toc", b"## Interface: 120105\n## Title: ElvUI Options\n"),
    ]);
    let (base_url, _shutdown) = spawn_tukui_server(elvui_zip).await;
    let _tukui_env = EnvVarGuard::set("FURPHY_TEST_TUKUI_BASEURL", &base_url);

    let mut conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(INITIAL_SCHEMA).unwrap();
    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) VALUES ('retail', '_retail_', 'Retail', 1, '12.1.5.70783', '120105')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) VALUES ('forever', '_forever_', 'WoW Forever', 1, '1.60.1.70862', '16001')",
        [],
    )
    .unwrap();

    let policy = Arc::new(NetworkPolicy::new());
    let runner = JobRunner::new(policy);

    // 1. ElvUI lists 12.1.5, so it installs into Retail through the normal add path.
    let record = runner
        .run_job(&mut conn, "add", Some("retail"), json!({ "target": "tukui:elvui" }))
        .await
        .expect("add job failed");
    assert_eq!(record.state, "completed");
    assert!(record.error.is_none(), "unexpected job error: {:?}", record.error);
    for folder in ["ElvUI", "ElvUI_Libraries", "ElvUI_Options"] {
        assert!(retail_addons.join(folder).is_dir(), "{} must be installed in Retail", folder);
    }
    let (source, slug, version, released): (String, String, Option<String>, Option<String>) = conn
        .query_row(
            "SELECT source, tukui_slug, version, released_at FROM addons WHERE flavour = 'retail' AND tukui_slug = 'elvui'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .expect("the Tukui addon row is missing");
    assert_eq!(source, "tukui");
    assert_eq!(slug, "elvui");
    assert_eq!(version.as_deref(), Some("12.1.5"));
    assert_eq!(released.as_deref(), Some("2026-11-09T00:00:00Z"), "the release date comes from Tukui's last_update");
    let folders: i64 = conn
        .query_row("SELECT COUNT(*) FROM addon_folders WHERE flavour = 'retail'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(folders, 3);
    let installed_activity: i64 = conn
        .query_row("SELECT COUNT(*) FROM activity WHERE flavour = 'retail' AND kind = 'installed'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(installed_activity, 1);

    // 2. Tukui does not list 1.60.x for the Tukui addon: WoW Forever gets nothing and the reason names the game version.
    let refused = runner
        .run_job(&mut conn, "add", Some("forever"), json!({ "target": "tukui:tukui" }))
        .await
        .expect("job record");
    assert!(refused.error.is_some(), "an unlisted game version must fail");
    let reason = refused.error.unwrap_or_default();
    assert!(reason.contains("WoW Forever"), "the reason names the game version, got: {}", reason);
    assert!(reason.contains("11.1.7"), "the reason lists what Tukui does list, got: {}", reason);
    assert_eq!(fs::read_dir(&forever_addons).unwrap().count(), 0, "nothing may be installed into WoW Forever");
}
