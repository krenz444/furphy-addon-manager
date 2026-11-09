use std::fs;
use std::path::{Path, PathBuf};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlavourDef {
    pub id: &'static str,
    pub folder: &'static str,
    pub label: &'static str,
    pub product: &'static str,
}

pub const FLAVOUR_DEFS: &[FlavourDef] = &[
    FlavourDef { id: "retail", folder: "_retail_", label: "Retail", product: "wow" },
    FlavourDef { id: "classic", folder: "_classic_", label: "Classic", product: "wow_classic" },
    FlavourDef { id: "classic_era", folder: "_classic_era_", label: "Classic Era", product: "wow_classic_era" },
    FlavourDef { id: "forever", folder: "_forever_", label: "WoW Forever", product: "wowf" },
    FlavourDef { id: "ptr", folder: "_ptr_", label: "PTR", product: "wowt" },
    FlavourDef { id: "xptr", folder: "_xptr_", label: "PTR (2)", product: "wowxptr" },
    FlavourDef { id: "beta", folder: "_beta_", label: "Beta", product: "wow_beta" },
];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClassicProgression {
    pub era_key: String,
    pub era_label: String,
    pub type_id: Option<i64>,
    pub wago_value: Option<String>,
    pub version_prefix: Option<String>,
}

pub fn resolve_classic_progression(interface: Option<i32>) -> ClassicProgression {
    if let Some(ival) = interface {
        if ival != 0 {
            if (11500..=11599).contains(&ival) {
                return ClassicProgression {
                    era_key: "classic_era".to_string(),
                    era_label: "Classic Era (Vanilla)".to_string(),
                    type_id: Some(67408),
                    wago_value: Some("classic".to_string()),
                    version_prefix: Some("1.15.".to_string()),
                };
            }
            if (16000..=16999).contains(&ival) {
                return ClassicProgression {
                    era_key: "forever".to_string(),
                    era_label: "WoW Forever".to_string(),
                    type_id: Some(88568),
                    wago_value: Some("forever".to_string()),
                    version_prefix: Some("1.60.".to_string()),
                };
            }
            if (20500..=20599).contains(&ival) {
                return ClassicProgression {
                    era_key: "tbc".to_string(),
                    era_label: "Burning Crusade Classic".to_string(),
                    type_id: Some(73246),
                    wago_value: Some("bc".to_string()),
                    version_prefix: Some("2.5.".to_string()),
                };
            }
            if (30400..=30699).contains(&ival) || (38000..=38099).contains(&ival) {
                return ClassicProgression {
                    era_key: "wrath".to_string(),
                    era_label: "Wrath Classic".to_string(),
                    type_id: Some(73713),
                    wago_value: Some("wotlk".to_string()),
                    version_prefix: Some("3.4.".to_string()),
                };
            }
            if (40400..=40499).contains(&ival) {
                return ClassicProgression {
                    era_key: "cata".to_string(),
                    era_label: "Cataclysm Classic".to_string(),
                    type_id: Some(77522),
                    wago_value: Some("cata".to_string()),
                    version_prefix: Some("4.4.".to_string()),
                };
            }
            if (50500..=50599).contains(&ival) {
                return ClassicProgression {
                    era_key: "mists".to_string(),
                    era_label: "Mists Classic".to_string(),
                    type_id: Some(79434),
                    wago_value: Some("mop".to_string()),
                    version_prefix: Some("5.5.".to_string()),
                };
            }
            if (120000..=129999).contains(&ival) {
                return ClassicProgression {
                    era_key: "retail".to_string(),
                    era_label: "Retail".to_string(),
                    type_id: Some(517),
                    wago_value: Some("retail".to_string()),
                    version_prefix: Some("12.".to_string()),
                };
            }

            // Real non-zero interface that doesn't match known progression ranges
            return ClassicProgression {
                era_key: "unknown".to_string(),
                era_label: "Unrecognized Classic client version".to_string(),
                type_id: None,
                wago_value: None,
                version_prefix: None,
            };
        }
    }

    // Default safe fallback when interface is None or 0
    ClassicProgression {
        era_key: "retail".to_string(),
        era_label: "Retail".to_string(),
        type_id: Some(517),
        wago_value: Some("retail".to_string()),
        version_prefix: Some("12.".to_string()),
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlavourMapping {
    pub type_id: Option<i64>,
    pub version_prefix: Option<String>,
    pub wago_field: Option<String>,
    pub era_label: String,
    pub era_key: String,
}

pub fn get_flavour_mapping(flavour: &str, client_interface: Option<i32>) -> FlavourMapping {
    match flavour {
        "retail" => FlavourMapping {
            type_id: Some(517),
            version_prefix: Some("12.".to_string()),
            wago_field: Some("retail".to_string()),
            era_label: "Retail".to_string(),
            era_key: "retail".to_string(),
        },
        "classic_era" => FlavourMapping {
            type_id: Some(67408),
            version_prefix: Some("1.15.".to_string()),
            wago_field: Some("classic".to_string()),
            era_label: "Classic Era (Vanilla)".to_string(),
            era_key: "classic_era".to_string(),
        },
        "forever" => FlavourMapping {
            type_id: Some(88568),
            version_prefix: Some("1.60.".to_string()),
            wago_field: Some("forever".to_string()),
            era_label: "WoW Forever".to_string(),
            era_key: "forever".to_string(),
        },
        "classic" => {
            let prog = resolve_classic_progression(client_interface);
            FlavourMapping {
                type_id: prog.type_id,
                version_prefix: prog.version_prefix,
                wago_field: prog.wago_value,
                era_label: prog.era_label,
                era_key: prog.era_key,
            }
        }
        _ => FlavourMapping {
            type_id: Some(517),
            version_prefix: Some("12.".to_string()),
            wago_field: Some("retail".to_string()),
            era_label: "Retail".to_string(),
            era_key: "retail".to_string(),
        },
    }
}

pub fn convert_to_interface_number(version_text: &str) -> Option<i32> {
    let parts: Vec<&str> = version_text.split('.').collect();
    if parts.len() >= 3 {
        let major = parts[0].parse::<i32>().ok()?;
        let minor = parts[1].parse::<i32>().ok()?;
        let patch = parts[2].parse::<i32>().ok()?;
        Some(major * 10000 + minor * 100 + patch)
    } else {
        None
    }
}

#[derive(Debug, Clone)]
pub struct InstalledFlavourInfo {
    pub id: String,
    pub folder: String,
    pub label: String,
    pub addons_path: PathBuf,
    pub client_build: Option<String>,
    pub client_interface: Option<i32>,
    pub custom_root: Option<PathBuf>,
}

pub fn resolve_custom_addons_path(custom_root: &Path) -> PathBuf {
    if custom_root
        .file_name()
        .and_then(|n| n.to_str())
        .map(|n| n.eq_ignore_ascii_case("AddOns"))
        .unwrap_or(false)
    {
        return custom_root.to_path_buf();
    }
    let addons_sub = custom_root.join("Interface").join("AddOns");
    if addons_sub.is_dir() {
        return addons_sub;
    }
    let iface = custom_root.join("Interface");
    if iface.is_dir() {
        return iface.join("AddOns");
    }
    addons_sub
}

pub fn detect_flavour_info_at_path(flavour_id: &str, custom_root: &Path) -> Option<InstalledFlavourInfo> {
    let def = FLAVOUR_DEFS.iter().find(|d| d.id == flavour_id)?;
    let addons_path = resolve_custom_addons_path(custom_root);

    let root_dir = if custom_root
        .file_name()
        .and_then(|n| n.to_str())
        .map(|n| n.eq_ignore_ascii_case("AddOns"))
        .unwrap_or(false)
    {
        custom_root
            .parent()
            .and_then(|p| p.parent())
            .unwrap_or(custom_root)
    } else {
        custom_root
    };

    let mut client_build = None;
    let mut client_interface = None;

    let build_info_rows = parse_build_info(&root_dir.join(".build.info"));
    for (prod, ver) in &build_info_rows {
        if prod == def.product {
            client_build = Some(ver.clone());
            client_interface = convert_to_interface_number(ver);
            break;
        }
    }

    if client_build.is_none() {
        let flavor_file = root_dir.join(".flavor.info");
        if let Ok(content) = fs::read_to_string(&flavor_file) {
            for line in content.lines() {
                let trimmed = line.trim();
                if !trimmed.is_empty() && !trimmed.contains('!') {
                    for (prod, ver) in &build_info_rows {
                        if prod.eq_ignore_ascii_case(trimmed) {
                            client_build = Some(ver.clone());
                            client_interface = convert_to_interface_number(ver);
                            break;
                        }
                    }
                }
            }
        }
    }

    if client_interface.is_none() && flavour_id == "forever" {
        client_interface = Some(16001);
        if client_build.is_none() {
            client_build = Some("1.60.1.0".to_string());
        }
    }

    Some(InstalledFlavourInfo {
        id: def.id.to_string(),
        folder: def.folder.to_string(),
        label: def.label.to_string(),
        addons_path,
        client_build,
        client_interface,
        custom_root: Some(root_dir.to_path_buf()),
    })
}

pub fn parse_build_info(build_info_path: &Path) -> Vec<(String, String)> {
    let mut rows = Vec::new();
    if let Ok(content) = fs::read_to_string(build_info_path) {
        let mut lines = content.lines();
        if let Some(header_line) = lines.next() {
            // Battle.net writes each column name with a type suffix ("Product!STRING:0").
            let headers: Vec<&str> = header_line
                .split('|')
                .map(|s| s.split('!').next().unwrap_or("").trim())
                .collect();
            let product_idx = headers.iter().position(|&h| h.eq_ignore_ascii_case("Product"));
            let version_idx = headers.iter().position(|&h| h.eq_ignore_ascii_case("Version"));

            if let (Some(pidx), Some(vidx)) = (product_idx, version_idx) {
                for line in lines {
                    let fields: Vec<&str> = line.split('|').map(|s| s.trim()).collect();
                    if pidx < fields.len() && vidx < fields.len() {
                        rows.push((fields[pidx].to_string(), fields[vidx].to_string()));
                    }
                }
            }
        }
    }
    rows
}

pub fn detect_installed_flavours_in_root(wow_root: &Path) -> Vec<InstalledFlavourInfo> {
    let mut result = Vec::new();
    let build_info_rows = parse_build_info(&wow_root.join(".build.info"));

    for def in FLAVOUR_DEFS {
        let folder_path = wow_root.join(def.folder);
        let addons_path = folder_path.join("Interface").join("AddOns");
        if addons_path.is_dir() {
            let mut client_build = None;
            let mut client_interface = None;

            for (prod, ver) in &build_info_rows {
                if prod == def.product {
                    client_build = Some(ver.clone());
                    client_interface = convert_to_interface_number(ver);
                    break;
                }
            }

            if client_build.is_none() {
                let flavor_file = folder_path.join(".flavor.info");
                if let Ok(content) = fs::read_to_string(&flavor_file) {
                    for line in content.lines() {
                        let trimmed = line.trim();
                        if !trimmed.is_empty() && !trimmed.contains('!') {
                            for (prod, ver) in &build_info_rows {
                                if prod.eq_ignore_ascii_case(trimmed) {
                                    client_build = Some(ver.clone());
                                    client_interface = convert_to_interface_number(ver);
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            result.push(InstalledFlavourInfo {
                id: def.id.to_string(),
                folder: def.folder.to_string(),
                label: def.label.to_string(),
                addons_path,
                client_build,
                client_interface,
                custom_root: None,
            });
        }
    }

    result
}

pub fn detect_all_installed_flavours(
    conn: &Connection,
    wow_root: Option<&Path>,
) -> Vec<InstalledFlavourInfo> {
    let mut detected = if let Some(root) = wow_root {
        detect_installed_flavours_in_root(root)
    } else {
        Vec::new()
    };

    // Query custom roots from database
    let custom_roots: Vec<(String, String)> = {
        let mut stmt = match conn.prepare("SELECT id, custom_root FROM flavours WHERE custom_root IS NOT NULL") {
            Ok(s) => s,
            Err(_) => return detected,
        };
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        });
        match rows {
            Ok(mapped) => mapped.filter_map(|r| r.ok()).collect(),
            Err(_) => Vec::new(),
        }
    };

    for (flavour_id, custom_root_str) in custom_roots {
        let path = PathBuf::from(&custom_root_str);
        if let Some(info) = detect_flavour_info_at_path(&flavour_id, &path) {
            if let Some(pos) = detected.iter().position(|f| f.id == flavour_id) {
                detected[pos] = info;
            } else {
                detected.push(info);
            }
        }
    }

    detected
}

pub fn sync_installed_flavours_to_db(
    conn: &mut Connection,
    installed: &[InstalledFlavourInfo],
) -> Result<(), rusqlite::Error> {
    let tx = conn.transaction()?;

    for flv in installed {
        tx.execute(
            "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
             VALUES (?1, ?2, ?3, 1, ?4, ?5) \
             ON CONFLICT(id) DO UPDATE SET \
                folder = excluded.folder, \
                label = excluded.label, \
                installed = 1, \
                client_build = COALESCE(excluded.client_build, flavours.client_build), \
                client_interface = COALESCE(excluded.client_interface, flavours.client_interface)",
            rusqlite::params![flv.id, flv.folder, flv.label, flv.client_build, flv.client_interface],
        )?;
    }

    let detected_ids: Vec<&str> = installed.iter().map(|f| f.id.as_str()).collect();
    let active_ids: Vec<String> = {
        let mut stmt = tx.prepare("SELECT id FROM flavours WHERE installed = 1")?;
        let ids: Result<Vec<String>, _> = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect();
        ids?
    };

    for db_id in active_ids {
        if !detected_ids.contains(&db_id.as_str()) {
            let count: i64 = tx.query_row(
                "SELECT COUNT(*) FROM addons WHERE flavour = ?1",
                rusqlite::params![db_id],
                |r| r.get(0),
            ).unwrap_or(0);
            if count == 0 {
                let has_custom_root: bool = tx.query_row(
                    "SELECT custom_root IS NOT NULL FROM flavours WHERE id = ?1",
                    rusqlite::params![db_id],
                    |r| r.get(0),
                ).unwrap_or(false);
                if !has_custom_root {
                    tx.execute(
                        "UPDATE flavours SET installed = 0 WHERE id = ?1",
                        rusqlite::params![db_id],
                    )?;
                }
            }
        }
    }

    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resolve_classic_progression() {
        let mists = resolve_classic_progression(Some(50504));
        assert_eq!(mists.era_key, "mists");
        assert_eq!(mists.type_id, Some(79434));
        assert_eq!(mists.wago_value.as_deref(), Some("mop"));

        let cata = resolve_classic_progression(Some(40402));
        assert_eq!(cata.era_key, "cata");
        assert_eq!(cata.type_id, Some(77522));

        let forever = resolve_classic_progression(Some(16001));
        assert_eq!(forever.era_key, "forever");
        assert_eq!(forever.era_label, "WoW Forever");
        assert_eq!(forever.type_id, Some(88568));
        assert_eq!(forever.wago_value.as_deref(), Some("forever"));
        assert_eq!(forever.version_prefix.as_deref(), Some("1.60."));

        let unknown = resolve_classic_progression(Some(99999));
        assert_eq!(unknown.era_key, "unknown");
        assert!(unknown.type_id.is_none());

        let default_val = resolve_classic_progression(None);
        assert_eq!(default_val.era_key, "retail");
    }

    #[test]
    fn test_convert_to_interface_number() {
        assert_eq!(convert_to_interface_number("11.0.2.56456"), Some(110002));
        assert_eq!(convert_to_interface_number("5.5.4.12345"), Some(50504));
        assert_eq!(convert_to_interface_number("4.4.2.55555"), Some(40402));
    }

    #[test]
    fn test_resolve_custom_addons_path_variants() {
        let direct_addons = PathBuf::from(r"C:\Custom\Interface\AddOns");
        assert_eq!(resolve_custom_addons_path(&direct_addons), direct_addons);

        let game_root = PathBuf::from(r"D:\Games\WoW Forever");
        assert_eq!(
            resolve_custom_addons_path(&game_root),
            game_root.join("Interface").join("AddOns")
        );
    }

    #[test]
    fn test_detect_all_installed_flavours_with_custom_root_decoupled() {
        use crate::db::schema::INITIAL_SCHEMA;

        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(INITIAL_SCHEMA).unwrap();
        crate::db::migrate::run_migrations(&mut conn).unwrap();

        let temp_dir = tempfile::tempdir().unwrap();
        let temp_root = temp_dir.path().join("WoW (Standard)");
        let retail_addons = temp_root.join("_retail_").join("Interface").join("AddOns");
        fs::create_dir_all(&retail_addons).unwrap();

        let temp_forever = temp_dir.path().join("WoW Forever (Standalone)");
        let forever_addons = temp_forever.join("Interface").join("AddOns");
        fs::create_dir_all(&forever_addons).unwrap();

        // Register custom root for forever in database
        crate::db::repo::set_flavour_custom_root(
            &conn,
            "forever",
            temp_forever.to_str().unwrap(),
        ).unwrap();

        let detected = detect_all_installed_flavours(&conn, Some(&temp_root));
        assert_eq!(detected.len(), 2);

        let retail = detected.iter().find(|f| f.id == "retail").unwrap();
        assert_eq!(retail.addons_path, retail_addons);
        assert!(retail.custom_root.is_none());

        let forever = detected.iter().find(|f| f.id == "forever").unwrap();
        assert_eq!(forever.addons_path, forever_addons);
        assert_eq!(forever.custom_root.as_deref(), Some(temp_forever.as_path()));
        assert_eq!(forever.client_interface, Some(16001));

        // Sync to DB and verify flavours are installed
        sync_installed_flavours_to_db(&mut conn, &detected).unwrap();
        let db_flavours = crate::db::repo::get_installed_flavours_db(&conn).unwrap();
        assert!(db_flavours.iter().any(|f| f.id == "retail" && f.installed));
        assert!(db_flavours.iter().any(|f| f.id == "forever" && f.installed));
    }

    // Header line of a real Battle.net .build.info: every column name carries a "!TYPE:size" suffix.
    const REAL_BUILD_INFO_HEADER: &str = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|Version!STRING:0|KeyRing!HEX:16|Product!STRING:0";

    fn write_real_format_build_info(root: &Path) {
        let row = |product: &str, version: &str| {
            format!(
                "us|1|aa|bb|cc||tpr/wow|a.example|b.example|Windows x86_64 enUS speech?:Windows x86_64 enUS text?||2026-11-08T00:00:00Z|{}||{}",
                version, product
            )
        };
        let content = format!(
            "{}\n{}\n{}\n",
            REAL_BUILD_INFO_HEADER,
            row("wow", "12.1.5.70783"),
            row("wowf", "1.60.1.70862")
        );
        fs::write(root.join(".build.info"), content).unwrap();
    }

    #[test]
    fn test_parse_build_info_reads_typed_battlenet_headers() {
        let dir = tempfile::tempdir().unwrap();
        write_real_format_build_info(dir.path());

        let rows = parse_build_info(&dir.path().join(".build.info"));
        assert_eq!(rows.len(), 2);
        assert!(rows.contains(&("wow".to_string(), "12.1.5.70783".to_string())));
        assert!(rows.contains(&("wowf".to_string(), "1.60.1.70862".to_string())));
    }

    #[test]
    fn test_detected_client_build_feeds_the_holdback_decision() {
        let dir = tempfile::tempdir().unwrap();
        write_real_format_build_info(dir.path());
        fs::create_dir_all(dir.path().join("_retail_").join("Interface").join("AddOns")).unwrap();
        fs::create_dir_all(dir.path().join("_forever_").join("Interface").join("AddOns")).unwrap();

        let detected = detect_installed_flavours_in_root(dir.path());
        let retail = detected.iter().find(|f| f.id == "retail").unwrap();
        assert_eq!(retail.client_build.as_deref(), Some("12.1.5.70783"));
        assert_eq!(retail.client_interface, Some(120105));
        let forever = detected.iter().find(|f| f.id == "forever").unwrap();
        assert_eq!(forever.client_build.as_deref(), Some("1.60.1.70862"));
        assert_eq!(forever.client_interface, Some(16001));

        let newer = vec!["12.2.0".to_string()];
        let same_patch = vec!["12.1.5".to_string()];
        assert!(crate::engine::holdback::is_update_held_back("retail", retail.client_build.as_deref(), &newer, None).is_some());
        assert_eq!(crate::engine::holdback::is_update_held_back("retail", retail.client_build.as_deref(), &same_patch, None), None);
        let forever_newer = vec!["1.60.2".to_string()];
        assert!(crate::engine::holdback::is_update_held_back("forever", forever.client_build.as_deref(), &forever_newer, None).is_some());
    }
}
