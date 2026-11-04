use std::path::{Path, PathBuf};
use rusqlite::{params, Connection};
use crate::engine::archive::extract_addon_archive;
use crate::engine::ownership::get_protected_folders;
use crate::engine::staging::{create_unique_staging_subfolder, prepare_flavour_staging_dir};
use crate::engine::swap::{execute_atomic_swap, remove_dir_all_safe};
use crate::logging::append_app_log;

pub fn rollback_addon(
    conn: &Connection,
    wow_root: &Path,
    flavour_folder: &str,
    addon_id: &str,
    flavour: &str,
    addons_path: &Path,
    data_dir: &Path,
) -> Result<(), String> {
    // 1. Fetch latest backup for this addon
    let (_backup_id, file_id, version, path_str): (String, Option<String>, Option<String>, String) = conn
        .query_row(
            "SELECT id, file_id, version, path FROM backups WHERE addon_id = ?1 ORDER BY created_at DESC LIMIT 1",
            params![addon_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .map_err(|e| format!("No rollback backup available for addon {}: {}", addon_id, e))?;

    let backup_path = PathBuf::from(&path_str);
    if !backup_path.exists() {
        return Err(format!("Backup zip file missing from disk: {}", path_str));
    }

    // 2. Fetch current folders scoped to this flavour
    let mut stmt = conn
        .prepare("SELECT folder FROM addon_folders WHERE addon_id = ?1 AND flavour = ?2")
        .map_err(|e| e.to_string())?;
    let frows = stmt
        .query_map(params![addon_id, flavour], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?;
    let previous_folders: Vec<String> = frows.flatten().collect();

    // 3. Staging and extract to unique isolated subfolder
    let staging_dir = prepare_flavour_staging_dir(data_dir, flavour).map_err(|e| e.to_string())?;
    let extract_dir = create_unique_staging_subfolder(&staging_dir, &format!("rollback_{}", addon_id))
        .map_err(|e| e.to_string())?;
    let candidate_folders = match extract_addon_archive(&backup_path, &extract_dir) {
        Ok(c) => c,
        Err(e) => {
            let _ = remove_dir_all_safe(&extract_dir);
            return Err(e.to_string());
        }
    };

    // 4. WTF snapshot before swap (ADR-314)
    let _ = crate::engine::wtf::take_wtf_snapshot(
        conn,
        wow_root,
        flavour_folder,
        addon_id,
        &previous_folders,
        data_dir,
        "pre-update",
    );

    // 5. Atomic swap with locked-file handling & transactional rollback
    let protected = get_protected_folders(conn, flavour, Some(addon_id)).map_err(|e| e.to_string())?;
    let installed_folders = match execute_atomic_swap(
        addons_path,
        &extract_dir,
        &candidate_folders,
        &previous_folders,
        &protected,
    ) {
        Ok(f) => {
            let _ = remove_dir_all_safe(&extract_dir);
            f
        }
        Err(err) => {
            let _ = remove_dir_all_safe(&extract_dir);
            return Err(err);
        }
    };

    // 6. Update DB: set version, file_id, and pin to file_id (or version)
    let pin_target = file_id.clone().or_else(|| version.clone()).unwrap_or_default();
    conn.execute(
        "UPDATE addons SET file_id = ?1, version = ?2, pinned_file_id = ?3 WHERE id = ?4",
        params![file_id, version, pin_target, addon_id],
    )
    .map_err(|e| e.to_string())?;

    // Update addon_folders scoped strictly to this flavour
    let _ = conn.execute(
        "DELETE FROM addon_folders WHERE addon_id = ?1 AND flavour = ?2",
        params![addon_id, flavour],
    );
    for f in &installed_folders {
        let _ = conn.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES (?1, ?2, ?3)",
            params![flavour, f, addon_id],
        );
    }

    append_app_log(
        "INFO",
        &format!(
            "Rolled back addon {} to file {:?} version {:?} (pinned)",
            addon_id, file_id, version
        ),
    );

    Ok(())
}
