use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use crate::logging::append_app_log;

pub const MAX_TOTAL_UNCOMPRESSED_BYTES: u64 = 1024 * 1024 * 1024; // 1 GB
pub const MAX_COMPRESSION_RATIO: u64 = 100;
pub const RATIO_CHECK_THRESHOLD_BYTES: u64 = 1024 * 1024; // 1 MB
pub const MAX_ENTRIES_COUNT: usize = 10_000;

#[derive(Debug, thiserror::Error)]
pub enum ArchiveError {
    #[error("Zip-Slip detected: invalid entry path '{0}'")]
    ZipSlip(String),
    #[error("Zip bomb detected: compression ratio exceeded for entry '{0}'")]
    ZipBomb(String),
    #[error("Package uncompressed size exceeds 1 GB safety limit")]
    TotalSizeExceeded,
    #[error("Package entry count exceeds 10,000 safety limit")]
    EntryCountExceeded,
    #[error("Failed reading zip archive: {0}")]
    ZipRead(String),
    #[error("IO error during extraction: {0}")]
    Io(#[from] std::io::Error),
    #[error("No valid addon folders (with a .toc file) found in package")]
    NoValidAddonFolders,
}

pub fn is_safe_entry_name(name: &str) -> bool {
    let normalized = name.replace('\\', "/");

    // No leading slash or drive letters
    if normalized.starts_with('/') || (normalized.len() >= 2 && normalized.as_bytes()[1] == b':') {
        return false;
    }

    // Check components
    for comp in normalized.split('/') {
        if comp == ".." {
            return false;
        }
    }

    true
}

pub fn extract_addon_archive(
    zip_path: &Path,
    extract_dir: &Path,
) -> Result<Vec<String>, ArchiveError> {
    let res = extract_addon_archive_internal(zip_path, extract_dir);
    if res.is_err() && extract_dir.exists() {
        let _ = fs::remove_dir_all(extract_dir);
    }
    res
}

fn extract_addon_archive_internal(
    zip_path: &Path,
    extract_dir: &Path,
) -> Result<Vec<String>, ArchiveError> {
    if extract_dir.exists() {
        let _ = fs::remove_dir_all(extract_dir);
    }
    fs::create_dir_all(extract_dir)?;

    let file = File::open(zip_path).map_err(|e| ArchiveError::ZipRead(e.to_string()))?;
    let mut archive = zip::ZipArchive::new(file).map_err(|e| ArchiveError::ZipRead(e.to_string()))?;

    if archive.len() > MAX_ENTRIES_COUNT {
        return Err(ArchiveError::EntryCountExceeded);
    }

    let mut total_uncompressed_bytes: u64 = 0;
    let mut actual_total_written_bytes: u64 = 0;

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| ArchiveError::ZipRead(e.to_string()))?;
        let entry_name = entry.name().to_string();

        if !is_safe_entry_name(&entry_name) {
            return Err(ArchiveError::ZipSlip(entry_name));
        }

        // Reject symlinks / reparse points
        if let Some(mode) = entry.unix_mode() {
            if (mode & 0o170000) == 0o120000 {
                return Err(ArchiveError::ZipSlip(format!("Symlink entry rejected: {}", entry_name)));
            }
        }

        let uncompressed_size = entry.size();
        let compressed_size = entry.compressed_size();

        // Check zip bomb ratio for entries over 1 MB
        if uncompressed_size > RATIO_CHECK_THRESHOLD_BYTES {
            let ratio = uncompressed_size / compressed_size.max(1);
            if ratio > MAX_COMPRESSION_RATIO {
                return Err(ArchiveError::ZipBomb(entry_name));
            }
        }

        total_uncompressed_bytes += uncompressed_size;
        if total_uncompressed_bytes > MAX_TOTAL_UNCOMPRESSED_BYTES {
            return Err(ArchiveError::TotalSizeExceeded);
        }

