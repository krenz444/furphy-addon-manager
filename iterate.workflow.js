export const meta = {
  name: 'iterate-addon-manager',
  description: 'One overnight round: audit the Addon Manager, fix, implement backlog expansions, review, and test',
  phases: [
    { title: 'Audit', detail: 'code audits + browser UX audit + feature-gap audit', model: 'haiku' },
    { title: 'Fix', detail: 'apply audit findings per component', model: 'sonnet' },
    { title: 'Expand', detail: 'implement backlog items sequentially', model: 'sonnet' },
    { title: 'Review', detail: 'lenses over the expanded code + contract', model: 'haiku' },
    { title: 'Test CLI', model: 'sonnet' },
    { title: 'Test Server', model: 'sonnet' },
    { title: 'Test UI', model: 'sonnet' },
  ],
}

const ROOT = 'C:\\Users\\drops\\AppData\\Local\\Temp\\claude\\C--Users-drops-Documents-3d\\e63e63f2-6f4b-4497-8d16-50029ad3f751\\scratchpad\\AddonSync2'
const SPEC = ROOT + '\\SPEC.md'
const ROADMAP = ROOT + '\\ROADMAP.md'
const CHANGELOG = ROOT + '\\CHANGELOG.md'
const TESTDIR = 'C:\\Users\\drops\\AppData\\Local\\Temp\\claude\\C--Users-drops-Documents-3d\\e63e63f2-6f4b-4497-8d16-50029ad3f751\\scratchpad\\test-addons'
const CLI = ROOT + '\\addon-sync.ps1'
const SERVER = ROOT + '\\addon-server.ps1'
const UI = ROOT + '\\ui'
const PARSE = (f) => `$errs=$null; [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath '${f}'), [ref]$errs) | Out-Null; $errs | Select Message, @{n='Line';e={$_.Token.StartLine}}`
const NODECHECK = `& 'C:\\Program Files\\nodejs\\node.exe' --check '${UI}\\app.js'`
const COMMON = `Read ${SPEC} in full first (authoritative spec, verified CurseForge facts, PowerShell 5.1 quirks on this machine, API contract). Never touch C:\\Program Files (x86)\\World of Warcraft. No CurseForge requests unless your task explicitly allows it. Never start a 'launch' job or click Update & Play / Launch WoW.`
const START_SERVER = `Start the server hidden: Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','"${SERVER}"','-Port','47899','-Root','"${ROOT}"','-AddonsPath','"${TESTDIR}"','-IdleMinutes','15' -WindowStyle Hidden -PassThru ; wait for GET http://localhost:47899/api/ping (retry 15 s). ALWAYS POST /api/shutdown at the end (and kill the PID if it lingers).`
const BROWSER = `Use the Browser pane tools (load via ToolSearch: mcp__Claude_Browser__preview_start, navigate, computer, read_page, find, javascript_tool, read_console_messages, resize_window) to open http://localhost:47899/ .`

const round = args && args.round ? args.round : 1
const expansions = (args && args.expansions) ? args.expansions : []
const FILES = { cli: CLI, server: SERVER, ui: UI + ' (index.html, style.css, app.js)' }
const CHECK = { cli: `parse check: ${PARSE(CLI)}`, server: `parse check: ${PARSE(SERVER)}`, ui: `syntax check: ${NODECHECK}` }

const FINDINGS_SCHEMA = { type: 'object', properties: { findings: { type: 'array', items: { type: 'object', properties: {
  component: { type: 'string', enum: ['cli', 'server', 'ui'] }, severity: { type: 'string', enum: ['high', 'medium', 'low'] },
  location: { type: 'string' }, summary: { type: 'string' }, fix: { type: 'string' } }, required: ['component', 'severity', 'location', 'summary', 'fix'] } } }, required: ['findings'] }
