use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;
use crate::engine::swap::remove_dir_all_safe;
use crate::logging::append_app_log;

pub fn get_flavour_staging_dir(data_dir: &Path, flavour: &str) -> PathBuf {
    data_dir.join("staging").join(flavour)
}

pub fn clean_flavour_staging_dir(data_dir: &Path, flavour: &str) -> std::io::Result<()> {
    let staging = get_flavour_staging_dir(data_dir, flavour);
    if staging.exists() {
        remove_dir_all_safe(&staging)?;
    }
    Ok(())
}

pub fn prepare_flavour_staging_dir(data_dir: &Path, flavour: &str) -> std::io::Result<PathBuf> {
    let staging = get_flavour_staging_dir(data_dir, flavour);
    if staging.exists() {
        let _ = remove_dir_all_safe(&staging);
    }
    fs::create_dir_all(&staging)?;
    Ok(staging)
}

pub fn create_unique_staging_subfolder(staging_dir: &Path, prefix: &str) -> std::io::Result<PathBuf> {
    let subfolder = staging_dir.join(format!("{}_{}", prefix, Uuid::new_v4().simple()));
    if subfolder.exists() {
        let _ = remove_dir_all_safe(&subfolder);
    }
    fs::create_dir_all(&subfolder)?;
    Ok(subfolder)
}

pub fn cleanup_orphaned_staging_dirs(data_dir: &Path) -> std::io::Result<usize> {
    let staging_root = data_dir.join("staging");
    if !staging_root.exists() {
        return Ok(0);
    }

    let entries = match fs::read_dir(&staging_root) {
        Ok(e) => e,
        Err(err) => return Err(err),
    };

    let mut cleaned_count = 0;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if let Ok(()) = remove_dir_all_safe(&path) {
                cleaned_count += 1;
                append_app_log("INFO", &format!("Cleaned orphaned staging directory '{}'", path.display()));
            }
        } else if path.is_file() {
            if let Ok(()) = fs::remove_file(&path) {
                cleaned_count += 1;
                append_app_log("INFO", &format!("Removed orphaned staging file '{}'", path.display()));
            }
        }
    }

    Ok(cleaned_count)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_prepare_and_clean_flavour_staging_dir() {
        let temp = tempfile::tempdir().unwrap();
        let data_dir = temp.path();

        let staging = prepare_flavour_staging_dir(data_dir, "retail").unwrap();
        assert!(staging.exists());
        assert_eq!(staging, data_dir.join("staging").join("retail"));

        // Create dummy files inside staging
        fs::write(staging.join("dummy.txt"), b"temp content").unwrap();
        assert!(staging.join("dummy.txt").exists());

        // Re-preparing should safely wipe existing contents
        let staging2 = prepare_flavour_staging_dir(data_dir, "retail").unwrap();
        assert!(staging2.exists());
        assert!(!staging2.join("dummy.txt").exists());

        // Clean flavour staging dir explicitly
        clean_flavour_staging_dir(data_dir, "retail").unwrap();
        assert!(!staging2.exists());
    }

    #[test]
    fn test_create_unique_staging_subfolder() {
        let temp = tempfile::tempdir().unwrap();
        let staging_dir = temp.path();

        let sub1 = create_unique_staging_subfolder(staging_dir, "rollback").unwrap();
        let sub2 = create_unique_staging_subfolder(staging_dir, "rollback").unwrap();

        assert!(sub1.exists());
        assert!(sub2.exists());
        assert_ne!(sub1, sub2, "Subfolders should have distinct unique UUID paths");
    }

    #[test]
    fn test_cleanup_orphaned_staging_dirs() {
        let temp = tempfile::tempdir().unwrap();
        let data_dir = temp.path();

        let retail_staging = prepare_flavour_staging_dir(data_dir, "retail").unwrap();
        let classic_staging = prepare_flavour_staging_dir(data_dir, "classic").unwrap();
        fs::write(data_dir.join("staging").join("stray.zip"), b"partial zip").unwrap();

        assert!(retail_staging.exists());
        assert!(classic_staging.exists());
        assert!(data_dir.join("staging").join("stray.zip").exists());

        let count = cleanup_orphaned_staging_dirs(data_dir).unwrap();
        assert!(count >= 3, "Expected at least 3 orphaned items cleaned up, got {}", count);
        assert!(!retail_staging.exists());
        assert!(!classic_staging.exists());
        assert!(!data_dir.join("staging").join("stray.zip").exists());
    }
}
