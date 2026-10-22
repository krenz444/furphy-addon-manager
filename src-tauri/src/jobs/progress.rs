use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProgressTallies {
    pub checked: usize,
    pub updated: usize,
    pub failed: usize,
    pub up_to_date: usize,
    pub updates_found: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct JobProgressStep {
    pub total: usize,
    pub index: usize,
    pub addon: Option<String>,
    pub phase: String, // "queued", "checking", "downloading", "installing", "up_to_date", "done", "failed"
    pub bytes_done: Option<u64>,
    pub bytes_total: Option<u64>,
    pub tallies: ProgressTallies,
}