const FIX_SCHEMA = { type: 'object', properties: { applied: { type: 'array', items: { type: 'string' } }, rejected: { type: 'array', items: { type: 'string' } }, parseClean: { type: 'boolean' } }, required: ['applied', 'rejected', 'parseClean'] }
const TEST_SCHEMA = { type: 'object', properties: {
  passed: { type: 'boolean' },
  results: { type: 'array', items: { type: 'object', properties: { test: { type: 'string' }, passed: { type: 'boolean' }, detail: { type: 'string' } }, required: ['test', 'passed', 'detail'] } },
  curseforgeRequests: { type: 'integer' },
  bugsForFixer: { type: 'array', items: { type: 'object', properties: { component: { type: 'string', enum: ['cli', 'server', 'ui'] }, defect: { type: 'string' } }, required: ['component', 'defect'] } },
}, required: ['passed', 'results', 'curseforgeRequests', 'bugsForFixer'] }
const BUILD_SCHEMA = { type: 'object', properties: { summary: { type: 'string' }, filesChanged: { type: 'array', items: { type: 'string' } }, acceptanceNotes: { type: 'string' } }, required: ['summary', 'filesChanged', 'acceptanceNotes'] }

// ---------- Audit ----------
const AUDITS = [
  { key: 'cli', model: 'haiku', prompt: `${COMMON}
Audit ${CLI} (round ${round}) with fresh eyes. Run ${PARSE(CLI)}. Look for real defects: PS 5.1 incompatibilities, the List[object] @() quirk, stray stdout under -Json, unsafe deletions, records with missing keys, wrong file selection (517/releaseType/pinned/ignored), error paths that abort the run, log/last-run inaccuracies. Only grounded findings, component "cli".` },
  { key: 'server', model: 'haiku', prompt: `${COMMON}
Audit ${SERVER} (round ${round}). Run ${PARSE(SERVER)}. Look for: requests that can hang or crash the loop, unclosed responses, path traversal, JSON encoding bugs, job lifecycle bugs (zombie processes, stale busy flag, log offsets), proxy header/URL mistakes, key leakage in any response or log line, cache bugs, idle/shutdown bugs. Only grounded findings, component "server".` },
  { key: 'ui', model: 'haiku', prompt: `${COMMON}
Audit ${UI} (index.html, style.css, app.js) (round ${round}). Run ${NODECHECK}. Look for: contract mismatches with SPEC section 2, unhandled promise rejections, polling leaks (intervals not cleared), state desync after jobs, XSS via unsanitized HTML/text, dead buttons, CSS overflow/horizontal scroll, focus traps, accessibility basics. Only grounded findings, component "ui".` },
  { key: 'ux', model: 'sonnet', prompt: `${COMMON}
You are a demanding product reviewer comparing this app to the CurseForge desktop app. Setup: recreate ${TESTDIR}, delete ${ROOT}\\addons.json, install two addons via the CLI (powershell -NoProfile -ExecutionPolicy Bypass -File "${CLI}" -AddonsPath "${TESTDIR}" -Add 1521253 -Add 911525 -Json). ${START_SERVER} ${BROWSER} Walk every view and interaction, take screenshots, resize to 1000 px and back. Budget 10 CurseForge requests. Report concrete, grounded UX defects and rough edges (component "ui" unless the API is at fault): confusing labels, missing feedback, layout glitches, inconsistent spacing, unreadable contrast, missing hover/focus, broken flows, anything the CurseForge app does better that is cheap to match. Severity: high = broken/misleading, medium = clearly worse than CurseForge, low = polish.` },
  { key: 'gaps', model: 'haiku', prompt: `${COMMON}
Read ${ROADMAP} and ${UI}\\app.js and ${SERVER}. Compare the implemented feature set to the CurseForge desktop app for WoW (installed list with update indicators, update all/individual, search/browse with categories and sorting, addon pages with description/changelog/screenshots/files, install specific version, ignore/pin, uninstall, settings for release channel and game path, launch game, scan for unmanaged addons, dependency handling, notifications, profiles/export). List gaps that are NOT already covered by ROADMAP items E1-E11 as findings with component "ui" (or server/cli where the backend is the gap), severity low/medium, and a concrete minimal implementation sketch in "fix". Do not report roadmap items.` },
]
const audits = await parallel(AUDITS.map(a => () => agent(a.prompt, { phase: 'Audit', schema: FINDINGS_SCHEMA, model: a.model, agentType: 'general-purpose', label: `audit:${a.key}` })))
// Mandatory fixes handed in via args.fixes: [{component, location, summary, fix}] - always applied, severity high.
const mandatory = ((args && args.fixes) ? args.fixes : []).map(f => ({ component: f.component, severity: 'high', location: f.location || 'see summary', summary: f.summary, fix: f.fix }))
const auditFindings = mandatory.concat(audits.filter(Boolean).flatMap(r => r.findings))
log(`Audit round ${round}: ${auditFindings.length} findings`)

