use std::fs;
use std::path::{Path, PathBuf};
use serde::{Deserialize, Serialize};
use crate::engine::flavours::resolve_classic_progression;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TocMetadata {
    pub interface: Option<i32>,
    pub interfaces: Vec<i32>,
    pub title: Option<String>,
    pub titles: Vec<GuardedTitle>,
    pub version: Option<String>,
    pub author: Option<String>,
    pub curse_project_id: Option<i64>,
    pub wago_id: Option<String>,
    pub required_deps: Vec<String>,
    pub optional_deps: Vec<String>,
    pub x_flavor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GuardedTitle {
    pub title: String,
    pub allow_game_type: Option<String>,
    pub exclude_game_type: Option<String>,
}

pub fn strip_wow_formatting(input: &str) -> String {
    let mut out = String::new();
    let mut chars = input.chars().peekable();

    while let Some(c) = chars.next() {
        if c == '|' {
            if let Some(&next) = chars.peek() {
                if next == 'c' || next == 'C' {
                    chars.next();
                    for _ in 0..8 {
                        if chars.peek().map(|ch| ch.is_ascii_hexdigit()).unwrap_or(false) {
                            chars.next();
                        } else {
                            break;
                        }
                    }
                    continue;
                } else if next == 'r' || next == 'R' {
                    chars.next();
                    continue;
                }
            }
        }
        out.push(c);
    }

    out.trim().to_string()
}

pub fn strip_load_conditions(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;

    while let Some(start) = rest.find('[') {
        out.push_str(&rest[..start]);
        let slice = &rest[start..];
        if let Some(end) = slice.find(']') {
            let inside = slice[1..end].trim();
            let inside_lower = inside.to_ascii_lowercase();
            if inside_lower.starts_with("allowloadgametype")
                || inside_lower.starts_with("excludeloadgametype")
            {
                rest = &slice[end + 1..];
                continue;
            } else {
                out.push('[');
                rest = &slice[1..];
            }
        } else {
            out.push_str(slice);
            rest = "";
            break;
        }
    }
    out.push_str(rest);

    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn parse_interfaces(input: &str) -> Vec<i32> {
    input
        .split([',', ' ', '\t', '\r', '\n'])
        .filter_map(|s| {
            let t = s.trim();
            if t.is_empty() {
                None
            } else {
                t.parse::<i32>().ok()
            }
        })
        .collect()
}

fn parse_guard_conditions(line: &str) -> (Option<String>, Option<String>) {
    let mut allow = None;
    let mut exclude = None;
    let mut rest = line;

    while let Some(start) = rest.find('[') {
        let slice = &rest[start..];
        if let Some(end) = slice.find(']') {
            let inside = slice[1..end].trim();
            let inside_lower = inside.to_ascii_lowercase();
            if inside_lower.starts_with("allowloadgametype") {
                let val = inside["allowloadgametype".len()..]
                    .trim()
                    .trim_start_matches(':')
                    .trim();
                if !val.is_empty() {
                    allow = Some(val.to_ascii_lowercase());
                }
            } else if inside_lower.starts_with("excludeloadgametype") {
                let val = inside["excludeloadgametype".len()..]
                    .trim()
                    .trim_start_matches(':')
                    .trim();
                if !val.is_empty() {
                    exclude = Some(val.to_ascii_lowercase());
                }
            }
            rest = &slice[end + 1..];
        } else {
            break;
        }
    }

    (allow, exclude)
}

pub fn parse_toc_file(toc_path: &Path) -> TocMetadata {
    let mut meta = TocMetadata::default();
    let content = match fs::read_to_string(toc_path) {
        Ok(c) => c,
        Err(_) => return meta,
    };

    for line in content.lines() {
        let trimmed = line.trim();
        if !trimmed.starts_with("##") {
            continue;
        }

        let rest = trimmed[2..].trim();
        if let Some((key, val)) = rest.split_once(':') {
            let key = key.trim().to_ascii_lowercase();
            let value = val.trim();

            let is_title_key = key == "title"
                || key.starts_with("title ")
                || key.starts_with("title[");

            if is_title_key {
                let (allow, exclude) = parse_guard_conditions(rest);
                let clean = strip_wow_formatting(&strip_load_conditions(value));
                let is_unguarded = allow.is_none() && exclude.is_none();
                meta.titles.push(GuardedTitle {
                    title: clean.clone(),
                    allow_game_type: allow,
                    exclude_game_type: exclude,
                });
                if meta.title.is_none() || is_unguarded {
                    meta.title = Some(clean);
                }
            } else {
                match key.as_str() {
                    "interface" => {
                        let parsed = parse_interfaces(value);
                        if meta.interface.is_none() {
                            meta.interface = parsed.first().copied();
                        }
                        meta.interfaces.extend(parsed);
                    }
                    "version" => {
                        meta.version = Some(strip_load_conditions(value));
                    }
                    "author" => {
                        meta.author = Some(strip_wow_formatting(value));
                    }
                    "x-curse-project-id" => {
                        meta.curse_project_id = value.parse::<i64>().ok();
                    }
                    "x-wago-id" => {
                        meta.wago_id = Some(value.to_string());
                    }
                    "x-flavor" => {
                        meta.x_flavor = Some(value.to_string());
                    }
                    "requireddeps" | "dependencies" | "x-requireddeps" | "x-dependencies" => {
                        let cleaned = strip_load_conditions(value);
                        for dep in cleaned.split([',', ' ', '\t']) {
                            let d = dep.trim();
                            if !d.is_empty() && !meta.required_deps.iter().any(|existing| existing.eq_ignore_ascii_case(d)) {
                                meta.required_deps.push(d.to_string());
                            }
                        }
                    }
                    "optionaldeps" | "x-optionaldeps" => {
                        let cleaned = strip_load_conditions(value);
                        for dep in cleaned.split([',', ' ', '\t']) {
                            let d = dep.trim();
                            if !d.is_empty() && !meta.optional_deps.iter().any(|existing| existing.eq_ignore_ascii_case(d)) {
                                meta.optional_deps.push(d.to_string());
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    meta
}

pub fn resolve_title_for_flavor(meta: &TocMetadata, flavour: &str) -> Option<String> {
    let target_game_type = match flavour.to_ascii_lowercase().as_str() {
        "retail" | "ptr" | "xptr" | "beta" => "mainline",
        "classic_era" | "classic_era_ptr" | "forever" => "vanilla",
        "classic" | "classic_beta" | "classic_ptr" | "anniversary" => "vanilla",
        _ => "mainline",
    };

    for gt in &meta.titles {
        if let Some(ref ex) = gt.exclude_game_type {
            if ex.split(',').any(|s| s.trim().eq_ignore_ascii_case(target_game_type)) {
                continue;
            }
        }

        if let Some(ref al) = gt.allow_game_type {
            if al.split(',').any(|s| s.trim().eq_ignore_ascii_case(target_game_type)) {
                return Some(gt.title.clone());
            }
        } else if gt.exclude_game_type.is_some() {
            return Some(gt.title.clone());
        }
    }

    for gt in &meta.titles {
        if gt.allow_game_type.is_none() && gt.exclude_game_type.is_none() {
            return Some(gt.title.clone());
        }
    }

    if meta.titles.is_empty() {
        return meta.title.clone();
    }

    None
}

struct EraSelector {
    x_flavor_tag: &'static str,
    suffixes: &'static [&'static str],
}

fn get_era_selector(flavour: &str, client_interface: Option<i32>) -> EraSelector {
    match flavour {
        "retail" => EraSelector {
            x_flavor_tag: "Mainline",
            suffixes: &["_Mainline", "-Mainline"],
        },
        "classic_era" | "classic_era_ptr" => EraSelector {
            x_flavor_tag: "Vanilla",
            suffixes: &["_Vanilla", "_Classic", "-Classic"],
        },
        "forever" => EraSelector {
            x_flavor_tag: "Vanilla",
            suffixes: &[
                "_Camelot", "-Camelot", "_Forever", "-Forever", "_Vanilla", "_Classic", "-Classic",
            ],
        },
        "classic" | "classic_beta" | "classic_ptr" | "anniversary" => {
            let prog = resolve_classic_progression(client_interface);
            match prog.era_key.as_str() {
                "tbc" => EraSelector {
                    x_flavor_tag: "TBC",
                    suffixes: &["_TBC", "-BCC"],
                },
                "wrath" => EraSelector {
                    x_flavor_tag: "Wrath",
                    suffixes: &["_Wrath", "-Wrath", "-WOTLKC"],
                },
                "cata" => EraSelector {
                    x_flavor_tag: "Cata",
                    suffixes: &["_Cata"],
                },
                "mists" => EraSelector {
                    x_flavor_tag: "Mists",
                    suffixes: &["_Mists"],
                },
                "classic_era" => EraSelector {
                    x_flavor_tag: "Vanilla",
                    suffixes: &["_Vanilla", "_Classic", "-Classic"],
                },
                "forever" => EraSelector {
                    x_flavor_tag: "Vanilla",
                    suffixes: &[
                        "_Camelot", "-Camelot", "_Forever", "-Forever", "_Vanilla", "_Classic", "-Classic",
                    ],
                },
                _ => EraSelector {
                    x_flavor_tag: "Mainline",
                    suffixes: &["_Mainline", "-Mainline"],
                },
            }
        }
        _ => EraSelector {
            x_flavor_tag: "Mainline",
            suffixes: &["_Mainline", "-Mainline"],
        },
    }
}

pub fn find_primary_toc(
    folder_path: &Path,
    flavour: &str,
    client_interface: Option<i32>,
) -> Option<PathBuf> {
    let entries = fs::read_dir(folder_path).ok()?;
    let mut tocs = Vec::new();

    for e in entries.flatten() {
        let p = e.path();
        if p.is_file() {
            if let Some(ext) = p.extension() {
                if ext.to_string_lossy().eq_ignore_ascii_case("toc") {
                    tocs.push(p);
                }
            }
        }
    }

    if tocs.is_empty() {
        return None;
    }

    let folder_name = folder_path.file_name().unwrap_or_default().to_string_lossy();
    tocs.sort_by_key(|t| {
        let stem = t.file_stem().unwrap_or_default().to_string_lossy();
        if stem.eq_ignore_ascii_case(&folder_name) {
            0
        } else if stem.to_ascii_lowercase().starts_with(&folder_name.to_ascii_lowercase()) {
            1
        } else {
            2
        }
    });

    let selector = get_era_selector(flavour, client_interface);

    // Rule 1: Check X-Flavor tag in each toc
    // Dedicated Forever tags take precedence over generic Vanilla fallback.
    for toc in &tocs {
        let meta = parse_toc_file(toc);
        if let Some(ref tag) = meta.x_flavor {
            if flavour == "forever" {
                if tag.eq_ignore_ascii_case("Forever") || tag.eq_ignore_ascii_case("Camelot") {
                    return Some(toc.clone());
                }
            } else if tag.eq_ignore_ascii_case(selector.x_flavor_tag) {
                return Some(toc.clone());
            }
        }
    }

    // Rule 2: Check suffix matching in priority order
    for suffix in selector.suffixes {
        for toc in &tocs {
            let stem = toc.file_stem().unwrap_or_default().to_string_lossy();
            if stem.to_ascii_lowercase().ends_with(&suffix.to_ascii_lowercase()) {
                return Some(toc.clone());
            }
        }
    }

    // Rule 1 fallback for Forever: generic Vanilla X-Flavor tag
    if flavour == "forever" {
        for toc in &tocs {
            let meta = parse_toc_file(toc);
            if let Some(ref tag) = meta.x_flavor {
                if tag.eq_ignore_ascii_case(selector.x_flavor_tag) {
                    return Some(toc.clone());
                }
            }
        }
    }

    // Rule 3: Bare <Folder>.toc matching folder name
    let bare_expected = format!("{}.toc", folder_name);
    for toc in &tocs {
        let file_name = toc.file_name().unwrap_or_default().to_string_lossy();
        if file_name.eq_ignore_ascii_case(&bare_expected) {
            return Some(toc.clone());
        }
    }

    // Rule 4: Fallback to first .toc, rejecting cross-flavour pollution (strict isolation)
    for toc in &tocs {
        let stem = toc.file_stem().unwrap_or_default().to_string_lossy().to_ascii_lowercase();
        if (flavour == "forever" || flavour == "classic_era")
            && (stem.ends_with("_mainline") || stem.ends_with("-mainline"))
        {
            continue;
        }
        if flavour == "retail"
            && (stem.ends_with("_classic")
                || stem.ends_with("-classic")
                || stem.ends_with("_vanilla")
                || stem.ends_with("_camelot")
                || stem.ends_with("-camelot")
                || stem.ends_with("_forever")
                || stem.ends_with("-forever"))
        {
            continue;
        }
        return Some(toc.clone());
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_strip_wow_formatting() {
        assert_eq!(
            strip_wow_formatting("|cff00ff00My Addon|r"),
            "My Addon"
        );
        assert_eq!(
            strip_wow_formatting("Plain Title"),
            "Plain Title"
        );
    }

    #[test]
    fn test_parse_toc() {
        let temp = tempfile::tempdir().unwrap();
        let toc_file = temp.path().join("TestAddon.toc");
        fs::write(
            &toc_file,
            "## Interface: 110002\n## Title: |cffff0000Test|r Addon\n## Version: 1.2.3\n## Author: Eric\n## X-Curse-Project-ID: 12345\n## RequiredDeps: Ace3, LibSharedMedia-3.0\n",
        )
        .unwrap();

        let meta = parse_toc_file(&toc_file);
        assert_eq!(meta.interface, Some(110002));
        assert_eq!(meta.interfaces, vec![110002]);
        assert_eq!(meta.title.as_deref(), Some("Test Addon"));
        assert_eq!(meta.titles.len(), 1);
        assert_eq!(meta.titles[0].title, "Test Addon");
        assert_eq!(meta.version.as_deref(), Some("1.2.3"));
        assert_eq!(meta.author.as_deref(), Some("Eric"));
        assert_eq!(meta.curse_project_id, Some(12345));
        assert_eq!(meta.required_deps, vec!["Ace3", "LibSharedMedia-3.0"]);
    }

    #[test]
    fn test_forever_suffixes_priority() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path().join("Details");
        fs::create_dir(&folder).unwrap();

        fs::write(folder.join("Details.toc"), "## Interface: 110002\n").unwrap();
        fs::write(folder.join("Details_Classic.toc"), "## Interface: 11500\n").unwrap();
        fs::write(folder.join("Details_Camelot.toc"), "## Interface: 16000\n").unwrap();

        let primary = find_primary_toc(&folder, "forever", Some(16000)).unwrap();
        assert_eq!(
            primary.file_name().unwrap().to_string_lossy(),
            "Details_Camelot.toc"
        );
    }

    #[test]
    fn test_forever_legacy_classic_fallback() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path().join("BigWigs");
        fs::create_dir(&folder).unwrap();

        fs::write(folder.join("BigWigs.toc"), "## Interface: 110002\n").unwrap();
        fs::write(folder.join("BigWigs_Classic.toc"), "## Interface: 11500\n").unwrap();

        let primary = find_primary_toc(&folder, "forever", Some(16000)).unwrap();
        assert_eq!(
            primary.file_name().unwrap().to_string_lossy(),
            "BigWigs_Classic.toc"
        );
    }

    #[test]
    fn test_interface_comma_list() {
        let parsed = parse_interfaces("11508, 11509, 16001");
        assert_eq!(parsed, vec![11508, 11509, 16001]);

        let temp = tempfile::tempdir().unwrap();
        let toc_file = temp.path().join("MultiInterface.toc");
        fs::write(
            &toc_file,
            "## Interface: 11508, 11509, 16001\n## Title: Multi Interface Addon\n",
        )
        .unwrap();

        let meta = parse_toc_file(&toc_file);
        assert_eq!(meta.interface, Some(11508));
        assert_eq!(meta.interfaces, vec![11508, 11509, 16001]);
    }

    #[test]
    fn test_strip_load_conditions() {
        let s = "My Addon [AllowLoadGameType vanilla]";
        assert_eq!(strip_load_conditions(s), "My Addon");

        let s2 = "My Addon [ExcludeLoadGameType mainline]";
        assert_eq!(strip_load_conditions(s2), "My Addon");

        let s3 = "My Addon [AllowLoadGameType vanilla] [ExcludeLoadGameType mainline]";
        assert_eq!(strip_load_conditions(s3), "My Addon");

        let deps = "Ace3, LibSharedMedia-3.0 [AllowLoadGameType vanilla]";
        assert_eq!(strip_load_conditions(deps), "Ace3, LibSharedMedia-3.0");
    }

    #[test]
    fn test_load_condition_stripping() {
        let s = "My Addon [AllowLoadGameType vanilla]";
        assert_eq!(strip_load_conditions(s), "My Addon");

        let temp = tempfile::tempdir().unwrap();
        let toc_file = temp.path().join("ConditionTest.toc");
        fs::write(
            &toc_file,
            "## Interface: 11508\n## Title: Addon Title [AllowLoadGameType vanilla]\n## RequiredDeps: Ace3 [AllowLoadGameType vanilla], LibSharedMedia-3.0\n",
        )
        .unwrap();

        let meta = parse_toc_file(&toc_file);
        assert_eq!(meta.title.as_deref(), Some("Addon Title"));
        assert_eq!(meta.required_deps, vec!["Ace3", "LibSharedMedia-3.0"]);
    }

    #[test]
    fn test_guarded_title_resolution() {
        let temp = tempfile::tempdir().unwrap();
        let toc_file = temp.path().join("Guarded.toc");
        fs::write(
            &toc_file,
            "## Interface: 11508, 110002\n## Title: Generic Addon\n## Title: Addon (Vanilla) [AllowLoadGameType vanilla]\n## Title: Addon (Retail) [AllowLoadGameType mainline]\n",
        )
        .unwrap();

        let meta = parse_toc_file(&toc_file);
        assert_eq!(
            resolve_title_for_flavor(&meta, "forever"),
            Some("Addon (Vanilla)".to_string())
        );
        assert_eq!(
            resolve_title_for_flavor(&meta, "classic_era"),
            Some("Addon (Vanilla)".to_string())
        );
        assert_eq!(
            resolve_title_for_flavor(&meta, "retail"),
            Some("Addon (Retail)".to_string())
        );

        let temp2 = tempfile::tempdir().unwrap();
        let toc_file2 = temp2.path().join("UnguardedFallback.toc");
        fs::write(
            &toc_file2,
            "## Interface: 110002\n## Title: Fallback Title\n## Title: Only Vanilla [AllowLoadGameType vanilla]\n",
        )
        .unwrap();
        let meta2 = parse_toc_file(&toc_file2);
        assert_eq!(
            resolve_title_for_flavor(&meta2, "retail"),
            Some("Fallback Title".to_string())
        );
    }
}
