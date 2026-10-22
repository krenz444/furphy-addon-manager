pub mod export_v1;
pub mod import_v1;
pub mod migrate;
pub mod repo;
pub mod schema;

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::{Path, PathBuf};
    use rusqlite::Connection;
    use serde_json::{json, Value};

    fn compute_dir_fingerprint(dir: &Path) -> Vec<(String, u64)> {
        let mut entries = Vec::new();
        if let Ok(rd) = fs::read_dir(dir) {
            for entry in rd.flatten() {
                let path = entry.path();
                let rel = path.strip_prefix(dir).unwrap().to_string_lossy().to_string();
                if path.is_file() {
                    let len = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
                    entries.push((rel, len));
                } else if path.is_dir() {
                    for (sub_rel, sub_len) in compute_dir_fingerprint(&path) {
                        entries.push((format!("{}/{}", rel, sub_rel), sub_len));
                    }
                }
            }
        }
        entries.sort();
        entries
    }

    #[test]
    fn test_ownership_guard_enforced_by_schema() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate::run_migrations(&mut conn).unwrap();

        let temp_dir = std::env::temp_dir().join(format!("furphy_test_ownership_{}", uuid::Uuid::new_v4()));
        let v1_dir = temp_dir.join("v1");
        let retail_dir = v1_dir.join("flavours").join("retail");
        fs::create_dir_all(&retail_dir).unwrap();

        let v2_data_dir = temp_dir.join("v2_data");
        fs::create_dir_all(&v2_data_dir).unwrap();

        // Two records in retail claiming the same folder "Details"
        let addons_json = json!([
            {
                "name": "Details! Damage Meter",
                "projectId": 61284,
                "folders": ["Details", "Details_DataStorage"],
                "source": "curseforge"
            },
            {
                "name": "Details Rogue Clone",
                "projectId": 99999,
                "folders": ["Details"],
                "source": "curseforge"
            }
        ]);

        fs::write(retail_dir.join("addons.json"), addons_json.to_string()).unwrap();

        let result = import_v1::import_from_v1(&mut conn, &v1_dir, &v2_data_dir, false);
        assert!(result.is_err(), "Import must fail on conflicting folder ownership");
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("Folder ownership conflict"), "Error should be FolderOwnershipConflict: {}", err_msg);
        assert!(err_msg.contains("Details"), "Error should identify conflicting folder: {}", err_msg);

        // Verify that transaction rolled back: 0 addons in database
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM addons", [], |r| r.get(0)).unwrap();
        assert_eq!(count, 0, "Transaction should roll back completely on ownership conflict");

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_v1_import_and_export_round_trip_with_immutability() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate::run_migrations(&mut conn).unwrap();

        let temp_dir = std::env::temp_dir().join(format!("furphy_test_roundtrip_{}", uuid::Uuid::new_v4()));
        let v1_dir = temp_dir.join("v1");
        let retail_dir = v1_dir.join("flavours").join("retail");
        let backups_dir = retail_dir.join("backups").join("2382");
        fs::create_dir_all(&backups_dir).unwrap();

        let v2_data_dir = temp_dir.join("v2_data");
        fs::create_dir_all(&v2_data_dir).unwrap();

        fs::write(v1_dir.join("VERSION"), "1.27.1\n").unwrap();

        // Synthetic settings.json with legacy keys and out-of-clamp values
        let original_settings = json!({
            "releaseType": 1,
            "port": 47831,
            "adFilter": true,
            "cfFocus": true,
            "hostWindow": { "x": 100, "y": 200, "w": 1200, "h": 800 },
            "hostTheme": { "name": "tokyo-rain", "colors": { "bg0": "#101018" } },
            "backgroundUpdates": true,
            "backgroundIntervalMinutes": 20, // should clamp to 30
            "runAtStartup": false,
            "appUpdateAutoInstall": true,
            "schemaVersion": 2,
            "activeFlavour": "retail",
            "showTestRealms": false,
            "githubToken": "ghp_test_token_never_logged",
            "cfApiKey": "legacy_key_to_drop",
            "autoUpdateOnLaunch": true
        });
        fs::write(v1_dir.join("settings.json"), serde_json::to_string_pretty(&original_settings).unwrap()).unwrap();

        // Synthetic addons.json with CurseForge, Wago, GitHub, and extra fields
        let original_addons = json!([
            {
                "name": "BigWigs",
                "projectId": 2382,
                "fileId": 9279720,
                "version": "v427.7",
                "fileName": "BigWigs-v427.7.zip",
                "installedAt": "2026-10-22T20:48:56Z",
                "folders": ["BigWigs", "BigWigs_Core", "BigWigs_Options"],
                "author": "funkehdude",
                "ignoreUpdates": false,
                "pinnedFileId": null,
                "releaseType": null,
                "previousFileId": 9182840,
                "previousVersion": "v427.6",
                "previousFileName": "BigWigs-v427.6.zip",
                "requiredDeps": [],
                "optionalDeps": ["Ace3", "LibCandyBar-3.0"],
                "source": "curseforge",
                "wagoId": "5NRegwG3",
                "slug": null,
                "curseId": "2382",
                "latestGameVersions": ["12.1.0", "12.1.5"],
                "latestFileDate": "2026-10-21T17:51:32.993Z",
                "adopted": false,
                "adoptedAt": null,
                "repo": null,
                "installedTag": null,
                "assetName": null,
                "githubRateLimitedUntil": null
            },
            {
                "name": "Wago Addon",
                "projectId": null,
                "fileId": 12345,
                "version": "1.0.0",
                "fileName": "WagoAddon.zip",
                "installedAt": "2026-10-20T10:00:00Z",
                "folders": ["WagoFolder"],
                "author": "wago_author",
                "ignoreUpdates": true,
                "pinnedFileId": 12345,
                "releaseType": 1,
                "previousFileId": null,
                "previousVersion": null,
                "requiredDeps": ["BigWigs"],
                "source": "wago",
                "wagoId": "wago_xyz",
                "slug": "wago-slug",
                "curseId": null,
                "latestGameVersions": ["12.1.0"],
                "adopted": false,
                "repo": null,
                "installedTag": null,
                "assetName": null,
                "githubRateLimitedUntil": null
            }
        ]);
        fs::write(retail_dir.join("addons.json"), serde_json::to_string_pretty(&original_addons).unwrap()).unwrap();

        // Backup zip
        fs::write(backups_dir.join("9279720.zip"), b"fake_zip_bytes").unwrap();

        // Fingerprint v1 directory before import
        let fp_before = compute_dir_fingerprint(&v1_dir);

        // Run import
        let summary = import_v1::import_from_v1(&mut conn, &v1_dir, &v2_data_dir, false).unwrap();
        assert_eq!(summary.addons_imported, 2);
        assert_eq!(summary.flavours_imported, 1);
        assert_eq!(summary.backups_copied, 1);

        // Immutability check: v1 folder tree hash / fingerprint must be completely unchanged
        let fp_after = compute_dir_fingerprint(&v1_dir);
        assert_eq!(fp_before, fp_after, "v1 directory must be completely untouched after import!");

        // Verify second run is a no-op
        let second_summary = import_v1::import_from_v1(&mut conn, &v1_dir, &v2_data_dir, false).unwrap();
        assert!(second_summary.already_imported, "Subsequent import should be a no-op");

        // Verify legacy keys dropped
        let has_legacy_api_key: bool = conn
            .query_row("SELECT COUNT(*) > 0 FROM settings WHERE key = 'cfApiKey'", [], |r| r.get(0))
            .unwrap();
        assert!(!has_legacy_api_key, "cfApiKey must be dropped");

        let has_legacy_autoupdate: bool = conn
            .query_row("SELECT COUNT(*) > 0 FROM settings WHERE key = 'autoUpdateOnLaunch'", [], |r| r.get(0))
            .unwrap();
        assert!(!has_legacy_autoupdate, "autoUpdateOnLaunch must be dropped");

        // Verify clamp re-applied
        let interval: String = conn
            .query_row("SELECT value FROM settings WHERE key = 'backgroundIntervalMinutes'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(interval, "30", "backgroundIntervalMinutes should be clamped to 30");

        // Verify theme mapped to ui_prefs
        let theme: String = conn
            .query_row("SELECT value FROM ui_prefs WHERE key = 'theme'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(theme, "tokyo-rain", "hostTheme should be mapped to ui_prefs 'theme'");

        // Verify backup copied to v2_data_dir
        let copied_backup = v2_data_dir.join("backups").join("retail").join("2382").join("9279720.zip");
        assert!(copied_backup.exists(), "Backup zip should be copied to v2 data dir");
        assert_eq!(fs::read(&copied_backup).unwrap(), b"fake_zip_bytes");

        // Export back to a new directory
        let export_dir = temp_dir.join("v1_exported");
        export_v1::export_to_v1(&conn, &export_dir).unwrap();

        // Verify exported addons.json matches original
        let exported_addons_path = export_dir.join("flavours").join("retail").join("addons.json");
        assert!(exported_addons_path.exists());

        let exported_addons_val: Value = serde_json::from_str(&fs::read_to_string(&exported_addons_path).unwrap()).unwrap();
        let original_addons_val: Value = serde_json::from_str(&fs::read_to_string(retail_dir.join("addons.json")).unwrap()).unwrap();

        assert_eq!(exported_addons_val.as_array().unwrap().len(), original_addons_val.as_array().unwrap().len());

        let orig_rec1 = &original_addons_val[0];
        let exp_rec1 = &exported_addons_val[0];

        // Check each critical field
        assert_eq!(exp_rec1["name"], orig_rec1["name"]);
        assert_eq!(exp_rec1["projectId"], orig_rec1["projectId"]);
        assert_eq!(exp_rec1["fileId"], orig_rec1["fileId"]);
        assert_eq!(exp_rec1["version"], orig_rec1["version"]);
        assert_eq!(exp_rec1["folders"], orig_rec1["folders"]);
        assert_eq!(exp_rec1["optionalDeps"], orig_rec1["optionalDeps"]);
        assert_eq!(exp_rec1["previousFileName"], orig_rec1["previousFileName"]);
        assert_eq!(exp_rec1["latestGameVersions"], orig_rec1["latestGameVersions"]);

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_import_schema_version_1_layout() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate::run_migrations(&mut conn).unwrap();

        let temp_dir = std::env::temp_dir().join(format!("furphy_test_schema1_{}", uuid::Uuid::new_v4()));
        let v1_dir = temp_dir.join("v1");
        fs::create_dir_all(&v1_dir).unwrap();

        let v2_data_dir = temp_dir.join("v2_data");
        fs::create_dir_all(&v2_data_dir).unwrap();

        // Schema version 1: top-level addons.json and backups
        let settings_v1 = json!({
            "schemaVersion": 1,
            "port": 47831,
            "releaseType": 1
        });
        fs::write(v1_dir.join("settings.json"), settings_v1.to_string()).unwrap();

        let addons_v1 = json!([
            {
                "name": "Legacy Addon",
                "projectId": 123,
                "folders": ["LegacyAddonFolder"],
                "source": "curseforge"
            }
        ]);
        fs::write(v1_dir.join("addons.json"), addons_v1.to_string()).unwrap();

        let top_backup = v1_dir.join("backups").join("123");
        fs::create_dir_all(&top_backup).unwrap();
        fs::write(top_backup.join("111.zip"), b"backup").unwrap();

        let summary = import_v1::import_from_v1(&mut conn, &v1_dir, &v2_data_dir, false).unwrap();
        assert_eq!(summary.addons_imported, 1);
        assert_eq!(summary.backups_copied, 1);

        // Verify it landed under retail
        let flavour: String = conn.query_row("SELECT flavour FROM addons WHERE project_id = 123", [], |r| r.get(0)).unwrap();
        assert_eq!(flavour, "retail");

        let _ = fs::remove_dir_all(&temp_dir);
    }

    fn copy_dir_all(src: &Path, dst: &Path) -> std::io::Result<()> {
        fs::create_dir_all(dst)?;
        for entry in fs::read_dir(src)? {
            let entry = entry?;
            let ty = entry.file_type()?;
            let file_name = entry.file_name();
            let name_str = file_name.to_string_lossy();
            // Skip actively locked log files from live running v1 server
            if name_str.ends_with(".log") || name_str.contains(".log.") {
                continue;
            }
            let dst_path = dst.join(&file_name);
            if ty.is_dir() {
                copy_dir_all(&entry.path(), &dst_path)?;
            } else {
                let _ = fs::copy(entry.path(), &dst_path);
            }
        }
        Ok(())
    }

    #[test]
    fn test_live_pc_data_roundtrip_and_immutability() {
        let live_sync_dir = PathBuf::from(r"C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync");
        if !live_sync_dir.exists() {
            println!("Skipping live data test: live AddonSync folder not found on this machine.");
            return;
        }

        let temp_dir = std::env::temp_dir().join(format!("furphy_test_live_{}", uuid::Uuid::new_v4()));
        let live_copy = temp_dir.join("live_copy");
        copy_dir_all(&live_sync_dir, &live_copy).expect("Failed to copy live AddonSync folder to temp");

        let v2_data_dir = temp_dir.join("v2_data");
        fs::create_dir_all(&v2_data_dir).unwrap();

        let mut conn = Connection::open_in_memory().unwrap();
        migrate::run_migrations(&mut conn).unwrap();

        let fp_before = compute_dir_fingerprint(&live_copy);

        let summary = import_v1::import_from_v1(&mut conn, &live_copy, &v2_data_dir, false).unwrap();
        assert!(summary.addons_imported > 0, "Live data should have imported addons");
        assert_eq!(summary.flavours_imported, 1);

        // Immutability: source folder is completely untouched
        let fp_after = compute_dir_fingerprint(&live_copy);
        assert_eq!(fp_before, fp_after, "Live copy folder was mutated by import!");

        // Export to new directory
        let export_dir = temp_dir.join("exported");
        export_v1::export_to_v1(&conn, &export_dir).unwrap();

        // Compare retail addons.json
        let orig_path = live_copy.join("flavours").join("retail").join("addons.json");
        let exp_path = export_dir.join("flavours").join("retail").join("addons.json");
        assert!(exp_path.exists(), "Exported retail addons.json must exist");

        let orig_val: Value = serde_json::from_str(&fs::read_to_string(&orig_path).unwrap()).unwrap();
        let exp_val: Value = serde_json::from_str(&fs::read_to_string(&exp_path).unwrap()).unwrap();

        let orig_arr = orig_val.as_array().expect("Original must be JSON array");
        let exp_arr = exp_val.as_array().expect("Exported must be JSON array");

        assert_eq!(orig_arr.len(), exp_arr.len(), "Addon count must match exactly");

        for i in 0..orig_arr.len() {
            let orig = &orig_arr[i];
            let exp = &exp_arr[i];

            if let (Value::Object(orig_map), Value::Object(exp_map)) = (orig, exp) {
                for (k, orig_v) in orig_map {
                    let exp_v = exp_map.get(k).unwrap_or_else(|| panic!("Missing key '{}' in exported addon #{}", k, i));
                    assert_eq!(orig_v, exp_v, "Field '{}' mismatch in addon #{}: orig={:?}, exp={:?}", k, i, orig_v, exp_v);
                }
            }
        }

        // Verify freshness state matches pending update in live state.json
        let freshness_state: String = conn
            .query_row("SELECT state FROM freshness WHERE flavour = 'retail'", [], |r| r.get(0))
            .unwrap();
        let live_state_path = live_copy.join("state.json");
        let expected_freshness = if live_state_path.exists() {
            let s: Value = serde_json::from_str(&fs::read_to_string(&live_state_path).unwrap()).unwrap();
            let has_updates = s.get("updateAvailable")
                .and_then(|u| u.get("retail"))
                .and_then(|r| r.as_object())
                .map_or(false, |m| !m.is_empty());
            if has_updates { "updates_available" } else { "up_to_date" }
        } else {
            "unknown"
        };
        assert_eq!(freshness_state, expected_freshness, "Retail freshness should reflect state.json");

        // Verify Wago backups are properly linked to addons (not null addon_id)
        let exboss_backup_aid: Option<String> = conn
            .query_row("SELECT addon_id FROM backups WHERE path LIKE '%wago-exboss%' LIMIT 1", [], |r| r.get(0))
            .unwrap();
        assert!(exboss_backup_aid.is_some(), "Wago exboss backup must have linked addon_id");
        assert_eq!(exboss_backup_aid.unwrap(), "retail:wago:vNAgrRKo");

        let talent_backup_aid: Option<String> = conn
            .query_row("SELECT addon_id FROM backups WHERE path LIKE '%wago-talentloadoutex%' LIMIT 1", [], |r| r.get(0))
            .unwrap();
        assert!(talent_backup_aid.is_some(), "Wago talentloadoutex backup must have linked addon_id");
        assert_eq!(talent_backup_aid.unwrap(), "retail:wago:Qb6mxnNP");

        // Verify zero unlinked backups
        let orphaned_backups: i64 = conn
            .query_row("SELECT COUNT(*) FROM backups WHERE addon_id IS NULL", [], |r| r.get(0))
            .unwrap();
        assert_eq!(orphaned_backups, 0, "All 34 live backups must be linked to valid addon_id");

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_ownership_guard_case_insensitive() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate::run_migrations(&mut conn).unwrap();

        let temp_dir = std::env::temp_dir().join(format!("furphy_test_ci_{}", uuid::Uuid::new_v4()));
        let retail_dir = temp_dir.join("flavours").join("retail");
        fs::create_dir_all(&retail_dir).unwrap();

        let addons_json = json!([
            {
                "name": "Addon 1",
                "projectId": 1001,
                "folders": ["Details"],
                "source": "curseforge"
            },
            {
                "name": "Addon 2",
                "projectId": 1002,
                "folders": ["details"],
                "source": "curseforge"
            }
        ]);
        fs::write(retail_dir.join("addons.json"), addons_json.to_string()).unwrap();

        let result = import_v1::import_from_v1(&mut conn, &temp_dir, &temp_dir.join("v2"), false);
        assert!(result.is_err(), "Must reject case-insensitive folder collision");
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("details") || err_msg.contains("Details"));

        let count: i64 = conn.query_row("SELECT COUNT(*) FROM addons", [], |r| r.get(0)).unwrap();
        assert_eq!(count, 0, "Transaction should roll back completely");

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_import_with_utf8_bom() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate::run_migrations(&mut conn).unwrap();

        let temp_dir = std::env::temp_dir().join(format!("furphy_test_bom_{}", uuid::Uuid::new_v4()));
        let retail_dir = temp_dir.join("flavours").join("retail");
        fs::create_dir_all(&retail_dir).unwrap();

        // Write files with UTF-8 BOM prefix
        let bom_settings = format!("\u{feff}{}", json!({"schemaVersion": 2, "releaseType": 1}));
        fs::write(temp_dir.join("settings.json"), bom_settings).unwrap();

        let bom_addons = format!("\u{feff}{}", json!([
            {
                "name": "BOM Addon",
                "projectId": 5555,
                "folders": ["BomFolder"],
                "source": "curseforge"
            }
        ]));
        fs::write(retail_dir.join("addons.json"), bom_addons).unwrap();

        let summary = import_v1::import_from_v1(&mut conn, &temp_dir, &temp_dir.join("v2"), false).unwrap();
        assert_eq!(summary.addons_imported, 1);

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_import_stringified_numeric_ids() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate::run_migrations(&mut conn).unwrap();

        let temp_dir = std::env::temp_dir().join(format!("furphy_test_strids_{}", uuid::Uuid::new_v4()));
        let retail_dir = temp_dir.join("flavours").join("retail");
        fs::create_dir_all(&retail_dir).unwrap();

        let addons_json = json!([
            {
                "name": "String IDs Addon",
                "projectId": "77777",
                "fileId": "88888",
                "folders": ["StrFolder"],
                "source": "curseforge"
            }
        ]);
        fs::write(retail_dir.join("addons.json"), addons_json.to_string()).unwrap();

        let summary = import_v1::import_from_v1(&mut conn, &temp_dir, &temp_dir.join("v2"), false).unwrap();
        assert_eq!(summary.addons_imported, 1);

        let pid: i64 = conn.query_row("SELECT project_id FROM addons WHERE id = 'retail:cf:77777'", [], |r| r.get(0)).unwrap();
        let fid: String = conn.query_row("SELECT file_id FROM addons WHERE id = 'retail:cf:77777'", [], |r| r.get(0)).unwrap();
        assert_eq!(pid, 77777);
        assert_eq!(fid, "88888");

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_self_duplicate_folders_within_addon() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate::run_migrations(&mut conn).unwrap();

        let temp_dir = std::env::temp_dir().join(format!("furphy_test_selfdup_{}", uuid::Uuid::new_v4()));
        let retail_dir = temp_dir.join("flavours").join("retail");
        fs::create_dir_all(&retail_dir).unwrap();

        let addons_json = json!([
            {
                "name": "Self Duplicate Addon",
                "projectId": 33333,
                "folders": ["DupFolder", "dupfolder", "DupFolder"],
                "source": "curseforge"
            }
        ]);
        fs::write(retail_dir.join("addons.json"), addons_json.to_string()).unwrap();

        let summary = import_v1::import_from_v1(&mut conn, &temp_dir, &temp_dir.join("v2"), false).unwrap();
        assert_eq!(summary.addons_imported, 1);

        let folder_count: i64 = conn.query_row("SELECT COUNT(*) FROM addon_folders WHERE addon_id = 'retail:cf:33333'", [], |r| r.get(0)).unwrap();
        assert_eq!(folder_count, 1, "Folders should be deduplicated within the addon");

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_corrupt_json_aborts_transaction() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate::run_migrations(&mut conn).unwrap();

        let temp_dir = std::env::temp_dir().join(format!("furphy_test_corrupt_{}", uuid::Uuid::new_v4()));
        let retail_dir = temp_dir.join("flavours").join("retail");
        fs::create_dir_all(&retail_dir).unwrap();

        fs::write(retail_dir.join("addons.json"), "{ invalid json [").unwrap();

        let res = import_v1::import_from_v1(&mut conn, &temp_dir, &temp_dir.join("v2"), false);
        assert!(res.is_err());

        let count: i64 = conn.query_row("SELECT COUNT(*) FROM addons", [], |r| r.get(0)).unwrap();
        assert_eq!(count, 0, "No records should be left in database");

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_wago_and_github_backup_keys_matched_to_addon_id() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate::run_migrations(&mut conn).unwrap();

        let temp_dir = std::env::temp_dir().join(format!("furphy_test_backups_{}", uuid::Uuid::new_v4()));
        let retail_dir = temp_dir.join("flavours").join("retail");
        fs::create_dir_all(&retail_dir).unwrap();

        let addons_json = json!([
            {
                "name": "ExBoss",
                "source": "wago",
                "wagoId": "vNAgrRKo",
                "slug": "exboss",
                "folders": ["EXBoss"]
            },
            {
                "name": "AuraUpdater",
                "source": "github",
                "repo": "bart-dev-wow/AuraUpdater",
                "folders": ["AuraUpdater"]
            }
        ]);
        fs::write(retail_dir.join("addons.json"), addons_json.to_string()).unwrap();

        // Create backup folders following v1 Get-RecordBackupKey format
        let wago_backup = retail_dir.join("backups").join("wago-exboss");
        let gh_backup = retail_dir.join("backups").join("github-bart-dev-wow_AuraUpdater");
        fs::create_dir_all(&wago_backup).unwrap();
        fs::create_dir_all(&gh_backup).unwrap();

        fs::write(wago_backup.join("rQPkLnB6.zip"), b"wago_zip").unwrap();
        fs::write(gh_backup.join("v1.0.0.zip"), b"gh_zip").unwrap();

        let v2_data_dir = temp_dir.join("v2");
        let summary = import_v1::import_from_v1(&mut conn, &temp_dir, &v2_data_dir, false).unwrap();
        assert_eq!(summary.addons_imported, 2);
        assert_eq!(summary.backups_copied, 2);

        // Verify Wago backup is linked to Wago addon ID
        let wago_aid: Option<String> = conn
            .query_row("SELECT addon_id FROM backups WHERE path LIKE '%wago-exboss%'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(wago_aid, Some("retail:wago:vNAgrRKo".into()));

        // Verify GitHub backup is linked to GitHub addon ID
        let gh_aid: Option<String> = conn
            .query_row("SELECT addon_id FROM backups WHERE path LIKE '%AuraUpdater%'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(gh_aid, Some("retail:gh:bart-dev-wow/AuraUpdater".into()));

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_state_json_wago_and_github_updates_and_freshness_state() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate::run_migrations(&mut conn).unwrap();

        let temp_dir = std::env::temp_dir().join(format!("furphy_test_state_{}", uuid::Uuid::new_v4()));
        let retail_dir = temp_dir.join("flavours").join("retail");
        fs::create_dir_all(&retail_dir).unwrap();

        let addons_json = json!([
            {
                "name": "ExBoss",
                "source": "wago",
                "wagoId": "vNAgrRKo",
                "slug": "exboss",
                "folders": ["EXBoss"]
            },
            {
                "name": "AuraUpdater",
                "source": "github",
                "repo": "bart-dev-wow/AuraUpdater",
                "folders": ["AuraUpdater"]
            }
        ]);
        fs::write(retail_dir.join("addons.json"), addons_json.to_string()).unwrap();

        // state.json with Wago alphanumeric string fileId and GitHub update key
        let state_json = json!({
            "updatesCheckedAt": {
                "retail": "2026-10-22T21:44:24Z"
            },
            "updateAvailable": {
                "retail": {
                    "wago:exboss": {
                        "fileId": "rQPkLnB6",
                        "version": "v2.1"
                    },
                    "github:bart-dev-wow/auraupdater": {
                        "fileId": "v1.2.0",
                        "version": "v1.2.0"
                    }
                }
            }
        });
        fs::write(temp_dir.join("state.json"), state_json.to_string()).unwrap();

        let v2_data_dir = temp_dir.join("v2");
        let summary = import_v1::import_from_v1(&mut conn, &temp_dir, &v2_data_dir, false).unwrap();
        assert_eq!(summary.addons_imported, 2);

        // Verify freshness is "updates_available" because updates exist
        let freshness_state: String = conn
            .query_row("SELECT state FROM freshness WHERE flavour = 'retail'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(freshness_state, "updates_available");

        // Verify Wago update check_results record has string update_file_id
        let (wago_fid, wago_ver): (String, String) = conn
            .query_row(
                "SELECT update_file_id, update_version FROM check_results WHERE addon_id = 'retail:wago:vNAgrRKo'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(wago_fid, "rQPkLnB6");
        assert_eq!(wago_ver, "v2.1");

        // Verify GitHub update check_results record
        let (gh_fid, gh_ver): (String, String) = conn
            .query_row(
                "SELECT update_file_id, update_version FROM check_results WHERE addon_id = 'retail:gh:bart-dev-wow/AuraUpdater'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(gh_fid, "v1.2.0");
        assert_eq!(gh_ver, "v1.2.0");

        let _ = fs::remove_dir_all(&temp_dir);
    }
}

