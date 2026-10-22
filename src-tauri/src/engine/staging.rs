use std::fs;
use std::path::{Path, PathBuf};

pub fn get_flavour_staging_dir(data_dir: &Path, flavour: &str) -> PathBuf {
    data_dir.join("staging").join(flavour)
}

pub fn prepare_flavour_staging_dir(data_dir: &Path, flavour: &str) -> std::io::Result<PathBuf> {
    let staging = get_flavour_staging_dir(data_dir, flavour);
    if staging.exists() {
        let _ = fs::remove_dir_all(&staging);
    }
    fs::create_dir_all(&staging)?;
    Ok(staging)
}
