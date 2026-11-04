use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::Duration;
use uuid::Uuid;
use crate::logging::append_app_log;

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct SwapTransactionJournal {
    pub tx_id: String,
    pub created_at_utc: String,
    pub candidate_folders: Vec<String>,
    pub previous_folders: Vec<String>,
    pub asides: Vec<(String, PathBuf)>, // (folder_name, aside_path)
    pub placed_folders: Vec<String>,
}

#[cfg(windows)]
pub fn set_writable_recursive(path: &Path) {
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
pub fn set_writable_recursive(_path: &Path) {}

pub fn remove_dir_all_safe(path: &Path) -> std::io::Result<()> {
    if !path.exists() {
        return Ok(());
    }

    let mut last_err = None;
    for attempt in 0..5 {
        set_writable_recursive(path);
        match fs::remove_dir_all(path) {
            Ok(()) => return Ok(()),
            Err(e) => {
                last_err = Some(e);
                if attempt < 4 {
                    sleep(Duration::from_millis(25 * (1 << attempt)));
                }
            }
        }
    }

    Err(last_err.unwrap_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::Other, "Failed to remove directory after retries")
    }))
}

pub fn move_directory_atomic(source: &Path, dest: &Path) -> std::io::Result<()> {
    set_writable_recursive(source);
    if dest.exists() {
        set_writable_recursive(dest);
    }

    for attempt in 0..5 {
        match fs::rename(source, dest) {
            Ok(()) => return Ok(()),
            Err(_e) => {
                if attempt < 4 {
                    sleep(Duration::from_millis(25 * (1 << attempt)));
                }
            }
        }
    }

    // Cross-volume fallback: copy to staging folder on target volume, then rename atomically
    let parent = dest.parent().unwrap_or(dest);
    let tmp_dest = parent.join(format!(".furphy-staging-{}", Uuid::new_v4().simple()));
    if tmp_dest.exists() {
        let _ = remove_dir_all_safe(&tmp_dest);
    }

    copy_dir_all(source, &tmp_dest)?;

    let mut rename_err = None;
    for attempt in 0..5 {
        match fs::rename(&tmp_dest, dest) {
            Ok(()) => {
                rename_err = None;
                break;
            }
            Err(e) => {
                rename_err = Some(e);
                if attempt < 4 {
                    sleep(Duration::from_millis(25 * (1 << attempt)));
                }
            }
        }
    }

    if let Some(e) = rename_err {
        let _ = remove_dir_all_safe(&tmp_dest);
        return Err(e);
    }

    let _ = remove_dir_all_safe(source);
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

fn write_journal_file(journal_path: &Path, journal: &SwapTransactionJournal) {
    if let Ok(json) = serde_json::to_string(journal) {
        let _ = fs::write(journal_path, json);
    }
}

pub fn restore_interrupted_folder_swaps(addons_path: &Path) {
    if !addons_path.exists() {
        return;
    }

    let entries = match fs::read_dir(addons_path) {
        Ok(e) => e,
        Err(_) => return,
    };

    let mut journal_files = Vec::new();
    let mut dir_entries = Vec::new();

    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();

        if path.is_file() && name.starts_with(".furphy-swap-tx-") && name.ends_with(".journal") {
            journal_files.push(path);
        } else if path.is_dir() {
            dir_entries.push((path, name, entry.metadata().and_then(|m| m.modified()).unwrap_or(std::time::SystemTime::UNIX_EPOCH)));
        }
    }

    // Step 1: Reconcile explicit transaction journals (crash recovery)
    for journal_path in journal_files {
        if let Ok(content) = fs::read_to_string(&journal_path) {
            if let Ok(journal) = serde_json::from_str::<SwapTransactionJournal>(&content) {
                // Revert any partially placed candidate folders
                for placed in &journal.placed_folders {
                    let placed_path = addons_path.join(placed);
                    let _ = remove_dir_all_safe(&placed_path);
                    append_app_log(
                        "WARN",
                        &format!(
                            "Cleaned uncommitted placed folder '{}' from transaction '{}'",
                            placed, journal.tx_id
                        ),
                    );
                }

                // Restore all folders moved aside
                for (orig_name, aside_path) in &journal.asides {
                    if aside_path.exists() {
                        let orig_path = addons_path.join(orig_name);
                        if orig_path.exists() {
                            let _ = remove_dir_all_safe(&orig_path);
                        }
                        if let Ok(()) = move_directory_atomic(aside_path, &orig_path) {
                            append_app_log(
                                "WARN",
                                &format!(
                                    "Restored folder '{}' from interrupted swap transaction '{}'",
                                    orig_name, journal.tx_id
                                ),
                            );
                        }
                    }
                }
            }
        }
        let _ = fs::remove_file(&journal_path);
    }

    // Step 2: Clean up orphaned staging directories and group asides
    let mut asides: std::collections::HashMap<String, Vec<(PathBuf, std::time::SystemTime)>> =
        std::collections::HashMap::new();

    for (path, name, mtime) in dir_entries {
        if name.starts_with(".furphy-staging-") || name.starts_with(".staging-") {
            let _ = remove_dir_all_safe(&path);
            append_app_log("INFO", &format!("Removed interrupted staging folder '{}'", name));
        } else if let Some(pos) = name.find(".furphy-old-") {
            let original_name = name[..pos].to_string();
            asides.entry(original_name).or_default().push((path, mtime));
        } else if let Some(pos) = name.find(".furphy-aside-") {
            let original_name = name[..pos].to_string();
            asides.entry(original_name).or_default().push((path, mtime));
        } else if let Some(pos) = name.find(".aside") {
            let original_name = name[..pos].to_string();
            asides.entry(original_name).or_default().push((path, mtime));
        }
    }

    // Step 3: Reconcile asides without journals (legacy or unjournaled crashes)
    for (original_name, mut aside_list) in asides {
        let original_path = addons_path.join(&original_name);
        aside_list.sort_by(|a, b| b.1.cmp(&a.1));

        if !original_path.exists() {
            if let Some((freshest, _)) = aside_list.first() {
                if move_directory_atomic(freshest, &original_path).is_ok() {
                    append_app_log(
                        "WARN",
                        &format!("Restored folder '{}' from interrupted earlier update", original_name),
                    );
                }
            }
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

pub fn execute_atomic_swap(
    addons_path: &Path,
    staged_extract_dir: &Path,
    candidate_folders: &[String],
    previous_folders: &[String],
    protected_folders: &HashSet<String>,
) -> Result<Vec<String>, String> {
    restore_interrupted_folder_swaps(addons_path);

    let tx_id = Uuid::new_v4().simple().to_string();
    let journal_path = addons_path.join(format!(".furphy-swap-tx-{}.journal", tx_id));

    let mut journal = SwapTransactionJournal {
        tx_id: tx_id.clone(),
        created_at_utc: chrono::Utc::now().to_rfc3339(),
        candidate_folders: candidate_folders.to_vec(),
        previous_folders: previous_folders.to_vec(),
        asides: Vec::new(),
        placed_folders: Vec::new(),
    };

    write_journal_file(&journal_path, &journal);

    // Phase 1: Move existing candidate target folders aside
    for folder_name in candidate_folders {
        let dest_path = addons_path.join(folder_name);
        if dest_path.exists() {
            let aside_path = addons_path.join(format!("{}.furphy-old-{}", folder_name, &tx_id[..8]));
            if aside_path.exists() {
                let _ = remove_dir_all_safe(&aside_path);
            }

            if let Err(e) = move_directory_atomic(&dest_path, &aside_path) {
                append_app_log("ERROR", &format!("Failed to rename folder '{}' aside: {}", folder_name, e));

                // Rollback Phase 1
                for (orig_name, aside) in &journal.asides {
                    let restore_dest = addons_path.join(orig_name);
                    let _ = move_directory_atomic(aside, &restore_dest);
                }
                let _ = fs::remove_file(&journal_path);

                return Err(format!("Failed to rename folder '{}' aside: {}", folder_name, e));
            }

            journal.asides.push((folder_name.clone(), aside_path));
            write_journal_file(&journal_path, &journal);
        }
    }

    // Phase 2: Move candidate folders into place
    let mut placement_failed = None;
    for folder_name in candidate_folders {
        let source_path = staged_extract_dir.join(folder_name);
        let dest_path = addons_path.join(folder_name);

        if !source_path.exists() {
            placement_failed = Some((folder_name.clone(), format!("Source folder '{}' does not exist in staging", folder_name)));
            break;
        }

        if let Err(e) = move_directory_atomic(&source_path, &dest_path) {
            placement_failed = Some((folder_name.clone(), format!("Failed to place folder '{}': {}", folder_name, e)));
            break;
        }

        journal.placed_folders.push(folder_name.clone());
        write_journal_file(&journal_path, &journal);
    }

    if let Some((failed_folder, err_msg)) = placement_failed {
        append_app_log("ERROR", &err_msg);

        // Rollback Phase 2: remove all placed candidate folders
        for placed in &journal.placed_folders {
            let placed_dest = addons_path.join(placed);
            let _ = remove_dir_all_safe(&placed_dest);
        }

        // Restore all folders moved aside
        for (orig_name, aside) in &journal.asides {
            let orig_dest = addons_path.join(orig_name);
            let _ = remove_dir_all_safe(&orig_dest);
            let _ = move_directory_atomic(aside, &orig_dest);
        }

        let _ = fs::remove_file(&journal_path);
        return Err(format!(
            "Failed to install folder '{}', so no folder of this addon was changed",
            failed_folder
        ));
    }

    // Phase 3: Commit - safely delete all aside copies and remove journal
    for (_orig_name, aside) in &journal.asides {
        let _ = remove_dir_all_safe(aside);
    }
    let _ = fs::remove_file(&journal_path);

    // Phase 4: Stale cleanup - remove old folders not in candidates and not protected
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

    Ok(candidate_folders.to_vec())
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

    #[test]
    fn test_interrupted_swap_with_partial_placed_folder() {
        let temp = tempfile::tempdir().unwrap();
        let addons_dir = temp.path().join("AddOns");
        fs::create_dir_all(&addons_dir).unwrap();

        let aside = addons_dir.join("CrashAddon.furphy-old-99999999");
        fs::create_dir_all(&aside).unwrap();
        fs::write(aside.join("original.lua"), b"original code").unwrap();

        let partial = addons_dir.join("CrashAddon");
        fs::create_dir_all(&partial).unwrap();
        fs::write(partial.join("corrupt.lua"), b"partial code").unwrap();

        let journal = SwapTransactionJournal {
            tx_id: "test-tx".to_string(),
            created_at_utc: chrono::Utc::now().to_rfc3339(),
            candidate_folders: vec!["CrashAddon".to_string(), "MissingSecond".to_string()],
            previous_folders: vec!["CrashAddon".to_string()],
            asides: vec![("CrashAddon".to_string(), aside.clone())],
            placed_folders: vec!["CrashAddon".to_string()],
        };
        let journal_path = addons_dir.join(".furphy-swap-tx-test-tx.journal");
        write_journal_file(&journal_path, &journal);

        restore_interrupted_folder_swaps(&addons_dir);

        assert!(!journal_path.exists(), "Journal should be reconciled and removed");
        let restored = addons_dir.join("CrashAddon");
        assert!(restored.exists());
        assert!(restored.join("original.lua").exists(), "Original files should be restored");
        assert!(!restored.join("corrupt.lua").exists(), "Partial uncommitted files must be removed");
        assert!(!aside.exists());
    }

    #[test]
    fn test_orphaned_aside_and_staging_patterns() {
        let temp = tempfile::tempdir().unwrap();
        let addons_dir = temp.path().join("AddOns");
        fs::create_dir_all(&addons_dir).unwrap();

        let staging = addons_dir.join(".furphy-staging-abcd1234");
        fs::create_dir_all(&staging).unwrap();

        let legacy_aside = addons_dir.join("LegacyAddon.aside");
        fs::create_dir_all(&legacy_aside).unwrap();
        fs::write(legacy_aside.join("core.lua"), b"legacy content").unwrap();

        restore_interrupted_folder_swaps(&addons_dir);

        assert!(!staging.exists(), "Interrupted staging folder should be removed");
        assert!(addons_dir.join("LegacyAddon").exists(), "Legacy aside should be restored");
        assert!(addons_dir.join("LegacyAddon").join("core.lua").exists());
        assert!(!legacy_aside.exists());
    }

    #[test]
    fn test_atomic_swap_rollback_on_partial_failure() {
        let temp = tempfile::tempdir().unwrap();
        let addons_dir = temp.path().join("AddOns");
        let staging_dir = temp.path().join("staging");
        fs::create_dir_all(&addons_dir).unwrap();
        fs::create_dir_all(&staging_dir).unwrap();

        // Addon with 2 subfolders
        let addon_main = addons_dir.join("MultiPack");
        fs::create_dir_all(&addon_main).unwrap();
        fs::write(addon_main.join("main.lua"), b"old main").unwrap();

        let addon_sub = addons_dir.join("MultiPack_Sub");
        fs::create_dir_all(&addon_sub).unwrap();
        fs::write(addon_sub.join("sub.lua"), b"old sub").unwrap();

        // Staging only contains MultiPack, missing MultiPack_Sub (simulating extracted archive defect)
        let staged_main = staging_dir.join("MultiPack");
        fs::create_dir_all(&staged_main).unwrap();
        fs::write(staged_main.join("main.lua"), b"new main").unwrap();

        let candidates = vec!["MultiPack".to_string(), "MultiPack_Sub".to_string()];
        let previous = vec!["MultiPack".to_string(), "MultiPack_Sub".to_string()];
        let protected = HashSet::new();

        let result = execute_atomic_swap(
            &addons_dir,
            &staging_dir,
            &candidates,
            &previous,
            &protected,
        );

        assert!(result.is_err(), "Swap should fail because MultiPack_Sub is missing in staging");
        // Verify original folders in addons_dir were NOT modified or deleted
        assert!(addon_main.join("main.lua").exists());
        let main_content = fs::read_to_string(addon_main.join("main.lua")).unwrap();
        assert_eq!(main_content, "old main", "MultiPack should be rolled back to old version");
        assert!(addon_sub.join("sub.lua").exists(), "MultiPack_Sub should remain intact");
    }
}
