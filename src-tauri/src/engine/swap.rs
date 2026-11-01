use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::Duration;
use uuid::Uuid;
use crate::logging::append_app_log;

#[derive(Debug)]
struct Placement {
    dest_path: PathBuf,
    aside_path: Option<PathBuf>,
}

#[cfg(windows)]
fn set_writable_recursive(path: &Path) {
    if let Ok(entries) = fs::read_dir(path) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                set_writable_recursive(&p);
            } else if let Ok(metadata) = fs::metadata(&p) {
                let mut perms = metadata.permissions();
                if perms.readonly() {
                    perms.set_readonly(false);
                    let _ = fs::set_permissions(&p, perms);
                }
            }
        }
    }
    if let Ok(metadata) = fs::metadata(path) {
        let mut perms = metadata.permissions();
        if perms.readonly() {
            perms.set_readonly(false);
            let _ = fs::set_permissions(path, perms);
        }
    }
}

#[cfg(not(windows))]
fn set_writable_recursive(_path: &Path) {}

pub fn remove_dir_all_safe(path: &Path) -> std::io::Result<()> {
    if !path.exists() {
        return Ok(());
    }
    set_writable_recursive(path);
    fs::remove_dir_all(path)
}

pub fn restore_interrupted_folder_swaps(addons_path: &Path) {
    if !addons_path.exists() {
        return;
    }

    let entries = match fs::read_dir(addons_path) {
        Ok(e) => e,
        Err(_) => return,
    };

    // Group asides by base folder name with timestamps
    let mut asides: std::collections::HashMap<String, Vec<(PathBuf, std::time::SystemTime)>> = std::collections::HashMap::new();

    for entry_res in entries.flatten() {
        let path = entry_res.path();
        if path.is_dir() {
            let name = entry_res.file_name().to_string_lossy().to_string();
            if name.starts_with(".furphy-staging-") {
                let _ = remove_dir_all_safe(&path);
                append_app_log("INFO", &format!("Removed interrupted staging folder '{}'", name));
            } else if let Some(pos) = name.find(".furphy-old-") {
                let original_name = name[..pos].to_string();
                let mtime = entry_res.metadata().and_then(|m| m.modified()).unwrap_or(std::time::SystemTime::UNIX_EPOCH);
                asides.entry(original_name).or_default().push((path, mtime));
            }
        }
    }

    for (original_name, mut aside_list) in asides {
        let original_path = addons_path.join(&original_name);
        // Sort asides newest first
        aside_list.sort_by(|a, b| b.1.cmp(&a.1));

        if !original_path.exists() {
            // Restore freshest aside
            if let Some((freshest, _)) = aside_list.first() {
                if fs::rename(freshest, &original_path).is_ok() {
                    append_app_log(
                        "WARN",
                        &format!("Restored folder '{}' from interrupted earlier update", original_name),
                    );
                }
            }
            // Delete remaining older asides
            for (older, _) in aside_list.iter().skip(1) {
                let _ = remove_dir_all_safe(older);
            }
        } else {
            // Original exists, delete all leftover asides
            for (aside, _) in aside_list {
                let _ = remove_dir_all_safe(&aside);
                append_app_log("INFO", &format!("Removed leftover aside '{}'", aside.display()));
            }
        }
    }
}

fn move_directory_atomic(source: &Path, dest: &Path) -> std::io::Result<()> {
    if fs::rename(source, dest).is_ok() {
        return Ok(());
    }

    // Cross-volume fallback: copy to staging folder on target volume, then rename atomically
    let parent = dest.parent().unwrap_or(dest);
    let tmp_dest = parent.join(format!(".furphy-staging-{}", Uuid::new_v4().simple()));
    if tmp_dest.exists() {
        #[cfg(windows)]
        set_writable_recursive(&tmp_dest);
        let _ = fs::remove_dir_all(&tmp_dest);
    }

    copy_dir_all(source, &tmp_dest)?;

    if let Err(e) = fs::rename(&tmp_dest, dest) {
        #[cfg(windows)]
        set_writable_recursive(&tmp_dest);
        let _ = fs::remove_dir_all(&tmp_dest);
        return Err(e);
    }

    #[cfg(windows)]
    set_writable_recursive(source);
    let _ = fs::remove_dir_all(source);
    Ok(())
}

fn copy_dir_all(src: &Path, dst: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let dest_child = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir_all(&entry.path(), &dest_child)?;
        } else {
            fs::copy(entry.path(), dest_child)?;
        }
    }
    Ok(())
}

