use crate::net::policy::NetworkPolicy;
use crate::net::tukui::TukuiAddon;

pub fn version_prefix_for(flavour_id: &str, client_build: Option<&str>) -> Option<String> {
    let flv = flavour_id.trim().to_ascii_lowercase();
    match flv.as_str() {
        "retail" | "ptr" | "xptr" | "beta" => {
            let build = client_build?.trim();
            if build.is_empty() {
                return None;
            }
            let major = build.split('.').next()?;
            if !major.is_empty() && major.chars().all(|c| c.is_ascii_digit()) {
                Some(format!("{}.", major))
            } else {
                None
            }
        }
        "forever" => Some("1.60.".to_string()),
        "classic_era" | "classic_era_ptr" => Some("1.15.".to_string()),
        "classic" | "classic_ptr" | "classic_beta" | "anniversary" => {
            let build = client_build?.trim();
            if build.is_empty() {
                return None;
            }
            let parts: Vec<&str> = build.split('.').collect();
            if parts.len() >= 2
                && !parts[0].is_empty()
                && parts[0].chars().all(|c| c.is_ascii_digit())
                && !parts[1].is_empty()
                && parts[1].chars().all(|c| c.is_ascii_digit())
            {
                Some(format!("{}.{}.", parts[0], parts[1]))
            } else {
                None
            }
        }
        _ => None,
    }
}

pub fn tukui_supports(addon: &TukuiAddon, version_prefix: Option<&str>) -> bool {
    match version_prefix {
        None => true,
        Some(prefix) => {
            let clean = prefix.trim();
            if clean.is_empty() {
                return true;
            }
            addon.patch.iter().any(|p| p.trim().starts_with(clean))
        }
    }
}

