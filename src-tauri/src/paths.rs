use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlavourDef {
    pub id: &'static str,
    pub folder: &'static str,
    pub label: &'static str,
    pub first_class: bool,
}

pub const FLAVOUR_DEFS: &[FlavourDef] = &[
    FlavourDef { id: "retail", folder: "_retail_", label: "Retail", first_class: true },
    FlavourDef { id: "classic", folder: "_classic_", label: "Classic", first_class: true },
    FlavourDef { id: "classic_era", folder: "_classic_era_", label: "Classic Era", first_class: true },
    FlavourDef { id: "ptr", folder: "_ptr_", label: "PTR", first_class: false },
    FlavourDef { id: "xptr", folder: "_xptr_", label: "PTR (2)", first_class: false },
    FlavourDef { id: "beta", folder: "_beta_", label: "Beta", first_class: false },
];

pub fn is_dev() -> bool {
    if let Ok(val) = std::env::var("FURPHY_DEV") {
        return val != "0" && val.to_lowercase() != "false";
    }
    cfg!(debug_assertions)
}

pub fn get_data_dir() -> PathBuf {
    let local_app_data = match std::env::var("LOCALAPPDATA") {
        Ok(val) => PathBuf::from(val),
        Err(_) => dirs::data_local_dir().unwrap_or_else(|| PathBuf::from(".")),
    };

    let folder_name = if is_dev() {
        "krenzcreative.furphy.addonmanager.dev"
    } else {
        "krenzcreative.furphy.addonmanager"
    };

    let dir = local_app_data.join(folder_name);
    let _ = std::fs::create_dir_all(&dir);
    dir
}

pub fn get_db_path() -> PathBuf {
    get_data_dir().join("furphy.db")
}

pub fn get_backups_dir() -> PathBuf {
    let dir = get_data_dir().join("backups");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

pub fn validate_dev_wowroot(path_str: &str) -> Result<PathBuf, String> {
    let trimmed = path_str.trim();
    if trimmed.is_empty() {
        return Err("FURPHY_DEV_WOWROOT is empty".into());
    }
    if !trimmed.contains(' ') {
        return Err("FURPHY_DEV_WOWROOT path must contain spaces per live-PC safety rules (ADR-307)".into());
    }
    if !trimmed.contains('(') || !trimmed.contains(')') {
        return Err("FURPHY_DEV_WOWROOT path must contain parentheses per live-PC safety rules (ADR-307)".into());
    }
    let path = PathBuf::from(trimmed);
    if !path.exists() {
        return Err(format!("FURPHY_DEV_WOWROOT path does not exist: {}", trimmed));
    }
    Ok(path)
}

pub fn detect_wow_root(override_path: Option<&str>) -> Result<PathBuf, String> {
    if let Some(ov) = override_path {
        let trimmed = ov.trim();
        if !trimmed.is_empty() {
            let p = PathBuf::from(trimmed);
            if p.exists() {
                return Ok(p);
            } else {
                return Err(format!("Override WoW path does not exist: {}", trimmed));
            }
        }
    }

    if is_dev() {
        match std::env::var("FURPHY_DEV_WOWROOT") {
            Ok(val) => return validate_dev_wowroot(&val),
            Err(_) => {
                return Err("Dev build refused to start: FURPHY_DEV_WOWROOT is not set. Dev builds require a fixture root with spaces and parentheses per live-PC safety rules (ADR-307).".into());
            }
        }
    }

    let mut candidates: Vec<PathBuf> = Vec::new();

    #[cfg(target_os = "windows")]
    {
        use winreg::enums::*;
        use winreg::RegKey;

        let reg_paths = [
            (HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft"),
            (HKEY_CURRENT_USER, r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft"),
            (HKEY_LOCAL_MACHINE, r"SOFTWARE\Blizzard Entertainment\World of Warcraft"),
            (HKEY_CURRENT_USER, r"SOFTWARE\Blizzard Entertainment\World of Warcraft"),
        ];

        for (hkey, subkey) in reg_paths {
            let root = RegKey::predef(hkey);
            if let Ok(key) = root.open_subkey(subkey) {
                if let Ok(val) = key.get_value::<String, _>("InstallPath") {
                    if !val.trim().is_empty() {
                        candidates.push(PathBuf::from(val.trim()));
                    }
                }
            }
        }
    }

    candidates.push(PathBuf::from(r"C:\Program Files (x86)\World of Warcraft"));
    candidates.push(PathBuf::from(r"C:\World of Warcraft"));

    for drive_letter in b'C'..=b'Z' {
        let drive_str = format!(r"{}:\\World of Warcraft", drive_letter as char);
        let p = PathBuf::from(drive_str);
        if p.exists() {
            candidates.push(p);
        }
    }

    for candidate in candidates {
        if candidate.exists() && !get_installed_flavours(&candidate).is_empty() {
            return Ok(candidate);
        }
    }

    Err("World of Warcraft installation could not be found.".into())
}

pub fn get_installed_flavours(wow_root: &Path) -> Vec<&'static FlavourDef> {
    let mut installed = Vec::new();
    for def in FLAVOUR_DEFS {
        let addons_path = wow_root.join(def.folder).join("Interface").join("AddOns");
        if addons_path.is_dir() {
            installed.push(def);
        }
    }
    installed
}

pub fn get_v1_sync_folder(wow_root: &Path) -> PathBuf {
    wow_root.join("_retail_").join("AddonSync")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_validate_dev_wowroot_requires_spaces_and_parentheses() {
        let temp = std::env::temp_dir();
        
        // No spaces or parens
        let no_sp = temp.join("wowroot_no_space");
        let _ = fs::create_dir_all(&no_sp);
        assert!(validate_dev_wowroot(no_sp.to_str().unwrap()).is_err());

        // Has spaces but no parens
        let sp_no_par = temp.join("wow root with spaces");
        let _ = fs::create_dir_all(&sp_no_par);
        let err = validate_dev_wowroot(sp_no_par.to_str().unwrap()).unwrap_err();
        assert!(err.contains("parentheses"));

        // Has parens but no space
        let par_no_sp = temp.join("wowroot(test)");
        let _ = fs::create_dir_all(&par_no_sp);
        let err = validate_dev_wowroot(par_no_sp.to_str().unwrap()).unwrap_err();
        assert!(err.contains("spaces"));

        // Has both spaces and parens
        let valid = temp.join("World of Warcraft (Dev Test)");
        let _ = fs::create_dir_all(&valid);
        assert!(validate_dev_wowroot(valid.to_str().unwrap()).is_ok());

        // Cleanup
        let _ = fs::remove_dir_all(&no_sp);
        let _ = fs::remove_dir_all(&sp_no_par);
        let _ = fs::remove_dir_all(&par_no_sp);
        let _ = fs::remove_dir_all(&valid);
    }

    #[test]
    fn test_detect_installed_flavours() {
        let temp = std::env::temp_dir().join("wow test root (flavour test)");
        let retail_addons = temp.join("_retail_").join("Interface").join("AddOns");
        let classic_addons = temp.join("_classic_").join("Interface").join("AddOns");
        let _ = fs::create_dir_all(&retail_addons);
        let _ = fs::create_dir_all(&classic_addons);

        let flavours = get_installed_flavours(&temp);
        assert_eq!(flavours.len(), 2);
        assert_eq!(flavours[0].id, "retail");
        assert_eq!(flavours[1].id, "classic");

        let _ = fs::remove_dir_all(&temp);
    }
}
