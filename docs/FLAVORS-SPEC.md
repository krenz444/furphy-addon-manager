# FLAVORS-SPEC.md — Multi-Flavour Support for Furphy Addon Manager

Authoritative design. Synthesized from three independent proposals (`switcher`, `minimal-delta`, `all-at-once`) judged 3x by independent panels (tally: switcher 123, all-at-once 111, minimal-delta 107). **Base architecture is `switcher`** — one app, one server process, one port, one `curseforge://` registration, per-flavour subfolders addressed by an explicit `?flavour=` query param, switcher UI that is entirely absent (not hidden) below two installed flavours. Grafted in: `all-at-once`'s and `minimal-delta`'s dynamic Interface-number-driven CurseForge/Wago flavour resolution for the rolling Classic client (replaces switcher's original static "Classic = 79434" hardcode, which every judge flagged as the design's weakest point), and `all-at-once`'s single "Update All" bulk-sync action. Dropped: `all-at-once`'s cross-flavour joined list/multi-badge-per-row UI (correctness risk from name-fallback joining, and tension with the project's one-status-pill-per-row rule) and `minimal-delta`'s N-process-per-flavour architecture (heavier runtime, fragile "most-recently-active port" routing).

**Non-negotiable outcome:** on this machine (Retail only), every byte of behavior, every pixel of UI, and every on-disk path is unchanged after this ships. Multi-flavour support is additive and provably invisible at n=1.

---

## 1. Principles

1. **One install, one server, one port, one `curseforge://` registration — always.** Flavours are subfolders and a query parameter inside the existing app, never separate processes, ports, or installs. This is what keeps `register-protocol.ps1` untouched and avoids any cross-process routing file.
2. **Invisible at one flavour.** Every new piece of UI (switcher, badges, multi-row About/Settings, Update-All) renders **zero DOM**, not `display:none`, when `installedFlavours.length <= 1`. A single-flavour machine's HTML output, API payloads (modulo two new always-present fields, §5.2), and file layout are indistinguishable from today's.
3. **Zero data loss, and reversible.** Existing Retail users' `addons.json`/`state.json`/`backups\` migrate through a copy-first, atomic, idempotent, one-time step with a documented manual undo. Nothing is ever deleted.
4. **Never hardcode a value that a game patch will make wrong.** Classic (`_classic_`) is a *rolling progression* client — its correct CurseForge `gameVersionTypeId` and Wago `game_version` change over time. Resolve them **dynamically** from the installed client's own Interface number via a small, appendable range table — never a single "current expansion" literal.
5. **Explicit over implicit.** Every addon-scoped API call names its flavour via `?flavour=`. No server-side "current active flavour" global is ever load-bearing for a data operation — only for UI convenience (§5.1).
6. **Hardcore and Anniversary are realms, not flavours.** They run inside `_classic_era_` — one folder, one client, one AddonSync subtree. They are explained in copy, never modeled as separate ids.
7. **Read-only, generic detection.** Flavour presence is derived from what's actually on disk (`Interface\AddOns` existing under a known-or-plausible folder name) plus `.build.info` as corroboration, never from asking the user to configure anything, and never by assuming a flavour is or isn't installed.

---

## 2. Detection

### 2.1 Vocabulary (fixed order — this is the order every list/switcher renders in)

| Internal id | Folder | Player-facing label | `.build.info` `Product` (expected) | First-class in v1? |
|---|---|---|---|---|
| `retail` | `_retail_` | **Retail** | `wow` | yes |
| `classic` | `_classic_` | **Classic** *(current progression — see §2.4)* | `wow_classic` | yes |
| `classic_era` | `_classic_era_` | **Classic Era** | `wow_classic_era` | yes |
| `ptr` | `_ptr_` | **PTR** | `wowt` | detected, hidden by default (§2.5) |
| `xptr` | `_xptr_` | **PTR (2)** | `wowxptr` (unconfirmed) | detected, hidden by default |
| `beta` | `_beta_` | **Beta** | `wow_beta` (unconfirmed) | detected, hidden by default |

Verified live 2026-09-04: this machine has `_retail_` only (`Wow.exe` 12.1.0.69587, `.build.info` single row `Product=wow`). No classic client installed anywhere accessible — every non-retail code path below must be validated against the synthetic fixture (§8), not a real client.

### 2.2 What "installed" means

A flavour counts as installed when **both**:
1. `<WowRoot>\<folder>\Interface\AddOns` exists (need not contain any addon yet — a fresh Battle.net install creates this path empty; `Resolve-AddonsPath` already tolerates that for Retail today).
2. The folder name is one of the six in §2.1, **or** the generic fallback (§2.6) fires for an unrecognized folder.

`.build.info` (pipe-delimited, typed-header table, confirmed live at `<WowRoot>\.build.info` — this machine's single row: `Product=wow, Version=12.1.0.69587, CDN Path=tpr/wow`) is **corroboration, not the primary signal**. When a row's `Product` matches the flavour's expected code, its `Version` string feeds the About panel (§6) and the Interface-range resolution (§2.4). When no matching row exists (stale/missing/unreadable `.build.info`, or a fresh classic install that hasn't launched once), the flavour still counts as installed — folder + AddOns path wins — and the build number shows as "—" (existing About-panel dash convention). `Get-InstalledFlavours` must never throw or hide a flavour for a `.build.info` mismatch; log once via the existing `Write-Log` pattern and move on.

### 2.3 New function: `Get-InstalledFlavours -WowRoot <path>`

Added once to **both** addon-sync.ps1 and addon-server.ps1 (existing duplication pattern — every shared helper already lives in both files). It:
1. Resolves `$WowRoot` (CLI: new `-WowRoot` override, defaulting to walking up from `$PSScriptRoot` until a folder containing any §2.1 flavour folder is found — this generalizes `Resolve-AddonsPath`'s current "parent leaf must equal `_retail_`" check, addon-sync.ps1 L2153-2179, into "parent leaf must be one of the known flavour folder names, tell me which").
2. Tests §2.2's two conditions for each of the six known folders, building `{id, folder, label, addonsPath, buildInfoRow, buildInfoMissing}` objects **in §2.1's fixed order**.
3. Appends any unknown folder that passes §2.6's fallback.
4. Returns `[]` only if the WoW root itself can't be resolved at all (existing fatal exit-code-2 path, unchanged).

### 2.4 Classic's rolling progression — dynamic resolution (grafted from `all-at-once`/`minimal-delta`)

`_classic_` is not pinned to one expansion; it has been Vanilla → TBC → Wrath → Cataclysm → Mists Classic (current, per live recon 2026-09-04) and will advance again. **Never hardcode "Classic = MoP = TypeId 79434."** Instead, resolve the live progression era from the client's own reported Interface number (already read via `Get-ClientBuildInfo`/`Get-TocInterfaceValues`'s existing Interface-parsing machinery) against this table:

| Interface prefix | Era | CurseForge `gameVersionTypeId` | Wago `game_version` | `.toc` suffix (X-Flavor tag) |
|---|---|---|---|---|
| `11.x` (11500-11599) | Classic Era (Vanilla) | 67408 | `classic` | `_Vanilla` (`Vanilla`) |
| `20.x` (20500-20599) | Burning Crusade Classic | 73246 | `bc` | `_TBC` (`TBC`) |
| `30.x`/`38.x` (30400-30699, 38000-38099) | Wrath Classic | 73713 | `wotlk` | `_Wrath` (`Wrath`) |
| `40.x` (40400-40499) | Cataclysm Classic | 77522 | `cata` | `_Cata` (`Cata`) |
| `50.x` (50500-50599) | Mists Classic | 79434 | `mop` | `_Mists` (`Mists`) |
| `12.x` | Retail | 517 | `retail` | `_Mainline` (`Mainline`) |

This table is the single place a future expansion bump is handled: append one row (new Interface prefix, new TypeId once CurseForge assigns one, new Wago value, new suffix) — no other code changes. `classic_era`'s Interface is always in the `11.x` row by definition (frozen client); `retail` and `classic_era` are therefore **static** lookups, while `classic` is **always** resolved dynamically through this table at call time, never cached as a fixed id.

A 7th CurseForge flavour was found live during recon — `81212`/"Titan Reforged Classic" (`titan_classic` in instawow-data), version prefix `3.80.x`. Its in-game meaning is unconfirmed (postdates training data, no CurseForge description). It is **not** wired to a Furphy flavour folder in v1 (no known Blizzard client folder maps to it) — it is picked up automatically, disabled by default, only if §2.6's generic fallback ever encounters a matching folder. Do not build UI copy for it speculatively.

### 2.5 PTR / XPTR / Beta

Detected (§2.3) but **excluded from the switcher and from tray background sync by default** — a new Advanced setting, **"Show test realms (PTR/Beta)"**, off by default (most players don't want PTR cluttering a daily-use menu, and background-syncing addons against a wipe-prone test client is unhelpful). When on, they behave like any other flavour everywhere in this spec. Their CurseForge/Wago mapping defaults to Retail's row (`517`/`retail`) per Recon 1 — flagged unconfirmed, safe fallback.

(Round 38, 2026-09-08: this "excluded by default" rule also covers install.ps1's own first-run "adopt existing addon folders" step, not just the switcher/tray-sync surfaces named above - a QA pass found the adopt loop had been iterating every detected flavour unfiltered, so a machine with a live PTR client got its PTR AddOns folder scanned and any recognizable addons silently adopted into flavours\ptr\addons.json before the player ever turned "Show test realms" on. Fixed to use the same first-class-only filter every other surface already respects; see CHANGELOG.md's Round 38 entry.)

### 2.6 Generic fallback (future-proofing)

A folder under `<WowRoot>` that is **not** one of the six known names, but (a) contains `Interface\AddOns`, and (b) has a `.build.info` row whose `Product` isn't already claimed, is surfaced as an **Unknown flavour**: label = the `.build.info` `Product` string verbatim (no attempt to prettify a name Furphy doesn't recognize), disabled by default (same toggle as §2.5). This is the mechanism that would eventually cover a 7th client folder (e.g. a future Titan Reforged Classic client) without a Furphy code update being a hard prerequisite for detection — it just won't sync until someone maps its TypeId.

### 2.7 Naming: Retail / Classic / Classic Era, and the Hardcore/Anniversary explanation

- **"Classic"** — never "Classic Progression," never the current expansion's name as the label. The label is stable across patches; a *subtitle* (switcher tooltip, About row, Settings folder row) may show the live era resolved via §2.4, e.g. "Classic — Mists of Pandaria," decorative only, never required for function.
- **"Classic Era"** always carries the subtitle/tooltip **"Includes Hardcore & Anniversary realms"** wherever there's room for one (switcher tooltip, Settings folder list, first-run detection dialog) — never inline in the compact switcher pill itself (word budget). This is the one, sufficient answer to "how are Hardcore/Anniversary explained": they are realm rulesets inside Classic Era's single client/folder, not separate flavours anywhere in the data model, detection, or switcher. Furphy manages addons per **client**, matching Blizzard's own folder layout, never per **realm**.

---

## 3. Data model, migration, backups

### 3.1 File layout

The app's home stays at `<WowRoot>\_retail_\AddonSync` for any machine with Retail — unchanged path, unchanged shortcut, unchanged protocol-handler target. Two levels up is `<WowRoot>`, already the app's own reference point today. Per-flavour data nests one level deeper:

```
<WowRoot>\_retail_\AddonSync\
  settings.json                    <- shared, one file (see §3.4)
  flavours\
    retail\
      addons.json
      state.json
      backups\<projectId>\<fileId>.zip
    classic\
      addons.json
      state.json
      backups\...
    classic_era\
      addons.json
      state.json
      backups\...
  jobs\                             <- shared job-history dir; each job object gains a `flavour` field (§5.4)
  cache\                            <- shared CurseForge/Wago catalogue cache — flavour-agnostic, unchanged
  sync.log                          <- shared log; lines gain a `[retail]`/`[classic]` prefix
```

Only subfolders for **installed** flavours are ever created — this machine ends up with exactly `flavours\retail\`, byte-for-byte the two JSON files it has today, one directory level deeper.

**Classic-only machine** (no `_retail_` at all): `install.ps1`'s `Find-WowRoot` (§7.1) is relaxed to accept any known flavour folder; the app installs into `<WowRoot>\<first-detected-flavour-by-§2.1-order>\AddonSync` instead, deterministic and documented.

### 3.2 addons.json / state.json — no schema change

Per-flavour records keep **exactly today's shape** — no new `flavour` field on individual records, because the folder they live in (`flavours\<id>\addons.json`) already scopes them unambiguously. This is a deliberate simplification versus a "stamp every record" approach: fewer fields to keep consistent, and it sidesteps any risk of a record's stamped flavour disagreeing with the file it's actually stored in.

### 3.3 Migration — zero data loss, one-time, idempotent, reversible

Runs once at CLI/server startup, before any path resolution, as `Invoke-FlavourMigration`:

1. Check `settings.json` for `schemaVersion`. Absent or `1` = pre-flavour install.
2. If pre-flavour: create `flavours\retail\`.
3. **Before moving anything**, copy (not move) the existing top-level `addons.json`, `state.json`, and `backups\` into `flavours\_migration-backup-<yyyyMMdd-HHmmss>\` — cheap (same volume, same parent), and gives a manual undo path (copy back up one level, delete `flavours\`, fully reverts). This backup step runs exactly once, guarded by the `schemaVersion` check in step 1.
4. **Then move** (`Move-Item`) the three items into `flavours\retail\`. Guard each file/folder individually with `Test-Path (Join-Path $flavourDir <name>)` first and skip any that already landed — so a crash-and-retry mid-migration never overwrites a half-moved state, and the one-time backup copy in step 3 never re-runs on retry.
5. Set `schemaVersion: 2` in `settings.json` only after every move in step 4 succeeds.
6. List (never auto-delete) the migration-backup folder in **Settings > Advanced > Troubleshooting**, alongside the existing "Open logs folder" affordance — a worried upgrader can see the safety net is there.
7. **Documented rollback:** reinstalling an older Furphy build over a migrated folder looks for `addons.json`/`state.json` at the top level and won't find them (an old build doesn't know about `flavours\`) — so the *documented* rollback is "restore from `flavours\_migration-backup-<timestamp>\`," called out explicitly in CHANGELOG.md's entry for this change set (§9, CS-F7) so a support thread has the answer ready, rather than relying on an old binary to cope.

### 3.4 settings.json — new fields

```json
{
  "...existing fields unchanged...": "releaseType, port, adFilter, cfFocus, hostWindow, hostTheme",
  "schemaVersion": 2,
  "activeFlavour": "retail",
  "showTestRealms": false
}
```

`activeFlavour` is only a **UI-continuity default** for which flavour's view to load after a reload — never consulted server-side to decide what a data-mutating request means (principle 5). `showTestRealms` is §2.5's toggle. No per-flavour settings exist — port, theme, ad filter, background-sync interval all stay single global values.

### 3.5 Backups

Unchanged structure (`backups\<ProjectId>\<FileId>.zip`), just nested one level under each flavour's own subfolder — collision-free by construction, since two flavours never share a `flavours\<id>\` directory.

---

## 4. CLI (addon-sync.ps1)

### 4.1 `-Flavor` parameter

Accepts one of §2.1's ids, validated against `Get-InstalledFlavours`'s live result (an unrecognized or not-installed value is a clean, existing-style fatal error, not a crash). Default: `-Flavor retail` when `_retail_` is installed (preserves every existing manual invocation, script, and scheduled task byte-for-byte); otherwise the first flavour `Get-InstalledFlavours` returns.

### 4.2 Path resolution

`Resolve-AddonsPath` (L2153-2179) becomes `Resolve-AddonsPath -Flavor <id>`: walks up to `<WowRoot>` exactly as today, then re-descends into `<WowRoot>\<folder-for-id>\Interface\AddOns` instead of hardcoding `_retail_`. Fatal-exit-2 behavior preserved for a flavour that isn't installed. `Resolve-EffectiveAddonsPath` in addon-server.ps1 (L472-486) gets the identical change, in the same change set.

### 4.3 `Get-ClientBuildInfo` (L1706-1767)

Gains a `-Product` param (or derives it internally from `-Flavor` via §2.1's mapping) instead of the hardcoded `Product -eq 'wow'` filter. Returns gracefully per §2.2's builder note — never fatal.

### 4.4 CurseForge file selection — `Select-CfFile` (L477-507)

Gains a `-TypeId` param, resolved via §2.4's table (static for `retail`/`classic_era`, dynamic-from-Interface-number for `classic`):

```powershell
function Resolve-CfTypeId {
  param([string]$Flavor, [int]$InstalledInterface)
  switch ($Flavor) {
    'retail'      { return 517 }
    'classic_era' { return 67408 }
    'classic'     { return Resolve-ClassicProgressionTypeId -Interface $InstalledInterface }  # walks §2.4's table
    default       { return 517 }  # ptr/xptr/beta default to retail's TypeId, unconfirmed but safe (§2.5)
  }
}
```

`Test-FileHasGameVersion12` (L463-475) becomes `Test-FileHasGameVersionPrefix -Prefix <string>`, driven by §2.4's Interface-prefix column (`"12."` retail, `"1.15."` classic era, and whichever prefix the resolved Classic era uses) instead of the literal `"12."`. The existing two-pass releaseType logic inside `Select-CfFile` is unchanged in structure — pure parameterization, confirmed by recon.

The manual-file-picker UI call site (L3292, `retail = (Test-FileHasTypeId -File $f -TypeId 517)`) becomes flavour-parameterized the same way, driven by the same resolver.

**Verified CurseForge `gameVersionTypeId` table (live, 2026-09-04):**

| TypeId | Label | Version prefix |
|---|---|---|
| 517 | Retail | 12.x |
| 67408 | Classic (Vanilla/Classic Era) | 1.15.x |
| 73246 | Classic TBC | 2.5.x |
| 73713 | WotLK Classic | 3.4.x |
| 77522 | Cataclysm Classic | 4.4.x |
| 79434 | MoP Classic | 5.5.x |
| 81212 | Titan Reforged Classic | 3.80.x |

A file's `gameVersionTypeIds` array can contain literal duplicates — dedupe with a Set before use (confirmed: DBM-Core-12.1.6.zip shipped `[79434,517,517,73246,67408,81212]`). The keyless files endpoint has no server-side flavour filter (a `gameVersionTypeId` query param is silently ignored) — flavour filtering must stay client-side, exactly as `Select-CfFile` already does; per-flavour "latest file" must be computed independently per flavour, never as "take the single newest file overall" (proven necessary by WeakAuras, which ships separate files per flavour track at different release cadences — its newest-overall file at one point had no Retail support at all).

### 4.5 `.toc` selection — `Get-PrimaryTocFile` (L967-1017), `Get-TocInterfaceValues` (L1576-1655)

Gains a `-Flavor` param (and, for `classic`, the era resolved via §2.4). Selection order, **primary signal first**:

1. **`## X-Flavor:` tag** inside any `.toc` in the folder (confirmed real and machine-readable — values seen live: `Mainline`, `Vanilla`, `TBC`, `Wrath`, `Cata`, `Mists`, e.g. WeakAuras). When present on any file in the folder, it is authoritative — pick the file whose tag matches the target flavour/era.
2. **Filename-suffix table** (fallback, when no `X-Flavor` tag exists anywhere in the folder; both underscore and hyphen forms are real — Details ships `_Classic`/`-Classic` side by side):

   | Flavour/era | Suffixes, in try-order |
   |---|---|
   | Retail | `_Mainline`, `-Mainline`, bare `{Folder}.toc` |
   | Classic Era | `_Vanilla`, `_Classic`, `-Classic` |
   | Classic → TBC era | `_TBC`, `-BCC` |
   | Classic → Wrath era | `_Wrath`, `-Wrath`, `-WOTLKC` |
   | Classic → Cata era | `_Cata` |
   | Classic → Mists era | `_Mists` |

   **Caveat, implement exactly:** bare `{Folder}.toc` is *only* retail's fallback when **no other flavour's suffixed file exists in the folder**. Build the full suffix-to-flavour map for every flavour Furphy knows, scan the folder's actual `.toc` files, and only fall through to "bare name = whichever flavour has no matching suffix among Retail/Classic/Classic Era" if exactly one flavour is left unclaimed after checking every other flavour's suffixes present — else bare name defaults to retail (today's behavior, unchanged for the overwhelmingly common case; confirmed correct against every real sample found: DBM-Core, Details, WeakAuras, AngryKeystones all use the bare name for retail with no exception observed).
3. Else: first `.toc` found (today's last-resort, unchanged).

Duplicated in addon-server.ps1 (L624-655) in the **same change set** — both copies must never drift (existing established pattern).

`Get-TocInterfaceValues` gains the equivalent `## Interface-<Flavour>:` tag awareness alongside the existing `## Interface-Mainline:` handling. **Flagged unconfirmed:** no real sample found of a single `.toc` carrying multiple flavour-specific Interface overrides (every real multi-flavour package sampled — Details, WeakAuras — used *separate files per flavour*, each with one plain `## Interface:` line). Builder must re-verify this mechanism is actually needed against a real multi-Interface `.toc` before implementing it; if none exists, skip it and rely on the file-selection-per-flavour in point 1-3 above, which already gets the right file's own `## Interface:` line.

### 4.6 Wago release selection — `Select-WagoRelease` (L799-824)

Gains a `-Flavor` param mapped to Wago's field-name table (confirmed live against `addons.wago.io` and cached Inertia JSON):

```powershell
$Script:FlavourWagoField = @{
  retail = 'retail'; classic_era = 'classic'
  # classic resolved dynamically per §2.4: 'bc' | 'wotlk' | 'cata' | 'mop'
}
```

Checks `$r.supported_<field>_patches` non-empty exactly as today's retail-only check does (L814), just parameterized; the Wago request's `game_version` query param is set from the same table. Every Wago release object carries all six `supported_*_patches` keys regardless of which flavours it actually ships for — "supported" means non-empty array, never key presence alone.

**Verified Wago `game_version` values (live UI dropdown, 2026-09-04):** `retail` (Retail), `mop` (Mists Classic), `cata` (Cataclysm Classic), `wotlk` (Wrath Classic), `bc` (Burning Crusade Classic), `classic` (Classic Era). No separate Wago value exists for a hypothetical Titan Reforged track — not wired.

(Round 34, 2026-09-07: section 4.7, "`-Launcher` mode per flavour" - the per-flavour `-Launcher` handoff to Battle.net and its product-code table - was removed at Eric's request along with the CLI's `-Launcher` mode entirely. See CHANGELOG.md. Nothing replaces it: the background service already updates every flavour on its own schedule, so a per-flavour launch handoff is no longer needed.)

---

## 5. Server API (addon-server.ps1)

### 5.1 Flavour addressing: explicit query param, always

Every endpoint that reads or writes addon-scoped data (addons list, sync/update/rollback jobs, scan/adopt, Wago search, freshness) takes `?flavour=<id>` (alias `flavor=` accepted too, canonicalized internally). No server-side "current flavour" global is ever load-bearing for a data operation — this avoids a background tray sync for Classic silently answering a foreground browser tab's Retail request, or vice versa.

**Scope of the 400 rule, narrowed from the original proposal per judge feedback:** a request to one of the small, fixed set of addon-scoped endpoints listed above, made while more than one flavour is installed, and omitting `?flavour=`, is a 400 with a plain message ("flavour required"). This set is enumerated once in a shared list (`$Script:FlavourScopedEndpoints`) that both the router and a startup self-check assert against, rather than being an unenforced convention scattered across call sites — cheap to add and it makes a missed call site fail loudly in dev instead of silently serving the wrong flavour's data. A single-flavour machine (this one) never needs to send the param — the server defaults to the one installed flavour, so **zero client-side change is required for today's Retail-only UI to keep working untouched.**

### 5.2 `/api/state` shape

```json
{
  "installedFlavours": [
    {"id": "retail", "label": "Retail", "addonsPath": "...", "clientBuild": "12.1.0.69587", "clientInterface": 120100},
    {"id": "classic_era", "label": "Classic Era", "subtitle": "Includes Hardcore & Anniversary realms", "addonsPath": "...", "clientBuild": "1.15.9.xxxxx", "clientInterface": 11509, "buildInfoMissing": false}
  ],
  "activeFlavour": "retail",
  "flavour": "retail",
  "addons": [ "...unchanged shape, scoped to the requested flavour..." ],
  "freshness": "...", "clientBuild": "...", "clientInterface": "...",
  "...every other existing top-level field, unchanged, now scoped to `flavour`...": true
}
```

`installedFlavours` and `activeFlavour` are the only two fields present **regardless of `?flavour=`** (they describe the machine, not one flavour's data). Everything else is that one flavour's slice — the existing single-flavour shape, unchanged, just parameterized. `Handle-State` (L4019-4087) changes are additive: two new top-level fields, and its body reads from `flavours\<flavour>\addons.json`/`state.json` instead of the old top-level paths.

### 5.3 Freshness per flavour

Each flavour's freshness/staleness is computed exactly the way today's single headline is, once per flavour. The single top-level freshness headline shown when a specific `?flavour=` is requested reflects that flavour only — there is deliberately **no cross-flavour aggregate headline** in this design (that was `all-at-once`'s unified-list idea, dropped for its join-correctness risk and one-pill-per-row tension); a player checking "is everything ready" switches the pill (§6.1) or uses the tray's per-flavour tooltip breakdown (§5.6).

### 5.4 Jobs

`job.flavour` is a new required field on job creation (`Build-CliArgs`/`Start-Job`, threading `-Flavor $flavour` into the CLI invocation alongside the existing `-ProgressPath`). `Test-JobBusy`'s single-job-at-a-time guard becomes **per-flavour scoped** (a Retail sync and a Classic Era sync may run concurrently; two Retail syncs still can't) — this is what lets the tray (§5.6) sync every installed flavour without serializing behind each other. Job history and the job panel UI display a flavour badge next to a job's title only when more than one flavour is installed (reuses the switcher's own pill component, §6.1).

A new bulk job kind, `{kind: "update-all-flavours"}`, fans out into one per-flavour update job (reuses the existing per-flavour update-all logic, looped) — this backs the UI's "Update All" action (§6.3) and the tray's scheduled sync (§5.6).

### 5.5 Protocol handler + embedded-site install targeting — which flavour receives an install

`curseforge-handler.vbs` and `register-protocol.ps1` are **unchanged** — there is only ever one Furphy install/server/port to register, so the single-registration model already works (this fully resolves the multi-install `curseforge://` conflict recon flagged, without touching either file). Flavour resolution happens **server-side**, on receiving a CurseForge install POST:

1. Fetch the target file's `gameVersionTypeIds` (already required to install it anyway — no new network call).
2. Intersect with the set of the user's **installed, non-hidden** flavours (via §4.4's TypeId table).
3. **Exactly one match** → install there silently, no prompt. Covers every install on this Retail-only machine, and the overwhelming common case generally.
4. **Zero matches** → job fails immediately with the plain message *"This addon doesn't support your installed WoW versions."* (Retry not offered — nothing to retry until a supporting flavour is installed.)
5. **More than one match** → the job is created in a new `awaiting_flavour` state; the UI shows a lightweight inline picker reusing the switcher's pill styling — *"Which version? [ Retail ] [ Classic Era ]"* — and picking one resumes the job with `?flavour=` set. This is the **only** new dialog this whole feature introduces to the install flow.

The same three-way logic (auto/refuse/ask) applies to the in-app Get New Addons "Install" button (§6.4) and to `-AddByLink`/`-AddById` CLI invocations without an explicit `-Flavor` (case 5 there prints the choices and exits non-zero, matching the CLI's existing plain-exit-code convention — no picker to show from a terminal).

The embedded CurseForge tab's own navigation (`curseforge.com/wow/addons`, `/wow/search?...`) is **not required to change** for this feature — the picker above is what actually guarantees correctness regardless of what filter was showing in the embedded pane. A future deep-link enhancement (passing CurseForge's own flavour filter param into the pane's starting URL when the switcher changes) is explicitly optional, out of scope for v1.

### 5.6 Tray sync-all (contract for when it's built)

Not present in this codebase snapshot as of this recon pass (searched CHANGELOG.md, ROADMAP.md, `host\FurphyHost.cs` — zero matches for tray/mutex/backgroundUpdates/tray-state.json). This section is the contract it must be built against from the start, not retrofitted later:

- **One tray icon, one mutex (`FurphyAddonManager.Tray`), one set of settings** (`backgroundUpdates`, `backgroundIntervalMinutes`, `runAtStartup`) — all stay global, never per-flavour. A flavour is an internal detail of what the tray loops over.
- On each scheduled tick, the tray posts **one** `{kind: "update-all-flavours"}` job (§5.4) to the already-running server (or starts it if not running, unchanged from today's contract) — excluding PTR/Beta unless §2.5's toggle is on. Per-flavour job-busy scoping (§5.4) lets these run concurrently.
- **Tooltip wording:**
  - Single flavour, nothing to do: `"Furphy — up to date"` (unchanged).
  - Single flavour, updates already installed: `"Furphy — Updated 3 at 14:05"` (past tense — the background cycle already applied the updates, matching the "Running — updated N at HH:MM" convention in UX-SPEC's Settings status line).
  - Multiple flavours, all up to date: `"Furphy — up to date"` (still one line — never announce "up to date" once per flavour).
  - Multiple flavours, mixed: `"Furphy — Updated 3 at 14:05 (Retail: 2, Classic: 1)"` — same past-tense "Updated N at HH:MM" stem as the single-flavour case, with a label-and-breakdown appended in parens, not a sentence, matching UX-SPEC's "plain words" rule.
- Left-click on the tray icon opens the native host to **My Addons on the last-active flavour** (`activeFlavour`, §3.4) — not a flavour picker; the switcher inside the app is where that choice lives.

---

## 6. UI (ui/app.js, ui/index.html)

### 6.1 Switcher

A compact segmented pill row, mounted once, directly under the nav row (`My Addons | Get new addons | Settings`):

```
  My Addons     Get new addons     Settings
  [ Retail ] [ Classic ] [ Classic Era ]
  ●  Everything's up to date · checked 5m ago
```

- **Entirely absent from the DOM** (not `display:none` — principle 2) when `installedFlavours.length <= 1`. This machine's UI is byte-for-byte what it is today.
- Each pill shows only its short label — no inline subtitle (word budget). Classic Era's "Includes Hardcore & Anniversary realms" is the pill's tooltip/`aria-label` only.
- Clicking a pill re-requests `/api/state?flavour=<id>`, swaps `Store.state.addons`/`freshness`/etc., and persists the choice to `settings.json`'s `activeFlavour` (fire-and-forget PATCH, not blocking the switch) so a reload lands back on the same flavour.
- Active pill uses a neutral `is-active` background/text treatment (`.flavour-pill.is-active`, `ui\style.css`), not the accent color. (Round 34, 2026-09-07: this originally called out an exception where the switcher's active pill and the sidebar's "Update & Play" button could both be accent-colored at once - moot now that "Update & Play" is gone entirely and nothing in the app is accent-colored any more, see CHANGELOG.md.)

### 6.2 Badges — About, Settings, Job panel

- **About panel** (`index.html` L665, single `<dd id="about-client-build">` today): becomes a small per-flavour list only when >1 flavour installed — `Retail — 12.1.0.69587`, `Classic Era — 1.15.9.xxxxx`. `buildInfoMissing` flavours show `— version unknown (launch this client once)`. Single-flavour machines: unchanged single `<dd>`.
- **Settings > Advanced > Game folders** (UX-SPEC §6.2): one row per installed flavour — `Retail: <path> [Open]`, `Classic: <path> [Open]`. Single-flavour machines: today's exact one row.
- **Job panel / history:** a small flavour pill next to a job's title, shown only when >1 flavour installed (§5.4).

No addon **row** ever carries more than one status pill (UX-SPEC's existing hard rule, preserved exactly) — because each view is scoped to one flavour at a time (§5.1/§6.1), this is never in tension the way a cross-flavour joined-row design would be.

### 6.3 Update All

(Round 34, 2026-09-07: this section originally also specced a per-flavour "Update & Play"/"Update & Open Battle.net" sidebar button with a reliability-caveat-driven copy split between flavours - removed entirely at Eric's request along with every launch-WoW feature; see CHANGELOG.md. Nothing replaces it.)

A separate, always-visible **"Update All"** button (only rendered when >1 flavour installed) fires `{kind: "update-all-flavours"}` (§5.4) — syncs every installed, non-hidden flavour, launches nothing. This is the one bulk convenience grafted from the `all-at-once` proposal: it answers "get every flavour's addons current in one click" without introducing a cross-flavour launch concept, since the background service (not this button) is what actually keeps addons updated.

### 6.4 Get New Addons

- **Wago segment:** search requests append `game_version=<mapped value>` (§4.6's table) for the currently active flavour — results become flavour-relevant instead of always-retail. No new UI chrome; a silent correctness fix riding the existing search box.
- **CurseForge segment (embedded site):** unaffected structurally (§5.5) — the install-flavour picker is what guarantees correctness, not a deep-link change.
- The install-flavour picker from §5.5 (case 5) renders as a small modal reusing the switcher's pill styling, title **"Which version of WoW?"**

### 6.5 Settings — new fields

- **"Show test realms (PTR/Beta)"** toggle (section 2.5), off by default, no explainer sentence (label states its own effect). (Round 34, 2026-09-07: this section originally also specced a "Launch product code override" advanced setting - removed along with section 4.7's `-Launcher` mode it hedged for; see CHANGELOG.md.)

### 6.6 Copy table

| Area | New string |
|---|---|
| Switcher pill (Retail) | "Retail" |
| Switcher pill (Classic) | "Classic" |
| Switcher pill (Classic Era) | "Classic Era" — tooltip: "Includes Hardcore & Anniversary realms" |
| Switcher pill (PTR) | "PTR" |
| Bulk sync button | "Update All" |
| Settings > Advanced toggle | "Show test realms (PTR/Beta)" |
| Settings > Advanced > Game folders row | "Retail: `<path>` [ Open ]" (one row per installed flavour) |
| About, per-flavour build row | "Retail — 12.1.0.69587" |
| About, missing build info | "— version unknown (launch this client once)" |
| Install-flavour picker title | "Which version of WoW?" |
| Install-flavour picker, no match | "This addon doesn't support your installed WoW versions." |
| Tray tooltip, multi-flavour mixed | "Furphy — 3 updates ready (Retail: 2, Classic: 1)" |
| Job panel flavour badge | flavour label only (reuses switcher pill styling) |
| Wago drawer table header (app.js L2791) | "Patches" (was "Retail Patches" — was already wrong-by-name for any non-retail addon; renamed regardless of flavour count since the drawer's data source is touched anyway) |
| First-run take-over dialog, per flavour | "Found 4 addons in your Classic Era AddOns folder" (flavour name inserted into the existing UX-SPEC §2.4 string, only when more than one flavour's dialog is shown in sequence) |

---

## 7. Installer, shortcut

### 7.1 install.ps1

`Find-WowRoot` (L62-108, currently requires `_retail_\Interface\AddOns`, L102) is generalized: a candidate WoW root qualifies if **any** §2.1 folder has an `Interface\AddOns` path — reusing `Get-InstalledFlavours`'s own test (§2.3) so this logic lives in exactly one place. This directly unblocks a Classic-only machine.

App install target: per §3.1, `_retail_\AddonSync` when Retail is present (upgrade path, byte-identical to today); otherwise the first-detected flavour's folder (§2.1 order).

**"Adopt existing addon folders"** (L448-496) runs once per **installed** flavour, not just the app's home flavour — a first-time install on a Retail+Classic machine offers to take over both AddOns folders' existing contents in the same first-run flow, one dialog per flavour in sequence (independent yes/no decisions), extending the existing take-over dialog (UX-SPEC §2.4) rather than merging into one list.

(Round 34, 2026-09-07: section 7.2, "Shortcuts + Battle.net product codes" - the per-flavour "Launch WoW (Updated)" launcher-pair/shortcut scheme this doc originally specced here - was removed entirely at Eric's request; see CHANGELOG.md. install.ps1 creates exactly one Desktop shortcut regardless of flavour count, "Furphy Addon Manager.lnk" - see SPEC.md's own install.ps1 section.)

### 7.3 register-protocol.ps1

**Unchanged, verbatim.** Because this design keeps exactly one AddonSync install per machine (§3.1), the single-registration model already works — no routing file, no idempotent-second-call handling, nothing to build here at all.

### 7.4 deploy.ps1

Dev-only tool. Gains an optional `-Flavor` param defaulting to `retail` (today's hardcode becomes the default, not a behavior change) so a developer can push a build to the synthetic Classic Era fixture (§8) without editing the script. Lowest priority.

---

## 8. Synthetic test fixture

Exact tree a builder creates once under a `test-fixtures\SyntheticWow\` folder in the build root and reuses for every check below — **never touches `C:\Program Files (x86)\World of Warcraft`.**

```
<scratch>\SyntheticWow\
  .build.info
  _retail_\
    Wow.exe                                          (empty stub file)
    Interface\AddOns\
      SingleFlavourAddon\SingleFlavourAddon.toc       (## Interface: 120100 — no suffix, no X-Flavor; mirrors real AngryKeystones sample)
  _classic_\
    Wow.exe
    Interface\AddOns\
      FakeAddon\
        FakeAddon.toc                                 (bare — DECOY, must NOT be picked for Classic; Interface: 120100)
        FakeAddon_Mists.toc                            (## Interface: 50504 — SHOULD be picked, since this fixture's wow_classic row is in the Mists range)
  _classic_era_\
    Wow.exe
    Interface\AddOns\
      MultiFlavourAddon\
        MultiFlavourAddon.toc                          (## Interface: 110207, ## X-Flavor: Mainline)
        MultiFlavourAddon_Vanilla.toc                  (## Interface: 11508,  ## X-Flavor: Vanilla — SHOULD be picked for classic_era)
        MultiFlavourAddon_Mists.toc                    (## Interface: 50503,  ## X-Flavor: Mists)
      PreExistingEraAddon\PreExistingEraAddon.toc       (## Interface: 11504 — no suffix; simulates a real pre-existing folder for take-over/scan testing)
  _ptr_\
    Wow.exe
    Interface\AddOns\                                  (empty — proves "detected, not offered by default" path, §2.5)
```

`.build.info` (pipe-delimited, matches this machine's real confirmed header/row format exactly — verified live, 2026-09-04):

```
Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|Version!STRING:0|KeyRing!HEX:16|Product!STRING:0
us|1|00000000000000000000000000000000|00000000000000000000000000000000|00000000000000000000000000000000|0|tpr/wow|cdn.example.test|cdn.example.test|us|none||2026-09-04T00:00:00Z|12.1.0.69587||wow
us|1|00000000000000000000000000000000|00000000000000000000000000000000|00000000000000000000000000000000|0|tpr/wow_classic|cdn.example.test|cdn.example.test|us|none||2026-09-04T00:00:00Z|5.5.4.61180||wow_classic
us|1|00000000000000000000000000000000|00000000000000000000000000000000|00000000000000000000000000000000|0|tpr/wow_classic_era|cdn.example.test|cdn.example.test|us|none||2026-09-04T00:00:00Z|1.15.9.60546||wow_classic_era
us|1|00000000000000000000000000000000|00000000000000000000000000000000|00000000000000000000000000000000|0|tpr/wowt|cdn.example.test|cdn.example.test|us|none||2026-09-04T00:00:00Z|12.1.0.69588||wowt
```

**How to point the app at this fixture:** `addon-sync.ps1 -WowRoot <scratch>\SyntheticWow -Flavor <id> ...` (new `-WowRoot` override, §2.3); `addon-server.ps1` gets the equivalent override for local dev/test runs; `deploy.ps1 -Flavor <id>` (§7.4) can push a build into any one of the fixture's flavour folders for a live-server test.

### Acceptance checklist

- [ ] `Get-InstalledFlavours -WowRoot <scratch>\SyntheticWow` returns exactly `{retail, classic, classic_era, ptr}`, in §2.1 order, none flagged `buildInfoMissing`.
- [ ] Each entry's `clientBuild` matches its `.build.info` row's `Version` string exactly.
- [ ] `classic`'s resolved progression era (§2.4) = Mists, derived from Interface 50504, **not** hardcoded — provably re-derivable: edit the fixture's `wow_classic` row to a Cataclysm-range version (e.g. `4.4.2.xxxxx`) and confirm the resolution flips to Cataclysm/`77522`/`cata` without any code change.
- [ ] `addon-sync.ps1 -Flavor retail -Scan` finds `SingleFlavourAddon` only; `-Flavor classic_era -Scan` finds `MultiFlavourAddon` and `PreExistingEraAddon`; `-Flavor classic -Scan` finds `FakeAddon` (empty otherwise if that folder is cleared — proves no fatal error on an empty AddOns dir).
- [ ] `Get-PrimaryTocFile -Flavor classic_era` on `MultiFlavourAddon` picks `MultiFlavourAddon_Vanilla.toc` (X-Flavor: Vanilla), not the bare Mainline-tagged file.
- [ ] `Get-PrimaryTocFile -Flavor classic` on `FakeAddon` picks `FakeAddon_Mists.toc`, **not** the bare decoy — proves the Mainline/bare-always-wins bug is fixed and the fallback-claiming logic (§4.5 caveat) works.
- [ ] `Get-PrimaryTocFile -Flavor retail` behaviour against pre-existing real fixtures already on disk (`servertest\AddOns\Details`, `servertest\AddOns\WeakAuras`) is byte-identical to pre-change output — explicit regression check that the default path is untouched.
- [ ] Deleting `_classic_\` from the fixture and re-running `Get-InstalledFlavours` drops it from the result with no error — proves detection is live, not cached.
- [ ] `_ptr_` is detected but absent from the switcher/tray-sync list by default; setting `showTestRealms: true` surfaces it.
- [ ] Running `Invoke-FlavourMigration` against a **copy** of this build root's own real top-level `addons.json`/`state.json` (a ready-made real pre-flavour sample) produces `flavours\retail\addons.json` byte-identical to the original, plus an untouched `flavours\_migration-backup-<timestamp>\` holding the same content, and existing `backups\<id>\<id>.zip` files unmoved in mtime until the move step.
- [ ] Re-running the migration after simulating a crash mid-move (partially populate `flavours\retail\` by hand, then re-run) does not overwrite an already-landed file with stale backup content, and does not create a second backup folder.
- [ ] `install.ps1` against a fixture copy with `_retail_` deleted still succeeds, home-rooting at `_classic_` or `_classic_era_` per §2.1 order.
- [ ] A CurseForge test file whose `gameVersionTypeIds` (mocked) matches only `classic_era` auto-targets it with no prompt (§5.5 case 3); one matching both `retail` and `classic_era` produces an `awaiting_flavour` job (case 5); one matching neither fails with the plain no-support message (case 4).
- [ ] Two concurrent mocked jobs, one `?flavour=retail` one `?flavour=classic_era`, run without blocking each other (§5.4); a request to a flavour-scoped endpoint missing `?flavour=` on this multi-flavour fixture returns 400; the same request against a single-flavour-only state succeeds without the param.
- [ ] `?mock=1` UI test with a mocked multi-flavour `/api/state`: switcher shows exactly the mocked flavours in §2.1 order; switching pills swaps My Addons' list/freshness without a full reload; on a mocked single-flavour response, the switcher DOM is entirely absent (not just hidden) — inspect the DOM tree directly, not just visual state.

---

## 9. Ordered change sets (one agent each)

### CS-F1 — Core detection + Interface-range resolver + CLI flavour param + migration
**Files:** `addon-sync.ps1`.
- `Get-InstalledFlavours`, `-WowRoot`/`-Flavor` params threaded through `Resolve-AddonsPath`, `Get-ClientBuildInfo`, `Select-CfFile`, `Test-FileHasGameVersionPrefix`, `Select-WagoRelease`, `Get-PrimaryTocFile`, `Get-TocInterfaceValues` (§2-4). Implements §2.4's dynamic Interface-range → TypeId/Wago-value resolver as its own small, appendable, unit-testable function (`Resolve-ClassicProgressionTypeId`).
- `Invoke-FlavourMigration` (§3.3), called once at CLI startup before any path resolution.
- **Verify:** every §8 acceptance check that doesn't require the server (detection, dynamic resolution, `.toc` selection, migration, migration-retry-safety).

### CS-F2 — Server API + job scoping
**Files:** `addon-server.ps1`.
- Duplicate CS-F1's helper changes (existing established duplication pattern) — `Resolve-EffectiveAddonsPath`, `Get-DefaultBuildInfoPath`, `Get-PrimaryTocFile`, `Get-TocInterfaceValues`, `Get-ClientBuildInfo`, in the same change set so they never drift.
- `?flavour=`/`?flavor=` param plumbing on every flavour-scoped endpoint (with the shared `$Script:FlavourScopedEndpoints` list + startup self-check, §5.1); `/api/state`'s `installedFlavours`/`activeFlavour` fields; per-flavour `Test-JobBusy` scoping; `job.flavour` field; `{kind:"update-all-flavours"}` job kind.
- **Verify:** the two concurrent-jobs and 400-on-missing-param checks in §8.

### CS-F3 — Install-flavour resolution (protocol handler + Get New Addons)
**Files:** `addon-server.ps1` (job-creation path for CF/Wago installs).
- §5.5's three-way auto/refuse/ask logic; new `awaiting_flavour` job state.
- **Verify:** the three mocked-file acceptance checks in §8 (single match, multi match, no match).

### CS-F4 — UI switcher + per-flavour views
**Files:** `ui/app.js`, `ui/index.html`.
- Switcher component (§6.1), entirely absent below 2 flavours; Update All (§6.3); Wago `game_version` param (§6.4); Settings folder list + About list (§6.2, §6.5); job-panel flavour badge; "Retail Patches" → "Patches" rename; install-flavour picker modal (§5.5/§6.4).
- **Verify:** the `?mock=1` DOM-absence check and pill-switch check in §8.

### CS-F5 — Installer
**Files:** `install.ps1`.
- `Find-WowRoot` generalization (section 7.1), per-flavour app-home selection, per-flavour "adopt existing folders" loop. (Round 34, 2026-09-07: this change set originally also specced per-flavour shortcut/launcher-pair generation with honest non-retail launch wording (section 7.2) - removed at Eric's request along with every launch-WoW feature; see CHANGELOG.md. install.ps1 creates exactly one Desktop shortcut regardless of flavour count.)
- **Verify:** the `install.ps1`-against-no-`_retail_`-fixture check in §8; confirm the app-home/adopt logic is correct when all four fixture flavours are present (PTR excluded by default).

### CS-F6 — Tray sync-all
**Files:** wherever the tray updater lands once built (not present in this codebase snapshot — this change set is written against §5.6's contract, to be picked up when that feature starts).
- **Verify:** against the §8 fixture, one scheduled tick posts a single `update-all-flavours` job covering `retail`+`classic`+`classic_era` (not `ptr`, `showTestRealms` off); tooltip wording matches §5.6 for both all-up-to-date and mixed cases (mock the job results to force each case).

### CS-F7 — Fixture + doc updates
**Files:** new `test-fixtures\SyntheticWow\` tree in the build root; `SPEC.md`, `CHANGELOG.md`.
- Build exactly the section 8 tree; add a CHANGELOG.md round entry documenting the migration behavior and the rollback path (section 3.3 point 7) so neither is silently forgotten. (Round 34, 2026-09-07: this bullet originally also called for documenting the non-retail launch-reliability caveat from section 4.7 - moot, that section was removed along with `-Launcher` itself; see CHANGELOG.md.)
- **Verify:** every checkbox in §8 passes against the checked-in fixture; this becomes the standing regression check for every later change set touching flavour code.

---

## 10. Do-not-change list

Everything in UX-SPEC §9, plus, explicitly, for this feature:

- Single server process, single port, single `curseforge://` registration (§7.3 — `register-protocol.ps1`/`curseforge-handler.vbs` get zero changes).
- Single tray mutex, single tray settings block (`backgroundUpdates`/`backgroundIntervalMinutes`/`runAtStartup` stay global, never per-flavour).
- Single theme, single native host, single `FurphyHost.cs`.
- `addons.json`/`state.json` record schema — no new fields on individual records (§3.2); flavour scoping is by folder location only.
- (Round 34, 2026-09-07: this bullet originally asserted the existing Retail-only shortcut/launcher filenames and toast wording stayed byte-identical at `installedFlavours.length == 1` - moot now that no launcher files or launch toasts exist at any flavour count; see CHANGELOG.md. `install.ps1` still creates exactly one Desktop shortcut, `Furphy Addon Manager.lnk`, regardless of flavour count.)
- Existing `-Flavor`-omitted CLI invocations (scheduled tasks, manual scripts) — default to `retail`, unchanged output.
- The one-status-pill-per-row UX rule — never violated by this design, because every view is scoped to one flavour at a time; no cross-flavour joined row is introduced.
- No file outside `flavours\` is ever deleted during migration; the pre-move backup copy (§3.3) is never auto-deleted.

**Load-bearing promise:** for every machine with exactly one installed flavour, including this one, this feature ships with **zero visible or behavioral change anywhere in the app.**
