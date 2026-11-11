use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct JobRecord {
    pub id: String,
    pub kind: String,
    pub flavour: Option<String>,
    pub params: Option<String>,
    pub state: String, // "running", "completed", "failed"
    pub started_at: String,
    pub finished_at: Option<String>,
    pub error: Option<String>,
    pub results: Option<String>,
    pub reload_needed: bool,
    pub log_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct ProgressTallies {
    pub checked: usize,
    pub updated: usize,
    pub failed: usize,
    pub up_to_date: usize,
    pub updates_found: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct JobProgressStep {
    pub total: usize,
    pub index: usize,
    pub addon: Option<String>,
    pub phase: String, // "queued", "checking", "downloading", "installing", "up_to_date", "done", "failed"
    pub bytes_done: Option<u64>,
    pub bytes_total: Option<u64>,
    pub tallies: ProgressTallies,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct QueuedJobDto {
    pub queue_id: String,
    pub kind: String,
    pub flavour: Option<String>,
    pub target_label: Option<String>,
    pub queued_at: String,
    pub position: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct JobProgressEvent {
    pub job_id: String,
    pub kind: String,
    pub flavour: Option<String>,
    pub step: JobProgressStep,
    pub percent: u8,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct JobQueueSnapshot {
    pub active_job: Option<JobRecord>,
    pub active_progress: Option<JobProgressEvent>,
    pub queued_jobs: Vec<QueuedJobDto>,
}

pub fn compute_progress_percent(step: &JobProgressStep) -> u8 {
    if step.total == 0 {
        return if step.phase == "done" { 100 } else { 0 };
    }
    let completed = match step.phase.as_str() {
        "done" | "up_to_date" | "failed" => step.index.min(step.total) as f64,
        _ => {
            let base = step.index.saturating_sub(1).min(step.total) as f64;
            let sub = match (step.bytes_done, step.bytes_total) {
                (Some(done), Some(total)) if total > 0 => (done as f64 / total as f64).clamp(0.0, 0.99),
                _ => match step.phase.as_str() {
                    "downloading" => 0.35,
                    "installing" => 0.70,
                    _ => 0.0,
                },
            };
            (base + sub).min(step.total as f64)
        }
    };
    ((completed / step.total as f64) * 100.0).round().clamp(0.0, 100.0) as u8
}
