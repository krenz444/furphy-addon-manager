use rusqlite::{params, Connection, OptionalExtension};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopyPlanItem {
    pub addon_id: String,
    pub name: String,
    pub add_target: Option<String>,
    pub skip_reason: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct CopyItemResult {
    pub addon_id: String,
    pub name: String,
    pub status: String,
    pub message: String,
}

struct SourceRow {
    id: String,
    name: String,
    source: Option<String>,
    project_id: Option<i64>,
    wago_slug: Option<String>,
    repo: Option<String>,
    tukui_slug: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Provider {
    CurseForge(i64),
    Wago(String),
    GitHub(String),
    Tukui(String),
}

fn non_empty(value: &Option<String>) -> Option<String> {
    value.as_ref().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

/// The provider an addon is kept up to date from. The `source` column decides; when it says nothing usable
/// (an adopted or older row) the first identity that exists is used.
fn provider_of(row: &SourceRow) -> Option<Provider> {
    let curseforge = row.project_id.filter(|id| *id > 0).map(Provider::CurseForge);
    let wago = non_empty(&row.wago_slug).map(Provider::Wago);
    let github = non_empty(&row.repo).map(Provider::GitHub);
    let tukui = non_empty(&row.tukui_slug).map(Provider::Tukui);
    match row.source.as_deref().map(|s| s.to_ascii_lowercase()).as_deref() {
        Some("curseforge") => curseforge,
        Some("wago") => wago,
        Some("github") => github,
        Some("tukui") => tukui,
        _ => curseforge.or(wago).or(github).or(tukui),
    }
}

fn add_target_for(provider: &Provider) -> String {
    match provider {
        Provider::CurseForge(id) => id.to_string(),
        Provider::Wago(slug) => format!("https://addons.wago.io/addons/{}", slug),
        Provider::GitHub(repo) => format!("https://github.com/{}", repo),
        Provider::Tukui(slug) => format!("tukui:{}", slug),
    }
}

fn present_in(conn: &Connection, flavour: &str, provider: &Provider) -> Result<bool, String> {
    let (sql, text, number): (&str, Option<String>, Option<i64>) = match provider {
        Provider::CurseForge(id) => ("SELECT COUNT(*) FROM addons WHERE flavour = ?1 AND project_id = ?2", None, Some(*id)),
        Provider::Wago(slug) => ("SELECT COUNT(*) FROM addons WHERE flavour = ?1 AND wago_slug = ?2 COLLATE NOCASE", Some(slug.clone()), None),
        Provider::GitHub(repo) => ("SELECT COUNT(*) FROM addons WHERE flavour = ?1 AND repo = ?2 COLLATE NOCASE", Some(repo.clone()), None),
        Provider::Tukui(slug) => ("SELECT COUNT(*) FROM addons WHERE flavour = ?1 AND tukui_slug = ?2 COLLATE NOCASE", Some(slug.clone()), None),
    };
    let count: i64 = match (text, number) {
        (Some(t), _) => conn.query_row(sql, params![flavour, t], |r| r.get(0)),
        (None, Some(n)) => conn.query_row(sql, params![flavour, n], |r| r.get(0)),
        (None, None) => Ok(0),
    }
    .map_err(|e| e.to_string())?;
    Ok(count > 0)
}

/// Decides, for each requested addon of the source game version, whether the add job can copy it to the target game
/// version and with which target string, or why it is skipped. Database only; the install itself is the normal add job.
pub fn plan_copy(
    conn: &Connection,
    source_flavour: &str,
    target_flavour: &str,
    addon_ids: &[String],
) -> Result<Vec<CopyPlanItem>, String> {
    let mut plan = Vec::with_capacity(addon_ids.len());
    for addon_id in addon_ids {
        let row: Option<SourceRow> = conn
            .query_row(
                "SELECT id, COALESCE(name, id), source, project_id, wago_slug, repo, tukui_slug \
                 FROM addons WHERE id = ?1 AND flavour = ?2",
                params![addon_id, source_flavour],
                |r| {
                    Ok(SourceRow {
                        id: r.get(0)?,
                        name: r.get(1)?,
                        source: r.get(2)?,
                        project_id: r.get(3)?,
                        wago_slug: r.get(4)?,
                        repo: r.get(5)?,
                        tukui_slug: r.get(6)?,
                    })
                },
            )
            .optional()
            .map_err(|e| e.to_string())?;
        let row = row.ok_or_else(|| format!("Addon {} is not in {}", addon_id, source_flavour))?;

        if row.source.as_deref().map(|s| s.eq_ignore_ascii_case("zip")).unwrap_or(false) {
            plan.push(CopyPlanItem {
                addon_id: row.id,
                name: row.name,
                add_target: None,
                skip_reason: Some("Installed from a zip file, so there is no source to download it again from".to_string()),
            });
            continue;
        }

        let Some(provider) = provider_of(&row) else {
            plan.push(CopyPlanItem {
                addon_id: row.id,
                name: row.name,
                add_target: None,
                skip_reason: Some("Has no download source Furphy can use".to_string()),
            });
            continue;
        };

        if present_in(conn, target_flavour, &provider)? {
            plan.push(CopyPlanItem {
                addon_id: row.id,
                name: row.name,
                add_target: None,
                skip_reason: Some(format!("Already in {}", target_flavour)),
            });
        } else {
            plan.push(CopyPlanItem {
                addon_id: row.id,
                name: row.name,
                add_target: Some(add_target_for(&provider)),
                skip_reason: None,
            });
        }
    }
    Ok(plan)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::migrate::run_migrations;

    fn db() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        run_migrations(&mut conn).unwrap();
        conn
    }

    #[allow(clippy::too_many_arguments)]
    fn add(conn: &Connection, id: &str, flavour: &str, source: Option<&str>, project_id: Option<i64>, wago_slug: Option<&str>, repo: Option<&str>, tukui_slug: Option<&str>) {
        conn.execute(
            "INSERT INTO addons (id, flavour, name, source, project_id, wago_slug, repo, tukui_slug) VALUES (?1, ?2, ?1, ?3, ?4, ?5, ?6, ?7)",
            params![id, flavour, source, project_id, wago_slug, repo, tukui_slug],
        )
        .unwrap();
    }

    fn ids(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn each_provider_gets_the_target_string_the_add_job_accepts() {
        let conn = db();
        add(&conn, "cf", "retail", Some("curseforge"), Some(3358), Some("wago-slug-too"), None, None);
        add(&conn, "wg", "retail", Some("wago"), None, Some("bigwigs"), None, None);
        add(&conn, "gh", "retail", Some("github"), None, None, Some("owner/repo"), None);
        add(&conn, "tk", "retail", Some("tukui"), None, None, None, Some("elvui"));
        let plan = plan_copy(&conn, "retail", "forever", &ids(&["cf", "wg", "gh", "tk"])).unwrap();
        let targets: Vec<Option<&str>> = plan.iter().map(|p| p.add_target.as_deref()).collect();
        assert_eq!(
            targets,
            vec![
                Some("3358"),
                Some("https://addons.wago.io/addons/bigwigs"),
                Some("https://github.com/owner/repo"),
                Some("tukui:elvui"),
            ]
        );
        assert!(plan.iter().all(|p| p.skip_reason.is_none()));
    }

    #[test]
    fn the_order_of_the_request_is_kept() {
        let conn = db();
        add(&conn, "a", "retail", Some("curseforge"), Some(1), None, None, None);
        add(&conn, "b", "retail", Some("curseforge"), Some(2), None, None, None);
        let plan = plan_copy(&conn, "retail", "forever", &ids(&["b", "a"])).unwrap();
        assert_eq!(plan.iter().map(|p| p.addon_id.as_str()).collect::<Vec<_>>(), vec!["b", "a"]);
    }

    #[test]
    fn an_addon_already_in_the_target_is_skipped_by_provider_identity() {
        let conn = db();
        add(&conn, "src-cf", "retail", Some("curseforge"), Some(3358), None, None, None);
        add(&conn, "dst-cf", "forever", Some("curseforge"), Some(3358), None, None, None);
        add(&conn, "src-wg", "retail", Some("wago"), None, Some("BigWigs"), None, None);
        add(&conn, "dst-wg", "forever", Some("wago"), None, Some("bigwigs"), None, None);
        add(&conn, "src-gh", "retail", Some("github"), None, None, Some("Owner/Repo"), None);
        add(&conn, "dst-gh", "forever", Some("github"), None, None, Some("owner/repo"), None);
        let plan = plan_copy(&conn, "retail", "forever", &ids(&["src-cf", "src-wg", "src-gh"])).unwrap();
        for item in &plan {
            assert_eq!(item.skip_reason.as_deref(), Some("Already in forever"), "{}", item.addon_id);
            assert!(item.add_target.is_none());
        }
        // The same project in a third game version does not count as present in forever.
        add(&conn, "other", "classic", Some("curseforge"), Some(77), None, None, None);
        let plan = plan_copy(&conn, "classic", "forever", &ids(&["other"])).unwrap();
        assert_eq!(plan[0].add_target.as_deref(), Some("77"));
    }

    #[test]
    fn zip_addons_and_addons_without_a_provider_are_skipped_with_their_own_text() {
        let conn = db();
        add(&conn, "zipped", "retail", Some("zip"), None, None, None, None);
        add(&conn, "loose", "retail", None, None, None, None, None);
        let plan = plan_copy(&conn, "retail", "forever", &ids(&["zipped", "loose"])).unwrap();
        assert_eq!(
            plan[0].skip_reason.as_deref(),
            Some("Installed from a zip file, so there is no source to download it again from")
        );
        assert_eq!(plan[1].skip_reason.as_deref(), Some("Has no download source Furphy can use"));
    }

    #[test]
    fn an_adopted_row_without_a_source_uses_the_first_identity_it_has() {
        let conn = db();
        add(&conn, "adopted", "retail", None, Some(555), Some("slug"), None, None);
        let plan = plan_copy(&conn, "retail", "forever", &ids(&["adopted"])).unwrap();
        assert_eq!(plan[0].add_target.as_deref(), Some("555"));
    }

    #[test]
    fn an_id_that_is_not_in_the_source_game_version_is_an_error() {
        let conn = db();
        add(&conn, "a", "retail", Some("curseforge"), Some(1), None, None, None);
        assert_eq!(plan_copy(&conn, "forever", "retail", &ids(&["a"])).unwrap_err(), "Addon a is not in forever");
        assert_eq!(plan_copy(&conn, "retail", "forever", &ids(&["missing"])).unwrap_err(), "Addon missing is not in retail");
        assert!(plan_copy(&conn, "retail", "forever", &[]).unwrap().is_empty());
    }
}
