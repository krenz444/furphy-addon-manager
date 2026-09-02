# Expansion backlog (each item is a self-contained spec; builders implement across CLI, server and UI as needed)

Conventions: every expansion appends its own section to SPEC.md (so SPEC stays authoritative) and an entry to CHANGELOG.md. Keep all existing tests passing. PowerShell 5.1, pure ASCII, keyless CurseForge facts as in SPEC. Each item lists ACCEPTANCE tests that the test stage must run.

## E1 - Rollback / version history
CLI: before replacing an addon, copy the previously installed zip (the one that produced the current fileId) into `ROOT\backups\<projectId>\<fileId>.zip`; simplest implementation: after every successful install keep the downloaded zip there (move it from staging instead of deleting) and prune so at most 2 zips per project remain (newest two). Record gains `previousFileId` (int64|null) and `previousVersion` (string|null) set on every update (the fileId/version being replaced). New param `-Rollback <int[]>`: for each id, if `backups\<projectId>\<previousFileId>.zip` exists install from that local zip (same Install-AddonPackage path, no download), swap fileId/version with previous, set `pinnedFileId` to the restored fileId (so it is not immediately re-updated), status row `Rolled-back`; else `Failed` with reason. `-Json` supported.
Server: job kind `rollback` `{projectId}` -> `-Rollback id`. `/api/state` records expose previousFileId/previousVersion.
UI: kebab "Roll back to <previousVersion>" (only when previousFileId present); Versions tab marks the previous file "Previous"; after rollback the row shows Pinned with a tooltip "Rolled back - unpin to resume updates".
ACCEPTANCE: install 911525 at an older fileId via -FileId, unpin, sync to newest -> backups has both zips, record.previousFileId = older; -Rollback 911525 -> record.fileId = older, pinnedFileId = older, folder contents match the older version (toc Version line), status Rolled-back; prune: never more than 2 zips per project.

## E2 - Automatic update checks
Server: persist the last check results (Would-update rows keyed by projectId, plus updatesCheckedAt) to `ROOT\state.json` and load it at startup so badges survive restarts. `/api/state` includes `updatesCheckedAt`.
UI: on load, if `updatesCheckedAt` is null or older than 10 minutes and no job is running, start a `check` job automatically (non-blocking, progress panel collapsed to a slim bar). Every 30 minutes while the window is open, repeat (skip if a job is running). Sidebar shows an orange "n updates" badge; header count text updates.
ACCEPTANCE: fresh server + UI load with stale/no check -> a check job starts automatically within 3 s; state.json written; restart server -> /api/state still has updatesCheckedAt and updateAvailable entries.

## E3 - Dependencies
CLI: at install/update time parse the primary .toc of each installed folder for `## Dependencies:`, `## RequiredDeps:`, `## Dependencies:` (values comma or space separated, case-insensitive keys) and `## OptionalDeps:`; store `requiredDeps` (string[] of folder names, deduplicated, excluding folders provided by the same package) and `optionalDeps` on the record. `-Status -Json` and `/api/state` compute `missingDeps` per record = requiredDeps not present as a folder in AddOns (computed live, not stored).
UI: My Addons row shows a warning chip "Missing: X" when missingDeps is non-empty; drawer Overview lists Required/Optional dependencies with a status dot (installed / missing) and, for missing ones, a "Search CurseForge" button (with key: switches to Browse pre-filled with the name; without key: opens https://www.curseforge.com/wow/search?search=<name> via /api/open with what 'url' - add that target to /api/open: `{what:'url', url}` restricted to https://www.curseforge.com/ and https://addons.wago.io/ prefixes).
ACCEPTANCE: after installing 1521253 the record has requiredDeps [] (none); hand-craft a scratch folder record test: create a fake installed folder whose toc has `## Dependencies: LibStub, Foo` -> -Status -Json shows missingDeps ["Foo"] (LibStub absent too unless present); UI shows the chip.

## E4 - Export / import addon list
Server: `GET /api/export` -> `{format:"wow-addon-manager/1", exportedAt, addons:[{projectId, name, pinnedFileId, ignoreUpdates, releaseType}]}` with `Content-Disposition: attachment; filename=addons-export.json`. `POST /api/import` body of the same shape -> starts job kind `import`: CLI `-Add` for every projectId not yet present (one CLI invocation with all ids), then applies pinnedFileId (via `-Only id -FileId f`) / ignoreUpdates (`-Ignore`) flags for imported records; results rows per addon. Reject bodies with wrong format field (400).
UI: Settings -> "Backup & restore": Export (creates a Blob download from /api/export), Import (file input -> POST /api/import -> progress panel), and a preview of how many will be added / already present before confirming.
ACCEPTANCE: export with two addons installed returns valid JSON with both; remove one; import the file -> job adds it back; importing the same file again -> 0 added, no errors.

## E5 - Update digest and changelog access
UI: when a sync/launch job finishes with Updated/Installed rows, the results list shows per row "What changed" (with key: opens drawer Changelog tab at the installed fileId; without key: opens the Versions tab). My Addons header gains a "Last run" summary line (from lastRun) with a "Details" link that opens the progress panel with the last results.
ACCEPTANCE: after an install job, the results panel has a "What changed" control per Installed row and it opens the drawer on the right tab; lastRun line visible after reload.

## E7 - UI polish batch
- Status filter chips above the table: All / Updates / Pinned / Ignored / Failed / Missing deps, with counts.
- Column sorting (Name, Installed, Latest, Status, Updated) with a visible indicator, persisted in localStorage.
- Keyboard: `/` focuses search, `Esc` closes drawer/menus/dialogs, `r` triggers Check for updates when no job runs.
- Density toggle (comfortable/compact) and theme toggle (dark/light) in Settings -> Appearance, persisted in localStorage; light theme must be complete (all tokens).
- Settings -> Maintenance: "Open backups folder" (/api/open what 'backups').
- Tooltips on every icon button (title attributes), focus-visible outlines everywhere.
ACCEPTANCE: chips filter rows and show counts; sorting toggles asc/desc and persists across reload; keyboard shortcuts work; light theme renders without unreadable text (browser screenshot); no console errors.

## E10 - Diagnostics
Server: `GET /api/diagnostics` -> runs quick checks and returns `{checks:[{name, ok, detail}]}`: AddOns path exists and writable (create+delete temp file), settings.json parse, addons.json parse + record count, CurseForge reachability (one keyless files request for project 1521253, allowed), official API key valid (only if key configured), free disk space on the game drive (GB), PowerShell version, server uptime, last sync timestamp.
UI: Settings -> Diagnostics: "Run" button, results list with green/red dots, "Copy report" button (clipboard, plain text).
ACCEPTANCE: endpoint returns all checks; UI renders them; copy produces text.

## E11 - Bulk actions
UI: checkbox column in My Addons (header checkbox selects visible/filtered rows); a selection bar appears with "Update selected", "Ignore selected"/"Stop ignoring", "Uninstall selected" (confirm listing names). Update -> sync job with ids; ignore -> sequential ignore calls; uninstall -> job kind `remove` must accept `projectIds:[...]` (server maps to one CLI `-Remove` invocation with all ids).
ACCEPTANCE: select two rows -> bar shows "2 selected"; Update selected starts a sync job with exactly those ids (verify job params); Uninstall selected removes both in one job.

## Deferred (only if all above are done and time remains)
- E6 faster sync (bounded concurrency) - risk of CurseForge bot detection, keep sequential unless proven safe.
- E8 "start server at logon" opt-in scheduled task.
- E9 fingerprint-based adoption of untracked folders (official API, needs a key to verify).
