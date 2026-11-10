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

    // 1. Dual match: TypeId AND version prefix match AND release_type <= max_release_type
    if !clean_prefix.is_empty() {
        for f in files {
            if f.game_version_type_ids.contains(&type_id)
                && f.release_type <= max_release_type
                && f.game_versions.iter().any(|v| v.starts_with(clean_prefix))
            {
                return Some(f.clone());
            }
        }
    }

    // 2. Primary match: Flavour TypeId AND releaseType <= max_release_type
    for f in files {
        if f.game_version_type_ids.contains(&type_id) && f.release_type <= max_release_type {
            return Some(f.clone());
        }
    }

    // 3. Secondary match: Version prefix string match AND releaseType <= max_release_type
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

    // 4. Fallback: If no strict channel match exists, only allow relaxing to Beta if Beta channel is permitted
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

pub fn select_wago_release_strict(
    releases: &[WagoRelease],
    max_release_type: i64,
    wago_field: &str,
) -> Option<WagoRelease> {
    let check_supported_patches = |r: &WagoRelease| -> bool {
        match wago_field {
            "retail" | "mainline" => r.supported_retail_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            "classic" | "vanilla" | "classic_era" => r.supported_classic_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            "forever" => r.supported_forever_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            "bc" | "tbc" => r.supported_bc_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            "wotlk" | "wrath" => r.supported_wotlk_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            "cata" | "cataclysm" => r.supported_cata_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            "mop" | "mists" => r.supported_mop_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false),
            _ => false,
        }
    };

    for r in releases {
        let rank = get_wago_stability_rank(r.stability.as_deref());
        if rank <= max_release_type && check_supported_patches(r) {
            return Some(r.clone());
        }
    }

    None
}

