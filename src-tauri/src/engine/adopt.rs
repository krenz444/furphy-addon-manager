use chrono::Utc;
use rusqlite::{params, Connection, Result};
use uuid::Uuid;
use crate::engine::scan::ScannedCandidateGroup;
use crate::logging::append_app_log;

pub fn adopt_candidate_group(
    conn: &mut Connection,
    flavour: &str,
    candidate: &ScannedCandidateGroup,
) -> Result<String> {
    let tx = conn.transaction()?;
    let addon_id = Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    tx.execute(
        "INSERT INTO addons (id, flavour, source, project_id, wago_id, name, author, version, installed_at, adopted, release_type, ignore_updates) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 1, 1, 0)",
        params![
            addon_id,
            flavour,
            candidate.source,
            candidate.project_id,
            candidate.wago_id,
            candidate.name,
            candidate.author,
            candidate.version,
            now
        ],
    )?;

    for folder in &candidate.folders {
        tx.execute(
            "INSERT INTO addon_folders (flavour, folder, addon_id) VALUES (?1, ?2, ?3)",
            params![flavour, folder, addon_id],
        )?;
    }

    tx.commit()?;

    append_app_log(
        "INFO",
        &format!(
            "Adopted addon '{}' ({}) with folders {:?}",
            candidate.name, addon_id, candidate.folders
        ),
    );

    Ok(addon_id)
}
