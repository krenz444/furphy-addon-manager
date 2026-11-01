use std::fs;
use std::path::{Path, PathBuf};
use serde::{Deserialize, Serialize};
use crate::engine::flavours::resolve_classic_progression;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TocMetadata {
    pub interface: Option<i32>,
    pub title: Option<String>,
    pub version: Option<String>,
    pub author: Option<String>,
    pub curse_project_id: Option<i64>,
    pub wago_id: Option<String>,
    pub required_deps: Vec<String>,
    pub optional_deps: Vec<String>,
    pub x_flavor: Option<String>,
}

pub fn strip_wow_formatting(input: &str) -> String {
    let mut out = String::new();
    let mut chars = input.chars().peekable();

    while let Some(c) = chars.next() {
        if c == '|' {
            if let Some(&next) = chars.peek() {
                if next == 'c' || next == 'C' {
                    // |cAARRGGBB - consume 'c' plus 8 hex chars
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

            match key.as_str() {
                "interface" => {
                    meta.interface = value.parse::<i32>().ok();
                }
                "title" => {
                    meta.title = Some(strip_wow_formatting(value));
                }
                "version" => {
                    meta.version = Some(value.to_string());
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
                    for dep in value.split([',', ' ', '\t']) {
                        let d = dep.trim();
                        if !d.is_empty() && !meta.required_deps.iter().any(|existing| existing.eq_ignore_ascii_case(d)) {
                            meta.required_deps.push(d.to_string());
                        }
                    }
                }
                "optionaldeps" | "x-optionaldeps" => {
                    for dep in value.split([',', ' ', '\t']) {
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

    meta
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
        "classic_era" => EraSelector {
            x_flavor_tag: "Vanilla",
            suffixes: &["_Vanilla", "_Classic", "-Classic"],
        },
        "classic" => {
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

    let selector = get_era_selector(flavour, client_interface);

    // Rule 1: Check X-Flavor tag in each toc
    for toc in &tocs {
        let meta = parse_toc_file(toc);
        if let Some(ref tag) = meta.x_flavor {
            if tag.eq_ignore_ascii_case(selector.x_flavor_tag) {
                return Some(toc.clone());
            }
        }
    }

    // Rule 2: Check suffix matching
    for suffix in selector.suffixes {
        for toc in &tocs {
            let stem = toc.file_stem().unwrap_or_default().to_string_lossy();
            if stem.ends_with(suffix) {
                return Some(toc.clone());
            }
        }
    }

    // Rule 3: Bare <Folder>.toc matching folder name
    let folder_name = folder_path.file_name().unwrap_or_default().to_string_lossy();
    let bare_expected = format!("{}.toc", folder_name);
    for toc in &tocs {
        let file_name = toc.file_name().unwrap_or_default().to_string_lossy();
        if file_name.eq_ignore_ascii_case(&bare_expected) {
            return Some(toc.clone());
        }
    }

    // Rule 4: Fallback to first .toc
    tocs.into_iter().next()
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
        assert_eq!(meta.title.as_deref(), Some("Test Addon"));
        assert_eq!(meta.version.as_deref(), Some("1.2.3"));
        assert_eq!(meta.author.as_deref(), Some("Eric"));
        assert_eq!(meta.curse_project_id, Some(12345));
        assert_eq!(meta.required_deps, vec!["Ace3", "LibSharedMedia-3.0"]);
    }
}