pub fn select_wago_release(
    releases: &[WagoRelease],
    max_release_type: i64,
    wago_field: &str,
) -> Option<WagoRelease> {
    let has_any_patch_specification = |r: &WagoRelease| -> bool {
        let has_retail = r.supported_retail_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        let has_classic = r.supported_classic_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        let has_forever = r.supported_forever_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        let has_bc = r.supported_bc_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        let has_wotlk = r.supported_wotlk_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        let has_cata = r.supported_cata_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        let has_mop = r.supported_mop_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
        has_retail || has_classic || has_forever || has_bc || has_wotlk || has_cata || has_mop
    };

    // 1. Stability <= max_release_type AND supported patches non-empty for requested flavour
    if let Some(strict) = select_wago_release_strict(releases, max_release_type, wago_field) {
        return Some(strict);
    }

    // 1b. For "forever", if no dedicated forever release exists across the addon, fall back to "classic"
    if wago_field == "forever" {
        for r in releases {
            let rank = get_wago_stability_rank(r.stability.as_deref());
            let has_classic = r.supported_classic_patches.as_ref().map(|p| !p.is_empty()).unwrap_or(false);
            if rank <= max_release_type && has_classic {
                return Some(r.clone());
            }
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

pub fn matches_flavour_asset_name(name: &str, flavour: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    match flavour {
        "forever" => {
            lower.contains("forever") || lower.contains("wowf") || lower.contains("1.60")
        }
        "classic" | "classic_era" => {
            (lower.contains("classic") || lower.contains("vanilla") || lower.contains("era") || lower.contains("1.15"))
                && !lower.contains("classic-tbc")
                && !lower.contains("classic-wotlk")
                && !lower.contains("classic-cata")
        }
        "retail" => {
            lower.contains("retail") || lower.contains("mainline") || lower.contains("12.") || lower.contains("11.")
        }
        "tbc" | "bc" => lower.contains("tbc") || lower.contains("bcc") || lower.contains("2.5"),
        "wotlk" | "wrath" => lower.contains("wotlk") || lower.contains("wrath") || lower.contains("3.4"),
        "cata" => lower.contains("cata") || lower.contains("cataclysm") || lower.contains("4.4"),
        "mop" | "mists" => lower.contains("mop") || lower.contains("mists") || lower.contains("5.5"),
        _ => false,
    }
}

pub fn is_conflicting_flavour_asset(name: &str, flavour: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    match flavour {
        "forever" => {
            lower.contains("retail")
                || lower.contains("mainline")
                || lower.contains("cata")
                || lower.contains("wotlk")
                || lower.contains("tbc")
                || lower.contains("mop")
        }
        "classic" | "classic_era" => {
            lower.contains("retail")
                || lower.contains("mainline")
                || lower.contains("cata")
                || lower.contains("wotlk")
                || lower.contains("tbc")
                || lower.contains("mop")
        }
        "retail" => {
            lower.contains("classic")
                || lower.contains("vanilla")
                || lower.contains("forever")
                || lower.contains("cata")
                || lower.contains("wotlk")
                || lower.contains("tbc")
        }
        _ => false,
    }
}

pub fn select_github_release(
    releases: &[GithubRelease],
    max_release_type: i64,
    pinned_tag: Option<&str>,
    flavour: Option<&str>,
) -> Option<GithubRelease> {
    if let Some(tag) = pinned_tag {
        return releases.iter().find(|r| r.tag_name == tag).cloned();
    }

    let eligible: Vec<&GithubRelease> = if max_release_type == 1 {
        // Release only, skip prerelease
        releases.iter().filter(|r| !r.prerelease).collect()
    } else {
        releases.iter().collect()
    };

    if let Some(flv) = flavour {
        // 1. Exact flavour match in tag or title
        for r in &eligible {
            let tag = &r.tag_name;
            let name = r.name.as_deref().unwrap_or("");
            if matches_flavour_asset_name(tag, flv) || matches_flavour_asset_name(name, flv) {
                return Some((*r).clone());
            }
        }

        // 1b. For "forever", fall back to classic
        if flv == "forever" {
            for r in &eligible {
                let tag = &r.tag_name;
                let name = r.name.as_deref().unwrap_or("");
                if matches_flavour_asset_name(tag, "classic") || matches_flavour_asset_name(name, "classic") {
                    return Some((*r).clone());
                }
            }
        }

        // 2. Flavour-neutral releases (no conflicting flavour in tag or title)
        for r in &eligible {
            let tag = &r.tag_name;
            let name = r.name.as_deref().unwrap_or("");
            if !is_conflicting_flavour_asset(tag, flv) && !is_conflicting_flavour_asset(name, flv) {
                return Some((*r).clone());
            }
        }

        // If all releases are for conflicting flavours, do NOT install cross-flavour
        return None;
    }

    eligible.first().copied().cloned()
}

pub fn select_github_asset<'a>(
    release: &'a GithubRelease,
    repo: &str,
    flavour: Option<&str>,
) -> Option<&'a GithubAsset> {
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

    if let Some(flv) = flavour {
        // 1. Direct flavour match
        if let Some(matched) = zip_assets.iter().find(|ast| matches_flavour_asset_name(&ast.name, flv)) {
            return Some(*matched);
        }

        // 1b. For "forever", fall back to classic/vanilla
        if flv == "forever" {
            if let Some(matched) = zip_assets.iter().find(|ast| matches_flavour_asset_name(&ast.name, "classic")) {
                return Some(*matched);
            }
        }

        // Filter out assets that are explicitly for a conflicting flavour
        let non_conflicting: Vec<&GithubAsset> = zip_assets
            .iter()
            .copied()
            .filter(|ast| !is_conflicting_flavour_asset(&ast.name, flv))
            .collect();

        if let Some(matched) = non_conflicting.iter().find(|ast| ast.name.to_ascii_lowercase().contains(&repo_lower)) {
            return Some(*matched);
        }

        if let Some(first) = non_conflicting.first() {
            return Some(*first);
        }

        // If all assets are conflicting flavours, reject rather than installing wrong flavour
        if zip_assets.iter().any(|ast| is_conflicting_flavour_asset(&ast.name, flv)) {
            return None;
        }
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
    fn test_select_cf_file_forever_leatrix_plus() {
        let files = vec![
            CfFile {
                id: 9471872,
                display_name: Some("1.60.29-forever".to_string()),
                file_name: Some("Leatrix_Plus-1.60.29-forever.zip".to_string()),
                file_length: Some(100),
                release_type: 1, // Release
                project_id: Some(94855),
                game_versions: vec!["1.60.1".to_string()],
                game_version_type_ids: vec![88568],
                date_created: None,
            },
            CfFile {
                id: 9428873,
                display_name: Some("1.15.164-classic".to_string()),
                file_name: Some("Leatrix_Plus-1.15.164-classic.zip".to_string()),
                file_length: Some(100),
                release_type: 1, // Release
                project_id: Some(94855),
                game_versions: vec!["1.15.9".to_string()],
                game_version_type_ids: vec![67408],
                date_created: None,
            },
            CfFile {
                id: 9428751,
                display_name: Some("12.1.16".to_string()),
                file_name: Some("Leatrix_Plus-12.1.16.zip".to_string()),
                file_length: Some(100),
                release_type: 1, // Release
                project_id: Some(94855),
                game_versions: vec!["12.1.5".to_string()],
                game_version_type_ids: vec![517],
                date_created: None,
            },
        ];

        // Forever (88568, "1.60.") MUST select file 9471872
        let sel_forever = select_cf_file(&files, 1, 88568, "1.60.").unwrap();
        assert_eq!(sel_forever.id, 9471872);

        // Classic Era (67408, "1.15.") MUST select file 9428873
        let sel_classic = select_cf_file(&files, 1, 67408, "1.15.").unwrap();
        assert_eq!(sel_classic.id, 9428873);

        // Retail (517, "12.") MUST select file 9428751
        let sel_retail = select_cf_file(&files, 1, 517, "12.").unwrap();
        assert_eq!(sel_retail.id, 9428751);

        // Forever on a classic-only addon MUST return None (strict compatibility, DEC-FURPHY-013)
        let classic_only = vec![files[1].clone()];
        let sel_fallback = select_cf_file(&classic_only, 1, 88568, "1.60.");
        assert!(sel_fallback.is_none());
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
                supported_forever_patches: None,
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
                created_at: None,
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
                supported_forever_patches: None,
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
                created_at: None,
            },
            WagoRelease {
                id: "rel3".to_string(),
                name: Some("Forever release".to_string()),
                version: Some("1.0".to_string()),
                stability: Some("stable".to_string()),
                size: Some(100),
                url: None,
                supported_retail_patches: None,
                supported_classic_patches: None,
                supported_forever_patches: Some(vec!["1.60.1".to_string()]),
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
                created_at: None,
            },
        ];

        let sel_retail = select_wago_release(&releases, 1, "retail").unwrap();
        assert_eq!(sel_retail.id, "rel1");

        let sel_classic = select_wago_release(&releases, 1, "classic").unwrap();
        assert_eq!(sel_classic.id, "rel2");

        let sel_forever = select_wago_release(&releases, 1, "forever").unwrap();
        assert_eq!(sel_forever.id, "rel3");
     }
    #[test]
    fn test_select_wago_release_pawn_forever() {
        // Simulates Pawn's Wago release list:
        // 1. Retail release (kwXVoAjQ) with supported_retail_patches ["12.1.5", "12.1.7"]
        // 2. Classic Era release (odGeLVO6) with supported_classic_patches ["1.15.9"]
        // 3. Forever release (5wq3moZQ) with supported_forever_patches ["1.60.1"]
        let releases = vec![
            WagoRelease {
                id: "kwXVoAjQ".to_string(),
                name: Some("Pawn 2.14.2".to_string()),
                version: Some("2.14.2".to_string()),
                stability: Some("stable".to_string()),
                size: Some(500000),
                url: None,
                supported_retail_patches: Some(vec!["12.1.5".to_string(), "12.1.7".to_string()]),
                supported_classic_patches: None,
                supported_forever_patches: None,
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
                created_at: None,
            },
            WagoRelease {
                id: "odGeLVO6".to_string(),
                name: Some("Pawn 2.14.1 (Classic)".to_string()),
                version: Some("2.14.1".to_string()),
                stability: Some("stable".to_string()),
                size: Some(400000),
                url: None,
                supported_retail_patches: None,
                supported_classic_patches: Some(vec!["1.15.9".to_string()]),
                supported_forever_patches: None,
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
                created_at: None,
            },
            WagoRelease {
                id: "5wq3moZQ".to_string(),
                name: Some("Pawn 2.14.1 (Forever)".to_string()),
                version: Some("2.14.1".to_string()),
                stability: Some("stable".to_string()),
                size: Some(400000),
                url: None,
                supported_retail_patches: None,
                supported_classic_patches: None,
                supported_forever_patches: Some(vec!["1.60.1".to_string()]),
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
                created_at: None,
            },
        ];

        let selected = select_wago_release(&releases, 1, "forever");
        assert!(selected.is_some());
        let release = selected.unwrap();
        assert_eq!(release.id, "5wq3moZQ");
        assert_eq!(release.name.as_deref(), Some("Pawn 2.14.1 (Forever)"));

        let selected_classic = select_wago_release(&releases, 1, "classic").unwrap();
        assert_eq!(selected_classic.id, "odGeLVO6");

        let selected_retail = select_wago_release(&releases, 1, "retail").unwrap();
        assert_eq!(selected_retail.id, "kwXVoAjQ");
    }
    #[test]
    fn test_select_wago_release_forever_classic_fallback() {
        // When an addon has NO forever releases (like BigWigs Classic KdMk8ER6),
        // it must fall back to the Classic Era release, but never to Retail-only releases.
        let releases = vec![
            WagoRelease {
                id: "rel_retail_only".to_string(),
                name: Some("Retail Only Addon".to_string()),
                version: Some("1.0".to_string()),
                stability: Some("stable".to_string()),
                size: Some(100),
                url: None,
                supported_retail_patches: Some(vec!["12.1.5".to_string()]),
                supported_classic_patches: None,
                supported_forever_patches: None,
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
                created_at: None,
            },
            WagoRelease {
                id: "rel_classic_fallback".to_string(),
                name: Some("BigWigs Classic".to_string()),
                version: Some("12.1.3".to_string()),
                stability: Some("stable".to_string()),
                size: Some(100),
                url: None,
                supported_retail_patches: Some(vec!["12.1.5".to_string()]),
                supported_classic_patches: Some(vec!["1.15.9".to_string()]),
                supported_forever_patches: None,
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
                created_at: None,
            },
        ];

        // For forever, rel_classic_fallback is selected because it supports classic patches
        let sel = select_wago_release(&releases, 1, "forever").unwrap();
        assert_eq!(sel.id, "rel_classic_fallback");

        // Retail only release list for forever must return None (no cross-contamination from Retail)
        let retail_only = vec![releases[0].clone()];
        assert!(select_wago_release(&retail_only, 1, "forever").is_none());
    }

    #[test]
    fn test_select_wago_release_multipage_forever_priority() {
        // Page 1: Has a Classic release
        let page_1 = vec![
            WagoRelease {
                id: "classic_p1".to_string(),
                name: Some("Pawn Classic".to_string()),
                version: Some("2.14.0".to_string()),
                stability: Some("stable".to_string()),
                size: Some(100),
                url: None,
                supported_retail_patches: None,
                supported_classic_patches: Some(vec!["1.15.5".to_string()]),
                supported_forever_patches: None,
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
                created_at: None,
            },
        ];

        // Page 2: Has a dedicated Forever release
        let page_2 = vec![
            WagoRelease {
                id: "forever_p2".to_string(),
                name: Some("Pawn Forever".to_string()),
                version: Some("2.14.1".to_string()),
                stability: Some("stable".to_string()),
                size: Some(100),
                url: None,
                supported_retail_patches: None,
                supported_classic_patches: None,
                supported_forever_patches: Some(vec!["1.60.1".to_string()]),
                supported_bc_patches: None,
                supported_wotlk_patches: None,
                supported_cata_patches: None,
                supported_mop_patches: None,
                created_at: None,
            },
        ];

        // Strict search on page 1 yields None
        assert!(select_wago_release_strict(&page_1, 1, "forever").is_none());

        // Strict search on page 2 finds the dedicated release
        let strict_p2 = select_wago_release_strict(&page_2, 1, "forever");
        assert!(strict_p2.is_some());
        assert_eq!(strict_p2.unwrap().id, "forever_p2");
    }

    #[test]
    fn test_select_github_flavour_filtering() {
        use crate::net::github::GithubAsset;

        let release = GithubRelease {
            id: 101,
            tag_name: "v1.0.0".to_string(),
            name: Some("v1.0.0".to_string()),
            prerelease: false,
            published_at: None,
            assets: vec![
                GithubAsset {
                    id: 1,
                    name: "WeakAuras-Retail.zip".to_string(),
                    size: Some(100),
                    url: "https://example.com/retail.zip".to_string(),
                    browser_download_url: None,
                    digest: None,
                },
                GithubAsset {
                    id: 2,
                    name: "WeakAuras-Classic.zip".to_string(),
                    size: Some(100),
                    url: "https://example.com/classic.zip".to_string(),
                    browser_download_url: None,
                    digest: None,
                },
                GithubAsset {
                    id: 3,
                    name: "WeakAuras-Forever.zip".to_string(),
                    size: Some(100),
                    url: "https://example.com/forever.zip".to_string(),
                    browser_download_url: None,
                    digest: None,
                },
            ],
            zipball_url: None,
        };

        // Forever selects Forever asset
        let ast_forever = select_github_asset(&release, "WeakAuras/WeakAuras2", Some("forever")).unwrap();
        assert_eq!(ast_forever.name, "WeakAuras-Forever.zip");

        // Classic selects Classic asset
        let ast_classic = select_github_asset(&release, "WeakAuras/WeakAuras2", Some("classic")).unwrap();
        assert_eq!(ast_classic.name, "WeakAuras-Classic.zip");

        // Retail selects Retail asset
        let ast_retail = select_github_asset(&release, "WeakAuras/WeakAuras2", Some("retail")).unwrap();
        assert_eq!(ast_retail.name, "WeakAuras-Retail.zip");

        // Release tag matching
        let releases = vec![
            GithubRelease {
                id: 201,
                tag_name: "v12.1.0-retail".to_string(),
                name: Some("12.1.0 Retail".to_string()),
                prerelease: false,
                published_at: None,
                assets: vec![],
                zipball_url: None,
            },
            GithubRelease {
                id: 202,
                tag_name: "v1.60.1-forever".to_string(),
                name: Some("1.60.1 Forever".to_string()),
                prerelease: false,
                published_at: None,
                assets: vec![],
                zipball_url: None,
            },
            GithubRelease {
                id: 203,
                tag_name: "v1.15.5-classic".to_string(),
                name: Some("1.15.5 Classic".to_string()),
                prerelease: false,
                published_at: None,
                assets: vec![],
                zipball_url: None,
            },
        ];

        let sel_forever = select_github_release(&releases, 1, None, Some("forever")).unwrap();
        assert_eq!(sel_forever.tag_name, "v1.60.1-forever");

        let sel_retail = select_github_release(&releases, 1, None, Some("retail")).unwrap();
        assert_eq!(sel_retail.tag_name, "v12.1.0-retail");

        let sel_classic = select_github_release(&releases, 1, None, Some("classic")).unwrap();
        assert_eq!(sel_classic.tag_name, "v1.15.5-classic");

        // Retail-only releases rejected for Forever
        let retail_only_releases = vec![releases[0].clone()];
        assert!(select_github_release(&retail_only_releases, 1, None, Some("forever")).is_none());
    }
}