pub fn tukui_unavailable_reason(
    addon: &TukuiAddon,
    era_label: &str,
    version_prefix: Option<&str>,
) -> Option<String> {
    if tukui_supports(addon, version_prefix) {
        return None;
    }

    let prefix = version_prefix.unwrap_or("");
    let prefix_display = if prefix.ends_with('.') {
        format!("{}x", prefix)
    } else {
        format!("{}.x", prefix)
    };

    let patches_display = if addon.patch.is_empty() {
        "no game versions".to_string()
    } else {
        addon.patch.join(", ")
    };

    Some(format!(
        "Tukui lists {} for this addon, not {}, the game version of {}.",
        patches_display, prefix_display, era_label
    ))
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TukuiChoice {
    pub file_id: String,
    pub version: String,
    pub file_name: String,
    pub download_url: String,
    pub released: Option<String>,
}

pub async fn choose_tukui_release(
    policy: &NetworkPolicy,
    client: &reqwest::Client,
    slug: &str,
    flavour_id: &str,
    era_label: &str,
    client_build: Option<&str>,
) -> Result<TukuiChoice, String> {
    let addons = crate::net::tukui::get_tukui_addons(policy, client).await?;

    let clean_slug = slug.trim();
    let addon = addons
        .into_iter()
        .find(|a| a.slug.eq_ignore_ascii_case(clean_slug))
        .ok_or_else(|| format!("Tukui does not list an addon called {}", clean_slug))?;

    let prefix = version_prefix_for(flavour_id, client_build);
    if !tukui_supports(&addon, prefix.as_deref()) {
        let reason = tukui_unavailable_reason(&addon, era_label, prefix.as_deref())
            .unwrap_or_else(|| format!("Addon {} is not compatible with {}", clean_slug, era_label));
        return Err(reason);
    }

    Ok(TukuiChoice {
        file_id: addon.version.clone(),
        version: addon.version.clone(),
        file_name: format!("{}-{}.zip", addon.slug, addon.version),
        download_url: addon.url,
        released: addon.last_update,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_elvui() -> TukuiAddon {
        TukuiAddon {
            id: "-2".to_string(),
            slug: "elvui".to_string(),
            name: "ElvUI".to_string(),
            author: "Elv, Simpy".to_string(),
            url: "https://api.tukui.org/v1/download/elvui/12.1.5".to_string(),
            version: "12.1.5".to_string(),
            patch: vec![
                "12.1.5".to_string(),
                "1.60.1".to_string(),
                "5.5.4".to_string(),
                "1.15.9".to_string(),
                "2.5.6".to_string(),
            ],
            last_update: Some("2026-11-09".to_string()),
            web_url: Some("https://www.tukui.org/addons.php?id=-2".to_string()),
            small_desc: Some("User interface overhaul".to_string()),
            directories: vec!["ElvUI".to_string(), "ElvUI_Libraries".to_string(), "ElvUI_Options".to_string()],
        }
    }

    fn sample_tukui() -> TukuiAddon {
        TukuiAddon {
            id: "-1".to_string(),
            slug: "tukui".to_string(),
            name: "Tukui".to_string(),
            author: "Tukz".to_string(),
            url: "https://api.tukui.org/v1/download/tukui/11.1.7".to_string(),
            version: "11.1.7".to_string(),
            patch: vec!["11.1.7".to_string(), "5.5.0".to_string(), "1.15.7".to_string()],
            last_update: Some("2026-10-15".to_string()),
            web_url: Some("https://www.tukui.org/addons.php?id=-1".to_string()),
            small_desc: Some("Minimalist UI".to_string()),
            directories: vec!["Tukui".to_string()],
        }
    }

    #[test]
    fn test_version_prefix_for_all_flavours() {
        assert_eq!(version_prefix_for("retail", Some("12.1.5.70783")), Some("12.".to_string()));
        assert_eq!(version_prefix_for("retail", None), None);
        assert_eq!(version_prefix_for("retail", Some("")), None);
        assert_eq!(version_prefix_for("retail", Some("not_a_version")), None);
        assert_eq!(version_prefix_for("ptr", Some("12.2.0.71000")), Some("12.".to_string()));
        assert_eq!(version_prefix_for("xptr", Some("12.2.0.71000")), Some("12.".to_string()));
        assert_eq!(version_prefix_for("beta", Some("12.0.0.69000")), Some("12.".to_string()));

        assert_eq!(version_prefix_for("forever", Some("1.60.1.70862")), Some("1.60.".to_string()));
        assert_eq!(version_prefix_for("forever", None), Some("1.60.".to_string()));

        assert_eq!(version_prefix_for("classic_era", Some("1.15.9.1234")), Some("1.15.".to_string()));
        assert_eq!(version_prefix_for("classic_era", None), Some("1.15.".to_string()));
        assert_eq!(version_prefix_for("classic_era_ptr", Some("1.15.9.1234")), Some("1.15.".to_string()));
        assert_eq!(version_prefix_for("classic_era_ptr", None), Some("1.15.".to_string()));

        assert_eq!(version_prefix_for("classic", Some("5.5.4.1")), Some("5.5.".to_string()));
        assert_eq!(version_prefix_for("classic", None), None);
        assert_eq!(version_prefix_for("classic_ptr", Some("5.5.4.1")), Some("5.5.".to_string()));
        assert_eq!(version_prefix_for("classic_beta", Some("5.5.4.1")), Some("5.5.".to_string()));
        assert_eq!(version_prefix_for("anniversary", Some("1.15.5.70000")), Some("1.15.".to_string()));
        assert_eq!(version_prefix_for("anniversary", None), None);

        assert_eq!(version_prefix_for("unknown", Some("12.1.5")), None);
    }

    #[test]
    fn test_tukui_supports_and_reason_retail() {
        let elvui = sample_elvui();
        let tukui = sample_tukui();
        let prefix = version_prefix_for("retail", Some("12.1.5.70783"));
        assert_eq!(prefix.as_deref(), Some("12."));

        assert!(tukui_supports(&elvui, prefix.as_deref()));
        assert_eq!(tukui_unavailable_reason(&elvui, "Retail", prefix.as_deref()), None);

        assert!(!tukui_supports(&tukui, prefix.as_deref()));
        let reason = tukui_unavailable_reason(&tukui, "Retail", prefix.as_deref());
        assert_eq!(
            reason,
            Some("Tukui lists 11.1.7, 5.5.0, 1.15.7 for this addon, not 12.x, the game version of Retail.".to_string())
        );
    }

    #[test]
    fn test_tukui_supports_and_reason_forever() {
        let elvui = sample_elvui();
        let tukui = sample_tukui();
        let prefix = version_prefix_for("forever", Some("1.60.1.70862"));
        assert_eq!(prefix.as_deref(), Some("1.60."));

        assert!(tukui_supports(&elvui, prefix.as_deref()));
        assert_eq!(tukui_unavailable_reason(&elvui, "WoW Forever", prefix.as_deref()), None);

        assert!(!tukui_supports(&tukui, prefix.as_deref()));
        let reason = tukui_unavailable_reason(&tukui, "WoW Forever", prefix.as_deref());
        assert_eq!(
            reason,
            Some("Tukui lists 11.1.7, 5.5.0, 1.15.7 for this addon, not 1.60.x, the game version of WoW Forever.".to_string())
        );
    }

    #[test]
    fn test_tukui_supports_and_reason_classic_era() {
        let elvui = sample_elvui();
        let tukui = sample_tukui();
        let prefix = version_prefix_for("classic_era", None);
        assert_eq!(prefix.as_deref(), Some("1.15."));

        assert!(tukui_supports(&elvui, prefix.as_deref()));
        assert_eq!(tukui_unavailable_reason(&elvui, "Classic Era", prefix.as_deref()), None);

        assert!(tukui_supports(&tukui, prefix.as_deref()));
        assert_eq!(tukui_unavailable_reason(&tukui, "Classic Era", prefix.as_deref()), None);
    }

    #[test]
    fn test_tukui_supports_none_prefix() {
        let elvui = sample_elvui();
        let tukui = sample_tukui();

        assert!(tukui_supports(&elvui, None));
        assert_eq!(tukui_unavailable_reason(&elvui, "Unknown", None), None);

        assert!(tukui_supports(&tukui, None));
        assert_eq!(tukui_unavailable_reason(&tukui, "Unknown", None), None);
    }
}
