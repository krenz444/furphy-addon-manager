use std::path::PathBuf;
use std::sync::Arc;
use rusqlite::Connection;
use serde_json::json;

use furphy_lib::db::schema::INITIAL_SCHEMA;
use furphy_lib::jobs::runner::JobRunner;
use furphy_lib::net::policy::NetworkPolicy;
use furphy_lib::system::game::TEST_ENV_LOCK;

struct TestGuard {
    wow_path: PathBuf,
    data_path: PathBuf,
    orig_wowroot: Option<String>,
    orig_localappdata: Option<String>,
}

impl Drop for TestGuard {
    fn drop(&mut self) {
        if let Some(ref w) = self.orig_wowroot {
            std::env::set_var("FURPHY_DEV_WOWROOT", w);
        } else {
            std::env::remove_var("FURPHY_DEV_WOWROOT");
        }
        if let Some(ref l) = self.orig_localappdata {
            std::env::set_var("LOCALAPPDATA", l);
        } else {
            std::env::remove_var("LOCALAPPDATA");
        }
        let _ = std::fs::remove_dir_all(&self.wow_path);
        let _ = std::fs::remove_dir_all(&self.data_path);
    }
}

#[tokio::test]
async fn test_e2e_github_full_lifecycle() {
    let _lock = TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let orig_wowroot = std::env::var("FURPHY_DEV_WOWROOT").ok();
    let orig_localappdata = std::env::var("LOCALAPPDATA").ok();

    // 1. Create tempdir sandbox with spaces and parentheses per ADR-307
    let temp = std::env::temp_dir().join(format!("furphy test wow (gh-{})", uuid::Uuid::new_v4()));
    let local_data = std::env::temp_dir().join(format!("furphy_gh_data_{}", uuid::Uuid::new_v4()));
    let retail_addons = temp.join("_retail_").join("Interface").join("AddOns");
    let retail_wtf = temp.join("_retail_").join("WTF");
    std::fs::create_dir_all(&retail_addons).unwrap();
    std::fs::create_dir_all(&retail_wtf).unwrap();
    std::fs::create_dir_all(&local_data).unwrap();
    std::fs::write(temp.join(".build.info"), "Product|Version\nwow|11.0.2.56819\n").unwrap();

    std::env::set_var("FURPHY_DEV_WOWROOT", temp.to_str().unwrap());
    std::env::set_var("LOCALAPPDATA", local_data.to_str().unwrap());
    let _cleanup = TestGuard {
        wow_path: temp.clone(),
        data_path: local_data.clone(),
        orig_wowroot,
        orig_localappdata,
    };

    // 2. Create in-memory DB with INITIAL_SCHEMA and retail flavour
    let mut conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(INITIAL_SCHEMA).unwrap();

    conn.execute(
        "INSERT INTO flavours (id, folder, label, installed, client_build, client_interface) \
         VALUES ('retail', '_retail_', 'Retail', 1, '11.0.2', '110002')",
        [],
    ).unwrap();

    // If local environment has a GitHub token, supply it to prevent rate limiting
    if let Ok(tok) = std::env::var("GITHUB_TOKEN").or_else(|_| std::env::var("GH_TOKEN")) {
        if !tok.trim().is_empty() {
            let _ = conn.execute(
                "INSERT OR REPLACE INTO settings (key, value) VALUES ('githubToken', ?1)",
                rusqlite::params![serde_json::to_string(&tok).unwrap()],
            );
        }
    }

    // 3. Instantiate JobRunner
    let policy = Arc::new(NetworkPolicy::new());
    let runner = JobRunner::new(policy.clone());

    // 4. Query GitHub releases for bart-dev-wow/AuraUpdater or a public addon repo
    let gh_client = furphy_lib::net::github::create_github_client().unwrap();
    let (target_repo, releases) = match furphy_lib::net::github::get_github_releases(
        &policy,
        &gh_client,
        "bart-dev-wow",
        "AuraUpdater",
        None,
    )
    .await
    {
        Ok(rels) if !rels.is_empty() => ("bart-dev-wow/AuraUpdater", rels),
        _ => {
            // Fallback to public addon repository on GitHub
            let rels = furphy_lib::net::github::get_github_releases(
                &policy,
                &gh_client,
                "BigWigsMods",
                "BigWigs",
                None,
            )
            .await
            .expect("Failed to query public GitHub releases for BigWigsMods/BigWigs");
            ("BigWigsMods/BigWigs", rels)
        }
    };
    assert!(!releases.is_empty(), "GitHub releases should contain at least one release");

    // 5. Run install/add job with chosen repo
    let res = runner.run_job(
        &mut conn,
        "add",
        Some("retail"),
        json!({ "target": target_repo, "repo": target_repo }),
    ).await;

    // 6. Verify job succeeds, downloaded, root normalized, folder extracted
    assert!(res.is_ok(), "GitHub add job failed: {:?}", res);
    let record = res.unwrap();
    assert_eq!(record.state, "completed");
    assert!(record.error.is_none(), "Job reported error: {:?}", record.error);

    let parts: Vec<&str> = target_repo.split('/').collect();
    let repo_name = parts[1];
    let addon_dir = retail_addons.join(repo_name);
    assert!(addon_dir.is_dir(), "Addon directory '{}' must exist at {:?}", repo_name, addon_dir);
    let addon_toc = addon_dir.join(format!("{}.toc", repo_name));
    assert!(addon_toc.is_file(), "Primary .toc must exist on disk at {:?}", addon_toc);

    // 7. Verify DB recorded source 'github' and 'repo'
    let (aid, db_source, db_repo, db_ver, inst_at): (String, String, String, Option<String>, Option<String>) = conn.query_row(
        "SELECT id, source, repo, version, installed_at FROM addons WHERE flavour = 'retail' AND repo = ?1",
        [target_repo],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
    ).expect("Addon record for repository must exist in DB");

    assert_eq!(db_source, "github");
    assert_eq!(db_repo, target_repo);
    assert!(db_ver.is_some() && !db_ver.as_ref().unwrap().is_empty(), "version must be recorded");
    assert!(inst_at.is_some() && !inst_at.as_ref().unwrap().is_empty(), "installed_at must be recorded");

    // Verify addon_folders tracks the folder
    let folders: Vec<String> = {
        let mut stmt = conn.prepare("SELECT folder FROM addon_folders WHERE addon_id = ?1").unwrap();
        stmt.query_map([&aid], |r| r.get(0)).unwrap().flatten().collect()
    };
    assert!(folders.iter().any(|f| f.eq_ignore_ascii_case(repo_name)), "addon_folders must track {}", repo_name);

    // 8. Run remove job, verify disk cleanup and DB deletion
    let rem_res = runner.run_job(
        &mut conn,
        "remove",
        Some("retail"),
        json!({ "addon_id": aid }),
    ).await;
    assert!(rem_res.is_ok(), "remove job failed: {:?}", rem_res);

    assert!(!addon_dir.exists(), "Addon directory should be removed from disk");

    let count_addons: i64 = conn.query_row(
        "SELECT COUNT(*) FROM addons WHERE id = ?1",
        [&aid],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(count_addons, 0, "addons record should be purged from DB");

    let count_folders: i64 = conn.query_row(
        "SELECT COUNT(*) FROM addon_folders WHERE addon_id = ?1",
        [&aid],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(count_folders, 0, "addon_folders records should be purged from DB");

    // 9. Teardown via TestGuard Drop
}
