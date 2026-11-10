use std::collections::HashSet;
use std::sync::Arc;
use rusqlite::OptionalExtension;
use crate::db::open_connection;
use crate::net::policy::NetworkPolicy;
use crate::paths::get_db_path;

#[derive(Debug, Clone, serde::Serialize)]
pub struct TukuiAddonDto {
    pub slug: String,
    pub name: String,
    pub author: String,
    pub version: String,
    pub last_update: Option<String>,
    pub supported_patches: Vec<String>,
    pub summary: Option<String>,
    pub web_url: Option<String>,
    pub compatible: bool,
    pub reason: Option<String>,
    pub installed: bool,
}

pub fn build_tukui_addon_dtos(
    conn: &rusqlite::Connection,
    addons: Vec<crate::net::tukui::TukuiAddon>,
    flavour: Option<&str>,
) -> Result<Vec<TukuiAddonDto>, String> {
    let target_flavour = flavour.map(str::trim).filter(|s| !s.is_empty());

    let (client_build, client_interface): (Option<String>, Option<i32>) = if let Some(flv) = target_flavour {
        conn.query_row(
            "SELECT client_build, client_interface FROM flavours WHERE id = ?1",
            rusqlite::params![flv],
            |r| {
                let build: Option<String> = r.get(0)?;
                let iface: Option<i32> = match r.get::<_, Option<i32>>(1) {
                    Ok(val) => val,
                    Err(_) => r.get::<_, Option<String>>(1).ok().flatten().and_then(|s| s.parse().ok()),
                };
                Ok((build, iface))
            },
        )
        .optional()
        .map_err(|e| format!("Database query error: {}", e))?
        .unwrap_or((None, None))
    } else {
        (None, None)
    };

    let era_label = if let Some(flv) = target_flavour {
        crate::engine::flavours::get_flavour_mapping(flv, client_interface).era_label
    } else {
        String::new()
    };

    let version_prefix = if let Some(flv) = target_flavour {
        crate::engine::tukui::version_prefix_for(flv, client_build.as_deref())
    } else {
        None
    };

    let installed_slugs: HashSet<String> = if let Some(flv) = target_flavour {
        let mut stmt = conn
            .prepare("SELECT COALESCE(tukui_slug, '') FROM addons WHERE flavour = ?1")
            .map_err(|e| format!("Database error: {}", e))?;
        let rows = stmt
            .query_map(rusqlite::params![flv], |r| r.get::<_, String>(0))
            .map_err(|e| format!("Database error: {}", e))?;
        let mut set = HashSet::new();
        for slug in rows.flatten() {
            let clean = slug.trim().to_ascii_lowercase();
            if !clean.is_empty() {
                set.insert(clean);
            }
        }
        set
    } else {
        HashSet::new()
    };

    let mut dtos = Vec::with_capacity(addons.len());
    for addon in addons {
        let (compatible, reason, installed) = if target_flavour.is_some() {
            let comp = crate::engine::tukui::tukui_supports(&addon, version_prefix.as_deref());
            let rsn = crate::engine::tukui::tukui_unavailable_reason(&addon, &era_label, version_prefix.as_deref());
            let inst = installed_slugs.contains(&addon.slug.trim().to_ascii_lowercase());
            (comp, rsn, inst)
        } else {
            (true, None, false)
        };

        dtos.push(TukuiAddonDto {
            slug: addon.slug,
            name: addon.name,
            author: addon.author,
            version: addon.version,
            last_update: addon.last_update,
            supported_patches: addon.patch,
            summary: addon.small_desc,
            web_url: addon.web_url,
            compatible,
            reason,
            installed,
        });
    }

    Ok(dtos)
}