// ---------- Fix audit findings ----------
const fixPrompt = (comp, items, why) => `${COMMON}
You are fixing component "${comp}": ${FILES[comp]} (${why}). Read the file(s) in full. For each finding: verify it against the code; apply it with Edit if real; reject with a one-line reason if not. Keep PowerShell pure ASCII / 5.1. Run the ${CHECK[comp]} at the end. Append a short bullet per applied fix to ${CHANGELOG} under a heading "## Round ${round}" (create the file/heading if missing; do not remove existing content). No network, no real WoW folder.
FINDINGS:
${JSON.stringify(items, null, 2)}`
const auditFixes = await parallel(['cli', 'server', 'ui'].map(comp => () => {
  const items = auditFindings.filter(f => f.component === comp && ((args && args.fixLow) || f.severity !== 'low'))
  if (!items.length) return Promise.resolve({ applied: [], rejected: [], parseClean: true })
  return agent(fixPrompt(comp, items, 'audit findings'), { phase: 'Fix', schema: FIX_SCHEMA, model: 'sonnet', agentType: 'general-purpose', label: `fix:${comp} (audit)` })
}))
const lowFindings = auditFindings.filter(f => f.severity === 'low')

// ---------- Expand (sequential to avoid edit conflicts) ----------
const expansionResults = []
for (const ex of expansions) {
  const r = await agent(`${COMMON}
Implement backlog item ${ex} from ${ROADMAP} (read the whole file; implement exactly that section) across ${CLI}, ${SERVER} and ${UI} as the section requires. Read every file you edit in full first and follow its existing structure and style. Requirements: keep all existing behaviour and tests; PowerShell pure ASCII / 5.1 (remember the List[object] @() quirk); -Json single-document guarantee; UI stays offline (no CDN), sanitized, no inline handlers, consistent with the existing design tokens. When done: append the item's spec (condensed, precise) to ${SPEC} under a heading "## Expansion ${ex}" and a CHANGELOG entry under "## Round ${round}" in ${CHANGELOG}; run ${PARSE(CLI)} , ${PARSE(SERVER)} and ${NODECHECK} and fix any errors. You may smoke-test offline commands against a throwaway folder; no CurseForge requests. Return summary, filesChanged, and acceptanceNotes (how a tester should verify, referencing the ACCEPTANCE line of the roadmap item).`,
    { phase: 'Expand', schema: BUILD_SCHEMA, model: 'sonnet', agentType: 'general-purpose', label: `expand:${ex}` })
  expansionResults.push({ id: ex, result: r })
  log(`Expansion ${ex}: ${r ? 'done' : 'no result'}`)
}

