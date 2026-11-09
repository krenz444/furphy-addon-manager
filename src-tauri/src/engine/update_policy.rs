use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SyncOrigin {
    Manual,
    Background,
}

impl Default for SyncOrigin {
    fn default() -> Self {
        SyncOrigin::Manual
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PolicyAction {
    Install,
    SkipHeld { reason: String },
    SkipDisabledAutoUpdate,
    SkipNotifyOnly,
    SkipModified { modified_files: Vec<String> },
    PromptModified { modified_files: Vec<String> },
    UpToDate,
    Ignored,
    Pinned,
}

pub struct PolicyContext<'a> {
    pub addon_id: &'a str,
    pub name: &'a str,
    pub flavour: &'a str,
    pub client_build: Option<&'a str>,
    pub target_game_versions: &'a [String],
    pub ignored_until_build: Option<&'a str>,
    pub ignore_updates: bool,
    pub is_pinned: bool,
    pub auto_update: bool,
    pub update_mode: &'a str,
    pub origin: SyncOrigin,
    pub override_hold: bool,
    pub override_modified: bool,
    pub integrity_status: Option<&'a str>,
    pub is_newer: bool,
    pub force: bool,
}

pub fn decide(ctx: &PolicyContext) -> PolicyAction {
    // When force is true (e.g. reinstall), bypass is_pinned and !is_newer checks
    if ctx.force {
        return PolicyAction::Install;
    }

    // 1. Pinned addons never update
    if ctx.is_pinned {
        return PolicyAction::Pinned;
    }

    // 2. Addons marked ignore_updates are skipped
    if ctx.ignore_updates {
        return PolicyAction::Ignored;
    }

    // 3. Current release is already current or newer
    if !ctx.is_newer {
        return PolicyAction::UpToDate;
    }

    // 4. Update control predicates
    if ctx.origin == SyncOrigin::Background {
        if !ctx.auto_update {
            return PolicyAction::SkipDisabledAutoUpdate;
        }
        if ctx.update_mode.eq_ignore_ascii_case("notify") {
            return PolicyAction::SkipNotifyOnly;
        }
    }

    // 5. Holdback predicate
    if !ctx.override_hold {
        let is_held = crate::engine::holdback::is_update_held_back(
            ctx.flavour,
            ctx.client_build,
            ctx.target_game_versions,
            ctx.ignored_until_build,
        );
        if let Some(reason) = is_held {
            return PolicyAction::SkipHeld { reason };
        }
    }

    // 6. Integrity predicate
    let is_modified = ctx.integrity_status.map(|s| s.eq_ignore_ascii_case("modified")).unwrap_or(false);
    if is_modified && !ctx.override_modified {
        let modified_files = vec![];
        if ctx.origin == SyncOrigin::Background {
            return PolicyAction::SkipModified { modified_files };
        } else {
            return PolicyAction::PromptModified { modified_files };
        }
    }

    PolicyAction::Install
}
