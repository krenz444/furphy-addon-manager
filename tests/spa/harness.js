/* ==========================================================================
   tests\spa\harness.js

   Drives ui\index.html (a same-origin COPY, served alongside this file by
   a plain python http.server - see tests\spa\Run-SpaHarness.ps1) inside an
   iframe, exercising it under several ?mock=1&test=1 query-string variants,
   and writes one aggregated JSON result object into <pre id="results"> for
   Run-SpaHarness.ps1 to read back out of a --dump-dom capture.

   Every check is a plain synchronous assertion appended to the CURRENT
   phase's list via check(name, passed, detail); nothing throws - a check
   that itself errors is caught and recorded as a failure with the error
   message, so one bad phase never stops the rest from running (and the
   <pre> always has a real BEST-EFFORT result, updated after every phase,
   even if the whole run is later cut short by the harness's own
   virtual-time budget).
   ========================================================================== */
(function () {
  "use strict";

  const results = { phases: [], startedAt: new Date().toISOString(), complete: false };
  let currentPhase = null;

  function statusEl() { return document.getElementById("status"); }
  function resultsEl() { return document.getElementById("results"); }

  function writeResults() {
    try {
      resultsEl().textContent = JSON.stringify(results, function (k, v) { return (typeof k === "string" && k.indexOf("_") === 0) ? undefined : v; });
    } catch (e) { /* keep going */ }
  }

  function beginPhase(name) {
    if (currentPhase) { currentPhase.durationMs = Date.now() - currentPhase._startedAtMs; }
    currentPhase = { name: name, checks: [], consoleErrors: [], startedAt: new Date().toISOString(), _startedAtMs: Date.now() };
    results.phases.push(currentPhase);
    statusEl().textContent = "phase: " + name;
    writeResults();
  }

  function check(name, passed, detail) {
    currentPhase.checks.push({ name: name, passed: !!passed, detail: detail === undefined ? null : String(detail) });
    writeResults();
  }

  function checkTry(name, fn) {
    try {
      const r = fn();
      check(name, !!r, r === false ? "returned false" : null);
    } catch (e) {
      check(name, false, "threw: " + (e && e.message ? e.message : e));
    }
  }

  function wait(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }

  function iframeEl() { return document.getElementById("spa-frame"); }

  function loadFrame(query) {
    return new Promise(function (resolve, reject) {
      const frame = iframeEl();
      const win = null;
      let settled = false;

      function onLoad() {
        frame.removeEventListener("load", onLoad);
        // Wire the iframe's own console.error/window.onerror BEFORE we do
        // anything else, so every check below can see errors that happen
        // during the rest of this phase (readiness polling included).
        try {
          const w = frame.contentWindow;
          const origError = w.console.error.bind(w.console);
          w.console.error = function () {
            try { currentPhase.consoleErrors.push(Array.prototype.slice.call(arguments).join(" ")); } catch (e) { }
            return origError.apply(null, arguments);
          };
          w.addEventListener("error", function (ev) {
            try { currentPhase.consoleErrors.push("window.onerror: " + (ev && ev.message ? ev.message : String(ev))); } catch (e) { }
          });
          // Neutralize any real OS-level file-save click (e.g. Settings >
          // Advanced's "Save addon list" export, ui\app.js's own
          // Blob+<a download> pattern) BEFORE it can ever fire - confirmed
          // live while developing this harness that a real anchor+Blob
          // download click inside msedge --headless=new (no explicit CDP
          // download policy available from this plain command-line
          // invocation) can leave the whole browser process hung for
          // MINUTES after the page's own JS has already finished and
          // written its results, even though the identical click in a
          // real, non-headless Chromium tab returns instantly with zero
          // console errors. The app's click handler runs its download
          // step synchronously and shows its toast unconditionally right
          // after - a real click() call is never awaited by anything, so
          // a no-op here still lets every check that matters (the toast
          // text) exercise the real code path.
          const origAnchorClick = w.HTMLAnchorElement.prototype.click;
          w.HTMLAnchorElement.prototype.click = function () {
            if (this.hasAttribute("download")) return;
            return origAnchorClick.apply(this, arguments);
          };
        } catch (e) {
          // Cross-origin or not-yet-ready - shouldn't happen (same origin
          // by construction), but never let this block the phase.
        }
        settled = true;
        resolve(frame.contentWindow);
      }
      frame.addEventListener("load", onLoad);
      frame.src = "/index.html" + query;
      setTimeout(function () { if (!settled) reject(new Error("iframe did not fire load within 10s: " + query)); }, 10000);
    });
  }

  function waitForReady(win, timeoutMs) {
    const deadline = Date.now() + (timeoutMs || 8000);
    return new Promise(function (resolve, reject) {
      (function poll() {
        try {
          if (win.__furphyTest && win.__furphyTest.ready) { resolve(win.__furphyTest); return; }
        } catch (e) { /* ignore, keep polling */ }
        if (Date.now() > deadline) { reject(new Error("window.__furphyTest.ready never became true")); return; }
        setTimeout(poll, 100);
      })();
    });
  }

  function q(win, sel) { return win.document.querySelector(sel); }
  function qa(win, sel) { return Array.prototype.slice.call(win.document.querySelectorAll(sel)); }
  // This app's own convention (see its source comments) is toggling
  // visibility with the `hidden` IDL attribute, never style.display - some
  // containers (e.g. #browse-cf-panel) are `display:contents`, which always
  // reports a null offsetParent/zero getBoundingClientRect even while
  // genuinely shown, so `hidden` alone is the correct, authoritative check
  // here (confirmed against the real app - do not "improve" this with an
  // offsetParent/rect check without re-verifying against display:contents
  // nodes first).
  function visible(el) { return !!el && !el.hidden; }
  function text(el) { return el ? el.textContent.replace(/\s+/g, " ").trim() : ""; }

  // UX-SPEC.md section 11's banned-term list, same source list as
  // tests\static\Test-BannedTerms.ps1 (see that file's own header comment
  // for the precision reasoning) - here it runs against real RENDERED body
  // text, the authoritative live-DOM check that static file said it needed.
  const BANNED_PHRASES = ["project id", "file id", "release type", "interface version",
    "stale-minor", "adopting", "untracked", "keyless", "instawow-data", "addon-radar.com"];
  const BANNED_WORDS = ["toc", "compat", "stale", "adopt", "digest", "indexed"];

  function scanBannedTerms(win) {
    const body = win.document.body.textContent || "";
    const bodyLower = body.toLowerCase();
    const hits = [];
    BANNED_PHRASES.forEach(function (p) { if (bodyLower.indexOf(p) !== -1) hits.push(p); });
    BANNED_WORDS.forEach(function (w) {
      const re = new RegExp("\\b" + w + "\\b", "i");
      if (re.test(body)) hits.push(w);
    });
    return hits;
  }

  async function clickAndSettle(win, el, ms) {
    el.click();
    await wait(ms || 250);
  }

  // ------------------------------------------------------------------
  // Phase 1: default single-flavour mock - the bulk of the acceptance
  // checklist (UX-SPEC.md section 11 / FLAVORS-SPEC.md section 8's own
  // ?mock=1 bullet). Runs FIRST and only once per page origin, before any
  // ?theme= variant below ever writes to localStorage - see that phase's
  // own comment for why order matters here.
  // ------------------------------------------------------------------
  async function phaseDefault() {
    beginPhase("default (?mock=1&test=1)");
    const win = await loadFrame("?mock=1&test=1");
    await waitForReady(win, 8000);
    check("readiness hook fired", true);

    // Freshness headline: exactly one on screen (sidebar dot-only + the
    // My Addons headline text - UX-SPEC.md 2.2/11). P3 perf-pass fix: the
    // old version only checked whether EACH CONTAINER'S textContent was
    // non-empty (text(sidebar).length > 0 / text(myaddons).length > 0) -
    // that only ever proves "the sidebar container has some text" vs "the
    // My Addons container has some text", never how many actual headline
    // ELEMENTS live inside a container. A regression that rendered the
    // headline TWICE inside #myaddons-freshness (Components.Freshness
    // appending instead of replacing, say) would still read as
    // "myaddonsHasText" and pass. Count the real `.freshness-headline`
    // elements (the class both the plain-span and Retry-button variants in
    // Components.Freshness.render carry) inside each container instead -
    // the sidebar's dotOnly mount must have NONE (it renders a colored dot
    // only, no headline text - see that function's own comment on why),
    // My Addons must have EXACTLY one; 0 or 2+ in either container is a
    // real failure now, not silently passed.
    checkTry("exactly one freshness headline element (sidebar has none, My Addons has exactly one - duplicates now fail)", function () {
      const sidebarHeadlines = qa(win, "#sidebar-freshness .freshness-headline");
      const myaddonsHeadlines = qa(win, "#myaddons-freshness .freshness-headline");
      if (sidebarHeadlines.length !== 0) return false;
      if (myaddonsHeadlines.length !== 1) return false;
      return text(myaddonsHeadlines[0]).length > 0;
    });

    checkTry("table has exactly 5 columns", function () {
      const ths = qa(win, "#myaddons-table thead th");
      return ths.length === 5;
    });

    checkTry("every addon row shows exactly one status pill", function () {
      const rows = qa(win, "#myaddons-tbody tr");
      if (rows.length === 0) return false;
      return rows.every(function (r) { return r.querySelectorAll(".chip").length === 1; });
    });

    checkTry("filter chips include All and Updates (permanent per UX-SPEC.md 3.4)", function () {
      const chips = qa(win, "#myaddons-filters .filter-chip").map(function (b) { return text(b); });
      return chips.some(function (t) { return /^All\d/.test(t); }) && chips.some(function (t) { return /^Updates\d/.test(t); });
    });

    // Switcher absent at 1 visible flavour - inspect the DOM directly, not
    // just visual hiding (FLAVORS-SPEC.md section 8's own acceptance line).
    checkTry("flavour switcher DOM entirely absent at 1 flavour", function () {
      return !q(win, "#flavour-switcher");
    });

    // Update all: of the default mock roster, Auctionator and Simple Damage
    // Meter both have an update and are NOT ignored; Bagnon also has one but
    // is ignoreUpdates:true, so it must be excluded from the count - button
    // visible with count 2, never 3.
    checkTry("Update all visible, count excludes ignored addons", function () {
      const btn = q(win, "#btn-update-all");
      return visible(btn) && /\(2\)/.test(text(btn));
    });

    // Drawer real name, never "Project N" (UX-SPEC.md 3.5/11).
    const rows = qa(win, "#myaddons-tbody tr");
    const auctionatorRow = rows.filter(function (r) { return /Auctionator/.test(text(r)); })[0];
    if (auctionatorRow) {
      const nameCell = auctionatorRow.querySelector(".addon-name-text") || auctionatorRow;
      await clickAndSettle(win, nameCell, 300);
      checkTry("drawer opens with the real addon name, not 'Project N'", function () {
        const header = text(q(win, "#drawer-header"));
        return header.indexOf("Auctionator") !== -1 && !/^Project \d/.test(header);
      });
      const closeBtn = q(win, "#drawer-close");
      if (closeBtn) await clickAndSettle(win, closeBtn, 150);
    } else {
      check("drawer opens with the real addon name, not 'Project N'", false, "Auctionator row not found");
    }

    // Mock job flow: Update all -> "sync" kind, 1 target (Auctionator),
    // forced to fail by the mock (Mock.runProgressJob's own forced-fail
    // selection - see ui\app.js) - one real job exercising BOTH the
    // in-flight progress bar and the done-with-failure/Retry views without
    // needing two separate jobs.
    // CHANGELOG Round 21 fix (App.onJobStarted): starting a job now
    // re-fetches /api/state immediately, so the freshness headline flips
    // to "Checking…" the instant the job starts rather than sitting on
    // its pre-job text until the job finishes (previously only the NEXT
    // idle-poll tick would have picked up the change). Capture the
    // pre-click headline text here so the check right after the click
    // below can prove it actually changed, not just that a headline
    // element exists (which the phase's earlier "exactly one freshness
    // headline" check already covers).
    const freshnessHeadlineBeforeJob = text(q(win, "#myaddons-freshness"));

    const updateAllBtn = q(win, "#btn-update-all");
    if (updateAllBtn && visible(updateAllBtn)) {
      await clickAndSettle(win, updateAllBtn, 150);

      // The mock's own ~120-240ms /api/state delay (Mock.handle) plus the
      // fire-and-forget reloadState() call from onJobStarted means the
      // flip can lag the click by a tick or two - poll briefly rather
      // than asserting on a single snapshot, but independently of (and
      // well before) the progress-bar poll below.
      const headlineDeadline = Date.now() + 1500;
      let headlineFlipped = false;
      while (Date.now() < headlineDeadline) {
        const nowHeadline = text(q(win, "#myaddons-freshness"));
        if (nowHeadline !== freshnessHeadlineBeforeJob && /Checking/.test(nowHeadline)) { headlineFlipped = true; break; }
        await wait(100);
      }
      check("freshness headline flips to 'Checking…' immediately on job start, not frozen on stale text (Round 21 onJobStarted fix)",
        headlineFlipped, "before=\"" + freshnessHeadlineBeforeJob + "\"");

      // Poll rather than a single fixed-delay snapshot: this app also runs
      // an idle-poll reloadState() shortly after load (App.startIdlePolling)
      // which can transiently re-render the job panel from a just-fetched
      // /api/state snapshot around the same moment the job itself starts -
      // a real, harmless overlap (confirmed live: the progress bar always
      // settles into place within ~1-2s regardless), not something a fixed
      // 400ms check can reliably outrun.
      const progressDeadline = Date.now() + 4000;
      let sawProgress = false;
      // Round 28 (SPEC.md section I): sample the running label's DISTINCT
      // texts across the whole job, not just once - the mock's "sync" plan
      // (Auctionator + Simple Damage Meter, one forced to fail) walks
      // checking -> downloading -> installing -> a terminal phase per
      // target, so a single snapshot could land on any one of those and
      // miss the wording this round actually changed. labelSamples lets the
      // checks below prove every phase this job passes through renders the
      // new phase-aware text, and NEVER the old buggy "Updating i of N
      // addons" line the tray-tooltip incident's own SPA-side copy of.
      const labelSamples = [];
      let lastLabel = null;
      function sampleLabel() {
        const t = text(q(win, "#job-progress-label"));
        if (t && t !== lastLabel) { labelSamples.push(t); lastLabel = t; }
      }
      while (Date.now() < progressDeadline) {
        const wrap = q(win, "#job-progress-wrap");
        const bar = q(win, "#job-progress-bar");
        if (visible(wrap) && bar && bar.tagName === "PROGRESS" && bar.hasAttribute("value")) sawProgress = true;
        sampleLabel();
        await wait(150);
      }
      check("job panel shows a determinate <progress> bar mid-flight", sawProgress);
      checkTry("Details disclosure is collapsed by default", function () {
        const details = q(win, "#job-details");
        return details && !details.open;
      });

      // Poll to completion - runProgressJob spreads its steps across ~6s
      // regardless of target count (ui\app.js's own design comment).
      const jobDeadline = Date.now() + 9000;
      let done = false;
      while (Date.now() < jobDeadline) {
        sampleLabel();
        const resultsBox = q(win, "#job-results");
        if (resultsBox && !resultsBox.hidden && resultsBox.children.length > 0) { done = true; break; }
        await wait(200);
      }
      checkTry("job reaches a done-with-failure state within 9s", function () { return done; });

      // Round 28: the new phase-aware Job Panel wording (SPEC.md section I),
      // asserted against the samples collected across the whole run above.
      checkTry("job panel label reads 'Checking addons (N of M)' while phase is queued/checking", function () {
        return labelSamples.some(function (t) { return /^Checking addons \(\d+ of \d+\)$/.test(t); });
      });
      checkTry("job panel label reads 'Checking addons (N of M) - K update(s) found so far' once an earlier addon updated", function () {
        return labelSamples.some(function (t) { return /^Checking addons \(\d+ of \d+\) - \d+ updates? found so far$/.test(t); });
      });
      checkTry("job panel label reads 'Updating <Name> (K of K)' while phase is downloading/installing (k always equals m, and k>=1 - never '(0 of 0)', which would say 'Updating' while the numbers say zero updates)", function () {
        return labelSamples.some(function (t) {
          const m = /^Updating (.+) \((\d+) of (\d+)\)$/.exec(t);
          return !!m && m[2] === m[3] && parseInt(m[2], 10) >= 1;
        });
      });
      checkTry("job panel label never renders the old 'Updating i of N addons' wording (the tray-tooltip incident's SPA-side copy of the same bug)", function () {
        return !labelSamples.some(function (t) { return /^Updating \d+ of \d+ addons/.test(t); });
      });
      checkTry("results list has one failed row with an inline Retry (Mock.runProgressJob forces exactly one target to fail)", function () {
        const rowsR = qa(win, "#job-results .job-result-row");
        if (rowsR.length === 0) return false;
        const failedRows = rowsR.filter(function (r) { return r.classList.contains("is-failed"); });
        if (failedRows.length !== 1) return false;
        const retryBtn = Array.prototype.slice.call(failedRows[0].querySelectorAll("button")).filter(function (b) { return /Retry/.test(text(b)); })[0];
        return !!retryBtn;
      });
      // Let the panel settle / job fully finish before moving on.
      await wait(300);
    } else {
      check("job panel shows a determinate <progress> bar mid-flight", false, "Update all button not visible/clickable");
    }

    // CHANGELOG Round 21: Settings > Advanced's Save/Load addon list
    // (export/import) flow - exercised here, still in My Addons view,
    // straight after the job above finishes (both #btn-export/#btn-import
    // live in Settings > Advanced markup but this app's DOM keeps them
    // present regardless of the current view, same as every other
    // always-mounted control this file already clicks without navigating
    // first). Save runs the app's real click handler end to end (a real
    // Blob + <a download> click) except for the final native file-save
    // step itself, which loadFrame's own HTMLAnchorElement.prototype.click
    // override above turns into a no-op purely to keep this harness safe
    // under msedge --headless=new (see that override's own comment) - the
    // Toast this check asserts on is shown unconditionally right after the
    // (now-neutralized) click, so it still proves the real code path ran.
    // Load is fed a canned File via a real DataTransfer/FileList
    // assignment (the standard, real way to drive a file <input> without
    // an OS picker) - Components.Dialogs.confirm's own copy is asserted
    // against the file's real contents, not guessed.
    const exportBtn = q(win, "#btn-export");
    if (exportBtn) {
      await clickAndSettle(win, exportBtn, 300);
      checkTry("Save (export) shows a 'Saved N addon(s)' toast", function () {
        const toasts = qa(win, "#toast-container .toast-body").map(function (el) { return text(el); });
        return toasts.some(function (t) { return /^Saved \d+ addon\(s\)\.$/.test(t); });
      });
    } else {
      check("Save (export) shows a 'Saved N addon(s)' toast", false, "#btn-export not found");
    }

    const importInput = q(win, "#import-file-input");
    if (importInput) {
      // One brand-new addon (will be added) + one already in the default
      // mock roster keyed by projectId (Auctionator, 68304 - will be
      // reported "already present") so the confirm dialog's own arithmetic
      // is checked against a real, known mixed file, not just a shape.
      const importPayload = {
        format: "wow-addon-manager/1",
        exportedAt: new Date().toISOString(),
        addons: [
          { projectId: 999001, name: "Totally New Addon", pinnedFileId: null, ignoreUpdates: false, releaseType: null },
          { projectId: 68304, name: "Auctionator", pinnedFileId: null, ignoreUpdates: false, releaseType: null }
        ]
      };
      const importFile = new win.File([JSON.stringify(importPayload)], "addons-export.json", { type: "application/json" });
      const dt = new win.DataTransfer();
      dt.items.add(importFile);
      importInput.files = dt.files;
      importInput.dispatchEvent(new win.Event("change", { bubbles: true }));

      // Poll rather than a single fixed-delay snapshot: the change handler
      // awaits file.text() + JSON.parse before opening the dialog, which
      // was observed to take noticeably longer than one 400ms wait under
      // msedge --headless=new's own virtual-time-budget policy (confirmed
      // live while developing this check - a real Chromium tab with no
      // virtual-time emulation opened the dialog well inside 400ms every
      // time, but the headless/virtual-time path needed longer).
      const dialogDeadline = Date.now() + 3000;
      let dialogShown = false;
      while (Date.now() < dialogDeadline) {
        if (visible(q(win, "#dialog-confirm"))) { dialogShown = true; break; }
        await wait(100);
      }

      checkTry("Load shows a confirm dialog with the real added/present counts from the file", function () {
        if (!dialogShown) return false;
        const msg = text(q(win, "#confirm-message"));
        return msg === "2 addon(s) in the file — 1 will be added, 1 already present.";
      });

      const confirmOkBtn = q(win, "#confirm-ok");
      if (dialogShown && confirmOkBtn) {
        await clickAndSettle(win, confirmOkBtn, 100);

        // Poll for the job panel/title rather than one fixed-delay
        // snapshot: Actions.importAddons awaits Api.importAddons (the
        // mock's own ~120-240ms artificial delay) before App.onJobStarted
        // ever shows the panel, so a single ~100ms check after the click
        // is unreliable (observed failing under headless/virtual-time
        // load while developing this check, even though the job title
        // does appear - just a little later).
        const titleDeadline = Date.now() + 2000;
        let titleShown = false;
        while (Date.now() < titleDeadline) {
          const panel = q(win, "#job-panel");
          if (panel && !panel.hidden && /Loading addon list/.test(text(q(win, "#job-title")))) { titleShown = true; break; }
          await wait(100);
        }
        check("job title reads 'Loading addon list' while the import job runs", titleShown);

        const importDeadline = Date.now() + 4000;
        let importDone = false;
        while (Date.now() < importDeadline) {
          const job = win.__furphyTest && win.__furphyTest.Store.state.job;
          if (job && job.kind === "import" && job.state === "done") { importDone = true; break; }
          await wait(150);
        }
        checkTry("import job completes with the real Installed/Skipped outcome for the two file entries", function () {
          const job = win.__furphyTest && win.__furphyTest.Store.state.job;
          if (!importDone || !job || !Array.isArray(job.results)) return false;
          const installed = job.results.some(function (r) { return r.projectId === 999001 && r.status === "Installed"; });
          const skipped = job.results.some(function (r) { return r.projectId === 68304 && r.status === "Skipped"; });
          return installed && skipped;
        });
      } else {
        check("job title reads 'Loading addon list' while the import job runs", false, "confirm dialog never appeared/#confirm-ok not found");
        check("import job completes with the real Installed/Skipped outcome for the two file entries", false, "confirm dialog never confirmed");
      }
      await wait(300);
    } else {
      check("Load shows a confirm dialog with the real added/present counts from the file", false, "#import-file-input not found");
    }

    // Get new addons: segmented Wago|CurseForge, Wago full-width with WAGO
    // badges only, CurseForge -> fallback panel (no host param).
    const navBrowse = win.document.querySelector("[data-view='browse']") || Array.prototype.slice.call(qa(win, ".nav-item")).filter(function (b) { return /Get new addons/i.test(text(b)); })[0];
    if (navBrowse) await clickAndSettle(win, navBrowse, 200);
    checkTry("segmented Wago/CurseForge tabs present", function () {
      return !!q(win, "#tab-wago") && !!q(win, "#tab-curseforge");
    });
    // Wago auto-searches with an empty query on first render (Views.browse
    // render()) - wait for the mock's own ~120-240ms delay plus render.
    await wait(700);
    checkTry("Wago grid rows carry a WAGO badge only, never CurseForge", function () {
      const badges = qa(win, "#browse-grid .source-badge");
      if (badges.length === 0) return false;
      return badges.every(function (b) { return b.classList.contains("is-wago") && !b.classList.contains("is-cf"); });
    });
    const cfTab = q(win, "#tab-curseforge");
    if (cfTab) await clickAndSettle(win, cfTab, 300);
    checkTry("CurseForge segment shows the fallback panel with no host param", function () {
      const fallback = q(win, "#browse-cf-fallback");
      const panel = q(win, "#browse-cf-panel");
      return visible(fallback) && !visible(panel);
    });

    // Settings: Essentials word count, no key row, Advanced collapsed.
    const navSettings = Array.prototype.slice.call(qa(win, ".nav-item")).filter(function (b) { return /Settings/i.test(text(b)); })[0];
    if (navSettings) await clickAndSettle(win, navSettings, 200);
    checkTry("Essentials (Updates+Appearance) running prose is <= 60 words", function () {
      // UX-SPEC.md section 11's own acceptance line: "copy-pasting the
      // visible section text" means the running PROSE, not every control's
      // own label (button/toggle/theme-swatch text is a control, not prose -
      // the swatch grid's 14 theme names alone would blow well past 60 if
      // counted, and section 6.1 explicitly documents it as zero-prose).
      // This app's own prose lines are consistently `.muted-text`/`p`
      // elements (the two-line auto-update explainer + the one background-
      // updates status line - see UX-SPEC.md 6.1's Round 17/18 carve-outs) -
      // count only those, matching how this codebase actually marks up
      // "helper prose" everywhere else (see tests\static\Test-BannedTerms.ps1's
      // own header comment on this same distinction).
      const updates = q(win, "#settings-updates");
      const appearance = q(win, "#settings-appearance");
      const combined = [updates, appearance].map(function (sec) {
        if (!sec) return "";
        return Array.prototype.slice.call(sec.querySelectorAll("p, .muted-text"))
          .filter(function (el) { return visible(el); })
          .map(function (el) { return text(el); }).join(" ");
      }).join(" ");
      const words = combined.split(/\s+/).filter(Boolean);
      return words.length > 0 && words.length <= 60;
    });
    checkTry("no CurseForge API key row anywhere in Settings", function () {
      const settingsView = q(win, "#view-settings");
      return !/curseforge key|api key/i.test(text(settingsView));
    });
    checkTry("Advanced is collapsed by default on load", function () {
      const details = q(win, "#settings-advanced");
      // Freshly reloaded page this phase - collapsed-by-default is the
      // real assertion; a later phase may have interacted with a
      // different iframe instance, never this one.
      return details && !details.open;
    });
    checkTry("Advanced contains both flavour-era toggles (show-test-realms, alpha)", function () {
      return !!q(win, "#toggle-show-test-realms") && !!q(win, "#toggle-alpha");
    });

    // Round 28 (SPEC.md section I): the Settings background-updates status
    // line now reads the SAME core sentence the tray tooltip/menu use
    // (Views.settings.backgroundStatusText's new computeCoreText branch),
    // sourced from tray-state.json's new `status` field rather than the
    // old lastResult-only text table. Off by default in a fresh mock
    // profile; turning it on drives Mock's fabricated "done_clean" cycle
    // (ui\app.js's /api/tray/start handler) through that exact code path.
    checkTry("Background updates status line reads 'Background updates off' before enabling", function () {
      return text(q(win, "#updates-background-status")) === "Background updates off";
    });
    const bgToggle = q(win, "#toggle-background-updates");
    if (bgToggle) {
      await clickAndSettle(win, bgToggle, 900);
      checkTry("Settings status line uses the tray's status-driven core sentence ('Everything's up to date - checked HH:MM - next ...') after enabling background updates, matching the tooltip's own done_clean wording verbatim - never a second, independently-worded text table", function () {
        const t = text(q(win, "#updates-background-status"));
        return /^Everything's up to date - checked \d{2}:\d{2} - next (tomorrow )?\d{2}:\d{2}$/.test(t);
      });
      // Leave it off again so later phases (and a re-run of this same
      // phase) start from the same fresh-profile baseline.
      await clickAndSettle(win, bgToggle, 400);
    } else {
      check("Settings status line uses the tray's status-driven core sentence after enabling background updates", false, "#toggle-background-updates not found");
    }

    checkTry("theme grid has 16 radios in THEMES-SPEC.md section 8/9 order, tokyo-rain checked on a fresh profile", function () {
      const expectedOrder = ["tokyo-rain", "arcane-library", "vaporwave", "lofi", "dark", "light", "terminal-green",
        "arctic-ice", "art-deco-gold", "alpine-dawn", "matcha", "desert-night", "brushed-steel",
        "aurora-sky", "strawberry-cream", "snow-day"];
      const tiles = qa(win, "#theme-grid [role='radio']");
      if (tiles.length !== 16) return false;
      const slugs = tiles.map(function (t) { return t.dataset.themeValue; });
      const orderOk = slugs.every(function (s, i) { return s === expectedOrder[i]; });
      const checkedTile = q(win, "#theme-grid [aria-checked='true']");
      const checkedSlug = checkedTile && checkedTile.dataset.themeValue;
      return orderOk && checkedSlug === "tokyo-rain" && win.document.documentElement.dataset.theme === "tokyo-rain";
    });

    checkTry("no banned UX-SPEC.md section 11 term appears in rendered body text", function () {
      const hits = scanBannedTerms(win);
      if (hits.length > 0) { check("banned terms found (detail)", false, hits.join(", ")); }
      return hits.length === 0;
    });

    // Round 34 (REMOVAL-SPEC.md): Eric asked to remove every feature that
    // launches or auto-updates-before-launching WoW - the sidebar's Update &
    // Play / Launch WoW buttons and the Settings auto-update-on-launch row
    // are gone for good. Scans real rendered body text (not just markup) so
    // a regression that re-adds any of this copy anywhere in the app fails
    // here, mirroring tests\static\Test-BannedTerms.ps1's own addition of
    // these same phrases for the static-HTML sweep.
    checkTry("no launch-feature strings anywhere in the rendered DOM (Update & Play / Launch WoW / before WoW starts - Round 34 removed WoW launching entirely)", function () {
      const bodyText = win.document.body.textContent || "";
      const launchPhrases = ["Update & Play", "Launch WoW", "before WoW starts", "Update & Open Battle.net", "update-addons-and-launch"];
      const hits = launchPhrases.filter(function (p) { return bodyText.indexOf(p) !== -1; });
      if (hits.length) check("launch-feature string hits (detail)", false, hits.join(", "));
      return hits.length === 0 && !q(win, "#btn-update-play") && !q(win, "#btn-launch-wow");
    });

    checkTry("no console errors during this phase", function () { return currentPhase.consoleErrors.length === 0; });
  }

  // ------------------------------------------------------------------
  // Phase 2: multi-flavour mock - switcher present with 3 pills, Era
  // tooltip. Does not touch theme/localStorage.
  // ------------------------------------------------------------------
  async function phaseFlavours() {
    beginPhase("multi-flavour (?mock=1&test=1&flavours=3)");
    const win = await loadFrame("?mock=1&test=1&flavours=3");
    await waitForReady(win, 8000);

    checkTry("switcher shows exactly 3 pills in fixed order (Retail, Classic, Classic Era)", function () {
      // Components.Switcher mounts #flavour-switcher as the ANCHOR's own
      // next SIBLING (insertAdjacentElement("afterend", ...) - see
      // ui\app.js), never as a child of #flavour-switcher-anchor itself.
      const node = q(win, "#flavour-switcher");
      if (!node) return false;
      const pills = qa(win, "#flavour-switcher .flavour-pill");
      const labels = pills.map(function (p) { return text(p); });
      return labels.length === 3 && labels[0] === "Retail" && labels[1] === "Classic" && labels[2] === "Classic Era";
    });
    checkTry("Classic Era pill carries the Hardcore/Anniversary tooltip", function () {
      const node = q(win, "#flavour-switcher");
      if (!node) return false;
      return /Hardcore/i.test(node.innerHTML) && /Anniversary/i.test(node.innerHTML);
    });
    checkTry("no console errors during this phase", function () { return currentPhase.consoleErrors.length === 0; });
  }

  // ------------------------------------------------------------------
  // Phase 3: host=webview2 mock - CurseForge segment shows the native
  // placeholder, not the fallback panel.
  // ------------------------------------------------------------------
  async function phaseHostWebview2() {
    beginPhase("host=webview2 (?mock=1&test=1&host=webview2&view=browse&tab=curseforge)");
    const win = await loadFrame("?mock=1&test=1&host=webview2&view=browse&tab=curseforge");
    await waitForReady(win, 8000);
    // The mock's fake host-ready (capabilities:["cf-pane"]) fires ~60ms
    // after page load - give it real time to land and Views.browse to
    // re-render once hasCfPane() has an answer (see ui\app.js's own
    // comment on this).
    await wait(1200);
    checkTry("CurseForge segment shows the native placeholder, not the fallback, under host=webview2", function () {
      const fallback = q(win, "#browse-cf-fallback");
      const panel = q(win, "#browse-cf-panel");
      return visible(panel) && !visible(fallback);
    });
    checkTry("no console errors during this phase", function () { return currentPhase.consoleErrors.length === 0; });
  }

  // ------------------------------------------------------------------
  // Phase 3b (WAGO-BROWSE-SPEC.md, Round 32/Expansion E29): the Wago
  // category browse redesign - sort tabs (labels/tooltips), the category
  // chip strip (collapse/expand, selection, empty-category state), Load
  // more, row meta, the game-running gate, and Gaining this week's not-
  // ready/ready states including the non-scoping note and "See Popular
  // instead". Runs on fresh, default-theme frames like Phase 3 above, so
  // it sits here (before Phase 4 starts mutating localStorage's theme).
  //
  // "new"/"rising"/"trending"/"season" are legitimate words elsewhere in
  // this app (e.g. the "Get new addons" nav label itself), so they are
  // NOT added to the shared, whole-document BANNED_WORDS list above -
  // scanWagoBannedTerms below scans only #browse-wago-panel's own
  // rendered text (+ its tooltip data-tooltip attributes), matching this
  // round's actual acceptance bar ("no visible string anywhere in the
  // Wago segment...").
  // ------------------------------------------------------------------
  const WAGO_BANNED_WORDS = ["new", "rising", "trending", "season"];
  function scanWagoBannedTerms(win) {
    const panel = q(win, "#browse-wago-panel");
    if (!panel) return ["#browse-wago-panel not found"];
    const domText = panel.textContent || "";
    const tipText = qa(win, "#browse-wago-panel .info-tip[data-tooltip]")
      .map(function (b) { return b.dataset.tooltip || ""; }).join(" ");
    const combined = domText + " " + tipText;
    const hits = [];
    WAGO_BANNED_WORDS.forEach(function (w) {
      const re = new RegExp("\\b" + w + "\\b", "i");
      if (re.test(combined)) hits.push(w);
    });
    return hits;
  }

  async function phaseWagoBrowse() {
    beginPhase("Wago category browse (WAGO-BROWSE-SPEC.md, Round 32/E29)");
    const win = await loadFrame("?mock=1&test=1&view=get-new-addons&tab=wago");
    await waitForReady(win, 8000);
    await wait(700); // the initial Popular fetch (mock's own ~120-240ms delay) + render

    // ---- Sort control: four segments, exact labels, Popular active by
    // default, and the two required tooltips (through Components.Tooltip -
    // static .info-tip triggers, wired by App.init's own initAll() call).
    checkTry("sort control has exactly 4 segments with the spec's exact labels, Popular active by default", function () {
      const btns = qa(win, "#wago-sort .segmented-btn[data-sort]");
      const labels = btns.map(text);
      const active = btns.filter(function (b) { return b.classList.contains("is-active"); });
      return btns.length === 4 &&
        labels[0] === "Popular" && labels[1] === "Recently updated" && labels[2] === "Name (A-Z)" && labels[3] === "Gaining this week" &&
        active.length === 1 && active[0].dataset.sort === "popular";
    });
    checkTry("Recently updated tooltip text matches the spec's exact sentence", function () {
      const item = qa(win, "#wago-sort .wago-sort-item").filter(function (it) { return /Recently updated/.test(text(it)); })[0];
      const tip = item && item.querySelector(".info-tip");
      return !!tip && tip.dataset.tooltip === "Sorted by each addon's own last-updated date, within the current results.";
    });
    checkTry("Gaining this week tooltip text matches the spec's exact sentence", function () {
      const item = qa(win, "#wago-sort .wago-sort-item").filter(function (it) { return /Gaining this week/.test(text(it)); })[0];
      const tip = item && item.querySelector(".info-tip");
      return !!tip && tip.dataset.tooltip === "Furphy's own measurement, not a number Wago publishes.";
    });

    // ---- Category chips: collapsed by default (the harness's 1280px
    // iframe is under the app's own wide-window breakpoint), a "More
    // categories" toggle expands to the full 30 (All + 29, server order
    // verbatim, including id 5 sorting after id 28).
    checkTry("category strip is collapsed by default with a 'More categories +N' toggle", function () {
      const chips = qa(win, "#wago-cat-strip .wago-chip[data-cat-id]");
      const toggle = q(win, "#wago-cat-more");
      return chips.length > 0 && text(chips[0]) === "All" && chips.length < 30 &&
        !!toggle && /^More categories \+\d+$/.test(text(toggle));
    });
    const catMoreBtn = q(win, "#wago-cat-more");
    if (catMoreBtn) await clickAndSettle(win, catMoreBtn, 150);
    checkTry("expanded category strip has all 30 chips (All + the server's own 29, id 5 after id 28, never re-sorted)", function () {
      const chips = qa(win, "#wago-cat-strip .wago-chip[data-cat-id]");
      if (chips.length !== 30 || text(chips[0]) !== "All") return false;
      const expectedOrder = ["Chat & Communication", "Auction & Economy", "Audio & Video", "PvP", "Artwork",
        "Data Export", "Guild", "Bags & Inventory", "Libraries", "Map & Minimap", "Mail", "Quests & Leveling",
        "Boss Encounters", "Professions", "Unit Frames", "Miscellaneous", "Action Bars", "Combat", "Class",
        "Development Tools", "Minigames", "Tooltip", "Roleplay", "Plugins", "Achievements", "Companions",
        "Garrison", "Buffs & Debuffs", "Transmog"];
      const actual = chips.slice(1).map(text);
      return actual.every(function (name, i) { return name === expectedOrder[i]; });
    });

    const pvpChip = qa(win, "#wago-cat-strip .wago-chip[data-cat-id]").filter(function (c) { return text(c) === "PvP"; })[0];
    if (pvpChip) {
      await clickAndSettle(win, pvpChip, 400);
      checkTry("selecting a category updates the search placeholder and the result-count line", function () {
        const input = q(win, "#browse-search");
        return !!input && input.placeholder === "Search in PvP..." && /result(s)? in PvP$/.test(text(q(win, "#browse-summary")));
      });
    } else {
      check("selecting a category updates the search placeholder and the result-count line", false, "PvP chip not found");
    }

    const achievementsChip = qa(win, "#wago-cat-strip .wago-chip[data-cat-id]").filter(function (c) { return text(c) === "Achievements"; })[0];
    if (achievementsChip) {
      await clickAndSettle(win, achievementsChip, 400);
      checkTry("a category with zero matches shows the context-aware empty state", function () {
        return visible(q(win, "#browse-empty")) && text(q(win, "#browse-empty")).indexOf("No addons in Achievements yet") !== -1;
      });
      const allChip = qa(win, "#wago-cat-strip .wago-chip[data-cat-id]").filter(function (c) { return text(c) === "All"; })[0];
      if (allChip) await clickAndSettle(win, allChip, 400);
    } else {
      check("a category with zero matches shows the context-aware empty state", false, "Achievements chip not found");
    }

    // ---- Load more: 15 rows on the unfiltered default page (21-item mock
    // pool), a second page appends the rest and hides the button.
    checkTry("Load more is visible with 15 rows on the unfiltered default page", function () {
      return qa(win, "#browse-grid .browse-row").length === 15 && visible(q(win, "#wago-loadmore"));
    });
    const loadMoreBtn = q(win, "#wago-loadmore-btn");
    if (loadMoreBtn) {
      await clickAndSettle(win, loadMoreBtn, 500);
      checkTry("Load more appends rows and hides once the last page is reached", function () {
        return qa(win, "#browse-grid .browse-row").length === 21 && !visible(q(win, "#wago-loadmore"));
      });
    } else {
      check("Load more appends rows and hides once the last page is reached", false, "#wago-loadmore-btn not found");
    }

    checkTry("every Wago row shows author, summary, and a downloads+updated meta line", function () {
      const rows = qa(win, "#browse-grid .browse-row");
      if (rows.length === 0) return false;
      return rows.every(function (r) {
        const meta = r.querySelector(".browse-row-meta");
        return !!r.querySelector(".browse-row-author") && !!r.querySelector(".browse-row-summary") &&
          !!meta && /downloads/.test(text(meta)) && /updated/.test(text(meta));
      });
    });

    // ---- Recently updated / Name (A-Z) tabs.
    const updatedTab = qa(win, "#wago-sort .segmented-btn[data-sort]").filter(function (b) { return b.dataset.sort === "updated"; })[0];
    if (updatedTab) {
      await clickAndSettle(win, updatedTab, 500);
      checkTry("Recently updated tab becomes active and reloads results", function () {
        return updatedTab.classList.contains("is-active") && qa(win, "#browse-grid .browse-row").length > 0;
      });
    } else {
      check("Recently updated tab becomes active and reloads results", false, "updated tab button not found");
    }
    const nameTab = qa(win, "#wago-sort .segmented-btn[data-sort]").filter(function (b) { return b.dataset.sort === "name"; })[0];
    if (nameTab) {
      await clickAndSettle(win, nameTab, 500);
      checkTry("Name (A-Z) tab sorts rows alphabetically", function () {
        const names = qa(win, "#browse-grid .browse-row-title").map(text);
        const sorted = names.slice().sort(function (a, b) { return a.localeCompare(b); });
        return names.length > 0 && names.every(function (n, i) { return n === sorted[i]; });
      });
    } else {
      check("Name (A-Z) tab sorts rows alphabetically", false, "name tab button not found");
    }

    // ---- Gaining this week: not-ready state (this frame's mock has no
    // ?wagoGainingReady=1, so it stays not-ready - a fresh install's real
    // starting state).
    const gainTab = qa(win, "#wago-sort .segmented-btn[data-sort]").filter(function (b) { return b.dataset.sort === "gaining"; })[0];
    if (gainTab) {
      await clickAndSettle(win, gainTab, 500);
      checkTry("Gaining this week not-ready state renders the rewritten copy (never 'Day N of 4') plus a real snapshot count", function () {
        if (!visible(q(win, "#wago-gain-notready"))) return false;
        const body = text(q(win, "#wago-gain-notready-body"));
        const count = text(q(win, "#wago-gain-notready-count"));
        return /^Furphy started measuring daily download changes on Wago on .+\. It needs two snapshots taken 5 to 9 days apart before it can show what's gaining - the earliest that could happen is .+\.$/.test(body) &&
          /^\d+ snapshot\(s\) captured so far\.$/.test(count) && !/Day \d+ of \d+/.test(body);
      });
      checkTry("category chips are visually disabled and the search field is disabled with the non-scoping note visible, while Gaining is active", function () {
        const chips = qa(win, "#wago-cat-strip .wago-chip");
        const input = q(win, "#browse-search");
        const note = q(win, "#wago-gain-note");
        return chips.length > 0 && chips.every(function (c) { return c.getAttribute("aria-disabled") === "true"; }) &&
          !!input && input.disabled && input.placeholder === "Not available on Gaining this week" &&
          visible(note) && text(note) === "Gaining this week shows Furphy's own top movers across Wago's popular list - it isn't split by category or search yet.";
      });
      const seePopularBtn = q(win, "#wago-gain-see-popular");
      if (seePopularBtn) {
        await clickAndSettle(win, seePopularBtn, 500);
        checkTry("'See Popular instead' switches the active tab back to Popular", function () {
          const popularBtn = qa(win, "#wago-sort .segmented-btn[data-sort]").filter(function (b) { return b.dataset.sort === "popular"; })[0];
          return !!popularBtn && popularBtn.classList.contains("is-active") && qa(win, "#browse-grid .browse-row").length > 0;
        });
      } else {
        check("'See Popular instead' switches the active tab back to Popular", false, "#wago-gain-see-popular not found");
      }
    } else {
      check("Gaining this week not-ready state renders the rewritten copy (never 'Day N of 4') plus a real snapshot count", false, "Gaining tab button not found");
      check("category chips are visually disabled and the search field is disabled with the non-scoping note visible, while Gaining is active", false, "Gaining tab button not found");
      check("'See Popular instead' switches the active tab back to Popular", false, "Gaining tab button not found");
    }

    // Last use of `win` in this phase - loadFrame below reuses the SAME
    // #spa-frame iframe (see this file's own header comment), so `win`
    // becomes a reference to whatever loads next the instant that call
    // fires. Scan it for banned terms now, while it is still the Popular-
    // tab/Gaining-not-ready page it was left on above.
    checkTry("no 'new'/'rising'/'trending'/'season' label anywhere in the Wago panel (Popular/Gaining tabs)", function () {
      const hits = scanWagoBannedTerms(win);
      if (hits.length) check("Wago banned-term hits, Popular/Gaining tabs (detail)", false, hits.join(", "));
      return hits.length === 0;
    });

    // ---- Game-running blocked state (separate frame, WAGO-BROWSE-SPEC.md
    // section 3.5's corrected gate) - reuses the same ?game=1 flag /api/state
    // already answers to. Loaded only now that every check above is done
    // with `win` (see the comment just above).
    const gameWin = await loadFrame("?mock=1&test=1&view=get-new-addons&tab=wago&game=1");
    await waitForReady(gameWin, 8000);
    await wait(700);
    checkTry("a WoW client running shows the honest game-running message, not a blank list, never a live request", function () {
      return visible(q(gameWin, "#browse-gameactive")) && !visible(q(gameWin, "#browse-grid")) &&
        text(q(gameWin, "#browse-gameactive")).indexOf("Wago browsing pauses while a WoW client is running. It'll pick back up once you close the game.") !== -1;
    });

    // ---- Gaining this week: ready state (separate frame, ?wagoGainingReady=1
    // - the LAST frame this phase loads, so it stays valid through its own
    // banned-terms scan below).
    const gainReadyWin = await loadFrame("?mock=1&test=1&view=get-new-addons&tab=wago&wagoGainingReady=1");
    await waitForReady(gainReadyWin, 8000);
    await wait(700);
    const gainReadyTab = qa(gainReadyWin, "#wago-sort .segmented-btn[data-sort]").filter(function (b) { return b.dataset.sort === "gaining"; })[0];
    if (gainReadyTab) {
      await clickAndSettle(gainReadyWin, gainReadyTab, 500);
      checkTry("Gaining this week ready state shows a leading rank number and a delta badge on every row", function () {
        const rows = qa(gainReadyWin, "#browse-grid .browse-row");
        if (rows.length === 0) return false;
        return rows.every(function (r) {
          const rank = r.querySelector(".wago-gain-rank");
          const delta = r.querySelector(".chip.chip-success");
          return !!rank && /^\d+$/.test(text(rank)) && !!delta && /^\+[\d,.]+ since /.test(text(delta));
        });
      });
      checkTry("Gaining this week ready state's line names both the measured-through date and the top-~150 scope", function () {
        return /^Based on downloads Furphy measured through .+ - looking only at Wago's current top ~150 popular addons\.$/.test(text(q(gainReadyWin, "#browse-summary")));
      });
    } else {
      check("Gaining this week ready state shows a leading rank number and a delta badge on every row", false, "Gaining tab button not found");
      check("Gaining this week ready state's line names both the measured-through date and the top-~150 scope", false, "Gaining tab button not found");
    }

    checkTry("no 'new'/'rising'/'trending'/'season' label anywhere in the Wago panel (Gaining ready tab)", function () {
      const hits = scanWagoBannedTerms(gainReadyWin);
      if (hits.length) check("Wago banned-term hits, Gaining ready tab (detail)", false, hits.join(", "));
      return hits.length === 0;
    });

    // ---- Gaining this week: not-ready, ZERO snapshots ever captured
    // (WAGO-BROWSE-SPEC.md section 4.6 point 1 - since=null, snapshotCount=0;
    // a real, reachable fresh-install/first-crawl-incomplete state, distinct
    // from the "since known, one snapshot" fixture the earlier not-ready
    // check above exercises). Round 2 fixer regression check for the bug
    // where formatWagoDay(null) produced empty date placeholders and a
    // dangling-period sentence.
    const gainNoSnapWin = await loadFrame("?mock=1&test=1&view=get-new-addons&tab=wago&wagoGainingNoSnapshots=1");
    await waitForReady(gainNoSnapWin, 8000);
    await wait(700);
    const gainNoSnapTab = qa(gainNoSnapWin, "#wago-sort .segmented-btn[data-sort]").filter(function (b) { return b.dataset.sort === "gaining"; })[0];
    if (gainNoSnapTab) {
      await clickAndSettle(gainNoSnapWin, gainNoSnapTab, 500);
      checkTry("Gaining this week not-ready state with zero snapshots ever (since=null) renders a complete sentence, never an empty date placeholder or dangling period", function () {
        if (!visible(q(gainNoSnapWin, "#wago-gain-notready"))) return false;
        const body = text(q(gainNoSnapWin, "#wago-gain-notready-body"));
        const count = text(q(gainNoSnapWin, "#wago-gain-notready-count"));
        return body.length > 0 && !/ on \.| is \.|\.\s*\.$/.test(body) &&
          !/started measuring/.test(body) && // since is unknown - must not reference a since date at all
          count === "0 snapshot(s) captured so far.";
      });
    } else {
      check("Gaining this week not-ready state with zero snapshots ever (since=null) renders a complete sentence, never an empty date placeholder or dangling period", false, "Gaining tab button not found");
    }

    checkTry("no console errors during this phase", function () { return currentPhase.consoleErrors.length === 0; });
  }

  // ------------------------------------------------------------------
  // Phase 4: ?theme=matcha - applies AND persists (THEMES-SPEC.md set B).
  // Deliberately runs AFTER every phase above that depends on the DEFAULT
  // (tokyo-rain, fresh-profile) theme, since this is same-origin and
  // will write localStorage - a later reload without ?theme= would
  // otherwise see matcha, not tokyo-rain.
  // ------------------------------------------------------------------
  async function phaseTheme() {
    beginPhase("theme deep link (?mock=1&test=1&theme=matcha)");
    const win = await loadFrame("?mock=1&test=1&theme=matcha");
    await waitForReady(win, 8000);
    checkTry("?theme=matcha applies on load", function () {
      return win.document.documentElement.dataset.theme === "matcha";
    });
    checkTry("no console errors during this phase", function () { return currentPhase.consoleErrors.length === 0; });
  }

  // ------------------------------------------------------------------
  // Phase 5: ?view=settings deep link.
  // ------------------------------------------------------------------
  async function phaseViewDeepLink() {
    beginPhase("view deep link (?mock=1&test=1&view=settings)");
    const win = await loadFrame("?mock=1&test=1&view=settings");
    await waitForReady(win, 8000);
    checkTry("?view=settings shows the Settings view on load", function () {
      return visible(q(win, "#view-settings")) && !visible(q(win, "#view-myaddons"));
    });
    checkTry("no console errors during this phase", function () { return currentPhase.consoleErrors.length === 0; });
  }

  // ------------------------------------------------------------------
  // Phase 6 (SETTINGS-SPEC.md section 6 - Round 32 settings UI/UX audit):
  // the tooltip component, the reworded CurseForge install-links row, the
  // merged/demoted Advanced groups, and the done_updated pluralization fix.
  // Finds a row's tooltip trigger by matching the START of a stable label/
  // heading text rather than by DOM position, since exact markup nesting is
  // an implementation detail this phase shouldn't have to track - only
  // "does the row whose visible text starts with X carry a wired .info-tip"
  // matters here.
  // ------------------------------------------------------------------
  function labelInfoTip(win, selector, textPrefix) {
    const el = qa(win, selector).filter(function (e) { return text(e).indexOf(textPrefix) === 0; })[0];
    return el ? el.querySelector(".info-tip") : undefined; // undefined: no such row found at all
  }

  async function phaseSettingsAudit() {
    beginPhase("Settings UI/UX audit (SETTINGS-SPEC.md section 6)");
    const win = await loadFrame("?mock=1&test=1&view=settings");
    await waitForReady(win, 8000);

    // Advanced starts collapsed - a closed <details> gives its content no
    // box at all (same as display:none), so every row inside it needs this
    // open before any of the checks below can find/interact with it.
    const summary = q(win, "#settings-advanced summary");
    if (summary) await clickAndSettle(win, summary, 150);
    checkTry("Advanced opens on a real click (info-tip inside <summary> does not eat the click)", function () {
      return q(win, "#settings-advanced").open === true;
    });

    // ---- Positive: every row this spec lists as having a tooltip carries
    // a wired .info-tip with a non-empty aria-label. Static rows only here
    // (present in the DOM regardless of Scan/Run ever being clicked) -
    // Untracked-folder and Diagnostics per-row tooltips are dynamic and
    // checked separately below, once their action has actually run.
    const STATIC_TOOLTIP_ARIA_LABELS = [
      "More about Include beta versions",
      "More about Update addons in the background",
      "More about How often",
      "More about Start with Windows",
      "More about Spacing",
      "More about Theme",
      "More about Advanced",
      "More about Open CurseForge install links in Furphy",
      "More about Available in the Furphy desktop window",
      "More about Show only search results on CurseForge",
      "More about Also include experimental versions",
      "More about World of Warcraft folder",
      "More about AddOns folder",
      "More about Show test realms (PTR/Beta)",
      "More about Folders Furphy doesn't manage yet",
      "More about Scan",
      "More about Save / load your addon list",
      "More about Open logs folder",
      "More about Force reinstall all",
      "More about Open addon list file",
      "More about Uninstall Furphy Addon Manager",
      "More about Run",
      "More about Copy report",
      "More about WoW client build",
      "More about Running for"
    ];
    STATIC_TOOLTIP_ARIA_LABELS.forEach(function (label) {
      checkTry("info-tip present: " + label, function () {
        const btn = q(win, '.info-tip[aria-label="' + label + '"]');
        return !!btn && btn.dataset.tooltip && btn.dataset.tooltip.length > 0;
      });
    });
    checkTry("exactly " + STATIC_TOOLTIP_ARIA_LABELS.length + " static settings tooltips present (no extras, none missing)", function () {
      const actualLabels = qa(win, "#view-settings .info-tip[data-tooltip]")
        .map(function (b) { return b.getAttribute("aria-label"); });
      const missing = STATIC_TOOLTIP_ARIA_LABELS.filter(function (l) { return actualLabels.indexOf(l) === -1; });
      const extra = actualLabels.filter(function (l) { return STATIC_TOOLTIP_ARIA_LABELS.indexOf(l) === -1; });
      if (missing.length || extra.length) {
        check("static settings tooltip mismatch (detail)", false,
          "missing: [" + missing.join(", ") + "]; extra: [" + extra.join(", ") + "]");
      }
      return missing.length === 0 && extra.length === 0;
    });

    // ---- Negative: rows this spec explicitly marks "tooltip: none" carry
    // NO .info-tip - both directions matter per the spec's own acceptance
    // line, not just "every listed row has one".
    // Round 34 (REMOVAL-SPEC.md CS-R4/CS-R15): the "Update addons before WoW
    // starts" row (and its #toggle-autoupdate checkbox) is gone entirely -
    // replaces the old "has NO tooltip" check on that row (dead now that the
    // row itself doesn't exist) with an assertion that the row/control are
    // absent altogether.
    checkTry("Settings has no 'Update addons before WoW starts' row or #toggle-autoupdate control (Round 34 removed the autoUpdateOnLaunch setting)", function () {
      return !q(win, "#toggle-autoupdate") && labelInfoTip(win, ".settings-row-label", "Update addons before WoW starts") === undefined;
    });
    checkTry("the ad-filter row's own main label has NO tooltip (only its fallback line does)", function () {
      const row = q(win, "#browsing-adfilter-row .settings-row-label");
      return !!row && !row.querySelector(".info-tip");
    });
    checkTry("the theme swatch grid itself has NO tooltip (only the 'Theme' label above it does)", function () {
      return !q(win, "#theme-grid .info-tip");
    });
    checkTry("About's 'Version' item has NO tooltip", function () {
      const items = qa(win, "#settings-about-footer .settings-footer-item");
      const versionItem = items.filter(function (e) { return text(e).indexOf("Version") === 0; })[0];
      return !!versionItem && !versionItem.querySelector(".info-tip");
    });

    // ---- No baked-in "- On"/"- Off" suffix anywhere in Settings (Eric's
    // named complaint) - scans the real rendered text, not just the
    // CurseForge row, since the whole point is no ROW on this screen
    // encodes state twice.
    checkTry('no visible "- On"/"- Off" (or "-On"/"-Off") suffix anywhere in #view-settings', function () {
      return !/[-\u2014]\s*(On|Off)\b/.test(text(q(win, "#view-settings")));
    });

    // ---- Banned-term scan (UX-SPEC.md section 11 + SETTINGS-SPEC.md
    // section 4's "curseforge://" addition), reading BOTH the rendered DOM
    // text AND every .info-tip's data-tooltip content - tooltip copy is
    // JS-generated and only shows on hover/focus, so the static-HTML-only
    // sweep (tests\static\Test-BannedTerms.ps1) can't see it.
    checkTry("banned-term scan (incl. curseforge://) finds zero hits across every Settings label/helper/tooltip", function () {
      const view = q(win, "#view-settings");
      const domText = text(view).toLowerCase();
      const tipText = qa(win, "#view-settings .info-tip[data-tooltip]")
        .map(function (b) { return b.dataset.tooltip || ""; }).join(" ").toLowerCase();
      const combined = domText + " " + tipText;
      const phrases = BANNED_PHRASES.concat(["curseforge://"]);
      const hits = [];
      phrases.forEach(function (p) { if (combined.indexOf(p) !== -1) hits.push(p); });
      BANNED_WORDS.forEach(function (w) {
        const re = new RegExp("\\b" + w + "\\b", "i");
        if (re.test(combined)) hits.push(w);
      });
      if (hits.length) check("Settings banned-term hits (detail)", false, hits.join(", "));
      return hits.length === 0;
    });

    // ---- Diagnostics: exactly the two new, non-duplicate sentences before
    // Run, never the old pair that both spelled out the same 4-item list.
    checkTry("Diagnostics intro sentence is the new single sentence, byte-exact", function () {
      const intro = qa(win, "#settings-diagnostics > p.muted-text")[0];
      return !!intro && text(intro) === "Quick check that your files and CurseForge connection are working.";
    });
    checkTry("Diagnostics pre-run placeholder is the new wording, byte-exact (not the old itemized sentence)", function () {
      return text(q(win, "#diagnostics-list")) === "Nothing checked yet. Click Run to look.";
    });

    // ---- About footer: no bordered box, no heading - just plain text/spans
    // below the Advanced disclosure.
    checkTry("About footer has no enclosing .settings-group border", function () {
      const footer = q(win, "#settings-about-footer");
      return !!footer && !footer.closest(".settings-group");
    });
    checkTry("About footer has no <h3>", function () {
      const footer = q(win, "#settings-about-footer");
      return !!footer && !footer.querySelector("h3") && footer.tagName !== "H3";
    });
    checkTry("About footer values still render (Version/WoW client build/Running for all non-placeholder)", function () {
      const footer = q(win, "#settings-about-footer");
      return /\S/.test(text(q(win, "#about-version"))) && /\S/.test(text(q(win, "#about-client-build"))) && /\S/.test(text(q(win, "#about-uptime")));
    });

    // ---- Row count: Advanced collapses to 5 groups at 1 flavour/no PTR
    // (CurseForge, Also include experimental versions, Game folders,
    // Folders Furphy doesn't manage yet, Backup & troubleshooting).
    checkTry("Advanced holds exactly 5 VISIBLE top-level .settings-group boxes on a single-flavour, no-PTR mock (6th, WoW versions, exists in the DOM but stays [hidden] here)", function () {
      return qa(win, ".settings-advanced-body > .settings-group").filter(visible).length === 5;
    });
    // DISTRIBUTION-SPEC.md section 3.2 adds a 4th sub-group (Row 20,
    // Uninstall) to this same box, after Diagnostics.
    checkTry("Backup & troubleshooting merges Save/load + Troubleshooting + Diagnostics + Uninstall into one box with 4 sub-groups", function () {
      const box = q(win, "#settings-backup-troubleshooting");
      return !!box && box.classList.contains("settings-group") && qa(win, "#settings-backup-troubleshooting > .settings-subgroup").length === 4;
    });

    // ---- CurseForge install-links row (Row 8, Eric's named complaint): the
    // switch and the label sentence never both encode on/off at once - the
    // label string must be byte-identical whether the toggle is on or off.
    const cfToggle = q(win, "#settings-protocol-control input[type=checkbox]");
    const cfLabelText = function () {
      const row = q(win, "#settings-protocol-control .settings-row-label");
      return row ? text(row) : null;
    };
    if (cfToggle) {
      const labelWhenOff = cfLabelText();
      checkTry("CurseForge install-links label carries no on/off suffix while off", function () {
        return labelWhenOff === "Open CurseForge install links in Furphy";
      });
      checkTry("CurseForge install-links checkbox carries its own aria-label (the only accessible state indicator once the suffix is gone)", function () {
        return cfToggle.getAttribute("aria-label") === "Open CurseForge install links in Furphy";
      });
      await clickAndSettle(win, cfToggle, 300);
      const labelWhenOn = cfLabelText();
      checkTry("CurseForge install-links label is byte-identical on vs. off (state lives in the switch alone)", function () {
        return labelWhenOn !== null && labelWhenOn === labelWhenOff;
      });
      // Leave it back where it started so a re-run of this phase (or a
      // later phase reusing this same mock profile) sees the same baseline.
      await clickAndSettle(win, cfToggle, 300);
    } else {
      check("CurseForge install-links label carries no on/off suffix while off", false, "checkbox not found");
      check("CurseForge install-links label is byte-identical on vs. off", false, "checkbox not found");
    }

    // ---- Untracked folders + Diagnostics: dynamic per-row tooltips only
    // exist once Scan/Run have actually populated their lists.
    const scanBtn = q(win, "#btn-scan");
    if (scanBtn) {
      await clickAndSettle(win, scanBtn, 800);
      checkTry("every 'Take over' button in a Scan result has its own wired .info-tip (Row 15 per-result tooltips)", function () {
        const rows = qa(win, "#untracked-list .untracked-row");
        if (rows.length === 0) return false; // the default mock fixture always has >=1 result
        return rows.every(function (r) {
          const groups = Array.prototype.slice.call(r.querySelectorAll(".btn-tip-group"));
          return groups.length > 0 && groups.every(function (g) { return !!g.querySelector(".info-tip[data-tooltip]"); });
        });
      });
    }
    const runBtn = q(win, "#btn-run-diagnostics");
    if (runBtn) {
      await clickAndSettle(win, runBtn, 1200);
      checkTry("AddOns folder/CurseForge/Disk space diagnostic rows each carry their own tooltip; other rows (Tracked addons, etc.) do not", function () {
        const names = qa(win, "#diagnostics-list .diag-name");
        const withTip = {}; names.forEach(function (n) { withTip[text(n)] = !!n.querySelector(".info-tip"); });
        const wantTip = ["AddOns folder", "CurseForge", "Disk space"];
        const noTip = ["Your addon settings", "Tracked addons"];
        return wantTip.every(function (n) { return withTip[n] === true; }) &&
          noTip.every(function (n) { return withTip[n] === undefined || withTip[n] === false; });
      });
      checkTry("Copy report's info-tip hides together with the button itself (no orphaned icon while report is unavailable)", function () {
        // Just ran successfully above, so both should now be visible together.
        const btn = q(win, "#btn-copy-diagnostics");
        const group = btn && btn.closest(".btn-tip-group");
        return !!group && !group.hidden && !btn.hidden;
      });
    }

    // ---- computeCoreText() done_updated pluralization (SETTINGS-SPEC.md
    // section 5, item 2 / section 6): proves the JS side's own singular vs.
    // plural output is correct and stable. Byte-identity with host\
    // FurphyHost.cs's ComputeCore is a cross-file, cross-language pairing
    // this JS-only harness cannot execute directly - that half is verified
    // by the matching Round 32 comment left in both files (see ui\app.js's
    // computeCoreText and host\FurphyHost.cs's ComputeCore, both quoting
    // this same acceptance line).
    checkTry("computeCoreText() pluralizes 'addon' for N=1 (no bare count, no missing noun)", function () {
      const fn = win.__furphyTest && win.__furphyTest.Views && win.__furphyTest.Views.settings && win.__furphyTest.Views.settings.computeCoreText;
      if (!fn) return false;
      const out = fn({ status: "done_updated", updated: 1, updatedNames: ["Auctionator"], lastRunAt: new Date().toISOString() });
      return /^Updated 1 addon at \d{2}:\d{2}: Auctionator$/.test(out);
    });
    checkTry("computeCoreText() pluralizes 'addons' for N>1", function () {
      const fn = win.__furphyTest && win.__furphyTest.Views && win.__furphyTest.Views.settings && win.__furphyTest.Views.settings.computeCoreText;
      if (!fn) return false;
      const out = fn({ status: "done_updated", updated: 3, updatedNames: ["A", "B", "C"], lastRunAt: new Date().toISOString() });
      return /^Updated 3 addons at \d{2}:\d{2}: A, B, C$/.test(out);
    });

    // ---- Escape closes the tooltip bubble first, without also dismissing
    // an overlay open underneath it (Section 3's ordering requirement) -
    // uses a real confirm dialog (Force reinstall all) as the "overlay
    // underneath", since Settings has no dropdown menu of its own to reuse.
    const forceBtn = q(win, "#btn-force-reinstall");
    if (forceBtn) {
      await clickAndSettle(win, forceBtn, 250);
      const dialogShown = visible(q(win, "#dialog-confirm"));
      if (dialogShown) {
        const betaTip = q(win, '.info-tip[aria-label="More about Include beta versions"]');
        if (betaTip) { betaTip.focus(); }
        await wait(600);
        const tooltipOpenedUnderneath = !!q(win, "#app-tooltip");
        win.document.dispatchEvent(new win.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
        await wait(150);
        checkTry("Escape closes the tooltip bubble", function () { return tooltipOpenedUnderneath && !q(win, "#app-tooltip"); });
        checkTry("that same Escape leaves the confirm dialog underneath untouched (still open)", function () { return visible(q(win, "#dialog-confirm")); });
        // Clean up: a second Escape dismisses the dialog itself, back to baseline.
        win.document.dispatchEvent(new win.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
        await wait(150);
      } else {
        check("Escape closes the tooltip bubble", false, "confirm dialog never opened");
        check("that same Escape leaves the confirm dialog underneath untouched (still open)", false, "confirm dialog never opened");
      }
    }

    checkTry("no console errors during this phase", function () { return currentPhase.consoleErrors.length === 0; });
  }

  // ------------------------------------------------------------------
  // Phase 7 (DISTRIBUTION-SPEC.md sections 3.2/3.4): Settings > Backup &
  // troubleshooting's "Uninstall Furphy Addon Manager" row - the button
  // itself, the shared confirm dialog's exact copy (including the derived
  // "kept at <appDest>" clause), the 409 busy path, and the 202 success
  // path's full-screen "being removed" state with polling actually
  // stopped. The busy path is forced deterministically via the mock's own
  // ?uninstallBusy=1 test-only param (same convention as ?game=1/
  // ?flavours=N above) rather than timing a real mock job's running
  // window - three separate frames (one per outcome, plus the unforced one
  // the copy checks run against) so entering the one-way uninstalling
  // state in the success frame can never bleed into the other two.
  // ------------------------------------------------------------------
  async function openAdvancedAndFindUninstallButton(win) {
    const summary = q(win, "#settings-advanced summary");
    if (summary) await clickAndSettle(win, summary, 150);
    return q(win, "#btn-uninstall-app");
  }

  async function phaseUninstall() {
    beginPhase("uninstall (DISTRIBUTION-SPEC.md sections 3.2/3.4)");

    // ---- Button + confirm dialog copy, on a plain unforced frame.
    const copyWin = await loadFrame("?mock=1&test=1&view=settings");
    await waitForReady(copyWin, 8000);
    const copyBtn = await openAdvancedAndFindUninstallButton(copyWin);
    checkTry("Uninstall Furphy Addon Manager button present, danger-styled, in Backup & troubleshooting", function () {
      return !!copyBtn && text(copyBtn) === "Uninstall Furphy Addon Manager" && copyBtn.classList.contains("btn-danger-outline");
    });
    if (copyBtn) {
      await clickAndSettle(copyWin, copyBtn, 250);
      const dialogShown = visible(q(copyWin, "#dialog-confirm"));
      checkTry("confirm dialog shows the exact title and message, with the derived addon-list path", function () {
        if (!dialogShown) return false;
        const title = text(q(copyWin, "#confirm-title"));
        const msg = text(q(copyWin, "#confirm-message"));
        return title === "Uninstall Furphy Addon Manager?" &&
          msg === "This removes Furphy's program files, its Start with Windows setting, and the CurseForge install-link handler. Your addons stay installed in WoW. Your addon list is kept at C:\\Program Files (x86)\\World of Warcraft\\_retail_\\AddonSync so reinstalling brings it back.";
      });
      checkTry("confirm dialog's OK button reads 'Uninstall' and is danger-styled", function () {
        const okBtn = q(copyWin, "#confirm-ok");
        return !!okBtn && text(okBtn) === "Uninstall" && okBtn.classList.contains("btn-danger");
      });
      if (dialogShown) {
        const cancelBtn = q(copyWin, "#confirm-cancel");
        if (cancelBtn) await clickAndSettle(copyWin, cancelBtn, 150);
      }
    } else {
      check("confirm dialog shows the exact title and message, with the derived addon-list path", false, "#btn-uninstall-app not found");
      check("confirm dialog's OK button reads 'Uninstall' and is danger-styled", false, "#btn-uninstall-app not found");
    }
    checkTry("cancelling the confirm dialog leaves the app running normally (no uninstalling state entered)", function () {
      return copyWin.__furphyTest.App.isUninstalling() === false && visible(q(copyWin, "#app")) && !visible(q(copyWin, "#app-closing-overlay"));
    });

    // ---- 409 busy path.
    const busyWin = await loadFrame("?mock=1&test=1&view=settings&uninstallBusy=1");
    await waitForReady(busyWin, 8000);
    const busyBtn = await openAdvancedAndFindUninstallButton(busyWin);
    if (busyBtn) {
      await clickAndSettle(busyWin, busyBtn, 250);
      const busyDialogShown = visible(q(busyWin, "#dialog-confirm"));
      if (busyDialogShown) {
        await clickAndSettle(busyWin, q(busyWin, "#confirm-ok"), 400);
        checkTry("409 response shows the plain-language busy toast and leaves the app running (not uninstalling)", function () {
          const toasts = qa(busyWin, "#toast-container .toast-body").map(function (el) { return text(el); });
          const sawBusyToast = toasts.some(function (t) { return t === "Furphy is updating an addon right now. Try again in a minute."; });
          return sawBusyToast && busyWin.__furphyTest.App.isUninstalling() === false && visible(q(busyWin, "#app"));
        });
      } else {
        check("409 response shows the plain-language busy toast and leaves the app running (not uninstalling)", false, "confirm dialog never opened");
      }
    } else {
      check("409 response shows the plain-language busy toast and leaves the app running (not uninstalling)", false, "#btn-uninstall-app not found");
    }

    // ---- 202 success path, on a separate unforced frame.
    const successWin = await loadFrame("?mock=1&test=1&view=settings");
    await waitForReady(successWin, 8000);
    const successBtn = await openAdvancedAndFindUninstallButton(successWin);
    if (successBtn) {
      await clickAndSettle(successWin, successBtn, 250);
      const successDialogShown = visible(q(successWin, "#dialog-confirm"));
      if (successDialogShown) {
        await clickAndSettle(successWin, q(successWin, "#confirm-ok"), 400);
        checkTry("202 response shows the full-screen 'being removed' state, hides the app shell, and stops polling", function () {
          const overlay = q(successWin, "#app-closing-overlay");
          const shell = q(successWin, "#app");
          const overlayText = text(overlay);
          return visible(overlay) && !visible(shell) &&
            overlayText.indexOf("Furphy is being removed") !== -1 &&
            overlayText.indexOf("You can close this window") !== -1 &&
            successWin.__furphyTest.App.isUninstalling() === true;
        });
        checkTry("no error or warning toast appears once the app enters the uninstalling state (a dropped connection here is expected, never an error)", function () {
          return qa(successWin, "#toast-container .toast-error, #toast-container .toast-warning").length === 0;
        });
      } else {
        check("202 response shows the full-screen 'being removed' state, hides the app shell, and stops polling", false, "confirm dialog never opened");
      }
    } else {
      check("202 response shows the full-screen 'being removed' state, hides the app shell, and stops polling", false, "#btn-uninstall-app not found");
    }

    checkTry("no banned UX-SPEC.md section 11 term appears in the uninstall confirm dialog or full-screen state, across all three frames", function () {
      const hits = [];
      [copyWin, busyWin, successWin].forEach(function (w) {
        const combined = (text(q(w, "#dialog-confirm")) + " " + text(q(w, "#app-closing-overlay"))).toLowerCase();
        BANNED_PHRASES.concat(["curseforge://"]).forEach(function (p) { if (combined.indexOf(p) !== -1) hits.push(p); });
        BANNED_WORDS.forEach(function (w2) { if (new RegExp("\\b" + w2 + "\\b", "i").test(combined)) hits.push(w2); });
      });
      if (hits.length) check("uninstall banned-term hits (detail)", false, hits.join(", "));
      return hits.length === 0;
    });

    checkTry("no console errors during this phase", function () { return currentPhase.consoleErrors.length === 0; });
  }

  async function main() {
    await phaseDefault();
    await phaseFlavours();
    await phaseHostWebview2();
    await phaseWagoBrowse();
    await phaseTheme();
    await phaseViewDeepLink();
    await phaseSettingsAudit();
    await phaseUninstall();

    if (currentPhase) { currentPhase.durationMs = Date.now() - currentPhase._startedAtMs; }
    results.complete = true;
    results.finishedAt = new Date().toISOString();
    const total = results.phases.reduce(function (n, p) { return n + p.checks.length; }, 0);
    const failed = results.phases.reduce(function (n, p) { return n + p.checks.filter(function (c) { return !c.passed; }).length; }, 0);
    results.summary = { total: total, failed: failed, passed: total - failed };
    statusEl().textContent = "done - " + results.summary.passed + "/" + results.summary.total + " checks passed";
    writeResults();
  }

  main().catch(function (e) {
    results.harnessError = String(e && e.stack ? e.stack : e);
    results.complete = false;
    writeResults();
    statusEl().textContent = "HARNESS ERROR: " + results.harnessError;
  });
})();
