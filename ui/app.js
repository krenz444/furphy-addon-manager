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
     App        - bootstrap, routing, polling, global event wiring
   ========================================================================== */

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

  // E15: a third theme value, "vaporwave", joins "light" as the only other
  // non-default option - anything else read back (missing key, corrupt
  // value, an older/newer build's value) still falls through to "dark".
  function isKnownTheme(v) { return v === "light" || v === "vaporwave" || v === "dark"; }

  function readTheme() {
    try { const v = localStorage.getItem(THEME_KEY); return isKnownTheme(v) ? v : "vaporwave"; } catch (e) { return "vaporwave"; }
  }
  function readDensity() {
    try { return localStorage.getItem(DENSITY_KEY) === "compact" ? "compact" : "comfortable"; } catch (e) { return "comfortable"; }
  }

  function applyTheme(value) { document.documentElement.dataset.theme = isKnownTheme(value) ? value : "vaporwave"; }
  function applyDensity(value) { document.documentElement.dataset.density = value === "compact" ? "compact" : "comfortable"; }

  function setTheme(value) {
    const v = isKnownTheme(value) ? value : "vaporwave";
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

  return { getTheme: readTheme, getDensity: readDensity, setTheme: setTheme, setDensity: setDensity };
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

  // E19: adFilter/hostWindow join the mock settings shape too, so Settings'
  // Browsing card and the protocol row are exercisable under ?mock=1.
  const mockSettings = { releaseType: 1, autoUpdateOnLaunch: true, cfApiKey: "", port: 47831, adFilter: false, hostWindow: null };
  let hasKey = false;
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

  const untracked = [
    { folder: "OldClique", title: "Clique", version: "60300-1", hasToc: true },
    { folder: "leftover_stuff", title: null, version: null, hasToc: false }
  ];

  const categories = [
    { id: 1001, name: "Combat", slug: "combat", iconUrl: "", parentCategoryId: 0 },
    { id: 1002, name: "Auction & Economy", slug: "auction-economy", iconUrl: "", parentCategoryId: 0 },
    { id: 1003, name: "Map & Minimap", slug: "map-minimap", iconUrl: "", parentCategoryId: 0 },
    { id: 1004, name: "UI Replacement", slug: "ui-replacement", iconUrl: "", parentCategoryId: 0 }
  ];

  function fakeMod(id, name, summary) {
    return {
      id: id, name: name, slug: name.toLowerCase().replace(/[^a-z0-9]+/g, "-"),
      summary: summary,
      downloadCount: Math.floor(Math.random() * 5000000) + 10000,
      logo: { thumbnailUrl: "", url: "" },
      authors: [{ name: "AddonAuthor" }],
      categories: [categories[id % categories.length]],
      dateModified: new Date(Date.now() - (id % 30) * 24 * 3600e3).toISOString(),
      dateReleased: new Date(Date.now() - (id % 30) * 24 * 3600e3).toISOString(),
      dateCreated: new Date(Date.now() - 900 * 24 * 3600e3).toISOString(),
      links: { websiteUrl: "https://www.curseforge.com/wow/addons/" + id, sourceUrl: "https://github.com/example/" + id, issuesUrl: "" },
      screenshots: [],
      latestFilesIndexes: [{ gameVersion: "12.0.0", fileId: id * 10, releaseType: 1, gameVersionTypeId: 517 }],
      allowModDistribution: true
    };
  }

  const browsePool = [];
  for (let i = 1; i <= 34; i++) {
    browsePool.push(fakeMod(90000 + i, "Sample Addon " + i, "A tidy little addon that does something useful for raiders and casuals alike."));
  }

  // E16 (keyless CurseForge enrichment): a small offline-catalogue-shaped
  // fixture pool, distinct from browsePool above (which represents the
  // OFFICIAL /api/cf/search results a keyed session sees) - exercises
  // /api/cf/browse and the "addon-radar"/"catalogue-only" drawer branches
  // under ?mock=1 with no key configured. 1521253 deliberately matches
  // BonusRollConfirm's real tracked projectId (see the addons fixture
  // above) so opening ITS row with no key exercises the enrichment path
  // for an already-tracked addon, not just a Browse card.
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

  function runJob(kind, params) {
    if (currentJob && currentJob.state === "running") return null;
    const id = String(nextJobId++);
    const job = {
      id: id, kind: kind, params: params || {}, state: "running",
      startedAt: new Date().toISOString(), finishedAt: null, exitCode: null,
      log: [], results: [], error: null
    };
    currentJob = job;
    jobs.unshift(job);
    if (jobs.length > 20) jobs.length = 20;

    const lines = jobLines(kind);
    let i = 0;
    const timer = setInterval(function () {
      if (i < lines.length) {
        job.log.push(lines[i]);
        i++;
        return;
      }
      clearInterval(timer);
      job.state = "done";
      job.finishedAt = new Date().toISOString();
      job.exitCode = 0;

      // E12: an addon's Mock-side key, matching Store.addonKey exactly - a
      // "sync"/"install"/"rollback" job's params always carry this form
      // (never a numeric-only id for a Wago row), so every id-matching
      // branch below compares against it rather than bare a.projectId.
      function mockKey(a) { return a.source === "wago" ? "wago:" + a.slug : a.projectId; }

      if (kind === "check") {
        updatesCheckedAt = new Date().toISOString();
        job.results = [
          { status: "Would-update", name: "Auctionator", version: "5.21.0", projectId: 68304, fileId: 112 },
          { status: "Would-update", name: "Bagnon", version: "10.9", projectId: 24560, fileId: 91 }
        ];
      } else if (kind === "sync") {
        const ids = params && params.ids;
        addons.forEach(function (a) {
          if (a.ignoreUpdates && !(params && params.force)) return;
          if (ids && ids.indexOf(mockKey(a)) === -1) return;
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
        lastRun = { timestamp: new Date().toISOString(), summary: job.results.length + " processed", rows: job.results.map(function (r) { return { status: r.status, name: r.name, version: r.version }; }) };
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
        lastRun = { timestamp: new Date().toISOString(), summary: job.results.length + " processed", rows: job.results.map(function (r) { return { status: r.status, name: r.name, version: r.version }; }) };
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
          lastRun = { timestamp: new Date().toISOString(), summary: job.results.length + " processed, then launched", rows: job.results.map(function (r) { return { status: r.status, name: r.name, version: r.version }; }) };
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
        lastRun = { timestamp: new Date().toISOString(), summary: job.results.length + " processed", rows: job.results.map(function (r) { return { status: r.status, name: r.name, version: r.version }; }) };
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
        lastRun = { timestamp: new Date().toISOString(), summary: job.results.length + " processed", rows: job.results.map(function (r) { return { status: r.status, name: r.name, version: r.version }; }) };
      }
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
        return { addons: addons.map(function (a) { return Object.assign({}, a); }), settings: currentSettings(), lastRun: lastRun, job: currentJob, updatesCheckedAt: updatesCheckedAt, clientBuild: "12.1.0.69587", clientInterface: 120100 };
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
        if (currentJob && currentJob.state === "running") return { __status: 409, error: "busy", jobId: currentJob.id };
        const job = runJob(body.kind, body);
        if (!job) return { __status: 409, error: "busy" };
        return { __status: 202, jobId: job.id };
      }
      const ignoreMatch = p.match(/^\/api\/addons\/(\d+)\/ignore$/);
      if (ignoreMatch && method === "POST") {
        const a = addons.find(function (x) { return x.projectId === Number(ignoreMatch[1]); });
        if (a) a.ignoreUpdates = !!body.ignore;
        return { addons: addons };
      }
      const unpinMatch = p.match(/^\/api\/addons\/(\d+)\/unpin$/);
      if (unpinMatch && method === "POST") {
        const a = addons.find(function (x) { return x.projectId === Number(unpinMatch[1]); });
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
            { name: "CurseForge API key", ok: true, detail: hasKey ? "Key is valid" : "No API key configured (optional)" },
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
        if (typeof body.cfApiKey === "string") { hasKey = body.cfApiKey.length > 0; mockSettings.cfApiKey = body.cfApiKey; }
        if (typeof body.port === "number") mockSettings.port = body.port;
        if (typeof body.adFilter === "boolean") mockSettings.adFilter = body.adFilter;
        if (body.hostWindow !== undefined && body.hostWindow !== null) mockSettings.hostWindow = body.hostWindow;
        return currentSettings();
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
      if (p === "/api/settings/test-key" && method === "POST") {
        const key = (body && body.cfApiKey) || mockSettings.cfApiKey;
        if (key && key.length >= 8) return { ok: true, message: "Key is valid." };
        return { ok: false, message: "Key rejected by CurseForge." };
      }
      // E16: /api/cf/enrich/*, /api/cf/browse and /api/cf/catalogue/refresh
      // are always keyless-capable (no 409 no-key gate) - exempted from the
      // blanket no-key 409 below, matching the real server (Handle-CfEnrich/
      // Handle-CfBrowse/Handle-CfCatalogueRefresh never check for a key at
      // all) and the client's own isKeylessCfPath exemption.
      const isKeylessCfMockPath = p.indexOf("/api/cf/enrich/") === 0 || p === "/api/cf/browse" || p === "/api/cf/catalogue/refresh";
      if (p.indexOf("/api/cf/") === 0 && !isKeylessCfMockPath) {
        if (!hasKey) return { __status: 409, error: "no-key" };
        // Round 6 fix: dev-only way to exercise a configured-but-rejected key
        // (real CurseForge 401/403) under ?mock=1 - same length-8 threshold
        // /api/settings/test-key above already uses, so saving a short key
        // in Settings and then visiting Browse reproduces the reported bug
        // (repeated /api/cf/* 403s) without any real network access.
        if (mockSettings.cfApiKey.length < 8) return { __status: 401, error: "unauthorized" };
      }
      // E16: keyless CurseForge enrichment - mirrors the real server's
      // /api/cf/enrich, /api/cf/browse and /api/cf/catalogue/refresh shapes
      // closely enough to exercise Browse's keyless-mode UI and the
      // drawer's cf-keyless branches (incl. a wago-match demo, id 654321)
      // without a real server. Reachable in mock mode regardless of
      // mockSettings.cfApiKey - see isKeylessCfMockPath above.
      const enrichMatch = p.match(/^\/api\/cf\/enrich\/(\d+)$/);
      if (enrichMatch) return mockCfEnrich(Number(enrichMatch[1]));
      if (p === "/api/cf/browse") {
        const bq = (q.get("q") || "").toLowerCase();
        const items = cfCatalogueMock.filter(function (e) { return !bq || e.name.toLowerCase().indexOf(bq) !== -1; }).map(function (e) {
          return { id: e.id, name: e.name, slug: e.slug, downloadCount: e.downloadCount, lastUpdated: e.lastUpdated, source: "catalogue", logoUrl: e.logoUrl };
        });
        return { items: items, catalogueAge: cfCatalogueMockFetchedAt, total: items.length };
      }
      if (p === "/api/cf/catalogue/refresh" && method === "POST") {
        cfCatalogueMockFetchedAt = new Date().toISOString();
        return { ok: true, fetchedAt: cfCatalogueMockFetchedAt, count: cfCatalogueMock.length, source: "instawow-data+strongbox" };
      }
      if (p === "/api/cf/categories") return { data: categories };
      if (p === "/api/cf/search") {
        const q2 = (q.get("q") || "").toLowerCase();
        let list = browsePool.filter(function (m) { return !q2 || m.name.toLowerCase().indexOf(q2) !== -1; });
        const index = Number(q.get("index") || 0);
        const pageSize = Number(q.get("pageSize") || 20);
        const page = list.slice(index, index + pageSize);
        return { data: page, pagination: { index: index, pageSize: pageSize, resultCount: page.length, totalCount: list.length } };
      }
      const modMatch = p.match(/^\/api\/cf\/mods\/(\d+)$/);
      if (modMatch && method === "GET") {
        const m = browsePool.find(function (x) { return x.id === Number(modMatch[1]); }) || addons.map(function (a) { return fakeMod(a.projectId, a.name, "A great addon."); }).find(function (x) { return x.id === Number(modMatch[1]); });
        if (!m) return { __status: 404, error: "not found" };
        return { data: m };
      }
      if (p === "/api/cf/mods" && method === "POST") {
        const ids = body.ids || [];
        const data = ids.map(function (id) {
          const fromPool = browsePool.find(function (x) { return x.id === id; });
          if (fromPool) return fromPool;
          const a = addons.find(function (x) { return x.projectId === id; });
          return fakeMod(id, a ? a.name : ("Addon " + id), "A great addon.");
        });
        return { data: data };
      }
      const descMatch = p.match(/^\/api\/cf\/mods\/(\d+)\/description$/);
      if (descMatch) return { data: "<p>This addon improves your World of Warcraft experience with <strong>lots</strong> of handy features.</p><ul><li>Fast</li><li>Lightweight</li><li>Configurable</li></ul><script>alert('should be stripped')<" + "/script>" };
      const filesCfMatch = p.match(/^\/api\/cf\/mods\/(\d+)\/files$/);
      if (filesCfMatch) {
        const pid2 = Number(filesCfMatch[1]);
        const a2 = addons.find(function (x) { return x.projectId === pid2; });
        const cfFiles = [];
        for (let i = 0; i < 6; i++) {
          const fid = (a2 ? a2.fileId : pid2 * 10) - i * 3 + (i === 0 ? 1 : 0);
          cfFiles.push({ id: fid, displayName: "v" + (6 - i) + ".0." + i, fileName: "file-" + fid + ".zip", fileDate: new Date(Date.now() - i * 10 * 24 * 3600e3).toISOString(), releaseType: i === 1 ? 2 : (i === 4 ? 3 : 1), gameVersions: ["12.0.0"], fileLength: 40000 + i * 9000, downloadCount: 500000 - i * 4000 });
        }
        return { data: cfFiles };
      }
      const changelogMatch = p.match(/^\/api\/cf\/mods\/(\d+)\/files\/(\d+)\/changelog$/);
      if (changelogMatch) return { data: "<p>Fixed a bug. Improved performance. Added support for the latest patch.</p>" };
      if (p === "/api/cf/resolve") {
        const url = q.get("url") || "";
        const slugMatch = url.match(/\/wow\/addons\/([a-z0-9-]+)/i);
        if (slugMatch) {
          const found = browsePool.find(function (x) { return x.slug === slugMatch[1]; }) || browsePool[0];
          return { projectId: found.id, name: found.name };
        }
        return { __status: 404, error: "not found" };
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
    // E13: checkAddonVersion is fixed mock data (read-only info, WTF\Config.wtf
    // - never set via PUT /api/settings, real or mock).
    return { releaseType: mockSettings.releaseType, autoUpdateOnLaunch: mockSettings.autoUpdateOnLaunch, port: mockSettings.port, hasApiKey: hasKey, apiKeyHint: hasKey ? mockSettings.cfApiKey.slice(-4) : "", addonsPath: "C:\\Program Files (x86)\\World of Warcraft\\_retail_\\Interface\\AddOns", wowRoot: "C:\\Program Files (x86)\\World of Warcraft\\_retail_", checkAddonVersion: "0", adFilter: mockSettings.adFilter, hostWindow: mockSettings.hostWindow };
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

  // E13: turns one addon's compat/tocInterfaces/latestGameVersions/
  // latestFileDate (all from /api/state, computed server-side) into a
  // {label, cls, title} triple - the chip text/color/tooltip shared by the
  // My Addons Compatibility column and the drawer Overview's compat section.
  // clientInterface comes from Store.state.clientInterface, passed in rather
  // than read directly so this stays a pure function like the rest of Utils.
  function compatDisplay(addon, clientInterface) {
    const compat = addon && addon.compat;
    const tocIfaces = (addon && addon.tocInterfaces) || [];
    const latestVersions = (addon && addon.latestGameVersions) || [];
    const bestOwnVersion = tocIfaces.length ? interfaceToVersion(tocIfaces[0]) : (latestVersions[0] || null);
    const clientVersion = interfaceToVersion(clientInterface);
    const clientMajorMinor = clientVersion ? clientVersion.split(".").slice(0, 2).join(".") : null;

    let label, cls;
    if (compat === "ok") {
      cls = "chip-success";
      label = "Built for " + (clientMajorMinor || "current patch");
    } else if (compat === "stale-minor") {
      cls = "chip-warning";
      label = "Older patch" + (bestOwnVersion ? " (" + bestOwnVersion + ")" : "");
    } else if (compat === "stale") {
      cls = "chip-danger";
      label = "Not for Midnight";
    } else {
      cls = "chip-muted";
      label = "Unknown";
    }

    const detailBits = [];
    detailBits.push(tocIfaces.length
      ? "Toc Interface: " + tocIfaces.map(function (n) { return interfaceToVersion(n) + " (" + n + ")"; }).join(", ")
      : "Toc Interface: none declared");
    if (latestVersions.length) {
      let s = "Newest known file supports: " + latestVersions.join(", ");
      // Round 9 fix: this is the FILE's own upload date (latestFileDate ==
      // the selected file's dateCreated, captured at sync time - see SPEC's
      // Sync-SingleAddon/Sync-SingleWagoAddon notes), not a timestamp of when
      // this app last polled CurseForge/Wago - "checked" implied the latter
      // and could read as claiming fresher data than it actually has.
      if (addon.latestFileDate) s += " (released " + fullDate(addon.latestFileDate) + ")";
      detailBits.push(s);
    }
    return { label: label, cls: cls, title: detailBits.join(" · ") };
  }

  return {
    qs: qs, qsa: qsa, el: el, icon: icon, escapeHtml: escapeHtml, debounce: debounce, relativeTime: relativeTime, fullDate: fullDate, formatBytes: formatBytes, formatNumber: formatNumber, releaseLabel: releaseLabel, releaseChipClass: releaseChipClass, colorForName: colorForName, firstLetter: firstLetter, normalizeId: normalizeId,
    interfaceToVersion: interfaceToVersion, compatDisplay: compatDisplay
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

  // Round 6 fix: every /api/cf/* call (LogoCache's batch logo fetch, Browse's
  // search/categories, the drawer's mod/description/changelog loaders,
  // Add-by-URL resolve) funnels through this one function, so a rejected key
  // is detected and reacted to in exactly one place instead of each call
  // site needing its own 401/403 handling. Live symptom this fixes: with a
  // rejected key configured, My Addons re-renders on every 800ms job poll,
  // each one calling LogoCache.ensure again for the same addons - without a
  // shared "already known rejected" flag that hammered POST /api/cf/mods
  // roughly once a second, forever.
  function isCfPath(path) { return path.indexOf("/api/cf/") === 0; }

  // E16: these three /api/cf/* routes are always keyless-capable - no 409
  // no-key gate, unlike every other /api/cf/* call above them - so a
  // rejected key must never short-circuit or flag them the way it does the
  // key-gated ones (isCfPath alone can't tell the two apart, since they
  // share the same URL prefix).
  function isKeylessCfPath(path) {
    return path.indexOf("/api/cf/enrich/") === 0 || path.indexOf("/api/cf/browse") === 0 || path.indexOf("/api/cf/catalogue/") === 0;
  }

  function noteCfResult(path, status) {
    if (!isCfPath(path) || isKeylessCfPath(path)) return;
    if (status === 401 || status === 403) {
      if (Store.state.cfKeyRejected) return; // already known - never a second banner/toast for the same rejection
      Store.state.cfKeyRejected = true;
      Components.Toast.show("Your CurseForge API key was rejected. Fix it in Settings.", "error");
    } else if (status < 400 && Store.state.cfKeyRejected) {
      // Cleared by a later call succeeding (e.g. the key was fixed in another
      // tab/session) - Actions.saveSettings also clears this on any settings
      // save made from this tab, so both paths documented in the fix note apply.
      Store.state.cfKeyRejected = false;
    }
  }

  async function request(method, path, body) {
    if (isCfPath(path) && !isKeylessCfPath(path) && Store.state.cfKeyRejected) {
      // A rejected key fails every /api/cf/* call the exact same way - stop
      // making the call at all (no fetch, no Mock round-trip) rather than
      // rediscovering the same 401/403 over and over.
      throw ApiError(403, { error: "key-rejected" });
    }

    if (Mock.enabled) {
      const result = await Mock.handle(method, path, body);
      const status = (result && result.__status) || 200;
      const data = result ? Object.assign({}, result) : {};
      delete data.__status;
      noteCfResult(path, status);
      if (status >= 400) throw ApiError(status, data);
      return data;
    }

    let res;
    try {
      res = await fetch(path, {
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
    noteCfResult(path, res.status);

    if (!res.ok) throw ApiError(res.status, data || {});
    return data;
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

    postJob: function (kind, params) { return request("POST", "/api/jobs", Object.assign({ kind: kind }, params || {})); },
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
    testKey: function (cfApiKey) { return request("POST", "/api/settings/test-key", cfApiKey === undefined ? {} : { cfApiKey: cfApiKey }); },
    getDiagnostics: function () { return request("GET", "/api/diagnostics"); },

    // E19 (script itself is E17's, unchanged) - the curseforge:// install-
    // link handler toggle in Settings > Game and the Browse > CurseForge pane.
    protocolStatus: function () { return request("GET", "/api/protocol/status"); },
    protocolRegister: function () { return request("POST", "/api/protocol/register", {}); },
    protocolUnregister: function () { return request("POST", "/api/protocol/unregister", {}); },

    cfSearch: function (params) { return request("GET", "/api/cf/search" + qs(params)); },
    cfCategories: function () { return request("GET", "/api/cf/categories"); },
    cfMod: function (id) { return request("GET", "/api/cf/mods/" + id); },
    cfMods: function (ids) { return request("POST", "/api/cf/mods", { ids: ids }); },
    cfDescription: function (id) { return request("GET", "/api/cf/mods/" + id + "/description"); },
    cfFiles: function (id, params) { return request("GET", "/api/cf/mods/" + id + "/files" + qs(params)); },
    cfChangelog: function (id, fileId) { return request("GET", "/api/cf/mods/" + id + "/files/" + fileId + "/changelog"); },
    cfResolve: function (url) { return request("GET", "/api/cf/resolve" + qs({ url: url })); },

    // E16: always keyless-capable (no 409 no-key gate) - the drawer/Browse
    // call these directly instead of the key-gated cfMod/cfSearch calls
    // above when no key is configured; see isKeylessCfPath just above.
    cfEnrich: function (id) { return request("GET", "/api/cf/enrich/" + id); },
    cfBrowse: function (params) { return request("GET", "/api/cf/browse" + qs(params)); },
    cfCatalogueRefresh: function () { return request("POST", "/api/cf/catalogue/refresh", {}); },

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

  const state = {
    view: "myaddons",          // 'myaddons' | 'browse' | 'settings'
    online: null,               // null = unknown yet, else true/false
    loadingState: true,
    stateError: null,

    addons: [],
    settings: null,
    // Round 6 fix: sticky "the saved CurseForge key is being rejected"
    // signal - set by Api.request the moment any /api/cf/* call comes back
    // 401/403, read by LogoCache (stop fetching logos) and Views.browse
    // (show a dedicated panel instead of the search UI). Cleared by
    // Actions.saveSettings on any settings save, or by a later /api/cf/*
    // call that succeeds.
    cfKeyRejected: false,
    lastRun: null,
    job: null,
    jobLabel: null,        // client-chosen human title for the job panel, set by Actions.startJob
    updatesCheckedAt: null,
    // E13 (compatibility audit): the WoW client's own build string/Interface
    // number, from /api/state (server reads .build.info once at startup).
    clientBuild: null,
    clientInterface: null,

    myaddonsSearch: "",
    myaddonsFilter: "all",   // 'all' | 'updates' | 'pinned' | 'ignored' | 'failed' | 'missingdeps'
    myaddonsSort: loadSortPref(),   // {column: 'name'|'installed'|'latest'|'status'|'updated', dir: 'asc'|'desc'}
    myaddonsSelection: [],   // E11: array of checked projectIds, driving the checkbox column/selection bar. Not persisted - resets on reload like search/filter.

    browse: {
      // E12: which marketplace Browse is currently showing - a top-level
      // switch, not per-view state, since switching sources resets the
      // whole result set/pagination the same way changing the query would.
      source: "curseforge",   // 'curseforge' | 'wago'
      loaded: false,
      loading: false,
      error: null,
      query: "",
      categoryId: "",
      sortField: 2,
      sort: "popular",         // Wago's own sort param (SPEC: e.g. popular/updated/downloads/name)
      index: 0,
      page: 1,                 // Wago pagination is page-based, not index/pageSize
      pageSize: 20,
      results: [],
      totalCount: 0,
      lastPage: 1,
      categories: [],
      categoriesLoading: false
    },

    drawer: {
      open: false,
      // E12: projectId is now the addon's general KEY - a number for
      // CurseForge (unchanged), or the string "wago:<slug>" for Wago (see
      // Store.addonKey / Utils.normalizeId). source records which so every
      // drawer render function knows which branch to take.
      projectId: null,
      source: "curseforge",   // 'curseforge' | 'wago'
      slug: null,
      tracked: false,        // true when this project has a local addon record
      tab: "overview",
      lastKnownFileId: null,  // addon.fileId as of the last open()/refresh() - lets refresh() detect an update
      mod: null,              // full CF mod details, once fetched
      modLoading: false,
      modError: null,
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
    protocolBusy: false        // true while a register/unregister call is in flight (disables the toggle)
  };

  function set(patch) { Object.assign(state, patch); }

  // E7: sets and persists the My Addons column sort so it survives a reload.
  function setMyAddonsSort(sort) {
    state.myaddonsSort = sort;
    try { localStorage.setItem(SORT_PREF_KEY, JSON.stringify(sort)); } catch (e) { /* storage unavailable - sort still applies for this load */ }
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

  function lastRunStatusFor(name) {
    if (!state.lastRun || !state.lastRun.rows) return null;
    const row = state.lastRun.rows.filter(function (r) { return r.name === name; }).pop();
    return row ? row.status : null;
  }

  // Session-lifetime cache of CurseForge mod details, populated by any
  // successful cfMod/cfMods call. Lets Overview show "the summary if known"
  // even without a key (e.g. a key was present earlier this session), and
  // saves refetching mod details the logo prefetch already pulled down.
  const modCache = {};
  function cacheMods(list) { (list || []).forEach(function (m) { if (m && m.id) modCache[m.id] = m; }); }
  function getCachedMod(id) { return modCache[Number(id)] || null; }

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
    state: state, set: set, setMyAddonsSort: setMyAddonsSort, addonKey: addonKey, addonByProjectId: addonByProjectId, jobActingOn: jobActingOn, isBusy: isBusy, updatesCount: updatesCount, lastRunStatusFor: lastRunStatusFor, cacheMods: cacheMods, getCachedMod: getCachedMod,
    isSelected: isSelected, toggleSelected: toggleSelected, selectIds: selectIds, deselectIds: deselectIds, clearSelection: clearSelection, selectedAddons: selectedAddons, pruneSelection: pruneSelection, mergeAddons: mergeAddons
  };
})();

/* ==========================================================================
   LogoCache - localStorage-backed cache of addon logo thumbnails, keyed by
   CurseForge project id, refreshed at most once per 24h and only ever
   populated when a key is configured (logos come from a keyed batch call).
   ========================================================================== */
const LogoCache = (function () {
  const KEY = "addonSync.logoCache.v1";
  const TTL_MS = 24 * 3600 * 1000;
  // Round 6 fix: "never re-request the same failed logo batch more than once
  // per 10 minutes" - independent of (and in addition to) the cfKeyRejected
  // short-circuit below, so a transient network/500 failure also backs off
  // instead of retrying on every My Addons/Browse render.
  const FAILURE_BACKOFF_MS = 10 * 60 * 1000;
  let cache = null;
  const inFlight = new Set();
  const failedAt = new Map(); // projectId -> ms timestamp of its last failed fetch attempt (in-memory only, resets on reload)

  function load() {
    if (cache) return cache;
    try { cache = JSON.parse(localStorage.getItem(KEY) || "{}"); } catch (e) { cache = {}; }
    if (!cache || typeof cache !== "object") cache = {};
    return cache;
  }
  function persist() { try { localStorage.setItem(KEY, JSON.stringify(cache)); } catch (e) { /* storage unavailable/full - degrade to in-memory only */ } }

  function get(projectId) {
    const c = load();
    const rec = c[projectId];
    if (!rec || Date.now() - rec.ts > TTL_MS) return null;
    return rec.url || null;
  }

  // Fetches logos for any of `projectIds` that are missing/stale, then calls
  // onUpdated() once. No-ops entirely when no API key is configured.
  async function ensure(projectIds, onUpdated) {
    if (!Store.state.settings || !Store.state.settings.hasApiKey) return;
    // Round 6 fix: a rejected key fails every /api/cf/* call the same way -
    // return immediately (no batch built, no Api call) instead of rediscovering
    // that on every render while a job is polling (previously this repeated
    // roughly once a second - see Api.request's own note on the same fix).
    if (Store.state.cfKeyRejected) return;
    const c = load();
    const now = Date.now();
    const need = [];
    (projectIds || []).forEach(function (raw) {
      const id = Number(raw);
      if (!id || inFlight.has(id)) return;
      const rec = c[id];
      if (rec && now - rec.ts <= TTL_MS) return;
      const failTs = failedAt.get(id);
      if (failTs && now - failTs < FAILURE_BACKOFF_MS) return;
      need.push(id);
    });
    if (!need.length) return;
    need.forEach(function (id) { inFlight.add(id); });
    try {
      for (let i = 0; i < need.length; i += 50) {
        const chunk = need.slice(i, i + 50);
        const res = await Api.cfMods(chunk);
        const data = (res && res.data) || [];
        Store.cacheMods(data);
        data.forEach(function (mod) {
          c[mod.id] = { url: (mod.logo && (mod.logo.thumbnailUrl || mod.logo.url)) || "", ts: Date.now() };
          failedAt.delete(mod.id);
        });
        // Also remember ids that didn't come back, so a missing mod isn't refetched every render.
        chunk.forEach(function (id) { if (!c[id]) c[id] = { url: "", ts: Date.now() }; });
      }
      persist();
      if (onUpdated) onUpdated();
    } catch (e) {
      // network/key issue - fallback letter avatars remain, silently. Mark
      // this whole batch as just-failed so the `need` filtering above skips
      // it for the next 10 minutes rather than retrying on the next render.
      const ts = Date.now();
      need.forEach(function (id) { failedAt.set(id, ts); });
    } finally {
      need.forEach(function (id) { inFlight.delete(id); });
    }
  }

  return { get: get, ensure: ensure };
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
    if (openName === name) openName = null;
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
    okBtn.className = "btn " + (opts.danger === false ? "btn-accent" : "btn-danger");
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
    adoptBtn.textContent = "Adopt all (" + items.length + ")";
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
    if (currentMenu) { currentMenu.remove(); currentMenu = null; currentAnchor = null; }
    window.removeEventListener("scroll", reposition, true);
    window.removeEventListener("resize", reposition);
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

  // items: [{label, icon, danger, disabled, title, onSelect}] | null for a separator
  function open(anchorEl, items) {
    if (currentAnchor === anchorEl) { close(); return; }
    close();
    const menu = Utils.el("div", { class: "dropdown-menu", role: "menu" }, items.map(function (item) {
      if (item === null) return Utils.el("div", { class: "dropdown-sep" });
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
    reposition();
    window.addEventListener("scroll", reposition, true);
    window.addEventListener("resize", reposition);
  }

  document.addEventListener("click", function (ev) {
    if (currentMenu && !currentMenu.contains(ev.target) && ev.target !== currentAnchor && !(currentAnchor && currentAnchor.contains(ev.target))) close();
  });

  function isOpen() { return !!currentMenu; }

  return { open: open, close: close, isOpen: isOpen };
})();

/* ---------- Status chip for an addon row/card ---------- */
Components.Chip = (function () {
  function forAddon(addon) {
    if (Store.jobActingOn(addon.projectId)) return build("Installing…", "chip-busy");
    if (addon.pinnedFileId !== null && addon.pinnedFileId !== undefined) {
      // E1 (round 2 fix): a pin left behind by a rollback gets a tooltip
      // explaining why it stopped updating, instead of reading like an
      // ordinary manual pin. This can NOT be detected from pinnedFileId vs.
      // previousFileId: Invoke-RollbackForRecord SWAPS fileId<->previousFileId
      // (so a second rollback can undo the first), which means right after a
      // real rollback pinnedFileId (the just-restored file) and previousFileId
      // (the file rolled back FROM) are two DIFFERENT values by construction -
      // the old `pinnedFileId === previousFileId` check could never be true.
      // Worse, the {pinnedFileId, previousFileId} shape left by a rollback is
      // indistinguishable from a plain "Install this older version" from the
      // Versions tab (both pin to a fileId that differs from previousFileId),
      // so no combination of those two fields can serve as the signal. The
      // last completed job's status for this addon is the only rollback-only
      // signal available client-side - same precedent as the "Failed" chip
      // below, which is also derived from lastRunStatusFor rather than a
      // stored record field.
      const rolledBack = Store.lastRunStatusFor(addon.name) === "Rolled-back";
      // Round 5 fix: an addon can be pinned AND have ignoreUpdates set at the
      // same time (e.g. "Pin current version" on an already-ignored addon) -
      // this branch returns before the Ignored check below ever runs, so that
      // second state had no chip of its own and was otherwise only visible via
      // the kebab menu wording or the Ignored filter-chip count. Folded into
      // the same tooltip the rollback signal above already uses rather than
      // adding a second chip/DOM element for one more boolean.
      const notes = [];
      if (rolledBack) notes.push("Rolled back — unpin to resume updates.");
      if (addon.ignoreUpdates) notes.push("Updates are also ignored for this addon.");
      return build("Pinned · " + addon.version, "chip-info", notes.length ? notes.join(" ") : null);
    }
    if (addon.ignoreUpdates) return build("Ignored", "chip-muted");
    if (addon.updateAvailable) return build("Update available", "chip-warning");
    if (Store.lastRunStatusFor(addon.name) === "Failed") return build("Failed", "chip-danger");
    return build("Up to date", "chip-success");
  }

  function build(label, cls, title) {
    return Utils.el("span", { class: "chip " + cls, title: title || null }, [Utils.el("span", { class: "chip-dot" }), label]);
  }

  // E13 (compatibility audit): the My Addons Compatibility column's chip -
  // Utils.compatDisplay does the actual label/color/tooltip computation
  // (shared with the drawer Overview's compat section), this just builds it.
  function forCompat(addon) {
    const info = Utils.compatDisplay(addon, Store.state.clientInterface);
    return build(info.label, info.cls, info.title);
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

  return { forAddon: forAddon, build: build, forCompat: forCompat, forJobStatus: forJobStatus };
})();

/* ---------- Addon/mod logo (image if known, else an initial on a coloured tile) ---------- */
Components.Logo = (function () {
  function build(info, size) {
    size = size || 40;
    const url = info.thumbnailUrl || LogoCache.get(info.projectId);
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
    Utils.qs("#lightbox-img").src = url;
    Utils.qs("#lightbox").hidden = false;
  }
  function close() {
    Utils.qs("#lightbox").hidden = true;
    Utils.qs("#lightbox-img").src = "";
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
    // E16: a CurseForge-sourced drawer opened with no API key configured
    // gets its own 'cf-keyless' source, distinct from the keyed
    // 'curseforge' one - every render function below reads Store.state.drawer.enrich
    // instead of .mod for that state, via /api/cf/enrich (see loadEnrich).
    const hasKey = !!(Store.state.settings && Store.state.settings.hasApiKey);
    const source = isWago ? "wago" : (hasKey ? "curseforge" : "cf-keyless");
    Store.set({
      drawer: {
        open: true, projectId: key, source: source, slug: slug, tracked: !!addon,
        tab: opts.tab || "overview",
        lastKnownFileId: addon ? addon.fileId : null,
        mod: isWago ? null : Store.getCachedMod(key), modLoading: false, modError: null,
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
        // null/unused for 'curseforge'/'wago').
        enrich: null, enrichLoading: false, enrichError: null
      }
    });
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
    else if (source === "cf-keyless") { loadEnrich(); }
    else if (hasKey && !Store.state.drawer.mod) { loadMod(); }
  }

  function close() {
    Utils.qs("#drawer-backdrop").classList.remove("is-visible");
    Utils.qs("#drawer").classList.remove("is-open");
    Utils.qs("#drawer").setAttribute("aria-hidden", "true");
    setTimeout(function () { Utils.qs("#drawer-backdrop").hidden = true; Utils.qs("#drawer").hidden = true; }, 150);
    Store.state.drawer.open = false;
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

  async function loadMod() {
    const pid = projectId();
    Store.state.drawer.modLoading = true;
    try {
      const res = await Api.cfMod(pid);
      Store.cacheMods([res.data]);
      if (projectId() !== pid) return;
      Store.state.drawer.mod = res.data;
      renderHeader();
      if (Store.state.drawer.tab === "screenshots") renderScreenshots();
    } catch (err) {
      if (projectId() === pid) Store.state.drawer.modError = err;
    } finally {
      if (projectId() === pid) Store.state.drawer.modLoading = false;
    }
  }

  // E12: Wago counterpart to loadMod - fetches addon/description/metadata
  // from the server's keyless Wago proxy. Unlike CF, this never needs an
  // API key check.
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
    const mod = d.mod;
    // E16: 'cf-keyless' has no mod (never fetched without a key) - falls
    // back to the /api/cf/enrich response's own name/logo/downloads/date
    // instead. Never set for a keyed 'curseforge' drawer (d.enrich stays
    // null there), so this changes nothing about the pre-E16 keyed path.
    const enrich = d.enrich;
    const name = mod ? mod.name : ((enrich && enrich.name) ? enrich.name : (addon ? addon.name : ("Project " + d.projectId)));
    // Round 4 fix: list every author CurseForge returns ("by A, B"), not just
    // the first - mod.authors is commonly more than one name.
    const author = (mod && mod.authors && mod.authors.length ? mod.authors.map(function (a) { return a.name; }).join(", ") : null) || (addon ? addon.author : null);
    const logoUrl = mod && mod.logo ? (mod.logo.thumbnailUrl || mod.logo.url) : (enrich ? enrich.logoUrl : null);

    const children = [
      Utils.el("div", { class: "drawer-header-top" }, [
        Components.Logo.build({ projectId: d.projectId, name: name, thumbnailUrl: logoUrl }, 56),
        Utils.el("div", {}, [
          Utils.el("div", { class: "drawer-title" }, [name]),
          author ? Utils.el("div", { class: "drawer-author" }, ["by " + author]) : null
        ])
      ])
    ];

    if (mod) {
      const meta = [
        Utils.el("span", {}, [Utils.formatNumber(mod.downloadCount) + " downloads"]),
        mod.dateModified ? Utils.el("span", { title: Utils.fullDate(mod.dateModified) }, ["updated " + Utils.relativeTime(mod.dateModified)]) : null
      ];
      // Round 4 fix: a lightweight "Popular" badge computed from data already
      // in the CF mod response (no featured/popularity flag exists in the
      // documented mod shape, so this uses a download-count threshold instead
      // of fabricating one) - flagged in the SPEC section 3 stats-display ask.
      if (mod.downloadCount >= 1000000) meta.push(Components.Chip.build("Popular", "chip-warning"));
      children.push(Utils.el("div", { class: "drawer-meta" }, meta));
      if (mod.categories && mod.categories.length) {
        children.push(Utils.el("div", { class: "drawer-cats" }, mod.categories.map(function (c) { return Utils.el("span", { class: "browse-card-cat" }, [c.name]); })));
      }
    } else if (enrich) {
      const meta = [];
      if (enrich.downloadCount != null) meta.push(Utils.el("span", {}, [Utils.formatNumber(enrich.downloadCount) + " downloads"]));
      if (enrich.lastUpdated) meta.push(Utils.el("span", { title: Utils.fullDate(enrich.lastUpdated) }, ["updated " + Utils.relativeTime(enrich.lastUpdated)]));
      if (meta.length) children.push(Utils.el("div", { class: "drawer-meta" }, meta));
      // E16: a small provenance pill so it's always visually clear whether
      // this is CurseForge's own data (official-api - no pill needed) or a
      // third party's best-effort mirror.
      const pillText = enrich.source === "addon-radar" ? "via addon-radar" : (enrich.source === "wago-match" ? "via Wago Addons" : (enrich.source === "catalogue-only" ? "via catalogue" : null));
      if (pillText) children.push(Utils.el("span", { class: "source-pill" }, [pillText]));
    } else if (d.enrichLoading) {
      children.push(Utils.el("div", { class: "muted-text" }, ["Loading…"]));
    } else if (d.enrichError) {
      children.push(Utils.el("div", { class: "muted-text" }, ["Couldn't load addon details (" + describeError(d.enrichError) + ")."]));
    }

    const links = [];
    if (mod && mod.links && mod.links.websiteUrl) links.push(Utils.el("a", { class: "btn btn-outline", href: mod.links.websiteUrl, target: "_blank", rel: "noopener noreferrer" }, [Utils.icon("external"), "Website"]));
    if (mod && mod.links && mod.links.sourceUrl) links.push(Utils.el("a", { class: "btn btn-outline", href: mod.links.sourceUrl, target: "_blank", rel: "noopener noreferrer" }, [Utils.icon("external"), "Source"]));
    links.push(Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.openOnCurseForge(d.projectId, mod ? mod.slug : d.slug); } }, [Utils.icon("external"), "CurseForge"]));
    children.push(Utils.el("div", { class: "drawer-links" }, links));

    // E12: the tracked record's own toc-parsed wagoId reveals a CurseForge
    // addon is ALSO on Wago - offers a one-job reinstall from there instead
    // of leaving the reader to go find and re-add it by hand.
    if (addon && addon.wagoId) {
      children.push(Utils.el("div", { class: "drawer-crosssource" }, [Actions.switchSourceButton(addon, "wago", addon.wagoId)]));
    }

    children.push(Utils.el("div", { class: "drawer-primary-action" }, [primaryActionButton(addon, mod)]));

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

  function primaryActionButton(addon, mod) {
    const d = Store.state.drawer;
    const pid = d.projectId;
    if (Store.jobActingOn(pid)) return Utils.el("button", { type: "button", class: "btn btn-accent", disabled: true }, ["Installing…"]);
    if (addon) {
      if (addon.updateAvailable) return Utils.el("button", { type: "button", class: "btn btn-accent", onclick: function () { Actions.updateNow(pid); } }, ["Update now"]);
      return Utils.el("button", { type: "button", class: "btn btn-outline", disabled: true }, [Utils.icon("check-circle"), "Installed"]);
    }
    if (d.source === "wago") {
      return Utils.el("button", { type: "button", class: "btn btn-accent", onclick: function () { Actions.installLatestWago(d.slug, (d.wagoAddon && d.wagoAddon.addon) ? d.wagoAddon.addon.display_name : null); } }, ["Install"]);
    }
    return Utils.el("button", { type: "button", class: "btn btn-accent", onclick: function () { Actions.installLatest(pid, mod ? mod.name : null); } }, ["Install"]);
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

  async function renderOverview() {
    const panel = Utils.qs("#drawer-panel-overview");
    if (Store.state.drawer.source === "wago") { renderWagoOverview(); return; }
    if (Store.state.drawer.source === "cf-keyless") { renderKeylessOverview(); return; }
    const hasKey = !!(Store.state.settings && Store.state.settings.hasApiKey);
    panel.textContent = "";
    if (!hasKey) {
      const cached = Store.getCachedMod(projectId());
      if (cached && cached.summary) panel.appendChild(Utils.el("p", { class: "rich-content" }, [cached.summary]));
      panel.appendChild(Utils.el("div", { class: "nokey-inline" }, [Utils.icon("warning"), Utils.el("span", {}, ["Add a free CurseForge API key in Settings to see descriptions, changelogs and screenshots."])]));
      renderCompat(panel);
      renderDependencies(panel);
      return;
    }
    panel.appendChild(Utils.el("div", { class: "rich-content" }, ["Loading description…"]));
    const pid = projectId();
    try {
      const res = await Api.cfDescription(pid);
      if (projectId() !== pid || Store.state.drawer.tab !== "overview") return;
      panel.textContent = "";
      const holder = Utils.el("div", { class: "rich-content" });
      panel.appendChild(holder);
      Sanitize.render(holder, res.data);
      renderCompat(panel);
      renderDependencies(panel);
    } catch (err) {
      if (projectId() !== pid) return;
      panel.textContent = "";
      panel.appendChild(Utils.el("p", { class: "rich-content" }, ["Couldn't load the description (" + describeError(err) + ")."]));
      renderCompat(panel);
      renderDependencies(panel);
    }
  }

  // E16: Overview for a 'cf-keyless' drawer (a CurseForge-sourced addon,
  // opened with no API key configured) - renders per d.enrich.source.
  // wago-match reuses E12's Wago overview render VERBATIM (it reads only
  // d.wagoAddon/d.wagoAddonLoading/d.wagoAddonError, never d.slug) plus a
  // small attribution note; addon-radar renders its own HTML description
  // (through the same Sanitize.render pipeline the official CurseForge
  // description already uses - description_html is real HTML, not
  // markdown, so it does NOT go through the Markdown module); catalogue-only
  // (or no match at all) shows the existing no-key placeholder plus a
  // "View on CurseForge.com" link, since that page is not itself
  // Cloudflare-blocked the way this app's own scripted requests are.
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
      panel.appendChild(Utils.el("p", { class: "muted-text source-note" }, ["(via addon-radar.com, an independent WoW addon index)"]));
    } else {
      if (d.enrich.summary) panel.appendChild(Utils.el("p", { class: "rich-content" }, [d.enrich.summary]));
      panel.appendChild(Utils.el("div", { class: "nokey-inline" }, [Utils.icon("warning"), Utils.el("span", {}, ["Add a free CurseForge API key in Settings to see descriptions, changelogs and screenshots."])]));
      panel.appendChild(Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.openOnCurseForge(d.projectId, d.enrich.slug || d.slug); } }, [Utils.icon("external"), "View on CurseForge.com"]));
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
    const info = Utils.compatDisplay(addon, Store.state.clientInterface);
    const section = Utils.el("div", { class: "compat-section" }, [
      Utils.el("div", { class: "deps-heading" }, ["Compatibility"]),
      Utils.el("div", { class: "compat-row" }, [
        Components.Chip.build(info.label, info.cls),
        Utils.el("span", { class: "muted-text compat-detail" }, [info.title])
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
        row.push(Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { Actions.searchDependency(name); } }, [Utils.icon("search"), "Search CurseForge"]));
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
      Utils.el("thead", {}, [Utils.el("tr", {}, ["Version", "Channel", "Retail Patches", "Date", "", ""].map(function (h) { return Utils.el("th", {}, [h]); }))]),
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
    const panel = Utils.qs("#drawer-panel-changelog");
    if (Store.state.drawer.source === "wago") { renderWagoChangelog(); return; }
    if (Store.state.drawer.source === "cf-keyless") { renderKeylessChangelog(); return; }
    const hasKey = !!(Store.state.settings && Store.state.settings.hasApiKey);
    panel.textContent = "";
    if (!hasKey) {
      panel.appendChild(Utils.el("div", { class: "nokey-inline" }, [Utils.icon("warning"), Utils.el("span", {}, ["Add a free CurseForge API key in Settings to see changelogs."])]));
      return;
    }
    const d = Store.state.drawer;
    if (!d.files) {
      panel.appendChild(Utils.el("div", { class: "rich-content" }, ["Loading versions…"]));
      if (!d.filesLoading) renderVersions(); // shares the Versions tab's lazy loader; harmless to also paint the hidden panel
      return;
    }
    const select = Utils.el("select", { class: "select", onchange: function (ev) { loadChangelogFor(Number(ev.target.value)); } },
      d.files.map(function (f) { return Utils.el("option", { value: f.id }, [f.displayName || f.version || f.fileName]); }));
    panel.appendChild(Utils.el("div", { class: "changelog-select-row" }, [Utils.el("span", { class: "muted-text" }, ["Version:"]), select]));
    const body = Utils.el("div", { class: "rich-content", id: "changelog-body" }, ["Select a version to view its changelog."]);
    panel.appendChild(body);
    if (d.files.length) {
      const startId = d.changelogFileId || d.files[0].id;
      select.value = String(startId);
      loadChangelogFor(Number(startId));
    }
  }

  async function loadChangelogFor(fileId) {
    const pid = projectId();
    const d = Store.state.drawer;
    d.changelogFileId = fileId;
    const body = Utils.qs("#changelog-body");
    if (body) body.textContent = "Loading changelog…";
    try {
      const res = await Api.cfChangelog(pid, fileId);
      if (projectId() !== pid || d.changelogFileId !== fileId) return;
      const target = Utils.qs("#changelog-body");
      if (!target) return;
      target.textContent = "";
      Sanitize.render(target, res.data);
    } catch (err) {
      if (projectId() !== pid || d.changelogFileId !== fileId) return;
      const target = Utils.qs("#changelog-body");
      if (target) target.textContent = "Couldn't load the changelog (" + describeError(err) + ").";
    }
  }

  // E16: Changelog for a 'cf-keyless' drawer. wago-match reuses E12's
  // existing Wago changelog tab exactly (per-release markdown changelog) -
  // renderWagoChangelog only reads d.wagoReleases/d.changelogFileId, never
  // d.slug, so pre-populating d.wagoReleases via loadCfKeylessWagoReleases
  // (keyed by d.enrich.wagoSlug) and then calling it directly is enough.
  // Every other case (addon-radar, catalogue-only, no match at all) shows a
  // dedicated empty state - SPEC's own investigation found no keyless
  // source anywhere that exposes CurseForge changelog text, so this is a
  // permanent gap, never a blank tab or a stuck spinner.
  function renderKeylessChangelog() {
    const panel = Utils.qs("#drawer-panel-changelog");
    const d = Store.state.drawer;

    if (d.enrich && d.enrich.source === "wago-match") {
      if (!d.wagoReleases && !d.wagoReleasesLoading) loadCfKeylessWagoReleases();
      renderWagoChangelog();
      return;
    }

    panel.textContent = "";
    panel.appendChild(Utils.el("div", { class: "nokey-inline" }, [
      Utils.icon("warning"),
      Utils.el("span", {}, ["Changelogs for CurseForge addons need a free API key (or a matching Wago Addons listing, which this one doesn't have)."])
    ]));
    panel.appendChild(Utils.el("div", { class: "btn-row" }, [
      Utils.el("button", { type: "button", class: "btn btn-outline", onclick: function () { App.switchView("settings"); } }, ["Go to Settings"]),
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
    const panel = Utils.qs("#drawer-panel-screenshots");
    if (Store.state.drawer.source === "wago") { renderWagoScreenshots(); return; }
    if (Store.state.drawer.source === "cf-keyless") { renderKeylessScreenshots(); return; }
    const hasKey = !!(Store.state.settings && Store.state.settings.hasApiKey);
    panel.textContent = "";
    if (!hasKey) {
      panel.appendChild(Utils.el("div", { class: "nokey-inline" }, [Utils.icon("warning"), Utils.el("span", {}, ["Add a free CurseForge API key in Settings to see screenshots."])]));
      return;
    }
    const mod = Store.state.drawer.mod;
    if (!mod) {
      panel.appendChild(Utils.el("p", { class: "rich-content" }, ["Loading…"]));
      if (!Store.state.drawer.modLoading) loadMod();
      return;
    }
    const shots = mod.screenshots || [];
    if (!shots.length) { panel.appendChild(Utils.el("p", { class: "rich-content" }, ["No screenshots provided."])); return; }
    panel.appendChild(Utils.el("div", { class: "screenshots-grid" }, shots.map(function (s) {
      return Utils.el("img", { class: "screenshot-thumb", src: s.thumbnailUrl || s.url, alt: s.title || "", loading: "lazy", onclick: function () { Components.Lightbox.open(s.url || s.thumbnailUrl); } });
    })));
  }

  return { open: open, close: close, isOpen: isOpen, selectTab: selectTab, refresh: refresh };
})();

/* ---------- Bottom job progress panel ---------- */
Components.JobPanel = (function () {
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
    const map = { check: "Checking for updates", sync: "Syncing addons", add: "Adding addon", install: "Installing version", remove: "Removing addon", launch: "Launching World of Warcraft", rollback: "Rolling back version", import: "Importing addon list", "switch-source": "Reinstalling from another source" };
    return map[job.kind] || "Working…";
  }

  // E5: a per-row "What changed" control for a just-Updated/Installed addon.
  // Guarded on r.projectId being present (every real sync/add/install/launch
  // result row carries one per SPEC's documented results shape; a synthesized
  // "last run" pseudo-job built from lastRun.rows - see Actions.showLastRunDetails -
  // does not, so this quietly omits the button there rather than throwing).
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

  function show(job) {
    const panel = Utils.qs("#job-panel");
    panel.hidden = false;
    panel.classList.remove("is-collapsed");
    Utils.qs("#job-panel-collapse .icon use").setAttribute("href", "#icon-chevron-down");
    update(job);
  }

  function update(job) {
    if (!job) return;
    const panel = Utils.qs("#job-panel");
    if (panel.hidden) panel.hidden = false;
    const running = job.state === "running";
    Utils.qs("#job-title").textContent = running ? titleFor(job) : ((job.state === "failed" ? "Failed — " : "Done — ") + titleFor(job));
    Utils.qs("#job-spinner").classList.toggle("is-done", !running);
    Utils.qs("#job-panel-close").hidden = running;

    const log = Utils.qs("#job-log");
    log.textContent = (job.log || []).join("\n");
    const body = Utils.qs("#job-panel-body");
    body.scrollTop = body.scrollHeight;

    const resultsBox = Utils.qs("#job-results");
    resultsBox.textContent = "";
    let any = false;
    if (job.state === "failed" && job.error) {
      resultsBox.appendChild(Utils.el("div", { class: "job-result-row" }, [Utils.el("span", {}, [job.error])]));
      any = true;
    }
    if (!running && job.results && job.results.length) {
      job.results.forEach(function (r) {
        resultsBox.appendChild(Utils.el("div", { class: "job-result-row" }, [
          Utils.el("div", { class: "job-result-name" }, [Utils.el("span", {}, [r.name || ""]), whatChangedButton(r)]),
          Components.Chip.forJobStatus(r.status)
        ]));
      });
      any = true;
    }
    resultsBox.hidden = !any;
  }

  function toggleCollapse() {
    const panel = Utils.qs("#job-panel");
    const collapsed = panel.classList.toggle("is-collapsed");
    Utils.qs("#job-panel-collapse .icon use").setAttribute("href", collapsed ? "#icon-chevron-right" : "#icon-chevron-down");
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

  return { show: show, update: update, toggleCollapse: toggleCollapse, collapseIfOpen: collapseIfOpen, hide: hide, summarize: summarize };
})();

/* ---------- E19 (script itself is E17's, unchanged): curseforge:// handler
   status pill + toggle. Painted twice from the same Store.state.protocol -
   once into Settings > Game's row, once into the Browse > CurseForge pane -
   by two calls to the one render(containerId) function below, so the two
   places can never drift out of sync with each other. ---------- */
Components.ProtocolControl = (function () {
  function render(containerId) {
    const box = Utils.qs("#" + containerId);
    if (!box) return;
    box.textContent = "";

    const p = Store.state.protocol;
    const busy = Store.state.protocolBusy;
    let pillLabel, pillCls, note, registered;
    if (Store.state.protocolLoading && !p) {
      pillLabel = "Checking…"; pillCls = "chip-muted";
      note = "Looking up whether Furphy handles CurseForge install links.";
      registered = false;
    } else if (!p) {
      pillLabel = "Unknown"; pillCls = "chip-muted";
      note = "Couldn't check the install-link handler.";
      registered = false;
    } else if (p.registered) {
      pillLabel = "Handled by Furphy"; pillCls = "chip-success";
      note = "Clicking Install on a curseforge.com addon page installs it here.";
      registered = true;
    } else if (p.currentHandler) {
      pillLabel = "Handled by another program"; pillCls = "chip-warning";
      note = "Another program currently opens curseforge:// links. Turning this on switches them to Furphy.";
      registered = false;
    } else {
      pillLabel = "Not registered"; pillCls = "chip-muted";
      note = "CurseForge.com's own Install buttons open its own picker instead of Furphy.";
      registered = false;
    }

    const toggle = Utils.el("input", { type: "checkbox", disabled: busy || (Store.state.protocolLoading && !p) });
    toggle.checked = registered;
    toggle.addEventListener("change", function () {
      Actions.setProtocolRegistered(toggle.checked);
    });

    box.appendChild(Utils.el("div", { class: "protocol-control-row" }, [
      Components.Chip.build(pillLabel, pillCls),
      Utils.el("label", { class: "switch", title: registered ? "Stop handling curseforge:// links" : "Handle curseforge:// links with Furphy" }, [
        toggle,
        Utils.el("span", { class: "switch-track" }, [Utils.el("span", { class: "switch-thumb" })])
      ])
    ]));
    box.appendChild(Utils.el("p", { class: "muted-text" }, [note]));
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
  // reacts instantly, then hands off to App's 800ms job poller.
  async function startJob(kind, params, label) {
    if (Store.isBusy()) { Components.Toast.show("Another task is running.", "warning"); return false; }
    Store.state.jobLabel = label || null;
    try {
      const res = await Api.postJob(kind, params);
      Store.state.job = { id: res.jobId, kind: kind, params: params || {}, state: "running", startedAt: new Date().toISOString(), finishedAt: null, exitCode: null, log: [], results: [], error: null };
      App.onJobStarted(res.jobId);
      return true;
    } catch (err) {
      if (err.status === 409) Components.Toast.show("Another task is already running.", "warning");
      else Components.Toast.show("Couldn't start the job: " + describeError(err), "error");
      return false;
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

  function updateAll() {
    const n = Store.updatesCount();
    const label = n > 0 ? ("Updating " + n + " addon" + (n === 1 ? "" : "s")) : "Updating addons";
    return startJob("sync", {}, label);
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

  // E18: the first-run Welcome dialog's "Adopt all" - one job installing
  // every already-fully-formed target token (a bare numeric CurseForge id,
  // or "wago:<id>") at once, mirroring what install.ps1 itself does via the
  // CLI directly. See Build-CliArgs's 'add' case (addon-server.ps1) for the
  // server-side projectIds handling this relies on.
  function adoptAll(targets) {
    Components.Dialogs.closeWelcome();
    const label = "Adopting " + targets.length + " addon" + (targets.length === 1 ? "" : "s");
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

  // E5: a job result row's "What changed" control. With a key, jumps straight
  // to the Changelog tab pinned to the file that was just installed (the only
  // source of changelog text, so this is where "what changed" actually lives);
  // without one, Changelog is itself key-gated, so falls back to Versions,
  // which already tags the installed/pinned file without any CurseForge call.
  function whatChanged(projectId, fileId) {
    // E12: Wago's changelog needs no key at all (unlike CurseForge's, which
    // is key-gated) - a Wago row's key always goes straight to Changelog.
    const isWago = typeof projectId === "string" && projectId.toLowerCase().indexOf("wago:") === 0;
    const hasKey = isWago || !!(Store.state.settings && Store.state.settings.hasApiKey);
    if (hasKey) Components.Drawer.open(projectId, { tab: "changelog", changelogFileId: fileId });
    else Components.Drawer.open(projectId, { tab: "versions" });
  }

  // E5: "Details" next to the My Addons header's "Last run" line. Prefers the
  // real last JobStatus (Store.state.job - the server's "current or most
  // recent job", which survives a page reload and carries full projectId/
  // fileId per result row, so "What changed" keeps working from here too)
  // over lastRun.rows, which SPEC documents as bare {status,name,version}
  // with no ids to route a "What changed" click on.
  function showLastRunDetails() {
    const lastRun = Store.state.lastRun;
    if (!lastRun) return;
    const job = Store.state.job;
    if (job && job.state !== "running" && job.results && job.results.length) {
      Store.state.jobLabel = null;
      Components.JobPanel.show(job);
      return;
    }
    const pseudo = { kind: null, state: "done", log: [], results: lastRun.rows || [], error: null, startedAt: lastRun.timestamp, finishedAt: lastRun.timestamp };
    Store.state.jobLabel = "Last run";
    Components.JobPanel.show(pseudo);
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

  function adopt(folder, projectId) { return startJob("add", { projectId: Number(projectId) }, "Adopting " + folder); }
  // E12: one-click adoption from the Wago id/slug -Scan found in the
  // untracked folder's own .toc (## X-Wago-ID) - same shape as
  // installLatestWago, just with an "Adopting..." label to match `adopt`'s.
  function adoptWago(folder, wagoRef) { return startJob("add", { source: "wago", slug: wagoRef }, "Adopting " + folder); }

  // Round 5 fix: each individual Settings control (a release-channel radio,
  // the auto-update toggle) calls saveSettings independently, so flipping
  // two or three of them in quick succession used to stack that many
  // identical "Settings saved." toasts on screen at once. Coalesces rapid
  // successive successful saves into a single toast, fired a moment after
  // the last one settles rather than after every individual call.
  let saveToastTimer = null;
  // Round 6 fix: optional `toastMessage` overrides the generic "Settings
  // saved." for callers with something more specific to say (the API key
  // save button reports "API key saved (…last4)" instead) - existing callers
  // that pass nothing are unaffected.
  async function saveSettings(patch, toastMessage) {
    try {
      const res = await Api.putSettings(patch);
      Store.state.settings = res;
      // Round 6 fix: any settings save clears a stale "key was rejected"
      // signal - the user may just have fixed it, and even if not, the next
      // /api/cf/* call will re-detect the rejection and set it right back.
      Store.state.cfKeyRejected = false;
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

  async function testKey(key) {
    try { return await Api.testKey(key); }
    catch (err) { return { ok: false, message: describeError(err) }; }
  }

  async function openWhat(what, extra) {
    try { await Api.openWhat(what, extra); }
    catch (err) { Components.Toast.show("Couldn't open that: " + describeError(err), "error"); }
  }

  function openOnCurseForge(projectId, slug) { return openWhat("curseforge", { projectId: Utils.normalizeId(projectId), slug: slug || undefined }); }

  // Round 9: Browse's "Search on CurseForge.com" box (CurseForge pane, both
  // keyless and keyed) - unlike searchDependency below, this always opens
  // CurseForge's own website search rather than ever redirecting into this
  // app's in-app search, since the whole point is reaching CurseForge's full
  // catalogue/official ranking. Uses the 'cf-window' open target (a
  // chromeless side window beside this app) rather than 'url' (the default
  // browser tab every other external link here uses) - server-side
  // allowlisted to curseforge.com, same as every other open target.
  function searchCurseForgeWebsite(term) {
    const q = (term || "").trim();
    if (!q) return;
    return openWhat("cf-window", { url: "https://www.curseforge.com/wow/search?search=" + encodeURIComponent(q) + "&class=addons" });
  }

  // E3: "Search CurseForge" on a missing dependency, from the drawer's
  // Overview tab. With a key, Browse can search directly, so switch there
  // pre-filled rather than leaving the app; without one, Browse is hidden
  // behind its own no-key panel, so fall back to opening CurseForge's own
  // search page in the default browser (server-side allowlisted to the two
  // addon marketplaces this app ever links to).
  function searchDependency(name) {
    const hasKey = !!(Store.state.settings && Store.state.settings.hasApiKey);
    if (hasKey) {
      // Set the query before switching: switching to a not-yet-loaded Browse
      // view auto-searches using whatever query is already in Store, so
      // setting it first means that auto-search (when it fires) already
      // uses the right term instead of an empty/stale one. When Browse was
      // already loaded that auto-search is skipped (Views.browse.render()
      // only searches when nothing has loaded yet), so an explicit search
      // call is still needed to pick up the new query in that case.
      Store.state.browse.query = name;
      const alreadyLoaded = Store.state.browse.loaded;
      App.switchView("browse");
      const input = Utils.qs("#browse-search");
      if (input) input.value = name;
      if (alreadyLoaded) Views.browse.search(true);
      return;
    }
    return openWhat("url", { url: "https://www.curseforge.com/wow/search?search=" + encodeURIComponent(name) });
  }

  // Validates+resolves the Add-addon dialog's free-text input, then starts the add job.
  async function submitAddInput(raw) {
    const value = (raw || "").trim();
    const errorBox = Utils.qs("#add-addon-error");
    const submitBtn = Utils.qs("#add-addon-submit");
    function fail(msg) { errorBox.textContent = msg; errorBox.hidden = false; errorBox.className = "form-msg is-error"; }

    if (!value) { fail("Enter a Project ID, a CurseForge URL, or a Wago addon URL."); return; }

    if (/^\d+$/.test(value)) {
      Components.Dialogs.closeAdd();
      await addByProjectId(Number(value));
      return;
    }

    // E12: a "wago:<slug-or-id>" token or a full wago URL needs no API key
    // (unlike a CurseForge URL below) and no server round-trip to resolve -
    // a Wago addon's identity already IS its slug/id.
    const wagoMatch = value.match(/^wago:(.+)$/i) || value.match(/^https?:\/\/addons\.wago\.io\/addons\/([a-z0-9-]+)/i);
    if (wagoMatch) {
      const ref = wagoMatch[1].trim();
      if (!ref) { fail("That doesn't look like a valid Wago reference."); return; }
      Components.Dialogs.closeAdd();
      await addByWagoSlug(ref);
      return;
    }

    if (value.toLowerCase().indexOf("curseforge.com") === -1) {
      fail("Enter a numeric Project ID, a curseforge.com addon URL, or a wago.io addon URL.");
      return;
    }
    if (!Store.state.settings || !Store.state.settings.hasApiKey) {
      fail("CurseForge URLs need an API key — use the numeric Project ID instead, or add a key in Settings.");
      return;
    }
    submitBtn.disabled = true;
    try {
      const res = await Api.cfResolve(value);
      Components.Dialogs.closeAdd();
      await startJob("add", { projectId: res.projectId }, "Installing " + (res.name || "addon"));
    } catch (err) {
      submitBtn.disabled = false;
      if (err.status === 404) fail("Couldn't find that addon on CurseForge.");
      else fail("Couldn't resolve that URL: " + describeError(err));
    }
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
    Store.state.jobLabel = "Importing addon list";
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

  return {
    startJob: startJob, checkForUpdates: checkForUpdates, autoCheckForUpdates: autoCheckForUpdates, updateAll: updateAll, updateNow: updateNow,
    forceReinstallAll: forceReinstallAll, uninstall: uninstall, installVersion: installVersion, pinCurrent: pinCurrent, rollback: rollback,
    installLatest: installLatest, addWithVersion: addWithVersion, addByProjectId: addByProjectId,
    updateAndPlay: updateAndPlay, launchOnly: launchOnly, toggleIgnore: toggleIgnore, unpin: unpin,
    deleteUntracked: deleteUntracked, adopt: adopt, adoptWago: adoptWago, saveSettings: saveSettings, testKey: testKey,
    openWhat: openWhat, openOnCurseForge: openOnCurseForge, searchDependency: searchDependency, searchCurseForgeWebsite: searchCurseForgeWebsite, submitAddInput: submitAddInput,
    whatChanged: whatChanged, showLastRunDetails: showLastRunDetails, importAddons: importAddons,
    updateSelected: updateSelected, uninstallSelected: uninstallSelected, ignoreSelected: ignoreSelected,
    // E12 (Wago second source)
    installLatestWago: installLatestWago, addWagoWithVersion: addWagoWithVersion, addByWagoSlug: addByWagoSlug,
    openOnWago: openOnWago, switchSource: switchSource, switchSourceButton: switchSourceButton,
    // E18 (first-run welcome)
    adoptAll: adoptAll,
    // E19 (curseforge:// handler toggle; ad filter goes through saveSettings above)
    loadProtocolStatus: loadProtocolStatus, setProtocolRegistered: setProtocolRegistered
  };
})();

/* ==========================================================================
   Views - one sub-module per screen. Each exposes render() (paint from
   current Store state) and bindOnce() (wire static DOM once at startup).
   ========================================================================== */
const Views = {};

/* ---------- My Addons ---------- */
Views.myAddons = (function () {
  // E7: status filter chips shown above the table. "missingdeps" reads
  // addon.missingDeps - populated by /api/state since the E3 dependency
  // expansion landed (requiredDeps not present as a folder in AddOns,
  // computed live server-side).
  const FILTER_DEFS = [
    { key: "all", label: "All" },
    { key: "updates", label: "Updates" },
    { key: "pinned", label: "Pinned" },
    { key: "ignored", label: "Ignored" },
    { key: "failed", label: "Failed" },
    { key: "missingdeps", label: "Missing deps" },
    // E13: covers both "Older patch" and "Not for Midnight" - anything the
    // Compatibility column would flag as needing a look, not just the worst
    // case; "unknown" (no evidence either way) is deliberately excluded, same
    // as the header's "N addons need attention" count below.
    { key: "stale", label: "Stale" }
  ];

  function addonMissingDeps(a) { return (a && a.missingDeps) || []; }

  // E3: an extra warning chip alongside the row's normal status chip (not a
  // replacement for it - missing dependencies and update/pin/ignore status
  // are orthogonal). Null when there is nothing missing; Utils.el drops a
  // null child, so this is safe to include unconditionally in the cell.
  function missingDepsChip(a) {
    const missing = addonMissingDeps(a);
    if (!missing.length) return null;
    return Components.Chip.build("Missing: " + missing.length, "chip-warning", "Missing dependencies: " + missing.join(", "));
  }

  function matchesFilter(a, filter) {
    if (filter === "updates") return !!a.updateAvailable;
    if (filter === "pinned") return a.pinnedFileId !== null && a.pinnedFileId !== undefined;
    if (filter === "ignored") return !!a.ignoreUpdates;
    if (filter === "failed") return Store.lastRunStatusFor(a.name) === "Failed";
    if (filter === "missingdeps") return addonMissingDeps(a).length > 0;
    if (filter === "stale") return isStale(a);
    return true; // "all"
  }

  // E13: an addon "needs attention" when the compat check found real
  // evidence it's behind (stale/stale-minor) - "unknown" (no evidence at
  // all, e.g. no .build.info or no toc Interface/latestGameVersions yet)
  // is not itself a red flag, so it's excluded from both this and the
  // header's count below.
  function isStale(a) { return a.compat === "stale" || a.compat === "stale-minor"; }

  function filterCounts() {
    const all = Store.state.addons;
    const counts = {};
    FILTER_DEFS.forEach(function (def) { counts[def.key] = all.filter(function (a) { return matchesFilter(a, def.key); }).length; });
    return counts;
  }

  function renderFilters() {
    const box = Utils.qs("#myaddons-filters");
    box.textContent = "";
    const counts = filterCounts();
    const active = Store.state.myaddonsFilter;
    FILTER_DEFS.forEach(function (def) {
      const isActive = active === def.key;
      box.appendChild(Utils.el("button", {
        type: "button",
        class: "filter-chip" + (isActive ? " is-active" : ""),
        "aria-pressed": isActive ? "true" : "false",
        title: "Show " + def.label.toLowerCase() + " (" + counts[def.key] + ")",
        onclick: function () { Store.state.myaddonsFilter = def.key; render(); }
      }, [def.label, Utils.el("span", { class: "filter-chip-count" }, [String(counts[def.key])])]));
    });
  }

  function statusRank(a) {
    if (Store.jobActingOn(Store.addonKey(a))) return 0;
    if (Store.lastRunStatusFor(a.name) === "Failed") return 1;
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

  // One comparator per sortable column (Addon/Installed/Latest/Status/Updated
  // headers); the click handler in bindOnce() flips `dir` to invert whichever
  // one this returns.
  function compareValues(a, b, column) {
    if (column === "installed") return compareVersionStrings(a.version, b.version);
    if (column === "latest") {
      const av = a.updateAvailable ? a.updateAvailable.version : "";
      const bv = b.updateAvailable ? b.updateAvailable.version : "";
      return compareVersionStrings(av, bv);
    }
    if (column === "status") return statusRank(a) - statusRank(b) || compareNames(a.name, b.name);
    if (column === "updated") return new Date(a.installedAt || 0) - new Date(b.installedAt || 0);
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

  // E5: the "Last run: <summary> · <relative time>" line above the filter
  // chips, with a "Details" link that reopens the progress panel on the last
  // job's results (Actions.showLastRunDetails). Shown whenever lastRun is
  // known - including right after a page reload, since /api/state's lastRun
  // is independent of loadingState/stateError - so it is rendered up front,
  // ahead of render()'s early-return branches below, rather than folded into
  // any one of them.
  function renderLastRun() {
    const line = Utils.qs("#myaddons-lastrun");
    const lastRun = Store.state.lastRun;
    if (!lastRun) { line.hidden = true; return; }
    line.hidden = false;
    Utils.qs("#myaddons-lastrun-text").textContent = "Last run: " + (lastRun.summary || "done") + " · " + Utils.relativeTime(lastRun.timestamp);
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
    renderLastRun();

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

    const total = Store.state.addons.length;
    const updates = Store.updatesCount();
    const checked = Store.state.updatesCheckedAt ? "checked " + Utils.relativeTime(Store.state.updatesCheckedAt) : "not checked yet";
    let text = total + (total === 1 ? " addon" : " addons");
    if (updates > 0) text += " · " + updates + " update" + (updates === 1 ? "" : "s") + " available";
    text += " · " + checked;
    // E13: "Client 12.1.0.69587 · N addons need attention" - only appended
    // once the client build is actually known, and the attention clause only
    // when there's something to flag (a spotless "0 need attention" clause
    // on every load would just be noise).
    if (Store.state.clientBuild) {
      text += " · Client " + Store.state.clientBuild;
      const staleCount = Store.state.addons.filter(isStale).length;
      if (staleCount > 0) text += " · " + staleCount + (staleCount === 1 ? " addon needs" : " addons need") + " attention";
    }
    if (list.length !== total) text = list.length + " of " + text;
    summary.textContent = text;

    LogoCache.ensure(list.map(function (a) { return a.projectId; }), render);
  }

  // E12: a tiny source badge (CF/Wago) next to each row's name, so a mixed
  // tracked list stays legible about where each addon actually comes from.
  function sourceBadge(a) {
    const isWago = a.source === "wago";
    return Utils.el("span", { class: "source-badge " + (isWago ? "is-wago" : "is-cf"), title: isWago ? "Wago Addons" : "CurseForge" }, [isWago ? "Wago" : "CF"]);
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
      Utils.el("td", {}, [Utils.el("span", { class: "version-text" }, [a.version || "-"])]),
      Utils.el("td", {}, [Utils.el("span", { class: "version-text" + (a.updateAvailable ? "" : " is-empty") }, [a.updateAvailable ? a.updateAvailable.version : "-"])]),
      Utils.el("td", {}, [Utils.el("div", { class: "status-cell" }, [
        Components.Chip.forAddon(a),
        missingDepsChip(a),
        // Round 4 fix: the Updated <th>/<td> is dropped entirely below 1100px
        // (see the media query in style.css) with nothing telling the reader
        // it went away. This mirrors that same relative-time text into the
        // status cell, hidden by default and shown only at the widths where
        // the real column is hidden, so the information isn't simply lost.
        Utils.el("span", { class: "updated-fallback", title: Utils.fullDate(a.installedAt) }, ["Updated " + Utils.relativeTime(a.installedAt)])
      ])]),
      Utils.el("td", {}, [Components.Chip.forCompat(a)]),
      Utils.el("td", { class: "updated-cell", title: Utils.fullDate(a.installedAt) }, [Utils.relativeTime(a.installedAt)]),
      Utils.el("td", {}, [kebab(a)])
    ]);
    tr.addEventListener("click", function (ev) {
      if (ev.target.closest(".menu-wrap") || ev.target.closest(".checkbox-cell")) return;
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
      // Round 4 fix: reuses the existing eye-off sprite icon (already defined
      // for the Settings API-key show/hide toggle) so this is the only kebab
      // item that isn't the sole entry with no leading icon - without one, its
      // label sat flush-left while every sibling item's label is indented past
      // an icon column, breaking the menu's alignment.
      a.ignoreUpdates
        ? { label: "Stop ignoring", icon: "eye-off", onSelect: function () { Actions.toggleIgnore(key, false); } }
        : { label: "Ignore updates", icon: "eye-off", onSelect: function () { Actions.toggleIgnore(key, true); } },
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
    Utils.qs("#myaddons-clear-filters").addEventListener("click", function () {
      Store.state.myaddonsSearch = "";
      Store.state.myaddonsFilter = "all";
      Utils.qs("#myaddons-search").value = "";
      render();
    });
    Utils.qs("#myaddons-retry").addEventListener("click", function () { App.reloadState(false); });
    Utils.qs("#myaddons-lastrun-details").addEventListener("click", function () { Actions.showLastRunDetails(); });

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

/* ---------- Browse ---------- */
Views.browse = (function () {
  // E12 (Wago second source): a source switch above the CF no-key panel and
  // the shared search/grid content - Wago never needs a key, so switching
  // to it must work even when CurseForge's own no-key panel is showing.
  function renderSourceSwitch() {
    const source = Store.state.browse.source;
    Utils.qsa("#browse-source-switch .segmented-btn").forEach(function (btn) {
      btn.classList.toggle("is-active", btn.dataset.sourceValue === source);
    });
  }

  // E16: whether Browse's CurseForge side is in keyless partial-search mode
  // right now - true only for the source:"curseforge" panel with no API
  // key configured (a rejected key is its own separate blocking state,
  // unaffected by this expansion; Wago never reaches this function at all).
  function isKeylessCf() {
    return Store.state.browse.source !== "wago" && !(Store.state.settings && Store.state.settings.hasApiKey);
  }

  function render() {
    renderSourceSwitch();
    const b = Store.state.browse;
    // Round 9: "Search on CurseForge.com" - shown for the CurseForge side of
    // the source switch in both keyless and keyed mode (Wago never needed a
    // separate website search box - Wago's own search IS the in-app one).
    Utils.qs("#cf-web-search").hidden = b.source === "wago";
    // E19 (script/registration itself is E17's, unchanged): painted every
    // render regardless of source - it's a no-op cost, and #cf-web-search's
    // own hidden flag just above already keeps it out of sight on the Wago
    // side, same as the search box/hint it lives alongside.
    Components.ProtocolControl.render("browse-protocol-control");
    Utils.qs("#browse-search").placeholder = b.source === "wago" ? "Search Wago addons" : "Search CurseForge addons";
    if (b.source === "wago") {
      Utils.qs("#browse-keyless-banner").hidden = true;
      Utils.qs("#browse-keyrejected").hidden = true;
      Utils.qs("#browse-installbyid").hidden = true;
      Utils.qs("#browse-category").hidden = false;
      Utils.qs("#browse-sort").hidden = false;
      Utils.qs("#browse-content").hidden = false;
      if (!b.categories.length && !b.categoriesLoading) loadWagoCategories();
      if (!b.loaded && !b.loading) searchWago(true);
      renderResults();
      return;
    }

    const hasKey = !!(Store.state.settings && Store.state.settings.hasApiKey);
    // Round 6 fix: a configured-but-rejected key is a third state, distinct
    // from "no key at all" - shows its own panel (with its own fix-it copy)
    // instead of either the no-key/keyless copy or a search UI that would
    // just keep failing every request.
    const rejected = hasKey && Store.state.cfKeyRejected;
    Utils.qs("#browse-keyrejected").hidden = !rejected;
    Utils.qs("#browse-content").hidden = rejected;
    if (rejected) {
      Utils.qs("#browse-keyless-banner").hidden = true;
      Utils.qs("#browse-installbyid").hidden = true;
      return;
    }

    // E16: no key -> a keyless partial search takes over #browse-content
    // instead of the old fully-blocking panel - the banner/Install-by-ID
    // card show, category/CurseForge-specific sort stay hidden (neither
    // keyless source carries CurseForge's category taxonomy).
    const keyless = !hasKey;
    Utils.qs("#browse-keyless-banner").hidden = !keyless;
    Utils.qs("#browse-installbyid").hidden = !keyless;
    Utils.qs("#browse-category").hidden = keyless;
    Utils.qs("#browse-sort").hidden = keyless;

    if (!keyless && !Store.state.browse.categories.length && !Store.state.browse.categoriesLoading) loadCfCategories();
    if (!Store.state.browse.loaded && !Store.state.browse.loading) searchCf(true);

    renderResults();
  }

  async function loadCfCategories() {
    Store.state.browse.categoriesLoading = true;
    try {
      const res = await Api.cfCategories();
      Store.state.browse.categories = res.data || [];
      const sel = Utils.qs("#browse-category");
      sel.textContent = "";
      sel.appendChild(Utils.el("option", { value: "" }, ["All categories"]));
      (res.data || []).forEach(function (c) { sel.appendChild(Utils.el("option", { value: c.id }, [c.name])); });
    } catch (err) {
      /* category filter degrades to "All categories" only */
    } finally {
      Store.state.browse.categoriesLoading = false;
    }
  }

  async function loadWagoCategories() {
    Store.state.browse.categoriesLoading = true;
    try {
      const res = await Api.wagoCategories();
      Store.state.browse.categories = res.data || [];
      const sel = Utils.qs("#browse-category");
      sel.textContent = "";
      sel.appendChild(Utils.el("option", { value: "" }, ["All categories"]));
      (res.data || []).forEach(function (c) { sel.appendChild(Utils.el("option", { value: c.id }, [c.display_name || c.name])); });
    } catch (err) {
      /* category filter degrades to "All categories" only */
    } finally {
      Store.state.browse.categoriesLoading = false;
    }
  }

  async function searchCf(reset) {
    if (isKeylessCf()) { return searchCfKeyless(reset); }
    const b = Store.state.browse;
    if (reset) { b.index = 0; b.results = []; }
    b.loading = true;
    b.error = null;
    renderResults();
    try {
      const res = await Api.cfSearch({ q: b.query, categoryId: b.categoryId, sortField: b.sortField, sortOrder: "desc", index: b.index, pageSize: b.pageSize });
      Store.cacheMods(res.data || []);
      b.results = reset ? (res.data || []) : b.results.concat(res.data || []);
      b.totalCount = res.pagination ? res.pagination.totalCount : b.results.length;
      b.loaded = true;
      b.loading = false;
      LogoCache.ensure((res.data || []).map(function (m) { return m.id; }), renderResults);
    } catch (err) {
      b.loading = false;
      b.error = err;
    }
    renderResults();
  }

  // E16: the no-key CurseForge search - GET /api/cf/browse, always keyless-
  // capable. No index/pageSize pagination on this endpoint (unlike the
  // official search above), so there is no "Load more" here - see
  // renderResults' loadMoreWrap.hidden logic.
  async function searchCfKeyless(reset) {
    const b = Store.state.browse;
    if (reset) { b.results = []; }
    b.loading = true;
    b.error = null;
    renderResults();
    try {
      const res = await Api.cfBrowse({ q: b.query, limit: 30 });
      const items = res.items || [];
      b.results = reset ? items : b.results.concat(items);
      b.totalCount = res.total != null ? res.total : b.results.length;
      b.catalogueAge = res.catalogueAge || null;
      b.loaded = true;
      b.loading = false;
    } catch (err) {
      b.loading = false;
      b.error = err;
    }
    renderResults();
  }

  async function searchWago(reset) {
    const b = Store.state.browse;
    if (reset) { b.page = 1; b.results = []; }
    b.loading = true;
    b.error = null;
    renderResults();
    try {
      const res = await Api.wagoSearch({ q: b.query, categoryId: b.categoryId, sort: b.sort, page: b.page });
      const items = res.items || [];
      b.results = reset ? items : b.results.concat(items);
      b.totalCount = res.total || b.results.length;
      b.lastPage = res.lastPage || b.page;
      b.loaded = true;
      b.loading = false;
    } catch (err) {
      b.loading = false;
      b.error = err;
    }
    renderResults();
  }

  // The one function bound to the search/category/sort/load-more controls -
  // dispatches to whichever source is currently active so bindOnce() below
  // needs no source-specific wiring of its own.
  function search(reset) {
    return Store.state.browse.source === "wago" ? searchWago(reset) : searchCf(reset);
  }

  function renderResults() {
    const b = Store.state.browse;
    const isWago = b.source === "wago";
    const keylessCf = !isWago && isKeylessCf();
    const grid = Utils.qs("#browse-grid");
    const skeleton = Utils.qs("#browse-skeleton");
    const empty = Utils.qs("#browse-empty");
    const errorBox = Utils.qs("#browse-error");
    const loadMoreWrap = Utils.qs("#browse-loadmore-wrap");
    const summary = Utils.qs("#browse-summary");

    if (b.loading && !b.results.length) {
      grid.hidden = true; empty.hidden = true; errorBox.hidden = true; loadMoreWrap.hidden = true; skeleton.hidden = false;
      summary.textContent = "";
      return;
    }
    skeleton.hidden = true;

    if (b.error && !b.results.length) {
      grid.hidden = true; empty.hidden = true; loadMoreWrap.hidden = true;
      errorBox.hidden = false;
      Utils.qs("#browse-error-msg").textContent = describeError(b.error);
      summary.textContent = "";
      return;
    }
    errorBox.hidden = true;

    if (b.loaded && !b.results.length) {
      grid.hidden = true; loadMoreWrap.hidden = true; empty.hidden = false;
      summary.textContent = "";
      return;
    }
    empty.hidden = true;

    grid.hidden = false;
    grid.textContent = "";
    b.results.forEach(function (m) { grid.appendChild(isWago ? wagoCard(m) : (keylessCf ? catalogueCard(m) : card(m))); });

    summary.textContent = b.results.length + " of " + Utils.formatNumber(b.totalCount) + " results";
    // E16: /api/cf/browse has no index/pageSize pagination of its own (it
    // returns up to `limit` items in one shot) - "Load more" never applies
    // in keyless CurseForge mode.
    loadMoreWrap.hidden = b.loading || keylessCf || (isWago ? b.page >= b.lastPage : b.results.length >= b.totalCount);
  }

  // E16: a keyless-CurseForge-browse card - sparser than the official
  // card() below (only id/name/slug/downloadCount/lastUpdated/logoUrl/source
  // are ever known - see /api/cf/browse's documented item shape), with a
  // small "Indexed"/"Live match" provenance pill instead of category chips
  // (neither keyless source carries CurseForge's category taxonomy).
  function catalogueCard(item) {
    const tracked = !!Store.addonByProjectId(item.id);
    const busy = Store.jobActingOn(item.id);
    const btn = tracked
      ? Utils.el("button", { type: "button", class: "btn btn-outline", disabled: true }, [Utils.icon("check-circle"), "Installed"])
      : Utils.el("button", { type: "button", class: "btn btn-accent", disabled: busy, onclick: function (ev) { ev.stopPropagation(); Actions.installLatest(item.id, item.name); } }, [busy ? "Installing…" : "Install"]);

    const meta = [];
    if (item.downloadCount != null) meta.push(Utils.el("span", {}, [Utils.formatNumber(item.downloadCount) + " downloads"]));
    if (item.lastUpdated) meta.push(Utils.el("span", { title: Utils.fullDate(item.lastUpdated) }, ["updated " + Utils.relativeTime(item.lastUpdated)]));

    const node = Utils.el("div", { class: "browse-card" }, [
      Utils.el("div", { class: "browse-card-top" }, [
        Components.Logo.build({ projectId: item.id, name: item.name, thumbnailUrl: item.logoUrl }, 44),
        Utils.el("div", {}, [
          Utils.el("div", { class: "browse-card-title" }, [item.name || ("Project " + item.id)]),
          Utils.el("span", { class: "source-pill" }, [item.source === "addon-radar" ? "Live match" : "Indexed"])
        ])
      ]),
      meta.length ? Utils.el("div", { class: "browse-card-meta" }, meta) : null,
      Utils.el("div", { class: "browse-card-footer" }, [btn])
    ]);
    node.addEventListener("click", function () { Components.Drawer.open(item.id, { tab: "overview", slug: item.slug }); });
    return node;
  }

  function card(m) {
    const tracked = !!Store.addonByProjectId(m.id);
    const busy = Store.jobActingOn(m.id);
    const btn = tracked
      ? Utils.el("button", { type: "button", class: "btn btn-outline", disabled: true }, [Utils.icon("check-circle"), "Installed"])
      : Utils.el("button", { type: "button", class: "btn btn-accent", disabled: busy, onclick: function (ev) { ev.stopPropagation(); Actions.installLatest(m.id, m.name); } }, [busy ? "Installing…" : "Install"]);

    const node = Utils.el("div", { class: "browse-card" }, [
      Utils.el("div", { class: "browse-card-top" }, [
        Components.Logo.build({ projectId: m.id, name: m.name, thumbnailUrl: m.logo ? (m.logo.thumbnailUrl || m.logo.url) : null }, 44),
        Utils.el("div", {}, [
          Utils.el("div", { class: "browse-card-title" }, [m.name]),
          Utils.el("div", { class: "browse-card-author" }, [m.authors && m.authors[0] ? m.authors[0].name : ""])
        ])
      ]),
      Utils.el("div", { class: "browse-card-summary" }, [m.summary || ""]),
      Utils.el("div", { class: "browse-card-cats" }, (m.categories || []).slice(0, 3).map(function (c) { return Utils.el("span", { class: "browse-card-cat" }, [c.name]); })),
      Utils.el("div", { class: "browse-card-meta" }, [
        Utils.el("span", {}, [Utils.formatNumber(m.downloadCount) + " downloads"]),
        Utils.el("span", { title: Utils.fullDate(m.dateModified) }, ["updated " + Utils.relativeTime(m.dateModified)])
      ]),
      Utils.el("div", { class: "browse-card-footer" }, [btn])
    ]);
    node.addEventListener("click", function () { Components.Drawer.open(m.id, { tab: "overview", slug: m.slug }); });
    return node;
  }

  // E12: Wago's search results are parsed HTML card snippets (slug/name/
  // thumbnail only - see SPEC's verified Wago facts) rather than a full mod
  // object, so this card is necessarily sparser than CurseForge's (no
  // summary/downloads/categories - that detail only exists on the addon's
  // own /addons/{slug} page, fetched once the drawer opens).
  function wagoCard(item) {
    const key = "wago:" + item.slug;
    const tracked = !!Store.addonByProjectId(key);
    const busy = Store.jobActingOn(key);
    const btn = tracked
      ? Utils.el("button", { type: "button", class: "btn btn-outline", disabled: true }, [Utils.icon("check-circle"), "Installed"])
      : Utils.el("button", { type: "button", class: "btn btn-accent", disabled: busy, onclick: function (ev) { ev.stopPropagation(); Actions.installLatestWago(item.slug, item.name); } }, [busy ? "Installing…" : "Install"]);

    const node = Utils.el("div", { class: "browse-card" }, [
      Utils.el("div", { class: "browse-card-top" }, [
        Components.Logo.build({ projectId: null, name: item.name, thumbnailUrl: item.thumbnail }, 44),
        Utils.el("div", {}, [
          Utils.el("div", { class: "browse-card-title" }, [item.name || item.slug]),
          Utils.el("div", { class: "source-badge is-wago" }, ["Wago"])
        ])
      ]),
      Utils.el("div", { class: "browse-card-footer" }, [btn])
    ]);
    node.addEventListener("click", function () { Components.Drawer.open(key, { tab: "overview", slug: item.slug, source: "wago" }); });
    return node;
  }

  function bindOnce() {
    Utils.qsa("#browse-source-switch .segmented-btn").forEach(function (btn) {
      btn.addEventListener("click", function () {
        const source = btn.dataset.sourceValue;
        if (Store.state.browse.source === source) return;
        Store.set({ browse: Object.assign({}, Store.state.browse, {
          source: source, loaded: false, loading: false, error: null, results: [],
          query: "", categoryId: "", categories: [], categoriesLoading: false,
          index: 0, page: 1
        }) });
        Utils.qs("#browse-search").value = "";
        renderSortOptions();
        render();
      });
    });

    Utils.qs("#browse-search").addEventListener("input", Utils.debounce(function (ev) {
      Store.state.browse.query = ev.target.value;
      search(true);
    }, 400));
    Utils.qs("#browse-category").addEventListener("change", function (ev) { Store.state.browse.categoryId = ev.target.value; search(true); });
    Utils.qs("#browse-sort").addEventListener("change", function (ev) {
      if (Store.state.browse.source === "wago") Store.state.browse.sort = ev.target.value;
      else Store.state.browse.sortField = Number(ev.target.value);
      search(true);
    });
    Utils.qs("#btn-load-more").addEventListener("click", function () {
      const b = Store.state.browse;
      if (b.source === "wago") b.page += 1; else b.index += b.pageSize;
      search(false);
    });
    Utils.qs("#btn-keyless-settings").addEventListener("click", function () { App.switchView("settings"); });
    // Round 6 fix: the key-rejected panel's own "Go to Settings" button.
    Utils.qs("#btn-keyrejected-settings").addEventListener("click", function () { App.switchView("settings"); });

    Utils.qs("#install-by-id-form").addEventListener("submit", function (ev) {
      ev.preventDefault();
      const input = Utils.qs("#install-by-id-input");
      const msg = Utils.qs("#install-by-id-msg");
      const value = input.value.trim();
      if (!/^\d+$/.test(value)) { msg.hidden = false; msg.className = "form-msg is-error"; msg.textContent = "Enter a numeric Project ID."; return; }
      msg.hidden = false; msg.className = "form-msg is-info"; msg.textContent = "Installing…";
      Actions.addByProjectId(Number(value)).then(function (ok) {
        if (ok) { msg.className = "form-msg is-success"; msg.textContent = "Install started — watch the progress panel below."; input.value = ""; }
        else { msg.hidden = true; }
      });
    });

    // Round 9: "Search on CurseForge.com" - Enter in its input or the button
    // both trigger the same external-window search; the input keeps
    // whatever term was typed rather than clearing, since re-opening the
    // same search (e.g. after closing the side window) is a common follow-up.
    Utils.qs("#btn-cf-web-search").addEventListener("click", function () {
      Actions.searchCurseForgeWebsite(Utils.qs("#cf-web-search-input").value);
    });
    Utils.qs("#cf-web-search-input").addEventListener("keydown", function (ev) {
      if (ev.key === "Enter") { ev.preventDefault(); Actions.searchCurseForgeWebsite(ev.target.value); }
    });
  }

  // Swaps #browse-sort's options between CurseForge's (numeric sortField)
  // and Wago's (a sort keyword) whenever the source switch changes.
  //
  // Verified live defect: Wago's own site only recognises sort=name. Any
  // other sort value (popular/updated/downloads/recent/newest/likes/
  // trending/latest/top) makes it silently ignore the search term and
  // return the plain popularity listing, and sort=updated returns an
  // empty list outright. So Wago only ever offers the two values that
  // actually work: Popularity (value "popular", meaning "send no sort
  // param at all" - see the server's Handle-WagoSearch) and Name (value
  // "name", the one value Wago recognises). The CurseForge-only "Last
  // updated"/"Total downloads" options are Wago-inapplicable and omitted.
  function renderSortOptions() {
    const sel = Utils.qs("#browse-sort");
    sel.textContent = "";
    if (Store.state.browse.source === "wago") {
      [["popular", "Popularity"], ["name", "Name"]].forEach(function (pair) {
        sel.appendChild(Utils.el("option", { value: pair[0] }, ["Sort: " + pair[1]]));
      });
      sel.value = Store.state.browse.sort;
    } else {
      [["2", "Popularity"], ["3", "Last updated"], ["4", "Name"], ["6", "Total downloads"]].forEach(function (pair) {
        sel.appendChild(Utils.el("option", { value: pair[0] }, ["Sort: " + pair[1]]));
      });
      sel.value = String(Store.state.browse.sortField);
    }
  }

  return { render: render, search: search, bindOnce: bindOnce };
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
  let apikeyVisible = false;
  // E10: Diagnostics panel state - null diagChecks means "never run yet"
  // (distinct from an empty array, which /api/diagnostics never actually
  // returns, but is handled the same as "never run" either way).
  let diagLoading = false;
  let diagError = null;
  let diagChecks = null;

  // Round 6 fix: the masked placeholder this app itself writes into
  // #input-apikey when a key is configured - eight bullet dots plus the
  // last-4-chars hint, e.g. "••••••••edf0". Centralised so render(), the
  // focus/blur handlers, and extractTypedKey() all agree on exactly what
  // "still showing the mask, unedited" looks like.
  function apikeyMask(hint) { return "••••••••" + (hint || ""); }

  // Round 6 fix: what the user actually typed/pasted, with the masked
  // placeholder stripped back off if it's still leading the value (defends
  // against a paste landing inside the mask instead of replacing it, which
  // is the live defect this whole helper exists to fix) and whitespace
  // trimmed. Returns "" for "nothing real here" - an empty field, the mask
  // alone, or the mask followed by only whitespace - which every caller
  // below treats as "no change".
  function extractTypedApiKey(raw) {
    if (!raw) return "";
    let v = raw;
    const s = Store.state.settings;
    if (s && s.hasApiKey) {
      const mask = apikeyMask(s.apiKeyHint);
      if (v.indexOf(mask) === 0) {
        v = v.slice(mask.length);
      } else {
        // Defensive fallback: the hint may be stale (e.g. changed elsewhere
        // this session) - still strip a leading run of the mask character.
        const m = v.match(/^•+/);
        if (m) v = v.slice(m[0].length);
      }
    }
    return v.trim();
  }

  function showApikeyHint(text) {
    const hint = Utils.qs("#apikey-hint");
    hint.textContent = text;
    hint.hidden = false;
  }
  function hideApikeyHint() {
    const hint = Utils.qs("#apikey-hint");
    hint.hidden = true;
    hint.textContent = "";
  }

  function render() {
    const s = Store.state.settings;
    if (!s) return;

    Utils.qs("#settings-wow-root").textContent = s.wowRoot || "—";
    Utils.qs("#settings-addons-path").textContent = s.addonsPath || "—";
    // E13: read-only info sourced from WTF\Config.wtf, not a manager setting
    // - see index.html's explanatory paragraph next to this row.
    Utils.qs("#settings-checkaddonversion").textContent = checkAddonVersionText(s.checkAddonVersion);

    ["1", "2", "3"].forEach(function (v) { Utils.qs("#radio-release-" + v).checked = String(s.releaseType) === v; });
    Utils.qs("#toggle-autoupdate").checked = !!s.autoUpdateOnLaunch;

    const apikeyInput = Utils.qs("#input-apikey");
    if (document.activeElement !== apikeyInput) apikeyInput.value = s.hasApiKey ? (apikeyMask(s.apiKeyHint)) : "";
    Utils.qs("#apikey-status").textContent = s.hasApiKey ? ("Key configured (…" + s.apiKeyHint + ")") : "No key configured";
    Utils.qs("#btn-clear-apikey").disabled = !s.hasApiKey;

    Utils.qs("#about-version").textContent = App.getServerVersion() || "—";
    const uptime = App.getServerUptime();
    Utils.qs("#about-uptime").textContent = uptime !== null ? formatUptime(uptime) : "—";
    Utils.qs("#about-port").textContent = s.port || "—";

    renderBrowsing(s);
    Components.ProtocolControl.render("settings-protocol-control");
    renderAppearance();
    renderUntracked();
    renderDiagnostics();
    const busy = Store.isBusy();
    const reinstall = Utils.qs("#btn-force-reinstall");
    reinstall.disabled = busy;
    if (busy) reinstall.title = "Another task is running"; else reinstall.removeAttribute("title");
  }

  // E13: WoW's own checkAddonVersion cvar - display text for the value
  // settings.checkAddonVersion carries (a raw string, whatever's actually in
  // WTF\Config.wtf, or null when the file/setting isn't there yet).
  function checkAddonVersionText(value) {
    if (value === "0") return "Disabled (0) — out-of-date addons load anyway";
    if (value === "1") return "Enabled (1) — WoW warns about/blocks out-of-date addons";
    if (value === null || value === undefined) return "Unknown (WTF\\Config.wtf not found)";
    return value; // some other value WoW itself wrote - shown verbatim rather than guessed at
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
  }

  // E7: reflects the persisted density/theme choice (Prefs, already applied
  // to <html> as soon as the page loaded) as the active button in each
  // segmented toggle.
  function renderAppearance() {
    const density = Prefs.getDensity();
    Utils.qsa("#density-toggle .segmented-btn").forEach(function (btn) {
      btn.classList.toggle("is-active", btn.dataset.densityValue === density);
    });
    const theme = Prefs.getTheme();
    Utils.qsa("#theme-toggle .segmented-btn").forEach(function (btn) {
      btn.classList.toggle("is-active", btn.dataset.themeValue === theme);
    });
  }

  function renderUntracked() {
    const box = Utils.qs("#untracked-list");
    box.textContent = "";
    if (untrackedLoading) { box.appendChild(Utils.el("div", { class: "skeleton-row" })); return; }
    if (untrackedError) { box.appendChild(Utils.el("p", { class: "muted-text" }, ["Couldn't scan: " + describeError(untrackedError)])); return; }
    if (!untrackedList.length) {
      const msg = untrackedScanned ? "Scanned — no untracked folders found." : "No untracked folders found yet. Click Scan to look.";
      box.appendChild(Utils.el("p", { class: "muted-text" }, [msg]));
      return;
    }
    untrackedList.forEach(function (u) { box.appendChild(untrackedRow(u)); });
  }

  function untrackedRow(u) {
    const idInput = Utils.el("input", { type: "text", placeholder: "Project ID" });
    const busy = Store.isBusy();
    const actions = [idInput];
    // E12: -Scan reports whatever curseId/wagoId it found in the folder's own
    // .toc (## X-Curse-Project-ID / ## X-Wago-ID) - offer a one-click adopt
    // straight from either id, ahead of the manual Project-ID input, when
    // the toc already answers the question.
    if (u.curseId) {
      actions.push(Utils.el("button", {
        type: "button", class: "btn btn-outline", disabled: busy,
        title: "Adopt as CurseForge project " + u.curseId,
        onclick: function () { Actions.adopt(u.folder, Number(u.curseId)); }
      }, ["Adopt (CF " + u.curseId + ")"]));
    }
    if (u.wagoId) {
      actions.push(Utils.el("button", {
        type: "button", class: "btn btn-outline", disabled: busy,
        title: "Adopt as Wago addon " + u.wagoId,
        onclick: function () { Actions.adoptWago(u.folder, u.wagoId); }
      }, ["Adopt (Wago)"]));
    }
    actions.push(
      Utils.el("button", {
        type: "button", class: "btn btn-outline", disabled: busy, onclick: function () {
          const v = idInput.value.trim();
          if (!/^\d+$/.test(v)) { Components.Toast.show("Enter a numeric Project ID first.", "warning"); return; }
          Actions.adopt(u.folder, Number(v));
        }
      }, ["Adopt"]),
      Utils.el("button", { type: "button", class: "btn btn-danger-outline", onclick: function () { Actions.deleteUntracked(u.folder); } }, ["Delete"])
    );
    return Utils.el("div", { class: "untracked-row" }, [
      Utils.el("div", { class: "untracked-info" }, [
        Utils.el("div", { class: "untracked-folder" }, [u.folder]),
        Utils.el("div", { class: "untracked-meta" }, [u.title ? (u.title + (u.version ? " · " + u.version : "")) : (u.hasToc ? "No title in .toc" : "No .toc file")])
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
    diagChecks.forEach(function (c) { box.appendChild(diagRow(c)); });
    copyBtn.hidden = diagChecks.length === 0;
  }

  function diagRow(c) {
    return Utils.el("div", { class: "diag-row" }, [
      Utils.el("span", { class: "diag-dot " + (c.ok ? "is-ok" : "is-fail") }),
      Utils.el("span", { class: "diag-name" }, [c.name]),
      Utils.el("span", { class: "diag-detail" }, [c.detail || ""])
    ]);
  }

  // Plain text for the "Copy report" button - one line per check, no markup,
  // so it pastes cleanly into a bug report or a chat message.
  function diagnosticsReportText() {
    if (!diagChecks) return "";
    const lines = ["Furphy Addon Manager diagnostics - " + new Date().toLocaleString()];
    diagChecks.forEach(function (c) { lines.push((c.ok ? "[OK]   " : "[FAIL] ") + c.name + ": " + (c.detail || "")); });
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
    ["1", "2", "3"].forEach(function (v) {
      Utils.qs("#radio-release-" + v).addEventListener("change", function () { Actions.saveSettings({ releaseType: Number(v) }); });
    });
    Utils.qs("#toggle-autoupdate").addEventListener("change", function (ev) { Actions.saveSettings({ autoUpdateOnLaunch: ev.target.checked }); });
    // E19: only visible/enabled while renderBrowsing() has shown the row
    // (the native host is running) - see that function's comment.
    Utils.qs("#toggle-adfilter").addEventListener("change", function (ev) { Actions.saveSettings({ adFilter: ev.target.checked }); });

    Utils.qsa("#density-toggle .segmented-btn").forEach(function (btn) {
      btn.addEventListener("click", function () { Prefs.setDensity(btn.dataset.densityValue); renderAppearance(); });
    });
    Utils.qsa("#theme-toggle .segmented-btn").forEach(function (btn) {
      btn.addEventListener("click", function () { Prefs.setTheme(btn.dataset.themeValue); renderAppearance(); });
    });

    Utils.qs("#btn-toggle-apikey-visibility").addEventListener("click", function () {
      apikeyVisible = !apikeyVisible;
      const input = Utils.qs("#input-apikey");
      input.type = apikeyVisible ? "text" : "password";
      const btn = Utils.qs("#btn-toggle-apikey-visibility");
      btn.setAttribute("aria-label", apikeyVisible ? "Hide key" : "Show key");
      btn.title = apikeyVisible ? "Hide key" : "Show key";
      Utils.qs("#btn-toggle-apikey-visibility svg use").setAttribute("href", apikeyVisible ? "#icon-eye-off" : "#icon-eye");
    });

    // Round 6 fix: clicking into the masked field used to leave the mask
    // sitting there - a paste with no prior select-all landed the new key
    // in the middle of the dots/hint instead of replacing them. Clearing on
    // focus means a paste (or fresh typing) always replaces the whole value;
    // the hint line explains the old key is untouched until Save.
    Utils.qs("#input-apikey").addEventListener("focus", function () {
      const input = Utils.qs("#input-apikey");
      const s = Store.state.settings;
      if (s && s.hasApiKey && input.value === apikeyMask(s.apiKeyHint)) {
        input.value = "";
        showApikeyHint("Paste your new key — the current key ends in …" + (s.apiKeyHint || "") + " and stays until you Save.");
      }
    });
    // Blurring a field the user cleared-by-focusing but never actually typed
    // into restores the masked display (render() only repaints #input-apikey
    // while it isn't focused). Only when the field is genuinely EMPTY though:
    // clicking Save/Test blurs this field first (blur fires before the
    // button's own click handler), so unconditionally calling render() here
    // would wipe out real just-typed/pasted content before Save/Test ever
    // gets to read it.
    Utils.qs("#input-apikey").addEventListener("blur", function () {
      hideApikeyHint();
      const input = Utils.qs("#input-apikey");
      if (!input.value) render();
    });

    Utils.qs("#btn-save-apikey").addEventListener("click", function () {
      const input = Utils.qs("#input-apikey");
      const raw = input.value;
      const typed = extractTypedApiKey(raw);
      if (!typed) {
        // Round 6 fix: both of these used to silently do nothing at all - no
        // toast, no saved change, no indication the click was even seen.
        Components.Toast.show(raw ? "No change." : "No key entered — current key kept.", "info");
        return;
      }
      Actions.saveSettings({ cfApiKey: typed }, "API key saved (…" + typed.slice(-4) + ").")
        .then(function () { input.value = ""; apikeyVisible = false; input.type = "password"; hideApikeyHint(); })
        .catch(function () { /* error already toasted by saveSettings; keep the typed key in the field so the user can retry */ });
    });

    Utils.qs("#btn-clear-apikey").addEventListener("click", async function () {
      const ok = await Components.Dialogs.confirm({
        title: "Clear CurseForge API key?",
        message: "Browse, logos, descriptions, and changelogs from CurseForge will stop working until a new key is saved.",
        confirmLabel: "Clear key"
      });
      if (!ok) return;
      try {
        await Actions.saveSettings({ cfApiKey: "" }, "API key cleared.");
        Utils.qs("#input-apikey").value = "";
        hideApikeyHint();
      } catch (e) { /* error already toasted by saveSettings */ }
    });

    // Round 4 fix: a Test result describing the previously-typed key must not
    // linger once the user starts editing it again - it would go on describing
    // a value the field no longer holds.
    Utils.qs("#input-apikey").addEventListener("input", function () {
      const msg = Utils.qs("#apikey-test-result");
      msg.hidden = true;
      msg.className = "form-msg";
      msg.textContent = "";
    });

    Utils.qs("#btn-test-apikey").addEventListener("click", async function () {
      const input = Utils.qs("#input-apikey");
      const raw = input.value;
      // Round 6 fix: unambiguous about WHICH key is being tested - a pasted
      // value that still starts with the mask (defensive - focus already
      // clears it in the normal flow) is now correctly recognised as "real
      // content", instead of being treated as "using the saved key" and
      // testing the wrong one while blaming the freshly-pasted key.
      const typed = extractTypedApiKey(raw);
      const usingSaved = !typed;
      const s = Store.state.settings;
      const label = usingSaved
        ? (s && s.hasApiKey ? ("Saved key (…" + s.apiKeyHint + ")") : "No saved key")
        : "Pasted key";
      const msg = Utils.qs("#apikey-test-result");
      msg.hidden = false; msg.className = "form-msg is-info"; msg.textContent = "Testing — " + label + "…";
      const res = await Actions.testKey(usingSaved ? undefined : typed);
      msg.className = "form-msg " + (res.ok ? "is-success" : "is-error");
      msg.textContent = label + ": " + (res.ok ? "valid" : (res.message || "rejected"));
    });

    Utils.qs("#btn-open-wowfolder").addEventListener("click", function () { Actions.openWhat("folder"); });
    Utils.qs("#btn-open-addons").addEventListener("click", function () { Actions.openWhat("addons"); });
    Utils.qs("#btn-open-synclog").addEventListener("click", function () { Actions.openWhat("log"); });
    Utils.qs("#btn-open-lastrun").addEventListener("click", function () { Actions.openWhat("lastrun"); });
    // NOTE: SPEC section 2's base /api/open enum is 'log'|'folder'|'addons'|'curseforge'|'lastrun' -
    // there is no separate value for server.log. Rather than invent a field the server won't
    // recognise, this reuses 'log' until the contract grows a dedicated one. (Expansions E7 and
    // E3 have since added 'backups' and 'url' respectively - see the calls just below/above.)
    Utils.qs("#btn-open-serverlog").addEventListener("click", function () { Actions.openWhat("log"); });
    Utils.qs("#btn-open-backups").addEventListener("click", function () { Actions.openWhat("backups"); });

    // E16: forces a fresh fetch+merge of the offline CurseForge catalogue
    // index (Search-CfCatalogue/Get-CfCatalogueEntry's backing store) -
    // a plain fetch, not a job (mirrors Diagnostics' own "Run" button,
    // which is likewise never busy-gated - see the comment on Diagnostics'
    // Run binding above).
    Utils.qs("#btn-refresh-cf-catalogue").addEventListener("click", async function () {
      const btn = Utils.qs("#btn-refresh-cf-catalogue");
      const status = Utils.qs("#cf-catalogue-status");
      btn.disabled = true;
      status.textContent = "Refreshing…";
      try {
        const res = await Api.cfCatalogueRefresh();
        status.textContent = res.count + " addon(s) indexed, just now (" + res.source + ").";
        Components.Toast.show("CurseForge catalogue refreshed (" + res.count + " addons).", "success");
      } catch (err) {
        status.textContent = "Refresh failed: " + describeError(err);
        Components.Toast.show("Couldn't refresh the CurseForge catalogue: " + describeError(err), "error");
      } finally {
        btn.disabled = false;
      }
    });

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
        Components.Toast.show("Exported " + ((data.addons && data.addons.length) || 0) + " addon(s).", "success");
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
        msg.hidden = false; msg.className = "form-msg is-error"; msg.textContent = "That file isn't a Furphy Addon Manager export.";
        return;
      }
      const existingIds = new Set(Store.state.addons.map(function (a) { return a.projectId; }));
      const toAdd = data.addons.filter(function (a) { return a && !existingIds.has(Number(a.projectId)); }).length;
      const present = data.addons.length - toAdd;
      const ok = await Components.Dialogs.confirm({
        title: "Import addon list?",
        message: data.addons.length + " addon(s) in the file — " + toAdd + " will be added, " + present + " already present.",
        confirmLabel: "Import",
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
   App - bootstrap, view routing, polling loops, and one-time global wiring
   (nav, drawer/dialog/lightbox dismissal, sidebar buttons, shutdown beacon).
   ========================================================================== */
const App = (function () {
  let idleTimer = null;
  let jobPollTimer = null;
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
    Store.state.view = view;
    Utils.qsa(".nav-item").forEach(function (btn) { btn.classList.toggle("is-active", btn.dataset.view === view); });
    Utils.qsa(".view").forEach(function (sec) { sec.hidden = sec.dataset.viewRoot !== view; });
    Components.JobPanel.collapseIfOpen();
    renderCurrentView();
  }

  function renderCurrentView() {
    if (Store.state.view === "myaddons") Views.myAddons.render();
    else if (Store.state.view === "browse") Views.browse.render();
    else if (Store.state.view === "settings") Views.settings.render();
    renderChrome();
  }

  // Sidebar badges/status line, the Update-all label, global busy-disabling,
  // and a live drawer refresh - anything that isn't specific to one view.
  function renderChrome() {
    Utils.qs("#nav-count-total").textContent = Store.state.addons.length;
    const badge = Utils.qs("#nav-count-updates");
    const updates = Store.updatesCount();
    if (updates > 0) { badge.hidden = false; badge.textContent = updates; } else { badge.hidden = true; }

    renderStatusLine();
    renderUpdateAllButton();
    applyBusyToStaticButtons();
    Components.Drawer.refresh();
  }

  function renderStatusLine() {
    const dot = Utils.qs("#status-dot");
    const text = Utils.qs("#status-text");
    if (Store.state.online === false) { dot.dataset.state = "error"; text.textContent = "Server unreachable"; return; }
    if (Store.state.online === null) { dot.dataset.state = "connecting"; text.textContent = "Connecting…"; return; }
    dot.dataset.state = "ok";
    text.textContent = "Server OK" + (Store.state.updatesCheckedAt ? " — checked " + Utils.relativeTime(Store.state.updatesCheckedAt) : " — not checked yet");
  }

  function renderUpdateAllButton() {
    const btn = Utils.qs("#btn-update-all");
    const n = Store.updatesCount();
    const checked = !!Store.state.updatesCheckedAt;
    btn.textContent = checked && n > 0 ? ("Update all (" + n + ")") : "Update all";
    const busy = Store.isBusy();
    const nothingToDo = checked && n === 0;
    btn.disabled = busy || nothingToDo;
    if (busy) btn.title = "Another task is running";
    else if (nothingToDo) btn.title = "No updates found. Run Check for updates again after new releases.";
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
    pollJob(jobId);
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
        await reloadState(true);
        const summary = job.state === "failed" ? ("Failed: " + (job.error || "unknown error")) : Components.JobPanel.summarize(job.results);
        Components.Toast.show(summary, job.state === "failed" ? "error" : "success");
        notifyIfUpdatesFound(job);
      } catch (err) {
        markOnline(err);
        reloadState(true);
      }
    }, 800);
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
        || nextClientBuild !== Store.state.clientBuild;

      Store.set({
        addons: nextAddons, settings: nextSettings, lastRun: nextLastRun,
        job: nextJob, updatesCheckedAt: nextCheckedAt,
        clientBuild: nextClientBuild, clientInterface: nextClientInterface,
        loadingState: false, stateError: null
      });
      if (!afterJob) resumeJobPollingIfNeeded();
      if (changed) renderCurrentView();
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
    renderStatusLine();
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
  // view currently on screen; a no-op in Settings and in Browse without a key
  // (its search box is hidden behind the no-key panel).
  function focusCurrentSearch() {
    if (Store.state.view === "myaddons") { Utils.qs("#myaddons-search").focus(); return; }
    // E12: Wago's search box is always usable (no key needed). E16: so is
    // CurseForge's now, keyed or not (a keyless session searches the
    // offline catalogue/addon-radar instead of the official API) - the
    // only state that still blocks it is a REJECTED key, which replaces
    // #browse-content (and its search box) with a dedicated blocking panel.
    const rejected = !!(Store.state.settings && Store.state.settings.hasApiKey) && Store.state.cfKeyRejected;
    const canFocusBrowseSearch = Store.state.browse.source === "wago" || !rejected;
    if (Store.state.view === "browse" && canFocusBrowseSearch) { Utils.qs("#browse-search").focus(); }
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
    wireGlobal();
    Views.myAddons.bindOnce();
    Views.browse.bindOnce();
    Views.settings.bindOnce();

    await fetchPingInfo();
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
    onJobStarted: onJobStarted, reloadState: reloadState, init: init,
    getServerVersion: function () { return serverVersion; }, getServerUptime: currentUptime,
    getServerHost: function () { return serverHost; }
  };
})();

document.addEventListener("DOMContentLoaded", function () { App.init(); });