// ---------- Review the expanded code ----------
const LENSES = [
  { key: 'cli', comp: 'cli', prompt: `Review ${CLI}: PS 5.1 compatibility (run ${PARSE(CLI)}), -Json integrity, filesystem safety of any new code paths (rollback, backups, dependency parsing), regression risks to existing behaviour.` },
  { key: 'server', comp: 'server', prompt: `Review ${SERVER}: run ${PARSE(SERVER)}; robustness of new routes/jobs, contract fidelity to SPEC (including the new Expansion sections), key leakage, path safety of new file operations (export/import/backups/open targets), state.json persistence.` },
  { key: 'ui', comp: 'ui', prompt: `Review ${UI}: run ${NODECHECK}; new views/controls wired correctly to the contract in SPEC (incl. Expansion sections), no leaks/intervals left dangling, sanitization, keyboard/focus, light theme completeness if present, no console errors likely.` },
  { key: 'contract', comp: 'ui', prompt: `Cross-check ${CLI} flags/JSON vs ${SERVER} usage vs ${UI}\\app.js calls vs ${SPEC} (all sections including Expansion ones). File each mismatch against the deviating component.` },
]
const reviews = await parallel(LENSES.map(l => () => agent(`You are an adversarial code reviewer. ${COMMON}
${l.prompt}
Report ONLY real defects or spec violations grounded in the code, with component, severity, location, summary, concrete fix. Empty list is valid.`, { phase: 'Review', schema: FINDINGS_SCHEMA, model: 'haiku', agentType: 'general-purpose', label: `review:${l.key}` })))
const reviewFindings = reviews.filter(Boolean).flatMap(r => r.findings)
log(`Review round ${round}: ${reviewFindings.length} findings`)
const reviewFixes = await parallel(['cli', 'server', 'ui'].map(comp => () => {
  const items = reviewFindings.filter(f => f.component === comp)
  if (!items.length) return Promise.resolve({ applied: [], rejected: [], parseClean: true })
  return agent(fixPrompt(comp, items, 'review findings on expansions'), { phase: 'Fix', schema: FIX_SCHEMA, model: 'sonnet', agentType: 'general-purpose', label: `fix:${comp} (review)` })
}))

