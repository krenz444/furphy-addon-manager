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
    try { resultsEl().textContent = JSON.stringify(results); } catch (e) { /* keep going */ }
  }

  function beginPhase(name) {
    currentPhase = { name: name, checks: [], consoleErrors: [] };
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
    // My Addons headline text - UX-SPEC.md 2.2/11).
    checkTry("exactly one freshness headline with visible text", function () {
      const sidebar = q(win, "#sidebar-freshness");
      const myaddons = q(win, "#myaddons-freshness");
      const sidebarHasText = text(sidebar).length > 0;
      const myaddonsHasText = text(myaddons).length > 0;
      return sidebarHasText !== myaddonsHasText || (!sidebarHasText && myaddonsHasText);
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
      while (Date.now() < progressDeadline) {
        const wrap = q(win, "#job-progress-wrap");
        const bar = q(win, "#job-progress-bar");
        if (visible(wrap) && bar && bar.tagName === "PROGRESS" && bar.hasAttribute("value")) { sawProgress = true; break; }
        await wait(150);
      }
      check("job panel shows a determinate <progress> bar mid-flight", sawProgress);
      checkTry("job progress label reads 'Updating i of N addons'", function () {
        return /Updating \d+ of \d+ addons/.test(text(q(win, "#job-progress-label")));
      });
      checkTry("Details disclosure is collapsed by default", function () {
        const details = q(win, "#job-details");
        return details && !details.open;
      });

      // Poll to completion - runProgressJob spreads its steps across ~6s
      // regardless of target count (ui\app.js's own design comment).
      const jobDeadline = Date.now() + 9000;
      let done = false;
      while (Date.now() < jobDeadline) {
        const resultsBox = q(win, "#job-results");
        if (resultsBox && !resultsBox.hidden && resultsBox.children.length > 0) { done = true; break; }
        await wait(250);
      }
      checkTry("job reaches a done-with-failure state within 9s", function () { return done; });
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

    checkTry("theme grid has 14 radios in THEMES-SPEC.md order, vaporwave checked on a fresh profile", function () {
      const expectedOrder = ["vaporwave", "lofi", "dark", "light", "terminal-green", "arctic-ice",
        "art-deco-gold", "alpine-dawn", "matcha", "desert-night", "tokyo-rain", "brushed-steel",
        "aurora-sky", "strawberry-cream"];
      const tiles = qa(win, "#theme-grid [role='radio']");
      if (tiles.length !== 14) return false;
      const slugs = tiles.map(function (t) { return t.dataset.themeValue; });
      const orderOk = slugs.every(function (s, i) { return s === expectedOrder[i]; });
      const checkedTile = q(win, "#theme-grid [aria-checked='true']");
      const checkedSlug = checkedTile && checkedTile.dataset.themeValue;
      return orderOk && checkedSlug === "vaporwave" && win.document.documentElement.dataset.theme === "vaporwave";
    });

    checkTry("no banned UX-SPEC.md section 11 term appears in rendered body text", function () {
      const hits = scanBannedTerms(win);
      if (hits.length > 0) { check("banned terms found (detail)", false, hits.join(", ")); }
      return hits.length === 0;
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
  // Phase 4: ?theme=matcha - applies AND persists (THEMES-SPEC.md set B).
  // Deliberately runs AFTER every phase above that depends on the DEFAULT
  // (vaporwave, fresh-profile) theme, since this is same-origin and will
  // write localStorage - a later reload without ?theme= would otherwise
  // see matcha, not vaporwave.
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

  async function main() {
    await phaseDefault();
    await phaseFlavours();
    await phaseHostWebview2();
    await phaseTheme();
    await phaseViewDeepLink();

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