        let clean_path = entry_name.replace('\\', "/");
        let path_parts: Vec<&str> = clean_path.split('/').filter(|s| !s.is_empty()).collect();

        if path_parts.is_empty() {
            continue;
        }

        // If it's a top-level file (length 1 and not a directory), drop it
        if path_parts.len() == 1 && !entry.is_dir() {
            append_app_log("WARN", &format!("Ignoring top-level file '{}' in package", entry_name));
            continue;
        }

        let out_path = extract_dir.join(PathBuf::from(&entry_name));

        if entry.is_dir() {
            fs::create_dir_all(&out_path)?;
        } else {
            if let Some(parent) = out_path.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut out_file = File::create(&out_path)?;
            let mut buffer = [0u8; 64 * 1024];
            let mut written_for_entry = 0u64;

            loop {
                let n = entry.read(&mut buffer)?;
                if n == 0 {
                    break;
                }
                out_file.write_all(&buffer[..n])?;
                written_for_entry += n as u64;
                actual_total_written_bytes += n as u64;

                if actual_total_written_bytes > MAX_TOTAL_UNCOMPRESSED_BYTES {
                    return Err(ArchiveError::TotalSizeExceeded);
                }

                // Validate that actual written bytes didn't lie in headers
                if written_for_entry > RATIO_CHECK_THRESHOLD_BYTES {
                    let actual_ratio = written_for_entry / compressed_size.max(1);
                    if actual_ratio > MAX_COMPRESSION_RATIO {
                        return Err(ArchiveError::ZipBomb(entry_name));
                    }
                }
            }
        }
    }

    // Now inspect top-level directories in extract_dir
    let mut candidate_folders = Vec::new();
    let entries = fs::read_dir(extract_dir)?;

    for entry_res in entries {
        let entry = entry_res?;
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            let folder_name = entry.file_name().to_string_lossy().to_string();
            // Check for at least one .toc file inside this folder
            let mut has_toc = false;
            if let Ok(sub_entries) = fs::read_dir(entry.path()) {
                for sub in sub_entries.flatten() {
                    let sub_name = sub.file_name().to_string_lossy().to_ascii_lowercase();
                    if sub_name.ends_with(".toc") {
                        has_toc = true;
                        break;
                    }
                }
            }

            if has_toc {
                candidate_folders.push(folder_name);
            } else {
                append_app_log(
                    "WARN",
                    &format!("Top-level folder '{}' has no .toc file, skipping", folder_name),
                );
            }
        }
    }

    if candidate_folders.is_empty() {
        return Err(ArchiveError::NoValidAddonFolders);
    }

    candidate_folders.sort();
    Ok(candidate_folders)
}

#[cfg(test)]
mod tests {
    use super::*;
    use zip::write::{SimpleFileOptions, ZipWriter};


    #[test]
    fn test_is_safe_entry_name() {
        assert!(is_safe_entry_name("MyAddon/MyAddon.toc"));
        assert!(is_safe_entry_name("MyAddon/Sub/File.lua"));
        assert!(!is_safe_entry_name("../MyAddon/File.lua"));
        assert!(!is_safe_entry_name("MyAddon/../../etc/passwd"));
        assert!(!is_safe_entry_name("/root/file.lua"));
        assert!(!is_safe_entry_name("C:/Windows/System32/calc.exe"));
    }