// ---------- Tests ----------
const acceptance = expansionResults.map(e => `- ${e.id}: ${e.result ? e.result.acceptanceNotes : 'see ROADMAP'}`).join('\n')
const TESTS = {
  cli: { phase: 'Test CLI', prompt: `${COMMON}
Test ${CLI} in ${TESTDIR} (recreate fresh). Run as: powershell -NoProfile -ExecutionPolicy Bypass -File "${CLI}" -AddonsPath "${TESTDIR}" <args>. Budget 25 CurseForge requests; only projects 1521253 and 911525. settings.json is next to the script (restore any edits).
REGRESSION (must all pass): (a) -Add 1521253 -Json is exactly one JSON doc with Installed row and a full record (name, author, fileId, folders, ignoreUpdates, pinnedFileId); (b) plain sync -> Up-to-date, no download; (c) -Files 911525 -Json lists files; -Add 911525 -FileId <second newest retail id> -> pinned; sync -> Pinned; -Unpin then sync -> Updated; (d) -Ignore/-Unignore semantics; (e) -Scan -Json lists an orphan folder with title/version; (f) -DryRun with fileId=1 -> Would-update and no writes; (g) -Remove both -> [] ; (h) ${PARSE(CLI)} clean.
EXPANSION ACCEPTANCE for this round (read the ACCEPTANCE lines in ${ROADMAP} and the SPEC Expansion sections; test the CLI-side parts):
${acceptance}
Report defects precisely in bugsForFixer (component cli unless clearly elsewhere). Do not edit code. Clean ${TESTDIR} at the end.` },
  server: { phase: 'Test Server', prompt: `${COMMON}
Test ${SERVER}. Recreate ${TESTDIR}; delete ${ROOT}\\addons.json and ${ROOT}\\state.json if present. ${START_SERVER} Budget 25 CurseForge requests. Use Invoke-RestMethod/Invoke-WebRequest -UseBasicParsing.
REGRESSION: static / and css/js with correct MIME; traversal blocked; /api/state shape (no raw key); add job 1521253 -> done with Installed; second job while busy -> 409; /api/addons/{id}/files; ignore/unpin; install job with fileId -> pinned; scan + scan/delete guards; settings GET/PUT masking + test-key with a bogus key -> ok:false; /api/cf/* -> 409 no-key without a key; malformed body -> 400 and server alive; remove job; shutdown exits.
EXPANSION ACCEPTANCE for this round (server-side parts; read ${ROADMAP} ACCEPTANCE lines and SPEC Expansion sections):
${acceptance}
SPACED-PATH REGRESSION (mandatory): copy addon-sync.ps1, addon-server.ps1, settings.json and the ui folder into a NEW directory whose name contains spaces and parentheses, e.g. ${ROOT}\\..\\Addon Sync (x86) test\\ (create it; write an empty addons.json there), start a second server from THAT directory on port 47898 with -AddonsPath "${TESTDIR}", run one add job (1521253) and one check job and confirm both reach state done with results (this guards the quoting of paths passed to the child process), then shut it down and delete that directory.
FAILURE-PATH REGRESSION (mandatory): start a third server instance on port 47897 from a directory that contains addon-server.ps1 but NO addon-sync.ps1 (so the child powershell exits immediately with an error); POST a check job; the server must stay responsive (GET /api/ping and GET /api/jobs/{id} must answer within 5 s) and the job must end in state failed with a non-empty error. Shut it down.
Do NOT test /api/open targets that open windows (you may test that invalid targets are rejected) and never start a launch job. Report defects in bugsForFixer with the right component. Always shut the server down.` },
  ui: { phase: 'Test UI', prompt: `${COMMON}
Browser smoke test. Recreate ${TESTDIR}; delete ${ROOT}\\addons.json and ${ROOT}\\state.json; install 1521253 via the CLI (-Add 1521253 -Json with -AddonsPath "${TESTDIR}"). ${START_SERVER} ${BROWSER} Budget 15 CurseForge requests. Screenshot every view.
REGRESSION: zero console errors; My Addons row with version + Up to date chip; no horizontal scroll at default and at width 1000; Check for updates runs and completes; kebab -> Versions drawer; row click -> drawer with no-key prompts; Browse no-key panel + Install by Project ID (911525) works; Settings release channel persists via PUT; ignore/unignore chip; uninstall via kebab.
EXPANSION ACCEPTANCE for this round (UI parts; read ${ROADMAP} ACCEPTANCE lines and SPEC Expansion sections):
${acceptance}
Never click Update & Play / Launch WoW. Report defects precisely (component ui, or server/cli if the API is at fault). Shut the server down, remove installed test addons via the CLI, clean ${TESTDIR}.` },
}
const testFixJobs = (test) => {
  const byComp = {}
  for (const b of test.bugsForFixer) { (byComp[b.component] = byComp[b.component] || []).push(b.defect) }
  return Object.keys(byComp).map(comp => ({ comp, prompt: `${COMMON}
Component "${comp}" (${FILES[comp]}) failed testing in round ${round}. Read the file(s) in full, fix EVERY defect below with Edit (spec, PS 5.1, pure ASCII), run the ${CHECK[comp]}, and add a CHANGELOG bullet under "## Round ${round}". No network, no real WoW folder.
DEFECTS:
${JSON.stringify(byComp[comp], null, 2)}
FULL TEST RESULTS:
${JSON.stringify(test.results, null, 2)}` }))
}
const outcomes = {}
for (const stage of ['cli', 'server', 'ui']) {
  let t = null
  for (let r = 1; r <= 3; r++) {
    t = await agent(TESTS[stage].prompt, { phase: TESTS[stage].phase, schema: TEST_SCHEMA, model: 'sonnet', agentType: 'general-purpose', label: `test:${stage} round ${round}.${r}` })
    if (!t) { log(`${stage} test ${r}: no result`); break }
    log(`${stage} test ${r}: ${t.passed ? 'PASSED' : 'FAILED'} (${t.results.filter(x => x.passed).length}/${t.results.length}), ${t.curseforgeRequests} CF requests`)
    if (t.passed || r === 3) break
    const jobs = testFixJobs(t)
    if (!jobs.length) break
    await parallel(jobs.map(j => () => agent(j.prompt, { phase: 'Fix', schema: FIX_SCHEMA, model: 'sonnet', agentType: 'general-purpose', label: `fix:${j.comp} after ${stage} ${r}` })))
  }
  outcomes[stage] = t
}

return { round, auditFindingsCount: auditFindings.length, auditFindings, lowFindings, auditFixes, expansions: expansionResults, reviewFindings, reviewFixes, outcomes }