pub fn execute_atomic_swap(
    addons_path: &Path,
    staged_extract_dir: &Path,
    candidate_folders: &[String],
    previous_folders: &[String],
    protected_folders: &HashSet<String>,
) -> Result<Vec<String>, String> {
    restore_interrupted_folder_swaps(addons_path);

    let mut placements: Vec<Placement> = Vec::new();
    let mut installed_folders: Vec<String> = Vec::new();
    let mut failed_folder: Option<String> = None;

    for folder_name in candidate_folders {
        let source_path = staged_extract_dir.join(folder_name);
        let dest_path = addons_path.join(folder_name);

        let mut aside_path = None;
        let mut swap_ok = false;

        for attempt in 1..=3 {
            // If dest exists, rename aside
            if dest_path.exists() {
                let aside = addons_path.join(format!("{}.furphy-old-{}", folder_name, &Uuid::new_v4().simple().to_string()[..8]));
                if let Err(e) = move_directory_atomic(&dest_path, &aside) {
                    if attempt < 3 {
                        sleep(Duration::from_millis(150));
                        continue;
                    } else {
                        append_app_log("ERROR", &format!("Failed to rename folder '{}' aside: {}", folder_name, e));
                        break;
                    }
                }
                aside_path = Some(aside);
            }

            // Move new folder into place
            if let Err(e) = move_directory_atomic(&source_path, &dest_path) {
                // Restore aside if we took one
                if let Some(ref aside) = aside_path {
                    let _ = move_directory_atomic(aside, &dest_path);
                    aside_path = None;
                }
                if attempt < 3 {
                    sleep(Duration::from_millis(150));
                    continue;
                } else {
                    append_app_log("ERROR", &format!("Failed to place folder '{}': {}", folder_name, e));
                    break;
                }
            }

            swap_ok = true;
            break;
        }

        if swap_ok {
            placements.push(Placement {
                dest_path,
                aside_path,
            });
            installed_folders.push(folder_name.clone());
        } else {
            failed_folder = Some(folder_name.clone());
            break;
        }
    }

    if let Some(failed) = failed_folder {
        // Rollback all already swapped folders
        for placement in placements.into_iter().rev() {
            let _ = remove_dir_all_safe(&placement.dest_path);
            if let Some(aside) = placement.aside_path {
                let _ = move_directory_atomic(&aside, &placement.dest_path);
            }
        }
        return Err(format!(
            "Failed to install folder '{}', so no folder of this addon was changed",
            failed
        ));
    }

    // Commit: delete all aside copies
    for placement in placements {
        if let Some(aside) = placement.aside_path {
            let _ = remove_dir_all_safe(&aside);
        }
    }

    // Stale cleanup: remove old folders that are not in candidate_folders and not protected
    for old_folder in previous_folders {
        if !candidate_folders.iter().any(|c| c.eq_ignore_ascii_case(old_folder)) {
            let lower_old = old_folder.to_ascii_lowercase();
            if protected_folders.contains(&lower_old) {
                append_app_log(
                    "INFO",
                    &format!(
                        "Kept folder '{}' - no longer part of addon but still tracked by another addon",
                        old_folder
                    ),
                );
                continue;
            }

            let old_path = addons_path.join(old_folder);
            if old_path.exists() {
                let _ = remove_dir_all_safe(&old_path);
                append_app_log("INFO", &format!("Removed stale folder '{}'", old_folder));
            }
        }
    }

    Ok(installed_folders)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_atomic_swap_and_stale_cleanup() {
        let temp = tempfile::tempdir().unwrap();
        let addons_dir = temp.path().join("AddOns");
        let staging_dir = temp.path().join("staging");
        fs::create_dir_all(&addons_dir).unwrap();
        fs::create_dir_all(&staging_dir).unwrap();

        // Previous folder in AddOns
        let old_folder = addons_dir.join("MyAddon");
        fs::create_dir_all(&old_folder).unwrap();
        fs::write(old_folder.join("old.lua"), b"old content").unwrap();

        // Stale folder to be deleted
        let stale_folder = addons_dir.join("MyAddon_OldSub");
        fs::create_dir_all(&stale_folder).unwrap();
        fs::write(stale_folder.join("stale.lua"), b"stale").unwrap();

        // New folder in staging
        let new_folder = staging_dir.join("MyAddon");
        fs::create_dir_all(&new_folder).unwrap();
        fs::write(new_folder.join("new.lua"), b"new content").unwrap();

        let candidates = vec!["MyAddon".to_string()];
        let previous = vec!["MyAddon".to_string(), "MyAddon_OldSub".to_string()];
        let protected = HashSet::new();

        let installed = execute_atomic_swap(
            &addons_dir,
            &staging_dir,
            &candidates,
            &previous,
            &protected,
        )
        .unwrap();

        assert_eq!(installed, vec!["MyAddon".to_string()]);
        assert!(addons_dir.join("MyAddon").join("new.lua").exists());
        assert!(!addons_dir.join("MyAddon").join("old.lua").exists());
        assert!(!addons_dir.join("MyAddon_OldSub").exists(), "Stale folder should be removed");
    }

    #[test]
    fn test_interrupted_swap_recovery() {
        let temp = tempfile::tempdir().unwrap();
        let addons_dir = temp.path().join("AddOns");
        fs::create_dir_all(&addons_dir).unwrap();

        // Simulate interrupted swap where aside exists but original was deleted
        let aside = addons_dir.join("RecoverMe.furphy-old-1234abcd");
        fs::create_dir_all(&aside).unwrap();
        fs::write(aside.join("file.lua"), b"recovered").unwrap();

        restore_interrupted_folder_swaps(&addons_dir);

        let restored = addons_dir.join("RecoverMe");
        assert!(restored.exists(), "Original folder should be restored from aside!");
        assert!(restored.join("file.lua").exists());
        assert!(!aside.exists());
    }
}
