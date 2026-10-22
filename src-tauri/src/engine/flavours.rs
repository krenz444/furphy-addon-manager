use std::fs;
use std::path::{Path, PathBuf};
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
}

pub fn parse_build_info(build_info_path: &Path) -> Vec<(String, String)> {
    let mut rows = Vec::new();
    if let Ok(content) = fs::read_to_string(build_info_path) {
        let mut lines = content.lines();
        if let Some(header_line) = lines.next() {
            let headers: Vec<&str> = header_line.split('|').map(|s| s.trim()).collect();
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

            result.push(InstalledFlavourInfo {
                id: def.id.to_string(),
                folder: def.folder.to_string(),
                label: def.label.to_string(),
                addons_path,
                client_build,
                client_interface,
            });
        }
    }

    result
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
}
