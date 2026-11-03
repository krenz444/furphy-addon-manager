use reqwest::Url;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WagoQueryParams {
    pub game_version: String,
    pub page: u32,
    pub search: Option<String>,
    pub category: Option<String>,
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

        if let Some(ref s) = self.sort {
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
}
