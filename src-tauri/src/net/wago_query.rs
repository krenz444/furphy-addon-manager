use reqwest::Url;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WagoQueryParams {
    pub game_version: String,
    pub page: u32,
    pub search: Option<String>,
    pub category: Option<String>,
    /// The sort the user asked for (UI vocabulary). Not necessarily sent to Wago:
    /// see [`WagoQueryParams::upstream_sort`].
    pub sort: Option<String>,
}

impl WagoQueryParams {
    pub fn new(
        flavour: Option<&str>,
        page: Option<u32>,
        query: Option<&str>,
        category: Option<&str>,
        sort: Option<&str>,
    ) -> Self {
        let game_version = match flavour.unwrap_or("retail") {
            "classic_era" | "forever" | "classic" => "classic".to_string(),
            "cata" => "cata".to_string(),
            "wotlk" => "wotlk".to_string(),
            _ => "retail".to_string(),
        };

        let page = page.unwrap_or(1).max(1);

        let search = query
            .map(|q| q.trim().to_string())
            .filter(|q| !q.is_empty());

        let category = category
            .map(|c| c.trim().to_string())
            .filter(|c| !c.is_empty() && c.chars().all(|ch| ch.is_ascii_digit()) && c != "0");

        let sort = sort
            .map(|s| s.trim().to_lowercase())
            .filter(|s| {
                matches!(
                    s.as_str(),
                    "popular" | "downloads" | "rating" | "updated" | "name" | "gaining"
                )
            });

        Self {
            game_version,
            page,
            search,
            category,
            sort,
        }
    }

    /// The only `sort` value Wago's listing honours is `name` (`updated` is accepted but
    /// returns an empty list). Any other value (`popular`, `downloads`, `rating`,
    /// `gaining`) makes Wago redirect to `/` and drop `search`, `game_version` and
    /// `category`, returning its unfiltered default listing. Verified live 2026-11-03.
    /// Wago's default order is already by downloads, so omitting `sort` is "popular".
    pub fn upstream_sort(&self) -> Option<&'static str> {
        match self.sort.as_deref() {
            Some("name") => Some("name"),
            _ => None,
        }
    }

    pub fn apply_to_url(&self, url: &mut Url) {
        let mut qp = url.query_pairs_mut();
        qp.append_pair("game_version", &self.game_version);
        qp.append_pair("page", &self.page.to_string());

        if let Some(ref s) = self.search {
            qp.append_pair("search", s);
        }

        if let Some(ref c) = self.category {
            qp.append_pair("category", c);
        }

        if let Some(s) = self.upstream_sort() {
            qp.append_pair("sort", s);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wago_query_params_mapping() {
        let p_forever = WagoQueryParams::new(Some("forever"), Some(2), Some(" Details "), Some("18"), Some("downloads"));
        assert_eq!(p_forever.game_version, "classic");
        assert_eq!(p_forever.page, 2);
        assert_eq!(p_forever.search.as_deref(), Some("Details"));
        assert_eq!(p_forever.category.as_deref(), Some("18"));
        assert_eq!(p_forever.sort.as_deref(), Some("downloads"));

        let p_retail = WagoQueryParams::new(Some("retail"), None, None, None, Some("rating"));
        assert_eq!(p_retail.game_version, "retail");
        assert_eq!(p_retail.page, 1);
        assert_eq!(p_retail.sort.as_deref(), Some("rating"));
        assert_eq!(p_retail.search, None);

        // Invalid sort fallback
        let p_invalid_sort = WagoQueryParams::new(None, Some(0), None, None, Some("unsupported_sort"));
        assert_eq!(p_invalid_sort.page, 1);
        assert_eq!(p_invalid_sort.sort, None);
    }

    fn url_for(p: &WagoQueryParams) -> String {
        let mut url = Url::parse("https://addons.wago.io/").unwrap();
        p.apply_to_url(&mut url);
        url.to_string()
    }

    #[test]
    fn test_only_name_sort_is_sent_upstream() {
        for sort in ["popular", "downloads", "rating", "updated", "gaining"] {
            let p = WagoQueryParams::new(Some("retail"), None, Some("plater"), None, Some(sort));
            let url = url_for(&p);
            assert!(!url.contains("sort="), "sort={sort} must not reach Wago: {url}");
            assert!(
                url.contains("search=plater") && url.contains("game_version=retail"),
                "filters must survive: {url}"
            );
        }
        let named = WagoQueryParams::new(Some("retail"), None, None, None, Some("name"));
        assert!(url_for(&named).contains("sort=name"));
    }

    #[test]
    fn test_requested_sort_is_kept_for_client_side_ordering() {
        let p = WagoQueryParams::new(None, None, None, None, Some("Updated"));
        assert_eq!(p.sort.as_deref(), Some("updated"));
        assert_eq!(p.upstream_sort(), None);
    }

    #[test]
    fn test_flavour_changes_game_version_and_search_is_url_encoded() {
        let retail = url_for(&WagoQueryParams::new(Some("retail"), Some(2), Some("Boss Mods"), Some("14"), None));
        assert!(retail.contains("game_version=retail") && retail.contains("page=2"), "{retail}");
        assert!(retail.contains("search=Boss+Mods") && retail.contains("category=14"), "{retail}");
        let forever = url_for(&WagoQueryParams::new(Some("forever"), None, None, None, None));
        assert!(forever.contains("game_version=classic"), "{forever}");
    }
}