    #[test]
    fn test_extract_valid_addon_zip() {
        let temp = tempfile::tempdir().unwrap();
        let zip_path = temp.path().join("test_addon.zip");
        let extract_dir = temp.path().join("extracted");

        // Create zip with MyAddon/MyAddon.toc and a top-level .exe to drop
        let file = File::create(&zip_path).unwrap();
        let mut zip = ZipWriter::new(file);

        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        zip.start_file("malicious.exe", options).unwrap();
        zip.write_all(b"not an addon").unwrap();

        zip.start_file("MyAddon/MyAddon.toc", options).unwrap();
        zip.write_all(b"## Interface: 110000\n## Title: My Addon").unwrap();

        zip.start_file("MyAddon/Core.lua", options).unwrap();
        zip.write_all(b"print('hello')").unwrap();

        zip.finish().unwrap();

        let candidates = extract_addon_archive(&zip_path, &extract_dir).unwrap();
        assert_eq!(candidates, vec!["MyAddon".to_string()]);
        assert!(!extract_dir.join("malicious.exe").exists(), "Root .exe should be dropped!");
        assert!(extract_dir.join("MyAddon").join("MyAddon.toc").exists());
    }

    #[test]
    fn test_zip_slip_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let zip_path = temp.path().join("slip.zip");
        let extract_dir = temp.path().join("extracted");

        let file = File::create(&zip_path).unwrap();
        let mut zip = ZipWriter::new(file);
        let options = SimpleFileOptions::default();
        zip.start_file("../outside.txt", options).unwrap();
        zip.write_all(b"pwned").unwrap();
        zip.finish().unwrap();

        let res = extract_addon_archive(&zip_path, &extract_dir);
        assert!(res.is_err());
        match res.unwrap_err() {
            ArchiveError::ZipSlip(_) => {}
            other => panic!("Expected ZipSlip, got {:?}", other),
        }
    }

    #[test]
    fn test_zip_bomb_ratio_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let zip_path = temp.path().join("bomb.zip");
        let extract_dir = temp.path().join("extracted");

        let file = File::create(&zip_path).unwrap();
        let mut zip = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

        // 2 MB of repeating bytes compresses to < 2 KB (ratio > 1000:1, threshold is 100:1)
        zip.start_file("MyAddon/huge.lua", options).unwrap();
        let zeros = vec![0u8; 2 * 1024 * 1024];
        zip.write_all(&zeros).unwrap();

        zip.start_file("MyAddon/MyAddon.toc", options).unwrap();
        zip.write_all(b"## Interface: 110000").unwrap();
        zip.finish().unwrap();

        let res = extract_addon_archive(&zip_path, &extract_dir);
        assert!(res.is_err());
        match res.unwrap_err() {
            ArchiveError::ZipBomb(_) => {}
            other => panic!("Expected ZipBomb error, got {:?}", other),
        }
        assert!(!extract_dir.exists(), "Extract dir should be cleaned up on failure");
    }

    #[test]
    fn test_missing_toc_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let zip_path = temp.path().join("notoc.zip");
        let extract_dir = temp.path().join("extracted");

        let file = File::create(&zip_path).unwrap();
        let mut zip = ZipWriter::new(file);
        let options = SimpleFileOptions::default();

        zip.start_file("RandomFolder/file.txt", options).unwrap();
        zip.write_all(b"hello world").unwrap();
        zip.finish().unwrap();

        let res = extract_addon_archive(&zip_path, &extract_dir);
        assert!(res.is_err());
        match res.unwrap_err() {
            ArchiveError::NoValidAddonFolders => {}
            other => panic!("Expected NoValidAddonFolders, got {:?}", other),
        }
    }

    #[test]
    fn test_symlink_entry_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let zip_path = temp.path().join("symlink.zip");
        let extract_dir = temp.path().join("extracted");

        let file = File::create(&zip_path).unwrap();
        let mut zip = ZipWriter::new(file);
        let options = SimpleFileOptions::default();
        zip.add_symlink("MyAddon/link", "/etc/passwd", options).unwrap();
        zip.finish().unwrap();

        let res = extract_addon_archive(&zip_path, &extract_dir);
        assert!(res.is_err());
        match res.unwrap_err() {
            ArchiveError::ZipSlip(msg) => {
                assert!(msg.contains("Symlink entry rejected"));
            }
            other => panic!("Expected ZipSlip for symlink, got {:?}", other),
        }
    }
}
