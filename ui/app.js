"use strict";
/* ==========================================================================
   Furphy Addon Manager - frontend
   Vanilla JS, no frameworks. Organised as namespaced modules:
     Mock       - dev-only fake backend, active only with ?mock=1
     Utils      - DOM/format helpers
     Sanitize   - upstream HTML sanitizer
     Api        - fetch wrapper for the server's JSON API
     Store      - central app state + derived getters
     Components - reusable UI pieces (toast, dialog, drawer, job panel, chips)
     Views      - per-screen render/bind logic (myAddons, browse, settings)
     Host       - postMessage bridge to the native WebView2 host (round 12)
     App        - bootstrap, routing, polling, global event wiring
   ========================================================================== */

/* ==========================================================================
   THEMES - THEMES-SPEC.md section 4's single source of truth: one {slug,
   name} entry per Appearance option, in the exact order the swatch-grid
   picker shows them (section 3.4 - Vaporwave, Lofi Night, Dark, Light, then
   the ten Round 18 (Set A) themes in tally order). Adding theme #15 is a
   one-entry change here, plus its own :root[data-theme] token block, .select
   chevron override, and .theme-swatch[data-theme-value] preview rule in
   style.css - nothing else. isKnownTheme, Views.settings.buildThemeGrid()'s
   picker rendering, and Host.reportTheme()'s message to the native host all
   derive from this array; none of them hardcode a theme list of their own.
   ========================================================================== */
const THEMES = [
  { slug: "vaporwave",         name: "Vaporwave" },
  { slug: "lofi",              name: "Lofi Night" },
  { slug: "dark",              name: "Dark" },
  { slug: "light",             name: "Light" },
  { slug: "terminal-green",    name: "Terminal Green" },
  { slug: "arctic-ice",        name: "Arctic Ice" },
  { slug: "art-deco-gold",     name: "Art Deco" },
  { slug: "alpine-dawn",       name: "Alpine Dawn" },
  { slug: "matcha",            name: "Matcha" },
  { slug: "desert-night",      name: "Desert Night" },
  { slug: "tokyo-rain",        name: "Tokyo Rain" },
  { slug: "brushed-steel",     name: "Brushed Steel" },
  { slug: "aurora-sky",        name: "Aurora Sky" },
  { slug: "strawberry-cream",  name: "Strawberry Cream" },
];
const DEFAULT_THEME = "vaporwave";

/* ==========================================================================
   Prefs - persisted appearance settings (theme, density), read from
   localStorage and stamped onto <html> as data-theme/data-density as the
   very first thing this script does (before Mock, before DOMContentLoaded)
   so the page never paints the wrong theme and then flashes to the stored
   one. Settings > Appearance calls setTheme/setDensity to change them.
   ========================================================================== */
const Prefs = (function () {
  const THEME_KEY = "addonSync.theme.v1";
  const DENSITY_KEY = "addonSync.density.v1";

  // E15/E15b/round 18: started as four theme values ("light", "vaporwave",
  // "dark" from E15, joined by "lofi" in E15b/round 11), now checks
  // membership against the full 14-slug THEMES array above (THEMES-SPEC.md
  // section 4) instead of a hardcoded list of its own - adding theme #15
  // needs no change here. "vaporwave" is the DEFAULT (round 17, Eric: "make
  // vaporwave the main theme again" - see SPEC.md section 3). Anything else
  // read back (missing key, corrupt value, an older/newer build's value, an
  // unknown slug) falls through to DEFAULT_THEME.
  function isKnownTheme(v) { return THEMES.some(function (t) { return t.slug === v; }); }

  function readTheme() {
    try { const v = localStorage.getItem(THEME_KEY); return isKnownTheme(v) ? v : DEFAULT_THEME; } catch (e) { return DEFAULT_THEME; }
  }
  function readDensity() {
    try { return localStorage.getItem(DENSITY_KEY) === "compact" ? "compact" : "comfortable"; } catch (e) { return "comfortable"; }
  }

  function applyTheme(value) {
    document.documentElement.dataset.theme = isKnownTheme(value) ? value : DEFAULT_THEME;
    // Round 12 (E19b): relay the just-applied theme to the native host (the
    // Host module, defined later in this file, near App) so it can recolor
    // its own chrome/title bar to match - see SPEC.md's E19b. Guarded: this
    // function's very first call happens at module-load time on the line
    // right below this one (before Host or App exist yet), which would
    // otherwise throw a ReferenceError; that first call is a harmless
    // no-op, and App.init() calls Host.reportTheme() again once
    // App.getServerHost() actually has an answer, so the host still gets a
    // real report once startup finishes. See Host's own module comment.
    try { Host.reportTheme(); } catch (e) { /* Host/App not initialized yet, or not running in the native host */ }
  }
  function applyDensity(value) { document.documentElement.dataset.density = value === "compact" ? "compact" : "comfortable"; }

  function setTheme(value) {
    const v = isKnownTheme(value) ? value : DEFAULT_THEME;
    applyTheme(v);
    try { localStorage.setItem(THEME_KEY, v); } catch (e) { /* storage unavailable - theme still applies for this load */ }
  }
  function setDensity(value) {
    const v = value === "compact" ? "compact" : "comfortable";
    applyDensity(v);
    try { localStorage.setItem(DENSITY_KEY, v); } catch (e) { /* storage unavailable - density still applies for this load */ }
  }

  applyTheme(readTheme());
  applyDensity(readDensity());

  return { getTheme: readTheme, getDensity: readDensity, setTheme: setTheme, setDensity: setDensity, isKnownTheme: isKnownTheme };
})();

/* ==========================================================================
   Mock (DEV ONLY) - active only when the page is opened with ?mock=1.
   Fakes every /api/* endpoint used by Api so the UI can be exercised in a
   plain browser tab without addon-server.ps1 running. Nothing here runs,
   and nothing here is reachable, unless the query flag is present.
   ========================================================================== */
const Mock = (function () {
  const enabled = new URLSearchParams(location.search).get("mock") === "1";
  if (!enabled) return { enabled: false };

  // Round 15: ?mock=1&host=webview2 also stands up a fake window.chrome.webview
  // so ui/app.js's Host module (window.chrome.webview.postMessage/
  // addEventListener("message", ...)) has something real to talk to in a
  // plain dev browser - no actual host\FurphyHost.exe involved. Every
  // page->host postMessage is logged to the console; a fake host replies
  // {type:"host-ready", capabilities:["cf-pane"]} once (mirroring the real
  // host's own "sent once CoreWebView2 is ready, and again on {type:'hello'}"
  // contract) and reacts to cf-show/cf-nav with plausible {type:"cf-state"}
  // replies (url/title/canGoBack/canGoForward/loading), driven by a tiny
  // in-memory history stack, so the CurseForge pane's toolbar/back/forward/
  // title are all exercisable with zero real network access.
  if (new URLSearchParams(location.search).get("host") === "webview2") {
    const cfListeners = [];
    let cfHistory = [];
    let cfIdx = -1;
    let cfHasPage = false;

    function cfCurrentUrl() { return cfIdx >= 0 ? cfHistory[cfIdx] : null; }
    function cfTitleFor(url) {
      if (!url) return "";
      const search = url.match(/[?&]search=([^&]+)/);
      if (search) return "Search: " + decodeURIComponent(search[1]) + " - CurseForge";
      const slug = url.match(/\/addons\/([a-z0-9-]+)/i);
      if (slug) return slug[1].replace(/-/g, " ").replace(/\b\w/g, function (c) { return c.toUpperCase(); }) + " - CurseForge";
      return "CurseForge - The Home for World of Warcraft Addons";
    }
    function sendToPage(msg) {
      console.log("[mock-host] host->page", msg);
      cfListeners.forEach(function (cb) { try { cb({ data: msg }); } catch (e) { /* a listener throwing shouldn't break the others */ } });
    }
    function sendCfState(loading) {
      sendToPage({ type: "cf-state", url: cfCurrentUrl(), title: cfTitleFor(cfCurrentUrl()), canGoBack: cfIdx > 0, canGoForward: cfIdx < cfHistory.length - 1, loading: !!loading });
    }
    function cfNavigate(url) {
      cfHistory = cfHistory.slice(0, cfIdx + 1);
      cfHistory.push(url);
      cfIdx = cfHistory.length - 1;
      cfHasPage = true;
      sendCfState(true);
      setTimeout(function () { sendCfState(false); }, 350);
    }

    window.chrome = window.chrome || {};
    window.chrome.webview = {
      postMessage: function (obj) {
        console.log("[mock-host] page->host", obj);
        if (!obj || typeof obj !== "object") return;
        if (obj.type === "hello") {
          sendToPage({ type: "host-ready", version: "mock-host-1.0", capabilities: ["cf-pane"] });
        } else if (obj.type === "cf-show") {
          if (obj.url && (!cfHasPage || obj.navigate)) cfNavigate(obj.url);
          else if (cfHasPage) sendCfState(false);
        } else if (obj.type === "cf-nav") {
          if (obj.action === "back" && cfIdx > 0) { cfIdx -= 1; sendCfState(false); }
          else if (obj.action === "forward" && cfIdx < cfHistory.length - 1) { cfIdx += 1; sendCfState(false); }
          else if (obj.action === "reload" && cfHasPage) { sendCfState(true); setTimeout(function () { sendCfState(false); }, 250); }
          else if (obj.action === "home") cfNavigate("https://www.curseforge.com/wow/addons");
          else if (obj.action === "go" && obj.url) cfNavigate(obj.url);
        }
        // cf-rect: nothing to reply to, already logged above.
        // cf-hide, theme, open-curseforge (legacy compat), cf-focus (Round
        // 16/E22): accepted, no reply needed for this mock's own purposes -
        // the page->host postMessage console.log above is the whole point
        // of exercising the toggle under ?mock=1&host=webview2.
      },
      addEventListener: function (type, cb) { if (type === "message") cfListeners.push(cb); },
      removeEventListener: function (type, cb) {
        if (type !== "message") return;
        const i = cfListeners.indexOf(cb);
        if (i !== -1) cfListeners.splice(i, 1);
      }
    };

    // Fired asynchronously (mirroring the real host's own timing) so it
    // lands after Host.init() has already wired its own listener during
    // App.init(), which runs after this module-load-time block.
    setTimeout(function () {
      sendToPage({ type: "host-ready", version: "mock-host-1.0", capabilities: ["cf-pane"] });
    }, 60);
  }

  // E19: adFilter/hostWindow join the mock settings shape too, so Settings'
  // Browsing card and the protocol row are exercisable under ?mock=1.
  // adFilter defaults true as of 2026-09-04 (Eric's explicit ask, SPEC E22 -
  // was OFF by default originally, see Get-DefaultSettings on the server).
  // Round 16 (E22): cfFocus joins them too, default true (see
  // Get-DefaultSettings on the server).
  // Round 18 (tray stage B): backgroundUpdates/runAtStartup default off,
  // backgroundIntervalMinutes defaults 120 - same defaults as the real
  // server's Get-DefaultSettings.
  // FLAVORS-SPEC.md CS-F4: activeFlavour/showTestRealms join the mock
  // settings shape too (S3.4 - same plain client-writable pattern as
  // adFilter/cfFocus), round-tripped by the PUT handler below.
  const mockSettings = { releaseType: 1, autoUpdateOnLaunch: true, port: 47831, adFilter: true, cfFocus: true, hostWindow: null, backgroundUpdates: false, backgroundIntervalMinutes: 120, runAtStartup: false, activeFlavour: "retail", showTestRealms: false };

  // FLAVORS-SPEC.md CS-F4 (section 8's own acceptance item / task brief's own
  // "?mock=1&flavours=3" verify step): ?mock=1&flavours=N (2-4) fakes an
  // N-flavour machine so the switcher/per-flavour views are exercisable with
  // no real server - omitted or out of range keeps today's single-Retail
  // shape exactly (installedFlavours stays a 1-entry array, matching what
  // the real server also always sends - S5.2's two always-present fields -
  // so this is a size difference only, never a shape one).
  const mockFlavourPool = [
    { id: "retail", label: "Retail", addonsPath: "C:\\Program Files (x86)\\World of Warcraft\\_retail_\\Interface\\AddOns", clientBuild: "12.1.0.69587", clientInterface: 120100, buildInfoMissing: false },
    { id: "classic", label: "Classic", addonsPath: "C:\\Program Files (x86)\\World of Warcraft\\_classic_\\Interface\\AddOns", clientBuild: "5.5.4.61180", clientInterface: 50504, buildInfoMissing: false },
    { id: "classic_era", label: "Classic Era", addonsPath: "C:\\Program Files (x86)\\World of Warcraft\\_classic_era_\\Interface\\AddOns", clientBuild: "1.15.9.60546", clientInterface: 11509, buildInfoMissing: false },
    { id: "ptr", label: "PTR", addonsPath: "C:\\Program Files (x86)\\World of Warcraft\\_ptr_\\Interface\\AddOns", clientBuild: "12.1.0.69588", clientInterface: 120100, buildInfoMissing: true }
  ];
  const mockFlavourCountParam = parseInt(new URLSearchParams(location.search).get("flavours"), 10);
  const mockInstalledFlavours = (mockFlavourCountParam >= 2 && mockFlavourCountParam <= 4)
    ? mockFlavourPool.slice(0, mockFlavourCountParam)
    : [mockFlavourPool[0]];

  // A small, deliberately distinct fixture per non-Retail flavour, so
  // switching the switcher's pills visibly changes My Addons' list/
  // freshness (the task brief's own verify bar) - Retail keeps using the
  // full `addons`/`jobs`/`currentJob` machinery below completely unchanged
  // (read-only for the others: no job-posting simulation for a non-Retail
  // flavour, nothing in the acceptance bar needs one).
  const mockFlavourExtra = {
    classic: {
      addons: [
        { name: "FakeAddon", projectId: 9001001, fileId: 1, version: "1.0.0", fileName: "FakeAddon-1.0.0.zip", installedAt: new Date(Date.now() - 10 * 24 * 3600e3).toISOString(), folders: ["FakeAddon"], author: "test", ignoreUpdates: false, pinnedFileId: null, releaseType: null, updateAvailable: { fileId: 2, version: "1.1.0" }, tocInterfaces: [50504], compat: "ok", latestGameVersions: ["5.5.4"], latestFileDate: new Date().toISOString() }
      ],
      lastRun: null, updatesCheckedAt: new Date(Date.now() - 40 * 60e3).toISOString(), lastCheckFailed: false, lastCheckError: null
    },
    classic_era: {
      addons: [
        { name: "MultiFlavourAddon", projectId: 9002002, fileId: 1, version: "2.0.0", fileName: "MultiFlavourAddon-2.0.0.zip", installedAt: new Date(Date.now() - 5 * 24 * 3600e3).toISOString(), folders: ["MultiFlavourAddon"], author: "test", ignoreUpdates: false, pinnedFileId: null, releaseType: null, updateAvailable: null, tocInterfaces: [11509], compat: "ok", latestGameVersions: ["1.15.9"], latestFileDate: new Date().toISOString() },
        { name: "PreExistingEraAddon", projectId: 9002003, fileId: 1, version: "0.9.0", fileName: "PreExistingEraAddon-0.9.0.zip", installedAt: new Date(Date.now() - 90 * 24 * 3600e3).toISOString(), folders: ["PreExistingEraAddon"], author: "test", ignoreUpdates: false, pinnedFileId: null, releaseType: null, updateAvailable: null }
      ],
      lastRun: null, updatesCheckedAt: new Date(Date.now() - 2 * 3600e3).toISOString(), lastCheckFailed: false, lastCheckError: null
    },
    ptr: { addons: [], lastRun: null, updatesCheckedAt: null, lastCheckFailed: false, lastCheckError: null }
  };
  function mockFreshnessForExtra(fx) {
    if (!fx.updatesCheckedAt) return "not_checked";
    if (fx.addons.some(function (a) { return !!a.updateAvailable; })) return "updates_available";
    return "up_to_date";
  }
  // Round 18: a fake background tray, entirely in-memory - no real process,
  // no real registry access. mockTray.running mirrors what a real
  // GET /api/tray/status would report (state.running AND that pid is alive);
  // starting it fabricates one plausible completed cycle immediately rather
  // than simulating a real wait, so the Settings status line is exercisable
  // under ?mock=1 without a timer.
  const mockTray = { running: false, state: null };
  let mockStartupRegistered = false;
  // E19: mock curseforge:// handler state - toggled entirely in-memory by
  // the /api/protocol/register|unregister handling below, no real registry
  // access. ?mock=1&host=webview2 also flips /api/ping's host field, so the
  // ad-filter toggle's "native host only" branch is previewable with no
  // real FurphyHost.exe running.
  let protocolRegistered = false;
  let nextJobId = 1;
  let currentJob = null;
  const jobs = [];

  const addons = [
    // Round 5 fix: this mock roster is dev-only fixture data, but naming a
    // real addon that no longer exists in Midnight (12.x) misleads anyone
    // reading the source - WeakAuras has no Midnight-era build. Swapped for
    // Auctionator, a real addon still current in Season 2 on 12.1.0.
    // E13: tocInterfaces/compat/latestGameVersions/latestFileDate exercise
    // the Compatibility column/chip and the drawer's compat section without
    // a real server - Auctionator is "ok" (matches the mock client build),
    // BigWigs below is "stale-minor" (12.0.x only), BonusRollConfirm is
    // "unknown" (no evidence at all, e.g. a record that predates E13).
    { name: "Auctionator", projectId: 68304, fileId: 111, version: "5.20.1", fileName: "Auctionator-5.20.1.zip", installedAt: new Date(Date.now() - 3 * 3600e3).toISOString(), folders: ["Auctionator"], author: "Sylvanaar", ignoreUpdates: false, pinnedFileId: null, releaseType: null, updateAvailable: { fileId: 112, version: "5.21.0" }, tocInterfaces: [120100], compat: "ok", latestGameVersions: ["12.1.0"], latestFileDate: new Date(Date.now() - 3 * 3600e3).toISOString() },
    // E3: requiredDeps/optionalDeps/missingDeps/missingOptionalDeps exercise
    // the drawer's Overview dependency list and the row's "Missing: n" chip
    // without a real server - DetailsFramework isn't itself a mock addon, so
    // it shows up missing; Bagnon is (installed), so it shows up satisfied.
    { name: "Details! Damage Meter", projectId: 25301, fileId: 220, version: "18.2", fileName: "Details-18.2.zip", installedAt: new Date(Date.now() - 26 * 3600e3).toISOString(), folders: ["Details"], author: "Tercioo", ignoreUpdates: false, pinnedFileId: null, releaseType: null, updateAvailable: null, requiredDeps: ["DetailsFramework"], optionalDeps: ["Bagnon"], missingDeps: ["DetailsFramework"], missingOptionalDeps: [] },
    { name: "BigWigs Bossmods", projectId: 33818, fileId: 305, version: "424.3", fileName: "BigWigs-424.3.zip", installedAt: new Date(Date.now() - 9 * 24 * 3600e3).toISOString(), folders: ["BigWigs"], author: "Ammo", ignoreUpdates: false, pinnedFileId: 305, releaseType: null, updateAvailable: null, tocInterfaces: [120007], compat: "stale-minor", latestGameVersions: ["12.0.7"], latestFileDate: new Date(Date.now() - 9 * 24 * 3600e3).toISOString() },
    { name: "Bagnon", projectId: 24560, fileId: 88, version: "10.6", fileName: "Bagnon-10.6.zip", installedAt: new Date(Date.now() - 40 * 24 * 3600e3).toISOString(), folders: ["Bagnon"], author: "Tuller", ignoreUpdates: true, pinnedFileId: null, releaseType: null, previousFileId: 85, previousVersion: "10.5", updateAvailable: { fileId: 91, version: "10.9" } },
    { name: "BonusRollConfirm", projectId: 1521253, fileId: 8720783, version: "1.0.2", fileName: "BonusRollConfirm-1.0.2.zip", installedAt: new Date(Date.now() - 400 * 24 * 3600e3).toISOString(), folders: ["BonusRollConfirm"], author: "krenz", ignoreUpdates: false, pinnedFileId: null, releaseType: null, updateAvailable: null },
    // E12 (Wago second source): a Wago-sourced tracked addon, exercising the
    // My Addons source badge, the drawer's Wago branches, and "Also on
    // CurseForge" (curseId set, matching a real dual-hosted addon in spirit)
    // without the real server.
    { name: "Simple Damage Meter", projectId: null, fileId: "r7k2m9q1", version: "3.4.0", fileName: "simple-damage-meter-r7k2m9q1.zip", installedAt: new Date(Date.now() - 2 * 24 * 3600e3).toISOString(), folders: ["SimpleDamageMeter"], author: null, ignoreUpdates: false, pinnedFileId: null, releaseType: null, source: "wago", wagoId: "SDM001", slug: "simple-damage-meter", curseId: "654321", updateAvailable: { fileId: "r8n4p2s3", version: "3.5.0" } }
  ];

  const wagoBrowsePool = [
    { slug: "simple-damage-meter", name: "Simple Damage Meter", thumbnail: "" },
    { slug: "tidy-bags", name: "Tidy Bags", thumbnail: "" },
    { slug: "quick-camera", name: "Quick Camera", thumbnail: "" },
    { slug: "raid-cooldowns", name: "Raid Cooldowns", thumbnail: "" }
  ];
  const wagoCategoriesMock = [
    { id: 1, display_name: "Combat" },
    { id: 2, display_name: "Interface" },
    { id: 3, display_name: "Utility" }
  ];
  function fakeWagoReleases(slug) {
    const out = [];
    for (let i = 0; i < 5; i++) {
      out.push({
        id: slug.slice(0, 3) + "-r" + (5 - i),
        addon_id: 1,
        size: 30000 + i * 5000,
        label: (5 - i) + ".0.0",
        stability: i === 1 ? "beta" : (i === 4 ? "alpha" : "stable"),
        changelog: i === 0 ? "## What's new\n- Fixed a bug\n- **Improved** performance" : "",
        created_at: new Date(Date.now() - i * 12 * 24 * 3600e3).toISOString(),
        supported_retail_patches: ["12.1.0"],
        download_link: "https://cdn.wago.io/mock/" + slug + "/" + i + ".zip"
      });
    }
    return out;
  }

  let lastRun = {
    timestamp: new Date(Date.now() - 5 * 60e3).toISOString(),
    summary: "1 updated, 3 up to date, 1 ignored",
    rows: [
      { status: "Updated", name: "Auctionator", version: "5.20.1" },
      { status: "Up-to-date", name: "Details! Damage Meter", version: "18.2" },
      { status: "Pinned", name: "BigWigs Bossmods", version: "424.3" },
      { status: "Ignored", name: "Bagnon", version: "10.6" },
      { status: "Failed", name: "BonusRollConfirm", version: "1.0.2" }
    ]
  };
  let updatesCheckedAt = new Date(Date.now() - 5 * 60e3).toISOString();
  // CS1 (UX-SPEC.md sections 2.1/4.2): mirrors addon-server.ps1's
  // $Script:LastCheckFailed/$Script:LastCheckError - in-memory-only mock
  // state, never persisted, feeding /api/state's computed "freshness" enum
  // the same way the real server's Get-ComputedFreshness reads them.
  let lastCheckFailed = false;
  let lastCheckError = null;

  function mockFreshness() {
    if (currentJob && currentJob.state === "running" && ["sync", "check", "add", "install"].indexOf(currentJob.kind) !== -1) return "checking";
    if (lastCheckFailed) return "check_failed";
    if (!updatesCheckedAt) return "not_checked";
    if (addons.some(function (a) { return !!a.updateAvailable; })) return "updates_available";
    return "up_to_date";
  }

  const untracked = [
    { folder: "OldClique", title: "Clique", version: "60300-1", hasToc: true },
    { folder: "leftover_stuff", title: null, version: null, hasToc: false }
  ];

  // E16 (keyless CurseForge enrichment): a small offline-catalogue-shaped
  // fixture pool - exercises /api/cf/browse and the "addon-radar"/
  // "catalogue-only" drawer branches under ?mock=1. 1521253 deliberately
  // matches BonusRollConfirm's real tracked projectId (see the addons fixture
  // above) so opening ITS row exercises the enrichment path for an
  // already-tracked addon, not just a Browse card.
  const cfCatalogueMock = [
    { id: 1521253, name: "BonusRollConfirm", slug: "bonusrollconfirm", downloadCount: 12000, lastUpdated: new Date(Date.now() - 5 * 24 * 3600e3).toISOString(), logoUrl: "" },
    { id: 25301, name: "Details! Damage Meter", slug: "details-damage-meter", downloadCount: 45000000, lastUpdated: new Date().toISOString(), logoUrl: "" }
  ];
  let cfCatalogueMockFetchedAt = new Date(Date.now() - 3 * 3600e3).toISOString();

  // GET /api/cf/enrich/{id} fixture - id 654321 (matching Simple Damage
  // Meter's own curseId in the addons fixture above, the same E12 cross-
  // source pairing) demonstrates the "wago-match" branch; a
  // cfCatalogueMock hit demonstrates "addon-radar"; anything else falls to
  // "catalogue-only", mirroring the real server's own fallback order.
  function mockCfEnrich(id) {
    if (id === 654321) {
      return {
        source: "wago-match", name: "Simple Damage Meter", slug: "simple-damage-meter",
        summary: "A lightweight combat meter, mirrored from its Wago Addons listing.",
        descriptionMarkdown: "## Simple Damage Meter\nA **lightweight** combat meter.\n- Fast\n- Configurable\n- [Wago page](https://addons.wago.io/addons/simple-damage-meter)",
        logoUrl: "", screenshots: [], downloadCount: 30000, lastUpdated: new Date().toISOString(), gameVersions: [],
        wagoSlug: "simple-damage-meter"
      };
    }
    const entry = cfCatalogueMock.find(function (e) { return e.id === id; });
    if (entry) {
      return {
        source: "addon-radar", name: entry.name, slug: entry.slug,
        summary: entry.name + " helps you do useful things in World of Warcraft.",
        descriptionHtml: "<p>" + entry.name + " helps you do useful things in World of Warcraft.</p><ul><li>Reliable</li><li>Actively maintained</li></ul>",
        logoUrl: entry.logoUrl, screenshots: [{ id: 1, title: "Screenshot", description: "", thumbnail: "", url: "" }],
        downloadCount: entry.downloadCount, lastUpdated: entry.lastUpdated, gameVersions: ["12.1.0"]
      };
    }
    return { source: "catalogue-only", name: "Project " + id, slug: null, summary: null, downloadCount: null, lastUpdated: null, gameVersions: [] };
  }

  function delay(ms) { return new Promise(function (res) { setTimeout(res, ms); }); }

  // E12: an addon's Mock-side key, matching Store.addonKey exactly - a
  // "sync"/"install"/"rollback" job's params always carry this form (never
  // a numeric-only id for a Wago row), so every id-matching branch below
  // compares against it rather than bare a.projectId. Hoisted to module
  // scope (CS1) so both finalizeJobResults and the progress-step builder
  // below share one definition.
  function mockKey(a) { return a.source === "wago" ? "wago:" + a.slug : a.projectId; }

  // CS1 (UX-SPEC.md section 4.1/4.3): job kinds whose progress the real CLI
  // reports via progress.json - the same job kinds addon-server.ps1 threads
  // -ProgressPath for. Every other kind (remove/rollback/import/switch-
  // source) keeps the plain line-by-line log animation below, same as
  // before this pass.
  // Review fix: "launch" belongs here too when updateFirst is true (Update
  // & Play) - the real server always runs that as a full progress-tracked
  // sync before launching (see addon-server.ps1's Start-Job $cliKind
  // mapping); see buildProgressPlan's own "launch" branch below for how
  // updateFirst:false (Launch WoW, no update) still ends up with zero
  // targets and skips straight to the plain 300ms finish, matching the real
  // server's synchronous no-CLI-process path for that case.
  const PROGRESS_KINDS = ["sync", "check", "add", "install", "launch"];

  function jobLines(kind) {
    if (kind === "check") return ["Checking 5 addons against CurseForge...", "Auctionator: update available (5.21.0)", "Bagnon: update available (10.9)", "Check complete."];
    if (kind === "sync") return ["Syncing addons...", "Auctionator: downloading 5.21.0...", "Auctionator: installed.", "Sync complete."];
    if (kind === "add") return ["Resolving project...", "Downloading latest file...", "Installed."];
    if (kind === "remove") return ["Removing addon and its folders...", "Removed."];
    if (kind === "install") return ["Downloading selected version...", "Installed."];
    if (kind === "launch") return ["Running pre-launch sync...", "Sync complete.", "Launching World of Warcraft..."];
    if (kind === "rollback") return ["Restoring previous version from local backup...", "Rolled back."];
    if (kind === "import") return ["Adding new addons...", "Applying pinned versions...", "Applying ignore flags...", "Import complete."];
    return ["Working..."];
  }

  function finalizeJobResults(job, kind, params, forcedFailMockKey) {
      // CS1: forcedFailMockKey (the "sync" kind only - see
      // buildProgressPlan) makes exactly one otherwise-would-update addon
      // report Failed instead, so a mock "Update all" run reliably
      // exercises the done-with-failures panel without needing real
      // network flakiness. Every other kind ignores this parameter
      // entirely (nothing in this fixture set has a realistic per-addon
      // failure to force for them).
      if (kind === "check") {
        updatesCheckedAt = new Date().toISOString();
        job.results = [
          { status: "Would-update", name: "Auctionator", version: "5.21.0", projectId: 68304, fileId: 112 },
          { status: "Would-update", name: "Bagnon", version: "10.9", projectId: 24560, fileId: 91 }
        ];
      } else if (kind === "sync") {
        const ids = params && params.ids;
        addons.forEach(function (a) {
          // Review-fix follow-up: mirrors addon-sync.ps1's own
          // ExplicitTarget semantics (line ~2243/2528 - "-ExplicitTarget
          // means this record was named directly via -Only... which
          // (together with -Force) overrides ignoreUpdates") - an addon
          // named directly in `ids` (e.g. Actions.updateAll's now-scoped
          // sync job) is processed even if ignoreUpdates is set, same as
          // the real CLI; only an UNTARGETED ignoreUpdates addon in a
          // scope-less sync is skipped. Keeps the mock's own job.progress
          // total in step with the ids list the job panel's title is
          // built from.
          const explicit = !!(ids && ids.indexOf(mockKey(a)) !== -1);
          if (a.ignoreUpdates && !(params && params.force) && !explicit) return;
          if (ids && ids.indexOf(mockKey(a)) === -1) return;
          // CS2: every push here now also carries wagoSlug (null for a
          // CurseForge row) - the "add"/"install"/"switch-source" branches
          // already did this; a Wago row's sync result was previously the
          // one shape with no stable key at all (projectId is always null
          // for Wago), which silently broke both "What changed" (pre-
          // existing, see whatChangedButton's own null-key guard) and this
          // round's per-row Retry for a failed Wago sync result.
          const wagoSlug = a.source === "wago" ? a.slug : null;
          if (forcedFailMockKey && mockKey(a) === forcedFailMockKey) {
            job.results.push({ status: "Failed", name: a.name, version: a.version, projectId: a.projectId, fileId: a.fileId, wagoSlug: wagoSlug });
            return;
          }
          if (a.updateAvailable) {
            a.previousFileId = a.fileId;
            a.previousVersion = a.version;
            a.version = a.updateAvailable.version;
            a.fileId = a.updateAvailable.fileId;
            a.installedAt = new Date().toISOString();
            a.updateAvailable = null;
            job.results.push({ status: "Updated", name: a.name, version: a.version, projectId: a.projectId, fileId: a.fileId, wagoSlug: wagoSlug });
          } else {
            job.results.push({ status: "Up-to-date", name: a.name, version: a.version, projectId: a.projectId, fileId: a.fileId, wagoSlug: wagoSlug });
          }
        });
        // Review fix: carry projectId/wagoSlug through into lastRun.rows too
        // (job.results already had them) - Store.lastRunStatusFor now keys
        // off the addon's stable key rather than its display name, and
        // mirrors the real server's rows (a literal passthrough of the CLI's
        // -Json rows, which always include these fields).
        lastRun = { timestamp: new Date().toISOString(), summary: job.results.length + " processed", rows: job.results.map(function (r) { return { status: r.status, name: r.name, version: r.version, projectId: r.projectId, wagoSlug: r.wagoSlug }; }) };
      } else if (kind === "add") {
        // E12: a Wago add posts {source:'wago', slug, fileId?} instead of a
        // projectId (see Actions.installLatestWago/addByWagoSlug) - mirrors
        // the real server's Start-Job normalization, just inline here since
        // Mock has no separate CLI process to normalize params for.
        if (params.source === "wago" && params.slug) {
          const slug = params.slug;
          const existing = addons.find(function (a) { return a.source === "wago" && a.slug === slug; });
          if (existing) { job.results = [{ status: "Skipped", name: existing.name, version: existing.version, projectId: null, fileId: existing.fileId, wagoSlug: slug }]; return; }
          const name = "New Wago Addon (" + slug + ")";
          const fid = params.fileId || (slug + "-r1");
          const rec = { name: name, projectId: null, fileId: fid, version: "1.0.0", fileName: name + "-1.0.0.zip", installedAt: new Date().toISOString(), folders: [name], author: null, ignoreUpdates: false, pinnedFileId: params.fileId || null, releaseType: null, source: "wago", wagoId: null, slug: slug, curseId: null, updateAvailable: null };
          addons.push(rec);
          job.results = [{ status: "Installed", name: name, version: "1.0.0", projectId: null, fileId: fid, wagoSlug: slug }];
        } else {
          const pid = params.projectId;
          const name = "New Addon " + pid;
          const rec = { name: name, projectId: pid, fileId: params.fileId || pid * 10, version: "1.0.0", fileName: name + "-1.0.0.zip", installedAt: new Date().toISOString(), folders: [name], author: "SomeAuthor", ignoreUpdates: false, pinnedFileId: params.fileId || null, releaseType: null, updateAvailable: null };
          addons.push(rec);
          job.results = [{ status: "Installed", name: name, version: "1.0.0", projectId: pid, fileId: rec.fileId, wagoSlug: null }];
        }
      } else if (kind === "switch-source") {
        // E12: mirrors the real server's two-phase remove-then-add, but as
        // one atomic step here (Mock has no multi-phase job machinery).
        const oldKey = params.projectId;
        const idx = addons.findIndex(function (a) { return (a.source === "wago" ? "wago:" + a.slug : a.projectId) === oldKey; });
        const oldName = idx !== -1 ? addons[idx].name : "addon";
        if (idx !== -1) addons.splice(idx, 1);
        if (params.toSource === "wago") {
          const rec = { name: oldName, projectId: null, fileId: params.toTarget + "-r1", version: "1.0.0", fileName: oldName + "-1.0.0.zip", installedAt: new Date().toISOString(), folders: [oldName], author: null, ignoreUpdates: false, pinnedFileId: null, releaseType: null, source: "wago", wagoId: params.toTarget, slug: params.toTarget, curseId: null, updateAvailable: null };
          addons.push(rec);
          job.results = [{ status: "Installed", name: oldName, version: "1.0.0", projectId: null, fileId: rec.fileId, wagoSlug: rec.slug }];
        } else {
          const pid = Number(params.toTarget);
          const rec = { name: oldName, projectId: pid, fileId: pid * 10, version: "1.0.0", fileName: oldName + "-1.0.0.zip", installedAt: new Date().toISOString(), folders: [oldName], author: "SomeAuthor", ignoreUpdates: false, pinnedFileId: null, releaseType: null, updateAvailable: null };
          addons.push(rec);
          job.results = [{ status: "Installed", name: oldName, version: "1.0.0", projectId: pid, fileId: rec.fileId, wagoSlug: null }];
        }
        lastRun = { timestamp: new Date().toISOString(), summary: job.results.length + " processed", rows: job.results.map(function (r) { return { status: r.status, name: r.name, version: r.version, projectId: r.projectId, wagoSlug: r.wagoSlug }; }) };
      } else if (kind === "remove") {
        // E11: bulk uninstall posts projectIds (array); the single per-row
        // kebab "Uninstall" still posts a single projectId - normalize both
        // to one id list so this mirrors the real server's one-job,
        // one-result-row-per-id behavior either way.
        const removeIds = (params && params.projectIds && params.projectIds.length) ? params.projectIds : [params.projectId];
        job.results = [];
        removeIds.forEach(function (pid) {
          // E12: pid may be a "wago:<slug>" key as well as a numeric projectId.
          const idx = addons.findIndex(function (a) { return (a.source === "wago" ? "wago:" + a.slug : a.projectId) === pid; });
          if (idx !== -1) {
            job.results.push({ status: "Removed", name: addons[idx].name, version: addons[idx].version, projectId: addons[idx].projectId, wagoSlug: addons[idx].slug });
            addons.splice(idx, 1);
          }
        });
      } else if (kind === "install") {
        const a = addons.find(function (x) { return mockKey(x) === params.projectId; });
        if (a) {
          a.pinnedFileId = params.fileId;
          if (a.fileId !== params.fileId) { a.fileId = params.fileId; a.installedAt = new Date().toISOString(); job.results = [{ status: "Updated", name: a.name, version: a.version, projectId: a.projectId, fileId: a.fileId }]; }
          else { job.results = [{ status: "Pinned", name: a.name, version: a.version, projectId: a.projectId, fileId: a.fileId }]; }
        }
      } else if (kind === "launch") {
        // E5: mirrors addon-server.ps1's real behavior - updateFirst runs a
        // full sync (same per-addon logic as the "sync" branch above,
        // including a fresh lastRun) before the Launched row is appended, so
        // the results panel's per-row "What changed" control is exercisable
        // from Update & Play too, not just a plain install/sync.
        const updateFirst = params && params.updateFirst;
        job.results = [];
        if (updateFirst) {
          addons.forEach(function (a) {
            if (a.ignoreUpdates) { job.results.push({ status: "Ignored", name: a.name, version: a.version, projectId: a.projectId, fileId: a.fileId }); return; }
            // Review fix: mirrors "sync"'s own forcedFailMockKey handling
            // (see buildProgressPlan's "launch" branch) - without this, an
            // Update & Play run's forced-fail target reported "Updated" here
            // while job.progress's final write for it said "failed", which
            // both broke the done-with-failures panel for this kind and
            // disagreed with mapFinalPhase's own comment that job.results
            // and job.progress must always agree on a target's outcome.
            if (forcedFailMockKey && mockKey(a) === forcedFailMockKey) {
              job.results.push({ status: "Failed", name: a.name, version: a.version, projectId: a.projectId, fileId: a.fileId });
              return;
            }
            if (a.updateAvailable) {
              a.previousFileId = a.fileId;
              a.previousVersion = a.version;
              a.version = a.updateAvailable.version;
              a.fileId = a.updateAvailable.fileId;
              a.installedAt = new Date().toISOString();
              a.updateAvailable = null;
              job.results.push({ status: "Updated", name: a.name, version: a.version, projectId: a.projectId, fileId: a.fileId });
            } else {
              job.results.push({ status: "Up-to-date", name: a.name, version: a.version, projectId: a.projectId, fileId: a.fileId });
            }
          });
          lastRun = { timestamp: new Date().toISOString(), summary: job.results.length + " processed, then launched", rows: job.results.map(function (r) { return { status: r.status, name: r.name, version: r.version, projectId: r.projectId, wagoSlug: r.wagoSlug }; }) };
        }
        job.results.push({ status: "Launched", name: "World of Warcraft" });
      } else if (kind === "rollback") {
        const a = addons.find(function (x) { return mockKey(x) === params.projectId; });
        if (a && a.previousFileId !== null && a.previousFileId !== undefined) {
          const replacedFileId = a.fileId, replacedVersion = a.version;
          a.fileId = a.previousFileId;
          a.version = a.previousVersion;
          a.previousFileId = replacedFileId;
          a.previousVersion = replacedVersion;
          a.pinnedFileId = a.fileId;
          a.installedAt = new Date().toISOString();
          job.results = [{ status: "Rolled-back", name: a.name, version: a.version, projectId: a.projectId, fileId: a.fileId }];
        } else {
          job.results = [{ status: "Failed", name: a ? a.name : ("project " + params.projectId), version: a ? a.version : "", projectId: params.projectId, fileId: a ? a.fileId : null }];
        }
        // Mirrors the real server's Apply-JobCompletionSideEffects, which
        // refreshes $Script:LastRun for every job action except
        // check/files/scan - needed so the Pinned chip's rollback tooltip
        // (driven by Store.lastRunStatusFor) is exercisable under ?mock=1.
        lastRun = { timestamp: new Date().toISOString(), summary: job.results.length + " processed", rows: job.results.map(function (r) { return { status: r.status, name: r.name, version: r.version, projectId: r.projectId, wagoSlug: r.wagoSlug }; }) };
      } else if (kind === "import") {
        // E4: mirrors the real server's Build-ImportPlan/Start-ImportJob at a
        // simplified level - add whatever isn't already present, apply
        // pinnedFileId/ignoreUpdates to every imported entry (new or not),
        // one result row per addon either way.
        const importAddons = (params && params.addons) || [];
        job.results = [];
        importAddons.forEach(function (entry) {
          const existing = addons.find(function (a) { return a.projectId === entry.projectId; });
          if (!existing) {
            const name = entry.name || ("Project " + entry.projectId);
            const fid = entry.pinnedFileId || entry.projectId * 10;
            const rec = { name: name, projectId: entry.projectId, fileId: fid, version: "1.0.0", fileName: name + "-1.0.0.zip", installedAt: new Date().toISOString(), folders: [name], author: "SomeAuthor", ignoreUpdates: !!entry.ignoreUpdates, pinnedFileId: entry.pinnedFileId || null, releaseType: entry.releaseType || null, updateAvailable: null };
            addons.push(rec);
            job.results.push({ status: "Installed", name: name, version: "1.0.0", projectId: entry.projectId, fileId: fid });
          } else {
            if (entry.pinnedFileId) existing.pinnedFileId = entry.pinnedFileId;
            if (entry.ignoreUpdates) existing.ignoreUpdates = true;
            job.results.push({ status: "Skipped", name: existing.name, version: existing.version, projectId: existing.projectId, fileId: existing.fileId });
          }
        });
        lastRun = { timestamp: new Date().toISOString(), summary: job.results.length + " processed", rows: job.results.map(function (r) { return { status: r.status, name: r.name, version: r.version, projectId: r.projectId, wagoSlug: r.wagoSlug }; }) };
      }
  }

  function finishJob(job, kind, params, forcedFailMockKey) {
    job.state = "done";
    job.finishedAt = new Date().toISOString();
    job.exitCode = 0;
    finalizeJobResults(job, kind, params, forcedFailMockKey);
  }

  // CS1 (UX-SPEC.md section 4.1): builds the ordered list of addons a
  // progress-tracked job kind will step through, plus - for "sync" only -
  // which one (if any) should end Failed instead of Updated, so
  // runProgressJob and finalizeJobResults agree on the very same target.
  // Mirrors, at fixture-simulation fidelity, the filtering
  // Sync-SingleAddon's own caller (addon-sync.ps1's main loop) applies.
  // CS1: the final per-addon progress phase (UX-SPEC.md section 4.1 point
  // 5) is mapped from the SAME status word finalizeJobResults is about to
  // report for that addon - see mapFinalPhase below - so job.progress's
  // very last entry for a target always agrees with its row in job.results.
  function mapFinalPhase(status) {
    if (status === "Up-to-date") return "up_to_date";
    if (status === "Failed") return "failed";
    if (status === "Installed" || status === "Updated") return "done";
    return "done";
  }

  function buildProgressPlan(kind, params) {
    let targets = [];
    let forcedFailMockKey = null;
    if (kind === "sync") {
      const ids = params && params.ids;
      const force = params && params.force;
      // Review-fix follow-up: same ExplicitTarget-overrides-ignoreUpdates
      // rule as finalizeJobResults' own sync branch above (mirrors
      // addon-sync.ps1) - keeps this plan's own `total` (what the job
      // panel's live "Updating i of N" line reads) in step with the ids
      // list the panel's static title is built from.
      targets = addons.filter(function (a) {
        const explicit = !!(ids && ids.indexOf(mockKey(a)) !== -1);
        if (a.ignoreUpdates && !force && !explicit) return false;
        if (ids && ids.indexOf(mockKey(a)) === -1) return false;
        return true;
      }).map(function (a) { return { label: a.name, ref: a, status: a.updateAvailable ? "Updated" : "Up-to-date" }; });
      // The LAST target that would actually update is the one forced to
      // fail (see the CS1 note on finalizeJobResults) - picking the last
      // rather than the first keeps the earlier addons in a run showing
      // their ordinary Updated/Up-to-date progression before the one
      // failure, closer to how a real flaky-network run tends to land.
      for (let i = targets.length - 1; i >= 0; i--) {
        if (targets[i].ref.updateAvailable) { forcedFailMockKey = mockKey(targets[i].ref); targets[i].status = "Failed"; break; }
      }
    } else if (kind === "check") {
      targets = addons.map(function (a) { return { label: a.name, ref: a, status: "Up-to-date" }; });
    } else if (kind === "add") {
      const label = (params && params.source === "wago" && params.slug) ? ("New Wago Addon (" + params.slug + ")") : ("New Addon " + (params && params.projectId));
      targets = [{ label: label, ref: null, status: "Installed" }];
    } else if (kind === "install") {
      const a = addons.find(function (x) { return mockKey(x) === (params && params.projectId); });
      targets = [{ label: a ? a.name : ("project " + (params && params.projectId)), ref: a || null, status: "Installed" }];
    } else if (kind === "launch") {
      // Review fix: mirrors finalizeJobResults' own "launch" branch above -
      // updateFirst:false (Launch WoW, no update) leaves targets empty, so
      // runProgressJob's total===0 fast path fires and this job finishes in
      // ~300ms with no progress bar at all, matching the real server's
      // synchronous no-CLI-process path for that case. updateFirst:true
      // (Update & Play) walks every addon (not filtered by an `ids` list -
      // launch has none), mapping an ignored addon straight to "Ignored" so
      // it never becomes forced-fail bait.
      const updateFirst = params && params.updateFirst;
      if (updateFirst) {
        targets = addons.map(function (a) {
          if (a.ignoreUpdates) return { label: a.name, ref: a, status: "Ignored" };
          return { label: a.name, ref: a, status: a.updateAvailable ? "Updated" : "Up-to-date" };
        });
        for (let i = targets.length - 1; i >= 0; i--) {
          if (targets[i].status === "Updated") { forcedFailMockKey = mockKey(targets[i].ref); targets[i].status = "Failed"; break; }
        }
      }
    }
    return { targets: targets, forcedFailMockKey: forcedFailMockKey };
  }

  // CS1 (UX-SPEC.md section 4.1/4.3): drives job.progress through the same
  // {total,index,addon,phase} shape Write-ProgressStep writes CLI-side -
  // "checking" for every target, plus "downloading"/"installing" for the
  // kinds that actually install something ("check" is read-only, so it
  // only ever reaches "checking" per addon, exactly like a real -DryRun
  // never reaching Sync-SingleAddon's own downloading/installing writes).
  // Total run length is spread to land close to 6 seconds regardless of
  // how many targets this job has, and job.log still gets a line per step
  // so the Details disclosure has something to show.
  function runProgressJob(job, kind, params) {
    const plan = buildProgressPlan(kind, params);
    const targets = plan.targets;
    const total = targets.length;
    job.progress = { total: total, index: 0, addon: null, phase: "queued" };

    if (total === 0) {
      setTimeout(function () { finishJob(job, kind, params, null); }, 300);
      return;
    }

    const hasInstallPhases = kind === "sync" || kind === "add" || kind === "install" || kind === "launch";
    const phaseSeq = hasInstallPhases ? ["checking", "downloading", "installing"] : ["checking"];
    // +1 per target: phaseSeq's own steps, plus the one final mapped-phase
    // write after them (see nextPhase below) - both cost one setTimeout
    // tick each, so both must count toward spreading ~6 seconds evenly.
    const totalSteps = total * (phaseSeq.length + 1);
    const stepMs = Math.max(150, Math.round(6000 / Math.max(totalSteps, 1)));

    let t = 0;
    function nextTarget() {
      if (t >= total) {
        finishJob(job, kind, params, plan.forcedFailMockKey);
        return;
      }
      const target = targets[t];
      let p = 0;
      function nextPhase() {
        if (p >= phaseSeq.length) {
          // CS1: final per-addon write (UX-SPEC.md section 4.1 point 5) -
          // bump index NOW (this target is finished) and report the phase
          // mapped from its planned outcome, same as the real CLI's main
          // loop does right after Sync-SingleAddon returns.
          t++;
          const finalPhase = mapFinalPhase(target.status);
          const finalWrite = { total: total, index: t, addon: target.label, phase: finalPhase };
          // CS2: a forced-fail target also carries failPhase (UX-SPEC.md
          // section 4.1's CS1 addendum) - "downloading" exercises the
          // JobPanel's "Couldn't download the update" plain-language mapping
          // under ?mock=1 (CS1 left this unset, so the mock never actually
          // reached that branch).
          if (finalPhase === "failed") finalWrite.failPhase = "downloading";
          job.progress = finalWrite;
          job.log.push(target.label + ": " + target.status.toLowerCase() + ".");
          setTimeout(nextTarget, stepMs);
          return;
        }
        const phase = phaseSeq[p];
        const write = { total: total, index: t, addon: target.label, phase: phase };
        // Review fix (UX-SPEC.md 4.3/4.4): fake a partial byte count on the
        // "downloading" tick so ?mock=1 can exercise the client's new
        // "(NN%)" rendering - CS6's real writes are many throttled
        // sub-steps climbing to 100%, but this mock only gets one
        // "downloading" tick per target, so it fakes one plausible partial
        // value (not 0%, not 100%) rather than a real multi-step climb.
        if (phase === "downloading") {
          const fakeTotal = 400000 + ((target.label.length * 97531) % 9600000);
          write.bytesTotal = fakeTotal;
          write.bytesDone = Math.round(fakeTotal * 0.62);
        }
        job.progress = write;
        job.log.push(target.label + ": " + phase + "...");
        p++;
        setTimeout(nextPhase, stepMs);
      }
      nextPhase();
    }
    nextTarget();
  }

  function runJob(kind, params, flavourId) {
    if (currentJob && currentJob.state === "running") return null;
    const id = String(nextJobId++);
    const job = {
      // FLAVORS-SPEC.md CS-F4/S5.4: every job carries its own flavour - the
      // job panel's badge (Components.JobPanel) reads this the same way it
      // reads a real server job's field. Falls back to 'retail' the same
      // way the real server's job.flavour defaults for anything pre-CS-F2.
      id: id, kind: kind, flavour: flavourId || "retail", params: params || {}, state: "running",
      startedAt: new Date().toISOString(), finishedAt: null, exitCode: null,
      log: [], results: [], error: null, progress: null
    };
    currentJob = job;
    jobs.unshift(job);
    if (jobs.length > 20) jobs.length = 20;

    if (PROGRESS_KINDS.indexOf(kind) !== -1) {
      runProgressJob(job, kind, params);
      return job;
    }

    // Every other kind (remove/rollback/import/switch-source/launch) keeps
    // the plain line-by-line log animation - unchanged from before CS1,
    // and never gets a -ProgressPath server-side either (see Start-Job).
    const lines = jobLines(kind);
    let i = 0;
    const timer = setInterval(function () {
      if (i < lines.length) {
        job.log.push(lines[i]);
        i++;
        return;
      }
      clearInterval(timer);
      finishJob(job, kind, params, null);
    }, 420);

    return job;
  }

  return {
    enabled: true,
    async handle(method, path, body) {
      await delay(120 + Math.random() * 120);
      const u = new URL(path, "http://mock.local");
      const p = u.pathname;
      const q = u.searchParams;

      if (p === "/api/state") {
        // E13: fixed mock client build - matches the "ok" Auctionator/
        // "stale-minor" BigWigs fixtures seeded above.
        // CS1 (UX-SPEC.md sections 2.1/4.2): freshness/lastCheckFailed/
        // lastCheckError mirror the real server's Handle-State additions -
        // see mockFreshness above for how the enum is derived here.
        // FLAVORS-SPEC.md CS-F4 (S5.2): installedFlavours/activeFlavour are
        // now always present too (a 1-entry array at n=1, matching the real
        // server exactly) - requestedFlavour resolves the SAME way
        // Resolve-RequestFlavour does (explicit ?flavour=/?flavor=, else the
        // persisted activeFlavour setting, else the first installed one).
        // Retail's data is the untouched `addons`/`lastRun`/`currentJob`
        // fixture above; every other flavour reads its own small fixture
        // from mockFlavourExtra (read-only - no job simulation).
        const requestedFlavour = (q.get("flavour") || q.get("flavor") || "").toLowerCase() || mockSettings.activeFlavour || mockInstalledFlavours[0].id;
        const extra = requestedFlavour !== "retail" ? mockFlavourExtra[requestedFlavour] : null;
        const meta = mockInstalledFlavours.find(function (f) { return f.id === requestedFlavour; });
        const body = extra
          ? {
            addons: extra.addons.map(function (a) { return Object.assign({}, a); }),
            lastRun: extra.lastRun, job: null, updatesCheckedAt: extra.updatesCheckedAt,
            freshness: mockFreshnessForExtra(extra), lastCheckFailed: extra.lastCheckFailed, lastCheckError: extra.lastCheckError,
            clientBuild: meta ? meta.clientBuild : null, clientInterface: meta ? meta.clientInterface : null
          }
          : {
            addons: addons.map(function (a) { return Object.assign({}, a); }),
            lastRun: lastRun, job: currentJob, updatesCheckedAt: updatesCheckedAt,
            freshness: mockFreshness(), lastCheckFailed: lastCheckFailed, lastCheckError: lastCheckError,
            clientBuild: "12.1.0.69587", clientInterface: 120100
          };
        // Real server contract (addon-server.ps1 Handle-State): activeFlavour
        // and flavour are the exact SAME value - whichever flavour THIS
        // request resolved to - never the persisted settings.activeFlavour
        // read back independently (that's only ever a fallback INPUT to
        // resolution, never the OUTPUT). Mirrored here as requestedFlavour
        // for both fields, so a just-clicked pill's own explicit ?flavour=
        // is reflected immediately with no dependency on the separate,
        // fire-and-forget settings PUT having resolved first.
        return Object.assign({
          installedFlavours: mockInstalledFlavours, activeFlavour: requestedFlavour, flavour: requestedFlavour,
          settings: currentSettings()
        }, body);
      }
      // E19: ?mock=1&host=webview2 previews the native-host-only ad-filter
      // toggle branch without a real FurphyHost.exe - mirrors the real
      // server's own "sticky on the first GET / with that query" contract
      // closely enough for dev purposes (the mock has no separate
      // static-file route to hook, so this just reads the page's own URL).
      if (p === "/api/ping") return { ok: true, name: "Furphy Addon Manager", version: "mock-1.0", uptime: 1234, host: new URLSearchParams(location.search).get("host") === "webview2" ? "webview2" : "edge-app" };
      if (p === "/api/jobs" && method === "GET") return jobs.slice(0, 20);
      if (p.indexOf("/api/jobs/") === 0 && method === "GET") {
        const id = p.split("/").pop();
        const j = jobs.find(function (x) { return x.id === id; });
        if (!j) return { __status: 404, error: "not found" };
        return j;
      }
      if (p === "/api/jobs" && method === "POST") {
        // FLAVORS-SPEC.md CS-F4 (S5.4/S5.6): the bulk fan-out kind the
        // switcher's own "Update All" button posts - never a single job id,
        // always the {kind, jobs:[]} wrapper shape. Only Retail gets a real
        // simulated job (this mock's only fixture with live job machinery);
        // every other visible flavour gets a small already-"done" job
        // object (still real enough for Api.getJob/attachToJob to resolve),
        // matching the real server's per-flavour fan-out without building a
        // fuller multi-flavour job engine this mock doesn't otherwise have.
        if (body.kind === "update-all-flavours") {
          const showTest = !!mockSettings.showTestRealms;
          const hiddenIds = { ptr: true, xptr: true, beta: true };
          const targets = mockInstalledFlavours.filter(function (f) { return showTest || !hiddenIds[f.id]; });
          const jobsOut = targets.map(function (f) {
            if (f.id === "retail") {
              if (currentJob && currentJob.state === "running") return { flavour: f.id, busy: true, jobId: currentJob.id };
              const job = runJob("sync", {}, "retail");
              if (!job) return { flavour: f.id, busy: true };
              return { flavour: f.id, jobId: job.id };
            }
            const id = String(nextJobId++);
            const job = { id: id, kind: "sync", flavour: f.id, params: {}, state: "done", startedAt: new Date().toISOString(), finishedAt: new Date().toISOString(), exitCode: 0, log: [], results: [], error: null, progress: null };
            jobs.unshift(job);
            if (jobs.length > 20) jobs.length = 20;
            return { flavour: f.id, jobId: job.id };
          });
          return { __status: 202, kind: "update-all-flavours", jobs: jobsOut };
        }
        if (currentJob && currentJob.state === "running") return { __status: 409, error: "busy", jobId: currentJob.id };
        const job = runJob(body.kind, body, q.get("flavour") || q.get("flavor"));
        if (!job) return { __status: 409, error: "busy" };
        return { __status: 202, jobId: job.id };
      }
      // Review fix: these used to match `\d+` only, so a Wago-tracked
      // addon's key ("wago:<slug>", per Store.addonKey - the same key
      // Actions.toggleIgnore/unpin/ignoreSelected actually POST) never
      // matched here and fell through to the 404 catch-all. The real
      // server's own route (`[^/]+`, addon-server.ps1) already accepts
      // both shapes; mirror that here and look the addon up the same way
      // Store.addonKey resolves it instead of a numeric-only projectId.
      function findByKey(rawKey) {
        const key = decodeURIComponent(rawKey);
        if (key.indexOf("wago:") === 0) {
          const slug = key.slice(5);
          return addons.find(function (x) { return x.source === "wago" && x.slug === slug; });
        }
        return addons.find(function (x) { return x.projectId === Number(key); });
      }
      const ignoreMatch = p.match(/^\/api\/addons\/([^/]+)\/ignore$/);
      if (ignoreMatch && method === "POST") {
        const a = findByKey(ignoreMatch[1]);
        if (a) a.ignoreUpdates = !!body.ignore;
        return { addons: addons };
      }
      const unpinMatch = p.match(/^\/api\/addons\/([^/]+)\/unpin$/);
      if (unpinMatch && method === "POST") {
        const a = findByKey(unpinMatch[1]);
        if (a) a.pinnedFileId = null;
        return { addons: addons };
      }
      const filesMatch = p.match(/^\/api\/addons\/(\d+)\/files$/);
      if (filesMatch && method === "GET") {
        const pid = Number(filesMatch[1]);
        const a = addons.find(function (x) { return x.projectId === pid; });
        const files = [];
        for (let i = 0; i < 6; i++) {
          const fid = (a ? a.fileId : pid * 10) - i * 3 + (i === 0 ? 1 : 0);
          files.push({ id: fid, displayName: "v" + (6 - i) + ".0." + i, version: (6 - i) + ".0." + i, fileName: "file-" + fid + ".zip", dateCreated: new Date(Date.now() - i * 10 * 24 * 3600e3).toISOString(), releaseType: i === 1 ? 2 : (i === 4 ? 3 : 1), gameVersions: ["12.0.0"], fileLength: 40000 + i * 9000, downloads: 500000 - i * 4000, author: a ? a.author : "author", retail: true });
        }
        return { action: "files", projectId: pid, files: files };
      }
      // E4
      if (p === "/api/export" && method === "GET") {
        return {
          format: "wow-addon-manager/1",
          exportedAt: new Date().toISOString(),
          addons: addons.map(function (a) { return { projectId: a.projectId, name: a.name, pinnedFileId: a.pinnedFileId, ignoreUpdates: a.ignoreUpdates, releaseType: a.releaseType }; })
        };
      }
      if (p === "/api/import" && method === "POST") {
        if (!body || body.format !== "wow-addon-manager/1" || !Array.isArray(body.addons)) return { __status: 400, error: "bad request: unsupported format" };
        if (currentJob && currentJob.state === "running") return { __status: 409, error: "busy", jobId: currentJob.id };
        const job = runJob("import", body);
        if (!job) return { __status: 409, error: "busy" };
        return { __status: 202, jobId: job.id };
      }
      if (p === "/api/scan" && method === "GET") return { action: "scan", untracked: untracked };
      if (p === "/api/scan/delete" && method === "POST") {
        const idx = untracked.findIndex(function (x) { return x.folder === body.folder; });
        if (idx !== -1) untracked.splice(idx, 1);
        return { ok: true };
      }
      // E10: fixed, synthetic set of checks - same shape/order as the real
      // server's Handle-Diagnostics - so the Settings > Diagnostics panel is
      // exercisable under ?mock=1 without hitting the network at all.
      if (p === "/api/diagnostics" && method === "GET") {
        return {
          checks: [
            { name: "AddOns folder", ok: true, detail: "C:\\Program Files (x86)\\World of Warcraft\\_retail_\\Interface\\AddOns" },
            { name: "settings.json", ok: true, detail: "valid" },
            { name: "addons.json", ok: true, detail: addons.length + " records" },
            { name: "CurseForge reachability", ok: true, detail: "Reachable (HTTP 200)" },
            { name: "Disk space", ok: true, detail: "412.6 GB free on C:\\" },
            { name: "PowerShell version", ok: true, detail: "5.1.19041.4291" },
            { name: "Server uptime", ok: true, detail: "12m" },
            { name: "Last sync", ok: true, detail: lastRun ? lastRun.timestamp : "never" },
            // E13: mirrors the real server's Test-DiagClientBuild row.
            { name: "WoW client build", ok: true, detail: "12.1.0.69587" },
            // E16: mirrors the real server's Test-DiagCfCatalogue/Test-DiagAddonRadar rows.
            { name: "CurseForge catalogue cache", ok: true, detail: cfCatalogueMock.length + " entries, 0.1h old (instawow-data+strongbox)" },
            { name: "addon-radar reachability", ok: true, detail: "Reachable" }
          ]
        };
      }
      if (p === "/api/settings" && method === "GET") return currentSettings();
      if (p === "/api/settings" && method === "PUT") {
        if (typeof body.releaseType === "number") mockSettings.releaseType = body.releaseType;
        if (typeof body.autoUpdateOnLaunch === "boolean") mockSettings.autoUpdateOnLaunch = body.autoUpdateOnLaunch;
        if (typeof body.port === "number") mockSettings.port = body.port;
        if (typeof body.adFilter === "boolean") mockSettings.adFilter = body.adFilter;
        if (typeof body.cfFocus === "boolean") mockSettings.cfFocus = body.cfFocus;
        if (body.hostWindow !== undefined && body.hostWindow !== null) mockSettings.hostWindow = body.hostWindow;
        if (typeof body.backgroundUpdates === "boolean") mockSettings.backgroundUpdates = body.backgroundUpdates;
        if (typeof body.backgroundIntervalMinutes === "number") {
          mockSettings.backgroundIntervalMinutes = Math.max(30, Math.min(1440, body.backgroundIntervalMinutes));
        }
        if (typeof body.runAtStartup === "boolean") mockSettings.runAtStartup = body.runAtStartup;
        // FLAVORS-SPEC.md CS-F4/S3.4: activeFlavour is pure UI continuity -
        // silently ignored (never rejected) when it doesn't name one of this
        // mock's own installed flavours, matching the real server's own
        // never-load-bearing design.
        if (typeof body.activeFlavour === "string") {
          const candidate = body.activeFlavour.trim().toLowerCase();
          if (mockInstalledFlavours.some(function (f) { return f.id === candidate; })) mockSettings.activeFlavour = candidate;
        }
        if (typeof body.showTestRealms === "boolean") mockSettings.showTestRealms = body.showTestRealms;
        return currentSettings();
      }
      // Round 18 (tray stage B): fake tray/startup endpoints - see mockTray above.
      if (p === "/api/tray/status" && method === "GET") {
        return { running: mockTray.running, state: mockTray.state, startupRegistered: mockStartupRegistered };
      }
      if (p === "/api/tray/start" && method === "POST") {
        if (mockTray.running) return { __status: 409, error: "tray already running" };
        const now = new Date();
        const next = new Date(now.getTime() + mockSettings.backgroundIntervalMinutes * 60000);
        mockTray.running = true;
        mockTray.state = {
          running: true, pid: 99999, lastRunAt: now.toISOString(), lastResult: "up_to_date",
          updatedNames: [], failedNames: [], message: "Furphy - up to date", nextRunAt: next.toISOString()
        };
        return { __status: 202, ok: true };
      }
      if (p === "/api/tray/stop" && method === "POST") {
        if (!mockTray.running) return { ok: false, reason: "not running" };
        mockTray.running = false;
        if (mockTray.state) mockTray.state.running = false;
        return { ok: true };
      }
      if (p === "/api/startup/register" && method === "POST") {
        mockStartupRegistered = true;
        mockSettings.runAtStartup = true;
        return { ok: true, settings: currentSettings() };
      }
      if (p === "/api/startup/unregister" && method === "POST") {
        mockStartupRegistered = false;
        mockSettings.runAtStartup = false;
        return { ok: true, settings: currentSettings() };
      }
      if (p === "/api/startup/status" && method === "GET") {
        return { registered: mockStartupRegistered };
      }
      // E19 (script itself is E17's, unchanged) - mock curseforge:// handler
      // toggle, in-memory only.
      if (p === "/api/protocol/status" && method === "GET") {
        return { registered: protocolRegistered, currentHandler: protocolRegistered ? "wscript.exe \"...\\curseforge-handler.vbs\" \"%1\"" : "", handlerPath: "...\\curseforge-handler.vbs", handlerExists: true };
      }
      if (p === "/api/protocol/register" && method === "POST") {
        protocolRegistered = true;
        return { registered: true, currentHandler: "wscript.exe \"...\\curseforge-handler.vbs\" \"%1\"", handlerPath: "...\\curseforge-handler.vbs", handlerExists: true };
      }
      if (p === "/api/protocol/unregister" && method === "POST") {
        protocolRegistered = false;
        return { registered: false, currentHandler: "", handlerPath: "...\\curseforge-handler.vbs", handlerExists: true };
      }
      // Round 16 (E22, CurseForge key removal): /api/cf/enrich/* and
      // /api/cf/browse are the only CurseForge routes left - always keyless,
      // matching the real server (Handle-CfEnrich/Handle-CfBrowse never
      // needed a key even before the key feature was removed). Round 17
      // removed the third route, /api/cf/catalogue/refresh, along with the
      // manual "Refresh the addon list from CurseForge" button that was its
      // only caller - the catalogue itself still refreshes automatically.
      const enrichMatch = p.match(/^\/api\/cf\/enrich\/(\d+)$/);
      if (enrichMatch) return mockCfEnrich(Number(enrichMatch[1]));
      if (p === "/api/cf/browse") {
        const bq = (q.get("q") || "").toLowerCase();
        const items = cfCatalogueMock.filter(function (e) { return !bq || e.name.toLowerCase().indexOf(bq) !== -1; }).map(function (e) {
          return { id: e.id, name: e.name, slug: e.slug, downloadCount: e.downloadCount, lastUpdated: e.lastUpdated, source: "catalogue", logoUrl: e.logoUrl };
        });
        return { items: items, catalogueAge: cfCatalogueMockFetchedAt, total: items.length };
      }
      // E12 (Wago second source) - keyless, mirrors the real server's
      // /api/wago/* shapes closely enough to exercise Browse's Wago tab and
      // the drawer's Wago branches without a real server.
      if (p === "/api/wago/search") {
        const wq = (q.get("q") || "").toLowerCase();
        const list = wagoBrowsePool.filter(function (x) { return !wq || x.name.toLowerCase().indexOf(wq) !== -1; });
        return { items: list, page: 1, lastPage: 1, total: list.length };
      }
      if (p === "/api/wago/categories") return { data: wagoCategoriesMock };
      const wagoAddonMatch = p.match(/^\/api\/wago\/addons\/([^/]+)$/);
      if (wagoAddonMatch) {
        const slug = decodeURIComponent(wagoAddonMatch[1]);
        const found = wagoBrowsePool.find(function (x) { return x.slug === slug; }) || { slug: slug, name: slug };
        return {
          addon: { id: "MOCK" + slug, slug: slug, display_name: found.name, summary: "A tidy little Wago addon.", thumbnail_image: "", categories: [{ id: 1, display_name: "Utility" }], website: "", source_url: "", is_unlisted: false },
          description: "## " + found.name + "\nA **mock** description with a [link](https://addons.wago.io/addons/" + slug + ") for offline testing.\n- Fast\n- Lightweight",
          metadata: { last_update: new Date(Date.now() - 2 * 24 * 3600e3).toISOString(), download_count: 42000, like_count: 310, developers: [{ name: "MockDev" }] }
        };
      }
      const wagoReleasesMatch = p.match(/^\/api\/wago\/addons\/([^/]+)\/releases$/);
      if (wagoReleasesMatch) {
        const slug = decodeURIComponent(wagoReleasesMatch[1]);
        return { data: { data: fakeWagoReleases(slug), current_page: 1, last_page: 1, per_page: 10, total: 5 } };
      }
      const wagoGalleryMatch = p.match(/^\/api\/wago\/addons\/([^/]+)\/gallery$/);
      if (wagoGalleryMatch) return { gallery: { images: [] } };
      if (p === "/api/wago/resolve") {
        const url = q.get("url") || "";
        const m = url.match(/\/addons\/([a-z0-9-]+)/i);
        if (m) return { slug: m[1] };
        if (/^[a-z0-9-]+$/i.test(url)) return { slug: url };
        return { __status: 404, error: "not found" };
      }
      if (p === "/api/open" && method === "POST") return { ok: true };
      if (p === "/api/shutdown" && method === "POST") return { ok: true };
      return { __status: 404, error: "no mock route for " + method + " " + p };
    }
  };

  function currentSettings() {
    // Round 17: checkAddonVersion (E13's read-only WTF\Config.wtf display)
    // is gone - Eric: "WoW's out-of-date warning... get rid of this it
    // doesn't do anything."
    return {
      releaseType: mockSettings.releaseType, autoUpdateOnLaunch: mockSettings.autoUpdateOnLaunch, port: mockSettings.port,
      addonsPath: "C:\\Program Files (x86)\\World of Warcraft\\_retail_\\Interface\\AddOns", wowRoot: "C:\\Program Files (x86)\\World of Warcraft\\_retail_",
      adFilter: mockSettings.adFilter, cfFocus: mockSettings.cfFocus, hostWindow: mockSettings.hostWindow,
      // Round 18 (tray stage B)
      backgroundUpdates: mockSettings.backgroundUpdates, backgroundIntervalMinutes: mockSettings.backgroundIntervalMinutes, runAtStartup: mockSettings.runAtStartup,
      // FLAVORS-SPEC.md CS-F4 (S3.4/S5.2)
      activeFlavour: mockSettings.activeFlavour, showTestRealms: mockSettings.showTestRealms
    };
  }
})();

/* ==========================================================================
   Utils
   ========================================================================== */
const Utils = (function () {
  function qs(sel, root) { return (root || document).querySelector(sel); }
  function qsa(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        const v = attrs[k];
        if (v === undefined || v === null || v === false) return;
        if (k === "class") node.className = v;
        else if (k === "dataset") Object.keys(v).forEach(function (dk) { node.dataset[dk] = v[dk]; });
        else if (k.indexOf("on") === 0 && typeof v === "function") node.addEventListener(k.slice(2), v);
        else if (k === "text") node.textContent = v;
        else if (v === true) node.setAttribute(k, "");
        else node.setAttribute(k, v);
      });
    }
    (children || []).forEach(function (c) {
      if (c === null || c === undefined || c === false) return;
      node.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    });
    return node;
  }

  function icon(name, extraClass) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "icon" + (extraClass ? " " + extraClass : ""));
    const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
    use.setAttribute("href", "#icon-" + name);
    svg.appendChild(use);
    return svg;
  }

  function escapeHtml(str) {
    const d = document.createElement("div");
    d.textContent = str === undefined || str === null ? "" : String(str);
    return d.innerHTML;
  }

  function debounce(fn, ms) {
    let t = null;
    return function () {
      const args = arguments, ctx = this;
      clearTimeout(t);
      t = setTimeout(function () { fn.apply(ctx, args); }, ms);
    };
  }

  function relativeTime(iso) {
    if (!iso) return "never";
    const then = new Date(iso).getTime();
    if (isNaN(then)) return "never";
    const diff = Math.max(0, Date.now() - then);
    const s = Math.floor(diff / 1000);
    if (s < 10) return "just now";
    if (s < 60) return s + "s ago";
    const m = Math.floor(s / 60);
    if (m < 60) return m + " min ago";
    const h = Math.floor(m / 60);
    if (h < 24) return h + (h === 1 ? " hour ago" : " hours ago");
    const dys = Math.floor(h / 24);
    if (dys < 30) return dys + (dys === 1 ? " day ago" : " days ago");
    const mo = Math.floor(dys / 30);
    if (mo < 12) return mo + (mo === 1 ? " month ago" : " months ago");
    const y = Math.floor(mo / 12);
    return y + (y === 1 ? " year ago" : " years ago");
  }

  function fullDate(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    return d.toLocaleString(undefined, { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
  }

  function formatBytes(n) {
    if (!n && n !== 0) return "-";
    if (n < 1024) return n + " B";
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB";
    return (n / (1024 * 1024)).toFixed(1) + " MB";
  }

  function formatNumber(n) {
    if (n === undefined || n === null) return "-";
    return n.toLocaleString(undefined);
  }

  function releaseLabel(rt) {
    return rt === 3 ? "Alpha" : rt === 2 ? "Beta" : "Release";
  }

  function releaseChipClass(rt) {
    return rt === 3 ? "chip-danger" : rt === 2 ? "chip-warning" : "chip-success";
  }

  // Deterministic pastel-ish color from a string, used for logo fallback circles.
  // .addon-logo-fallback (style.css) paints the initial in a fixed white -
  // every hue this can produce must stay dark enough for that white text to
  // hit WCAG AA (4.5:1). At this saturation the worst case is yellow (hue
  // ~60, where R and G both peak and B is 0 - the highest weighted
  // luminance the HSL wheel can produce here): 40% lightness only reaches
  // ~3.3:1 there. 30% keeps every hue, including that one, above 5:1.
  function colorForName(name) {
    let hash = 0;
    for (let i = 0; i < name.length; i++) hash = (hash * 31 + name.charCodeAt(i)) >>> 0;
    const hue = hash % 360;
    return "hsl(" + hue + ", 45%, 30%)";
  }

  function firstLetter(name) {
    const t = (name || "?").trim();
    // Round 9 fix: a name that starts with punctuation (CurseForge's common
    // "<Camera> Max Distance" color-code-bracket naming style) used to fall
    // back to a bare "<" instead of a letter, in both the My Addons row logo
    // and the drawer header logo (both go through Components.Logo.build ->
    // here). Skip past any leading non-alphanumeric characters and take the
    // first real letter/digit instead; "?" only when there is none at all.
    const m = t.match(/[A-Za-z0-9]/);
    return m ? m[0].toUpperCase() : "?";
  }

  // E12 (Wago second source): an addon's "id" is a number (its CurseForge
  // projectId) for a CurseForge-sourced record, or the string "wago:<slug>"
  // for a Wago-sourced one (which has no numeric projectId at all - see
  // Store.addonKey). Every place that used to do a bare Number(id) before
  // posting a job/looking up a record now goes through this instead, so a
  // "wago:..." key passes through untouched instead of becoming NaN.
  function normalizeId(id) {
    if (typeof id === "string" && id.toLowerCase().indexOf("wago:") === 0) return id;
    return Number(id);
  }

  // E13 (compatibility audit): converts a numeric toc/client Interface value
  // (major*10000 + minor*100 + patch, e.g. 120100) back into the dotted
  // "major.minor.patch" form addon devs and CurseForge/Wago both use
  // (e.g. "12.1.0"). Returns null for a non-finite/missing input.
  function interfaceToVersion(n) {
    const iface = Number(n);
    if (!isFinite(iface) || iface <= 0) return null;
    const major = Math.floor(iface / 10000);
    const minor = Math.floor((iface % 10000) / 100);
    const patch = iface % 100;
    return major + "." + minor + "." + patch;
  }

  // E13: turns one addon's compat (from /api/state, computed server-side)
  // into a {label, cls} pair. CS5 (UX-SPEC.md 3.5/§7): rewritten to use the
  // exact same plain words as the table's Status pill ("Built for 12.1" /
  // "Old patch" / "Won't work this patch") - "the same plain words... no
  // separate restatement, no raw interface-version numbers." The old
  // {title} field (a raw "Toc Interface: 120100 (12.1.0) ..." tooltip
  // string) is deleted outright along with its only caller - that was the
  // hidden hover tooltip the spec already deletes from the table, now also
  // removed from here rather than left as a second, differently-worded
  // restatement in the drawer. clientInterface comes from
  // Store.state.clientInterface, passed in rather than read directly so
  // this stays a pure function like the rest of Utils.
  function compatDisplay(addon, clientInterface) {
    const compat = addon && addon.compat;
    const clientVersion = interfaceToVersion(clientInterface);
    const clientMajorMinor = clientVersion ? clientVersion.split(".").slice(0, 2).join(".") : null;

    if (compat === "ok") return { label: "Built for " + (clientMajorMinor || "current patch"), cls: "chip-success" };
    if (compat === "stale-minor") return { label: "Old patch", cls: "chip-warning" };
    if (compat === "stale") return { label: "Won't work this patch", cls: "chip-danger" };
    return { label: "Unknown", cls: "chip-muted" };
  }

  // Review fix: factored out of Components.JobPanel (which had the only
  // copy) so Components.Chip.forStatus can render a row's own live phase
  // with the exact same word the JobPanel's current-item line uses for that
  // same addon at that same instant (UX-SPEC.md 4.3: "same wording, same
  // source data, intentionally kept").
  function phaseWord(phase) {
    const map = { queued: "Queued", checking: "Checking", downloading: "Downloading", installing: "Installing", up_to_date: "Up to date", done: "Done", failed: "Failed" };
    return map[phase] || (phase || "");
  }

  return {
    qs: qs, qsa: qsa, el: el, icon: icon, escapeHtml: escapeHtml, debounce: debounce, relativeTime: relativeTime, fullDate: fullDate, formatBytes: formatBytes, formatNumber: formatNumber, releaseLabel: releaseLabel, releaseChipClass: releaseChipClass, colorForName: colorForName, firstLetter: firstLetter, normalizeId: normalizeId,
    interfaceToVersion: interfaceToVersion, compatDisplay: compatDisplay, phaseWord: phaseWord
  };
})();

/* ==========================================================================
   Sanitize - strips upstream (CurseForge) HTML down to a safe subset before
   it is ever inserted into the DOM.
   ========================================================================== */
const Sanitize = (function () {
  const ALLOWED_TAGS = { P: 1, BR: 1, B: 1, STRONG: 1, I: 1, EM: 1, U: 1, UL: 1, OL: 1, LI: 1, A: 1, IMG: 1, H1: 1, H2: 1, H3: 1, H4: 1, BLOCKQUOTE: 1, CODE: 1, PRE: 1, SPAN: 1, DIV: 1, TABLE: 1, THEAD: 1, TBODY: 1, TR: 1, TD: 1, TH: 1, HR: 1, SMALL: 1 };
  const ALLOWED_ATTRS = { A: ["href", "title"], IMG: ["src", "alt", "title"] };

  function safeUrl(url) {
    try {
      const u = new URL(url, location.href);
      if (u.protocol === "http:" || u.protocol === "https:") return u.href;
    } catch (e) { /* fall through */ }
    return null;
  }

  function clean(node) {
    Array.prototype.slice.call(node.childNodes).forEach(function (child) {
      if (child.nodeType === Node.TEXT_NODE) return;
      if (child.nodeType !== Node.ELEMENT_NODE) { node.removeChild(child); return; }
      const tag = child.tagName;
      if (tag === "SCRIPT" || tag === "STYLE" || tag === "IFRAME" || tag === "OBJECT" || tag === "EMBED" || tag === "LINK" || tag === "META") {
        child.remove();
        return;
      }
      if (!ALLOWED_TAGS[tag]) {
        // Unwrap unknown tags: keep their children, drop the wrapper.
        while (child.firstChild) node.insertBefore(child.firstChild, child);
        node.removeChild(child);
        clean(node);
        return;
      }
      // Strip every attribute except the small allowlist for this tag.
      const keep = ALLOWED_ATTRS[tag] || [];
      Array.prototype.slice.call(child.attributes).forEach(function (attr) {
        if (keep.indexOf(attr.name) === -1) child.removeAttribute(attr.name);
      });
      if (tag === "A") {
        const href = child.getAttribute("href");
        const safe = href ? safeUrl(href) : null;
        if (safe) { child.setAttribute("href", safe); child.setAttribute("target", "_blank"); child.setAttribute("rel", "noopener noreferrer"); }
        else { child.removeAttribute("href"); }
      }
      if (tag === "IMG") {
        const src = child.getAttribute("src");
        const safe = src ? safeUrl(src) : null;
        if (safe) child.setAttribute("src", safe);
        else { child.remove(); return; }
        child.setAttribute("loading", "lazy");
      }
      clean(child);
    });
  }

  function toSafeFragment(html) {
    const doc = new DOMParser().parseFromString(String(html || ""), "text/html");
    clean(doc.body);
    const frag = document.createDocumentFragment();
    Array.prototype.slice.call(doc.body.childNodes).forEach(function (n) { frag.appendChild(n); });
    return frag;
  }

  // Renders sanitized upstream HTML into `container` (replacing its contents).
  function render(container, html) {
    container.textContent = "";
    container.appendChild(toSafeFragment(html));
  }

  return { render: render };
})();

/* ==========================================================================
   Markdown (E12) - a deliberately minimal markdown-to-HTML converter for
   Wago's description/changelog text (SPEC documents both as "markdown", not
   HTML like CurseForge's own description/changelog endpoints). Covers just
   headings, bold, italic, links, and lists per the roadmap's own "a minimal
   markdown-to-HTML converter for headings/bold/lists/links is fine,
   sanitized" - the output is HTML markup, still always run through
   Sanitize.render before insertion, exactly like CurseForge's HTML
   descriptions/changelogs already are, so a malicious/malformed markdown
   link or heading can't smuggle anything unsafe through either.
   ========================================================================== */
const Markdown = (function () {
  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function inline(text) {
    let s = escapeHtml(text);
    s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2">$1</a>');
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/(^|[^*])\*([^*]+)\*(?!\*)/g, "$1<em>$2</em>");
    return s;
  }

  function toHtml(md) {
    const lines = String(md == null ? "" : md).replace(/\r\n/g, "\n").split("\n");
    const out = [];
    let listOpen = false;
    let para = [];

    function flushPara() {
      if (para.length) { out.push("<p>" + para.join(" ") + "</p>"); para = []; }
    }
    function closeList() {
      if (listOpen) { out.push("</ul>"); listOpen = false; }
    }

    lines.forEach(function (raw) {
      const line = raw.trim();
      const heading = line.match(/^(#{1,6})\s+(.*)$/);
      const item = line.match(/^[-*]\s+(.*)$/);
      if (heading) {
        flushPara(); closeList();
        const level = heading[1].length;
        out.push("<h" + level + ">" + inline(heading[2]) + "</h" + level + ">");
      } else if (item) {
        flushPara();
        if (!listOpen) { out.push("<ul>"); listOpen = true; }
        out.push("<li>" + inline(item[1]) + "</li>");
      } else if (line.length === 0) {
        flushPara(); closeList();
      } else if (listOpen) {
        // Round 8 fix: a bullet item's text that wraps onto an indented
        // continuation line (no marker of its own - standard CommonMark
        // "lazy continuation") used to unconditionally close the list here
        // and start a new paragraph, shredding a normal multi-line bullet
        // into a run of disconnected, bullet-less fragments. Append the
        // continuation text onto the still-open last <li> instead.
        const last = out.length - 1;
        out[last] = out[last].replace(/<\/li>$/, " " + inline(line) + "</li>");
      } else {
        para.push(inline(line));
      }
    });
    flushPara(); closeList();
    return out.join("");
  }

  return { toHtml: toHtml };
})();

/* ==========================================================================
   Api - JSON fetch wrapper around the server's HTTP API (routed through
   Mock instead when the page was opened with ?mock=1).
   ========================================================================== */
const Api = (function () {
  function ApiError(status, data) {
    const err = new Error((data && (data.error || data.message)) || ("HTTP " + status));
    err.name = "ApiError";
    err.status = status;
    err.data = data || {};
    return err;
  }

  // FLAVORS-SPEC.md CS-F4/S5.1: the exact same fixed, addon-scoped endpoint
  // set addon-server.ps1's own $Script:FlavourScopedEndpoints enumerates
  // server-side. Mirrored here so request() below can auto-append the
  // active flavour's ?flavour= to exactly these calls, and only once more
  // than one flavour is installed - never otherwise, so a single-flavour
  // machine's requests stay byte-identical to before this change set
  // (principle 2). Add a new addon-scoped endpoint here AND to the server's
  // own list - never scatter this per call site.
  const FLAVOUR_SCOPED_PATTERNS = [
    { method: "GET", re: /^\/api\/state$/ },
    { method: "POST", re: /^\/api\/addons\/[^/]+\/ignore$/ },
    { method: "POST", re: /^\/api\/addons\/[^/]+\/unpin$/ },
    { method: "GET", re: /^\/api\/addons\/[^/]+\/files$/ },
    { method: "GET", re: /^\/api\/scan$/ },
    { method: "POST", re: /^\/api\/scan\/delete$/ },
    { method: "GET", re: /^\/api\/export$/ },
    { method: "POST", re: /^\/api\/import$/ },
    { method: "GET", re: /^\/api\/wago\/search$/ }
  ];
  function needsFlavourParam(method, pathname) {
    return FLAVOUR_SCOPED_PATTERNS.some(function (p) { return p.method === method && p.re.test(pathname); });
  }

  async function request(method, path, body) {
    // FLAVORS-SPEC.md CS-F4: auto-append ?flavour=<active> to the fixed
    // addon-scoped endpoint set above - but only once Store.hasMultipleFlavours()
    // (raw installed count > 1, matching the server's own gate exactly) and
    // only when the caller hasn't already named one (postJob's own optional
    // flavour arg, or resumeJobWithFlavour's explicit pick, both win). A
    // single-flavour machine never sends the param at all - byte-identical
    // URLs to before this change set.
    let finalPath = path;
    if (Store.hasMultipleFlavours() && Store.state.activeFlavour) {
      const qIdx = path.indexOf("?");
      const pathname = qIdx === -1 ? path : path.slice(0, qIdx);
      const alreadyHasFlavour = qIdx !== -1 && /[?&](flavour|flavor)=/.test(path.slice(qIdx));
      if (!alreadyHasFlavour && needsFlavourParam(method, pathname)) {
        finalPath = path + (qIdx === -1 ? "?" : "&") + "flavour=" + encodeURIComponent(Store.state.activeFlavour);
      }
    }

    if (Mock.enabled) {
      const result = await Mock.handle(method, finalPath, body);
      const status = (result && result.__status) || 200;
      const data = result ? Object.assign({}, result) : {};
      delete data.__status;
      if (status >= 400) throw ApiError(status, data);
      return data;
    }

    let res;
    try {
      res = await fetch(finalPath, {
        method: method,
        headers: body ? { "Content-Type": "application/json; charset=utf-8" } : undefined,
        body: body ? JSON.stringify(body) : undefined
      });
    } catch (networkErr) {
      const err = ApiError(0, { error: "network" });
      err.isNetworkError = true;
      throw err;
    }

    let data = null;
    const text = await res.text();
    if (text) { try { data = JSON.parse(text); } catch (e) { data = { raw: text }; } }

    if (!res.ok) throw ApiError(res.status, data || {});
    return data;
  }

  // FLAVORS-SPEC.md CS-F3/S5.5's exact carve-out (Handle-JobsPost, addon-
  // server.ps1), mirrored here so postJob below can default the SAME set of
  // job kinds to the active flavour without defeating the CurseForge
  // install-flavour ask flow: a genuine single-target CurseForge add/
  // install/add-by-slug (never a bulk add, never a Wago target) must reach
  // the server with NO ?flavour= at all when the caller didn't name one, so
  // Start-Job's own auto/refuse/ask resolution (S5.5) can run. Every other
  // kind - sync/check/remove/rollback/switch-source/launch/import, a bulk
  // add, or any Wago-sourced add/install - is scoped to one flavour's own
  // addons.json/AddOns folder already, so it needs the active flavour
  // supplied automatically or the server 400s "flavour required".
  function isSkipFlavourGateKind(kind, params) {
    const p = params || {};
    const hasWagoSourceSlug = !!(p.source && p.slug);
    const hasMultiAdd = !!(p.projectIds && p.projectIds.length);
    const bodyHasSingleProjectId = !!p.projectId;
    const isSingleCfInstallKind = (kind === "add" && bodyHasSingleProjectId && !hasMultiAdd) || kind === "install" || kind === "add-by-slug";
    if (!isSingleCfInstallKind) return false;
    const pidText = (p.projectId !== undefined && p.projectId !== null) ? String(p.projectId) : "";
    const targetsWago = hasWagoSourceSlug || pidText.toLowerCase().indexOf("wago:") === 0;
    return !targetsWago;
  }

  function qs(params) {
    const usp = new URLSearchParams();
    Object.keys(params || {}).forEach(function (k) {
      const v = params[k];
      if (v === undefined || v === null || v === "") return;
      usp.set(k, v);
    });
    const s = usp.toString();
    return s ? "?" + s : "";
  }

  return {
    getState: function () { return request("GET", "/api/state"); },
    ping: function () { return request("GET", "/api/ping"); },

    // FLAVORS-SPEC.md CS-F3/CS-F4: optional third arg names a flavour
    // explicitly (the install-flavour picker's resume POST, Actions.
    // resumeJobWithFlavour) - always wins outright. Otherwise (CS-F4), every
    // OTHER job kind except update-all-flavours and a genuine single-target
    // CurseForge add/install/add-by-slug (isSkipFlavourGateKind above - that
    // one must reach the server with no ?flavour= at all so its own S5.5
    // ask/auto resolution can run) is auto-scoped to the active flavour once
    // more than one is installed - every existing call site (checkForUpdates,
    // updateAll, updateAndPlay, etc.) needs no change of its own. At n<=1
    // flavour this is always undefined, so every URL/body stays exactly
    // what it was before this change set.
    postJob: function (kind, params, flavour) {
      let effectiveFlavour = flavour;
      if (effectiveFlavour === undefined && kind !== "update-all-flavours" && Store.hasMultipleFlavours() && !isSkipFlavourGateKind(kind, params)) {
        effectiveFlavour = Store.state.activeFlavour;
      }
      return request("POST", "/api/jobs" + qs({ flavour: effectiveFlavour }), Object.assign({ kind: kind }, params || {}));
    },
    getJob: function (id) { return request("GET", "/api/jobs/" + encodeURIComponent(id)); },
    listJobs: function () { return request("GET", "/api/jobs"); },

    setIgnore: function (projectId, ignore) { return request("POST", "/api/addons/" + projectId + "/ignore", { ignore: ignore }); },
    unpin: function (projectId) { return request("POST", "/api/addons/" + projectId + "/unpin"); },
    getAddonFiles: function (projectId) { return request("GET", "/api/addons/" + projectId + "/files"); },

    scan: function () { return request("GET", "/api/scan"); },
    scanDelete: function (folder) { return request("POST", "/api/scan/delete", { folder: folder }); },

    // E4: exportAddons's response IS the file body (format/exportedAt/addons) -
    // no {kind} wrapper, unlike postJob - and importAddons posts that same
    // shape straight back to /api/import, which starts job kind "import".
    exportAddons: function () { return request("GET", "/api/export"); },
    importAddons: function (payload) { return request("POST", "/api/import", payload); },

    getSettings: function () { return request("GET", "/api/settings"); },
    putSettings: function (patch) { return request("PUT", "/api/settings", patch); },
    getDiagnostics: function () { return request("GET", "/api/diagnostics"); },

    // E19 (script itself is E17's, unchanged) - the curseforge:// install-
    // link handler toggle in Settings > Game and the Browse > CurseForge pane.
    protocolStatus: function () { return request("GET", "/api/protocol/status"); },
    protocolRegister: function () { return request("POST", "/api/protocol/register", {}); },
    protocolUnregister: function () { return request("POST", "/api/protocol/unregister", {}); },

    // Round 18 (tray stage B): start/stop the background-updater tray
    // process and read its live state; register/unregister is the "Start
    // with Windows" HKCU Run value.
    getTrayStatus: function () { return request("GET", "/api/tray/status"); },
    startTray: function () { return request("POST", "/api/tray/start", {}); },
    stopTray: function () { return request("POST", "/api/tray/stop", {}); },
    registerStartup: function () { return request("POST", "/api/startup/register", {}); },
    unregisterStartup: function () { return request("POST", "/api/startup/unregister", {}); },

    // E16: keyless CurseForge enrichment (Round 16, E22: the only
    // CurseForge fetch path left, now that the key-gated search/mod/
    // description/files/changelog/resolve endpoints are gone). Round 17
    // removed the manual "Refresh the addon list from CurseForge" button and
    // its cfCatalogueRefresh call - the catalogue still refreshes itself
    // automatically (Load/Save-CfCatalogueIndex, once/24h) with no UI action.
    cfEnrich: function (id) { return request("GET", "/api/cf/enrich/" + id); },
    cfBrowse: function (params) { return request("GET", "/api/cf/browse" + qs(params)); },

    // E12 (Wago second source): keyless, no NoKey/409 handling needed -
    // Wago never requires an API key.
    wagoSearch: function (params) { return request("GET", "/api/wago/search" + qs(params)); },
    wagoCategories: function () { return request("GET", "/api/wago/categories"); },
    wagoAddon: function (slug) { return request("GET", "/api/wago/addons/" + encodeURIComponent(slug)); },
    wagoReleases: function (slug, params) { return request("GET", "/api/wago/addons/" + encodeURIComponent(slug) + "/releases" + qs(params)); },
    wagoGallery: function (slug) { return request("GET", "/api/wago/addons/" + encodeURIComponent(slug) + "/gallery"); },
    wagoResolve: function (url) { return request("GET", "/api/wago/resolve" + qs({ url: url })); },

    openWhat: function (what, extra) { return request("POST", "/api/open", Object.assign({ what: what }, extra || {})); },
    shutdown: function () { return request("POST", "/api/shutdown"); }
  };
})();

/* ==========================================================================
   Store - central client-side state. Views read from Store.state and call
   render functions directly after mutating it (no virtual-DOM diffing -
   the app is small enough that targeted re-renders are simpler and cheaper).
   ========================================================================== */
const Store = (function () {
  // E7: the active sort column/direction for My Addons persists across
  // reloads (a plain localStorage read, done here rather than in Views.myAddons
  // so the very first render already reflects it instead of a default flash).
  const SORT_PREF_KEY = "addonSync.myaddonsSort.v1";
  function loadSortPref() {
    try {
      const raw = JSON.parse(localStorage.getItem(SORT_PREF_KEY) || "null");
      if (raw && typeof raw.column === "string" && (raw.dir === "asc" || raw.dir === "desc")) return raw;
    } catch (e) { /* storage unavailable/corrupt - fall back to the default below */ }
    return { column: "name", dir: "asc" };
  }

  // Round 15: the Get new addons segmented switch's last choice persists
  // across reloads (default Wago) - same "read once here so the first
  // render already reflects it" reasoning as loadSortPref above. A
  // ?tab=wago|curseforge query param (see App.applyInitialViewFromQuery)
  // overrides this once, on load only.
  const BROWSE_TAB_KEY = "addonSync.browseTab.v1";
  function loadBrowseTabPref() {
    try {
      const raw = localStorage.getItem(BROWSE_TAB_KEY);
      if (raw === "wago" || raw === "curseforge") return raw;
    } catch (e) { /* storage unavailable - fall back to the default below */ }
    return "wago";
  }

  const state = {
    view: "myaddons",          // 'myaddons' | 'browse' | 'settings'
    online: null,               // null = unknown yet, else true/false
    loadingState: true,
    stateError: null,

    addons: [],
    settings: null,
    lastRun: null,
    job: null,
    jobLabel: null,        // client-chosen human title for the job panel, set by Actions.startJob
    updatesCheckedAt: null,
    // CS2 (UX-SPEC.md sections 2.1/4.2): the one server-computed freshness
    // enum ('not_checked'|'checking'|'up_to_date'|'updates_available'|
    // 'check_failed') plus the two failure-detail fields CS1 added to
    // /api/state - read by Components.Freshness, never derived client-side
    // from other fields (per the spec's own rule).
    freshness: null,
    lastCheckFailed: false,
    lastCheckError: null,
    // E13 (compatibility audit): the WoW client's own build string/Interface
    // number, from /api/state (server reads .build.info once at startup).
    clientBuild: null,
    clientInterface: null,

    myaddonsSearch: "",
    myaddonsFilter: "all",   // 'all' | 'updates' | 'pinned' | 'ignored' | 'failed' | 'missingdeps'
    myaddonsSort: loadSortPref(),   // {column: 'name'|'installed'|'latest'|'status'|'updated', dir: 'asc'|'desc'}
    myaddonsSelection: [],   // E11: array of checked projectIds, driving the checkbox column/selection bar. Not persisted - resets on reload like search/filter.

    // Round 15: replaces CS3's merged CurseForge+Wago search with a
    // segmented [Wago | CurseForge] switch (see UX-SPEC.md section 5,
    // rewritten this round) - Wago keeps its own in-app search (query/
    // loading/loaded/error/results); CurseForge is the real curseforge.com
    // site rendered by the native host (or a fallback panel), tracked
    // separately by Host.getCfState()/Host.hasCfPane(), not here.
    browse: {
      tab: loadBrowseTabPref(),   // 'wago' | 'curseforge'
      query: "",
      wago: { loading: false, loaded: false, error: null, results: [] }
    },

    drawer: {
      open: false,
      // E12: projectId is now the addon's general KEY - a number for
      // CurseForge (unchanged), or the string "wago:<slug>" for Wago (see
      // Store.addonKey / Utils.normalizeId). source records which so every
      // drawer render function knows which branch to take.
      projectId: null,
      source: "cf-keyless",   // 'cf-keyless' | 'wago'
      slug: null,
      tracked: false,        // true when this project has a local addon record
      tab: "overview",
      lastKnownFileId: null,  // addon.fileId as of the last open()/refresh() - lets refresh() detect an update
      files: null,
      filesLoading: false,
      filesError: null,
      changelogFileId: null,
      changelogHtml: null,
      changelogLoading: false,
      screenshotsLoaded: false,
      // E12 Wago-specific drawer state (all $null/unused for a CurseForge drawer).
      wagoAddon: null,          // {addon, description, metadata} from /api/wago/addons/{slug}
      wagoAddonLoading: false,
      wagoAddonError: null,
      wagoReleases: null,       // flat array (this build fetches page 1 only - see renderVersions)
      wagoReleasesLoading: false,
      wagoReleasesError: null,
      wagoGallery: null,
      wagoGalleryLoading: false,
      wagoGalleryError: null
    },

    installingAdd: null,       // {kind:'add'|'install', projectId} optimistic marker while a dialog-triggered job is being posted

    // E19 (script itself is E17's, unchanged): the curseforge:// install-link
    // handler status - {registered, currentHandler, handlerPath,
    // handlerExists} from GET /api/protocol/status, or null before the first
    // load/on a failed load. Read by both the Settings > Game row and the
    // Browse > CurseForge pane's status pill (Actions.loadProtocolStatus
    // keeps both in sync from one shared fetch).
    protocol: null,
    protocolLoading: false,
    protocolBusy: false,        // true while a register/unregister call is in flight (disables the toggle)

    // FLAVORS-SPEC.md CS-F4 (section 5.2): describe the MACHINE, not one
    // flavour - present on every /api/state response regardless of
    // ?flavour= (even a single-entry array at n=1), read here from that same
    // response (App.reloadState). {id,label,addonsPath,clientBuild,
    // clientInterface,buildInfoMissing} per entry, §2.1 order.
    installedFlavours: [],
    activeFlavour: null,

    // Security-review fix: a machine-wide (not flavour-scoped) job in
    // state "awaiting_flavour" the server wants surfaced regardless of
    // which flavour is active right now - see reloadState's own comment.
    pendingFlavourChoice: null
  };

  function set(patch) { Object.assign(state, patch); }

  // FLAVORS-SPEC.md CS-F4/S5.1: mirrors the exact gate addon-server.ps1
  // itself uses ((installed).Count -gt 1) for "does an addon-scoped request
  // need ?flavour=" - the RAW installed count, never the test-realms-
  // filtered one below. Getting this wrong in either direction either 400s
  // every request on a machine with a hidden PTR client, or silently omits
  // ?flavour= on a machine the server considers multi-flavour.
  function hasMultipleFlavours() { return state.installedFlavours.length > 1; }

  // FLAVORS-SPEC.md CS-F4 (section 2.5): PTR/XPTR/Beta are detected but
  // excluded from the switcher/Update All/job-badge gating by default - a
  // SEPARATE, smaller count than hasMultipleFlavours() above, which must
  // stay keyed off the raw count. A machine with just Retail+PTR (raw count
  // 2, showTestRealms off) has exactly one VISIBLE flavour, so every piece
  // of UI gated on ">1 flavour" (the switcher itself, Update All, badges)
  // renders nothing, even though the server-facing ?flavour= param is still
  // required for its requests.
  const HIDDEN_FLAVOUR_IDS = { ptr: true, xptr: true, beta: true };
  function visibleFlavours() {
    const showTest = !!(state.settings && state.settings.showTestRealms);
    return state.installedFlavours.filter(function (f) { return showTest || !HIDDEN_FLAVOUR_IDS[f.id]; });
  }

  // E7: sets and persists the My Addons column sort so it survives a reload.
  function setMyAddonsSort(sort) {
    state.myaddonsSort = sort;
    try { localStorage.setItem(SORT_PREF_KEY, JSON.stringify(sort)); } catch (e) { /* storage unavailable - sort still applies for this load */ }
  }

  // Round 15: sets and persists the Get new addons segmented switch's choice.
  function setBrowseTab(tab) {
    if (tab !== "wago" && tab !== "curseforge") return;
    state.browse.tab = tab;
    try { localStorage.setItem(BROWSE_TAB_KEY, tab); } catch (e) { /* storage unavailable - choice still applies for this load */ }
  }

  // E12: an addon's stable key - its numeric CurseForge projectId, or
  // "wago:<slug>" for a Wago-sourced record (projectId is null there). Every
  // place that used to read addon.projectId directly to identify a row/
  // start a job now goes through this instead.
  function addonKey(addon) {
    if (addon && addon.source === "wago") return "wago:" + addon.slug;
    return addon ? addon.projectId : null;
  }

  function addonByProjectId(id) {
    const key = Utils.normalizeId(id);
    if (typeof key === "string" && key.toLowerCase().indexOf("wago:") === 0) {
      const ref = key.slice(5).toLowerCase();
      return state.addons.find(function (a) {
        return a.source === "wago" && (((a.slug || "").toLowerCase() === ref) || ((a.wagoId || "").toLowerCase() === ref));
      });
    }
    return state.addons.find(function (a) { return a.projectId === key; });
  }

  // True while a running job plausibly affects this project (drives "Installing..." chips).
  function jobActingOn(projectId) {
    const j = state.job;
    if (!j || j.state !== "running") return false;
    const p = j.params || {};
    const pid = Utils.normalizeId(projectId);
    if (j.kind === "sync") return !p.ids || p.ids.map(Utils.normalizeId).indexOf(pid) !== -1;
    // E11: a bulk uninstall's remove job carries projectIds (array) instead
    // of a single projectId - check membership there first; a single-row
    // remove (still just projectId) falls through to the shared check below.
    if (j.kind === "remove" && p.projectIds && p.projectIds.length) return p.projectIds.map(Utils.normalizeId).indexOf(pid) !== -1;
    if (j.kind === "install" || j.kind === "remove" || j.kind === "add" || j.kind === "rollback" || j.kind === "switch-source") {
      // E12: a brand-new Wago add posts {source:'wago', slug} rather than a
      // projectId (there's no existing record yet to derive a key from) -
      // matched against the row's own "wago:<slug>" key on that side instead.
      if (p.source === "wago" && p.slug) return pid === "wago:" + p.slug;
      return Utils.normalizeId(p.projectId) === pid;
    }
    if (j.kind === "launch") return true; // a launch job runs a full sync first
    // E4: an import job's params carry the whole imported addons[] list -
    // "Installing..." only lights up rows actually named in that file.
    if (j.kind === "import") return (p.addons || []).some(function (a) { return Number(a.projectId) === pid; });
    return false;
  }

  function isBusy() { return !!(state.job && state.job.state === "running"); }

  function updatesCount() {
    return state.addons.reduce(function (n, a) { return n + (a.updateAvailable ? 1 : 0); }, 0);
  }

  // Review fix: was keyed by display name alone, so two tracked addons that
  // happen to share a name (a CurseForge addon and an unrelated/forked Wago
  // addon with an identical title, or the same addon tracked from both
  // sources via "Also on CurseForge/Wago") could misattribute one addon's
  // failure onto the other's Status pill/filter/sort. Now takes the addon
  // itself and matches by its stable key (projectId, or "wago:<slug>") the
  // same way Store.addonKey does - both the real server's rows (a literal
  // passthrough of the CLI's -Json rows, which always carry projectId/
  // wagoSlug) and the mock's now carry that data on every row. Falls back to
  // a name match only against rows with no key data at all (e.g. the
  // synthetic "Launched" row), matching the old behavior for those.
  function lastRunStatusFor(addon) {
    if (!state.lastRun || !state.lastRun.rows) return null;
    const rows = state.lastRun.rows;
    const key = Utils.normalizeId(addonKey(addon));
    function rowKey(r) {
      if (r.wagoSlug) return "wago:" + r.wagoSlug;
      if (r.projectId !== null && r.projectId !== undefined) return Utils.normalizeId(r.projectId);
      return null;
    }
    const keyed = rows.filter(function (r) { const rk = rowKey(r); return rk !== null && rk === key; }).pop();
    if (keyed) return keyed.status;
    const byName = rows.filter(function (r) { return rowKey(r) === null && r.name === (addon && addon.name); }).pop();
    return byName ? byName.status : null;
  }

  // E11: My Addons bulk selection. A plain array of projectIds rather than a
  // Set so it round-trips cleanly through the JSON.stringify comparisons
  // elsewhere in this module (unused here, but keeps the type consistent
  // with every other piece of array-shaped state in Store).
  // E12: the selection array holds addonKey() values (a mix of numbers and
  // "wago:<slug>" strings is fine - normalizeId leaves either kind alone).
  function isSelected(projectId) { return state.myaddonsSelection.indexOf(Utils.normalizeId(projectId)) !== -1; }
  function toggleSelected(projectId) {
    const pid = Utils.normalizeId(projectId);
    const idx = state.myaddonsSelection.indexOf(pid);
    if (idx === -1) state.myaddonsSelection.push(pid); else state.myaddonsSelection.splice(idx, 1);
  }
  function selectIds(ids) {
    (ids || []).forEach(function (id) {
      const pid = Utils.normalizeId(id);
      if (state.myaddonsSelection.indexOf(pid) === -1) state.myaddonsSelection.push(pid);
    });
  }
  function deselectIds(ids) {
    const drop = {};
    (ids || []).forEach(function (id) { drop[Utils.normalizeId(id)] = true; });
    state.myaddonsSelection = state.myaddonsSelection.filter(function (id) { return !drop[id]; });
  }
  function clearSelection() { state.myaddonsSelection = []; }
  function selectedAddons() {
    const want = {};
    state.myaddonsSelection.forEach(function (id) { want[id] = true; });
    return state.addons.filter(function (a) { return want[addonKey(a)]; });
  }
  // Drops any selected id that no longer names a tracked addon (removed by
  // this or another job) - called from Views.myAddons.render() so a stale id
  // never inflates the selection-bar count or reaches a bulk action.
  function pruneSelection() {
    if (!state.myaddonsSelection.length) return;
    const present = {};
    state.addons.forEach(function (a) { present[addonKey(a)] = true; });
    const pruned = state.myaddonsSelection.filter(function (id) { return present[id]; });
    if (pruned.length !== state.myaddonsSelection.length) state.myaddonsSelection = pruned;
  }

  // Round 9 fix: the fast-op endpoints (POST .../ignore, .../unpin) return
  // the CLI's raw addons.json records (SPEC: "addons: full records" from
  // addon-sync.ps1 -Json), not the enriched /api/state shape - updateAvailable,
  // compat, tocInterfaces, missingDeps, latestGameVersions etc. only exist
  // because Handle-State computes them server-side on top of those same raw
  // records. Swapping state.addons for one of those bare responses wholesale
  // (`Store.state.addons = res.addons`) silently dropped every enriched field
  // for every row until the next /api/state poll caught it back up - which
  // is what made an immediate post-toggle render look like it "waited for the
  // poll" even though the assignment and re-render both ran synchronously.
  // Object.assign onto the SAME existing addon object only overwrites the
  // keys the incoming record actually carries (ignoreUpdates, pinnedFileId,
  // fileId, version, etc.), so anything the raw record doesn't know about -
  // and the object identity anything else in the UI may have cached - both
  // survive untouched, while the field that DID change is live for the very
  // next render.
  function mergeAddons(list) {
    (list || []).forEach(function (record) {
      const key = addonKey(record);
      const existing = state.addons.filter(function (a) { return addonKey(a) === key; })[0];
      if (existing) Object.assign(existing, record);
      else state.addons.push(record);
    });
  }

  return {
    state: state, set: set, setMyAddonsSort: setMyAddonsSort, setBrowseTab: setBrowseTab, addonKey: addonKey, addonByProjectId: addonByProjectId, jobActingOn: jobActingOn, isBusy: isBusy, updatesCount: updatesCount, lastRunStatusFor: lastRunStatusFor,
    isSelected: isSelected, toggleSelected: toggleSelected, selectIds: selectIds, deselectIds: deselectIds, clearSelection: clearSelection, selectedAddons: selectedAddons, pruneSelection: pruneSelection, mergeAddons: mergeAddons,
    hasMultipleFlavours: hasMultipleFlavours, visibleFlavours: visibleFlavours
  };
})();


/* ==========================================================================
   Round 15: a tiny reference-counted "something modal-ish is open right now"
   tracker - any dialog (Components.Dialogs), the detail drawer
   (Components.Drawer), a kebab/filter popover (Components.Dropdown), or the
   screenshot lightbox (Components.Lightbox) calls open()/close() as it
   shows/hides. Views.browse subscribes via onChange so the embedded
   CurseForge pane can post cf-hide the instant anything opens on top of it
   (a WebView2 child window always paints above ordinary HTML, so hiding it
   is the only way a popover can ever appear "in front" of it) and cf-show
   again once the last one closes. A plain counter, not a stack, since these
   four things can nest (e.g. a confirm dialog opened from inside the
   drawer) - only the 0->1 and 1->0 transitions matter to any listener.
   ========================================================================== */
const OverlayTracker = (function () {
  let count = 0;
  const listeners = [];
  function open() { count += 1; if (count === 1) listeners.forEach(function (fn) { fn(true); }); }
  function close() { count = Math.max(0, count - 1); if (count === 0) listeners.forEach(function (fn) { fn(false); }); }
  function onChange(fn) { listeners.push(fn); }
  function isAnyOpen() { return count > 0; }
  return { open: open, close: close, onChange: onChange, isAnyOpen: isAnyOpen };
})();

/* ==========================================================================
   Components - reusable, presentation-only UI pieces shared by the views.
   ========================================================================== */
const Components = {};

/* ---------- Toasts ---------- */
Components.Toast = (function () {
  function show(message, type, opts) {
    type = type || "info";
    opts = opts || {};
    const container = Utils.qs("#toast-container");
    const iconName = type === "success" ? "check-circle" : type === "error" ? "alert-circle" : type === "warning" ? "warning" : "check-circle";
    let removed = false;
    const children = [
      Utils.icon(iconName),
      Utils.el("div", { class: "toast-body" }, [String(message)])
    ];
    // E19: an optional inline action (e.g. "Undo" on the curseforge://
    // handler register/unregister toggle) - opt-in, every existing caller
    // that passes no opts.actionLabel is unaffected.
    if (opts.actionLabel && typeof opts.onAction === "function") {
      children.push(Utils.el("button", {
        type: "button", class: "link-btn toast-action",
        onclick: function () { opts.onAction(); remove(); }
      }, [opts.actionLabel]));
    }
    children.push(Utils.el("button", { type: "button", class: "icon-btn toast-close", "aria-label": "Dismiss", title: "Dismiss", onclick: function () { remove(); } }, [Utils.icon("close")]));
    const node = Utils.el("div", { class: "toast toast-" + type, role: "status" }, children);
    function remove() {
      if (removed) return;
      removed = true;
      node.classList.add("is-leaving");
      setTimeout(function () { node.remove(); }, 160);
    }
    container.appendChild(node);
    setTimeout(remove, opts.duration || (type === "error" ? 7000 : 4500));
    return { remove: remove };
  }
  return { show: show };
})();

/* ---------- Generic dialog plumbing (shared backdrop, Add + Confirm) ---------- */
Components.Dialogs = (function () {
  let openName = null;      // 'add' | 'confirm' | 'welcome' | null
  let confirmResolve = null;

  function show(name) {
    openName = name;
    OverlayTracker.open();
    const backdrop = Utils.qs("#dialog-backdrop");
    const dlg = Utils.qs("#dialog-" + name);
    backdrop.hidden = false;
    dlg.hidden = false;
    requestAnimationFrame(function () {
      backdrop.classList.add("is-visible");
      dlg.classList.add("is-visible");
    });
  }

  function hide(name) {
    const backdrop = Utils.qs("#dialog-backdrop");
    const dlg = Utils.qs("#dialog-" + name);
    backdrop.classList.remove("is-visible");
    dlg.classList.remove("is-visible");
    setTimeout(function () { backdrop.hidden = true; dlg.hidden = true; }, 150);
    if (openName === name) { openName = null; OverlayTracker.close(); }
  }

  function openAdd() {
    Utils.qs("#add-addon-input").value = "";
    Utils.qs("#add-addon-error").hidden = true;
    Utils.qs("#add-addon-submit").disabled = false;
    show("add");
    setTimeout(function () { Utils.qs("#add-addon-input").focus(); }, 160);
  }
  function closeAdd() { hide("add"); }

  // E18: first-run welcome (Components.Welcome builds its content; this just
  // owns the shared show/hide/backdrop/Esc plumbing, same as add/confirm).
  function openWelcome() { show("welcome"); }
  function closeWelcome() { hide("welcome"); }

  function confirm(opts) {
    opts = opts || {};
    Utils.qs("#confirm-title").textContent = opts.title || "Are you sure?";
    Utils.qs("#confirm-message").textContent = opts.message || "";
    const okBtn = Utils.qs("#confirm-ok");
    okBtn.textContent = opts.confirmLabel || "Confirm";
    // Review fix: was btn-accent for the non-destructive case, colliding
    // with the sidebar's "Update & Play" - the only accent button the app
    // is allowed to have on screen at once (UX-SPEC.md section 1/2.3).
    okBtn.className = "btn " + (opts.danger === false ? "btn-outline" : "btn-danger");
    show("confirm");
    return new Promise(function (resolve) { confirmResolve = resolve; });
  }
  function resolveConfirm(result) {
    hide("confirm");
    if (confirmResolve) { const r = confirmResolve; confirmResolve = null; r(!!result); }
  }

  function backdropClicked() {
    if (openName === "confirm") resolveConfirm(false);
    else if (openName === "add") closeAdd();
    else if (openName === "welcome") closeWelcome();
  }
  function escPressed() {
    if (openName === "confirm") { resolveConfirm(false); return true; }
    if (openName === "add") { closeAdd(); return true; }
    if (openName === "welcome") { closeWelcome(); return true; }
    return false;
  }
  function isOpen() { return openName !== null; }

  return {
    openAdd: openAdd, closeAdd: closeAdd, confirm: confirm, resolveConfirm: resolveConfirm,
    openWelcome: openWelcome, closeWelcome: closeWelcome,
    backdropClicked: backdropClicked, escPressed: escPressed, isOpen: isOpen
  };
})();

/* ---------- E18: first-run welcome dialog content -----------------------
   Lists the untracked-but-recognizable (curseId/wagoId) folders App found
   on load when addons.json had 0 records - the same signal Settings'
   "Untracked folders" scan (E7) surfaces later, just surfaced once, up
   front, so a fresh install (or a hand-populated AddOns folder) doesn't
   look empty when it actually has addons Furphy could already manage. */
Components.Welcome = (function () {
  // A bare numeric CurseForge id, or "wago:<id>" - exactly the token shape
  // addon-sync.ps1's -Add classifier (and this app's own Store.addonKey)
  // already expects, so no further translation happens server-side either.
  function targetFor(u) { return u.curseId ? String(u.curseId) : ("wago:" + u.wagoId); }

  function itemRow(u) {
    const isWago = !u.curseId && !!u.wagoId;
    const badge = Utils.el("span", { class: "source-badge " + (isWago ? "is-wago" : "is-cf"), title: isWago ? "Wago Addons" : "CurseForge" }, [isWago ? "Wago" : "CF"]);
    const label = u.title || u.folder;
    return Utils.el("li", { class: "welcome-item" }, [
      badge,
      Utils.el("span", { class: "welcome-item-name", title: label }, [label]),
      Utils.el("span", { class: "welcome-item-folder muted-text" }, [u.folder])
    ]);
  }

  function open(items) {
    const list = Utils.qs("#welcome-list");
    list.innerHTML = "";
    items.forEach(function (u) { list.appendChild(itemRow(u)); });
    Utils.qs("#welcome-count").textContent = items.length;
    const adoptBtn = Utils.qs("#welcome-adopt");
    adoptBtn.textContent = "Take over all (" + items.length + ")";
    adoptBtn.onclick = function () { Actions.adoptAll(items.map(targetFor)); };
    Components.Dialogs.openWelcome();
  }

  return { open: open };
})();

/* ---------- Kebab dropdown menu (single instance, portalled to <body>) ----------
   Appended to document.body with position:fixed (rather than absolute inside its
   row) so it is never clipped by .table-scroll's overflow-x:auto - which, per the
   CSS overflow spec, forces overflow-y to 'auto' too and would otherwise clip a
   menu opened from a row near the bottom of the table. Repositions on scroll/resize
   and flips above the anchor when there isn't room below. */
Components.Dropdown = (function () {
  let currentMenu = null;
  let currentAnchor = null;

  function close() {
    // Review fix: whichever trigger opened this popover (e.g. the "More"
    // filter chip, which ships aria-haspopup="true") gets aria-expanded
    // flipped back to "false" here so assistive tech sees the disclosure
    // state change - previously this attribute was never set at all.
    if (currentAnchor) currentAnchor.setAttribute("aria-expanded", "false");
    // Review fix (low severity, keyboard focus management): only steal
    // focus back to the trigger if focus was actually inside the menu
    // being closed (e.g. Escape, or a menu item's own click) - a close
    // triggered by clicking some unrelated element shouldn't yank focus
    // away from wherever the user actually clicked.
    const anchor = currentAnchor;
    const hadFocusInMenu = !!(currentMenu && currentMenu.contains(document.activeElement));
    if (currentMenu) { currentMenu.remove(); currentMenu = null; currentAnchor = null; OverlayTracker.close(); }
    window.removeEventListener("scroll", reposition, true);
    window.removeEventListener("resize", reposition);
    if (hadFocusInMenu && anchor) anchor.focus();
  }

  // Review fix (low severity): keyboard navigation among the menu's own
  // items - the menu is appended to document.body (not adjacent to its
  // trigger in the DOM), so native Tab order never reaches it; this gives
  // a keyboard-only user Arrow/Home/End traversal once the menu is open.
  function menuItems() {
    return currentMenu ? Array.prototype.slice.call(currentMenu.querySelectorAll(".dropdown-item:not([disabled])")) : [];
  }
  function focusMenuItem(index) {
    const items = menuItems();
    if (!items.length) return;
    const i = ((index % items.length) + items.length) % items.length;
    items[i].focus();
  }
  function onMenuKeydown(ev) {
    if (ev.key === "ArrowDown") { ev.preventDefault(); focusMenuItem(menuItems().indexOf(document.activeElement) + 1); }
    else if (ev.key === "ArrowUp") { ev.preventDefault(); focusMenuItem(menuItems().indexOf(document.activeElement) - 1); }
    else if (ev.key === "Home") { ev.preventDefault(); focusMenuItem(0); }
    else if (ev.key === "End") { ev.preventDefault(); focusMenuItem(menuItems().length - 1); }
  }

  function reposition() {
    if (!currentMenu || !currentAnchor) return;
    const r = currentAnchor.getBoundingClientRect();
    const menuWidth = currentMenu.offsetWidth || 200;
    const menuHeight = currentMenu.offsetHeight || 0;
    let left = r.right - menuWidth;
    left = Math.max(8, Math.min(left, window.innerWidth - menuWidth - 8));
    let top = r.bottom + 6;
    if (top + menuHeight > window.innerHeight - 8) top = Math.max(8, r.top - menuHeight - 6);
    currentMenu.style.left = left + "px";
    currentMenu.style.top = top + "px";
  }

  // items: [{label, icon, danger, disabled, title, onSelect}] | null for a
  // separator | {info: true, label, title} for a non-interactive info line
  // (CS2: "Installed [date]" in the addon row kebab menu, UX-SPEC.md 3.3).
  function open(anchorEl, items) {
    if (currentAnchor === anchorEl) { close(); return; }
    close();
    OverlayTracker.open();
    const menu = Utils.el("div", { class: "dropdown-menu", role: "menu" }, items.map(function (item) {
      if (item === null) return Utils.el("div", { class: "dropdown-sep" });
      if (item.info) return Utils.el("div", { class: "dropdown-info", title: item.title || null }, [item.label]);
      return Utils.el("button", {
        type: "button",
        class: "dropdown-item" + (item.danger ? " is-danger" : ""),
        disabled: !!item.disabled,
        title: item.title || null,
        role: "menuitem",
        onclick: function (ev) { ev.stopPropagation(); close(); item.onSelect(); }
      }, [item.icon ? Utils.icon(item.icon) : null, Utils.el("span", {}, [item.label])]);
    }));
    document.body.appendChild(menu);
    currentMenu = menu;
    currentAnchor = anchorEl;
    currentAnchor.setAttribute("aria-expanded", "true");
    reposition();
    window.addEventListener("scroll", reposition, true);
    window.addEventListener("resize", reposition);
    // Review fix (low severity): move focus into the menu on open (first
    // enabled item) and wire Arrow/Home/End navigation within it.
    menu.addEventListener("keydown", onMenuKeydown);
    focusMenuItem(0);
  }

  document.addEventListener("click", function (ev) {
    if (currentMenu && !currentMenu.contains(ev.target) && ev.target !== currentAnchor && !(currentAnchor && currentAnchor.contains(ev.target))) close();
  });

  function isOpen() { return !!currentMenu; }

  return { open: open, close: close, isOpen: isOpen };
})();

/* ---------- Status chip for an addon row/card ---------- */
Components.Chip = (function () {
  function build(label, cls, title) {
    return Utils.el("span", { class: "chip " + cls, title: title || null }, [Utils.el("span", { class: "chip-dot" }), label]);
  }

  // CS2 (UX-SPEC.md section 3.2): the single-pill Status vocabulary - a row
  // shows EXACTLY one pill, chosen by this priority order, replacing the old
  // separate Status chip + "Missing: N" chip + Compat column chip (three
  // colored badges a row could previously carry at once). An actionable pill
  // (Update / Couldn't update - Retry) renders as a real <button> via
  // buildAction below so clicking it starts that one addon's job directly,
  // per the spec's "actionable pills act as buttons" rule.
  // Review fix: was a single hardcoded "Installing..." for every row a
  // running job might touch, contradicting the JobPanel's own live phase
  // word for the exact same addon at the same instant (UX-SPEC.md 4.3 says
  // the two must match). job.progress is a single overwritten snapshot (no
  // per-addon history), so only the one addon it currently names can show a
  // real phase; every other row still in the batch (not yet reached, or
  // already past the moment progress moved on) falls back to a neutral
  // "Queued..." placeholder rather than a wrong or stale phase word.
  const LIVE_PHASES = { queued: true, checking: true, downloading: true, installing: true };
  function forStatus(addon) {
    const key = Store.addonKey(addon);
    if (Store.jobActingOn(key)) {
      const p = Store.state.job && Store.state.job.progress;
      if (p && p.addon === addon.name && LIVE_PHASES[p.phase]) {
        return build(Utils.phaseWord(p.phase) + "…", "chip-busy");
      }
      return build("Queued…", "chip-busy");
    }
    // Priority 1: last attempt for this addon failed.
    if (Store.lastRunStatusFor(addon) === "Failed") {
      return buildAction("Couldn't update — Retry", "chip-danger", function () { Actions.updateNow(key); });
    }
    // Priority 2: a required dependency isn't installed - named directly,
    // no hover needed (the old hidden "Missing dependencies: ..." tooltip
    // is gone, per the spec's deleted-tooltip rule).
    const missing = addon.missingDeps || [];
    if (missing.length) return build("Needs: " + missing.join(", "), "chip-danger");
    // Priority 3: a newer version exists - the pill itself is the one-click
    // fix (the Version cell next to it already shows the installed->latest
    // diff, so this pill only needs the verb).
    if (addon.updateAvailable && !addon.ignoreUpdates) {
      return buildAction("Update", "chip-warning", function () { Actions.updateNow(key); });
    }
    // Priorities 4/5: the compat check found real evidence the installed
    // file predates (stale-minor) or can't run on (stale) the current
    // patch, and priority 3 above already ruled out "a newer file exists to
    // fix it". Utils.compatDisplay's own tooltip text (raw Toc Interface
    // numbers) is deliberately NOT used here - that hidden hover tooltip is
    // deleted outright per the spec, not carried into the merged pill.
    if (addon.compat === "stale-minor") return build("Old patch", "chip-warning");
    if (addon.compat === "stale") return build("Won't work this patch", "chip-danger");
    // Priority 6: pinned - version shown inline, no second pill.
    if (addon.pinnedFileId !== null && addon.pinnedFileId !== undefined) {
      // E1 (round 2 fix, carried over): a pin left behind by a rollback gets
      // a tooltip explaining why it stopped updating (see the original
      // comment on this signal, preserved below); a pin+ignore combo notes
      // both rather than growing a second pill for one more boolean.
      const rolledBack = Store.lastRunStatusFor(addon) === "Rolled-back";
      const notes = [];
      if (rolledBack) notes.push("Rolled back — unpin to resume updates.");
      if (addon.ignoreUpdates) notes.push("Updates are also ignored for this addon.");
      return build("Pinned · " + addon.version, "chip-info", notes.length ? notes.join(" ") : null);
    }
    // Priority 7: update exists (implicitly none here, or ignored regardless)
    // but the player chose to skip it.
    if (addon.ignoreUpdates) return build("Ignoring updates", "chip-muted");
    // Priority 8 (default): nothing to do - low-weight, not a fully blank
    // cell (a truly empty cell reads as a rendering bug per the spec).
    return build("Up to date", "chip-muted");
  }

  // CS2: an actionable pill - same look as a plain chip, but a real <button>
  // so "Update"/"Couldn't update — Retry" double as the one-click fix
  // (UX-SPEC.md section 3.2). stopPropagation keeps the click from also
  // bubbling to the row's own click handler, which would otherwise open the
  // detail drawer right after starting the job.
  function buildAction(label, cls, onClick) {
    const busy = Store.isBusy();
    return Utils.el("button", {
      type: "button", class: "chip chip-action " + cls, disabled: busy,
      title: busy ? "Another task is running" : null,
      onclick: function (ev) { ev.stopPropagation(); if (!Store.isBusy()) onClick(); }
    }, [Utils.el("span", { class: "chip-dot" }), label]);
  }

  function forJobStatus(status) {
    const map = {
      "Updated": "chip-success", "Installed": "chip-success", "Removed": "chip-success", "Launched": "chip-success",
      "Unpinned": "chip-success", "Unignored": "chip-success", "Up-to-date": "chip-success", "Rolled-back": "chip-success",
      "Would-update": "chip-warning", "Pinned": "chip-info", "Ignored": "chip-muted", "Skipped": "chip-muted",
      "Failed": "chip-danger"
    };
    return build(status, map[status] || "chip-muted");
  }

  return { forStatus: forStatus, build: build, forJobStatus: forJobStatus };
})();

/* ---------- Freshness headline (UX-SPEC.md sections 1.1/2.1) ----------
   The one "is anything out of date" fact, computed once server-side
   (Store.state.freshness, plus updatesCheckedAt/lastCheckError) and
   rendered here by exactly one component, mounted in exactly two spots:
   the sidebar (compact) and the top of My Addons (full). Never derives its
   own opinion from any other field - a container with no matching state
   just renders nothing, so a stale/unknown enum value fails silently
   rather than showing a wrong headline. */
Components.Freshness = (function () {
  function describe() {
    const freshness = Store.state.freshness;
    const checkedAt = Store.state.updatesCheckedAt;
    const n = Store.updatesCount();
    if (freshness === "checking") {
      return { dot: "is-checking", headline: "Checking…", clause: null };
    }
    if (freshness === "check_failed") {
      return {
        dot: "is-danger", retry: true, headline: "Couldn't check — Retry",
        clause: checkedAt ? ("last success " + Utils.relativeTime(checkedAt)) : null
      };
    }
    if (freshness === "updates_available") {
      return {
        dot: "is-warning", headline: n + " update" + (n === 1 ? "" : "s") + " ready",
        clause: checkedAt ? ("checked " + Utils.relativeTime(checkedAt)) : null
      };
    }
    if (freshness === "up_to_date") {
      return {
        dot: "is-success", headline: "Everything's up to date",
        clause: checkedAt ? ("checked " + Utils.relativeTime(checkedAt)) : null
      };
    }
    // "not_checked", or freshness not yet known (still loading /api/state).
    return { dot: "is-muted", headline: "Not checked yet", clause: null };
  }

  // Review fix (acceptance checklist item 1 - "sidebar shows a connectivity
  // dot only"): the sidebar mount used to still render the full headline
  // text ("3 updates ready" etc, just minus the clause), which is a SECOND
  // on-screen rendering of the freshness fact next to the My Addons header's
  // own full headline - exactly the duplication the checklist bullet rules
  // out, not just the "checked X ago" clause specifically. dotOnly (sidebar
  // mount only) now renders just the colored dot - the fact still reaches
  // the sidebar (color/animation), but the words live in exactly one place
  // on screen. The dot keeps a title tooltip so the state is still
  // discoverable on hover/for assistive tech, and stays a real <button>
  // (not a <span>) whenever a Retry is available, so the sidebar's own
  // click-to-retry affordance survives losing its label.
  function render(containerId, opts) {
    const box = Utils.qs("#" + containerId);
    if (!box) return;
    const dotOnly = !!(opts && opts.dotOnly);
    box.textContent = "";
    const d = describe();
    if (dotOnly) {
      const dotEl = d.retry
        ? Utils.el("button", {
          type: "button", class: "freshness-dot freshness-dot-btn " + d.dot, title: d.headline,
          "aria-label": d.headline,
          onclick: function () { if (!Store.isBusy()) Actions.checkForUpdates(); }
        }, [])
        : Utils.el("span", { class: "freshness-dot " + d.dot, title: d.headline, "aria-label": d.headline }, []);
      box.appendChild(Utils.el("div", { class: "freshness-row" }, [dotEl]));
      return;
    }
    const parts = [Utils.el("span", { class: "freshness-dot " + d.dot })];
    if (d.retry) {
      parts.push(Utils.el("button", {
        type: "button", class: "link-btn freshness-headline",
        onclick: function () { if (!Store.isBusy()) Actions.checkForUpdates(); }
      }, [d.headline]));
    } else {
      parts.push(Utils.el("span", { class: "freshness-headline" }, [d.headline]));
    }
    if (d.clause) parts.push(Utils.el("span", { class: "freshness-clause" }, [" · " + d.clause]));
    box.appendChild(Utils.el("div", { class: "freshness-row" }, parts));
  }

  return { render: render };
})();

/* ==========================================================================
   FLAVORS-SPEC.md CS-F4 (section 6.1): the WoW-flavour switcher pill row,
   mounted once right after #flavour-switcher-anchor (inside the sidebar's
   <nav>, index.html). Entirely absent from the DOM (inserted/removed
   wholesale, never just display:none) whenever fewer than two flavours are
   VISIBLE (Store.visibleFlavours - PTR/XPTR/Beta stay excluded unless
   Settings' "Show test realms" is on, section 2.5) - a single-flavour
   machine's sidebar is byte-for-byte what it is today (principle 2). Also
   owns the "Update All" bulk button (section 6.3) - gated on the exact same
   visible-count condition, since both only make sense together.
   ========================================================================== */
Components.Switcher = (function () {
  function render() {
    const anchor = Utils.qs("#flavour-switcher-anchor");
    if (!anchor) return;
    const visible = Store.visibleFlavours();
    let node = Utils.qs("#flavour-switcher");
    if (visible.length <= 1) {
      if (node) node.remove();
      return;
    }
    if (!node) {
      node = Utils.el("div", { class: "flavour-switcher", id: "flavour-switcher" }, []);
      anchor.insertAdjacentElement("afterend", node);
    }
    node.textContent = "";

    const active = Store.state.activeFlavour;
    const pills = Utils.el("div", { class: "flavour-pills", role: "tablist", "aria-label": "WoW version" },
      visible.map(function (f) {
        // section 2.7: Classic Era's realm explanation lives ONLY in a
        // tooltip/aria-label here, never inline in the pill's own label.
        const subtitle = f.id === "classic_era" ? "Includes Hardcore & Anniversary realms" : null;
        return Utils.el("button", {
          type: "button", class: "flavour-pill" + (f.id === active ? " is-active" : ""),
          role: "tab", "aria-selected": f.id === active ? "true" : "false",
          title: subtitle || undefined, "aria-label": subtitle ? (f.label + ". " + subtitle) : undefined,
          onclick: function () { Actions.setActiveFlavour(f.id); }
        }, [f.label]);
      }));
    node.appendChild(pills);

    // section 6.3: a separate, always-visible bulk action - never gated on
    // whether the ACTIVE flavour has updates, since it targets every
    // installed, non-hidden flavour at once regardless of which pill is
    // selected right now.
    node.appendChild(Utils.el("button", {
      type: "button", class: "btn btn-outline btn-block flavour-update-all",
      disabled: Store.isBusy() || undefined,
      onclick: function () { if (!Store.isBusy()) Actions.updateAllFlavours(); }
    }, ["Update All"]));
  }

  return { render: render };
})();

/* ---------- Addon/mod logo (image if known, else an initial on a coloured tile) ---------- */
Components.Logo = (function () {
  function build(info, size) {
    size = size || 40;
    const url = info.thumbnailUrl;
    if (url) {
      const img = Utils.el("img", { class: "addon-logo", src: url, alt: "", loading: "lazy" });
      img.style.width = size + "px"; img.style.height = size + "px";
      img.addEventListener("error", function () { img.replaceWith(fallback(info.name, size)); });
      return img;
    }
    return fallback(info.name, size);
  }
  function fallback(name, size) {
    const node = Utils.el("div", { class: "addon-logo-fallback" }, [Utils.firstLetter(name)]);
    node.style.width = size + "px"; node.style.height = size + "px";
    node.style.background = Utils.colorForName(name || "?");
    return node;
  }
  return { build: build };
})();

/* ---------- Screenshot lightbox ---------- */
Components.Lightbox = (function () {
  function open(url) {
    OverlayTracker.open();
    Utils.qs("#lightbox-img").src = url;
    Utils.qs("#lightbox").hidden = false;
  }
  function close() {
    if (Utils.qs("#lightbox").hidden) return;
    Utils.qs("#lightbox").hidden = true;
    Utils.qs("#lightbox-img").src = "";
    OverlayTracker.close();
  }
  function isOpen() { return !Utils.qs("#lightbox").hidden; }
  return { open: open, close: close, isOpen: isOpen };
})();

/* ---------- Detail drawer ---------- */
Components.Drawer = (function () {
  function projectId() { return Store.state.drawer.projectId; }

  function open(pid, opts) {
    opts = opts || {};
    // E12: pid is either a number (CurseForge) or a "wago:<slug>" key -
    // Utils.normalizeId leaves either alone; source is derived from it (or
    // from opts.source, for a Browse Wago card which has no local record to
    // read source off of yet - see Views.browse.card).
    const key = Utils.normalizeId(pid);
    const isWago = opts.source === "wago" || (typeof key === "string" && key.toLowerCase().indexOf("wago:") === 0);
    const addon = Store.addonByProjectId(key);
    const slug = opts.slug || (addon ? addon.slug : null) || (isWago && typeof key === "string" ? key.slice(5) : null);
    // Round 16 (E22, CurseForge key removal): every CurseForge-sourced
    // drawer is keyless now (the old keyed 'curseforge' source, fed by
    // Api.cfMod, is gone) - every render function below reads
    // Store.state.drawer.enrich, populated via /api/cf/enrich (loadEnrich).
    const source = isWago ? "wago" : "cf-keyless";
    // Round 15 (OverlayTracker): open() can be called again to re-target an
    // already-open drawer at a different addon (no intervening close()) -
    // only count the 0->1 transition, never a re-open while already open.
    const wasOpen = Store.state.drawer.open;
    Store.set({
      drawer: {
        open: true, projectId: key, source: source, slug: slug, tracked: !!addon,
        tab: opts.tab || "overview",
        lastKnownFileId: addon ? addon.fileId : null,
        files: null, filesLoading: false, filesError: null,
        // E5: opts.changelogFileId lets a caller (Actions.whatChanged) pin the
        // Changelog tab to a specific file - e.g. the version a job just
        // installed - instead of defaulting to the newest one once files load.
        changelogFileId: opts.changelogFileId || null, changelogHtml: null, changelogLoading: false,
        screenshotsLoaded: false,
        wagoAddon: null, wagoAddonLoading: false, wagoAddonError: null,
        wagoReleases: null, wagoReleasesLoading: false, wagoReleasesError: null,
        wagoGallery: null, wagoGalleryLoading: false, wagoGalleryError: null,
        // E16: keyless CurseForge enrichment (source:'cf-keyless' only -
        // null/unused for 'wago').
        enrich: null, enrichLoading: false, enrichError: null
      }
    });
    if (!wasOpen) OverlayTracker.open();
    Utils.qs("#drawer-backdrop").hidden = false;
    Utils.qs("#drawer").hidden = false;
    Utils.qs("#drawer").setAttribute("aria-hidden", "false");
    requestAnimationFrame(function () {
      Utils.qs("#drawer-backdrop").classList.add("is-visible");
      Utils.qs("#drawer").classList.add("is-open");
    });
    renderHeader();
    selectTab(Store.state.drawer.tab);
    if (isWago) { loadWagoAddon(); }
    else { loadEnrich(); }
  }

  function close() {
    const wasOpen = Store.state.drawer.open;
    Utils.qs("#drawer-backdrop").classList.remove("is-visible");
    Utils.qs("#drawer").classList.remove("is-open");
    Utils.qs("#drawer").setAttribute("aria-hidden", "true");
    setTimeout(function () { Utils.qs("#drawer-backdrop").hidden = true; Utils.qs("#drawer").hidden = true; }, 150);
    Store.state.drawer.open = false;
    if (wasOpen) OverlayTracker.close();
  }

  function isOpen() { return Store.state.drawer.open; }

  function selectTab(tab) {
    Store.state.drawer.tab = tab;
    // Round 5 fix: the tabs carry role="tab" (index.html) but nothing ever
    // set aria-selected, so assistive tech had no way to tell which one is
    // active even though the visible underline/bold state was always correct.
    Utils.qsa(".drawer-tab").forEach(function (btn) {
      const active = btn.dataset.tab === tab;
      btn.classList.toggle("is-active", active);
      btn.setAttribute("aria-selected", String(active));
    });
    ["overview", "versions", "changelog", "screenshots"].forEach(function (t) { Utils.qs("#drawer-panel-" + t).hidden = t !== tab; });
    if (tab === "overview") renderOverview();
    else if (tab === "versions") renderVersions();
    else if (tab === "changelog") renderChangelog();
    else if (tab === "screenshots") renderScreenshots();
  }

  // Re-renders whichever panels are visibly affected by fresh Store data
  // (called after a job completes / state refresh), without resetting scroll or loaded caches.
  function refresh() {
    if (!isOpen()) return;
    renderHeader();
    const d = Store.state.drawer;

    // Round 4 fix: a job that updates/installs/rolls back this addon changes
    // addon.fileId, but the cached Versions file list (d.files) and the
    // Changelog tab's selected file (d.changelogFileId) were fetched against
    // the OLD fileId - Versions would keep showing no "Installed" tag on the
    // now-current file, and Changelog would keep defaulting to the file that
    // was current before the job ran. Detect the move and drop those caches
    // so the next render of either tab fetches fresh data. Guarded so this
    // only fires once per actual fileId change, not on every routine
    // 5s/800ms poll that leaves the addon untouched.
    if (d.tracked) {
      const addon = Store.addonByProjectId(d.projectId);
      const currentFileId = addon ? addon.fileId : null;
      if (currentFileId !== d.lastKnownFileId) {
        d.lastKnownFileId = currentFileId;
        d.files = null; d.filesLoading = false; d.filesError = null;
        // E12: the Wago equivalent of the same invalidation, one line below.
        d.wagoReleases = null; d.wagoReleasesLoading = false; d.wagoReleasesError = null;
        d.changelogFileId = null; d.changelogHtml = null;
      }
    }

    const tab = d.tab;
    if (tab === "versions") renderVersions();
    else if (tab === "changelog") renderChangelog();
    // The description itself doesn't change from job state, so it's left
    // as-is; the E3 dependency list's installed/missing status (and, as of
    // E13, the compat verdict - a job can install a different version with a
    // different toc Interface) can, so those parts of the Overview panel are
    // refreshed in place. Screenshots aren't per-file (CurseForge mod
    // screenshots aren't keyed to a fileId), so there's nothing there to
    // invalidate on a version change.
    else if (tab === "overview") refreshDependenciesInPlace();
  }

  // Swaps in fresh compat/dependency sections without re-triggering the
  // (unrelated) CurseForge description fetch that opening/switching to this
  // tab already did.
  function refreshDependenciesInPlace() {
    const panel = Utils.qs("#drawer-panel-overview");
    if (!panel) return;
    const existingCompat = panel.querySelector(".compat-section");
    if (existingCompat) existingCompat.remove();
    renderCompat(panel);
    const existing = panel.querySelector(".deps-section");
    if (existing) existing.remove();
    renderDependencies(panel);
  }

  // E12: fetches addon/description/metadata from the server's keyless Wago
  // proxy - Wago has never needed a key, unlike CurseForge's old (now-
  // removed) key-gated mod loader.
  async function loadWagoAddon() {
    const d = Store.state.drawer;
    const slug = d.slug;
    d.wagoAddonLoading = true;
    d.wagoAddonError = null;
    try {
      const res = await Api.wagoAddon(slug);
      if (Store.state.drawer.slug !== slug) return;
      d.wagoAddon = res;
      renderHeader();
      if (d.tab === "overview") renderOverview();
      if (d.tab === "screenshots") renderScreenshots();
    } catch (err) {
      if (Store.state.drawer.slug === slug) { d.wagoAddonError = err; renderHeader(); if (d.tab === "overview") renderOverview(); }
    } finally {
      if (Store.state.drawer.slug === slug) d.wagoAddonLoading = false;
    }
  }

  // E16: fetches /api/cf/enrich/{id} for a 'cf-keyless' drawer (a
  // CurseForge-sourced addon opened with no API key configured) - the
  // keyless fallback counterpart to loadMod above. The response's `source`
  // field ("wago-match"/"addon-radar"/"catalogue-only") drives which
  // Overview/Changelog/Screenshots branch renders; see renderKeylessOverview
  // etc. below.
  async function loadEnrich() {
    const d = Store.state.drawer;
    const pid = projectId();
    d.enrichLoading = true;
    d.enrichError = null;
    try {
      const res = await Api.cfEnrich(pid);
      if (projectId() !== pid) return;
      d.enrich = res;
      if (!d.slug && res.slug) d.slug = res.slug; // cosmetic: a better "Open on CurseForge" link once resolved
      renderHeader();
      if (d.tab === "overview") renderOverview();
      if (d.tab === "changelog") renderChangelog();
      if (d.tab === "screenshots") renderScreenshots();
    } catch (err) {
      if (projectId() === pid) { d.enrichError = err; renderHeader(); if (d.tab === "overview") renderOverview(); }
    } finally {
      if (projectId() === pid) d.enrichLoading = false;
    }
  }

  // E16: the three functions below fetch a "wago-match" enrichment's data
  // straight into d.wagoAddon/d.wagoReleases/d.wagoGallery - the SAME
  // fields loadWagoAddon/loadWagoReleases/renderWagoScreenshots's own loader
  // already populate - keyed by d.enrich.wagoSlug rather than d.slug (which
  // stays the addon's own CurseForge identity in cf-keyless mode). Once
  // populated, renderWagoOverview/renderWagoChangelog/renderWagoScreenshots
  // (E12, unmodified) render them directly - none of those three read
  // d.slug themselves, only their OWN loaders do, and those loaders are
  // skipped here since the target field is already set (or already loading).
  async function loadCfKeylessWagoAddon() {
    const d = Store.state.drawer;
    const wagoSlug = d.enrich && d.enrich.wagoSlug;
    if (!wagoSlug || d.wagoAddon || d.wagoAddonLoading) return;
    d.wagoAddonLoading = true;
    d.wagoAddonError = null;
    try {
      const res = await Api.wagoAddon(wagoSlug);
      if (!Store.state.drawer.enrich || Store.state.drawer.enrich.wagoSlug !== wagoSlug) return;
      d.wagoAddon = res;
      renderHeader();
      if (d.tab === "overview") renderOverview();
    } catch (err) {
      if (Store.state.drawer.enrich && Store.state.drawer.enrich.wagoSlug === wagoSlug) { d.wagoAddonError = err; renderHeader(); if (d.tab === "overview") renderOverview(); }
    } finally {
      if (Store.state.drawer.enrich && Store.state.drawer.enrich.wagoSlug === wagoSlug) d.wagoAddonLoading = false;
    }
  }

  function loadCfKeylessWagoReleases() {
    const d = Store.state.drawer;
    const wagoSlug = d.enrich && d.enrich.wagoSlug;
    if (!wagoSlug || d.wagoReleases || d.wagoReleasesLoading) return;
    d.wagoReleasesLoading = true;
    Api.wagoReleases(wagoSlug, { page: 1 }).then(function (res) {
      if (!Store.state.drawer.enrich || Store.state.drawer.enrich.wagoSlug !== wagoSlug) return;
      const paginator = res.data || {};
      d.wagoReleases = paginator.data || [];
      d.wagoReleasesLoading = false;
      if (d.tab === "versions") renderVersions();
      if (d.tab === "changelog") renderChangelog();
    }).catch(function (err) {
      if (!Store.state.drawer.enrich || Store.state.drawer.enrich.wagoSlug !== wagoSlug) return;
      d.wagoReleasesError = err; d.wagoReleasesLoading = false;
      if (d.tab === "changelog") renderChangelog();
    });
  }

  function loadCfKeylessWagoGallery() {
    const d = Store.state.drawer;
    const wagoSlug = d.enrich && d.enrich.wagoSlug;
    if (!wagoSlug || d.wagoGallery || d.wagoGalleryLoading) return;
    d.wagoGalleryLoading = true;
    d.wagoGalleryError = null;
    Api.wagoGallery(wagoSlug).then(function (res) {
      if (!Store.state.drawer.enrich || Store.state.drawer.enrich.wagoSlug !== wagoSlug) return;
      d.wagoGallery = res.gallery || res;
      d.wagoGalleryLoading = false;
      if (d.tab === "screenshots") renderScreenshots();
    }).catch(function (err) {
      if (!Store.state.drawer.enrich || Store.state.drawer.enrich.wagoSlug !== wagoSlug) return;
      // Round 9 fix: keep wagoGallery null on failure (was set to {}, which
      // wagoGalleryImages() and a genuinely-empty gallery both render as
      // "No screenshots provided." - indistinguishable from a real network/
      // API failure) - wagoGalleryError carries the failure instead, same
      // {loading, loaded-empty, error} contract as wagoAddonError/
      // wagoReleasesError already use for their own sibling fields.
      d.wagoGalleryError = err;
      d.wagoGalleryLoading = false;
      if (d.tab === "screenshots") renderScreenshots();
    });
  }

  function renderHeader() {
    const d = Store.state.drawer;
    if (d.source === "wago") { renderWagoHeader(); return; }
    const addon = d.tracked ? Store.addonByProjectId(d.projectId) : null;
    // Round 16 (E22, CurseForge key removal): every CurseForge-sourced
    // drawer is keyless now (source is always 'cf-keyless') - this header
    // has only ever had /api/cf/enrich's data to work with since, so it
    // reads d.enrich alone (the old richer d.mod branch, fed by the
    // removed keyed /api/cf/mods/{id} call, is gone).
    const enrich = d.enrich;
    // CS2 bug fix (UX-SPEC.md section 3.5, flagged by every judge as the
    // app's worst functional defect): a TRACKED addon's real name/author is
    // already known locally the instant a row is clicked (Store.state.addons),
    // so it must win over enrich - which starts out null and can itself
    // resolve to a literal "Project <id>" placeholder (the catalogue-only
    // fallback - see Mock's mockCfEnrich) that used to silently override the
    // real tracked name once it loaded. enrich still supplies the name for
    // an UNTRACKED drawer (opened from Browse, where no local addon record
    // exists at all).
    const name = (addon && addon.name) ? addon.name : ((enrich && enrich.name) ? enrich.name : ("Project " + d.projectId));
    // CS2: same tracked-first priority as name above. enrich carries no
    // author field, so an untracked drawer just has none to show.
    const author = (addon && addon.author) ? addon.author : null;
    const logoUrl = enrich ? enrich.logoUrl : null;

    const children = [
      Utils.el("div", { class: "drawer-header-top" }, [
        Components.Logo.build({ projectId: d.projectId, name: name, thumbnailUrl: logoUrl }, 56),
        Utils.el("div", {}, [
          Utils.el("div", { class: "drawer-title" }, [name]),
          author ? Utils.el("div", { class: "drawer-author" }, ["by " + author]) : null
        ])
      ])
    ];

    if (enrich) {
      const meta = [];
      if (enrich.downloadCount != null) meta.push(Utils.el("span", {}, [Utils.formatNumber(enrich.downloadCount) + " downloads"]));
      if (enrich.lastUpdated) meta.push(Utils.el("span", { title: Utils.fullDate(enrich.lastUpdated) }, ["updated " + Utils.relativeTime(enrich.lastUpdated)]));
      if (meta.length) children.push(Utils.el("div", { class: "drawer-meta" }, meta));
      // CS5 (UX-SPEC.md 3.5/§7, "Drawer badge | via catalogue | DELETE"):
      // the old provenance pill ("via catalogue"/"via addon-radar"/"via
      // Wago Addons" - internal plumbing naming which mirror answered the
      // request) is gone; this branch is always a CurseForge-sourced entry
      // (Wago has its own renderWagoHeader above), so it gets the same
      // plain source badge every other CurseForge card in the app uses.
      children.push(Utils.el("span", { class: "source-badge is-cf" }, ["CurseForge"]));
    } else if (d.enrichLoading) {
      children.push(Utils.el("div", { class: "muted-text" }, ["Loading…"]));
    } else if (d.enrichError) {
      children.push(Utils.el("div", { class: "muted-text" }, ["Couldn't load addon details (" + describeError(d.enrichError) + ")."]));
    }

    const links = [];
    links.push(Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.openOnCurseForge(d.projectId, d.slug); } }, [Utils.icon("external"), "CurseForge"]));
    children.push(Utils.el("div", { class: "drawer-links" }, links));

    // E12: the tracked record's own toc-parsed wagoId reveals a CurseForge
    // addon is ALSO on Wago - offers a one-job reinstall from there instead
    // of leaving the reader to go find and re-add it by hand.
    if (addon && addon.wagoId) {
      children.push(Utils.el("div", { class: "drawer-crosssource" }, [Actions.switchSourceButton(addon, "wago", addon.wagoId)]));
    }

    children.push(Utils.el("div", { class: "drawer-primary-action" }, [primaryActionButton(addon, enrich ? enrich.name : null)]));

    const container = Utils.qs("#drawer-header");
    container.textContent = "";
    children.forEach(function (c) { if (c) container.appendChild(c); });
  }

  // E12: Wago's own header render, kept as a fully separate function rather
  // than threading `if (d.source === "wago")` branches through every line of
  // the CurseForge one above - the two sources' metadata shapes (addon/
  // metadata/description vs. mod) share almost nothing structurally.
  function renderWagoHeader() {
    const d = Store.state.drawer;
    const addon = d.tracked ? Store.addonByProjectId(d.projectId) : null;
    const wa = d.wagoAddon;
    const waAddon = wa ? wa.addon : null;
    const meta = wa ? wa.metadata : null;
    const name = (waAddon && waAddon.display_name) || (addon ? addon.name : d.slug);
    const developers = (meta && meta.developers && meta.developers.length) ? meta.developers.map(function (x) { return x.name; }).join(", ") : (addon ? addon.author : null);
    const thumb = waAddon ? waAddon.thumbnail_image : null;

    const children = [
      Utils.el("div", { class: "drawer-header-top" }, [
        Components.Logo.build({ projectId: d.projectId, name: name, thumbnailUrl: thumb }, 56),
        Utils.el("div", {}, [
          Utils.el("div", { class: "drawer-title" }, [name]),
          developers ? Utils.el("div", { class: "drawer-author" }, ["by " + developers]) : null
        ])
      ])
    ];

    if (meta) {
      const metaRow = [
        Utils.el("span", {}, [Utils.formatNumber(meta.download_count) + " downloads"]),
        Utils.el("span", {}, [Utils.formatNumber(meta.like_count) + " likes"]),
        meta.last_update ? Utils.el("span", { title: Utils.fullDate(meta.last_update) }, ["updated " + Utils.relativeTime(meta.last_update)]) : null
      ];
      children.push(Utils.el("div", { class: "drawer-meta" }, metaRow));
    }
    if (waAddon && waAddon.categories && waAddon.categories.length) {
      children.push(Utils.el("div", { class: "drawer-cats" }, waAddon.categories.map(function (c) { return Utils.el("span", { class: "browse-card-cat" }, [c.display_name || c.name]); })));
    }
    if (d.wagoAddonLoading && !wa) children.push(Utils.el("div", { class: "muted-text" }, ["Loading…"]));
    if (d.wagoAddonError && !wa) children.push(Utils.el("div", { class: "muted-text" }, ["Couldn't load addon details (" + describeError(d.wagoAddonError) + ")."]));

    const links = [];
    if (waAddon && waAddon.website) links.push(Utils.el("a", { class: "btn btn-outline", href: waAddon.website, target: "_blank", rel: "noopener noreferrer" }, [Utils.icon("external"), "Website"]));
    if (waAddon && waAddon.source_url) links.push(Utils.el("a", { class: "btn btn-outline", href: waAddon.source_url, target: "_blank", rel: "noopener noreferrer" }, [Utils.icon("external"), "Source"]));
    links.push(Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.openOnWago(d.slug); } }, [Utils.icon("external"), "Wago"]));
    children.push(Utils.el("div", { class: "drawer-links" }, links));

    // E12: the tracked record's own toc-parsed curseId reveals a Wago addon
    // is ALSO on CurseForge.
    if (addon && addon.curseId) {
      children.push(Utils.el("div", { class: "drawer-crosssource" }, [Actions.switchSourceButton(addon, "curseforge", addon.curseId)]));
    }

    children.push(Utils.el("div", { class: "drawer-primary-action" }, [primaryActionButton(addon, null)]));

    const container = Utils.qs("#drawer-header");
    container.textContent = "";
    children.forEach(function (c) { if (c) container.appendChild(c); });
  }

  // Review fix: these were all btn-accent, which meant the drawer's own
  // primary action rendered in the exact same accent color as the sidebar's
  // persistent "Update & Play" button whenever the drawer was open - two
  // accent buttons on screen at once. UX-SPEC.md section 1/2.3 are explicit
  // that Update & Play is the ONLY accent button in the app; everything
  // else (including this drawer action) is outline/ghost/menu.
  function primaryActionButton(addon, fallbackName) {
    const d = Store.state.drawer;
    const pid = d.projectId;
    if (Store.jobActingOn(pid)) return Utils.el("button", { type: "button", class: "btn btn-outline", disabled: true }, ["Installing…"]);
    if (addon) {
      if (addon.updateAvailable) return Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.updateNow(pid); } }, ["Update now"]);
      return Utils.el("button", { type: "button", class: "btn btn-outline", disabled: true }, [Utils.icon("check-circle"), "Installed"]);
    }
    if (d.source === "wago") {
      return Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.installLatestWago(d.slug, (d.wagoAddon && d.wagoAddon.addon) ? d.wagoAddon.addon.display_name : null); } }, ["Install"]);
    }
    return Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.installLatest(pid, fallbackName); } }, ["Install"]);
  }

  // E12: Wago's Overview - always available, no key ever needed. props.description
  // is documented as "plain text/markdown", not HTML like CF's - rendered
  // through the same minimal markdown converter the Changelog tab uses,
  // rather than treated as pre-formatted text (which would lose the
  // headings/lists/links a real changelog-style description commonly has).
  function renderWagoOverview() {
    const panel = Utils.qs("#drawer-panel-overview");
    const d = Store.state.drawer;
    panel.textContent = "";
    if (d.wagoAddonLoading && !d.wagoAddon) {
      panel.appendChild(Utils.el("div", { class: "rich-content" }, ["Loading description…"]));
    } else if (d.wagoAddonError && !d.wagoAddon) {
      panel.appendChild(Utils.el("p", { class: "rich-content" }, ["Couldn't load the description (" + describeError(d.wagoAddonError) + ")."]));
    } else if (d.wagoAddon && d.wagoAddon.description) {
      const holder = Utils.el("div", { class: "rich-content" });
      panel.appendChild(holder);
      Sanitize.render(holder, Markdown.toHtml(d.wagoAddon.description));
    } else if (d.wagoAddon) {
      panel.appendChild(Utils.el("p", { class: "rich-content muted-text" }, ["No description provided."]));
    }
    renderCompat(panel);
    renderDependencies(panel);
  }

  function renderOverview() {
    if (Store.state.drawer.source === "wago") { renderWagoOverview(); return; }
    renderKeylessOverview();
  }

  // E16: Overview for the drawer's (only, since Round 16's key removal)
  // CurseForge fetch path - renders per d.enrich.source. wago-match reuses
  // E12's Wago overview render VERBATIM (it reads only d.wagoAddon/
  // d.wagoAddonLoading/d.wagoAddonError, never d.slug) plus a small
  // attribution note; addon-radar renders its own HTML description (through
  // the same Sanitize.render pipeline the old keyed CurseForge description
  // call used - description_html is real HTML, not markdown, so it does
  // NOT go through the Markdown module); catalogue-only (or no match at
  // all) shows plain "No description available" text, since that's simply
  // what's available - CurseForge's own page (linked in the header) is the
  // fuller source.
  function renderKeylessOverview() {
    const panel = Utils.qs("#drawer-panel-overview");
    const d = Store.state.drawer;

    if (d.enrichLoading && !d.enrich) {
      panel.textContent = "";
      panel.appendChild(Utils.el("div", { class: "rich-content" }, ["Loading description…"]));
      return;
    }
    if (!d.enrich) {
      panel.textContent = "";
      panel.appendChild(Utils.el("p", { class: "rich-content" }, [d.enrichError ? ("Couldn't load addon details (" + describeError(d.enrichError) + ").") : "Loading description…"]));
      renderCompat(panel);
      renderDependencies(panel);
      return;
    }

    if (d.enrich.source === "wago-match") {
      if (!d.wagoAddon && !d.wagoAddonLoading) loadCfKeylessWagoAddon();
      renderWagoOverview();
      const panel2 = Utils.qs("#drawer-panel-overview");
      panel2.appendChild(Utils.el("p", { class: "muted-text source-note" }, ["(metadata from Wago Addons — this addon is also listed there)"]));
      return;
    }

    panel.textContent = "";
    if (d.enrich.source === "addon-radar") {
      const holder = Utils.el("div", { class: "rich-content" });
      panel.appendChild(holder);
      if (d.enrich.descriptionHtml) {
        Sanitize.render(holder, d.enrich.descriptionHtml);
      } else if (d.enrich.summary) {
        holder.appendChild(Utils.el("p", {}, [d.enrich.summary]));
      } else {
        holder.appendChild(Utils.el("p", { class: "muted-text" }, ["No description provided."]));
      }
      // Review fix (principle 2 - "no visible sentence explains a WoW/
      // CurseForge/PowerShell internal the player didn't ask about"): this
      // used to append "(from a community addon index)" here, naming which
      // offline mirror served the description - an internal plumbing detail
      // with no action for the player to take on it. The header's own
      // source badge already says where the addon itself comes from;
      // dropped this line rather than reword it.
    } else {
      if (d.enrich.summary) {
        panel.appendChild(Utils.el("p", { class: "rich-content" }, [d.enrich.summary]));
      } else {
        // Round 16 (E22, CurseForge key removal): no metadata source
        // matched this addon at all - plain text, never a nudge to add a
        // key (the key feature is gone). The header's own "CurseForge"
        // link (renderHeader's drawer-links button a few pixels above) is
        // the fuller source, so no second "open externally" control here.
        panel.appendChild(Utils.el("p", { class: "rich-content muted-text" }, ["No description available."]));
      }
    }
    renderCompat(panel);
    renderDependencies(panel);
  }

  // E3: Required/Optional dependency lists, sourced entirely from the local
  // addon record (requiredDeps/optionalDeps/missingDeps/missingOptionalDeps
  // all come from /api/state) - shown regardless of API key, since none of
  // it is CurseForge data. Only tracked addons carry a local record at all,
  // so a Browse-only drawer (no addon record yet) renders nothing here.
  function renderDependencies(panel) {
    const d = Store.state.drawer;
    if (!d.tracked) return;
    const addon = Store.addonByProjectId(d.projectId);
    if (!addon) return;
    const required = addon.requiredDeps || [];
    const optional = addon.optionalDeps || [];
    if (!required.length && !optional.length) return;

    const section = Utils.el("div", { class: "deps-section" });
    if (required.length) {
      section.appendChild(Utils.el("div", { class: "deps-heading" }, ["Required dependencies"]));
      section.appendChild(depList(required, addon.missingDeps || []));
    }
    if (optional.length) {
      section.appendChild(Utils.el("div", { class: "deps-heading" }, ["Optional dependencies"]));
      section.appendChild(depList(optional, addon.missingOptionalDeps || []));
    }
    panel.appendChild(section);
  }

  // E13 (compatibility audit): drawer Overview's counterpart to the My
  // Addons Compatibility column - same Utils.compatDisplay computation, just
  // rendered as a labeled row instead of a bare table-cell chip. Local-record
  // only (tocInterfaces/compat/latestGameVersions all come from /api/state),
  // so a Browse-only drawer (no tracked addon yet) renders nothing here,
  // same guard shape as renderDependencies just above.
  function renderCompat(panel) {
    const d = Store.state.drawer;
    if (!d.tracked) return;
    const addon = Store.addonByProjectId(d.projectId);
    if (!addon || !addon.compat) return;
    // CS5 (UX-SPEC.md 3.5): "shown once, in the same plain words as the
    // table Status pill... no separate restatement" - just the one chip now,
    // the old raw-detail line (compat-detail, Toc Interface numbers) is gone.
    // Review fix: also drop the standalone "Compatibility" heading/label -
    // section 3.5's own wireframe shows the pill alone with no label above
    // it, and a bare heading fails the banned-term list's "'compat' as a
    // header/label" rule (the carve-out there is for plain sentences only).
    const info = Utils.compatDisplay(addon, Store.state.clientInterface);
    const section = Utils.el("div", { class: "compat-section" }, [
      Utils.el("div", { class: "compat-row" }, [
        Components.Chip.build(info.label, info.cls)
      ])
    ]);
    panel.appendChild(section);
  }

  function depList(names, missingNames) {
    return Utils.el("ul", { class: "deps-list" }, names.map(function (name) {
      const missing = missingNames.indexOf(name) !== -1;
      const row = [
        Utils.el("span", { class: "dep-dot " + (missing ? "is-missing" : "is-installed"), title: missing ? "Not installed" : "Installed" }),
        Utils.el("span", { class: "dep-name" }, [name])
      ];
      if (missing) {
        // Round 15: was "Search CurseForge" - Actions.searchDependency now
        // lands on Get new addons' Wago search (CurseForge is reachable
        // from there via the segment switch, not searched directly by this
        // click any more), so a source-neutral label is the honest one.
        row.push(Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.searchDependency(name); } }, [Utils.icon("search"), "Search for it"]));
      }
      return Utils.el("li", { class: "dep-row" }, row);
    }));
  }

  // E12: fetches page 1 of a Wago addon's releases (SPEC: 10/page). Later
  // pages are not paginated into this tab in this build - the Versions tab
  // has no "load more" affordance of its own anywhere in the base spec, and
  // the newest ~10 releases cover the pin/changelog/install use cases this
  // tab exists for; a -Files-style "see everything" view is a follow-up.
  function loadWagoReleases() {
    const d = Store.state.drawer;
    if (d.wagoReleases || d.wagoReleasesLoading) return;
    d.wagoReleasesLoading = true;
    const slug = d.slug;
    Api.wagoReleases(slug, { page: 1 }).then(function (res) {
      if (Store.state.drawer.slug !== slug) return;
      const paginator = res.data || {};
      d.wagoReleases = paginator.data || [];
      d.wagoReleasesLoading = false;
      if (d.tab === "versions") renderVersions();
      if (d.tab === "changelog") renderChangelog();
    }).catch(function (err) {
      if (Store.state.drawer.slug !== slug) return;
      d.wagoReleasesError = err; d.wagoReleasesLoading = false;
      if (d.tab === "versions") renderVersions();
    });
  }

  function wagoStabilityChipClass(stability) {
    const s = (stability || "").toLowerCase();
    return s === "alpha" ? "chip-danger" : s === "beta" ? "chip-warning" : "chip-success";
  }
  function wagoStabilityLabel(stability) {
    const s = (stability || "").toLowerCase();
    return s === "alpha" ? "Alpha" : s === "beta" ? "Beta" : "Release";
  }

  function renderWagoVersions() {
    const panel = Utils.qs("#drawer-panel-versions");
    const d = Store.state.drawer;
    if (!d.wagoReleases && !d.wagoReleasesLoading) loadWagoReleases();
    panel.textContent = "";
    if (d.wagoReleasesLoading && !d.wagoReleases) { panel.appendChild(Utils.el("div", { class: "skeleton-row" })); return; }
    if (d.wagoReleasesError && !d.wagoReleases) { panel.appendChild(Utils.el("p", { class: "rich-content" }, ["Couldn't load versions (" + describeError(d.wagoReleasesError) + ")."])); return; }
    if (!d.wagoReleases || !d.wagoReleases.length) { panel.appendChild(Utils.el("p", { class: "rich-content" }, ["No releases found for this addon."])); return; }

    const addon = d.tracked ? Store.addonByProjectId(d.projectId) : null;
    const table = Utils.el("table", { class: "versions-table" }, [
      // FLAVORS-SPEC.md CS-F4 (copy table): "Retail Patches" -> "Patches" -
      // was already wrong-by-name for any non-Retail addon; renamed
      // regardless of flavour count since this drawer's data source is
      // touched anyway.
      Utils.el("thead", {}, [Utils.el("tr", {}, ["Version", "Channel", "Patches", "Date", "", ""].map(function (h) { return Utils.el("th", {}, [h]); }))]),
      Utils.el("tbody", {}, d.wagoReleases.map(function (r) { return wagoVersionRow(r, addon); }))
    ]);
    panel.appendChild(table);
  }

  function wagoVersionRow(release, addon) {
    const tags = [];
    const relId = String(release.id);
    if (addon && String(addon.fileId) === relId) tags.push(Utils.el("span", { class: "version-tag installed" }, ["Installed"]));
    if (addon && String(addon.pinnedFileId) === relId) tags.push(Utils.el("span", { class: "version-tag pinned" }, ["Pinned"]));
    if (addon && String(addon.previousFileId) === relId) tags.push(Utils.el("span", { class: "version-tag previous" }, ["Previous"]));
    const patches = (release.supported_retail_patches && release.supported_retail_patches.length) ? release.supported_retail_patches.join(", ") : "-";
    return Utils.el("tr", {}, [
      Utils.el("td", {}, [
        Utils.el("span", {}, [release.label]),
        Utils.el("span", { class: "version-size" }, [" · " + Utils.formatBytes(release.size)])
      ].concat(tags)),
      Utils.el("td", {}, [Utils.el("span", { class: "chip " + wagoStabilityChipClass(release.stability) }, [wagoStabilityLabel(release.stability)])]),
      Utils.el("td", {}, [patches]),
      Utils.el("td", { title: Utils.fullDate(release.created_at) }, [Utils.relativeTime(release.created_at)]),
      Utils.el("td", {}, [release.changelog ? Utils.el("button", { type: "button", class: "link-btn", onclick: function () { selectTab("changelog"); loadWagoChangelogFor(relId); } }, ["Changelog"]) : null]),
      Utils.el("td", {}, [wagoVersionButton(release, addon)])
    ]);
  }

  function wagoVersionButton(release, addon) {
    const d = Store.state.drawer;
    if (Store.jobActingOn(d.projectId)) return Utils.el("button", { type: "button", class: "btn btn-outline", disabled: true, title: "Another task is running" }, ["Installing…"]);
    const relId = String(release.id);
    if (addon) {
      if (String(addon.pinnedFileId) === relId) return Utils.el("button", { type: "button", class: "btn btn-outline", disabled: true }, ["Pinned"]);
      const label = String(addon.fileId) === relId ? "Pin this version" : "Install";
      return Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.installVersion(d.projectId, relId, label === "Pin this version" ? ("Pinning " + addon.name) : undefined); } }, [label]);
    }
    return Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.addWagoWithVersion(d.slug, relId); } }, ["Install"]);
  }

  function renderVersions() {
    const panel = Utils.qs("#drawer-panel-versions");
    const d = Store.state.drawer;
    if (d.source === "wago") { renderWagoVersions(); return; }
    if (!d.files && !d.filesLoading) {
      d.filesLoading = true;
      const pid = projectId();
      Api.getAddonFiles(pid).then(function (res) {
        if (projectId() !== pid) return;
        d.files = res.files || [];
        d.filesLoading = false;
        if (d.tab === "versions") renderVersions();
        if (d.tab === "changelog") renderChangelog();
      }).catch(function (err) {
        if (projectId() !== pid) return;
        d.filesError = err; d.filesLoading = false;
        if (d.tab === "versions") renderVersions();
      });
    }
    panel.textContent = "";
    if (d.filesLoading && !d.files) { panel.appendChild(Utils.el("div", { class: "skeleton-row" })); return; }
    if (d.filesError && !d.files) { panel.appendChild(Utils.el("p", { class: "rich-content" }, ["Couldn't load versions (" + describeError(d.filesError) + ")."])); return; }
    if (!d.files || !d.files.length) { panel.appendChild(Utils.el("p", { class: "rich-content" }, ["No files found for this project."])); return; }

    const addon = d.tracked ? Store.addonByProjectId(d.projectId) : null;
    // Size is folded into the Version cell (as a small muted suffix) rather than
    // getting its own column: at the drawer's 640px width, a full 7-column table
    // (incl. the per-row action button) silently overflows past the drawer's
    // right edge with no scrollbar to reach it - dropping this one column keeps
    // every column, action button included, inside the visible width.
    const table = Utils.el("table", { class: "versions-table" }, [
      Utils.el("thead", {}, [Utils.el("tr", {}, ["Version", "Channel", "Game Versions", "Date", "Downloads", ""].map(function (h) { return Utils.el("th", {}, [h]); }))]),
      Utils.el("tbody", {}, d.files.map(function (f) { return versionRow(f, addon); }))
    ]);
    panel.appendChild(table);
  }

  // "12.1.0" and "12.1.5" both compatible? show every version the file lists rather
  // than guessing which one matters - lets the reader spot retail vs. classic builds.
  function gameVersionsText(gameVersions) {
    if (!gameVersions || !gameVersions.length) return "-";
    return gameVersions.join(", ");
  }

  function versionRow(file, addon) {
    const tags = [];
    if (addon && addon.fileId === file.id) tags.push(Utils.el("span", { class: "version-tag installed" }, ["Installed"]));
    if (addon && addon.pinnedFileId === file.id) tags.push(Utils.el("span", { class: "version-tag pinned" }, ["Pinned"]));
    // E1: marks the file this addon was on immediately before its last
    // update/rollback, so "Roll back to..." in the kebab menu has a visible
    // target in this list.
    if (addon && addon.previousFileId === file.id) tags.push(Utils.el("span", { class: "version-tag previous" }, ["Previous"]));
    return Utils.el("tr", {}, [
      Utils.el("td", {}, [
        Utils.el("span", {}, [file.displayName || file.version || file.fileName]),
        Utils.el("span", { class: "version-size" }, [" · " + Utils.formatBytes(file.fileLength)])
      ].concat(tags)),
      Utils.el("td", {}, [Utils.el("span", { class: "chip " + Utils.releaseChipClass(file.releaseType) }, [Utils.releaseLabel(file.releaseType)])]),
      Utils.el("td", { class: "version-gameversions" }, [gameVersionsText(file.gameVersions)]),
      Utils.el("td", { title: Utils.fullDate(file.dateCreated) }, [Utils.relativeTime(file.dateCreated)]),
      Utils.el("td", {}, [Utils.formatNumber(file.downloads)]),
      Utils.el("td", {}, [versionButton(file, addon)])
    ]);
  }

  function versionButton(file, addon) {
    const pid = Store.state.drawer.projectId;
    if (Store.jobActingOn(pid)) return Utils.el("button", { type: "button", class: "btn btn-outline", disabled: true, title: "Another task is running" }, ["Installing…"]);
    if (addon) {
      if (addon.pinnedFileId === file.id) return Utils.el("button", { type: "button", class: "btn btn-outline", disabled: true }, ["Pinned"]);
      const label = addon.fileId === file.id ? "Pin this version" : "Install";
      return Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.installVersion(pid, file.id); } }, [label]);
    }
    return Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.addWithVersion(pid, file.id); } }, ["Install"]);
  }

  // E12: Wago's changelog is per-release text already present on the
  // release object itself (release.changelog) - no separate fetch needed,
  // unlike CurseForge's changelog (its own endpoint per file id). Always
  // available, no key needed.
  function loadWagoChangelogFor(releaseId) {
    const d = Store.state.drawer;
    d.changelogFileId = releaseId;
    if (d.tab === "changelog") renderChangelog();
  }

  function renderWagoChangelog() {
    const panel = Utils.qs("#drawer-panel-changelog");
    const d = Store.state.drawer;
    panel.textContent = "";
    if (!d.wagoReleases && !d.wagoReleasesLoading) loadWagoReleases();
    if (!d.wagoReleases) {
      panel.appendChild(Utils.el("div", { class: "rich-content" }, ["Loading versions…"]));
      return;
    }
    if (!d.wagoReleases.length) {
      panel.appendChild(Utils.el("p", { class: "rich-content" }, ["No releases found for this addon."]));
      return;
    }
    const select = Utils.el("select", { class: "select", onchange: function (ev) { loadWagoChangelogFor(ev.target.value); } },
      d.wagoReleases.map(function (r) { return Utils.el("option", { value: r.id }, [r.label]); }));
    panel.appendChild(Utils.el("div", { class: "changelog-select-row" }, [Utils.el("span", { class: "muted-text" }, ["Version:"]), select]));
    const startId = d.changelogFileId || String(d.wagoReleases[0].id);
    select.value = startId;
    const release = d.wagoReleases.filter(function (r) { return String(r.id) === String(startId); })[0];
    const body = Utils.el("div", { class: "rich-content" });
    panel.appendChild(body);
    if (release && release.changelog) {
      Sanitize.render(body, Markdown.toHtml(release.changelog));
    } else {
      body.textContent = "No changelog provided for this version.";
    }
  }

  function renderChangelog() {
    if (Store.state.drawer.source === "wago") { renderWagoChangelog(); return; }
    renderKeylessChangelog();
  }

  // E16: Changelog for the drawer's (only, since Round 16's key removal)
  // CurseForge fetch path. wago-match reuses E12's existing Wago changelog
  // tab exactly (per-release markdown changelog) - renderWagoChangelog only
  // reads d.wagoReleases/d.changelogFileId, never d.slug, so pre-populating
  // d.wagoReleases via loadCfKeylessWagoReleases (keyed by
  // d.enrich.wagoSlug) and then calling it directly is enough. Every other
  // case (addon-radar, catalogue-only, no match at all) shows a plain empty
  // state with a link to CurseForge's own page - SPEC's own investigation
  // found no keyless source anywhere that exposes CurseForge changelog
  // text, and the old key-gated per-file changelog endpoint is gone with
  // the key feature (Round 16, E22), so this is a permanent gap, never a
  // blank tab or a stuck spinner.
  function renderKeylessChangelog() {
    const panel = Utils.qs("#drawer-panel-changelog");
    const d = Store.state.drawer;

    if (d.enrich && d.enrich.source === "wago-match") {
      if (!d.wagoReleases && !d.wagoReleasesLoading) loadCfKeylessWagoReleases();
      renderWagoChangelog();
      return;
    }

    panel.textContent = "";
    panel.appendChild(Utils.el("p", { class: "rich-content muted-text" }, ["No changelog available."]));
    panel.appendChild(Utils.el("div", { class: "btn-row" }, [
      Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.openOnCurseForge(d.projectId, (d.enrich && d.enrich.slug) || d.slug); } }, [Utils.icon("external"), "View on CurseForge.com"])
    ]));
  }

  // E12: Wago's gallery shape is documented in SPEC as "inspect and
  // document" - genuinely unverified against the live site (no Wago
  // requests were made during this build). Renders defensively: tries the
  // handful of plausible shapes (an array of urls, or objects carrying url/
  // thumbnailUrl/src/image) and falls back to an empty state rather than
  // guessing wrong and throwing.
  function wagoGalleryImages(gallery) {
    if (!gallery) return [];
    const raw = Array.isArray(gallery) ? gallery : (gallery.images || gallery.screenshots || gallery.gallery || []);
    return (raw || []).map(function (item) {
      if (typeof item === "string") return { full: item, thumb: item };
      const full = item.url || item.image || item.full || item.src || "";
      const thumb = item.thumbnailUrl || item.thumbnail || item.thumb || full;
      return { full: full, thumb: thumb };
    }).filter(function (x) { return x.full; });
  }

  function renderWagoScreenshots() {
    const panel = Utils.qs("#drawer-panel-screenshots");
    const d = Store.state.drawer;
    panel.textContent = "";
    if (!d.wagoGallery && !d.wagoGalleryLoading) {
      d.wagoGalleryLoading = true;
      d.wagoGalleryError = null;
      const slug = d.slug;
      Api.wagoGallery(slug).then(function (res) {
        if (Store.state.drawer.slug !== slug) return;
        d.wagoGallery = res.gallery || res;
        d.wagoGalleryLoading = false;
        if (d.tab === "screenshots") renderScreenshots();
      }).catch(function (err) {
        if (Store.state.drawer.slug !== slug) return;
        // Round 9 fix: see loadCfKeylessWagoGallery's identical fix above -
        // wagoGallery stays null on failure so wagoGalleryError (checked
        // below) can render a distinct "couldn't load" state instead of the
        // same "No screenshots provided." a genuinely empty gallery shows.
        d.wagoGalleryError = err;
        d.wagoGalleryLoading = false;
        if (d.tab === "screenshots") renderScreenshots();
      });
    }
    if (d.wagoGalleryLoading && !d.wagoGallery) { panel.appendChild(Utils.el("p", { class: "rich-content" }, ["Loading…"])); return; }
    if (d.wagoGalleryError && !d.wagoGallery) { panel.appendChild(Utils.el("p", { class: "rich-content" }, ["Couldn't load screenshots (" + describeError(d.wagoGalleryError) + ")."])); return; }
    const images = wagoGalleryImages(d.wagoGallery);
    if (!images.length) { panel.appendChild(Utils.el("p", { class: "rich-content" }, ["No screenshots provided."])); return; }
    panel.appendChild(Utils.el("div", { class: "screenshots-grid" }, images.map(function (s) {
      return Utils.el("img", { class: "screenshot-thumb", src: s.thumb, alt: "", loading: "lazy", onclick: function () { Components.Lightbox.open(s.full); } });
    })));
  }

  // E16: Screenshots for a 'cf-keyless' drawer. wago-match reuses E12's
  // existing Wago gallery renderer exactly (same reasoning as
  // renderKeylessChangelog above - renderWagoScreenshots only reads
  // d.wagoGallery, never d.slug, once pre-populated by
  // loadCfKeylessWagoGallery). addon-radar feeds its own screenshots[]
  // into the SAME lightbox grid component E12 built for Wago's gallery,
  // just a different data source; every other case shows the existing
  // empty state.
  function renderKeylessScreenshots() {
    const panel = Utils.qs("#drawer-panel-screenshots");
    const d = Store.state.drawer;

    if (d.enrich && d.enrich.source === "wago-match") {
      if (!d.wagoGallery && !d.wagoGalleryLoading) loadCfKeylessWagoGallery();
      renderWagoScreenshots();
      return;
    }

    panel.textContent = "";
    const shots = (d.enrich && d.enrich.source === "addon-radar") ? (d.enrich.screenshots || []) : [];
    if (!shots.length) { panel.appendChild(Utils.el("p", { class: "rich-content" }, ["No screenshots provided."])); return; }
    panel.appendChild(Utils.el("div", { class: "screenshots-grid" }, shots.map(function (s) {
      const full = s.url || s.thumbnail;
      const thumb = s.thumbnail || s.url;
      return Utils.el("img", { class: "screenshot-thumb", src: thumb, alt: s.title || "", loading: "lazy", onclick: function () { Components.Lightbox.open(full); } });
    })));
  }

  function renderScreenshots() {
    if (Store.state.drawer.source === "wago") { renderWagoScreenshots(); return; }
    renderKeylessScreenshots();
  }

  return { open: open, close: close, isOpen: isOpen, selectTab: selectTab, refresh: refresh };
})();

/* ---------- Bottom job progress panel ---------- */
Components.JobPanel = (function () {
  // CS2 (UX-SPEC.md section 4.1/4.3): job kinds whose job.progress the CLI/
  // server actually populate (see addon-sync.ps1's Write-ProgressStep call
  // sites) - every other kind (remove/rollback/import/switch-source) has no
  // progress object at all, and keeps the plain title-bar-only view this
  // panel always had.
  // Review fix: "launch" belongs here too - addon-server.ps1's Start-Job
  // (see the $cliKind mapping right above the Job object literal) always
  // runs a "launch" job's CLI process as $cliKind='sync' when updateFirst is
  // true (Update & Play), so -ProgressPath is threaded and job.progress is
  // populated exactly like a real "sync" job; a launchOnly (updateFirst:
  // false) job never reaches a CLI process at all (see the synchronous
  // no-CLI branch in Start-Job) and finishes before job.progress.total is
  // ever > 0, so showProgress below still correctly stays false for it.
  const PROGRESS_KINDS = ["sync", "check", "add", "install", "launch"];

  // CS2: job.progress is a single overwritten snapshot (the server's
  // best-effort read of one progress.json file), not a per-addon history -
  // once the run moves on to its next target, a `failed` addon's own
  // failPhase is gone from job.progress. This module-scoped map catches
  // every failPhase this panel actually SAW while polling (best-effort,
  // same as the server's own read of progress.json) and keys it by addon
  // name so the done-state failure list (built after the job finishes,
  // when job.progress may already point at a different/no addon) can still
  // look each failed row's phase up. Cleared whenever a new job starts.
  let failPhaseByName = {};
  let trackedJobId = null;

  // Review fix (UX-SPEC.md 2.3 / 7): "Done, all succeeded - panel collapses
  // to 'Updated N (dot) checked just now' for ~4 seconds then reverts to the
  // 'Up to date' headline. No permanent 'last run' line survives." This was
  // never implemented (CS2's own notesForNext flagged the gap) - the panel
  // just sat open indefinitely after every finished job. successHandledJobId
  // guards so a job id is only ever collapsed once (pollJob's final "not
  // running" tick is normally the only trigger, but show() can also re-fire
  // update() for an already-finished job on a page reload/reconnect).
  let successHandledJobId = null;
  let successCollapseTimer = null;

  function scheduleSuccessCollapse(job) {
    if (job.id === successHandledJobId) return;
    successHandledJobId = job.id;
    const updatedCount = job.results.filter(function (r) { return r.status === "Updated" || r.status === "Installed"; }).length;
    const titleEl = Utils.qs("#job-title");
    if (titleEl) {
      titleEl.textContent = updatedCount > 0
        ? ("Updated " + updatedCount + " · checked just now")
        : ("Everything's up to date · checked just now");
    }
    const panel = Utils.qs("#job-panel");
    if (panel && !panel.classList.contains("is-collapsed")) toggleCollapse();
    clearTimeout(successCollapseTimer);
    successCollapseTimer = setTimeout(function () { hide(); }, 4000);
  }

  function trackProgress(job) {
    if (job.id !== trackedJobId) { failPhaseByName = {}; trackedJobId = job.id; }
    const p = job.progress;
    if (p && p.phase === "failed" && p.addon) failPhaseByName[p.addon] = p.failPhase || null;
  }

  // CS2 (UX-SPEC.md section 4.3): maps a failed row's last-seen failPhase to
  // one of the spec's plain-language reasons. Only three failPhase values
  // ever reach the wire (checking/downloading/installing - see addon-sync.ps1's
  // Write-ProgressStep), one short of the spec's five-bucket list - "checking"
  // is mapped to "No matching version found" (the most common reason a sync
  // fails during its own check step, before any download/install ever
  // starts); "no compatible file found" isn't a separate signal available
  // client-side. A failure this panel never actually polled a failPhase for
  // (missed by the 500ms cadence, or a whole-job failure with no per-addon
  // progress at all) falls back to a connectivity guess (offline right now)
  // or the generic catch-all, per the spec's own last-resort bucket.
  function failureReason(r) {
    const failPhase = failPhaseByName[r.name];
    if (failPhase === "downloading") return "Couldn't download the update";
    if (failPhase === "installing") return "Couldn't install the update";
    if (failPhase === "checking") return "No matching version found";
    if (Store.state.online === false) return "Couldn't reach CurseForge — check your connection";
    return "Something went wrong";
  }

  // Review fix (UX-SPEC.md 4.3 / acceptance checklist item 8): the same
  // plain-language treatment as failureReason(), but for a WHOLE-JOB
  // failure (job.state === "failed", no per-addon progress to key off of -
  // e.g. a corrupted addons.json causing CLI exit code 2, a JSON-parse
  // failure of the CLI's own output, or any uncaught server-side
  // exception). job.error in these cases is raw stderr/exception text and
  // must never be the default on-screen string; it stays available only
  // via #job-log/Details (see update() below). Exported so pollJob's own
  // terminal-poll toast (ui/app.js, App module) can show the identical
  // plain sentence instead of concatenating raw job.error itself.
  function wholeJobFailureReason(job) {
    if (Store.state.online === false) return "Couldn't reach CurseForge — check your connection";
    const err = ((job && job.error) || "").toLowerCase();
    if (err.indexOf("json") !== -1 || err.indexOf("parse") !== -1) return "Something went wrong reading the results";
    if (err.indexOf("exit") !== -1 || err.indexOf("code") !== -1) return "Something went wrong running the update";
    return "Something went wrong";
  }

  // Review fix: a 'done' job (job.state stays "done" even when one addon's
  // OWN result was Failed - only a whole-job crash sets "failed") used to
  // always show the blind past-tense scope label ("Done — Updated 3
  // addons"), which overstates success right above a results list showing a
  // red "Couldn't download the update" row for one of those three. Mirrors
  // the count-aware wording scheduleSuccessCollapse already computes for its
  // all-succeeded case, extended to cover the partial-failure case that was
  // left using the generic label. Kind-independent ("succeeded"/"failed"
  // reads correctly whether the job was a sync, a check, an add, or any
  // other results-bearing kind) rather than reusing "Updated", which is
  // wrong wording for e.g. a "check" job where nothing was updated at all.
  function doneTitleWithFailures(job) {
    if (!job.results || !job.results.length) return null;
    const failedCount = job.results.filter(function (r) { return r.status === "Failed"; }).length;
    if (failedCount === 0) return null;
    const okCount = job.results.length - failedCount;
    return "Done — " + okCount + " succeeded, " + failedCount + " failed";
  }

  // Review fix: moved to Utils.phaseWord so Components.Chip.forStatus can
  // share the exact same mapping - kept as a thin alias here so every
  // existing call site in this module still reads `phaseWord(...)`.
  function phaseWord(phase) { return Utils.phaseWord(phase); }

  function summarize(results) {
    if (!results || !results.length) return "No changes.";
    const counts = {};
    results.forEach(function (r) { counts[r.status] = (counts[r.status] || 0) + 1; });
    const order = ["Updated", "Installed", "Removed", "Launched", "Rolled-back", "Pinned", "Unpinned", "Ignored", "Unignored", "Would-update", "Up-to-date", "Skipped", "Failed"];
    const labels = { "Updated": "updated", "Installed": "installed", "Removed": "removed", "Launched": "launched", "Rolled-back": "rolled back", "Pinned": "pinned", "Unpinned": "unpinned", "Ignored": "ignored", "Unignored": "unignored", "Would-update": "update available", "Up-to-date": "up to date", "Skipped": "skipped", "Failed": "failed" };
    const parts = [];
    order.forEach(function (status) {
      if (counts[status]) {
        const n = counts[status];
        let label = labels[status] || status.toLowerCase();
        if (status === "Would-update" && n !== 1) label = "updates available";
        parts.push(n + " " + label);
      }
    });
    return parts.join(", ") || "Done.";
  }

  function titleFor(job) {
    if (Store.state.jobLabel) return Store.state.jobLabel;
    if (!job) return "Working…";
    const map = { check: "Checking for updates", sync: "Syncing addons", add: "Adding addon", install: "Installing version", remove: "Removing addon", launch: "Launching World of Warcraft", rollback: "Rolling back version", import: "Loading addon list", "switch-source": "Reinstalling from another source" };
    return map[job.kind] || "Working…";
  }

  // FLAVORS-SPEC.md CS-F4 (section 5.4/6.2): the job title's flavour badge -
  // reuses the switcher's own pill look (.flavour-pill), a plain label only
  // (never the era subtitle - word budget, same as the switcher itself).
  function hideJobFlavourBadge() {
    const badge = Utils.qs("#job-flavour-badge");
    if (badge) badge.hidden = true;
  }
  function renderJobFlavourBadge(job) {
    const badge = Utils.qs("#job-flavour-badge");
    if (!badge) return;
    if (!Store.hasMultipleFlavours() || !job.flavour) { badge.hidden = true; return; }
    const meta = Store.state.installedFlavours.filter(function (f) { return f.id === job.flavour; })[0];
    badge.textContent = meta ? meta.label : job.flavour;
    badge.hidden = false;
  }

  // Review fix: the finished title used to reuse the running label verbatim
  // ("Done — Updating 3 addons"), a tense collision that reads as unfinished
  // text. titleFor()'s label is free-form (every Actions.startJob call site
  // writes its own present-progressive sentence, ~25 of them), so rather
  // than threading a second done-tense string through every call site, this
  // rewrites the SAME label's leading gerund to its past-tense form via an
  // ordered prefix list (longest/most-specific match first, since several
  // share a leading word - e.g. "Updating & launching" vs plain "Updating").
  // Any label that doesn't start with a known gerund (there is none today,
  // but a future call site's wording could drift) is returned unchanged
  // rather than risking a garbled rewrite.
  const PAST_TENSE_PATTERNS = [
    [/^Updating & launching/, "Updated & launched"],
    [/^Checking for updates/, "Checked for updates"],
    [/^Force reinstalling/, "Force reinstalled"],
    [/^Rolling back/, "Rolled back"],
    [/^Taking over/, "Took over"],
    [/^Retrying/, "Retried"],
    [/^Updating/, "Updated"],
    [/^Installing/, "Installed"],
    [/^Adding/, "Added"],
    [/^Removing/, "Removed"],
    [/^Reinstalling/, "Reinstalled"],
    [/^Loading/, "Loaded"],
    [/^Launching/, "Launched"],
    [/^Syncing/, "Synced"]
  ];
  function pastTenseLabel(label) {
    if (!label) return label;
    for (let i = 0; i < PAST_TENSE_PATTERNS.length; i++) {
      const pair = PAST_TENSE_PATTERNS[i];
      if (pair[0].test(label)) return label.replace(pair[0], pair[1]);
    }
    return label;
  }

  // E5: a per-row "What changed" control for a just-Updated/Installed addon.
  // Guarded on r.projectId being present (every real sync/add/install/launch
  // result row carries one per SPEC's documented results shape).
  function whatChangedButton(r) {
    if (r.status !== "Updated" && r.status !== "Installed") return null;
    // E12: a Wago row's projectId is always null (it has none) - its
    // stable key comes from the additive wagoSlug field instead (see
    // addon-sync.ps1's -Json contract). Still omitted for a synthesized
    // last-run pseudo-job row, which carries neither.
    const key = (r.projectId !== undefined && r.projectId !== null) ? r.projectId : (r.wagoSlug ? "wago:" + r.wagoSlug : null);
    if (key === null) return null;
    return Utils.el("button", { type: "button", class: "link-btn job-result-whatchanged", onclick: function () { Actions.whatChanged(key, r.fileId); } }, ["What changed"]);
  }

  // CS2: a per-row Retry for a failed job result - re-posts the SAME job
  // kind, scoped to just this one addon, reusing the server's existing
  // single-target params (no new server logic needed, per the spec). A
  // "sync"/"check" job (Update all / Update now / Update selected / Check
  // now all post one of these kinds) retries with `ids:[key]`; "add"/
  // "install" jobs are already single-target, so retrying just re-posts the
  // same params.
  // Review fix: "rollback" and "switch-source" were falling through to the
  // generic sync-retry branch below, which is wrong for both - a failed
  // rollback (no previousFileId, or its backup zip missing/corrupt) got
  // silently retried as a plain sync, which installs the LATEST version
  // instead of retrying the rollback (the opposite of what was asked); a
  // failed switch-source got retried as a sync against the OLD source key,
  // which by then may already be gone (the switch's own -Remove phase can
  // have already dropped it), making the "retry" a confusing no-op. Both
  // now re-post their own job kind instead.
  function retryFailedResult(job, r) {
    const key = (r.projectId !== undefined && r.projectId !== null) ? r.projectId : (r.wagoSlug ? "wago:" + r.wagoSlug : null);
    const label = "Retrying " + (r.name || "addon");
    if (job.kind === "add" || job.kind === "install") return Actions.startJob(job.kind, job.params, label);
    if (job.kind === "rollback") {
      if (key !== null) return Actions.startJob("rollback", { projectId: Utils.normalizeId(key) }, label);
    } else if (job.kind === "switch-source") {
      // job.params already carries the full {projectId, toSource, toTarget}
      // this job kind needs - re-post it verbatim rather than deriving a
      // new one from the result row, which only carries the OLD source's key.
      return Actions.startJob("switch-source", job.params, label);
    } else if (key !== null) {
      return Actions.startJob("sync", { ids: [Utils.normalizeId(key)] }, label);
    }
    // Defensive fallback - every real result row carries either projectId or
    // wagoSlug (see SPEC's -Json contract), so this should be unreachable;
    // still better than a silently do-nothing Retry click.
    Components.Toast.show("Couldn't identify " + (r.name || "that addon") + " to retry it.", "error");
    return null;
  }

  function show(job) {
    const panel = Utils.qs("#job-panel");
    panel.hidden = false;
    panel.classList.remove("is-collapsed");
    Utils.qs("#job-panel-collapse .icon use").setAttribute("href", "#icon-chevron-down");
    // CS2: the raw log disclosure starts closed for every new job, even if
    // a curious click left it open during a previous one (UX-SPEC.md 4.3 -
    // "closed-by-default", not just closed-once-ever).
    const details = Utils.qs("#job-details");
    if (details) details.open = false;
    // Review fix: a brand-new job means any pending success-collapse from a
    // previous finished job is no longer relevant - clear it so its 4s
    // timer can never call hide() out from under the job that's now showing.
    clearTimeout(successCollapseTimer);
    successHandledJobId = null;
    update(job);
  }

  function update(job) {
    if (!job) return;
    const panel = Utils.qs("#job-panel");
    if (panel.hidden) panel.hidden = false;

    // FLAVORS-SPEC.md CS-F3 S5.5 case 5 / S6.4: the server created this job
    // but could not tell which installed WoW flavour it targets (a
    // CurseForge file the account's client supports more than one of) -
    // this same panel asks instead of the normal running/done/failed
    // rendering below. Plain words, remembers nothing across jobs (no
    // stored "last picked flavour") - a fresh pick every time this state
    // is hit, per this round's own bar. Never reached on a single-flavour
    // machine (the server-side resolution this state comes from only ever
    // engages when more than one flavour is installed).
    if (job.state === "awaiting_flavour") {
      Utils.qs("#job-title").textContent = "Which version of WoW?";
      // No single flavour to badge yet - this job belongs to none until one
      // of the choices below is picked (see Get-CurrentOrLastJobSummary's
      // own matching rule server-side).
      hideJobFlavourBadge();
      Utils.qs("#job-spinner").classList.add("is-done");
      Utils.qs("#job-panel-close").hidden = false;
      Utils.qs("#job-progress-wrap").hidden = true;
      Utils.qs("#job-log").textContent = "";
      const resultsBox = Utils.qs("#job-results");
      resultsBox.textContent = "";
      resultsBox.hidden = false;
      resultsBox.appendChild(Utils.el("div", { class: "job-result-row" }, [
        Utils.el("span", {}, ["This addon supports more than one of your installed WoW versions."])
      ]));
      // FLAVORS-SPEC.md CS-F4 (section 6.4): restyled to reuse the
      // switcher's own pill look (.flavour-pill) instead of a plain
      // btn-outline row, now that that styling exists - the underlying
      // choices/onclick wiring CS-F3 built is unchanged.
      resultsBox.appendChild(Utils.el("div", { class: "flavour-pills" }, (job.choices || []).map(function (c) {
        return Utils.el("button", {
          type: "button", class: "flavour-pill",
          onclick: function () { Actions.resumeJobWithFlavour(job, c.id); }
        }, [c.label]);
      })));
      const jobBody = Utils.qs("#job-panel-body");
      jobBody.scrollTop = jobBody.scrollHeight;
      return;
    }

    const running = job.state === "running";
    // Review fix: the finished title is now tense-correct in both the Done
    // and Failed states ("Done — Updated 3 addons" / "Failed — Updated 3
    // addons") instead of reusing the present-progressive running label
    // verbatim, which read as unfinished/broken text.
    const doneWithFailuresTitle = (!running && job.state === "done") ? doneTitleWithFailures(job) : null;
    Utils.qs("#job-title").textContent = running
      ? titleFor(job)
      : (doneWithFailuresTitle || ((job.state === "failed" ? "Failed — " : "Done — ") + pastTenseLabel(titleFor(job))));
    // FLAVORS-SPEC.md CS-F4 (section 5.4/6.2): a flavour badge next to the
    // title, shown only once more than one flavour is installed and this
    // job actually names one (every job does, except an unresolved
    // awaiting_flavour one - handled in its own branch above).
    renderJobFlavourBadge(job);
    Utils.qs("#job-spinner").classList.toggle("is-done", !running);
    Utils.qs("#job-panel-close").hidden = running;

    if (PROGRESS_KINDS.indexOf(job.kind) !== -1) trackProgress(job);

    // CS2 (UX-SPEC.md section 4.3): determinate n-of-N bar + current-item
    // phase line, driven directly by job.progress - the primary view for
    // any job kind the CLI reports progress for, replacing the old
    // log-only panel. Every other kind (remove/rollback/import/switch-
    // source, and a launchOnly launch job) has no job.progress at all, so
    // this whole block just stays hidden and the panel falls back to its
    // title bar + Details, same as always.
    const progressWrap = Utils.qs("#job-progress-wrap");
    const showProgress = running && PROGRESS_KINDS.indexOf(job.kind) !== -1 && job.progress && job.progress.total > 0;
    progressWrap.hidden = !showProgress;
    if (showProgress) {
      const p = job.progress;
      const bar = Utils.qs("#job-progress-bar");
      const label = Utils.qs("#job-progress-label");
      const current = Utils.qs("#job-progress-current");
      if (job.kind === "check") {
        bar.removeAttribute("value"); // indeterminate
        // Review fix: -webkit-appearance:none (needed for the determinate
        // bar's themed fill/track colors) also strips the browser's own
        // indeterminate animation, leaving a flat, static track with no
        // value-less native rendering to fall back on. .is-indeterminate
        // (style.css) drives a themed sweep animation instead so this state
        // reads as active, not stalled.
        bar.classList.add("is-indeterminate");
        label.textContent = "Checking…";
      } else {
        bar.classList.remove("is-indeterminate");
        bar.max = p.total; bar.value = p.index;
        label.textContent = "Updating " + p.index + " of " + p.total + " addons…";
      }
      // Review fix (UX-SPEC.md 4.3): "Downloading (+ % from bytesDone/
      // bytesTotal when present)" - CS6 (addon-sync.ps1) now populates real
      // byte counts during the downloading phase and addon-server.ps1 passes
      // them through on job.progress untouched, but nothing here ever read
      // them. Only appended when phase is actually "downloading" and a
      // nonzero bytesTotal came through (a job/kind that never reports
      // bytes - or a target too small to hit CS6's throttle before moving
      // on - just shows the plain phase word, same as before).
      let currentText = (p.addon && p.phase && p.phase !== "queued") ? (phaseWord(p.phase) + " " + p.addon) : "";
      if (p.phase === "downloading" && p.bytesTotal) {
        currentText += " (" + Math.round((p.bytesDone / p.bytesTotal) * 100) + "%)";
      }
      current.textContent = currentText;
    }

    const log = Utils.qs("#job-log");
    let logText = (job.log || []).join("\n");
    // Review fix (UX-SPEC.md 4.3 / acceptance checklist item 8): a whole-job
    // failure's raw job.error (stderr/exception text) belongs behind this
    // Details disclosure, never in the always-visible results box - see the
    // plain-language row below instead.
    if (job.state === "failed" && job.error) {
      logText = (logText ? logText + "\n\n" : "") + job.error;
    }
    log.textContent = logText;

    const resultsBox = Utils.qs("#job-results");
    resultsBox.textContent = "";
    let any = false;
    if (job.state === "failed" && job.error) {
      resultsBox.appendChild(Utils.el("div", { class: "job-result-row is-failed" }, [
        Utils.el("span", { class: "job-result-reason" }, [wholeJobFailureReason(job)])
      ]));
      any = true;
    }
    // CS2: one clean per-addon list, done state only - a failed row gets a
    // plain-language reason (never raw exception text) plus an inline
    // Retry scoped to just that addon; the raw log stays reachable behind
    // Details regardless.
    if (!running && job.results && job.results.length) {
      job.results.forEach(function (r) {
        const failed = r.status === "Failed";
        const row = [Utils.el("div", { class: "job-result-name" }, [Utils.el("span", {}, [r.name || ""]), whatChangedButton(r)])];
        if (failed) {
          row.push(Utils.el("div", { class: "job-result-fail" }, [
            Utils.el("span", { class: "job-result-reason" }, [failureReason(r)]),
            Utils.el("button", { type: "button", class: "link-btn", onclick: function () { retryFailedResult(job, r); } }, ["Retry"])
          ]));
        } else {
          row.push(Components.Chip.forJobStatus(r.status));
        }
        resultsBox.appendChild(Utils.el("div", { class: "job-result-row" + (failed ? " is-failed" : "") }, row));
      });
      any = true;
    }
    resultsBox.hidden = !any;

    // Review fix (UX-SPEC.md 2.3): done, zero Failed rows -> transient
    // collapse (see scheduleSuccessCollapse above). A whole-job failure
    // (job.state === "failed", no per-addon results at all) and a
    // done-with-failures run both skip this and stay open, per spec.
    if (!running && job.state === "done" && job.results && job.results.length
      && !job.results.some(function (r) { return r.status === "Failed"; })) {
      scheduleSuccessCollapse(job);
    }

    const body = Utils.qs("#job-panel-body");
    body.scrollTop = body.scrollHeight;
  }

  function toggleCollapse() {
    // Review fix: any toggle (manual click or the auto-collapse call inside
    // scheduleSuccessCollapse) cancels a pending success-auto-hide timer.
    // Without this, a user who clicks the chevron to re-expand a
    // just-auto-collapsed panel would still have it yanked away by hide()
    // a few seconds later, mid-review, with no way to get the results back.
    clearTimeout(successCollapseTimer);
    const panel = Utils.qs("#job-panel");
    const collapsed = panel.classList.toggle("is-collapsed");
    Utils.qs("#job-panel-collapse .icon use").setAttribute("href", collapsed ? "#icon-chevron-right" : "#icon-chevron-down");
    // Low-severity polish fix: keep the collapse button's aria-label/title in
    // sync with its actual effect (was static "Collapse" even once already
    // collapsed, so a screen-reader user always heard "Collapse" even when
    // clicking it would expand).
    const btn = Utils.qs("#job-panel-collapse");
    if (btn) {
      const label = collapsed ? "Expand" : "Collapse";
      btn.setAttribute("aria-label", label);
      btn.setAttribute("title", label);
    }
  }

  // Collapses the panel (if visible and not already collapsed) to just its slim
  // title bar. Called on every view switch so a still-open panel from a previous
  // job (which has no auto-dismiss) can never sit on top of newly-rendered
  // content in the view the user just navigated to - it stays reachable via the
  // collapse chevron instead of silently covering the page.
  function collapseIfOpen() {
    const panel = Utils.qs("#job-panel");
    if (panel.hidden || panel.classList.contains("is-collapsed")) return;
    toggleCollapse();
  }

  function hide() {
    Utils.qs("#job-panel").hidden = true;
    Store.state.jobLabel = null;
  }

  return { show: show, update: update, toggleCollapse: toggleCollapse, collapseIfOpen: collapseIfOpen, hide: hide, summarize: summarize, wholeJobFailureReason: wholeJobFailureReason };
})();

/* ---------- E19 (script itself is E17's, unchanged): curseforge:// handler
   status pill + toggle. Painted twice from the same Store.state.protocol -
   once into Settings > Game's row, once into the Browse > CurseForge pane -
   by two calls to the one render(containerId) function below, so the two
   places can never drift out of sync with each other. ---------- */
// CS4 (UX-SPEC.md 6.2 + copy table): its one remaining home is Settings >
// Advanced, and the label states its own status - "Let CurseForge.com's
// Install buttons open here - On/Off" - with no separate explainer sentence
// underneath. The old chip + always-shown explanatory paragraph (still
// correct for the pre-CS4 Settings > Game placement and the now-removed
// Browse mount) is folded into that one label line; the "handled by another
// program" fact - functionally useful, not generic filler - stays reachable
// as a short parenthetical on the same line rather than a whole sentence of
// its own, per demote-don't-delete (UX-SPEC.md 1.3).
Components.ProtocolControl = (function () {
  function render(containerId) {
    const box = Utils.qs("#" + containerId);
    if (!box) return;
    box.textContent = "";

    const p = Store.state.protocol;
    const busy = Store.state.protocolBusy;
    const loading = Store.state.protocolLoading && !p;
    let label, registered;
    if (loading) {
      label = "Checking whether CurseForge's Install buttons open here…";
      registered = false;
    } else if (!p) {
      label = "Couldn't check CurseForge install-link handling.";
      registered = false;
    } else if (p.registered) {
      label = "Let CurseForge.com's Install buttons open here — On";
      registered = true;
    } else if (p.currentHandler) {
      label = "Let CurseForge.com's Install buttons open here — Off (currently handled by another program)";
      registered = false;
    } else {
      label = "Let CurseForge.com's Install buttons open here — Off";
      registered = false;
    }

    const toggle = Utils.el("input", { type: "checkbox", disabled: busy || loading });
    toggle.checked = registered;
    toggle.addEventListener("change", function () {
      Actions.setProtocolRegistered(toggle.checked);
    });

    box.appendChild(Utils.el("div", { class: "settings-row" }, [
      Utils.el("div", { class: "settings-row-text" }, [
        Utils.el("div", { class: "settings-row-label" }, [label])
      ]),
      // Review fix: dropped the title tooltip - it both re-added an
      // explainer sentence UX-SPEC.md 6.2 says the label alone should carry
      // ("No explainer sentence; the label already says what matters.") and
      // leaked the raw curseforge:// scheme name on hover, which the rest of
      // this pass deliberately keeps off-screen elsewhere.
      Utils.el("label", { class: "switch" }, [
        toggle,
        Utils.el("span", { class: "switch-track" }, [Utils.el("span", { class: "switch-thumb" })])
      ])
    ]));
  }

  return { render: render };
})();

/* ==========================================================================
   describeError - turns an Api error into a short, user-facing message.
   Declared as a plain top-level function (not inside a module) since it is
   used by Components, Actions and Views alike, and function declarations
   are hoisted so definition order here doesn't matter.
   ========================================================================== */
function describeError(err) {
  if (!err) return "unknown error";
  if (err.isNetworkError) return "server not reachable";
  if (err.data && err.data.error) return String(err.data.error);
  if (err.message) return err.message;
  return "unknown error";
}

/* ==========================================================================
   Actions - talks to Api, starts/tracks jobs, and reports outcomes via
   toasts. Used by every view and by Components (dialogs, drawer, menus).
   ========================================================================== */
const Actions = (function () {

  // Posts a job, seeds an optimistic "running" record into Store so the UI
  // reacts instantly, then hands off to App's 800ms job poller. -flavour
  // (FLAVORS-SPEC.md CS-F3) is optional and only ever passed by
  // resumeJobWithFlavour below - every existing caller keeps posting with
  // no flavour, byte-identical to before this change set.
  async function startJob(kind, params, label, flavour) {
    if (Store.isBusy()) { Components.Toast.show("Another task is running.", "warning"); return false; }
    Store.state.jobLabel = label || null;
    try {
      const res = await Api.postJob(kind, params, flavour);
      Store.state.job = { id: res.jobId, kind: kind, params: params || {}, state: "running", startedAt: new Date().toISOString(), finishedAt: null, exitCode: null, log: [], results: [], error: null };
      App.onJobStarted(res.jobId);
      return true;
    } catch (err) {
      if (err.status === 409) Components.Toast.show("Another task is already running.", "warning");
      else Components.Toast.show("Couldn't start the job: " + describeError(err), "error");
      return false;
    }
  }

  // FLAVORS-SPEC.md CS-F3 S5.5 case 5's resume: re-posts the SAME job kind
  // and params an 'awaiting_flavour' job already carries, now with the
  // user's chosen flavour explicit - the server's own resolution
  // (addon-server.ps1 Start-Job) always honors an explicit ?flavour=
  // outright with no re-check, so this always proceeds as a normal case-3
  // "install there silently" job under a fresh job id (there is no
  // "resume this exact job" endpoint - see that function's own comment).
  function resumeJobWithFlavour(job, flavourId) {
    return startJob(job.kind, job.params, "Installing addon", flavourId);
  }

  // FLAVORS-SPEC.md CS-F4 (section 6.1): switches the active flavour pill.
  // The switch itself is immediate and never blocked on the network -
  // persisting the choice (settings.json's activeFlavour, S3.4) is a
  // fire-and-forget PATCH that never blocks it either, and is deliberately
  // non-load-bearing (an error here just means the next reload lands back
  // on whatever flavour the server itself still remembers/defaults to).
  function setActiveFlavour(flavourId) {
    if (!flavourId || Store.state.activeFlavour === flavourId) return;
    Store.state.activeFlavour = flavourId;
    App.renderChrome(); // snaps the active pill immediately, before the refetch below resolves
    Api.putSettings({ activeFlavour: flavourId }).catch(function () { /* S3.4: never load-bearing */ });
    App.reloadState(true); // forces a repaint even if the newly-fetched flavour's data happens to diff-match
  }

  // FLAVORS-SPEC.md CS-F4 (section 6.3/S5.4): the switcher's "Update All"
  // bulk button - fans out into one sync job per installed, non-hidden
  // flavour server-side (Handle-JobsPost's own update-all-flavours kind).
  // Unlike every other job kind, this doesn't map onto a single job id the
  // usual job panel can poll - only the ACTIVE flavour's own resulting job
  // (if any) is attached to that panel, so its progress is still visible;
  // the others just get a summarizing toast.
  async function updateAllFlavours() {
    try {
      const res = await Api.postJob("update-all-flavours", {});
      const jobs = res.jobs || [];
      const started = jobs.filter(function (j) { return j.jobId && !j.error; });
      const busy = jobs.filter(function (j) { return j.busy; });
      const failed = jobs.filter(function (j) { return j.error; });
      const mine = jobs.filter(function (j) { return j.flavour === Store.state.activeFlavour && j.jobId; })[0];
      if (mine) App.attachToJob(mine.jobId);
      let msg = started.length ? ("Updating " + started.length + " flavour" + (started.length === 1 ? "" : "s") + "…") : "Nothing to update.";
      if (busy.length) msg += " (" + busy.length + " already running)";
      if (failed.length) msg += " — " + failed.length + " couldn't start";
      Components.Toast.show(msg, failed.length && !started.length ? "error" : "success");
    } catch (err) {
      Components.Toast.show("Couldn't start updates: " + describeError(err), "error");
    }
  }

  function checkForUpdates() { return startJob("check", {}, "Checking for updates"); }

  // E2: the automatic background check (on load when stale, then every
  // 30 min) - same job as checkForUpdates, but immediately collapses the
  // progress panel back to its slim title bar so an unattended check never
  // pops the full panel open over whatever the user is currently looking at.
  async function autoCheckForUpdates() {
    const started = await startJob("check", {}, "Checking for updates");
    if (started) Components.JobPanel.collapseIfOpen();
    return started;
  }

  // Review fix (post-CS6): scope this job to just the addons that need an
  // update, so the panel title's own count matches the live "Updating i of
  // N addons..." progress line the same job then shows (job.progress.total
  // is however many ids the server actually received) - previously this
  // posted a scope-less sync (every tracked addon) but labeled the panel
  // with only the updates-needed count, so the two numbers could disagree
  // mid-run whenever an already-up-to-date addon was also in the job.
  function updateAll() {
    const ids = Store.state.addons.filter(function (a) { return a.updateAvailable && !a.ignoreUpdates; }).map(Store.addonKey);
    const n = ids.length;
    const label = n > 0 ? ("Updating " + n + " addon" + (n === 1 ? "" : "s")) : "Updating addons";
    return startJob("sync", n > 0 ? { ids: ids } : {}, label);
  }

  function updateNow(projectId) {
    const addon = Store.addonByProjectId(projectId);
    return startJob("sync", { ids: [Utils.normalizeId(projectId)] }, "Updating " + (addon ? addon.name : "addon"));
  }

  function forceReinstallAll() { return startJob("sync", { force: true }, "Force reinstalling all addons"); }

  // Round 4 fix: reverse-dependency check before uninstalling. requiredDeps
  // (E3) names another package's declared dependency by ITS folder name(s),
  // not its display name, so matching has to go through addon.folders -
  // exactly the same data Get-PackageDependencies/Get-MissingDeps already
  // key on server-side. Purely client-side (no new endpoint): every tracked
  // addon's requiredDeps already reaches the UI via /api/state.
  function findDependents(addon) {
    if (!addon) return [];
    const targetFolders = (addon.folders || []).map(function (f) { return String(f).toLowerCase(); });
    if (!targetFolders.length) return [];
    // E12: keyed comparison, not a bare projectId === projectId - two
    // different Wago-sourced addons both have projectId === null, which
    // would otherwise compare equal and wrongly exclude every OTHER Wago
    // addon from this check whenever the target itself is Wago-sourced.
    const targetKey = Store.addonKey(addon);
    return Store.state.addons.filter(function (other) {
      if (Store.addonKey(other) === targetKey) return false;
      const req = other.requiredDeps || [];
      return req.some(function (dep) { return targetFolders.indexOf(String(dep).toLowerCase()) !== -1; });
    });
  }

  async function uninstall(projectId) {
    const addon = Store.addonByProjectId(projectId);
    const name = addon ? addon.name : ("project " + projectId);
    let message = "This removes its folders from AddOns and stops tracking it. This can't be undone from here.";
    const dependents = findDependents(addon);
    if (dependents.length) {
      message += " " + (dependents.length === 1 ? "1 installed addon depends" : dependents.length + " installed addons depend") +
        " on it and may break: " + dependents.map(function (d) { return d.name; }).join(", ") + ".";
    }
    const ok = await Components.Dialogs.confirm({
      title: "Uninstall " + name + "?",
      message: message,
      confirmLabel: "Uninstall"
    });
    if (!ok) return;
    return startJob("remove", { projectId: Utils.normalizeId(projectId) }, "Removing " + name);
  }

  // E11: bulk actions from the My Addons selection bar/checkbox column.

  // "Update selected" - one sync job covering exactly the checked ids
  // (same job kind Update all/Update now already use, just with a bigger
  // ids array), so it goes through the identical progress-panel/results path.
  async function updateSelected() {
    const ids = Store.state.myaddonsSelection.slice();
    if (!ids.length) return;
    const label = "Updating " + ids.length + " addon" + (ids.length === 1 ? "" : "s");
    const started = await startJob("sync", { ids: ids }, label);
    if (started) Store.clearSelection();
    return started;
  }

  // "Uninstall selected" - one remove job covering every checked id
  // (server comma-joins them into a single -Remove invocation), guarded by
  // the same confirm-dialog pattern as the single-addon Uninstall above,
  // listing every name being removed per the roadmap's "confirm listing
  // names" requirement.
  async function uninstallSelected() {
    const selected = Store.selectedAddons();
    if (!selected.length) return;
    const names = selected.map(function (a) { return a.name; });
    const ok = await Components.Dialogs.confirm({
      title: "Uninstall " + selected.length + " addon" + (selected.length === 1 ? "" : "s") + "?",
      message: "This removes their folders from AddOns and stops tracking them. This can't be undone from here. Addons: " + names.join(", ") + ".",
      confirmLabel: "Uninstall"
    });
    if (!ok) return;
    const ids = selected.map(function (a) { return Store.addonKey(a); });
    const label = "Removing " + ids.length + " addon" + (ids.length === 1 ? "" : "s");
    const started = await startJob("remove", { projectIds: ids }, label);
    if (started) Store.clearSelection();
    return started;
  }

  // "Ignore selected" / "Stop ignoring" - a sequence of the same fast
  // POST .../ignore call the single-addon kebab entry (toggleIgnore) already
  // uses, not a job (per the roadmap: "ignore -> sequential ignore calls").
  // Direction: if every checked addon is already ignored, the button reads
  // "Stop ignoring" and this un-ignores all of them; otherwise it ignores
  // all of them (re-ignoring an already-ignored one in a mixed selection is
  // a harmless no-op).
  async function ignoreSelected() {
    const selected = Store.selectedAddons();
    if (!selected.length) return;
    const ignore = !selected.every(function (a) { return a.ignoreUpdates; });
    let failCount = 0;
    for (let i = 0; i < selected.length; i++) {
      try {
        const res = await Api.setIgnore(Store.addonKey(selected[i]), ignore);
        Store.mergeAddons(res.addons);
      } catch (err) {
        failCount++;
      }
    }
    Store.clearSelection();
    App.renderCurrentView();
    const n = selected.length;
    if (failCount) {
      Components.Toast.show("Couldn't update " + failCount + " of " + n + " addon" + (n === 1 ? "" : "s") + ".", "error");
    } else {
      Components.Toast.show((ignore ? "Updates ignored for " : "Updates re-enabled for ") + n + " addon" + (n === 1 ? "" : "s") + ".", "success");
    }
  }

  function installVersion(projectId, fileId, label) {
    const addon = Store.addonByProjectId(projectId);
    return startJob("install", { projectId: Utils.normalizeId(projectId), fileId: fileId }, label || ("Installing " + (addon ? addon.name : "addon")));
  }

  // Round 4 fix: pinning the currently-installed file is a config change, not
  // a reinstall-in-progress, so its job panel title says "Pinning ..." rather
  // than reusing installVersion's default "Installing ..." label.
  function pinCurrent(projectId) {
    const addon = Store.addonByProjectId(projectId);
    if (!addon) return;
    return installVersion(projectId, addon.fileId, "Pinning " + addon.name);
  }

  // E1: reinstalls the addon from its locally archived previous-version zip
  // (server-side, no download) and pins it there. Only ever offered by the
  // kebab menu when addon.previousFileId is set, so no confirm dialog here -
  // it mirrors "Pin current version" (a same-risk, instantly reversible
  // config+reinstall action) rather than the destructive Uninstall path.
  function rollback(projectId) {
    const addon = Store.addonByProjectId(projectId);
    const target = addon && addon.previousVersion ? (" to " + addon.previousVersion) : "";
    return startJob("rollback", { projectId: Utils.normalizeId(projectId) }, "Rolling back " + (addon ? addon.name : "addon") + target);
  }

  function installLatest(projectId, name) { return startJob("add", { projectId: Utils.normalizeId(projectId) }, "Installing " + (name || "addon")); }
  function addWithVersion(projectId, fileId) { return startJob("add", { projectId: Utils.normalizeId(projectId), fileId: fileId }, "Installing addon"); }
  function addByProjectId(projectId) { return startJob("add", { projectId: Utils.normalizeId(projectId) }, "Adding addon"); }

  // E12 (Wago second source): a brand-new Wago add has no existing record
  // yet to derive a "wago:<slug>" key from, so these post {source:'wago',
  // slug, fileId?} instead of a projectId, per SPEC's documented job body -
  // the server normalizes it to that same key before it ever reaches
  // Build-CliArgs (see addon-server.ps1 Start-Job).
  function installLatestWago(slug, name) { return startJob("add", { source: "wago", slug: slug }, "Installing " + (name || "addon")); }
  function addWagoWithVersion(slug, releaseId) { return startJob("add", { source: "wago", slug: slug, fileId: releaseId }, "Installing addon"); }
  function addByWagoSlug(slug) { return startJob("add", { source: "wago", slug: slug }, "Adding addon"); }

  // E18: the first-run Welcome dialog's "Take over all" - one job installing
  // every already-fully-formed target token (a bare numeric CurseForge id,
  // or "wago:<id>") at once, mirroring what install.ps1 itself does via the
  // CLI directly. See Build-CliArgs's 'add' case (addon-server.ps1) for the
  // server-side projectIds handling this relies on.
  // CS5 (UX-SPEC.md 6.2/7): "Adopt"/"Adopting" -> "Take over"/"Taking over"
  // in this display label too - the only other surviving caller besides
  // Views.settings' untrackedRow (renamed by CS4).
  function adoptAll(targets) {
    Components.Dialogs.closeWelcome();
    const label = "Taking over " + targets.length + " addon" + (targets.length === 1 ? "" : "s");
    return startJob("add", { projectIds: targets }, label);
  }

  function openOnWago(slug) { return openWhat("url", { url: "https://addons.wago.io/addons/" + encodeURIComponent(slug) }); }

  // E12: "Also on CurseForge/Wago" cross-link, shown in the drawer header
  // when the tracked record's OWN toc revealed the other source's id -
  // uninstalls the current package and re-adds it fresh from that other
  // source, as one job (kind 'switch-source'). toTarget is a numeric
  // CurseForge project id (switching TO CurseForge) or a Wago slug/id
  // string (switching TO Wago, matching -Add's own wago: token contract -
  // no "wago:" prefix here, the server adds it).
  function switchSource(addon, toSource, toTarget) {
    const label = "Reinstalling " + addon.name + " from " + (toSource === "wago" ? "Wago" : "CurseForge");
    return startJob("switch-source", { projectId: Store.addonKey(addon), toSource: toSource, toTarget: toTarget }, label);
  }
  function switchSourceButton(addon, toSource, toTarget) {
    const label = "Also on " + (toSource === "wago" ? "Wago" : "CurseForge");
    return Utils.el("button", {
      type: "button", class: "link-btn", disabled: Store.jobActingOn(Store.addonKey(addon)),
      onclick: function () { switchSource(addon, toSource, toTarget); }
    }, [label + " — reinstall from there"]);
  }

  // E5: a job result row's "What changed" control. Wago's changelog needs no
  // key and supports jumping straight to the release that was just
  // installed. CurseForge's per-file changelog was key-gated and was
  // removed along with the key feature (Round 16, E22) - falls back to
  // Versions, which already tags the installed/pinned file without any
  // CurseForge call.
  function whatChanged(projectId, fileId) {
    const isWago = typeof projectId === "string" && projectId.toLowerCase().indexOf("wago:") === 0;
    if (isWago) Components.Drawer.open(projectId, { tab: "changelog", changelogFileId: fileId });
    else Components.Drawer.open(projectId, { tab: "versions" });
  }

  function updateAndPlay() { return startJob("launch", { updateFirst: true }, "Updating & launching World of Warcraft"); }
  function launchOnly() { return startJob("launch", { updateFirst: false }, "Launching World of Warcraft"); }

  async function toggleIgnore(projectId, ignore) {
    try {
      const res = await Api.setIgnore(projectId, ignore);
      Store.mergeAddons(res.addons);
      App.renderCurrentView();
      Components.Toast.show(ignore ? "Updates ignored for this addon." : "Updates re-enabled for this addon.", "success");
    } catch (err) {
      Components.Toast.show("Couldn't update the addon: " + describeError(err), "error");
    }
  }

  async function unpin(projectId) {
    try {
      const res = await Api.unpin(projectId);
      Store.mergeAddons(res.addons);
      App.renderCurrentView();
      Components.Toast.show("Unpinned — it will follow the newest allowed release again.", "success");
    } catch (err) {
      Components.Toast.show("Couldn't unpin: " + describeError(err), "error");
    }
  }

  async function deleteUntracked(folder) {
    const ok = await Components.Dialogs.confirm({
      title: "Delete “" + folder + "”?",
      message: "This permanently deletes the AddOns\\" + folder + " folder. This can't be undone.",
      confirmLabel: "Delete"
    });
    if (!ok) return;
    try {
      await Api.scanDelete(folder);
      Components.Toast.show("Deleted " + folder + ".", "success");
      await Views.settings.rescan();
    } catch (err) {
      Components.Toast.show("Couldn't delete the folder: " + describeError(err), "error");
    }
  }

  // CS4 (UX-SPEC.md 6.2/§7): "Adopt"/"Adopting" -> "Take over"/"Taking
  // over" in the job-panel title this label feeds - these two functions are
  // called only from Views.settings' "Folders Furphy doesn't manage yet"
  // row actions (grepped, no other caller), so this rename is fully scoped
  // to that one section; Components.Welcome's own separate "Adopt all"
  // first-run flow (Actions.adoptAll, untouched here) is CS5's own copy-
  // sweep territory per UX-SPEC.md section 10.
  // FLAVORS-SPEC.md CS-F4: -Scan (and so this folder) is already scoped to
  // whichever flavour is currently active (S5.1) - naming that flavour
  // explicitly here skips CS-F3's own CurseForge ambiguity picker, which
  // would otherwise ask a question this call site already knows the answer
  // to. Only passed once Store.hasMultipleFlavours() - undefined at n<=1,
  // so the URL stays byte-identical there (Api.postJob's own qs() drops an
  // undefined value).
  function adoptFlavour() { return Store.hasMultipleFlavours() ? Store.state.activeFlavour : undefined; }
  function adopt(folder, projectId) { return startJob("add", { projectId: Number(projectId) }, "Taking over " + folder, adoptFlavour()); }
  // E12: one-click adoption from the Wago id/slug -Scan found in the
  // folder's own .toc (## X-Wago-ID) - same shape as installLatestWago,
  // just with a "Taking over..." label to match `adopt`'s.
  function adoptWago(folder, wagoRef) { return startJob("add", { source: "wago", slug: wagoRef }, "Taking over " + folder, adoptFlavour()); }

  // Round 5 fix: each individual Settings control (a release-channel radio,
  // the auto-update toggle) calls saveSettings independently, so flipping
  // two or three of them in quick succession used to stack that many
  // identical "Settings saved." toasts on screen at once. Coalesces rapid
  // successive successful saves into a single toast, fired a moment after
  // the last one settles rather than after every individual call.
  let saveToastTimer = null;
  // Round 6 fix: optional `toastMessage` overrides the generic "Settings
  // saved." for callers with something more specific to say; existing
  // callers that pass nothing are unaffected.
  async function saveSettings(patch, toastMessage) {
    try {
      const res = await Api.putSettings(patch);
      Store.state.settings = res;
      App.renderChrome();
      if (Store.state.view === "settings") Views.settings.render();
      if (Store.state.view === "browse") Views.browse.render();
      clearTimeout(saveToastTimer);
      saveToastTimer = setTimeout(function () { Components.Toast.show(toastMessage || "Settings saved.", "success"); }, 300);
      return res;
    } catch (err) {
      Components.Toast.show("Couldn't save settings: " + describeError(err), "error");
      throw err;
    }
  }

  async function openWhat(what, extra) {
    try { await Api.openWhat(what, extra); }
    catch (err) { Components.Toast.show("Couldn't open that: " + describeError(err), "error"); }
  }

  // Round 15 (design D): switches Get new addons to the CurseForge segment
  // and navigates the pane, in the native host with the cf-pane capability;
  // everywhere else (a plain Edge-window install, or an older host without
  // that capability), falls through to the existing 'cf-window'/'curseforge'
  // /api/open targets (a chromeless side window) unchanged - the old
  // Host.openCurseForge (E19b's embedded-CurseForge-tab message) is no
  // longer sent by the SPA at all (SPEC.md E21: the host still accepts it
  // for compatibility, but this app doesn't need it once cf-show/cf-nav
  // exist).
  function switchToCfPane(url, navigate) {
    App.switchView("browse");
    // navigateCf both switches the segment (if not already there) and
    // navigates in one go - calling setTab first would show the pane at
    // its home/last-state URL, then navigateCf would immediately have to
    // send a second cf-nav to correct it.
    Views.browse.navigateCf(url, navigate);
  }

  // E12/round 9's project-page URL shape, built client-side - what the
  // server's own 'curseforge' /api/open target also builds from
  // {projectId, slug}, kept here so this can decide whether to route into
  // the CurseForge pane before ever reaching the server.
  function openOnCurseForge(projectId, slug) {
    const id = Utils.normalizeId(projectId);
    const url = slug
      ? "https://www.curseforge.com/wow/addons/" + encodeURIComponent(slug)
      : "https://www.curseforge.com/projects/" + encodeURIComponent(String(id));
    if (Host.hasCfPane()) { switchToCfPane(url, true); return; }
    return openWhat("curseforge", { projectId: id, slug: slug || undefined });
  }

  // The Wago panel's "Not on Wago? Try CurseForge" fallback link (UX-SPEC.md
  // section 5, rewritten round 15): switches segments in the native host;
  // everywhere else, opens the existing chromeless side window directly
  // (the 'cf-window' target) rather than switching to a CurseForge segment
  // that would only show its own "browsing happens in the desktop window"
  // fallback panel.
  function searchCurseForgeWebsite(term) {
    const q = (term || "").trim();
    const url = q
      ? "https://www.curseforge.com/wow/search?search=" + encodeURIComponent(q) + "&class=addons"
      : "https://www.curseforge.com/wow/addons";
    if (Host.hasCfPane()) { switchToCfPane(url, true); return; }
    return Views.browse.openCfWindowFallback(url);
  }

  // E3: "Search CurseForge" on a missing dependency, from the drawer's
  // Overview tab - switches to Get new addons' Wago search (unchanged
  // plumbing; the query is pre-filled the same way it always was, just
  // against Wago only now rather than the old merged CurseForge+Wago grid).
  function searchDependency(name) {
    Store.state.browse.query = name;
    const alreadyLoaded = Store.state.browse.wago.loaded;
    App.switchView("browse");
    Views.browse.setTab("wago");
    const input = Utils.qs("#browse-search");
    if (input) input.value = name;
    if (alreadyLoaded) Views.browse.search(true);
  }

  // Validates+resolves the Add-addon dialog's free-text input, then starts the add job.
  async function submitAddInput(raw) {
    const value = (raw || "").trim();
    const errorBox = Utils.qs("#add-addon-error");
    function fail(msg) { errorBox.textContent = msg; errorBox.hidden = false; errorBox.className = "form-msg is-error"; }

    if (!value) { fail("Paste a wago.io addon link, or type a CurseForge ID number."); return; }

    if (/^\d+$/.test(value)) {
      Components.Dialogs.closeAdd();
      await addByProjectId(Number(value));
      return;
    }

    // E12: a "wago:<slug-or-id>" token or a full wago URL needs no server
    // round-trip to resolve - a Wago addon's identity already IS its
    // slug/id.
    const wagoMatch = value.match(/^wago:(.+)$/i) || value.match(/^https?:\/\/addons\.wago\.io\/addons\/([a-z0-9-]+)/i);
    if (wagoMatch) {
      const ref = wagoMatch[1].trim();
      if (!ref) { fail("That doesn't look like a valid Wago reference."); return; }
      Components.Dialogs.closeAdd();
      await addByWagoSlug(ref);
      return;
    }

    // Round 16 (E22, CurseForge key removal): resolving a curseforge.com
    // page URL to its project id was always a key-gated CurseForge Core API
    // call (/api/cf/resolve, now deleted along with the key feature) - a
    // CurseForge addon can still be added by its numeric ID (shown on its
    // CurseForge page) or, better, by clicking Install on that page inside
    // Furphy's own CurseForge pane. Review fix (F1): name what the player
    // just did when it's actually a CurseForge link (the dialog's own
    // permanent hint above now says where the ID number lives, so this
    // doesn't repeat that) - anything else unrecognized keeps the original,
    // more general message.
    if (/curseforge\.com/i.test(value)) {
      fail("That looks like a CurseForge page link - type its ID number instead.");
      return;
    }
    fail("Type a numeric CurseForge ID, or paste a wago.io addon link.");
  }

  // E4: posts an imported addons-export.json body to /api/import (job kind
  // "import"), started/tracked the same way startJob() does for every other
  // kind - just via Api.importAddons (a bare POST of `payload` itself, not
  // Api.postJob's {kind, ...} wrapper), since /api/import's body IS the
  // export shape, not a {kind} envelope. Views.settings shows the
  // added/already-present preview and gets user confirmation before this
  // is ever called.
  async function importAddons(payload) {
    if (Store.isBusy()) { Components.Toast.show("Another task is running.", "warning"); return false; }
    Store.state.jobLabel = "Loading addon list";
    try {
      const res = await Api.importAddons(payload);
      Store.state.job = { id: res.jobId, kind: "import", params: payload, state: "running", startedAt: new Date().toISOString(), finishedAt: null, exitCode: null, log: [], results: [], error: null };
      App.onJobStarted(res.jobId);
      return true;
    } catch (err) {
      if (err.status === 409) Components.Toast.show("Another task is already running.", "warning");
      else Components.Toast.show("Couldn't start the import: " + describeError(err), "error");
      return false;
    }
  }

  // E19 (script itself is E17's, unchanged): shared by Settings > Game's row
  // and the Browse > CurseForge pane's status pill - fetches
  // GET /api/protocol/status once and repaints whichever of those two views
  // is currently on screen (a no-op render call on the other is harmless -
  // both Views.settings.render/Views.browse.render just repaint whatever
  // DOM is present, matching the pattern App.renderChrome already uses
  // elsewhere in this file). A failed fetch leaves Store.state.protocol
  // null - both call sites render that as "Checking..." rather than an
  // error, since this is a nicety, never something worth an error toast for
  // on its own.
  async function loadProtocolStatus() {
    Store.state.protocolLoading = true;
    if (Store.state.view === "settings") Views.settings.render();
    if (Store.state.view === "browse") Views.browse.render();
    try {
      Store.state.protocol = await Api.protocolStatus();
    } catch (err) {
      Store.state.protocol = null;
    } finally {
      Store.state.protocolLoading = false;
      if (Store.state.view === "settings") Views.settings.render();
      if (Store.state.view === "browse") Views.browse.render();
    }
  }

  // Flips the curseforge:// handler toggle. `isUndo` suppresses the
  // "Undo" toast on the undo action itself (so clicking Undo can't chain
  // into another Undo offer) - every normal caller omits it.
  async function setProtocolRegistered(wantRegistered, isUndo) {
    if (Store.state.protocolBusy) return;
    Store.state.protocolBusy = true;
    if (Store.state.view === "settings") Views.settings.render();
    if (Store.state.view === "browse") Views.browse.render();
    try {
      const status = wantRegistered ? await Api.protocolRegister() : await Api.protocolUnregister();
      Store.state.protocol = status;
      if (!isUndo) {
        Components.Toast.show(
          wantRegistered ? "CurseForge install links are now handled by Furphy." : "Furphy no longer handles CurseForge install links.",
          "success",
          { actionLabel: "Undo", onAction: function () { setProtocolRegistered(!wantRegistered, true); } }
        );
      }
    } catch (err) {
      Components.Toast.show("Couldn't change the install-link handler: " + describeError(err), "error");
    } finally {
      Store.state.protocolBusy = false;
      if (Store.state.view === "settings") Views.settings.render();
      if (Store.state.view === "browse") Views.browse.render();
    }
  }

  // Round 18 (tray stage B): re-fetches /api/tray/status into
  // Store.state.trayStatus and repaints the status line if Settings is the
  // active view. Called after every tray-affecting action here, and once on
  // entering Settings (App.switchView) - the normal state poll
  // (App.reloadState) also calls this on its own cadence while Settings
  // stays open, so the line never goes stale without needing its own timer.
  async function refreshTrayStatus() {
    try {
      Store.state.trayStatus = await Api.getTrayStatus();
    } catch (err) {
      Store.state.trayStatus = null;
    }
    if (Store.state.view === "settings") Views.settings.render();
  }

  // Saves backgroundUpdates, then starts or stops the tray process to match -
  // one settings save (saveSettings' own "Settings saved." toast covers it),
  // no separate toast for the start/stop call itself.
  async function setBackgroundUpdates(enabled) {
    try {
      await saveSettings({ backgroundUpdates: enabled });
      if (enabled) await Api.startTray(); else await Api.stopTray();
    } catch (err) {
      Components.Toast.show("Couldn't change background updates: " + describeError(err), "error");
    } finally {
      await refreshTrayStatus();
    }
  }

  // Registers/unregisters the "Start with Windows" Run value. Turning it ON
  // while background updates is currently off also turns background updates
  // on - a single settings PUT (one save, one toast) rather than two, since
  // a --tray process with nothing to do would just exit within a minute of
  // every logon otherwise (task brief: "one action, plainly labelled").
  async function setRunAtStartup(enabled) {
    try {
      const patch = { runAtStartup: enabled };
      const alsoStartBackground = enabled && !Store.state.settings.backgroundUpdates;
      if (alsoStartBackground) patch.backgroundUpdates = true;
      await saveSettings(patch);
      if (enabled) {
        await Api.registerStartup();
        if (alsoStartBackground) await Api.startTray();
      } else {
        await Api.unregisterStartup();
      }
    } catch (err) {
      Components.Toast.show("Couldn't change Start with Windows: " + describeError(err), "error");
    } finally {
      await refreshTrayStatus();
    }
  }

  return {
    startJob: startJob, resumeJobWithFlavour: resumeJobWithFlavour, setActiveFlavour: setActiveFlavour, updateAllFlavours: updateAllFlavours, checkForUpdates: checkForUpdates, autoCheckForUpdates: autoCheckForUpdates, updateAll: updateAll, updateNow: updateNow,
    forceReinstallAll: forceReinstallAll, uninstall: uninstall, installVersion: installVersion, pinCurrent: pinCurrent, rollback: rollback,
    installLatest: installLatest, addWithVersion: addWithVersion, addByProjectId: addByProjectId,
    updateAndPlay: updateAndPlay, launchOnly: launchOnly, toggleIgnore: toggleIgnore, unpin: unpin,
    deleteUntracked: deleteUntracked, adopt: adopt, adoptWago: adoptWago, saveSettings: saveSettings,
    openWhat: openWhat, openOnCurseForge: openOnCurseForge, searchDependency: searchDependency, searchCurseForgeWebsite: searchCurseForgeWebsite, submitAddInput: submitAddInput,
    whatChanged: whatChanged, importAddons: importAddons,
    updateSelected: updateSelected, uninstallSelected: uninstallSelected, ignoreSelected: ignoreSelected,
    // E12 (Wago second source)
    installLatestWago: installLatestWago, addWagoWithVersion: addWagoWithVersion, addByWagoSlug: addByWagoSlug,
    openOnWago: openOnWago, switchSource: switchSource, switchSourceButton: switchSourceButton,
    // E18 (first-run welcome)
    adoptAll: adoptAll,
    // E19 (curseforge:// handler toggle; ad filter goes through saveSettings above)
    loadProtocolStatus: loadProtocolStatus, setProtocolRegistered: setProtocolRegistered,
    // Round 18 (tray stage B)
    setBackgroundUpdates: setBackgroundUpdates, setRunAtStartup: setRunAtStartup, refreshTrayStatus: refreshTrayStatus
  };
})();

/* ==========================================================================
   Views - one sub-module per screen. Each exposes render() (paint from
   current Store state) and bindOnce() (wire static DOM once at startup).
   ========================================================================== */
const Views = {};

/* ---------- My Addons ---------- */
Views.myAddons = (function () {
  // CS2 (UX-SPEC.md section 3.4): only All/Updates are permanent chips now.
  // Every other status is demoted into a single "More" popover, shown only
  // once at least one of them has a count > 0 (see renderFilters below).
  const FILTER_DEFS = [
    { key: "all", label: "All" },
    { key: "updates", label: "Updates" }
  ];
  // E7 (kept, demoted): "missingdeps" reads addon.missingDeps - populated by
  // /api/state since the E3 dependency expansion landed (requiredDeps not
  // present as a folder in AddOns, computed live server-side). Labels match
  // the Status pill vocabulary's own wording (UX-SPEC.md section 3.2/§7
  // copy table) rather than the old raw filter names.
  // CS5 fix (UX-SPEC.md 3.4 + §7 copy table row "Filter chip | 'Stale N' |
  // DELETE as a separate chip"): this list previously also carried a fifth
  // "stale" entry ("Old patch / won't work") CS2 added on its own - section
  // 3.4's own extras list names exactly four (Pinned, Ignored, "Couldn't
  // update", "Needs another addon"), and the copy table is explicit that a
  // patch-staleness filter chip is deleted outright, folded only into the
  // Status pill (§3.2), never kept as its own filter. Removed here, along
  // with its only caller (isStale()) and matchesFilter's "stale" branch.
  const EXTRA_FILTER_DEFS = [
    { key: "failed", label: "Couldn't update" },
    { key: "missingdeps", label: "Needs another addon" },
    { key: "pinned", label: "Pinned" },
    { key: "ignored", label: "Ignoring updates" }
  ];
  const ALL_FILTER_DEFS = FILTER_DEFS.concat(EXTRA_FILTER_DEFS);

  function addonMissingDeps(a) { return (a && a.missingDeps) || []; }

  function matchesFilter(a, filter) {
    if (filter === "updates") return !!a.updateAvailable;
    if (filter === "pinned") return a.pinnedFileId !== null && a.pinnedFileId !== undefined;
    if (filter === "ignored") return !!a.ignoreUpdates;
    if (filter === "failed") return Store.lastRunStatusFor(a) === "Failed";
    if (filter === "missingdeps") return addonMissingDeps(a).length > 0;
    return true; // "all"
  }

  function filterCounts() {
    const all = Store.state.addons;
    const counts = {};
    ALL_FILTER_DEFS.forEach(function (def) { counts[def.key] = all.filter(function (a) { return matchesFilter(a, def.key); }).length; });
    return counts;
  }

  // CS2 (UX-SPEC.md section 3.4): All/Updates always shown; every other
  // status only appears (grouped under one "More" popover) once its count
  // is > 0 - "a clean install shows just All 6". When the active filter is
  // one of those extras, the trigger chip itself takes on that filter's
  // label/count so the current selection stays visible without the popover
  // open, per the "not just clearer, but honest about the app's own current
  // state" spirit that already runs through the rest of this spec.
  function renderFilters() {
    const box = Utils.qs("#myaddons-filters");
    const counts = filterCounts();
    // Safety: if the active filter is an extra whose count has since
    // dropped to 0 (its last matching addon just got fixed/removed), fall
    // back to "all" rather than leaving the table silently filtered to zero
    // rows with no visible chip explaining why.
    const active = Store.state.myaddonsFilter;
    if (active !== "all" && active !== "updates" && !counts[active]) Store.state.myaddonsFilter = "all";
    box.textContent = "";
    const activeNow = Store.state.myaddonsFilter;
    FILTER_DEFS.forEach(function (def) {
      const isActive = activeNow === def.key;
      box.appendChild(Utils.el("button", {
        type: "button",
        class: "filter-chip" + (isActive ? " is-active" : ""),
        "aria-pressed": isActive ? "true" : "false",
        title: "Show " + def.label.toLowerCase() + " (" + counts[def.key] + ")",
        onclick: function () { Store.state.myaddonsFilter = def.key; render(); }
      }, [def.label, Utils.el("span", { class: "filter-chip-count" }, [String(counts[def.key])])]));
    });
    const extras = EXTRA_FILTER_DEFS.filter(function (def) { return counts[def.key] > 0; });
    if (!extras.length) return;
    const activeExtra = extras.find(function (def) { return def.key === activeNow; });
    box.appendChild(Utils.el("button", {
      type: "button",
      class: "filter-chip filter-chip-more" + (activeExtra ? " is-active" : ""),
      "aria-haspopup": "true",
      "aria-expanded": "false",
      title: "More filters",
      onclick: function (ev) {
        Components.Dropdown.open(ev.currentTarget, extras.map(function (def) {
          return { label: def.label + " (" + counts[def.key] + ")", onSelect: function () { Store.state.myaddonsFilter = def.key; render(); } };
        }));
      }
    }, [activeExtra ? activeExtra.label : "⋯ More", Utils.el("span", { class: "filter-chip-count" }, [String(activeExtra ? counts[activeExtra.key] : extras.length)])]));
  }

  function statusRank(a) {
    if (Store.jobActingOn(Store.addonKey(a))) return 0;
    if (Store.lastRunStatusFor(a) === "Failed") return 1;
    if (a.updateAvailable) return 2;
    if (a.pinnedFileId !== null && a.pinnedFileId !== undefined) return 3;
    if (a.ignoreUpdates) return 4;
    return 5;
  }

  // Round 4 fix: WoW addon titles commonly carry bracket/symbol decoration
  // ("<Camera> Max Distance", "[Bracket] AddonName") that sorts ahead of
  // plain alphabetic names under a plain (or even ignorePunctuation) locale
  // compare - Unicode collation still weighs a leading "<"/"[" before a
  // letter, so "<Camera>..." lands ahead of "BonusRollConfirm" even though a
  // user scanning an alphabetical list expects it among the C's. Stripping
  // leading non-alphanumeric characters before comparing matches that
  // expectation; an all-symbol name falls back to comparing the raw string.
  function sortableName(name) {
    const n = name || "";
    const stripped = n.replace(/^[^a-z0-9]+/i, "");
    return stripped || n;
  }

  function compareNames(a, b) {
    return sortableName(a).localeCompare(sortableName(b), undefined, { numeric: true, sensitivity: "base" });
  }

  // Round 5 fix: the Installed/Latest columns compared version strings with
  // a plain localeCompare, which sorts lexically, not numerically - "v10.0"
  // landed ahead of "v2.0". Splits each string into dot-separated segments
  // (a leading "v" stripped first), compares segment-by-segment as numbers,
  // and falls back to a plain string compare for any segment that isn't
  // purely numeric (release tags, "1.0.0-beta", etc.).
  function compareVersionStrings(a, b) {
    const pa = String(a || "").replace(/^v/i, "").split(".");
    const pb = String(b || "").replace(/^v/i, "").split(".");
    const len = Math.max(pa.length, pb.length);
    for (let i = 0; i < len; i++) {
      const sa = pa[i], sb = pb[i];
      if (sa === undefined) return sb === undefined ? 0 : -1;
      if (sb === undefined) return 1;
      const na = Number(sa), nb = Number(sb);
      if (!isNaN(na) && !isNaN(nb)) {
        if (na !== nb) return na - nb;
      } else if (sa !== sb) {
        return sa < sb ? -1 : 1;
      }
    }
    return 0;
  }

  // One comparator per sortable column (Addon/Version/Status headers); the
  // click handler in bindOnce() flips `dir` to invert whichever one this
  // returns. CS2: "installed"/"latest" merged into one "version" column -
  // sorts by the installed version (what's actually on disk), same as the
  // old "installed" column did; a row with an update available still shows
  // both in its cell (see row() below), just no longer as a separate sort.
  function compareValues(a, b, column) {
    if (column === "version") return compareVersionStrings(a.version, b.version);
    if (column === "status") return statusRank(a) - statusRank(b) || compareNames(a.name, b.name);
    return compareNames(a.name, b.name); // "name"
  }

  function renderSortIndicators() {
    const sort = Store.state.myaddonsSort;
    Utils.qsa(".th-sort-btn").forEach(function (btn) {
      const col = btn.dataset.sortCol;
      const th = btn.closest("th");
      const indicator = btn.querySelector(".sort-indicator");
      const isActive = col === sort.column;
      th.setAttribute("aria-sort", isActive ? (sort.dir === "asc" ? "ascending" : "descending") : "none");
      indicator.textContent = isActive ? (sort.dir === "asc" ? "▲" : "▼") : "";
      btn.classList.toggle("is-active-sort", isActive);
    });
  }

  function filteredSorted() {
    const q = Store.state.myaddonsSearch.trim().toLowerCase();
    let list = Store.state.addons.slice();
    if (q) {
      list = list.filter(function (a) {
        const folders = (a.folders || []).join(" ").toLowerCase();
        return a.name.toLowerCase().indexOf(q) !== -1 || (a.author || "").toLowerCase().indexOf(q) !== -1 || folders.indexOf(q) !== -1;
      });
    }
    const filter = Store.state.myaddonsFilter;
    if (filter && filter !== "all") list = list.filter(function (a) { return matchesFilter(a, filter); });

    const sort = Store.state.myaddonsSort;
    list.sort(function (a, b) {
      const cmp = compareValues(a, b, sort.column);
      return sort.dir === "desc" ? -cmp : cmp;
    });
    return list;
  }

  // E11: hides the selection bar and, when a list is given, syncs the header
  // "select all" checkbox's checked/indeterminate state to it. Called with no
  // argument from every early-return branch below where the table itself is
  // hidden (loading/error/no-addons-at-all/filtered-to-zero) - the bar has
  // nothing to attach to in those states, mirroring how .filter-chips is
  // hidden in the same branches.
  function renderSelectionBar(list) {
    const bar = Utils.qs("#myaddons-selection-bar");
    const selectAll = Utils.qs("#myaddons-select-all");
    if (!list) {
      bar.hidden = true;
      if (selectAll) { selectAll.checked = false; selectAll.indeterminate = false; }
      return;
    }
    const selectedCount = list.filter(function (a) { return Store.isSelected(Store.addonKey(a)); }).length;
    if (selectAll) {
      selectAll.checked = list.length > 0 && selectedCount === list.length;
      selectAll.indeterminate = selectedCount > 0 && selectedCount < list.length;
    }
    const selected = Store.selectedAddons();
    if (!selected.length) { bar.hidden = true; return; }
    bar.hidden = false;
    Utils.qs("#myaddons-selection-count").textContent = selected.length + " selected";
    Utils.qs("#myaddons-bulk-ignore").textContent = selected.every(function (a) { return a.ignoreUpdates; }) ? "Stop ignoring" : "Ignore selected";
  }

  function render() {
    // E11: drop any selected id that no longer names a tracked addon before
    // anything below reads the selection (e.g. a job started elsewhere just
    // removed it) - keeps the selection-bar count and every bulk action
    // honest even when the row that changed wasn't part of this selection.
    Store.pruneSelection();
    // CS2 (UX-SPEC.md sections 1.1/2.2): the one freshness headline, mounted
    // here (and in the sidebar - see App.renderChrome) - replaces the old
    // summary sentence AND the separate "Last run" line, both deleted below.
    Components.Freshness.render("myaddons-freshness");

    const table = Utils.qs("#myaddons-table");
    const tbody = Utils.qs("#myaddons-tbody");
    const skeleton = Utils.qs("#myaddons-skeleton");
    const empty = Utils.qs("#myaddons-empty");
    const emptyFiltered = Utils.qs("#myaddons-empty-filtered");
    const errorBox = Utils.qs("#myaddons-error");
    const summary = Utils.qs("#myaddons-summary");
    const filters = Utils.qs("#myaddons-filters");

    if (Store.state.loadingState) {
      table.hidden = true; empty.hidden = true; emptyFiltered.hidden = true; errorBox.hidden = true; skeleton.hidden = false; filters.hidden = true;
      renderSelectionBar(null);
      summary.textContent = "";
      return;
    }
    skeleton.hidden = true;

    if (Store.state.stateError) {
      table.hidden = true; empty.hidden = true; emptyFiltered.hidden = true; summary.textContent = ""; filters.hidden = true;
      renderSelectionBar(null);
      errorBox.hidden = false;
      Utils.qs("#myaddons-error-msg").textContent = describeError(Store.state.stateError);
      return;
    }
    errorBox.hidden = true;

    if (!Store.state.addons.length) {
      table.hidden = true; empty.hidden = false; emptyFiltered.hidden = true; summary.textContent = ""; filters.hidden = true;
      renderSelectionBar(null);
      return;
    }
    empty.hidden = true;

    filters.hidden = false;
    renderFilters();

    const list = filteredSorted();

    // Round 4 fix: a status chip or search narrowing the list to zero rows
    // used to leave a bare table (just the column headers) with nothing
    // explaining why - distinct from the "no addons tracked at all" state
    // above, which never applies once at least one addon exists.
    if (!list.length) {
      table.hidden = true;
      tbody.textContent = "";
      emptyFiltered.hidden = false;
      renderSelectionBar(null);
      const total = Store.state.addons.length;
      summary.textContent = "0 of " + total + (total === 1 ? " addon" : " addons");
      return;
    }
    emptyFiltered.hidden = true;

    table.hidden = false;
    tbody.textContent = "";
    list.forEach(function (a) { tbody.appendChild(row(a)); });
    renderSortIndicators();
    renderSelectionBar(list);

    // CS2 (UX-SPEC.md section 1.1 / word budget, §7 copy table): the old
    // multi-clause sentence ("6 addons · 3 updates available · checked 5 min
    // ago · Client ... · 1 addon needs attention") is deleted outright - every
    // one of those facts now lives exactly once elsewhere (the freshness
    // headline above, the nav's own addon count, the Status pill per row,
    // client build in Settings > About). The only thing still worth a line
    // here is "N of M shown", and only while a search/filter narrows the list.
    const total = Store.state.addons.length;
    summary.textContent = list.length !== total ? (list.length + " of " + total + (total === 1 ? " addon" : " addons") + " shown") : "";
  }

  // E12: a tiny source badge (CF/Wago) next to each row's name, so a mixed
  // tracked list stays legible about where each addon actually comes from.
  function sourceBadge(a) {
    const isWago = a.source === "wago";
    return Utils.el("span", { class: "source-badge " + (isWago ? "is-wago" : "is-cf"), title: isWago ? "Wago Addons" : "CurseForge" }, [isWago ? "Wago" : "CF"]);
  }

  // CS2 (UX-SPEC.md section 3.1): the merged Version cell - "installed ->
  // latest" when an update exists, just the installed version when current.
  // Purely informational (what version); the Status pill next to it is the
  // actionable one (what to do about it).
  function versionCell(a) {
    const text = a.updateAvailable ? (a.version + " → " + a.updateAvailable.version) : (a.version || "-");
    return Utils.el("span", { class: "version-text" }, [text]);
  }

  function row(a) {
    const key = Store.addonKey(a);
    const logo = Components.Logo.build({ projectId: a.projectId, name: a.name }, 40);
    const tr = Utils.el("tr", { class: "addon-row" }, [
      Utils.el("td", { class: "checkbox-cell" }, [
        Utils.el("input", {
          type: "checkbox", class: "chk", checked: Store.isSelected(key), "aria-label": "Select " + a.name,
          onchange: function () { Store.toggleSelected(key); render(); }
        })
      ]),
      Utils.el("td", {}, [Utils.el("div", { class: "addon-identity" }, [
        logo,
        Utils.el("div", { class: "addon-names" }, [
          Utils.el("div", { class: "addon-name" }, [Utils.el("span", { class: "addon-name-text" }, [a.name]), sourceBadge(a)]),
          Utils.el("div", { class: "addon-author" }, [a.author || "Unknown author"])
        ])
      ])]),
      Utils.el("td", {}, [versionCell(a)]),
      Utils.el("td", {}, [Components.Chip.forStatus(a)]),
      Utils.el("td", {}, [kebab(a)])
    ]);
    tr.addEventListener("click", function (ev) {
      if (ev.target.closest(".menu-wrap") || ev.target.closest(".checkbox-cell") || ev.target.closest(".chip-action")) return;
      Components.Drawer.open(key, { tab: "overview", source: a.source });
    });
    return tr;
  }

  function kebab(a) {
    return Utils.el("div", { class: "menu-wrap" }, [
      Utils.el("button", {
        type: "button", class: "icon-btn", "aria-label": "More actions", title: "More actions", onclick: function (ev) {
          ev.stopPropagation();
          Components.Dropdown.open(ev.currentTarget, menuItems(a));
        }
      }, [Utils.icon("kebab")])
    ]);
  }

  function menuItems(a) {
    const key = Store.addonKey(a);
    const isWago = a.source === "wago";
    const busy = Store.jobActingOn(key);
    const pinned = a.pinnedFileId !== null && a.pinnedFileId !== undefined;
    const hasPrevious = a.previousFileId !== null && a.previousFileId !== undefined;
    const items = [
      { label: "Update now", icon: "refresh", disabled: busy, onSelect: function () { Actions.updateNow(key); } },
      { label: "Versions…", icon: "list", onSelect: function () { Components.Drawer.open(key, { tab: "versions", source: a.source }); } },
      null,
      pinned
        ? { label: "Unpin", icon: "pin", disabled: busy, onSelect: function () { Actions.unpin(key); } }
        : { label: "Pin current version", icon: "pin", disabled: busy, onSelect: function () { Actions.pinCurrent(key); } }
    ];
    // E1: only offered when a local backup of the previous version exists to
    // restore from (addon.previousFileId set). A conditional `null` entry
    // here would render as a visible separator, not disappear, so this is
    // pushed rather than ternary'd into the array above.
    if (hasPrevious) {
      items.push({ label: "Roll back to " + (a.previousVersion || "previous version"), icon: "history", disabled: busy, onSelect: function () { Actions.rollback(key); } });
    }
    items.push(
      // Round 4 fix: uses the eye-off sprite icon (restored to the sprite
      // sheet in Round 16 after the API-key removal pass deleted it - this
      // menu item was its only remaining consumer) so this is the only kebab
      // item that isn't the sole entry with no leading icon - without one, its
      // label sat flush-left while every sibling item's label is indented past
      // an icon column, breaking the menu's alignment.
      a.ignoreUpdates
        ? { label: "Stop ignoring", icon: "eye-off", onSelect: function () { Actions.toggleIgnore(key, false); } }
        : { label: "Ignore updates", icon: "eye-off", onSelect: function () { Actions.toggleIgnore(key, true); } },
      // CS2 (UX-SPEC.md section 3.3): the old "Updated" table column's last-
      // installed date, demoted here as a plain info line - not a daily-
      // glance fact, but still one click away.
      { info: true, label: "Installed " + Utils.relativeTime(a.installedAt), title: Utils.fullDate(a.installedAt) },
      // E12: source-aware "Open on ..." entry.
      isWago
        ? { label: "Open on Wago", icon: "external", onSelect: function () { Actions.openOnWago(a.slug); } }
        : { label: "Open on CurseForge", icon: "external", onSelect: function () { Actions.openOnCurseForge(key); } }
    );
    // E12: "Also on Wago/CurseForge" - only when the tracked record's own
    // toc-parsed id revealed the other source, same condition the drawer
    // header's cross-source button uses.
    if (isWago && a.curseId) {
      items.push({ label: "Reinstall from CurseForge", icon: "refresh", disabled: busy, onSelect: function () { Actions.switchSource(a, "curseforge", a.curseId); } });
    } else if (!isWago && a.wagoId) {
      items.push({ label: "Reinstall from Wago", icon: "refresh", disabled: busy, onSelect: function () { Actions.switchSource(a, "wago", a.wagoId); } });
    }
    items.push(
      null,
      { label: "Uninstall", icon: "trash", danger: true, disabled: busy, onSelect: function () { Actions.uninstall(key); } }
    );
    return items;
  }

  function bindOnce() {
    Utils.qs("#myaddons-search").addEventListener("input", function (ev) {
      Store.state.myaddonsSearch = ev.target.value;
      render();
    });
    Utils.qsa(".th-sort-btn").forEach(function (btn) {
      btn.addEventListener("click", function () {
        const col = btn.dataset.sortCol;
        const current = Store.state.myaddonsSort;
        const dir = (current.column === col && current.dir === "asc") ? "desc" : "asc";
        Store.setMyAddonsSort({ column: col, dir: dir });
        render();
      });
    });
    Utils.qs("#btn-check-updates").addEventListener("click", function () { Actions.checkForUpdates(); });
    Utils.qs("#btn-update-all").addEventListener("click", function () { Actions.updateAll(); });
    Utils.qs("#btn-add-addon").addEventListener("click", function () { Components.Dialogs.openAdd(); });
    Utils.qs("#myaddons-empty-add").addEventListener("click", function () { Components.Dialogs.openAdd(); });
    Utils.qs("#myaddons-empty-browse").addEventListener("click", function () { App.switchView("browse"); });
    Utils.qs("#myaddons-clear-filters").addEventListener("click", function () {
      Store.state.myaddonsSearch = "";
      Store.state.myaddonsFilter = "all";
      Utils.qs("#myaddons-search").value = "";
      render();
    });
    Utils.qs("#myaddons-retry").addEventListener("click", function () { App.reloadState(false); });

    // E11: header checkbox toggles every currently visible/filtered row -
    // not the full underlying selection, so a search or status filter never
    // silently sweeps up rows the user can't see.
    Utils.qs("#myaddons-select-all").addEventListener("change", function (ev) {
      const visibleIds = filteredSorted().map(function (a) { return Store.addonKey(a); });
      if (ev.target.checked) Store.selectIds(visibleIds); else Store.deselectIds(visibleIds);
      render();
    });
    Utils.qs("#myaddons-clear-selection").addEventListener("click", function () { Store.clearSelection(); render(); });
    Utils.qs("#myaddons-bulk-update").addEventListener("click", function () { Actions.updateSelected(); });
    Utils.qs("#myaddons-bulk-ignore").addEventListener("click", function () { Actions.ignoreSelected(); });
    Utils.qs("#myaddons-bulk-uninstall").addEventListener("click", function () { Actions.uninstallSelected(); });
  }

  return { render: render, bindOnce: bindOnce };
})();

/* ---------- Get new addons ---------- */
// Round 15 (Eric, verbatim: "i dont like the weird tab thing on the left
// with furphy and curseforge - get rid of that. rename browse to get new
// addons. at the top of get new addons screen, let user switch between
// wago in app search, and curseforge, which browses the site contained in
// the area that the wago search was in, one unified experience"). Replaces
// CS3's merged CurseForge+Wago search grid with a segmented [Wago |
// CurseForge] switch (UX-SPEC.md section 5, rewritten this round):
//  - Wago keeps its own in-app search (query/loading/loaded/error/results
//    in Store.state.browse.wago) - CurseForge is no longer searched in-app;
//    its /api/cf/* endpoints stay live for add-by-link resolution and
//    drawer enrichment only.
//  - CurseForge is the real curseforge.com site. Inside the native host
//    with the cf-pane capability, an embedded WebView2 overlay the host
//    positions over #cf-placeholder's screen rect (SPEC.md's new E21
//    section - Host.cfShow/cfRect/cfHide/cfNav, and the host-ready/
//    cf-state/cf-job messages it sends back). Everywhere else (a plain
//    Edge-window install, or an older host without that capability), a
//    compact fallback panel pointing at the existing chromeless side
//    window (the 'cf-window' /api/open target).
Views.browse = (function () {
  const CF_HOME = "https://www.curseforge.com/wow/addons";

  // Whether this module currently believes the pane is the active segment
  // and has been told to show (subject to a temporary OverlayTracker-driven
  // hide while a dialog/drawer/popover is open on top of it).
  let cfActive = false;
  let overlayHidden = false;
  let rectObserver = null;
  let rafPending = false;
  let installNoteShown = false;

  function currentTab() { return Store.state.browse.tab; }

  /* ---- Wago (in-app search) ---- */

  async function searchWago(reset) {
    const b = Store.state.browse;
    const query = b.query;
    if (reset) { b.wago.results = []; }
    b.wago.loading = true;
    b.wago.error = null;
    renderWagoResults();
    try {
      const res = await Api.wagoSearch({ q: query, page: 1 });
      if (Store.state.browse.query !== query) return;
      b.wago.results = res.items || [];
      b.wago.loaded = true;
      b.wago.loading = false;
    } catch (err) {
      if (Store.state.browse.query !== query) return;
      b.wago.loading = false;
      b.wago.error = err;
    }
    renderWagoResults();
  }

  // Kept as a stable name for external callers (the input handler below,
  // Actions.searchDependency) - Wago is the only in-app source now.
  function search(reset) { searchWago(reset); }

  // Case-insensitive exact/starts-with/contains tiering, mirroring the same
  // three-tier scheme Search-CfCatalogue already applies server-side to the
  // (now unused-in-Browse) keyless CurseForge path. An empty query (the
  // default pre-typing view) gets one flat tier.
  function relevanceTier(name, needle) {
    if (!needle) return 3;
    const n = (name || "").toLowerCase();
    if (n === needle) return 0;
    if (n.indexOf(needle) === 0) return 1;
    if (n.indexOf(needle) !== -1) return 2;
    return 3;
  }

  // E12: Wago's search results are parsed HTML card snippets (slug/name/
  // thumbnail only - see SPEC's verified Wago facts), never author/summary/
  // downloads - that detail only exists on the addon's own /addons/{slug}
  // page, fetched once the drawer opens.
  function normalizeWagoEntry(item) {
    return {
      source: "wago", id: null, key: "wago:" + item.slug, name: item.name || item.slug, slug: item.slug,
      logoUrl: item.thumbnail || null, summary: null, author: null,
      downloadCount: null, updatedAt: null
    };
  }

  function sortedWagoEntries(b) {
    const needle = (b.query || "").trim().toLowerCase();
    const list = b.wago.results.map(normalizeWagoEntry);
    list.forEach(function (e) { e.tier = relevanceTier(e.name, needle); });
    list.sort(function (a, c) { return a.tier - c.tier; });
    return list;
  }

  function renderWagoResults() {
    const b = Store.state.browse;
    const grid = Utils.qs("#browse-grid");
    const skeleton = Utils.qs("#browse-skeleton");
    const empty = Utils.qs("#browse-empty");
    const errorBox = Utils.qs("#browse-error");
    const summary = Utils.qs("#browse-summary");
    const list = sortedWagoEntries(b);

    if (b.wago.loading && !list.length) {
      grid.hidden = true; empty.hidden = true; errorBox.hidden = true; skeleton.hidden = false;
      summary.textContent = "";
      return;
    }
    skeleton.hidden = true;

    if (!b.wago.loading && b.wago.error && !list.length) {
      grid.hidden = true; empty.hidden = true;
      errorBox.hidden = false;
      Utils.qs("#browse-error-msg").textContent = "Couldn't reach Wago right now.";
      summary.textContent = "";
      return;
    }
    errorBox.hidden = true;

    if (!b.wago.loading && !list.length) {
      grid.hidden = true; empty.hidden = false;
      summary.textContent = "";
    } else {
      empty.hidden = true;
      grid.hidden = false;
      grid.textContent = "";
      list.forEach(function (entry) { grid.appendChild(resultCard(entry)); });
      summary.textContent = list.length + " result" + (list.length === 1 ? "" : "s");
    }
  }

  // Round 17 (Eric: "change the wago results to a curseforge style
  // listing... they go the whole distance horizontally instead of little
  // tiles"): logo left, name+badge/author/summary/meta stacked in the
  // middle, Install right-aligned and vertically centered (see
  // .browse-row/style.css). Wago cards only ever carry name/slug/thumbnail
  // (E12) - every other field below renders only when the source actually
  // supplied it, never a blank slot.
  function resultCard(entry) {
    const tracked = !!Store.addonByProjectId(entry.key);
    const busy = Store.jobActingOn(entry.key);
    const btn = tracked
      ? Utils.el("button", { type: "button", class: "btn btn-outline", disabled: true }, [Utils.icon("check-circle"), "Installed"])
      // Review fix: was btn-accent - Browse cards can render alongside the
      // sidebar's own "Update & Play" accent button; only that one is ever
      // accent-colored per UX-SPEC.md section 1/2.3.
      : Utils.el("button", { type: "button", class: "btn btn-outline", disabled: busy, onclick: function (ev) {
          ev.stopPropagation();
          if (entry.source === "wago") Actions.installLatestWago(entry.slug, entry.name);
          else Actions.installLatest(entry.id, entry.name);
        } }, [busy ? "Installing…" : "Install"]);

    // UX-SPEC.md 5.1: source badge on every row, CF or Wago - the existing
    // Wago badge style (source-badge.is-wago) extended to CurseForge rows
    // (source-badge.is-cf) too.
    const heading = [
      Utils.el("span", { class: "browse-row-title" }, [entry.name]),
      Utils.el("span", { class: "source-badge " + (entry.source === "wago" ? "is-wago" : "is-cf") }, [entry.source === "wago" ? "Wago" : "CurseForge"])
    ];
    const main = [Utils.el("div", { class: "browse-row-heading" }, heading)];
    if (entry.author) main.push(Utils.el("div", { class: "browse-row-author" }, [entry.author]));
    if (entry.summary) main.push(Utils.el("div", { class: "browse-row-summary" }, [entry.summary]));

    const meta = [];
    if (entry.downloadCount != null) meta.push(Utils.el("span", {}, [Utils.formatNumber(entry.downloadCount) + " downloads"]));
    if (entry.updatedAt) meta.push(Utils.el("span", { title: Utils.fullDate(entry.updatedAt) }, ["updated " + Utils.relativeTime(entry.updatedAt)]));
    if (meta.length) main.push(Utils.el("div", { class: "browse-row-meta" }, meta));

    function open() {
      const opts = { tab: "overview", slug: entry.slug };
      if (entry.source === "wago") opts.source = "wago";
      Components.Drawer.open(entry.key, opts);
    }

    const node = Utils.el("div", {
      class: "browse-row", tabindex: "0", role: "button", "aria-label": "View " + entry.name,
      onkeydown: function (ev) {
        if (ev.target !== node) return; // let Enter/Space on the Install button do its own thing
        if (ev.key === "Enter" || ev.key === " " || ev.key === "Spacebar") { ev.preventDefault(); open(); }
      }
    }, [
      // Logo.build sets width/height as inline styles, which beat the
      // [data-density="compact"] .browse-row .addon-logo CSS override - so
      // the size has to be picked here, not left to that CSS rule (Round 17
      // review fix).
      Components.Logo.build({ projectId: entry.source === "cf" ? entry.id : null, name: entry.name, thumbnailUrl: entry.logoUrl }, Prefs.getDensity() === "compact" ? 44 : 56),
      Utils.el("div", { class: "browse-row-main" }, main),
      Utils.el("div", { class: "browse-row-action" }, [btn])
    ]);
    node.addEventListener("click", open);
    return node;
  }

  // The curseforge:// protocol toggle's one remaining home is Settings >
  // Advanced. There's no reliable way for this page to observe a click on
  // CurseForge.com's own Install button failing out in the separate side
  // window, so this fires the one thing Furphy CAN observe at the moment it
  // matters - right after the user opens that window, if the handler is
  // confirmed off (Store.state.protocol, loaded once at startup by
  // Actions.loadProtocolStatus) - shown at most once per session. Only
  // relevant to the fallback panel's own window - inside the native host's
  // embedded pane there is no OS-level protocol handoff in play at all.
  function maybeShowInstallNote() {
    if (installNoteShown) return;
    const p = Store.state.protocol;
    if (p && p.registered === false) {
      installNoteShown = true;
      const note = Utils.qs("#browse-install-note");
      if (note) note.hidden = false;
    }
  }

  // Opens the existing chromeless side window directly - the Edge-window/
  // older-host fallback path, used both by the fallback panel's own button
  // and by Actions.searchCurseForgeWebsite when Host.hasCfPane() is false.
  function openCfWindowFallback(url) {
    Actions.openWhat("cf-window", { url: url || CF_HOME });
    maybeShowInstallNote();
  }

  /* ---- CurseForge (native host, cf-pane capability) ---- */

  function placeholderEl() { return Utils.qs("#cf-placeholder"); }

  function measureRect() {
    const el = placeholderEl();
    if (!el) return null;
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height) return null;
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  }

  function scheduleRectUpdate() {
    if (rafPending || !cfActive) return;
    rafPending = true;
    requestAnimationFrame(function () {
      rafPending = false;
      if (!cfActive) return;
      const rect = measureRect();
      if (rect) Host.cfRect(rect);
    });
  }

  // Moves the actual #job-panel node (same node, same listeners) into
  // .cfpane-job-mount so it renders inline between the toolbar and the
  // placeholder instead of floating - see index.html's #job-panel-anchor
  // comment. A ResizeObserver on the placeholder (below) naturally posts a
  // fresh cf-rect once the panel's own height changes the placeholder's box.
  function placeInline() {
    const mount = Utils.qs("#cfpane-job-mount");
    const panel = Utils.qs("#job-panel");
    if (!mount || !panel || panel.parentNode === mount) return;
    panel.classList.add("is-inline");
    mount.appendChild(panel);
  }
  function placeFloating() {
    const anchor = Utils.qs("#job-panel-anchor");
    const panel = Utils.qs("#job-panel");
    if (!anchor || !panel) return;
    panel.classList.remove("is-inline");
    if (panel.previousElementSibling === anchor) return;
    if (anchor.parentNode) anchor.parentNode.insertBefore(panel, anchor.nextSibling);
  }

  function renderCfToolbar() {
    const st = Host.getCfState();
    const back = Utils.qs("#cf-nav-back");
    const fwd = Utils.qs("#cf-nav-forward");
    if (back) back.disabled = !st.canGoBack;
    if (fwd) fwd.disabled = !st.canGoForward;
    const title = Utils.qs("#cf-pane-title");
    if (title) title.textContent = st.loading ? "Loading…" : (st.title || "");
  }

  function ensureCfObservers() {
    const el = placeholderEl();
    if (!rectObserver && window.ResizeObserver) {
      rectObserver = new ResizeObserver(function () { scheduleRectUpdate(); });
    }
    if (rectObserver && el) rectObserver.observe(el);
    window.addEventListener("resize", scheduleRectUpdate);
    window.addEventListener("scroll", scheduleRectUpdate, true);
  }
  function teardownCfObservers() {
    if (rectObserver) rectObserver.disconnect();
    window.removeEventListener("resize", scheduleRectUpdate);
    window.removeEventListener("scroll", scheduleRectUpdate, true);
  }

  // opts: {url, navigate} - present only for an explicit "go to this URL"
  // request (Actions.switchToCfPane/navigateCf below); a plain "just show/
  // reposition" call (a tab click, a resize, returning from an overlay)
  // passes nothing, and only ever navigates the very first time the pane is
  // shown this session with no page of its own yet (SPEC.md E21's cf-show
  // contract).
  function setupCfPane(opts) {
    opts = opts || {};
    if (!cfActive) {
      const main = Utils.qs("#main");
      // Round 17: #main stops scrolling and stretches #view-browse/.cfpane
      // to fill the content area exactly (style.css's .main.is-cf-pane-
      // active) while the pane is up - removed in teardownCfPane below so
      // My Addons/Settings/the Wago segment are never affected. This class
      // must go on BEFORE the first measureRect() below: the placeholder
      // only joins the flex-fill chain once it's present, and reading
      // getBoundingClientRect() right after the classList change forces a
      // synchronous layout, so the very first rect sent to the host already
      // reflects the final filled height instead of the pre-class sliver.
      main.classList.add("is-cf-pane-active");
      const rect = measureRect();
      if (!rect) { main.classList.remove("is-cf-pane-active"); return; }
      const showOpts = {};
      if (opts.url) { showOpts.url = opts.url; if (opts.navigate) showOpts.navigate = true; }
      else if (!Host.getCfState().url) { showOpts.url = CF_HOME; }
      Host.cfShow(rect, showOpts);
      cfActive = true;
      placeInline();
      ensureCfObservers();
      Utils.qs("#toast-container").classList.add("is-cf-pane");
    } else if (opts.url) {
      Host.cfNav("go", opts.url);
    } else {
      scheduleRectUpdate();
    }
    renderCfToolbar();
  }

  function teardownCfPane() {
    if (cfActive) {
      cfActive = false;
      overlayHidden = false;
      Host.cfHide();
      teardownCfObservers();
      Utils.qs("#toast-container").classList.remove("is-cf-pane");
      Utils.qs("#main").classList.remove("is-cf-pane-active");
    }
    placeFloating();
  }

  function applyTabVisibility() {
    const tab = currentTab();
    const wagoTab = Utils.qs("#tab-wago");
    const cfTab = Utils.qs("#tab-curseforge");
    wagoTab.classList.toggle("is-active", tab === "wago");
    wagoTab.setAttribute("aria-selected", tab === "wago" ? "true" : "false");
    cfTab.classList.toggle("is-active", tab === "curseforge");
    cfTab.setAttribute("aria-selected", tab === "curseforge" ? "true" : "false");
    const showCfNative = tab === "curseforge" && Host.hasCfPane();
    const showCfFallback = tab === "curseforge" && !Host.hasCfPane();
    Utils.qs("#browse-wago-panel").hidden = tab !== "wago";
    Utils.qs("#browse-cf-panel").hidden = !showCfNative;
    Utils.qs("#browse-cf-fallback").hidden = !showCfFallback;
    return { tab: tab, showCfNative: showCfNative };
  }

  function render() {
    const info = applyTabVisibility();
    if (info.tab === "wago") {
      const b = Store.state.browse;
      if (!b.wago.loaded && !b.wago.loading && !b.wago.error) searchWago(true);
      else renderWagoResults();
      teardownCfPane();
    } else if (info.showCfNative) {
      setupCfPane();
    } else {
      teardownCfPane();
    }
  }

  function setTab(tab) {
    if (tab !== "wago" && tab !== "curseforge") return;
    if (tab === currentTab()) return;
    Store.setBrowseTab(tab);
    render();
  }

  // Actions.switchToCfPane's navigation half - switches to the CurseForge
  // segment (if not already there) and navigates the pane to url. A no-op
  // past the tab switch when the native host doesn't have the cf-pane
  // capability - applyTabVisibility() has already shown the fallback panel
  // in that case, and Actions itself only calls this when hasCfPane() is
  // true (see Actions.openOnCurseForge/searchCurseForgeWebsite).
  function navigateCf(url, forceNavigate) {
    Store.setBrowseTab("curseforge");
    const info = applyTabVisibility();
    if (info.showCfNative) setupCfPane({ url: url, navigate: forceNavigate !== false });
  }

  // App.switchView calls this when leaving Get new addons for another view
  // entirely (render() above only tears the pane down for an in-view tab
  // switch, since it's only ever called while this view is the active one).
  function onLeaveView() { teardownCfPane(); }

  function bindOnce() {
    Utils.qs("#tab-wago").addEventListener("click", function () { setTab("wago"); });
    Utils.qs("#tab-curseforge").addEventListener("click", function () { setTab("curseforge"); });

    Utils.qs("#browse-search").addEventListener("input", Utils.debounce(function (ev) {
      Store.state.browse.query = ev.target.value;
      search(true);
    }, 400));

    // "Not on Wago? Try CurseForge" - switches segments in the native host;
    // everywhere else, opens the existing side window directly rather than
    // switching to a segment that would only show its own "browsing
    // happens in the desktop window" fallback panel (UX-SPEC.md section 5).
    Utils.qs("#btn-cf-web-search").addEventListener("click", function () {
      if (Host.hasCfPane()) { setTab("curseforge"); return; }
      openCfWindowFallback();
    });
    Utils.qs("#btn-browse-add-link").addEventListener("click", function () { Components.Dialogs.openAdd(); });
    Utils.qs("#btn-browse-add-link-fallback").addEventListener("click", function () { Components.Dialogs.openAdd(); });

    Utils.qs("#btn-cf-open-window").addEventListener("click", function () { openCfWindowFallback(); });
    Utils.qs("#btn-browse-install-note-settings").addEventListener("click", function () { App.switchView("settings"); });

    // CurseForge pane toolbar (drawn in HTML - see design note at the top
    // of this file's Views.browse comment).
    Utils.qs("#cf-nav-back").addEventListener("click", function () { if (cfActive) Host.cfNav("back"); });
    Utils.qs("#cf-nav-forward").addEventListener("click", function () { if (cfActive) Host.cfNav("forward"); });
    Utils.qs("#cf-nav-reload").addEventListener("click", function () { if (cfActive) Host.cfNav("reload"); });
    Utils.qs("#cf-nav-home").addEventListener("click", function () { if (cfActive) Host.cfNav("home"); });
    Utils.qs("#cf-pane-search").addEventListener("keydown", function (ev) {
      if (ev.key !== "Enter" || !cfActive) return;
      const q = ev.target.value.trim();
      if (!q) return;
      Host.cfNav("go", "https://www.curseforge.com/wow/search?search=" + encodeURIComponent(q) + "&class=addons");
    });

    // Host -> page (SPEC.md E21): cf-state repaints the toolbar; host-ready
    // re-renders once hasCfPane() actually has an answer, which can arrive
    // after the first render (a fresh page load racing the host's own
    // CoreWebView2 startup - or the mock's own simulated delay); cf-job
    // opens the job panel immediately for a job the host itself started (an
    // Install click intercepted on curseforge.com), instead of waiting for
    // the next poll tick.
    Host.onCfState(function () {
      if (Store.state.view === "browse" && currentTab() === "curseforge") renderCfToolbar();
    });
    Host.onHostReady(function () {
      if (Store.state.view === "browse") render();
    });
    Host.onCfJob(function (jobId) {
      if (jobId) App.attachToJob(jobId);
    });

    // Any dialog/drawer/popover opening covers the pane's screen rect with
    // real HTML (a confirm dialog, the detail drawer, a kebab menu...) but
    // a WebView2 child window always paints above ordinary HTML regardless
    // of z-index, so it has to be told to hide instead - then shown again
    // once the last one closes (OverlayTracker only fires on the 0->1/1->0
    // transitions, so nested popovers don't flicker it).
    OverlayTracker.onChange(function (open) {
      if (!cfActive) return;
      if (open) {
        overlayHidden = true;
        Host.cfHide();
      } else if (overlayHidden) {
        overlayHidden = false;
        const rect = measureRect();
        if (rect) Host.cfShow(rect);
      }
    });

    // A reload/navigate-away/close - the host keeps the pane's own page
    // loaded (so back/forward survives a reopen), but it should stop
    // painting over whatever's about to replace this page.
    window.addEventListener("pagehide", function () { if (cfActive) Host.cfHide(); });
  }

  return {
    render: render, search: search, bindOnce: bindOnce,
    setTab: setTab, navigateCf: navigateCf, onLeaveView: onLeaveView,
    openCfWindowFallback: openCfWindowFallback
  };
})();

/* ---------- Settings ---------- */
Views.settings = (function () {
  let untrackedList = [];
  let untrackedLoading = false;
  let untrackedError = null;
  // Round 5 fix: distinguishes "Scan has never run" from "Scan ran and found
  // nothing" - both used to render the identical "click Scan to look" copy,
  // so a real zero-result scan gave no visible confirmation it had run at all.
  let untrackedScanned = false;
  // E10: Diagnostics panel state - null diagChecks means "never run yet"
  // (distinct from an empty array, which /api/diagnostics never actually
  // returns, but is handled the same as "never run" either way).
  let diagLoading = false;
  let diagError = null;
  let diagChecks = null;

  function render() {
    const s = Store.state.settings;
    if (!s) return;

    renderGameFolders(s);

    // CS4 (UX-SPEC.md 6.1): the old 3-way release-channel radio is now two
    // independent toggles driven off the same releaseType value - "Include
    // beta versions" (Essentials) and "Also include alpha/experimental
    // versions" (Advanced). Alpha implies beta (releaseType 3), so the beta
    // toggle also shows checked when releaseType is 3, even though flipping
    // it back off on its own is what un-checks alpha too (see bindOnce).
    Utils.qs("#toggle-beta").checked = Number(s.releaseType) === 2 || Number(s.releaseType) === 3;
    Utils.qs("#toggle-alpha").checked = Number(s.releaseType) === 3;
    Utils.qs("#toggle-autoupdate").checked = !!s.autoUpdateOnLaunch;

    Utils.qs("#about-version").textContent = App.getServerVersion() || "—";
    // UX-SPEC.md §7/§8: "Client build number" was removed from My Addons and
    // relocated here, matching the "kept, just relocated" pattern used for
    // every other row in that table. Store.state.clientBuild is delivered on
    // /api/state (see the reloadState diff below, ~line 6093).
    renderAboutClientBuild();
    const uptime = App.getServerUptime();
    Utils.qs("#about-uptime").textContent = uptime !== null ? formatUptime(uptime) : "—";
    // CS4: "Port" is dropped from the visible About list (UX-SPEC.md 6.2) -
    // it still goes out in Diagnostics' "Copy report" text, see
    // diagnosticsReportText() below, which reads s.port directly.

    renderFlavourSettings(s);
    renderBrowsing(s);
    renderBackgroundUpdates(s);
    Components.ProtocolControl.render("settings-protocol-control");
    renderAppearance();
    renderUntracked();
    renderDiagnostics();
    const busy = Store.isBusy();
    const reinstall = Utils.qs("#btn-force-reinstall");
    reinstall.disabled = busy;
    if (busy) reinstall.title = "Another task is running"; else reinstall.removeAttribute("title");
  }

  // FLAVORS-SPEC.md CS-F4 (section 6.2/copy table): today's exact two rows
  // (#settings-game-single), untouched, at <=1 installed flavour; one row
  // per installed flavour (#settings-game-multi) once there's more than one.
  // The per-flavour "Open" button passes its own flavour along (Actions.
  // openWhat's extra arg) for forward-compatibility - the server's own
  // /api/open 'folder' target has no per-flavour resolution yet (untouched
  // by this change set, addon-server.ps1 is outside CS-F4's file list), so
  // every row's button currently opens the same default flavour's folder
  // until a future round wires that up; see this function's own notesForNext.
  function renderGameFolders(s) {
    // Deliberately the RAW installed count, not visibleFlavours() - this is
    // an informational/troubleshooting list (like About's build list below),
    // not the switcher, so a detected-but-hidden PTR/XPTR/Beta client still
    // earns its own row here.
    const multi = Store.state.installedFlavours.length > 1;
    Utils.qs("#settings-game-single").hidden = multi;
    const box = Utils.qs("#settings-game-multi");
    box.hidden = !multi;
    if (!multi) { Utils.qs("#settings-wow-root").textContent = s.wowRoot || "—"; Utils.qs("#settings-addons-path").textContent = s.addonsPath || "—"; return; }
    box.textContent = "";
    Store.state.installedFlavours.forEach(function (f) {
      box.appendChild(Utils.el("div", { class: "settings-row" }, [
        Utils.el("div", { class: "settings-row-text" }, [
          Utils.el("div", { class: "settings-row-label" }, [f.label]),
          Utils.el("div", { class: "settings-row-value" }, [f.addonsPath || "—"])
        ]),
        Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.openWhat("folder", { flavour: f.id }); } }, ["Open"])
      ]));
    });
  }

  // FLAVORS-SPEC.md CS-F4 (section 6.2): a small per-flavour list only once
  // more than one flavour is installed - single-flavour machines keep
  // today's exact single line, unchanged.
  function renderAboutClientBuild() {
    const dd = Utils.qs("#about-client-build");
    const visible = Store.state.installedFlavours;
    if (visible.length <= 1) { dd.textContent = Store.state.clientBuild || "—"; return; }
    dd.textContent = "";
    visible.forEach(function (f, i) {
      if (i > 0) dd.appendChild(Utils.el("br", {}, []));
      const build = f.buildInfoMissing || !f.clientBuild ? "— version unknown (launch this client once)" : f.clientBuild;
      dd.appendChild(Utils.el("span", {}, [f.label + " — " + build]));
    });
  }

  // FLAVORS-SPEC.md CS-F4 (section 2.5/6.5): only shown at all when a PTR/
  // XPTR/Beta client is actually detected - a machine that never sees one
  // gets no clutter for a setting that would otherwise do nothing.
  const HIDDEN_FLAVOUR_IDS = { ptr: true, xptr: true, beta: true };
  function renderFlavourSettings(s) {
    const section = Utils.qs("#settings-flavours");
    const hasTestRealm = Store.state.installedFlavours.some(function (f) { return HIDDEN_FLAVOUR_IDS[f.id]; });
    section.hidden = !hasTestRealm;
    if (hasTestRealm) Utils.qs("#toggle-show-test-realms").checked = !!s.showTestRealms;
  }

  function formatUptime(seconds) {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    return h > 0 ? (h + "h " + m + "m") : (m + "m");
  }

  // Round 5 fix: About > Server uptime is a live extrapolation
  // (App.getServerUptime(), computed from a single /api/ping fetched once at
  // startup) but was only ever painted by the full render() pass above -
  // which the idle poll's `changed` gate (App.reloadState) skips whenever
  // nothing else in /api/state actually changed, since ping-derived uptime
  // isn't part of that diff. Sitting on Settings with no other state change
  // therefore froze the displayed value until leaving and re-entering the
  // view forced a full repaint. This repaints just the one element on its
  // own short ticker (see App.startUptimeTicker) without going through the
  // full render()/state-diff path.
  function renderUptimeOnly() {
    const el = Utils.qs("#about-uptime");
    if (!el) return;
    const uptime = App.getServerUptime();
    el.textContent = uptime !== null ? formatUptime(uptime) : "—";
  }

  // E19: the ad filter only does anything inside the native host's
  // (host\FurphyHost.exe) embedded CurseForge tab - the plain Edge app
  // window (App.getServerHost() === "edge-app") has no such tab to filter,
  // so the toggle is swapped for a muted explainer there instead of
  // offering a control that would silently do nothing when flipped.
  function renderBrowsing(s) {
    const isHost = App.getServerHost() === "webview2";
    Utils.qs("#browsing-adfilter-row").hidden = !isHost;
    Utils.qs("#browsing-adfilter-unavailable").hidden = isHost;
    if (isHost) Utils.qs("#toggle-adfilter").checked = !!s.adFilter;
    // Round 16 (E22): cfFocus, unlike adFilter, is meaningful (and saved)
    // even in the plain Edge window - it just doesn't take effect until the
    // desktop window is used next, since only the native host has a
    // CurseForge pane to trim. So this row is never hidden.
    Utils.qs("#toggle-cf-focus").checked = !!s.cfFocus;
  }

  // Round 18 (tray stage B): unlike adFilter, these three are meaningful
  // (and saved) everywhere - the background tray is a plain Windows process,
  // not tied to the native host's own CurseForge pane - so this row is never
  // hidden. The interval <select> only shows while background updates is on;
  // the status line reads Store.state.trayStatus, kept fresh by the normal
  // state poll and by an immediate fetch on entering this view (see
  // App.switchView/App.reloadState).
  function renderBackgroundUpdates(s) {
    const bgOn = !!s.backgroundUpdates;
    Utils.qs("#toggle-background-updates").checked = bgOn;
    Utils.qs("#updates-interval-row").hidden = !bgOn;
    Utils.qs("#select-background-interval").value = String(s.backgroundIntervalMinutes || 120);
    Utils.qs("#toggle-run-at-startup").checked = !!s.runAtStartup;
    Utils.qs("#updates-background-status").textContent = backgroundStatusText(s, Store.state.trayStatus);
  }

  // "HH:MM" in the viewer's local time, from a lastRunAt ISO timestamp -
  // matches the plain "14:02" style the task brief's status lines use, no
  // date/seconds/timezone clutter.
  function formatLocalTime(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
  }

  // One plain-words line, fed by /api/tray/status (Store.state.trayStatus) -
  // the five shapes are exactly what the task brief specifies; anything else
  // tray-state.json's lastResult could report (skipped_busy, error, or no
  // cycle run yet) gets a same-style fallback rather than blank text.
  function backgroundStatusText(s, trayStatus) {
    if (!s || !s.backgroundUpdates) return "Background updates off";
    const state = trayStatus && trayStatus.state;
    if (!state || !state.lastResult) return "Running - waiting for the first check";
    const time = formatLocalTime(state.lastRunAt);
    switch (state.lastResult) {
      case "up_to_date": return "Running - last check " + time + ": everything up to date";
      case "updated": return "Running - updated " + ((state.updatedNames || []).length) + " at " + time;
      case "failed": return "Running - " + ((state.failedNames || []).length) + " failed at " + time;
      case "skipped_wow_running": return "Waiting - WoW is running";
      case "skipped_busy": return "Waiting - another task is running";
      default: return "Running - check failed at " + time;
    }
  }

  // E7: reflects the persisted density/theme choice (Prefs, already applied
  // to <html> as soon as the page loaded) as the active button in each
  // segmented toggle, and (round 18, Set B) the checked swatch in the theme
  // picker grid.
  function renderAppearance() {
    const density = Prefs.getDensity();
    Utils.qsa("#density-toggle .segmented-btn").forEach(function (btn) {
      btn.classList.toggle("is-active", btn.dataset.densityValue === density);
    });
    paintThemeGrid();
  }

  // THEMES-SPEC.md section 3.1/3.3: one <button role="radio"> per THEMES
  // entry, built ONCE (called from bindOnce, not render) so a mid-session
  // repaint - the idle poll while Settings is open, for instance - never
  // yanks focus out from under a keyboard user mid-navigation. Every commit
  // path (click, or Enter/Space which a real <button> already turns into a
  // "click" for free) re-renders only the checked state via paintThemeGrid()
  // below, never rebuilds the buttons.
  function buildThemeGrid() {
    const grid = Utils.qs("#theme-grid");
    if (!grid || grid.childElementCount) return; // already built, or markup missing
    THEMES.forEach(function (t) {
      const check = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      check.setAttribute("class", "theme-swatch-check");
      check.setAttribute("viewBox", "0 0 12 12");
      check.setAttribute("width", "12");
      check.setAttribute("height", "12");
      check.setAttribute("aria-hidden", "true");
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      path.setAttribute("d", "M2 6l3 3 5-6");
      path.setAttribute("fill", "none");
      path.setAttribute("stroke", "currentColor");
      path.setAttribute("stroke-width", "1.6");
      path.setAttribute("stroke-linecap", "round");
      path.setAttribute("stroke-linejoin", "round");
      check.appendChild(path);

      const btn = Utils.el("button", {
        type: "button", class: "theme-swatch", role: "radio",
        dataset: { themeValue: t.slug }
      }, [
        Utils.el("span", { class: "theme-swatch-preview", "aria-hidden": "true" }, [
          Utils.el("span", { class: "theme-swatch-accent" }),
          Utils.el("span", { class: "theme-swatch-text" }, ["Aa"]),
          check
        ]),
        Utils.el("span", { class: "theme-swatch-name" }, [t.name])
      ]);
      grid.appendChild(btn);
    });

    // Click commits immediately. Enter/Space on a focused <button> already
    // fire a native "click" event, so no separate key handling is needed for
    // those two - only arrow/Home/End navigation (focus-only, per section
    // 3.3) needs its own keydown handler.
    grid.addEventListener("click", function (ev) {
      const btn = ev.target.closest(".theme-swatch");
      if (!btn) return;
      Prefs.setTheme(btn.dataset.themeValue);
      paintThemeGrid();
    });
    grid.addEventListener("keydown", function (ev) {
      const swatches = Utils.qsa(".theme-swatch", grid);
      const i = swatches.indexOf(document.activeElement);
      if (i === -1) return;
      let next = -1;
      if (ev.key === "ArrowRight" || ev.key === "ArrowDown") next = (i + 1) % swatches.length;
      else if (ev.key === "ArrowLeft" || ev.key === "ArrowUp") next = (i - 1 + swatches.length) % swatches.length;
      else if (ev.key === "Home") next = 0;
      else if (ev.key === "End") next = swatches.length - 1;
      else return;
      ev.preventDefault();
      swatches[next].focus(); // focus only - theme changes only on the commit path above
    });
  }

  // Roving tabindex + aria-checked/visual ring, kept in sync with
  // Prefs.getTheme() on every settings render and every commit - never
  // recreates the buttons themselves (see buildThemeGrid above).
  function paintThemeGrid() {
    const theme = Prefs.getTheme();
    Utils.qsa("#theme-grid .theme-swatch").forEach(function (btn) {
      const checked = btn.dataset.themeValue === theme;
      btn.setAttribute("aria-checked", checked ? "true" : "false");
      btn.tabIndex = checked ? 0 : -1;
    });
  }

  function renderUntracked() {
    const box = Utils.qs("#untracked-list");
    box.textContent = "";
    if (untrackedLoading) { box.appendChild(Utils.el("div", { class: "skeleton-row" })); return; }
    if (untrackedError) { box.appendChild(Utils.el("p", { class: "muted-text" }, ["Couldn't scan: " + describeError(untrackedError)])); return; }
    if (!untrackedList.length) {
      // CS4 (UX-SPEC.md 6.2/§7): "Untracked" -> "doesn't manage yet" in
      // every visible string here, not just the section heading/intro.
      const msg = untrackedScanned ? "Scanned — nothing found." : "Nothing found yet. Click Scan to look.";
      box.appendChild(Utils.el("p", { class: "muted-text" }, [msg]));
      return;
    }
    untrackedList.forEach(function (u) { box.appendChild(untrackedRow(u)); });
  }

  function untrackedRow(u) {
    // CS5 (UX-SPEC.md 6.2's own flagged follow-up): add the missing "find
    // this on the addon's page" hint - a title tooltip rather than another
    // visible sentence, matching Browse's own light-touch fallback link.
    const idInput = Utils.el("input", { type: "text", placeholder: "Numeric ID", title: "Find this on the addon's CurseForge or Wago page" });
    const busy = Store.isBusy();
    const actions = [idInput];
    // E12: -Scan reports whatever curseId/wagoId it found in the folder's own
    // .toc (## X-Curse-Project-ID / ## X-Wago-ID) - offer a one-click take-
    // over straight from either id, ahead of the manual Project-ID input,
    // when the folder's own info already answers the question. CS4
    // (UX-SPEC.md 6.2/§7): "Adopt" -> "Take over" in every visible string
    // this row shows - Actions.adopt/adoptWago (this row's only callers)
    // carry the matching "Taking over..." job-panel label.
    if (u.curseId) {
      actions.push(Utils.el("button", {
        type: "button", class: "btn btn-outline", disabled: busy,
        title: "Take over as CurseForge project " + u.curseId,
        onclick: function () { Actions.adopt(u.folder, Number(u.curseId)); }
      }, ["Take over (CF " + u.curseId + ")"]));
    }
    if (u.wagoId) {
      actions.push(Utils.el("button", {
        type: "button", class: "btn btn-outline", disabled: busy,
        title: "Take over as Wago addon " + u.wagoId,
        onclick: function () { Actions.adoptWago(u.folder, u.wagoId); }
      }, ["Take over (Wago)"]));
    }
    actions.push(
      Utils.el("button", {
        type: "button", class: "btn btn-outline", disabled: busy, onclick: function () {
          const v = idInput.value.trim();
          if (!/^\d+$/.test(v)) { Components.Toast.show("Enter a numeric ID first.", "warning"); return; }
          Actions.adopt(u.folder, Number(v));
        }
      }, ["Take over"]),
      Utils.el("button", { type: "button", class: "btn btn-danger-outline", onclick: function () { Actions.deleteUntracked(u.folder); } }, ["Delete"])
    );
    return Utils.el("div", { class: "untracked-row" }, [
      Utils.el("div", { class: "untracked-info" }, [
        Utils.el("div", { class: "untracked-folder" }, [u.folder]),
        Utils.el("div", { class: "untracked-meta" }, [u.title ? (u.title + (u.version ? " · " + u.version : "")) : (u.hasToc ? "No title found" : "No details found")])
      ]),
      Utils.el("div", { class: "untracked-actions" }, actions)
    ]);
  }

  async function rescan() {
    untrackedLoading = true; untrackedError = null; renderUntracked();
    try {
      const res = await Api.scan();
      untrackedList = res.untracked || [];
      untrackedScanned = true;
    } catch (err) {
      untrackedError = err;
    } finally {
      untrackedLoading = false;
      renderUntracked();
    }
  }

  // E10: Settings > Diagnostics. A plain fetch-and-render, not a job - there
  // is no CLI process or addons.json write behind /api/diagnostics, so it
  // doesn't go through Actions.startJob's job-panel/polling machinery, the
  // same way Untracked folders' Scan (above) doesn't either.
  function renderDiagnostics() {
    const box = Utils.qs("#diagnostics-list");
    const copyBtn = Utils.qs("#btn-copy-diagnostics");
    const runBtn = Utils.qs("#btn-run-diagnostics");
    runBtn.disabled = diagLoading;
    box.textContent = "";
    if (diagLoading) {
      box.appendChild(Utils.el("div", { class: "skeleton-row" }));
      copyBtn.hidden = true;
      return;
    }
    if (diagError) {
      box.appendChild(Utils.el("p", { class: "muted-text" }, ["Couldn't run diagnostics: " + describeError(diagError)]));
      copyBtn.hidden = true;
      return;
    }
    if (!diagChecks) {
      box.appendChild(Utils.el("p", { class: "muted-text" }, ["Click Run to check the AddOns folder, config files, CurseForge reachability, and disk space."]));
      copyBtn.hidden = true;
      return;
    }
    // CS4 (UX-SPEC.md 6.2 + copy table): "PowerShell version" is dropped
    // from the visible list entirely - it stays in diagChecks (and so in
    // diagnosticsReportText()'s Copy report below) but is never painted as
    // a row here.
    diagChecks.forEach(function (c) { if (DIAG_HIDDEN_ONSCREEN.indexOf(c.name) === -1) box.appendChild(diagRow(c)); });
    copyBtn.hidden = diagChecks.length === 0;
  }

  // CS4: on-screen rows show plain pass/fail language, never the server's
  // raw filenames/HTTP codes/PS version string/internal source names/ISO
  // timestamps (UX-SPEC.md 6.2 + copy table + acceptance checklist) - all of
  // that stays intact, byte-verbatim, in diagnosticsReportText()'s Copy
  // report output below. This is a purely client-side rewording layer;
  // addon-server.ps1's /api/diagnostics response itself is untouched (out
  // of this change set's file scope - see notesForNext).
  const DIAG_HIDDEN_ONSCREEN = ["PowerShell version"];
  const DIAG_ISO_RE = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/;

  function plainDiagRow(c) {
    const ok = c.ok;
    const detail = c.detail || "";
    switch (c.name) {
      case "AddOns folder":
        return { label: "AddOns folder", detail: ok ? "Found and writable" : "Couldn't find or write to it" };
      case "settings.json":
        return { label: "Your addon settings", detail: ok ? "Look fine" : "There's a problem" };
      case "addons.json": {
        const m = detail.match(/^(\d+)\s+record/);
        if (ok && m) return { label: "Tracked addons", detail: m[1] + " addon" + (m[1] === "1" ? "" : "s") + " tracked" };
        return { label: "Tracked addons", detail: ok ? "Look fine" : "There's a problem" };
      }
      case "CurseForge reachability":
        return { label: "CurseForge", detail: ok ? "Reached OK" : "Couldn't reach it" };
      case "Disk space":
        return { label: "Disk space", detail: ok ? "Plenty free" : "Running low" };
      case "Server uptime":
        return { label: "Server uptime", detail: DIAG_ISO_RE.test(detail) ? "" : (detail || "—") };
      case "Last sync":
        return { label: "Last sync", detail: DIAG_ISO_RE.test(detail) ? "Recorded" : (detail || "never") };
      case "WoW client build":
        return { label: "WoW client build", detail: ok ? "Detected" : "Couldn't detect it" };
      case "CurseForge catalogue cache":
        return { label: "Addon catalogue", detail: ok ? "Up to date" : "Needs a refresh" };
      case "addon-radar reachability":
        return { label: "Addon search mirror", detail: ok ? "Reached OK" : "Couldn't reach it" };
      default:
        // Defensive fallback for any future check this mapping doesn't yet
        // know about - still strips a raw ISO timestamp if one shows up.
        return { label: c.name, detail: DIAG_ISO_RE.test(detail) ? "" : detail };
    }
  }

  function diagRow(c) {
    const plain = plainDiagRow(c);
    return Utils.el("div", { class: "diag-row" }, [
      Utils.el("span", { class: "diag-dot " + (c.ok ? "is-ok" : "is-fail") }),
      Utils.el("span", { class: "diag-name" }, [plain.label]),
      Utils.el("span", { class: "diag-detail" }, [plain.detail || ""])
    ]);
  }

  // Plain text for the "Copy report" button - one line per check, no markup,
  // so it pastes cleanly into a bug report or a chat message. Unlike the
  // on-screen rows above, this reads the server's raw c.name/c.detail
  // verbatim (including the hidden "PowerShell version" row) and appends
  // the port, per UX-SPEC.md 6.2's "Port... kept in Copy report only".
  function diagnosticsReportText() {
    if (!diagChecks) return "";
    const lines = ["Furphy Addon Manager diagnostics - " + new Date().toLocaleString()];
    diagChecks.forEach(function (c) { lines.push((c.ok ? "[OK]   " : "[FAIL] ") + c.name + ": " + (c.detail || "")); });
    const s = Store.state.settings;
    if (s && s.port) lines.push("Port: " + s.port);
    return lines.join("\n");
  }

  async function runDiagnostics() {
    diagLoading = true; diagError = null; renderDiagnostics();
    try {
      const res = await Api.getDiagnostics();
      diagChecks = res.checks || [];
    } catch (err) {
      diagError = err;
    } finally {
      diagLoading = false;
      renderDiagnostics();
    }
  }

  function bindOnce() {
    // CS4 (UX-SPEC.md 6.1/6.2): the old 3-way release-channel radio is now
    // two independent toggles - "Include beta versions" (Essentials) and
    // "Also include alpha/experimental versions" (Advanced) - driven off the
    // one underlying releaseType value (1/2/3). Alpha implies beta, so
    // turning beta OFF while alpha is still on turns alpha off too (there is
    // no releaseType value for "alpha but not beta"); turning alpha ON always
    // lands on 3 regardless of beta's current state.
    Utils.qs("#toggle-beta").addEventListener("change", function (ev) {
      const beta = ev.target.checked;
      const alpha = beta && Utils.qs("#toggle-alpha").checked;
      Actions.saveSettings({ releaseType: alpha ? 3 : (beta ? 2 : 1) });
    });
    Utils.qs("#toggle-alpha").addEventListener("change", function (ev) {
      const alpha = ev.target.checked;
      const beta = alpha || Utils.qs("#toggle-beta").checked;
      Actions.saveSettings({ releaseType: alpha ? 3 : (beta ? 2 : 1) });
    });
    Utils.qs("#toggle-autoupdate").addEventListener("change", function (ev) { Actions.saveSettings({ autoUpdateOnLaunch: ev.target.checked }); });
    // FLAVORS-SPEC.md CS-F4 (section 2.5/6.5): saveSettings' own
    // App.renderChrome() call already repaints the switcher (Store.
    // visibleFlavours() reads this same setting), so PTR/XPTR/Beta appear
    // or disappear from the pill row the instant this toggle is flipped.
    Utils.qs("#toggle-show-test-realms").addEventListener("change", function (ev) { Actions.saveSettings({ showTestRealms: ev.target.checked }); });
    // E19: only visible/enabled while renderBrowsing() has shown the row
    // (the native host is running) - see that function's comment.
    Utils.qs("#toggle-adfilter").addEventListener("change", function (ev) { Actions.saveSettings({ adFilter: ev.target.checked }); });
    // Round 16 (E22): saves like any other setting, and - only when actually
    // running inside the native host - also applies live to the CurseForge
    // pane already open, no restart needed (Host.cfFocus is a no-op outside
    // the host).
    Utils.qs("#toggle-cf-focus").addEventListener("change", function (ev) {
      Actions.saveSettings({ cfFocus: ev.target.checked });
      Host.cfFocus(ev.target.checked);
    });

    // Round 18 (tray stage B): these three drive the background tray
    // process (start/stop, its interval, and the Windows Run value) - see
    // Actions.setBackgroundUpdates/setRunAtStartup for the actual
    // save+tray-control sequencing.
    Utils.qs("#toggle-background-updates").addEventListener("change", function (ev) {
      Actions.setBackgroundUpdates(ev.target.checked);
    });
    Utils.qs("#select-background-interval").addEventListener("change", function (ev) {
      Actions.saveSettings({ backgroundIntervalMinutes: Number(ev.target.value) });
    });
    Utils.qs("#toggle-run-at-startup").addEventListener("change", function (ev) {
      Actions.setRunAtStartup(ev.target.checked);
    });

    Utils.qsa("#density-toggle .segmented-btn").forEach(function (btn) {
      btn.addEventListener("click", function () { Prefs.setDensity(btn.dataset.densityValue); renderAppearance(); });
    });
    // Round 18 (Set B): the theme picker is a dynamically-built grid, not
    // static markup - built once here (its own click/keydown wiring lives
    // inside buildThemeGrid itself), never rebuilt by render().
    buildThemeGrid();

    Utils.qs("#btn-open-wowfolder").addEventListener("click", function () { Actions.openWhat("folder"); });
    Utils.qs("#btn-open-addons").addEventListener("click", function () { Actions.openWhat("addons"); });
    // CS4 (UX-SPEC.md 6.2): the four separate "Open sync log / Open last run
    // report / Open server log / Open backups folder" buttons collapse into
    // one "Open logs folder" button, backed by a new server-side /api/open
    // 'logs' target (addon-server.ps1 Handle-Open) that opens the app's own
    // root folder in Explorer - sync.log, server.log, last-run.txt and
    // backups\ all already live there side by side, so one Explorer window
    // reaches every one of them. The 'log'/'serverlog'/'lastrun'/'backups'
    // /api/open targets themselves are untouched server-side (demote, don't
    // delete - still reachable by any other caller), just no longer wired to
    // their own individual buttons here.
    Utils.qs("#btn-open-logs").addEventListener("click", function () { Actions.openWhat("logs"); });

    // Round 17: the manual "Refresh the addon list from CurseForge" button
    // (and its Api.cfCatalogueRefresh call) is gone - the catalogue still
    // refreshes itself automatically at most once/24h
    // (Load/Save-CfCatalogueIndex, addon-server.ps1), and its age is still
    // reported by the "CurseForge catalogue cache" diagnostics row below.

    // E4: Export downloads a Blob built from the parsed /api/export response
    // (rather than a plain `<a href="/api/export" download>`) so it works
    // identically under ?mock=1, where there's no real URL to link to at
    // all - every other action in this file already goes through Api the
    // same way. Import reads the chosen file, validates its format/shape
    // client-side up front (Handle-Import repeats this server-side, so a
    // malformed or foreign file never starts a job either way), shows the
    // "how many will be added / already present" preview via the existing
    // generic confirm dialog, then starts the import job on confirm.
    Utils.qs("#btn-export").addEventListener("click", async function () {
      try {
        const data = await Api.exportAddons();
        const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "addons-export.json";
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
        Components.Toast.show("Saved " + ((data.addons && data.addons.length) || 0) + " addon(s).", "success");
      } catch (err) {
        Components.Toast.show("Couldn't export: " + describeError(err), "error");
      }
    });

    Utils.qs("#btn-import").addEventListener("click", function () {
      const input = Utils.qs("#import-file-input");
      input.value = ""; // clears any previous selection so re-picking the same file still fires "change"
      input.click();
    });
    Utils.qs("#import-file-input").addEventListener("change", async function (ev) {
      const file = ev.target.files && ev.target.files[0];
      if (!file) return;
      const msg = Utils.qs("#backup-msg");
      msg.hidden = true;
      let data;
      try {
        data = JSON.parse(await file.text());
      } catch (err) {
        msg.hidden = false; msg.className = "form-msg is-error"; msg.textContent = "Couldn't read that file: not valid JSON.";
        return;
      }
      if (!data || data.format !== "wow-addon-manager/1" || !Array.isArray(data.addons)) {
        msg.hidden = false; msg.className = "form-msg is-error"; msg.textContent = "That file isn't a Furphy Addon Manager addon list.";
        return;
      }
      // Review fix: was keyed on a bare Number(a.projectId), which is 0 for
      // every Wago entry (projectId is always null for those - Number(null)
      // === 0, not null) - so a Wago addon in the file was checked against
      // existingIds.has(0), essentially never true, meaning every Wago
      // addon always previewed as "will be added" here even when already
      // tracked. Both the export shape (Handle-Export) and Store.state.addons
      // records carry the same source/slug/projectId fields Store.addonKey
      // already knows how to read, so reuse it for both sides instead of a
      // hand-rolled projectId comparison. This is purely a client-side
      // preview-count fix - the actual import job is still resolved
      // correctly server-side by Build-ImportPlan regardless.
      const existingIds = new Set(Store.state.addons.map(function (a) { return Utils.normalizeId(Store.addonKey(a)); }));
      const toAdd = data.addons.filter(function (a) { return a && !existingIds.has(Utils.normalizeId(Store.addonKey(a))); }).length;
      const present = data.addons.length - toAdd;
      const ok = await Components.Dialogs.confirm({
        title: "Load addon list?",
        message: data.addons.length + " addon(s) in the file — " + toAdd + " will be added, " + present + " already present.",
        confirmLabel: "Load",
        danger: false
      });
      if (!ok) return;
      await Actions.importAddons(data);
    });

    Utils.qs("#btn-scan").addEventListener("click", function () { rescan(); });

    Utils.qs("#btn-force-reinstall").addEventListener("click", async function () {
      const ok = await Components.Dialogs.confirm({
        title: "Force reinstall all addons?",
        message: "Every tracked addon is re-downloaded and reinstalled, even ones already up to date.",
        confirmLabel: "Force reinstall"
      });
      if (ok) Actions.forceReinstallAll();
    });

    Utils.qs("#btn-run-diagnostics").addEventListener("click", function () { runDiagnostics(); });
    Utils.qs("#btn-copy-diagnostics").addEventListener("click", async function () {
      const text = diagnosticsReportText();
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
        Components.Toast.show("Diagnostics report copied.", "success");
      } catch (err) {
        // Fallback for a context where the async Clipboard API rejects (e.g.
        // clipboard-write permission denied) - a hidden textarea + the older
        // execCommand path still works there.
        try {
          const ta = document.createElement("textarea");
          ta.value = text;
          ta.style.position = "fixed";
          ta.style.opacity = "0";
          document.body.appendChild(ta);
          ta.focus();
          ta.select();
          document.execCommand("copy");
          ta.remove();
          Components.Toast.show("Diagnostics report copied.", "success");
        } catch (err2) {
          Components.Toast.show("Couldn't copy to clipboard.", "error");
        }
      }
    });
  }

  return { render: render, bindOnce: bindOnce, rescan: rescan, renderUptimeOnly: renderUptimeOnly };
})();

/* ==========================================================================
   Host - round 12 (E19b): postMessage bridge to the native WebView2 host
   (host\FurphyHost.cs), used ONLY while this page is actually running
   inside it. Everywhere else (a plain browser tab, ?mock=1, or the Edge
   --app fallback window) isNative() is false and every caller below falls
   back to the existing HTTP /api/open flow, unchanged.

   Placed here (right before App, whose getServerHost() this module reads)
   for that reason, NOT because every caller runs this late - Prefs.applyTheme
   calls reportTheme() as literally the first thing this whole script does
   (module-load time, before Host OR App exist yet as far down the file as
   they do), which is exactly why isNative()/reportTheme() are written to
   swallow a reference to either not existing yet rather than assume it: that
   very first call is a harmless no-op, and App.init() calls reportTheme()
   again once App.getServerHost() actually has an answer, so the host still
   gets a real report once startup finishes. Every later call (a user
   switching themes in Settings, well after the whole script has loaded) hits
   no such gap.
   ========================================================================== */
const Host = (function () {
  function isNative() {
    try {
      return !!(window.chrome && window.chrome.webview && App.getServerHost() === "webview2");
    } catch (e) {
      // App (or, in principle, this very module) not initialized yet - see
      // the module comment above. Not native as far as this call can tell.
      return false;
    }
  }

  function post(obj) {
    if (!isNative()) return false;
    try {
      window.chrome.webview.postMessage(obj);
      return true;
    } catch (e) {
      return false;
    }
  }

  // Routes a curseforge.com URL to the host's embedded CurseForge tab
  // instead of a browser/side-window. Returns true when handled (the caller
  // should stop there and do nothing else); false when this isn't the
  // native host, or the url isn't a curseforge.com one - the caller's
  // existing server-backed fallback ('cf-window'/'curseforge'/'url') should
  // run in that case, unchanged.
  function openCurseForge(url) {
    if (!url || typeof url !== "string") return false;
    if (!/^https:\/\/www\.curseforge\.com\//i.test(url)) return false;
    return post({ type: "open-curseforge", url: url });
  }

  // Relays the theme CSS custom properties actually in effect right now to
  // the host, so it can recolor its own chrome/title bar to match. Reads
  // document.documentElement.dataset.theme directly (not Prefs.getTheme(),
  // which reads localStorage - stale at the exact moment Prefs.setTheme
  // calls applyTheme(v) BEFORE writing v to localStorage) and every color
  // via getComputedStyle, which is synchronous and always reflects whatever
  // data-theme attribute is on the element right now. No-op (false) outside
  // the native host.
  function reportTheme() {
    if (!isNative()) return false;
    const name = document.documentElement.dataset.theme || DEFAULT_THEME;
    const cs = getComputedStyle(document.documentElement);
    const propByKey = { bg0: "--bg-0", bg1: "--bg-1", bg2: "--bg-2", bg3: "--bg-3", border: "--border", text: "--text", muted: "--text-muted", accent: "--accent" };
    const colors = {};
    Object.keys(propByKey).forEach(function (key) {
      const v = (cs.getPropertyValue(propByKey[key]) || "").trim();
      if (/^#[0-9a-fA-F]{6}$/.test(v)) colors[key] = v;
    });
    return post({ type: "theme", name: name, colors: colors });
  }

  /* ------------------------------------------------------------------------
     Round 15 (SPEC.md E21): the embedded CurseForge pane contract. The host
     is the source of truth for whether it supports a pane at all - a
     {type:"host-ready", capabilities:[...]} message (sent once when the
     host's own CoreWebView2 is ready, and again in reply to this module's
     own {type:"hello"} - the only way a page that reloaded mid-session can
     rediscover it) is the ONLY thing that ever sets hasCfPane() true, so an
     older host that doesn't know about any of this simply never flips it -
     Views.browse falls back to the plain-Edge-window panel in that case,
     exactly as it does outside the native host entirely.
     ------------------------------------------------------------------------ */
  let cfPaneCapable = false;
  let hostVersionStr = null;
  // {url, title, canGoBack, canGoForward, loading} - the host's last-reported
  // CurseForge navigation state, mirrored here so a caller that hasn't
  // subscribed yet (e.g. Views.browse.render() on first paint) can still
  // read the current snapshot instead of waiting for the next message.
  let lastCfState = { url: null, title: null, canGoBack: false, canGoForward: false, loading: false };
  const cfStateListeners = [];
  const cfJobListeners = [];
  const hostReadyListeners = [];
  let wired = false;

  function onHostMessage(m) {
    if (!m || typeof m !== "object") return;
    if (m.type === "host-ready") {
      cfPaneCapable = !!(m.capabilities && m.capabilities.indexOf("cf-pane") !== -1);
      hostVersionStr = m.version || null;
      // host-ready can arrive asynchronously, well after Views.browse's
      // first render already ran with hasCfPane() still false (a fresh
      // page load racing the host's own CoreWebView2 startup) - listeners
      // re-check/re-render once it's actually known.
      hostReadyListeners.forEach(function (fn) { try { fn(cfPaneCapable); } catch (e) { /* one bad listener shouldn't break the rest */ } });
    } else if (m.type === "cf-state") {
      lastCfState = { url: m.url || null, title: m.title || null, canGoBack: !!m.canGoBack, canGoForward: !!m.canGoForward, loading: !!m.loading };
      cfStateListeners.forEach(function (fn) { try { fn(lastCfState); } catch (e) { /* one bad listener shouldn't break the rest */ } });
    } else if (m.type === "cf-job") {
      cfJobListeners.forEach(function (fn) { try { fn(m.jobId, m.status); } catch (e) { /* ditto */ } });
    }
  }

  // Wires the host->page message channel once (called from App.init()) and
  // asks whatever host is listening to (re-)announce itself. Outside the
  // native host, window.chrome.webview never exists, so this is a harmless
  // no-op - hasCfPane() simply stays false forever, same as an old host
  // that never replies at all.
  function init() {
    if (wired) return;
    wired = true;
    try {
      if (window.chrome && window.chrome.webview && window.chrome.webview.addEventListener) {
        window.chrome.webview.addEventListener("message", function (e) { onHostMessage(e && e.data); });
      }
    } catch (e) { /* not the native host */ }
    post({ type: "hello" });
  }

  function hasCfPane() { return isNative() && cfPaneCapable; }
  function hostVersion() { return hostVersionStr; }
  function getCfState() { return lastCfState; }
  function onCfState(fn) { cfStateListeners.push(fn); }
  function onCfJob(fn) { cfJobListeners.push(fn); }
  function onHostReady(fn) { hostReadyListeners.push(fn); }

  // Shows (or, called again while already shown, moves/resizes) the pane
  // over a CSS-pixel rect (viewport-relative, from the placeholder's own
  // getBoundingClientRect()) - device pixels are computed host-side as
  // css * dpr. opts.url only actually navigates when the pane has no page
  // loaded yet, or opts.navigate is explicitly set (SPEC.md E21).
  function cfShow(rect, opts) {
    opts = opts || {};
    const msg = { type: "cf-show", rect: rect, dpr: window.devicePixelRatio || 1 };
    if (opts.url) msg.url = opts.url;
    if (opts.navigate) msg.navigate = true;
    return post(msg);
  }
  function cfRect(rect) { return post({ type: "cf-rect", rect: rect, dpr: window.devicePixelRatio || 1 }); }
  function cfHide() { return post({ type: "cf-hide" }); }
  // Round 16 (E22): applies (or un-applies) the CurseForge listing/search
  // focus-view trim to the pane already open, live, without a reload -
  // Settings' toggle calls this alongside Actions.saveSettings so the
  // setting persists AND takes effect immediately. No-op (false) outside the
  // native host, same as every other Host.* call - the setting still saved
  // via Actions.saveSettings applies next time the desktop window is used.
  function cfFocus(enabled) { return post({ type: "cf-focus", enabled: !!enabled }); }
  function cfNav(action, url) {
    const msg = { type: "cf-nav", action: action };
    if (url) msg.url = url;
    return post(msg);
  }

  return {
    isNative: isNative, post: post, openCurseForge: openCurseForge, reportTheme: reportTheme,
    init: init, hasCfPane: hasCfPane, hostVersion: hostVersion,
    getCfState: getCfState, onCfState: onCfState, onCfJob: onCfJob, onHostReady: onHostReady,
    cfShow: cfShow, cfRect: cfRect, cfHide: cfHide, cfNav: cfNav, cfFocus: cfFocus
  };
})();

/* ==========================================================================
   App - bootstrap, view routing, polling loops, and one-time global wiring
   (nav, drawer/dialog/lightbox dismissal, sidebar buttons, shutdown beacon).
   ========================================================================== */
const App = (function () {
  let idleTimer = null;
  let jobPollTimer = null;
  // Security-review fix: id of the last machine-wide awaiting_flavour job
  // (data.pendingFlavourChoice) this client auto-surfaced the picker for -
  // see reloadState's own comment. Lets a user who closes the panel keep it
  // closed across idle polls instead of it reopening every 5s, while still
  // surfacing a genuinely NEW ask.
  let pendingFlavourChoiceShownId = null;
  let autoCheckTimer = null;
  let uptimeTimer = null;
  let serverVersion = null;
  let serverUptimeAtFetch = null;
  let serverUptimeFetchedAt = null;
  // E19: 'webview2' | 'edge-app' | null (unknown until the first successful
  // ping) - see the server's Handle-Ping/Invoke-Route (sticky once set to
  // 'webview2': the native host's Furphy tab is the only caller that ever
  // sends ?host=webview2 on GET /). Read by Views.settings.renderBrowsing
  // to decide whether the ad-filter toggle can do anything.
  let serverHost = null;

  // E2: automatic update checks. A missing/stale updatesCheckedAt starts a
  // background check shortly after load; then it repeats every 30 minutes
  // for as long as the window stays open, skipping whenever a job is busy.
  const AUTO_CHECK_STALE_MS = 10 * 60 * 1000;
  const AUTO_CHECK_INTERVAL_MS = 30 * 60 * 1000;

  // E18: first-run welcome dialog - shown at most once per browser after
  // the user dismisses it (see wireGlobal's #welcome-skip handler below).
  const WELCOME_SKIPPED_KEY = "addonSync.welcomeSkipped.v1";

  function switchView(view) {
    if (Store.state.view === view) return;
    // Round 15: render() only tears the CurseForge pane down for an in-view
    // tab switch (Wago <-> CurseForge) - leaving Get new addons for another
    // view entirely needs its own explicit teardown, since Views.browse's
    // own render() is never called again once another view is active.
    const leavingBrowse = Store.state.view === "browse";
    Store.state.view = view;
    Utils.qsa(".nav-item").forEach(function (btn) { btn.classList.toggle("is-active", btn.dataset.view === view); });
    Utils.qsa(".view").forEach(function (sec) { sec.hidden = sec.dataset.viewRoot !== view; });
    if (leavingBrowse) Views.browse.onLeaveView();
    Components.JobPanel.collapseIfOpen();
    renderCurrentView();
    // Round 18 (tray stage B): fetch the current tray status right away on
    // entering Settings, rather than waiting up to one idle-poll tick (see
    // reloadState) for the status line to stop showing stale/empty data.
    if (view === "settings") Actions.refreshTrayStatus();
  }

  function renderCurrentView() {
    if (Store.state.view === "myaddons") Views.myAddons.render();
    else if (Store.state.view === "browse") Views.browse.render();
    else if (Store.state.view === "settings") Views.settings.render();
    renderChrome();
  }

  // CS5: deep-link support for verification and future callers - a
  // ?view=my-addons|browse|settings query param picks the initial view on
  // load (default unchanged: no/unrecognized param stays on My Addons).
  // Round 15: "browse" is renamed "get-new-addons" everywhere visible, but
  // "browse" keeps working as an alias (internal identifiers - Views.browse,
  // Store.state.view's "browse" value - are unchanged, per design B); a
  // ?tab=wago|curseforge alongside either one picks the initial segment
  // (design D). Applied once, directly against the static markup (nav-item
  // classes + .view section visibility, and Store.setBrowseTab for the tab)
  // rather than via switchView()/Views.browse.setTab() themselves, since
  // both no-op when the target already equals the current state - true for
  // the default "myaddons"/"wago" case.
  const VIEW_QUERY_MAP = { "my-addons": "myaddons", "browse": "browse", "get-new-addons": "browse", "settings": "settings" };
  function applyInitialViewFromQuery() {
    const params = new URLSearchParams(location.search);
    // THEMES-SPEC.md Set B: ?theme=<slug> applies AND persists that theme on
    // load, same pattern as ?view=/?tab= above - used for verification
    // screenshots and deep links. An unknown slug is silently ignored (no
    // theme change) rather than falling back to the default, so a typo in a
    // link can't clobber whatever the viewer already had set.
    const themeParam = params.get("theme");
    if (themeParam && Prefs.isKnownTheme(themeParam)) Prefs.setTheme(themeParam);
    const target = VIEW_QUERY_MAP[params.get("view")];
    if (target && target !== Store.state.view) {
      Store.state.view = target;
      Utils.qsa(".nav-item").forEach(function (btn) { btn.classList.toggle("is-active", btn.dataset.view === target); });
      Utils.qsa(".view").forEach(function (sec) { sec.hidden = sec.dataset.viewRoot !== target; });
    }
    const tab = params.get("tab");
    if (target === "browse" && (tab === "wago" || tab === "curseforge")) Store.setBrowseTab(tab);
  }

  // Sidebar badges/status line, the Update-all label, global busy-disabling,
  // and a live drawer refresh - anything that isn't specific to one view.
  function renderChrome() {
    Utils.qs("#nav-count-total").textContent = Store.state.addons.length;

    renderConnectivity();
    Components.Freshness.render("sidebar-freshness", { dotOnly: true });
    renderUpdateAllButton();
    // FLAVORS-SPEC.md CS-F4: the switcher/Update All pair (zero DOM at <=1
    // visible flavour) and the "Update & Play" label (section 6.3).
    Components.Switcher.render();
    renderUpdatePlayButton();
    applyBusyToStaticButtons();
    Components.Drawer.refresh();
  }

  // FLAVORS-SPEC.md CS-F4 (section 6.3/copy table): unchanged text/toast at
  // <=1 VISIBLE flavour (principle 2) - "Update & Play [Label]" for Retail,
  // "Update & Open Battle.net [Label]" for every other flavour once the
  // switcher exists, reflecting whichever pill is currently active.
  function renderUpdatePlayButton() {
    const btn = Utils.qs("#btn-update-play");
    const span = btn && btn.querySelector("span");
    if (!span) return;
    const visible = Store.visibleFlavours();
    if (visible.length <= 1) { span.textContent = "Update & Play"; return; }
    const active = Store.state.activeFlavour;
    const meta = visible.filter(function (f) { return f.id === active; })[0] || visible[0];
    span.textContent = (!meta || meta.id === "retail") ? ("Update & Play " + (meta ? meta.label : "Retail")) : ("Update & Open Battle.net " + meta.label);
  }

  // CS2 (UX-SPEC.md section 2.1): connectivity ("can the UI reach the local
  // server at all") is a separate fact from freshness, never folded into the
  // same dot/text - the sidebar dot stays grey/green at all times and only
  // carries visible text in the two problem states. Freshness itself is
  // rendered by Components.Freshness (called from renderChrome, right next
  // to this), not here.
  function renderConnectivity() {
    const dot = Utils.qs("#status-dot");
    const text = Utils.qs("#status-text");
    if (Store.state.online === false) {
      dot.dataset.state = "error";
      text.textContent = "Server not reachable — restart from the desktop shortcut.";
      return;
    }
    if (Store.state.online === null) { dot.dataset.state = "connecting"; text.textContent = "Connecting…"; return; }
    dot.dataset.state = "ok";
    text.textContent = ""; // connected and nothing wrong: silence, not absence
  }

  // CS2 (UX-SPEC.md section 2.3 / copy table §7): "Update all" is kept but
  // now outline-styled - on the main dashboard, the sidebar's "Update & Play"
  // is the one accent-colored call to action against which "Update all" and
  // the per-row Update pills should read as secondary (a handful of other
  // dialog/empty-state buttons elsewhere in the app are also accent-styled
  // as their own one-primary-CTA-per-dialog choice; this scoping is about
  // the dashboard's own competing buttons, not a whole-app rule) - and
  // hidden entirely once a completed check found nothing to update, not
  // just disabled, so no dead button sits there.
  function renderUpdateAllButton() {
    const btn = Utils.qs("#btn-update-all");
    // Review fix (F2): scope the button's own count to what updateAll()
    // actually updates (excludes ignored addons) - Store.updatesCount()
    // stays the informational "updates exist somewhere" figure used by the
    // sidebar badge/Freshness headline, but this button's label promises
    // what clicking it will do, so it must match updateAll()'s real scope
    // per the file's own pre-existing post-CS6 invariant (see updateAll()).
    const n = Store.state.addons.filter(function (a) { return a.updateAvailable && !a.ignoreUpdates; }).length;
    const checked = !!Store.state.updatesCheckedAt;
    const nothingToDo = checked && n === 0;
    btn.hidden = nothingToDo;
    if (nothingToDo) return;
    btn.textContent = n > 0 ? ("Update all (" + n + ")") : "Update all";
    const busy = Store.isBusy();
    btn.disabled = busy;
    if (busy) btn.title = "Another task is running";
    else btn.removeAttribute("title");
  }

  function applyBusyToStaticButtons() {
    const busy = Store.isBusy();
    // E11: "Update selected"/"Uninstall selected" each start a job (sync/
    // remove), same as Update now/Uninstall on the per-row kebab menu, which
    // already disable during a running job - these two get the same
    // treatment. "Ignore selected" does NOT start a job (sequential fast
    // POST .../ignore calls), matching the per-row kebab's "Ignore updates"/
    // "Stop ignoring" entry, which has never been busy-gated either.
    ["btn-update-play", "btn-launch-wow", "btn-check-updates", "btn-add-addon", "myaddons-empty-add", "myaddons-bulk-update", "myaddons-bulk-uninstall"].forEach(function (id) {
      const btn = document.getElementById(id);
      if (!btn) return;
      btn.disabled = busy;
      if (busy) btn.title = "Another task is running"; else btn.removeAttribute("title");
    });
  }

  function onJobStarted(jobId) {
    Components.JobPanel.show(Store.state.job);
    renderChrome();
    renderCurrentView();
    // Review fix (F1/F3): pick up the server's already-"checking" freshness
    // (Get-ComputedFreshness flips the instant the job's state is "running")
    // right away, instead of leaving the headline frozen on stale text for
    // the whole run - pollJob only re-fetches /api/jobs/{id} (no freshness
    // field on that endpoint) and only calls reloadState once the job stops
    // running; the idle poll explicitly skips reloadState while busy. Fire-
    // and-forget: reloadState repaints on its own once the fetch resolves.
    reloadState(false);
    pollJob(jobId);
  }

  // Round 15 (SPEC.md E21's cf-job message): a job the host itself started
  // (an Install click intercepted on curseforge.com, POSTed to /api/jobs
  // directly by the host, not through this page's own Actions.startJob) -
  // fetches its current state and opens the job panel for it immediately,
  // instead of waiting for the next 500ms poll tick to notice it. Ignored
  // if this page already knows about it (its own startJob already showed
  // the panel and is already polling). Best-effort - a fetch failure here
  // just means the panel opens on the next regular poll instead, same as
  // before this message existed.
  async function attachToJob(jobId) {
    if (!jobId || (Store.state.job && Store.state.job.id === jobId)) return;
    try {
      const job = await Api.getJob(jobId);
      Store.state.job = job;
      Components.JobPanel.show(job);
      renderChrome();
      renderCurrentView();
      if (job.state === "running") pollJob(jobId);
    } catch (err) { /* best-effort only - see comment above */ }
  }

  // Round 9: a completed check job that found updates gets a real desktop
  // notification, not just the in-app toast/badge below - CurseForge's own
  // app keeps a Windows notification up even after its check panel closes,
  // which matters most for the unattended background check (autoCheckForUpdates,
  // every 30 min - see Actions.autoCheckForUpdates) where nobody is
  // necessarily looking at the app at all. Purely client-side (the standard
  // Notification API) - no new /api surface, no PowerShell module dependency;
  // degrades silently wherever Notification is unavailable, blocked, or the
  // user never grants permission.
  function notifyIfUpdatesFound(job) {
    if (!job || job.kind !== "check" || job.state !== "done") return;
    if (typeof Notification === "undefined") return;
    const rows = (job.results || []).filter(function (r) { return r.status === "Would-update"; });
    if (!rows.length) return;
    function fire() {
      const names = rows.map(function (r) { return r.name; });
      const body = names.length <= 4 ? names.join(", ") : (names.slice(0, 4).join(", ") + ", and " + (names.length - 4) + " more");
      try {
        // requireInteraction keeps it on screen until the user dismisses it
        // (Chromium/Edge honor this; browsers that don't just auto-dismiss,
        // which is no worse than not having a notification at all) - the
        // "persist until dismissed or an update is started" behavior a
        // check-and-forget in-app toast can't offer.
        const n = new Notification(rows.length + " addon update" + (rows.length === 1 ? "" : "s") + " available", {
          body: body, requireInteraction: true, tag: "furphy-addon-updates"
        });
        n.onclick = function () { window.focus(); switchView("myaddons"); n.close(); };
      } catch (err) { /* best-effort only - never let a notification failure affect the job flow */ }
    }
    if (Notification.permission === "granted") fire();
    else if (Notification.permission === "default") {
      Notification.requestPermission().then(function (perm) { if (perm === "granted") fire(); });
    }
  }

  function pollJob(jobId) {
    clearTimeout(jobPollTimer);
    jobPollTimer = setTimeout(async function () {
      try {
        const job = await Api.getJob(jobId);
        Store.state.job = job;
        Components.JobPanel.update(job);
        renderChrome();
        renderCurrentView();
        if (job.state === "running") { pollJob(jobId); return; }
        // FLAVORS-SPEC.md CS-F3: awaiting_flavour is a dead end until the
        // user picks one of the panel's choices (JobPanel.update just
        // rendered the picker above) - never a finished-job toast, and
        // nothing to reload yet since no addon has actually changed.
        if (job.state === "awaiting_flavour") return;
        await reloadState(true);
        // Review fix (UX-SPEC.md 7 copy table / acceptance checklist item 8):
        // this toast used to be "Failed: " + raw job.error - the exact
        // pre-spec string the copy table calls out by name. The plain-
        // language sentence is now the same one already persisted in the
        // job panel (Components.JobPanel.wholeJobFailureReason), and the
        // toast itself is just a transient nudge to look at the panel - the
        // raw text stays reachable only behind that panel's own Details.
        // FLAVORS-SPEC.md CS-F4 (section 6.3/copy table): a non-Retail
        // launch's own honest toast - never a silent "Launching WoW…"
        // overpromise, per section 4.7's launch-reliability caveat. Retail
        // (job.flavour is 'retail', or absent on a single-flavour machine)
        // keeps today's exact wording via the unchanged summarize() branch.
        const summary = job.state === "failed" ? Components.JobPanel.wholeJobFailureReason(job)
          : (job.kind === "launch" && job.flavour && job.flavour !== "retail")
            ? "Addons updated. Check Battle.net — you may need to press Play."
            : Components.JobPanel.summarize(job.results);
        Components.Toast.show(summary, job.state === "failed" ? "error" : "success");
        notifyIfUpdatesFound(job);
      } catch (err) {
        markOnline(err);
        reloadState(true);
      }
    }, 500); // CS2 (UX-SPEC.md section 4.3): 800ms -> 500ms, so the determinate
             // progress bar/current-item line track a fast-moving job closely.
  }

  async function reloadState(afterJob) {
    try {
      const data = await Api.getState();
      markOnline(null);
      const nextAddons = data.addons || [];
      const nextSettings = data.settings || Store.state.settings;
      const nextLastRun = data.lastRun || null;
      const nextJob = data.job || (afterJob ? null : Store.state.job);
      const nextCheckedAt = data.updatesCheckedAt || null;
      const nextClientBuild = data.clientBuild || null;
      const nextClientInterface = data.clientInterface || null;
      // CS2: the one computed freshness enum plus the two failure-detail
      // fields CS1 added to /api/state - read here, alongside every other
      // /api/state field, rather than in a separate fetch.
      const nextFreshness = data.freshness || null;
      const nextLastCheckFailed = !!data.lastCheckFailed;
      const nextLastCheckError = data.lastCheckError || null;
      // FLAVORS-SPEC.md CS-F4 (S5.2): the two fields present on every
      // response regardless of ?flavour= - describe the MACHINE, not one
      // flavour's data. installedFlavours always has at least one entry;
      // activeFlavour falls back to its own id when the server ever omits
      // it (should not happen, but keeps Store.state.activeFlavour from
      // going null and silently disabling every flavour-scoped request).
      const nextInstalledFlavours = data.installedFlavours || [];
      const nextActiveFlavour = data.activeFlavour || data.flavour || (nextInstalledFlavours[0] && nextInstalledFlavours[0].id) || Store.state.activeFlavour;
      // Security-review fix: a job in state "awaiting_flavour" is never
      // attributed to any one flavour (Get-CurrentOrLastJobSummary skips
      // it deliberately), so a CurseForge install link that lands in this
      // state - curseforge-handler.vbs, run from the OS protocol handler,
      // never reads the /api/jobs response body at all - used to leave the
      // user with nothing visible: no picker, no toast, no error, the job
      // just sat unresolved forever. The server now surfaces that same job
      // machine-wide as data.pendingFlavourChoice regardless of which
      // flavour is active; picked up here so it renders through the
      // already-built awaiting_flavour picker (Components.JobPanel).
      const nextPendingFlavourChoice = data.pendingFlavourChoice || null;

      // Round 4 fix: the idle poll (every 5s, see scheduleIdlePoll below) used
      // to call renderCurrentView() unconditionally on every tick, even when
      // the fetched state was identical to what's already on screen. My
      // Addons' render() clears and rebuilds its whole tbody, Browse/Settings
      // similarly repaint - doing that every 5s can tear a DOM node (an open
      // kebab menu, a mid-click drawer tab) out from under a click that
      // landed in the same instant. Skip the repaint when nothing changed;
      // markOnline() above already refreshes the "checked ... ago" status
      // line regardless, so that text doesn't go stale.
      const changed = afterJob
        || Store.state.loadingState || !!Store.state.stateError
        || JSON.stringify(nextAddons) !== JSON.stringify(Store.state.addons)
        || JSON.stringify(nextSettings) !== JSON.stringify(Store.state.settings)
        || JSON.stringify(nextLastRun) !== JSON.stringify(Store.state.lastRun)
        || JSON.stringify(nextJob) !== JSON.stringify(Store.state.job)
        || nextCheckedAt !== Store.state.updatesCheckedAt
        || nextClientBuild !== Store.state.clientBuild
        || nextFreshness !== Store.state.freshness
        || nextLastCheckFailed !== Store.state.lastCheckFailed
        || nextLastCheckError !== Store.state.lastCheckError
        || JSON.stringify(nextInstalledFlavours) !== JSON.stringify(Store.state.installedFlavours)
        || nextActiveFlavour !== Store.state.activeFlavour
        || JSON.stringify(nextPendingFlavourChoice) !== JSON.stringify(Store.state.pendingFlavourChoice);

      Store.set({
        addons: nextAddons, settings: nextSettings, lastRun: nextLastRun,
        job: nextJob, updatesCheckedAt: nextCheckedAt,
        clientBuild: nextClientBuild, clientInterface: nextClientInterface,
        freshness: nextFreshness, lastCheckFailed: nextLastCheckFailed, lastCheckError: nextLastCheckError,
        installedFlavours: nextInstalledFlavours, activeFlavour: nextActiveFlavour,
        pendingFlavourChoice: nextPendingFlavourChoice,
        loadingState: false, stateError: null
      });
      if (!afterJob) resumeJobPollingIfNeeded();
      // Security-review fix: surface a newly-discovered pending
      // awaiting_flavour job's picker exactly once (tracked by job id) -
      // never re-forces the panel open on every idle poll if the user
      // already closed it, but a genuinely different pending ask (a new
      // id) still gets shown. Only auto-shown while no OTHER job is
      // actively running, so it never steals the panel from a sync/install
      // the user is already watching.
      if (nextPendingFlavourChoice && nextPendingFlavourChoice.id !== pendingFlavourChoiceShownId
        && (!nextJob || nextJob.state !== "running")) {
        pendingFlavourChoiceShownId = nextPendingFlavourChoice.id;
        Components.JobPanel.show(nextPendingFlavourChoice);
      } else if (!nextPendingFlavourChoice) {
        pendingFlavourChoiceShownId = null;
      }
      if (changed) renderCurrentView();
      // Round 18 (tray stage B): the background-tray status line
      // (Views.settings) is fed by a separate endpoint (/api/tray/status,
      // not part of /api/state's own shape) - piggyback it on this same
      // poll cadence, but only while Settings is actually the active view,
      // so no extra request happens on every other screen. Fire-and-forget:
      // refreshTrayStatus repaints Settings itself once the fetch resolves.
      if (Store.state.view === "settings") Actions.refreshTrayStatus();
    } catch (err) {
      markOnline(err);
      Store.set({ loadingState: false, stateError: err });
      renderCurrentView();
    }
  }

  function resumeJobPollingIfNeeded() {
    if (Store.state.job && Store.state.job.state === "running") {
      Components.JobPanel.show(Store.state.job);
      pollJob(Store.state.job.id);
    }
  }

  function markOnline(err) {
    const wasOnline = Store.state.online;
    if (err) {
      Store.state.online = false;
      Utils.qs("#banner-offline").hidden = false;
      if (wasOnline !== false) Components.Toast.show("Lost connection to the server.", "error");
    } else {
      Store.state.online = true;
      Utils.qs("#banner-offline").hidden = true;
      if (wasOnline === false) Components.Toast.show("Reconnected to the server.", "success");
    }
    renderConnectivity();
  }

  // Self-rescheduling (setTimeout, not setInterval) so the cadence can adapt
  // after every tick: 5s while the server answers normally, backing off to
  // 10s while it's unreachable (banner-offline shown by markOnline) so a
  // server that exited on idle isn't hammered, then dropping straight back
  // to 5s on the first successful response once it's back.
  const POLL_ONLINE_MS = 5000;
  const POLL_OFFLINE_MS = 10000;

  function startIdlePolling() {
    clearTimeout(idleTimer);
    scheduleIdlePoll();
  }

  function scheduleIdlePoll() {
    const delay = Store.state.online === false ? POLL_OFFLINE_MS : POLL_ONLINE_MS;
    idleTimer = setTimeout(async function () {
      if (!Store.isBusy()) await reloadState(false); // the 800ms job poller already covers the busy window
      scheduleIdlePoll();
    }, delay);
  }

  function isUpdatesCheckStale() {
    const checkedAt = Store.state.updatesCheckedAt;
    if (!checkedAt) return true;
    const then = new Date(checkedAt).getTime();
    if (isNaN(then)) return true;
    return (Date.now() - then) >= AUTO_CHECK_STALE_MS;
  }

  // E2: kicks off the initial background check (if the last one is missing
  // or older than 10 minutes and nothing else is running), then arms a
  // 30-minute repeat for as long as this page stays open.
  function scheduleAutoCheck() {
    if (!Store.isBusy() && isUpdatesCheckStale()) Actions.autoCheckForUpdates();
    clearInterval(autoCheckTimer);
    autoCheckTimer = setInterval(function () {
      if (Store.isBusy()) return;
      Actions.autoCheckForUpdates();
    }, AUTO_CHECK_INTERVAL_MS);
  }

  async function fetchPingInfo() {
    try {
      const res = await Api.ping();
      serverVersion = res.version;
      serverUptimeAtFetch = res.uptime;
      serverUptimeFetchedAt = Date.now();
      if (res.host) serverHost = res.host;
      markOnline(null);
    } catch (err) {
      markOnline(err);
    }
  }

  function currentUptime() {
    if (serverUptimeAtFetch === null) return null;
    return serverUptimeAtFetch + Math.floor((Date.now() - serverUptimeFetchedAt) / 1000);
  }

  // Round 5 fix: ticks the About panel's Server uptime line on its own short
  // timer, independent of reloadState's full-state diff (see the "changed"
  // comment there - ping-derived uptime was never part of it). Only touches
  // the DOM while Settings is the active view; a no-op otherwise.
  function startUptimeTicker() {
    clearInterval(uptimeTimer);
    uptimeTimer = setInterval(function () {
      if (Store.state.view === "settings") Views.settings.renderUptimeOnly();
    }, 5000);
  }

  // E7: '/' keyboard shortcut - focuses whichever search box belongs to the
  // view currently on screen; a no-op in Settings. On Get new addons, that's
  // the Wago search box on the Wago segment, or the CurseForge pane's own
  // toolbar search field on the CurseForge segment (Round 15).
  function focusCurrentSearch() {
    if (Store.state.view === "myaddons") { Utils.qs("#myaddons-search").focus(); return; }
    if (Store.state.view !== "browse") return;
    if (Store.state.browse.tab === "curseforge") { Utils.qs("#cf-pane-search").focus(); return; }
    Utils.qs("#browse-search").focus();
  }

  function wireGlobal() {
    Utils.qsa(".nav-item").forEach(function (btn) { btn.addEventListener("click", function () { switchView(btn.dataset.view); }); });

    Utils.qs("#btn-update-play").addEventListener("click", function () { Actions.updateAndPlay(); });
    Utils.qs("#btn-launch-wow").addEventListener("click", function () { Actions.launchOnly(); });

    Utils.qs("#drawer-backdrop").addEventListener("click", function () { Components.Drawer.close(); });
    Utils.qs("#drawer-close").addEventListener("click", function () { Components.Drawer.close(); });
    Utils.qsa(".drawer-tab").forEach(function (btn) { btn.addEventListener("click", function () { Components.Drawer.selectTab(btn.dataset.tab); }); });

    Utils.qs("#job-panel-collapse").addEventListener("click", function () { Components.JobPanel.toggleCollapse(); });
    Utils.qs("#job-panel-close").addEventListener("click", function () { Components.JobPanel.hide(); });

    Utils.qs("#dialog-backdrop").addEventListener("click", function () { Components.Dialogs.backdropClicked(); });
    Utils.qs("#add-addon-cancel").addEventListener("click", function () { Components.Dialogs.closeAdd(); });
    Utils.qs("#add-addon-form").addEventListener("submit", function (ev) {
      ev.preventDefault();
      Actions.submitAddInput(Utils.qs("#add-addon-input").value);
    });
    // Clear a stale validation error as soon as the user edits their input again.
    Utils.qs("#add-addon-input").addEventListener("input", function () { Utils.qs("#add-addon-error").hidden = true; });
    Utils.qs("#confirm-cancel").addEventListener("click", function () { Components.Dialogs.resolveConfirm(false); });
    Utils.qs("#confirm-ok").addEventListener("click", function () { Components.Dialogs.resolveConfirm(true); });

    // E18: Skip remembers itself per-browser (localStorage) so a plain
    // reload doesn't re-show the dialog every time - it's a one-time nudge,
    // not a persistent nag. Adopting anything, or the untracked folders
    // simply going away, both naturally stop it recurring too (the load-time
    // check re-scans and re-filters every time - see App.maybeShowWelcome).
    Utils.qs("#welcome-skip").addEventListener("click", function () {
      try { localStorage.setItem(WELCOME_SKIPPED_KEY, "1"); } catch (err) { /* best-effort only */ }
      Components.Dialogs.closeWelcome();
    });
    Utils.qs("#welcome-browse-link").addEventListener("click", function () {
      Components.Dialogs.closeWelcome();
      switchView("browse");
    });

    Utils.qs("#lightbox-close").addEventListener("click", function () { Components.Lightbox.close(); });
    Utils.qs("#lightbox").addEventListener("click", function (ev) { if (ev.target.id === "lightbox") Components.Lightbox.close(); });

    document.addEventListener("keydown", function (ev) {
      if (ev.key === "Escape") {
        // Ordered by actual stacking (highest z-index first) so Escape always
        // dismisses whatever is visually on top.
        if (Components.Dropdown.isOpen()) { Components.Dropdown.close(); return; }
        if (Components.Lightbox.isOpen()) { Components.Lightbox.close(); return; }
        if (Components.Dialogs.escPressed()) return;
        if (Components.Drawer.isOpen()) { Components.Drawer.close(); return; }
        return;
      }

      // E7: '/' focuses the current view's search box, 'r' re-runs Check for
      // updates - both suppressed while typing in a field, while a dialog has
      // focus, or with a modifier held (so e.g. Ctrl+R still refreshes the page).
      const target = ev.target;
      const tag = target && target.tagName;
      const isTyping = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || (target && target.isContentEditable);
      if (isTyping || ev.metaKey || ev.ctrlKey || ev.altKey || Components.Dialogs.isOpen()) return;

      if (ev.key === "/") {
        ev.preventDefault();
        focusCurrentSearch();
      } else if (ev.key === "r" || ev.key === "R") {
        if (!Store.isBusy()) Actions.checkForUpdates();
      }
    });

    // Deliberately NOT wired: a naive `pagehide` -> sendBeacon('/api/shutdown') also fires on
    // a plain reload/refresh (F5, Ctrl+R) or any in-tab navigation, not only on an actual
    // window close - there is no reliable way from script to tell those apart. That would kill
    // the local backend mid-reload, leaving the user staring at an unstyled page (the reload's
    // own request for style.css/app.js hits a server that's already gone) with no recovery
    // short of relaunching from the desktop shortcut. The server's own -IdleMinutes auto-exit
    // already reclaims the process once the app is left idle, so no shutdown-on-navigate
    // trigger is wired here at all.
  }

  // E18: when addons.json has 0 records, a scan may still find folders the
  // user already had in AddOns before ever opening the app (or where
  // install.ps1's own adoption was skipped) - offer to adopt them once,
  // rather than leaving the app looking empty when it doesn't have to.
  // Silently gives up on any failure (offline server, malformed scan JSON,
  // etc.) - this is a nicety, never allowed to block or error out the rest
  // of startup.
  async function maybeShowWelcome() {
    if (Store.state.addons.length !== 0) return;
    try {
      if (localStorage.getItem(WELCOME_SKIPPED_KEY) === "1") return;
    } catch (err) { /* storage unavailable - proceed as if never skipped */ }
    try {
      const scan = await Api.scan();
      const adoptable = (scan.untracked || []).filter(function (u) { return u.curseId || u.wagoId; });
      if (adoptable.length > 0) Components.Welcome.open(adoptable);
    } catch (err) { /* best-effort only */ }
  }

  async function init() {
    applyInitialViewFromQuery();
    wireGlobal();
    Views.myAddons.bindOnce();
    Views.browse.bindOnce();
    Views.settings.bindOnce();

    await fetchPingInfo();
    // Round 12 (E19b): now that serverHost is known (Host.isNative() reads
    // App.getServerHost()), fire the real initial theme report - Prefs's own
    // module-load-time applyTheme() call ran before that was possible and
    // no-opped (see Host's module comment and Prefs.applyTheme above).
    Host.reportTheme();
    // Round 15: same ordering requirement - Host.init()'s own {type:"hello"}
    // goes through post(), which is a no-op until isNative() can answer.
    // Wires the host->page message listener and asks the host to (re-)
    // announce host-ready, so Host.hasCfPane() has a real answer by the time
    // Views.browse first renders below.
    Host.init();
    // E19: fire-and-forget, like maybeShowWelcome below - loadProtocolStatus
    // catches its own errors (leaves Store.state.protocol null, rendered as
    // "Checking..."/"Unknown" by Components.ProtocolControl) and is a
    // nicety, never worth delaying the rest of startup for.
    Actions.loadProtocolStatus();
    await reloadState(false);
    await maybeShowWelcome();
    startIdlePolling();
    scheduleAutoCheck();
    startUptimeTicker();
  }

  return {
    switchView: switchView, renderCurrentView: renderCurrentView, renderChrome: renderChrome,
    onJobStarted: onJobStarted, attachToJob: attachToJob, reloadState: reloadState, init: init,
    getServerVersion: function () { return serverVersion; }, getServerUptime: currentUptime,
    getServerHost: function () { return serverHost; }
  };
})();

document.addEventListener("DOMContentLoaded", function () { App.init(); });
