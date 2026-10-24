use std::fs;
use std::path::PathBuf;

use furphy_lib::commands::addons::fetch_addons_with_details;
use furphy_lib::db::open_connection;
use furphy_lib::db::schema::INITIAL_SCHEMA;
use furphy_lib::engine::flavours::detect_installed_flavours_in_root;
use furphy_lib::paths::get_db_path;
use furphy_lib::system::game::TEST_ENV_LOCK;
use furphy_lib::system::protocol::{
    check_protocol_consent, parse_protocol_url, ProtocolInstallRequest,
};

struct TestContext {
    wow_dir: PathBuf,
    local_data_dir: PathBuf,
    orig_wowroot: Option<String>,
    orig_localappdata: Option<String>,
}

impl TestContext {
    fn setup(name: &str) -> Self {
        let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
        let orig_localappdata = std::env::var("LOCALAPPDATA").ok();

        let rand_suffix = uuid::Uuid::new_v4().to_string();
        // Path MUST contain space and parentheses per ADR-307
        let wow_dir = std::env::temp_dir().join(format!("furphy e2e multiflavour ({}_{})", name, rand_suffix));
        let local_data_dir = std::env::temp_dir().join(format!("furphy_e2e_data_multiflavour_{}_{}", name, rand_suffix));

        fs::create_dir_all(&wow_dir).unwrap();
        fs::create_dir_all(&local_data_dir).unwrap();

        std::env::set_var("FURPHY_DEV_WOWROOT", wow_dir.to_str().unwrap());
        std::env::set_var("LOCALAPPDATA", local_data_dir.to_str().unwrap());

        Self {
            wow_dir,
            local_data_dir,
            orig_wowroot,
            orig_localappdata,
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

        let _ = fs::remove_dir_all(&self.wow_dir);
        let _ = fs::remove_dir_all(&self.local_data_dir);
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct ProtocolDispatchPayload {
    pub scheme: String,
    pub action: String,
    pub project_id: i64,
    pub file_id: Option<i64>,
    pub flavour: String,
}

pub fn parse_and_validate_protocol_dispatch(url_str: &str) -> Result<ProtocolDispatchPayload, String> {
    let raw = url_str.trim();
    if raw.is_empty() {
        return Err("Empty protocol URL".into());
    }

    let colon_pos = raw.find(':').ok_or_else(|| "Missing scheme separator ':'".to_string())?;
    let scheme = &raw[..colon_pos].to_ascii_lowercase();

    // Scheme whitelist: only curseforge, furphy, or furphy-dev
    if scheme != "curseforge" && scheme != "furphy" && scheme != "furphy-dev" {
        return Err(format!("Malformed or unsupported scheme '{}'", scheme));
    }

    let remainder = &raw[colon_pos + 1..];
    let stripped = remainder.trim_start_matches('/');

    let (path_part, query_part) = if let Some(q_pos) = stripped.find('?') {
        (&stripped[..q_pos], Some(&stripped[q_pos + 1..]))
    } else {
        (stripped, None)
    };

    let action = if path_part.starts_with("install") || path_part.is_empty() {
        "install".to_string()
    } else {
        path_part.split('/').next().unwrap_or("").to_ascii_lowercase()
    };

    if action != "install" {
        return Err(format!("Unsupported protocol action '{}'", action));
    }

    let mut project_id: Option<i64> = None;
    let mut file_id: Option<i64> = None;
    let mut flavour: String = "retail".to_string();

    if let Some(query) = query_part {
        for pair in query.split('&') {
            if let Some(eq_pos) = pair.find('=') {
                let key = pair[..eq_pos].trim().to_ascii_lowercase();
                let val = pair[eq_pos + 1..].trim();

                // Path traversal / injection defense
                if val.contains("..") || val.contains('/') || val.contains('\\') {
                    return Err(format!("Path traversal payload detected in parameter '{}'", key));
                }

                if key == "addonid" || key == "addon_id" || key == "projectid" || key == "project_id" {
                    project_id = val.parse::<i64>().ok();
                } else if key == "fileid" || key == "file_id" {
                    file_id = val.parse::<i64>().ok();
                } else if key == "flavour" || key == "flavor" {
                    let flv_clean = val.to_ascii_lowercase();
                    if flv_clean != "retail" && flv_clean != "classic" && flv_clean != "classic_era" {
                        return Err(format!("Unknown or unsupported flavour '{}'", val));
                    }
                    flavour = flv_clean;
                }
            }
        }
    }

    let pid = project_id.ok_or_else(|| "Missing or non-numeric project ID".to_string())?;
    if pid <= 0 {
        return Err("Project ID must be a positive integer".to_string());
    }

    Ok(ProtocolDispatchPayload {
        scheme: scheme.to_string(),
        action,
        project_id: pid,
        file_id,
        flavour,
    })
}

#[test]
fn test_e2e_multi_flavour_directory_isolation() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    // 1. Set up sandbox with _retail_, _classic_, and _classic_era_
    let ctx = TestContext::setup("multi_flavour");
    let wow_root = ctx.wow_dir.clone();

    let retail_addons = wow_root.join("_retail_").join("Interface").join("AddOns");
    let classic_addons = wow_root.join("_classic_").join("Interface").join("AddOns");
    let classic_era_addons = wow_root.join("_classic_era_").join("Interface").join("AddOns");

    fs::create_dir_all(&retail_addons).unwrap();
    fs::create_dir_all(wow_root.join("_retail_").join("WTF")).unwrap();
    fs::create_dir_all(&classic_addons).unwrap();
    fs::create_dir_all(wow_root.join("_classic_").join("WTF")).unwrap();
    fs::create_dir_all(&classic_era_addons).unwrap();
    fs::create_dir_all(wow_root.join("_classic_era_").join("WTF")).unwrap();

    // Create .build.info with version strings for all 3 flavours
    let build_info_content = "\
Product | Version
wow | 11.0.2.56456
wow_classic | 4.4.2.55555
wow_classic_era | 1.15.3.56000
";
    fs::write(wow_root.join(".build.info"), build_info_content).unwrap();

    // 2. Detect flavours: verify all 3 identified with distinct interface versions and folder paths
    let flavours = detect_installed_flavours_in_root(&wow_root);
    assert_eq!(flavours.len(), 3, "All 3 flavours must be detected");

    let retail_flv = flavours.iter().find(|f| f.id == "retail").expect("retail flavour missing");
    let classic_flv = flavours.iter().find(|f| f.id == "classic").expect("classic flavour missing");
    let classic_era_flv = flavours.iter().find(|f| f.id == "classic_era").expect("classic_era flavour missing");

    assert_eq!(retail_flv.folder, "_retail_");
    assert_eq!(retail_flv.client_build.as_deref(), Some("11.0.2.56456"));
    assert_eq!(retail_flv.client_interface, Some(110002));
    assert_eq!(retail_flv.addons_path, retail_addons);

    assert_eq!(classic_flv.folder, "_classic_");
    assert_eq!(classic_flv.client_build.as_deref(), Some("4.4.2.55555"));
    assert_eq!(classic_flv.client_interface, Some(40402));
    assert_eq!(classic_flv.addons_path, classic_addons);

    assert_eq!(classic_era_flv.folder, "_classic_era_");
    assert_eq!(classic_era_flv.client_build.as_deref(), Some("1.15.3.56000"));
    assert_eq!(classic_era_flv.client_interface, Some(11503));
    assert_eq!(classic_era_flv.addons_path, classic_era_addons);

    // Verify distinct directories
    assert_ne!(retail_flv.addons_path, classic_flv.addons_path);
    assert_ne!(classic_flv.addons_path, classic_era_flv.addons_path);
    assert_ne!(retail_flv.client_interface, classic_flv.client_interface);

    // 3. Install addon in retail: verify it is NOT visible in classic AddOns/ and classic DB queries
    let db_path = get_db_path();
    let conn = open_connection(&db_path).unwrap();
    conn.execute_batch(INITIAL_SCHEMA).unwrap();

    for f in &flavours {
        conn.execute(
            "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
             VALUES (?1, ?2, ?3, 1, ?4, ?5)",
            rusqlite::params![f.id, f.folder, f.label, f.client_build, f.client_interface],
        ).unwrap();
    }

    // Install an addon strictly into retail
    let retail_addon_dir = retail_addons.join("RetailOnlyAddon");
    fs::create_dir_all(&retail_addon_dir).unwrap();
    fs::write(
        retail_addon_dir.join("RetailOnlyAddon.toc"),
        "## Interface: 110002\n## Title: Retail Only Addon\n## Version: 1.0.0\n",
    ).unwrap();

    conn.execute(
        "INSERT INTO addons (id, flavour, name, version) \
         VALUES ('addon-retail-1', 'retail', 'Retail Only Addon', '1.0.0')",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO addon_folders (flavour, folder, addon_id) \
         VALUES ('retail', 'RetailOnlyAddon', 'addon-retail-1')",
        [],
    ).unwrap();

    // Verify filesystem isolation: present in retail, strictly absent in classic and classic_era
    assert!(retail_addon_dir.exists(), "Addon directory must exist in retail");
    assert!(
        !classic_addons.join("RetailOnlyAddon").exists(),
        "Retail addon MUST NOT appear in classic AddOns directory"
    );
    assert!(
        !classic_era_addons.join("RetailOnlyAddon").exists(),
        "Retail addon MUST NOT appear in classic_era AddOns directory"
    );

    // Verify SQLite database query isolation
    let retail_addons_list = fetch_addons_with_details(&conn, "retail").unwrap();
    assert_eq!(retail_addons_list.len(), 1);
    assert_eq!(retail_addons_list[0].id, "addon-retail-1");
    assert_eq!(retail_addons_list[0].name.as_deref(), Some("Retail Only Addon"));

    let classic_addons_list = fetch_addons_with_details(&conn, "classic").unwrap();
    assert!(
        classic_addons_list.is_empty(),
        "Classic query must return 0 addons, found: {:?}",
        classic_addons_list
    );

    let classic_era_addons_list = fetch_addons_with_details(&conn, "classic_era").unwrap();
    assert!(
        classic_era_addons_list.is_empty(),
        "Classic Era query must return 0 addons, found: {:?}",
        classic_era_addons_list
    );

    // Verify folder table isolation
    let classic_folder_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM addon_folders WHERE flavour = 'classic'",
        [],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(classic_folder_count, 0);

    let classic_era_folder_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM addon_folders WHERE flavour = 'classic_era'",
        [],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(classic_era_folder_count, 0);
}

#[test]
fn test_e2e_protocol_url_parsing_and_dispatch() {
    let _guard = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _ctx = TestContext::setup("protocol_test");

    // 1. Test valid curseforge://install?addonId=2382
    let cf_url = "curseforge://install?addonId=2382";
    let cf_dispatch = parse_and_validate_protocol_dispatch(cf_url).expect("Valid CurseForge protocol URL must parse");
    assert_eq!(cf_dispatch.scheme, "curseforge");
    assert_eq!(cf_dispatch.action, "install");
    assert_eq!(cf_dispatch.project_id, 2382);
    assert_eq!(cf_dispatch.file_id, None);
    assert_eq!(cf_dispatch.flavour, "retail");

    // Also verify with fileId parameter
    let cf_url_with_file = "curseforge://install?addonId=2382&fileId=98765";
    let cf_dispatch_file = parse_and_validate_protocol_dispatch(cf_url_with_file).unwrap();
    assert_eq!(cf_dispatch_file.project_id, 2382);
    assert_eq!(cf_dispatch_file.file_id, Some(98765));

    // 2. Test valid furphy://install?addonId=2382&flavour=retail
    let furphy_url = "furphy://install?addonId=2382&flavour=retail";
    let furphy_dispatch = parse_and_validate_protocol_dispatch(furphy_url).expect("Valid furphy protocol URL must parse");
    assert_eq!(furphy_dispatch.scheme, "furphy");
    assert_eq!(furphy_dispatch.action, "install");
    assert_eq!(furphy_dispatch.project_id, 2382);
    assert_eq!(furphy_dispatch.file_id, None);
    assert_eq!(furphy_dispatch.flavour, "retail");

    // Verify furphy:// with classic flavour
    let furphy_classic = "furphy://install?addonId=54321&flavour=classic";
    let furphy_classic_dispatch = parse_and_validate_protocol_dispatch(furphy_classic).unwrap();
    assert_eq!(furphy_classic_dispatch.project_id, 54321);
    assert_eq!(furphy_classic_dispatch.flavour, "classic");

    // 3. Test invalid or malicious protocol URLs (malformed schemes, path traversal payloads). Verify rejection.
    let malicious_and_invalid_urls = [
        // Malformed / dangerous schemes
        "javascript:alert(1)",
        "file:///C:/Windows/System32/calc.exe",
        "data:text/html,<script>evil()</script>",
        "http://curseforge.com/install?addonId=2382",
        "https://evil-site.com/install?addonId=2382",
        "ftp://install?addonId=2382",
        // Path traversal in parameters
        "curseforge://install?addonId=../../Windows/System32",
        "furphy://install?addonId=2382&flavour=../../etc/passwd",
        "curseforge://install?addonId=2382&fileId=..\\..\\boot.ini",
        "furphy://install?addonId=2382&flavour=folder/subfolder",
        // Malicious / unsupported actions
        "curseforge://delete?addonId=2382",
        "curseforge://execute?addonId=2382",
        "furphy://uninstall?addonId=2382",
        // Non-numeric or negative IDs
        "curseforge://install?addonId=not_a_number",
        "curseforge://install?addonId=-1",
        "curseforge://install?addonId=0",
        // Missing required ID
        "curseforge://install?foo=bar",
        "furphy://install?flavour=retail",
        // Empty / broken strings
        "",
        "   ",
        "corrupted_url_without_scheme",
    ];

    for bad in malicious_and_invalid_urls {
        let res = parse_and_validate_protocol_dispatch(bad);
        assert!(
            res.is_err(),
            "Malicious or invalid URL '{}' MUST be rejected, got: {:?}",
            bad,
            res
        );
    }

    // Verify native library protocol parser (furphy_lib::system::protocol::parse_protocol_url)
    let native_cf = "curseforge://install?addonId=2382&fileId=12345";
    let native_req = parse_protocol_url(native_cf, Some("curseforge")).unwrap();
    assert_eq!(native_req.project_id, 2382);
    assert_eq!(native_req.file_id, 12345);

    let native_dev = "furphy-dev://install?addon_id=2382&file_id=12345";
    let native_dev_req = parse_protocol_url(native_dev, Some("furphy-dev")).unwrap();
    assert_eq!(native_dev_req.project_id, 2382);
    assert_eq!(native_dev_req.file_id, 12345);

    // Native parser strict rejections
    assert!(parse_protocol_url("malicious://install?addonId=2382&fileId=12345", Some("curseforge")).is_err());
    assert!(parse_protocol_url("curseforge://delete?addonId=2382&fileId=12345", Some("curseforge")).is_err());
    assert!(parse_protocol_url("curseforge://install?addonId=abc&fileId=123", Some("curseforge")).is_err());
    assert!(parse_protocol_url("curseforge://install?addonId=0&fileId=1", Some("curseforge")).is_err());

    // Verify consent check
    let db_path = get_db_path();
    let conn = open_connection(&db_path).unwrap();
    conn.execute_batch(INITIAL_SCHEMA).unwrap();

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed) VALUES ('retail', '_retail_', 'Retail', 1)",
        [],
    ).unwrap();

    let req = ProtocolInstallRequest {
        scheme: "curseforge".into(),
        action: "install".into(),
        project_id: 2382,
        file_id: 12345,
    };

    // Initially unmanaged
    let consent_unmanaged = check_protocol_consent(&conn, &req, "retail").unwrap();
    assert!(!consent_unmanaged.already_managed);
    assert_eq!(consent_unmanaged.project_id, 2382);

    // Register addon as managed
    conn.execute(
        "INSERT INTO addons (id, flavour, name, source, project_id) \
         VALUES ('curse-2382', 'retail', 'TestCurseAddon', 'curseforge', 2382)",
        [],
    ).unwrap();

    // Now consent check reports already managed
    let consent_managed = check_protocol_consent(&conn, &req, "retail").unwrap();
    assert!(consent_managed.already_managed);
    assert_eq!(consent_managed.existing_addon_id, Some("curse-2382".into()));
    assert_eq!(consent_managed.existing_name, Some("TestCurseAddon".into()));
}
