use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use crate::logging::append_app_log;

pub const MAX_TOTAL_UNCOMPRESSED_BYTES: u64 = 1024 * 1024 * 1024; // 1 GB
pub const MAX_COMPRESSION_RATIO: u64 = 100;
pub const MAX_MEDIA_COMPRESSION_RATIO: u64 = 5_000;
pub const RATIO_CHECK_THRESHOLD_BYTES: u64 = 1024 * 1024; // 1 MB
pub const RATIO_CHECK_THRESHOLD_BYTES_MEDIA: u64 = 64 * 1024 * 1024; // 64 MB
pub const MAX_ENTRIES_COUNT: usize = 10_000;

pub fn is_media_texture_file(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.ends_with(".tga")
        || lower.ends_with(".blp")
        || lower.ends_with(".bmp")
        || lower.ends_with(".png")
        || lower.ends_with(".wav")
        || lower.ends_with(".mp3")
        || lower.ends_with(".ogg")
        || lower.ends_with(".raw")
}

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

    // No leading slash or any colons (drive letters, NTFS Alternate Data Streams)
    if normalized.starts_with('/') || normalized.contains(':') {
        return false;
    }

    // Windows reserved device names
    const RESERVED_NAMES: &[&str] = &[
        "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7",
        "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    ];

    // Check components
    for comp in normalized.split('/') {
        if comp == ".." {
            return false;
        }
        let base_comp = comp.split('.').next().unwrap_or(comp).to_ascii_lowercase();
        if RESERVED_NAMES.contains(&base_comp.as_str()) {
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

        let is_media = is_media_texture_file(&entry_name);
        let ratio_threshold = if is_media {
            RATIO_CHECK_THRESHOLD_BYTES_MEDIA
        } else {
            RATIO_CHECK_THRESHOLD_BYTES
        };
        let max_ratio = if is_media {
            MAX_MEDIA_COMPRESSION_RATIO
        } else {
            MAX_COMPRESSION_RATIO
        };

        // Check zip bomb ratio for entries over threshold
        if uncompressed_size > ratio_threshold {
            let ratio = uncompressed_size / compressed_size.max(1);
            if ratio > max_ratio {
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
                if written_for_entry > ratio_threshold {
                    let actual_ratio = written_for_entry / compressed_size.max(1);
                    if actual_ratio > max_ratio {
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

pub fn normalize_github_zipball(
    raw_zip_path: &Path,
    repo_name: &str,
    dest_normalized_zip: &Path,
) -> Result<(), ArchiveError> {
    let clean_repo_name = repo_name.trim();
    if clean_repo_name.is_empty()
        || clean_repo_name.starts_with('.')
        || clean_repo_name.contains('/')
        || clean_repo_name.contains('\\')
    {
        return Err(ArchiveError::ZipSlip(format!(
            "Unsafe repo name '{}'",
            repo_name
        )));
    }

    let raw_file = File::open(raw_zip_path).map_err(|e| ArchiveError::ZipRead(e.to_string()))?;
    let mut archive =
        zip::ZipArchive::new(raw_file).map_err(|e| ArchiveError::ZipRead(e.to_string()))?;

    // 1. Identify the single wrapper folder
    let mut wrapper_prefix: Option<String> = None;
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|e| ArchiveError::ZipRead(e.to_string()))?;
        let name = entry.name().replace('\\', "/");
        if let Some(first_part) = name.split('/').next() {
            if !first_part.is_empty() {
                if let Some(ref p) = wrapper_prefix {
                    if p != first_part {
                        return Err(ArchiveError::ZipRead(
                            "Unexpected zipball shape: multiple root entries".to_string(),
                        ));
                    }
                } else {
                    wrapper_prefix = Some(first_part.to_string());
                }
            }
        }
    }

    let wrapper = wrapper_prefix.ok_or(ArchiveError::NoValidAddonFolders)?;
    let wrapper_slash = format!("{}/", wrapper);

    // 2. Check if wrapper root has its own .toc file
    let mut wrapper_has_own_toc = false;
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|e| ArchiveError::ZipRead(e.to_string()))?;
        let name = entry.name().replace('\\', "/");
        if name.starts_with(&wrapper_slash) {
            let rel = &name[wrapper_slash.len()..];
            if !rel.contains('/') && rel.to_ascii_lowercase().ends_with(".toc") {
                wrapper_has_own_toc = true;
                break;
            }
        }
    }

    // 3. Write normalized zip
    if let Some(parent) = dest_normalized_zip.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let out_file = File::create(dest_normalized_zip)?;
    let mut writer = zip::write::ZipWriter::new(out_file);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| ArchiveError::ZipRead(e.to_string()))?;
        let name = entry.name().replace('\\', "/");
        if !name.starts_with(&wrapper_slash) {
            continue;
        }
        let rel = &name[wrapper_slash.len()..];
        if rel.is_empty() {
            continue;
        }

        let new_name = if wrapper_has_own_toc {
            format!("{}/{}", clean_repo_name, rel)
        } else {
            rel.to_string()
        };

        if entry.is_dir() {
            writer
                .add_directory(&new_name, options)
                .map_err(|e| ArchiveError::Io(std::io::Error::new(std::io::ErrorKind::Other, e)))?;
        } else {
            writer
                .start_file(&new_name, options)
                .map_err(|e| ArchiveError::Io(std::io::Error::new(std::io::ErrorKind::Other, e)))?;
            let mut buf = [0u8; 64 * 1024];
            loop {
                let n = entry.read(&mut buf)?;
                if n == 0 {
                    break;
                }
                writer.write_all(&buf[..n])?;
            }
        }
    }

    writer
        .finish()
        .map_err(|e| ArchiveError::Io(std::io::Error::new(std::io::ErrorKind::Other, e)))?;
    Ok(())
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
        assert!(!is_safe_entry_name("MyAddon/evil.lua:stream"), "NTFS ADS colon must be rejected");
        assert!(!is_safe_entry_name("sub/C:/file.txt"), "Colon anywhere in path must be rejected");
        assert!(!is_safe_entry_name("MyAddon/aux.lua"), "Windows reserved name AUX must be rejected");
        assert!(!is_safe_entry_name("MyAddon/CON.toc"), "Windows reserved name CON must be rejected");
        assert!(!is_safe_entry_name("MyAddon/nul"), "Windows reserved name NUL must be rejected");
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
    fn test_tga_texture_high_ratio_allowed() {
        let temp = tempfile::tempdir().unwrap();
        let zip_path = temp.path().join("addon_with_tga.zip");
        let extract_dir = temp.path().join("extracted");

        let file = File::create(&zip_path).unwrap();
        let mut zip = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

        // 2 MB of repeating bytes in a .tga file (ratio > 1000:1) should NOT be flagged as zip bomb
        zip.start_file("MyAddon/cursor.tga", options).unwrap();
        let zeros = vec![0u8; 2 * 1024 * 1024];
        zip.write_all(&zeros).unwrap();

        zip.start_file("MyAddon/MyAddon.toc", options).unwrap();
        zip.write_all(b"## Interface: 110000").unwrap();
        zip.finish().unwrap();

        let res = extract_addon_archive(&zip_path, &extract_dir);
        assert!(res.is_ok(), "High ratio on .tga texture should be allowed, got {:?}", res.err());
        assert!(extract_dir.join("MyAddon").join("cursor.tga").exists());
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

    #[test]
    fn test_normalize_github_zipball() {
        let temp = tempfile::tempdir().unwrap();
        let raw_zip_path = temp.path().join("raw_zipball.zip");
        let norm_zip_path = temp.path().join("normalized.zip");
        let extract_dir = temp.path().join("extracted");

        // Case: Wrapper directory with root .toc file
        let file = File::create(&raw_zip_path).unwrap();
        let mut zip = ZipWriter::new(file);
        let options = SimpleFileOptions::default();
        zip.start_file("author-MyAddon-abc1234/MyAddon.toc", options).unwrap();
        zip.write_all(b"## Interface: 110000\n## Title: My Addon").unwrap();
        zip.start_file("author-MyAddon-abc1234/Core.lua", options).unwrap();
        zip.write_all(b"print('loaded')").unwrap();
        zip.finish().unwrap();

        normalize_github_zipball(&raw_zip_path, "MyAddon", &norm_zip_path).unwrap();

        let candidates = extract_addon_archive(&norm_zip_path, &extract_dir).unwrap();
        assert_eq!(candidates, vec!["MyAddon".to_string()]);
        assert!(extract_dir.join("MyAddon").join("MyAddon.toc").exists());
        assert!(extract_dir.join("MyAddon").join("Core.lua").exists());
    }
}
