use std::path::{Path, PathBuf};
use crate::db::open_connection;
use crate::engine::battlenet::{parse_product_db, product_db_path, BattlenetInstall};
use crate::engine::flavours::{detect_all_installed_flavours, InstalledFlavourInfo, FLAVOUR_DEFS};
use crate::paths::{detect_wow_root, get_db_path};

#[derive(Debug, Clone, serde::Serialize)]
pub struct BattlenetInstallDto {
    pub product: String,
    pub install_path: String,
    pub flavour: Option<String>,
    pub flavour_folder_exists: bool,
    pub current_path: Option<String>,
}

fn native_path(raw: &str) -> String {
    raw.replace('/', "\\")
}

/// One row per World of Warcraft product: its game version when Furphy has one, whether that game version's folder is
/// in the install, and the folder Furphy uses for it now.
pub fn build_install_dtos(
    installs: &[BattlenetInstall],
    installed: &[InstalledFlavourInfo],
    default_root: Option<&Path>,
) -> Vec<BattlenetInstallDto> {
    installs
        .iter()
        .filter(|i| i.product.starts_with("wow"))
        .map(|install| {
            let install_path = native_path(&install.install_path);
            let def = FLAVOUR_DEFS.iter().find(|d| d.product == install.product);
            let folder_exists = match def {
                Some(d) if !install_path.is_empty() => Path::new(&install_path).join(d.folder).is_dir(),
                _ => false,
            };
            let current: Option<PathBuf> = def.and_then(|d| {
                installed
                    .iter()
                    .find(|f| f.id == d.id)
                    .and_then(|f| f.custom_root.clone().or_else(|| default_root.map(|r| r.to_path_buf())))
            });
            BattlenetInstallDto {
                product: install.product.clone(),
                install_path,
                flavour: def.map(|d| d.id.to_string()),
                flavour_folder_exists: folder_exists,
                current_path: current.map(|p| p.to_string_lossy().into_owned()),
            }
        })
        .collect()
}

#[tauri::command]
pub fn detect_battlenet_installs() -> Result<Vec<BattlenetInstallDto>, String> {
    let bytes = match std::fs::read(product_db_path()) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(format!("Could not read Battle.net's list of installed games: {}", e)),
    };
    let installs = parse_product_db(&bytes)?;

    let wow_root = detect_wow_root(None).ok();
    let installed = match open_connection(&get_db_path()) {
        Ok(conn) => detect_all_installed_flavours(&conn, wow_root.as_deref()),
        Err(_) => Vec::new(),
    };
    Ok(build_install_dtos(&installs, &installed, wow_root.as_deref()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn install(product: &str, path: &str) -> BattlenetInstall {
        BattlenetInstall { product: product.to_string(), uid: product.to_string(), install_path: path.to_string() }
    }

    fn info(id: &str, custom_root: Option<PathBuf>) -> InstalledFlavourInfo {
        InstalledFlavourInfo {
            id: id.to_string(),
            folder: format!("_{}_", id),
            label: id.to_string(),
            addons_path: PathBuf::new(),
            client_build: None,
            client_interface: None,
            custom_root,
        }
    }

    #[test]
    fn only_wow_products_are_listed_with_their_game_version_and_folder_state() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("World of Warcraft");
        std::fs::create_dir_all(root.join("_retail_")).unwrap();
        let path = root.to_string_lossy().replace('\\', "/");

        let installs = vec![
            install("agent", &path),
            install("wow", &path),
            install("wowf", &path),
            install("wow_unknown_product", &path),
        ];
        let installed = vec![info("retail", None)];
        let dtos = build_install_dtos(&installs, &installed, Some(root.as_path()));

        assert_eq!(dtos.iter().map(|d| d.product.as_str()).collect::<Vec<_>>(), vec!["wow", "wowf", "wow_unknown_product"]);
        assert_eq!(dtos[0].flavour.as_deref(), Some("retail"));
        assert!(dtos[0].flavour_folder_exists);
        assert_eq!(dtos[0].current_path.as_deref(), Some(root.to_string_lossy().as_ref()));
        assert!(dtos[0].install_path.contains('\\') || !cfg!(windows));

        assert_eq!(dtos[1].flavour.as_deref(), Some("forever"));
        assert!(!dtos[1].flavour_folder_exists, "there is no _forever_ folder in this install");
        assert_eq!(dtos[1].current_path, None, "forever is not installed here, so Furphy has no folder for it");

        assert_eq!(dtos[2].flavour, None);
        assert!(!dtos[2].flavour_folder_exists);
    }

    #[test]
    fn a_custom_root_wins_over_the_default_root() {
        let custom = PathBuf::from("E:/Games/WoW");
        let installs = vec![install("wow", "C:/Program Files (x86)/World of Warcraft")];
        let installed = vec![info("retail", Some(custom.clone()))];
        let dtos = build_install_dtos(&installs, &installed, Some(Path::new("C:/Program Files (x86)/World of Warcraft")));
        assert_eq!(dtos[0].current_path.as_deref(), Some(custom.to_string_lossy().as_ref()));
    }
}