#[tauri::command]
pub async fn tukui_addons(
    policy: tauri::State<'_, Arc<NetworkPolicy>>,
    flavour: Option<String>,
) -> Result<Vec<TukuiAddonDto>, String> {
    let client = crate::net::tukui::create_tukui_client()
        .map_err(|e| format!("Failed to create Tukui HTTP client: {}", e))?;
    let addons = crate::net::tukui::get_tukui_addons(&policy, &client).await?;

    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| format!("Database error: {}", e))?;

    build_tukui_addon_dtos(&conn, addons, flavour.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use crate::net::tukui::TukuiAddon;

    fn sample_addons() -> Vec<TukuiAddon> {
        vec![
            TukuiAddon {
                id: "-2".to_string(),
                slug: "elvui".to_string(),
                name: "ElvUI".to_string(),
                author: "Elv, Simpy".to_string(),
                url: "https://api.tukui.org/v1/download/elvui/12.1.5".to_string(),
                version: "12.1.5".to_string(),
                patch: vec![
                    "12.1.5".to_string(),
                    "1.60.1".to_string(),
                    "5.5.4".to_string(),
                    "1.15.9".to_string(),
                    "2.5.6".to_string(),
                ],
                last_update: Some("2026-11-09".to_string()),
                web_url: Some("https://www.tukui.org/addons.php?id=-2".to_string()),
                small_desc: Some("Complete UI overhaul".to_string()),
                directories: vec!["ElvUI".to_string(), "ElvUI_Libraries".to_string(), "ElvUI_Options".to_string()],
            },
            TukuiAddon {
                id: "-1".to_string(),
                slug: "tukui".to_string(),
                name: "Tukui".to_string(),
                author: "Tukz".to_string(),
                url: "https://api.tukui.org/v1/download/tukui/11.1.7".to_string(),
                version: "11.1.7".to_string(),
                patch: vec!["11.1.7".to_string(), "5.5.0".to_string(), "1.15.7".to_string()],
                last_update: Some("2026-10-15".to_string()),
                web_url: Some("https://www.tukui.org/addons.php?id=-1".to_string()),
                small_desc: Some("Minimalist UI".to_string()),
                directories: vec!["Tukui".to_string()],
            },
        ]
    }

    fn setup_test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("
            CREATE TABLE flavours (
                id TEXT PRIMARY KEY,
                folder TEXT NOT NULL,
                label TEXT NOT NULL,
                product TEXT,
                installed INTEGER NOT NULL DEFAULT 0,
                client_build TEXT,
                client_interface TEXT
            );
            CREATE TABLE addons (
                id TEXT PRIMARY KEY,
                flavour TEXT NOT NULL,
                source TEXT,
                tukui_slug TEXT
            );

            INSERT INTO flavours (id, folder, label, installed, client_build, client_interface)
            VALUES ('retail', '_retail_', 'Retail', 1, '12.1.5.70783', '120105');

            INSERT INTO flavours (id, folder, label, installed, client_build, client_interface)
            VALUES ('forever', '_forever_', 'WoW Forever', 1, '1.60.1.70862', '16001');

            INSERT INTO addons (id, flavour, source, tukui_slug)
            VALUES ('tukui:retail:elvui', 'retail', 'tukui', 'elvui');
        ").unwrap();
        conn
    }

    #[test]
    fn test_build_tukui_addon_dtos_retail() {
        let conn = setup_test_db();
        let addons = sample_addons();

        let dtos = build_tukui_addon_dtos(&conn, addons, Some("retail")).unwrap();
        assert_eq!(dtos.len(), 2);

        let elvui = &dtos[0];
        assert_eq!(elvui.slug, "elvui");
        assert!(elvui.compatible);
        assert_eq!(elvui.reason, None);
        assert!(elvui.installed);
        assert_eq!(elvui.summary.as_deref(), Some("Complete UI overhaul"));

        let tukui = &dtos[1];
        assert_eq!(tukui.slug, "tukui");
        assert!(!tukui.compatible);
        assert!(tukui.reason.is_some());
        assert!(!tukui.installed);
    }

    #[test]
    fn test_build_tukui_addon_dtos_forever() {
        let conn = setup_test_db();
        let addons = sample_addons();

        let dtos = build_tukui_addon_dtos(&conn, addons, Some("forever")).unwrap();
        assert_eq!(dtos.len(), 2);

        let elvui = &dtos[0];
        assert_eq!(elvui.slug, "elvui");
        assert!(elvui.compatible);
        assert_eq!(elvui.reason, None);
        assert!(!elvui.installed);

        let tukui = &dtos[1];
        assert_eq!(tukui.slug, "tukui");
        assert!(!tukui.compatible);
        assert!(tukui.reason.is_some());
        assert!(!tukui.installed);
    }

    #[test]
    fn test_build_tukui_addon_dtos_none_flavour() {
        let conn = setup_test_db();
        let addons = sample_addons();

        let dtos = build_tukui_addon_dtos(&conn, addons, None).unwrap();
        assert_eq!(dtos.len(), 2);

        for dto in dtos {
            assert!(dto.compatible);
            assert_eq!(dto.reason, None);
            assert!(!dto.installed);
        }
    }
}
