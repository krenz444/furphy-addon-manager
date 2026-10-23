use chrono::{DateTime, Local, Utc};
use serde::{Deserialize, Serialize};

pub const STATUS_IDLE: &str = "idle";
pub const STATUS_CHECKING: &str = "checking";
pub const STATUS_UPDATING: &str = "updating";
pub const STATUS_FINISHING: &str = "finishing";
pub const STATUS_DONE_CLEAN: &str = "done_clean";
pub const STATUS_DONE_UPDATED: &str = "done_updated";
pub const STATUS_DONE_FAILED: &str = "done_failed";
pub const STATUS_WAITING_BUSY: &str = "waiting_busy";
pub const STATUS_UNREACHABLE: &str = "unreachable";

pub const ICON_NORMAL: &str = "normal";
pub const ICON_BUSY: &str = "busy";
pub const ICON_UPDATED: &str = "updated";
pub const ICON_FAILED: &str = "failed";

pub const NOTIFY_ICON_SHELL_LIMIT: usize = 127;
pub const NOTIFY_ICON_TOOLTIP_LIMIT: usize = 118;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TrayStateSnapshot {
    pub status: String,
    pub phase: Option<String>,
    pub current_addon: Option<String>,
    pub total: usize,
    pub checked_count: usize,
    pub updated: usize,
    pub failed: usize,
    pub up_to_date: usize,
    pub updates_found: usize,
    pub core_text: String,
    pub tooltip: String,
    pub icon_variant: String,
    pub last_result: Option<String>,
    pub last_run_at: Option<DateTime<Utc>>,
    pub next_run_at: Option<DateTime<Utc>>,
    pub updated_names: Vec<String>,
    pub failed_names: Vec<String>,
    pub reload_needed: bool,
}

impl Default for TrayStateSnapshot {
    fn default() -> Self {
        let now = Local::now();
        let core = compute_core(
            STATUS_IDLE,
            None,
            None,
            0,
            0,
            0,
            0,
            0,
            0,
            None,
            None,
            None,
            None,
            Some(now),
        );
        let tooltip = make_tooltip(&core);
        Self {
            status: STATUS_IDLE.to_string(),
            phase: None,
            current_addon: None,
            total: 0,
            checked_count: 0,
            updated: 0,
            failed: 0,
            up_to_date: 0,
            updates_found: 0,
            core_text: core,
            tooltip,
            icon_variant: ICON_NORMAL.to_string(),
            last_result: None,
            last_run_at: None,
            next_run_at: None,
            updated_names: Vec::new(),
            failed_names: Vec::new(),
            reload_needed: false,
        }
    }
}

pub fn is_cycle_running(status: &str) -> bool {
    matches!(status, STATUS_CHECKING | STATUS_UPDATING | STATUS_FINISHING)
}

pub fn icon_variant_for_status(status: &str) -> &'static str {
    match status {
        STATUS_CHECKING | STATUS_UPDATING | STATUS_FINISHING => ICON_BUSY,
        STATUS_DONE_UPDATED => ICON_UPDATED,
        STATUS_DONE_FAILED => ICON_FAILED,
        _ => ICON_NORMAL,
    }
}

pub fn format_next_check(next_run_at_utc: Option<DateTime<Utc>>, now_local: DateTime<Local>) -> String {
    let next_utc = match next_run_at_utc {
        Some(t) => t,
        None => return "soon".to_string(),
    };
    let local = next_utc.with_timezone(&Local);
    let hhmm = local.format("%H:%M").to_string();
    let day_diff = (local.date_naive() - now_local.date_naive()).num_days();

    if day_diff <= 0 {
        hhmm
    } else if day_diff == 1 {
        format!("tomorrow {}", hhmm)
    } else {
        format!("{} {}", local.format("%b %-d"), hhmm)
    }
}

pub fn join_names_truncated(names: &[String], cap: usize) -> String {
    if names.is_empty() {
        return String::new();
    }
    let shown_count = names.len().min(cap);
    let mut out = names[..shown_count].join(", ");
    let remaining = names.len().saturating_sub(shown_count);
    if remaining > 0 {
        out.push_str(&format!(" +{} more", remaining));
    }
    out
}

