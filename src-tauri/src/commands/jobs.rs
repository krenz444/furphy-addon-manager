use std::sync::Arc;
use serde_json::Value;
use crate::db::open_connection;
use crate::jobs::runner::{JobRecord, JobRunner};
use crate::paths::get_db_path;

#[tauri::command]
pub async fn start_job(
    runner: tauri::State<'_, Arc<JobRunner>>,
    kind: String,
    params: Option<Value>,
    flavour: Option<String>,
) -> Result<JobRecord, String> {
    let runner = runner.inner().clone();
    let (tx, rx) = tokio::sync::oneshot::channel();

    std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(r) => r,
            Err(e) => {
                let _ = tx.send(Err(format!("Failed to build async runtime for job: {}", e)));
                return;
            }
        };

        rt.block_on(async move {
            let db_path = get_db_path();
            let mut conn = match open_connection(&db_path) {
                Ok(c) => c,
                Err(e) => {
                    let _ = tx.send(Err(e.to_string()));
                    return;
                }
            };
            let params_val = params.unwrap_or(Value::Null);
            let res = runner
                .run_job(&mut conn, &kind, flavour.as_deref(), params_val)
                .await
                .map_err(|e| e.to_string());
            let _ = tx.send(res);
        });
    });

    rx.await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn list_jobs() -> Result<Vec<JobRecord>, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare(
            "SELECT id, kind, flavour, params, state, started_at, finished_at, error, results, reload_needed, log_path \
             FROM jobs ORDER BY started_at DESC LIMIT 20",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([], |r| {
            Ok(JobRecord {
                id: r.get(0)?,
                kind: r.get(1)?,
                flavour: r.get(2)?,
                params: r.get(3)?,
                state: r.get(4)?,
                started_at: r.get(5)?,
                finished_at: r.get(6)?,
                error: r.get(7)?,
                results: r.get(8)?,
                reload_needed: r.get::<_, i32>(9)? != 0,
                log_path: r.get(10)?,
            })
        })
        .map_err(|e| e.to_string())?;

    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(|e| e.to_string())?);
    }
    Ok(out)
}

#[tauri::command]
pub fn get_job(id: String) -> Result<JobRecord, String> {
    let db_path = get_db_path();
    let conn = open_connection(&db_path).map_err(|e| e.to_string())?;
    conn.query_row(
        "SELECT id, kind, flavour, params, state, started_at, finished_at, error, results, reload_needed, log_path \
         FROM jobs WHERE id = ?1",
        rusqlite::params![id],
        |r| {
            Ok(JobRecord {
                id: r.get(0)?,
                kind: r.get(1)?,
                flavour: r.get(2)?,
                params: r.get(3)?,
                state: r.get(4)?,
                started_at: r.get(5)?,
                finished_at: r.get(6)?,
                error: r.get(7)?,
                results: r.get(8)?,
                reload_needed: r.get::<_, i32>(9)? != 0,
                log_path: r.get(10)?,
            })
        },
    )
    .map_err(|e| e.to_string())
}
