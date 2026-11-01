use crate::net::curseforge::CfFile;
use crate::net::github::{GithubAsset, GithubRelease};
use crate::net::wago::WagoRelease;

pub fn select_cf_file(
    files: &[CfFile],
    max_release_type: i64,
    type_id: i64,
    version_prefix: &str,
) -> Option<CfFile> {
    let clean_prefix = version_prefix.trim();

    // 1. Primary match: Flavour TypeId AND releaseType <= max_release_type
    for f in files {
        if f.game_version_type_ids.contains(&type_id) && f.release_type <= max_release_type {
            return Some(f.clone());
        }
    }

    // 2. Secondary match: Version prefix string match AND releaseType <= max_release_type
    if !clean_prefix.is_empty() {
        for f in files {
            if f.release_type <= max_release_type {
                for v in &f.game_versions {
                    if v.starts_with(clean_prefix) {
                        return Some(f.clone());
                    }
                }
            }
        }
    }

    // 3. Fallback: If no strict channel match exists, only allow relaxing to Beta if Beta channel is permitted
    if max_release_type > 1 {
        for f in files {
            if f.game_version_type_ids.contains(&type_id) && f.release_type <= 2 {
                return Some(f.clone());
            }
        }
    }

    None
}

pub fn get_wago_stability_rank(stability: Option<&str>) -> i64 {
    match stability.map(|s| s.to_ascii_lowercase()).as_deref() {
        Some("stable") | Some("release") | Some("production") => 1,
        Some("beta") => 2,
        Some("alpha") | Some("dev") | Some("development") => 3,
        None => 1, // Default untagged releases to stable/release channel
        _ => 3,
    }
}

pub fn select_wago_release(
    releases: &[WagoRelease],
    max_release_type: i64,
    wago_field: &str,
) -> Option<WagoRelease> {
    let check_supported_patches = |r: &WagoRelease| -> bool {
        match wago_field {
            "retail" | "mainline" => r.supported_retail_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            "classic" | "vanilla" | "classic_era" => r.supported_classic_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            "bc" | "tbc" => r.supported_bc_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            "wotlk" | "wrath" => r.supported_wotlk_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            "cata" | "cataclysm" => r.supported_cata_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            "mop" | "mists" => r.supported_mop_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            _ => false,
        }
    };

    let has_any_patch_specification = |r: &WagoRelease| -> bool {
        let has_retail = r.supported_retail_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        let has_classic = r.supported_classic_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        let has_bc = r.supported_bc_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        let has_wotlk = r.supported_wotlk_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        let has_cata = r.supported_cata_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        let has_mop = r.supported_mop_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        has_retail || has_classic || has_bc || has_wotlk || has_cata || has_mop
    };

    // 1. Stability <= max_release_type AND supported patches non-empty for requested flavour
    for r in releases {
        let rank = get_wago_stability_rank(r.stability.as_deref());
        if rank <= max_release_type && check_supported_patches(r) {
            return Some(r.clone());
        }
    }

    // 2. Fallback to newest allowed stability ONLY if release is flavour-agnostic
    for r in releases {
        let rank = get_wago_stability_rank(r.stability.as_deref());
        if rank <= max_release_type && !has_any_patch_specification(r) {
            return Some(r.clone());
        }
    }

    None
}

pub fn select_github_release(
    releases: &[GithubRelease],
    max_release_type: i64,
    pinned_tag: Option<&str>,
) -> Option<GithubRelease> {
    if let Some(tag) = pinned_tag {
        return releases.iter().find(|r| r.tag_name == tag).cloned();
    }

    if max_release_type == 1 {
        // Release only, skip prerelease
        releases.iter().find(|r| !r.prerelease).cloned()
    } else {
        releases.first().cloned()
    }
}

pub fn select_github_asset<'a>(release: &'a GithubRelease, repo: &str) -> Option<&'a GithubAsset> {
    let repo_name = repo.rsplit('/').next().unwrap_or(repo);
    let repo_clean = repo_name.strip_suffix(".git").unwrap_or(repo_name);
    let repo_lower = repo_clean.to_ascii_lowercase();

    let zip_assets: Vec<&GithubAsset> = release
        .assets
        .iter()
        .filter(|ast| ast.name.to_ascii_lowercase().ends_with(".zip"))
        .collect();

    if zip_assets.is_empty() {
        return None;
    }

    // Prefer asset containing repo_name
    if let Some(matched) = zip_assets.iter().find(|ast| {
        ast.name.to_ascii_lowercase().contains(&repo_lower)
    }) {
        return Some(*matched);
    }

    // Fall back to first zip asset
    zip_assets.first().copied()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_select_cf_file_channel_ceiling() {
        let files = vec![
            CfFile {
                id: 1,
                display_name: Some("v1.0-alpha".to_string()),
                file_name: Some("file1.zip".to_string()),
                file_length: Some(100),
                release_type: 3, // Alpha
                project_id: Some(100),
                game_versions: vec!["11.0.2".to_string()],
                game_version_type_ids: vec![517],
                date_created: None,
            },
            CfFile {
                id: 2,
                display_name: Some("v0.9-release".to_string()),
                file_name: Some("file2.zip".to_string()),
                file_length: Some(100),
                release_type: 1, // Release
                project_id: Some(100),
                game_versions: vec!["11.0.2".to_string()],
                game_version_type_ids: vec![517],
                date_created: None,
            },
        ];

        // Channel 1: must pick release file id 2
        let sel = select_cf_file(&files, 1, 517, "12.").unwrap();
        assert_eq!(sel.id, 2);

        // Channel 3: picks newest file id 1
        let sel3 = select_cf_file(&files, 3, 517, "12.").unwrap();
        assert_eq!(sel3.id, 1);
    }

    #[test]
    fn test_select_wago_release_patch_matching() {
        let releases = vec![
            WagoRelease {
                id: "rel1".to_string(),
                name: Some("Retail release".to_string()),
                version: Some("1.0".to_string()),
                stability: Some("stable".to_string()),
                size: Some(100),
                url: None,
                supported_retail_patches: Some(vec!["11.0.2".to_string()]),
                supported_classic_patches: None,
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
            },
            WagoRelease {
                id: "rel2".to_string(),
                name: Some("Classic release".to_string()),
                version: Some("1.0".to_string()),
                stability: Some("stable".to_string()),
                size: Some(100),
                url: None,
                supported_retail_patches: None,
                supported_classic_patches: Some(vec!["1.15.2".to_string()]),
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
            },
        ];

        let sel_retail = select_wago_release(&releases, 1, "retail").unwrap();
        assert_eq!(sel_retail.id, "rel1");

        let sel_classic = select_wago_release(&releases, 1, "classic").unwrap();
        assert_eq!(sel_classic.id, "rel2");
    }
}