pub fn truncate_tooltip(s: &str) -> String {
    if s.len() <= NOTIFY_ICON_TOOLTIP_LIMIT {
        s.to_string()
    } else {
        format!("{}...", &s[..115])
    }
}

pub fn fit_notify_icon_text(text: &str, limit: usize) -> String {
    if text.is_empty() {
        return String::new();
    }
    let lim = if limit < 4 { 4 } else { limit };
    if text.len() <= lim {
        text.to_string()
    } else {
        format!("{}...", &text[..lim - 3])
    }
}

pub fn make_tooltip(core_text: &str) -> String {
    let raw = format!("Furphy - {}", core_text);
    let truncated = truncate_tooltip(&raw);
    fit_notify_icon_text(&truncated, NOTIFY_ICON_SHELL_LIMIT)
}

pub fn compute_core(
    status: &str,
    _phase: Option<&str>,
    current_addon: Option<&str>,
    total: usize,
    checked_count: usize,
    updated: usize,
    failed: usize,
    _up_to_date: usize,
    updates_found: usize,
    done_stamp: Option<&str>,
    next_run_at_utc: Option<DateTime<Utc>>,
    updated_names: Option<&[String]>,
    _failed_names: Option<&[String]>,
    now_local: Option<DateTime<Local>>,
) -> String {
    let now = now_local.unwrap_or_else(Local::now);

    match status {
        STATUS_IDLE => {
            format!("Background updates on - next check {}", format_next_check(next_run_at_utc, now))
        }
        STATUS_CHECKING => {
            if total == 0 {
                "Starting the updater...".to_string()
            } else {
                let mut p = checked_count + 1;
                if p > total {
                    p = total;
                }
                if p < 1 {
                    p = 1;
                }
                format!("Checking addons ({} of {})...", p, total)
            }
        }
        STATUS_UPDATING => {
            let addon_name = current_addon.unwrap_or("addon");
            let current_idx = if updates_found == 0 {
                updated + 1
            } else {
                (updated + 1).min(updates_found)
            };
            format!("Updating {} ({} of {} updates)...", addon_name, current_idx, updates_found)
        }
        STATUS_FINISHING => "Finishing...".to_string(),
        STATUS_DONE_CLEAN => {
            let stamp = done_stamp.unwrap_or("");
            format!(
                "Everything's up to date - checked {} - next {}",
                stamp,
                format_next_check(next_run_at_utc, now)
            )
        }
        STATUS_DONE_UPDATED => {
            let plural = if updated == 1 { "" } else { "s" };
            let stamp = done_stamp.unwrap_or("");
            let names_str = join_names_truncated(updated_names.unwrap_or(&[]), 4);
            format!("Updated {} addon{} at {}: {}", updated, plural, stamp, names_str)
        }
        STATUS_DONE_FAILED => {
            let plural = if failed == 1 { "" } else { "s" };
            let stamp = done_stamp.unwrap_or("");
            format!("{} addon{} couldn't update at {} - open Furphy for details", failed, plural, stamp)
        }
        STATUS_WAITING_BUSY => "Waiting for the current task - retrying in 5 min".to_string(),
        STATUS_UNREACHABLE => "Couldn't reach the updater - retrying in 5 min".to_string(),
        _ => "Working...".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone};

    #[test]
    fn test_format_next_check() {
        let now = Local.with_ymd_and_hms(2026, 10, 23, 10, 0, 0).unwrap();

        // None -> soon
        assert_eq!(format_next_check(None, now), "soon");

        // Same day -> HH:mm
        let today_utc = now.with_timezone(&Utc) + Duration::hours(2);
        assert_eq!(format_next_check(Some(today_utc), now), "12:00");

        // Tomorrow -> tomorrow HH:mm
        let tomorrow_utc = now.with_timezone(&Utc) + Duration::days(1) + Duration::hours(1);
        assert_eq!(format_next_check(Some(tomorrow_utc), now), "tomorrow 11:00");

        // 2+ days -> MMM d HH:mm
        let two_days_utc = now.with_timezone(&Utc) + Duration::days(3);
        assert_eq!(format_next_check(Some(two_days_utc), now), "Oct 26 10:00");
    }

    #[test]
    fn test_join_names_truncated() {
        let names = vec!["BigWigs".into(), "Details".into(), "Plater".into(), "WeakAuras".into(), "TomTom".into()];
        assert_eq!(
            join_names_truncated(&names, 4),
            "BigWigs, Details, Plater, WeakAuras +1 more"
        );
        assert_eq!(
            join_names_truncated(&names[..2], 4),
            "BigWigs, Details"
        );
        assert_eq!(join_names_truncated(&[], 4), "");
    }

    #[test]
    fn test_fit_and_truncate_limits() {
        let long_str = "x".repeat(200);
        let truncated = truncate_tooltip(&long_str);
        assert_eq!(truncated.len(), 118);
        assert!(truncated.ends_with("..."));

        let shell_fit = fit_notify_icon_text(&long_str, 127);
        assert_eq!(shell_fit.len(), 127);
        assert!(shell_fit.ends_with("..."));
    }

    #[test]
    fn test_compute_core_sentences() {
        let now = Local.with_ymd_and_hms(2026, 10, 23, 20, 51, 0).unwrap();
        let next_utc = (now + Duration::days(1)).with_timezone(&Utc);

        // done_clean
        let clean = compute_core(
            STATUS_DONE_CLEAN,
            None,
            None,
            0,
            0,
            0,
            0,
            0,
            0,
            Some("20:51"),
            Some(next_utc),
            None,
            None,
            Some(now),
        );
        assert_eq!(
            clean,
            "Everything's up to date - checked 20:51 - next tomorrow 20:51"
        );

        // done_updated plural
        let names = vec!["Auctionator".into(), "Bagnon".into()];
        let updated = compute_core(
            STATUS_DONE_UPDATED,
            None,
            None,
            2,
            2,
            2,
            0,
            0,
            2,
            Some("20:51"),
            Some(next_utc),
            Some(&names),
            None,
            Some(now),
        );
        assert_eq!(updated, "Updated 2 addons at 20:51: Auctionator, Bagnon");

        // done_updated singular
        let one_name = vec!["Auctionator".into()];
        let updated_single = compute_core(
            STATUS_DONE_UPDATED,
            None,
            None,
            1,
            1,
            1,
            0,
            0,
            1,
            Some("20:51"),
            Some(next_utc),
            Some(&one_name),
            None,
            Some(now),
        );
        assert_eq!(updated_single, "Updated 1 addon at 20:51: Auctionator");

        // done_failed
        let failed = compute_core(
            STATUS_DONE_FAILED,
            None,
            None,
            1,
            1,
            0,
            2,
            0,
            0,
            Some("20:51"),
            Some(next_utc),
            None,
            None,
            Some(now),
        );
        assert_eq!(failed, "2 addons couldn't update at 20:51 - open Furphy for details");

        // updating progress: updated + 1 of updates_found
        let updating = compute_core(
            STATUS_UPDATING,
            None,
            Some("Details"),
            5,
            5,
            1, // 1 already updated
            0,
            0,
            3, // 3 updates found total
            None,
            None,
            None,
            None,
            Some(now),
        );
        assert_eq!(updating, "Updating Details (2 of 3 updates)...");

        // checking with total > 0
        let checking = compute_core(
            STATUS_CHECKING,
            None,
            None,
            35,
            34,
            0,
            0,
            0,
            0,
            None,
            None,
            None,
            None,
            Some(now),
        );
        assert_eq!(checking, "Checking addons (35 of 35)...");

        // checking with total == 0
        let checking_zero = compute_core(
            STATUS_CHECKING,
            None,
            None,
            0,
            0,
            0,
            0,
            0,
            0,
            None,
            None,
            None,
            None,
            Some(now),
        );
        assert_eq!(checking_zero, "Starting the updater...");
    }
}
