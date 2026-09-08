# SETTINGS-SPEC.md
Furphy Addon Manager - Settings UI/UX Audit - Authoritative Build Spec
Synthesized from the confirmed-findings audit round. ASCII only.

NOTE ON DASHES: this document is kept ASCII-only, so every place below that
shows " - " inside a piece of quoted UI copy or a label should be implemented
in the actual app as a real em dash character, per the punctuation rule in
Section 4, UNLESS the row's text explicitly says "hyphen" or shows a literal
"-" as part of a control name. Do not read the ASCII hyphens in this file as
an instruction to use hyphens in the shipped UI.

===============================================================================
1. GOALS AND ERIC'S VERBATIM ASKS
===============================================================================

Standing brief (earlier rounds): "clean experience, no extra textual fluff,
easy to understand terms, unified settings, simple, all in one."

This round, verbatim: "after these do a full settings ui/ux audit, make it as
simple and easy to understand as possible for everything, add tooltips with
more details."

Named complaint, verbatim, about one specific row: "this setting CurseForge
install links / Let CurseForge.com's Install buttons open here - On / also
that setting is worded weirdly."

Working interpretation used to resolve every conflict in this document:
- Add tooltips where a control's effect, scope, or a hidden coupling with
  another control is not obvious from its label alone.
- Do NOT duplicate content that is already permanently visible (the two
  locked "Update addons before WoW starts" lines, the ad-filter rationale
  paragraph) - tooltips are for filling real gaps, not restating existing
  prose.
- Do NOT remove or hide information the visible copy already carries.
- Reduce visual weight (box/heading count) without removing capability.
- Fix the one row Eric named by wording, not by moving it somewhere new.
- Where two confirmed findings proposed genuinely different, mutually
  exclusive fixes for the same row, this document picks one final answer
  (see "Conflicts resolved during synthesis" at the end of Section 2) so the
  build round has a single instruction per row, not two to reconcile itself.

===============================================================================
2. FINAL SETTINGS STRUCTURE
===============================================================================

Format per row: key | control | default | label | helper line | tooltip |
prior location.

No settings.json keys are renamed in this round. Where the exact key name
used by addon-server.ps1 was not given in the audit material, it is marked
"(verify in addon-server.ps1)" - do not guess a different name, look it up.

-------------------------------------------------------------------------
ESSENTIALS (always visible, unchanged tier structure, unchanged word budget)
-------------------------------------------------------------------------

Group 1: Updates

Row 1
  key: releaseType (shared with the "Also include experimental versions" row
       in Advanced; integer 1/2/3 - checkbox is checked when releaseType>=2)
  control: toggle
  default: off (releaseType=1)
  label: "Include beta versions" (unchanged)
  helper line: none
  tooltip: "Beta versions are early test builds an addon's author releases
       before the regular one - more features sooner, but more likely to
       have bugs. Turning this off also turns off 'Also include experimental
       versions' in Advanced. Off by default."
  prior location: Essentials > Updates (unchanged position)

(Row 2, "Update addons before WoW starts" - the autoUpdateOnLaunch toggle and
its two locked helper lines - removed at Eric's request, Round 34, 2026-09-07:
"we dont need a button to launch wow, and we dont need to have it run auto
updates before launching wow, since we now have a service running in the
background." See CHANGELOG.md. Every row below is renumbered up by one to
close the gap.)

Row 2
  key: backgroundUpdates
  control: toggle
  default: off
  label: "Update addons in the background" (unchanged)
  helper line: none (still no permanent explainer sentence - Round 18 rule
       stays in force for this row's own label)
  tooltip: "Checks for updates on a schedule and installs them automatically
       - using a separate process that keeps running even after you close
       Furphy. It pauses while WoW is running. Off by default."
  prior location: Essentials > Updates (unchanged position)

  Row 2a (child, shown only when Row 2 is on)
    key: updateIntervalMinutes (verify in addon-server.ps1)
    control: select
    default: matches current shipped default ("Once a day" per Eric's
         paste - do not change)
    label: "How often" (unchanged)
    helper line: none
    tooltip: "How often Furphy checks for updates in the background. If WoW
         is already running, it skips that check and tries again once you
         close the game."
    prior location: Essentials > Updates, nested under Row 2 (unchanged
         position)

Row 3
  key: runAtStartup
  control: toggle
  default: off
  label: "Start with Windows" (unchanged)
  helper line: none
  tooltip: "Starts Furphy's background updater when you log into Windows.
       Turning this on also turns on 'Update addons in the background'
       above, since it would otherwise have nothing to do. Off by default."
  prior location: Essentials > Updates (unchanged position)

Row 4 (status line, read-only)
  key: n/a (derived; reflects backgroundUpdates/runAtStartup/last cycle
       state via the same computeCoreText()/ComputeCore() contract used for
       the tray tooltip, tray menu, and balloon notification)
  control: static text
  default: n/a
  label: none (this line has no label, it IS the value)
  helper line: n/a
  tooltip: none
  prior location: below all three toggles (Round 18 position, unchanged;
       a confirmed finding explicitly rejected moving it - see Section 7,
       structure:background-status-reposition)
  WORDING FIX (confirmed, see Section 4): the "done_updated" branch must
       read "Updated N addon(s) at HH:MM: names" (pluralized), not
       "Updated 1 at HH:MM: names". This is a cross-surface string - see
       Section 5 for the required host-side mirror.

Group 2: Appearance

Row 5
  key: density
  control: segmented control (2 options)
  default: "Comfortable"
  label: "Spacing" (RENAMED from "Density" - also update the control's own
       aria-label from "Table density" to "Spacing", since "Table density"
       undersold the control's real app-wide scope)
  helper line: none
  tooltip: "Comfortable gives buttons, rows and lists more breathing room.
       Compact tightens everything up so more fits on screen at once.
       Purely visual - it doesn't change what anything does."
  prior location: Essentials > Appearance (unchanged position)

Row 6
  key: theme
  control: 16-swatch grid (radiogroup, checked tile = ring + checkmark)
  default: current shipped default (unchanged)
  label: "Theme" (unchanged)
  helper line: none - the swatch grid itself gets ZERO new visible text;
       only the "Theme" label gets a tooltip. Do NOT add a
       "does clicking a tile need a Save step" reassurance anywhere - a
       confirmed skeptic pass rejected that content, see Section 7,
       tooltips:theme-group-tooltip.
  tooltip (on the "Theme" label only): "Changes the colors of the Furphy
       desktop window only. It has no effect on World of Warcraft or your
       in-game addons."
  prior location: Essentials > Appearance (unchanged position)

-------------------------------------------------------------------------
ADVANCED (collapsed <details>/<summary>, unchanged collapse mechanism)
-------------------------------------------------------------------------

Summary row
  label: "Advanced" (unchanged, no visible text change)
  tooltip (on the <summary> itself): "Less commonly needed settings, such as
       CurseForge install links, extra version options, game folders, ad
       filtering, and troubleshooting tools."

Group 3: "CurseForge" (RENAMED from "Browsing"; this group now absorbs the
old standalone "CurseForge install links" box - see Conflicts section below
for why this consolidation is the final call). Contains all three rows that
govern how Furphy talks to CurseForge.com, in this order:

Row 7 (the row Eric named as "worded weirdly")
  key: none - this reflects live OS protocol-handler registration state,
       read via register-protocol.ps1, NOT a persisted settings.json field.
       Toggling it calls register/unregister directly.
  control: toggle
  default: off (until the user registers Furphy as the handler)
  label (FIXED across every state - no more "- On"/"- Off" suffix baked
       into the sentence; the switch alone now carries on/off, matching
       every other toggle on the page):
       "Open CurseForge install links in Furphy"
  loading-state label: "Checking whether CurseForge install links open in
       Furphy..."
  error-state label (unchanged): "Couldn't check CurseForge install-link
       handling."
  helper line: shown ONLY when off AND another program is currently
       registered as the handler:
       "Currently handled by another program on this PC."
       (no helper line in the two ordinary states - on, or off-and-
       unclaimed - label + switch position are enough there, same as every
       sibling toggle)
  tooltip: "On CurseForge.com, each addon page has a green Install button.
       Turning this on sends that button straight to Furphy to install the
       addon. Turn it off and you'll need to download the file yourself and
       add it to your AddOns folder."
       NEVER mention curseforge://, "protocol", or any other internal
       scheme/identifier in this tooltip or helper line.
  IMPLEMENTATION NOTE: give the underlying checkbox its own aria-label
       ("Open CurseForge install links in Furphy") so removing the text
       suffix does not remove the only accessible state indicator.
  prior location: its own standalone Advanced box, "CurseForge install
       links" (h3 removed - the heading was redundant with the row's own
       label and is subsumed into this group's "CurseForge" heading)

Row 8
  key: adFilter
  control: toggle
  default: ON
  label: "Filter ads and trackers in the CurseForge tab" (unchanged)
  helper line (LOCKED visible sentence, wording tightened - drop the
       circular "in Settings" since the reader is already looking at this
       exact toggle):
       "On by default. CurseForge is ad-funded and pays addon authors from
       that revenue - turn this off if you'd rather see it unfiltered."
  fallback line (shown only outside the native host, e.g. plain Edge
       window): "Available in the Furphy desktop window." (unchanged) with
       a NEW tooltip on that fallback line only:
       "There's no CurseForge tab here to filter - only the Furphy desktop
       window has one."
  tooltip on the main label: none (the visible sentence already covers it;
       do not duplicate)
  prior location: Advanced > Browsing (now Advanced > CurseForge)

Row 9
  key: cfFocus
  control: toggle
  default: On (matches addon-server.ps1 Get-DefaultSettings and SPEC.md
       Expansion E22)
  label: "Show only search results on CurseForge" (unchanged)
  helper line: none (unchanged - this row is deliberately explainer-
       sentence-free, per UX-SPEC.md 6.2)
  tooltip: "Trims CurseForge's search and listing pages down to just the
       results, hiding the promo banner, header, and filter sidebar. On an
       addon's own page, only ads, upsells, and unrelated extras are hidden
       - its title, description, and files stay."
       (Do NOT ship the earlier draft that claimed an addon's own page is
       "never trimmed" - that is factually wrong per SPEC.md's Expansion
       E22; the corrected wording above is the one to ship.)
  prior location: Advanced > Browsing (now Advanced > CurseForge)

Group 4: single ungrouped row, no heading (unchanged - kept separate from
the CurseForge group since it is a different topic, and NOT merged into a
3-way Stable/Beta/Alpha control - see Conflicts section)

Row 10
  key: releaseType (shared with Row 1; setting this row on forces
       releaseType=3 regardless of Row 1's current state)
  control: toggle
  default: off
  label: "Also include experimental versions" (RENAMED from "Also include
       alpha/experimental versions" - drops the unexplained "alpha/" jargon
       prefix; "experimental" alone was never flagged as jargon and keeps
       this row's label parallel to Row 1's "Include beta versions")
  helper line: none
  tooltip: "Experimental versions are an addon's newest, least-tested
       builds - often posted within hours of a change. Turning this on
       also turns on 'Include beta versions' above, since experimental is a
       further step past beta, not a separate option. Off by default."
  prior location: Advanced (unchanged position, still separate from the
       CurseForge group)

Group 5: "Game folders" (unchanged heading and position)

Row 11
  key: n/a (derived path, read-only display)
  control: path display + button
  label: "World of Warcraft folder" (unchanged)
  button text: "Open" (CHANGED from "Open folder" - matches the sibling
       row's button text and the documented/shipped multi-flavour
       convention; see copy:f10 in Section 7)
  tooltip: "Where World of Warcraft itself is installed. You'll rarely need
       this - it's here mainly for troubleshooting."
  CAUTION (do not fix this round, but do not ship a tooltip that overstates
       it either): a separately-flagged wiring bug means this button's
       server-side handler may not open the folder the label promises.
       The tooltip text above deliberately avoids asserting specific
       Explorer/Notepad behavior for exactly this reason. See Section 5.
       UPDATE (Round 33, merged from checkout commit 50c3698): the wiring
       is fixed - this button now opens the folder shown on its row (new
       'wowfolder' /api/open target). Tooltip text above left as written.
  prior location: Advanced > Game folders (unchanged position)

Row 12
  key: n/a (derived path, read-only display)
  control: path display + button
  label: "AddOns folder" (unchanged)
  button text: "Open" (unchanged)
  tooltip: "The exact folder your installed addons live in - the same one
       WoW reads from when you log in. Opening it lets you see the addon
       files directly."
  CAUTION: same wiring-bug caveat as Row 11 - see Section 5.
  prior location: Advanced > Game folders (unchanged position)

Group 6: "WoW versions" - CONDITIONAL, rendered only when a PTR/XPTR/Beta
client is detected on the machine (unchanged gating logic)

Row 13
  key: showTestRealms (verify exact name in addon-server.ps1)
  control: toggle
  default: off
  label: "Show test realms (PTR/Beta)" (UNCHANGED - do not remove the
       parenthetical; it is a documented, spec-locked label in two spec
       files, see Section 7)
  helper line: none (locked "no explainer sentence" rule stays)
  tooltip: "Adds your PTR or Beta realm as another WoW version Furphy
       tracks addons for, alongside your normal Retail or Classic install.
       Off by default since most players never touch a test realm."
  prior location: Advanced > WoW versions (unchanged position, unchanged
       visibility gating)

Group 7: "Folders Furphy doesn't manage yet" (unchanged heading, sentence,
and position)

Row 14
  key: n/a (Scan is an action, not a stored setting)
  control: intro sentence (unchanged: "Folders in your AddOns folder that
       Furphy doesn't manage yet.") + Scan button + dynamic per-result rows
  heading tooltip (on the "Folders Furphy doesn't manage yet" h3):
       "Addons installed by unzipping a download, or with another addon
       manager, before Furphy knew about them."
  Scan button tooltip: "Looks only - nothing changes until you take over or
       delete a result"
  Per-result "Take over" button tooltips:
       CurseForge-id variant: "Re-downloads this addon from CurseForge, so
            Furphy can keep it updated from now on."
       Wago-id variant: "Re-downloads this addon from Wago, so Furphy can
            keep it updated from now on."
       Manual-ID variant: "Re-downloads this addon from CurseForge, so
            Furphy can keep it updated from now on." (this path always
            submits a CurseForge project id)
       Do NOT ship "it doesn't touch the files themselves" - that claim is
       false; Take over re-downloads and overwrites the folder.
  prior location: Advanced (unchanged position)

Group 8: "Backup & troubleshooting" (MERGED from three former standalone
boxes - "Save / load your addon list", "Troubleshooting", "Diagnostics" -
into one Advanced group with two thin visual dividers, same border-top
divider style already used between rows elsewhere on this screen)

  -- cluster 1 --
Row 15
  key: n/a (export/import are actions)
  control: heading + unchanged visible sentence ("Save your addon list to a
       file, or load one you saved before.") + Save addon list / Load
       addon list buttons
  heading tooltip (single combined tooltip on the "Save / load your addon
       list" heading - do not also add separate per-button tooltips, to
       avoid three tooltip icons stacked in one small area):
       "Useful before reinstalling Windows, moving to a new PC, or just to
       back up what you're running now. Includes each addon's pinned
       version, ignored-updates choice, and release channel (Release,
       Beta, or Alpha) - not the addon files themselves."
  prior location: Advanced, its own box (now folded into this group)

  -- divider --

Row 16
  key: n/a (action button)
  control: button
  label: "Open logs folder" (unchanged)
  tooltip: "Opens the folder with Furphy's own log files and backups.
       You'll only need it if something's gone wrong and you're asking for
       help - otherwise, safe to ignore."
  prior location: Advanced > Troubleshooting (now folded into this group)

Row 17
  key: n/a (action button)
  control: danger button + unchanged confirm dialog ("Force reinstall all
       addons?" / "Every tracked addon is re-downloaded and reinstalled,
       even ones already up to date.")
  label: "Force reinstall all" (unchanged)
  tooltip: "For when an addon's files get corrupted or deleted by hand -
       otherwise Update all already keeps everything current."
       (Deliberately does not repeat the confirm dialog's own mechanism
       sentence - the tooltip's whole job is the missing "when", not the
       "what", which the dialog already states.)
  prior location: Advanced > Troubleshooting (now folded into this group)

  -- divider --

Row 18
  key: n/a
  control: plain row-label text (13px, same treatment as every toggle name
       elsewhere on this screen) reading "Diagnostics" - NOT a full <h3> and
       NOT its own bordered box. Keep the word "Diagnostics" on screen
       (needed as the anchor a support conversation refers to) but without
       the disproportionate box/heading weight it had before.
  intro sentence (REWRITTEN - was two near-duplicate sentences stacked back
       to back; now one):
       "Quick check that your files and CurseForge connection are working."
  Run button tooltip (carries the itemized detail that used to be in the
       now-removed second sentence, reworded to match the plain-language
       result-row labels the checks themselves already use):
       "Checks: AddOns folder, your addon settings, CurseForge, and disk
       space."
  pre-run placeholder (REPLACES "Click Run to check the AddOns folder,
       config files, CurseForge reachability, and disk space." - mirrors
       the sibling Untracked-folders section's own not-yet-run wording):
       "Nothing checked yet. Click Run to look."
  Per-check result-row tooltips (title on each row's name span):
       AddOns folder: "Furphy reads and writes files in your AddOns folder
            to install and update addons. A failure here usually means the
            folder couldn't be found, or Furphy doesn't have permission to
            write to it."
       CurseForge: "Furphy checks curseforge.com to find and download
            addon updates. A failure here is usually your internet
            connection or a firewall blocking access - it can also mean
            curseforge.com is temporarily unavailable."
       Disk space: "Furphy needs free space on the drive that holds your
            AddOns folder to download and install updates. A failure here
            means that drive is nearly full."
  Copy report button tooltip: "Copies more detail than what's shown below -
       exact paths, version numbers, and status codes - ready to paste into
       a bug report or a chat message."
  prior location: Advanced > Diagnostics (now folded into this group)

  -- divider --

Row 19 (new, Round 33 - DISTRIBUTION-SPEC.md sections 3.2/3.4; a new final
  cluster after Diagnostics, its own thin border-top divider, still inside
  this group's bordered box - the unboxed About footer line below stays
  outside any box, unchanged)
  key: n/a (action button, not a persisted setting)
  control: danger button, same visual weight as Row 17 "Force reinstall
       all", opens the existing Components.Confirm/Components.Dialogs.
       confirm modal verbatim (the same promise-based UI.confirm() the
       "Force reinstall all addons?" dialog already uses) - no new modal
       plumbing
  label: "Uninstall Furphy Addon Manager"
  tooltip (Components.Tooltip, same component/shape as every other row
       this round): "Removes Furphy's program files from this PC. Your
       addons and your saved addon list are kept - reinstalling picks up
       right where you left off."
  confirm dialog title: "Uninstall Furphy Addon Manager?"
  confirm dialog message: "This removes Furphy's program files, its
       Start with Windows setting, and the CurseForge install-link
       handler. Your addons stay installed in WoW. Your addon list is
       kept at <appDest> so reinstalling brings it back." (falls back to
       "kept on this PC" if the app's own install path can't be computed)
  confirmLabel: "Uninstall", danger: true
  on confirm: POST /api/uninstall. A 409/busy response renders the
       existing toast/error pattern with "Furphy is updating an addon
       right now. Try again in a minute." Success renders a plain final
       state, "Furphy is uninstalling itself and will close shortly." -
       no redirect; the window receives its own close request moments
       later as part of the same mechanism (see DISTRIBUTION-SPEC.md
       section 5.3), so nothing else needs to happen client-side.
  prior location: n/a (new)
  see also: DISTRIBUTION-SPEC.md sections 2.2/3.2/3.4/5 for the full
       end-to-end mechanism (tray menu, Windows Settings > Apps, and this
       row all converge on the same design) and UX-SPEC.md's Round 33
       entry for the summary version of this same row.

Footer line (About), directly below the Advanced disclosure, OUTSIDE any
bordered box, no <h3> heading - three items separated by " . ", each its
own small span so a tooltip icon can still attach per item:

  "Version 1.11.1" - no tooltip (already the clearest row in About; adding
       one would be filler, see the rejected finding in Section 7)

  "WoW client build 12.1.0.69587" - label RENAMED from "Client build" (adds
       "WoW" so it can't be misread as Furphy's own build, sitting as it
       does between Furphy's own Version and Server uptime)
       tooltip: "The version of World of Warcraft installed on this PC -
       used to check whether your addons still work with it. Separate from
       Furphy's own version, shown above."

  "Running for 8h 28m" - label RENAMED from "Server uptime" (removes
       backend-server jargon that raises an unnecessary "what server?"
       question in a desktop app)
       tooltip: "How long Furphy's background helper has been continuously
       running. It can keep running in the background even after you close
       this window - for example while background updates are on - and
       only stops after sitting idle for a while or when your PC
       restarts."
       Also update app.js's Diagnostics plainDiagRow label for the same
       underlying value from "Server uptime" to "Running for" so the two
       panels describe the same fact with the same words.

  prior location: its own bordered "About" box with h3 (demoted to this
       plain footer line - see Conflicts section below for how the rename/
       tooltip findings and the box-demotion finding were reconciled)

-------------------------------------------------------------------------
Explicit accounting of the rest of the screen (no wording/placement change)
-------------------------------------------------------------------------
Confirmed as fine exactly as shipped, no tooltip needed, no reword:
nav labels; (Round 34, 2026-09-07: the sidebar "Update & Play"/"Launch WoW"
buttons named here no longer exist, removed at Eric's request - see
CHANGELOG.md); the "How often" select's
own option words; the theme tile names; Save/Load button text ("Save
addon list" / "Load addon list"); the diagnostic pass/fail phrases inside
each result row ("Found and writable", "Reached OK", "Plenty free", etc. -
these are freshly generated on every Run and must not get a static
tooltip that could drift out of sync with a live result); the "How often"
row's option words; the background-updates status line's own live text
(covered by the wording fix in Row 4, not a fresh tooltip).

What moves behind "Advanced": nothing new - the Advanced/Essentials split
itself is unchanged; this round only consolidates boxes already inside
Advanced.

What moves elsewhere in the app: NOTHING. A confirmed finding explicitly
rejected relocating Scan (Folders Furphy doesn't manage yet) or Save/Load
to the My Addons screen - see Section 7, structure:relocation-scan-
saveload-rejected. Everything stays inside Settings, per Eric's "unified
settings ... all in one" brief.

What is removed: no functionality is removed. Only visual/structural
consolidation: 9 Advanced boxes collapse to 5 groups (6 when WoW versions
is shown) plus one unboxed footer line. The only text actually deleted
(not just relocated) is the redundant "CurseForge install links" h3
heading (subsumed into the new "CurseForge" group heading) and the
"About" h3/box (demoted to a plain footer line, value and meaning
unchanged).

Merged version-channel choice: NOT confirmed / explicitly rejected.
"Include beta versions" and "Also include experimental versions" remain
two separate toggles in two separate tiers (Beta always visible in
Essentials, Experimental tucked in Advanced), sharing one underlying
releaseType value under the hood. Do not build a 3-way Stable/Beta/Alpha
control - see structure:versions-merge-beta-alpha and structure:final-
order in Section 7.

-------------------------------------------------------------------------
CONFLICTS AMONG CONFIRMED FINDINGS, RESOLVED HERE
-------------------------------------------------------------------------
Several rows had more than one confirmed finding proposing different,
mutually exclusive text for the exact same control. Since a row can only
ship one final answer, this document picked one each time; the losing
proposal is not a defect to reintroduce later, it is a superseded
alternative. Do not re-open any of these:

1. CurseForge install-links row (Row 7): copy:f1 and structure:curseforge-
   install-links-wording both argued to KEEP the "- On/Off" suffix in the
   label (just improve its wording); first-time:curseforge-install-links-
   reword and tooltips:curseforge-install-links-wording both argued to
   DROP the suffix entirely and let the switch alone carry state, adding a
   conditional helper line instead. This document ships the DROP-the-
   suffix design (Row 7 above) because it is the only version that
   actually fixes the "state said twice" problem Eric named, and it makes
   this row finally consistent with every other toggle on the page. The
   keep-the-suffix camp's real concern - that the suffix was the ONLY
   accessible state text anywhere - is addressed instead by adding an
   explicit aria-label to the checkbox (see Row 7's implementation note),
   so nothing is actually lost.

2. Whether "CurseForge install links" gets its own box/heading or is
   folded into a combined "CurseForge" group with the ad-filter and
   cf-focus toggles: structure:final-order (the broader, later, most
   thoroughly-checked reorganization) folds it in; a separate, narrower
   finding (structure:curseforge-group-merge) that considered only this
   one merge in isolation was rejected on separation-of-concerns grounds
   (protocol handoff works even outside the native host; ad-filter/
   cf-focus are native-host-only). This document follows structure:final-
   order's broader call: the three rows still behave identically and keep
   their own labels/tooltips, only the surrounding box/heading is shared,
   so the separation-of-concerns objection does not actually bite in
   practice. See Section 7 for the rejected finding's full reasoning.

3. "Show test realms (PTR/Beta)" tooltip: first-time:show-test-realms
   explains what PTR/Beta ARE; tooltips:row-test-realms explains what
   toggling the Furphy setting DOES. Shipped: the latter (Row 13 above),
   since everyone who ever sees this row already has a PTR/Beta client
   installed and therefore already knows what PTR/Beta are - the real gap
   is what this specific Furphy toggle changes.

4. "WoW client build" tooltip: two confirmed drafts existed (first-time:
   about-client-build-rename's and tooltips:row-about's). Shipped: a
   combined version (see the footer entry above) - disambiguates from
   Furphy's own Version AND states why the number matters.

5. "Running for" (uptime) tooltip: tooltips:row-about's draft claims
   "it restarts each time you open Furphy" - this is FACTUALLY WRONG per
   first-time:about-uptime-rename's own code trace (the background
   process is detached and is reused across app opens/closes; only
   -IdleMinutes or a PC restart ends it). Do not ship tooltips:row-about's
   uptime text under any circumstance. Ship only the corrected text in
   the footer entry above.

6. "Update addons in the background" tooltip: four confirmed drafts
   existed (first-time:toggle-background-updates, copy:tooltip-style-
   guide's worked example, copy:f5-background-updates-tooltip, tooltips:
   row-background-updates). Row 2 above ships a composite combining each
   draft's one genuinely new, non-overlapping fact (separate process,
   survives window close, pauses during WoW) while dropping redundant
   restatements and the Start-with-Windows cross-reference (already
   covered from the other side, on Row 3's own tooltip).

7. "Include beta versions" / "Also include experimental versions"
   tooltips: three confirmed drafts existed per row (first-time:toggle-
   beta vs. copy:f7 vs. tooltips:row-beta for Beta; first-time:toggle-
   alpha vs. copy:f7 vs. tooltips:row-alpha for Experimental). Shipped
   text in Rows 1 and 10 above is a composite that keeps the corrected,
   non-backwards causality ("experimental is a further step past beta,
   not a separate option" - NOT "alpha comes after beta" and NOT "alpha
   is always newer than beta", both of which read as confusing/backwards
   per first-time:toggle-alpha's own correction) plus the jargon gloss
   and the coupling fact, each stated once.

8. "Start with Windows" tooltip: three confirmed drafts existed (first-
   time:toggle-run-at-startup, copy:f6-start-with-windows-hidden-
   coupling, structure:start-with-windows-tooltip); a fourth entry
   (tooltips:row-start-with-windows) is a degenerate placeholder ("test"/
   "test") and was ignored entirely. Row 3 above ships a composite of the
   three real drafts.

9. Save/load tooltip: three confirmed drafts existed at different levels
   (a heading-level "what's included" tooltip, a heading-level "why would
   I do this" tooltip, and two separate per-button mechanism tooltips).
   Row 15 above ships ONE combined heading-level tooltip covering why +
   what's included + the "not the addon files themselves" clarification,
   and deliberately skips separate per-button tooltips to avoid clutter
   (three tooltip icons for a two-button row would fight the "simple, no
   fluff" brief).

10. "Open logs folder" and "Force reinstall all" tooltips: each had two
    confirmed drafts (first-time:* and tooltips:row-troubleshooting).
    Row 16 ships first-time:logs-folder-tooltip's version (it correctly
    includes "and backups", which the shorter alternative omits). Row 17
    ships tooltips:row-troubleshooting's version (it correctly avoids
    repeating the confirm dialog's own mechanism sentence, which the
    other draft redundantly restates).

11. About box vs. footer line: the box-to-footer demotion comes from
    structure:final-order; the label renames and their tooltips come from
    three separate, more narrowly-scoped findings (first-time:about-
    client-build-rename, first-time:about-uptime-rename, tooltips:row-
    about, the last one only partially - see #5 above). All four are
    compatible once the footer keeps discrete per-item spans instead of
    collapsing to one unstructured string, which is what this document
    specifies.

===============================================================================
3. TOOLTIP COMPONENT SPEC
===============================================================================

No tooltip mechanism exists anywhere in Settings today (confirmed live:
zero title attributes, zero .tooltip/.hint/.help CSS, zero info-icon
button pattern - only bare native title="" on a handful of unrelated icon
buttons like Back/Forward/Close). Build ONE new component and use it for
every tooltip in this spec. Do not use a bare title="" attribute on a
label div anywhere in Settings - it has no visual affordance (nothing
tells a mouse user hovering does anything) and a plain non-focusable div
is unreachable by keyboard.

MARKUP - one small, focusable info-icon button placed right after the
label text it belongs to (row label, group heading, or the Advanced
<summary>):

  <div class="settings-row-label">
    Include beta versions
    <button type="button" class="info-tip" tabindex="0"
            aria-label="More about Include beta versions"
            aria-describedby="app-tooltip">
      <svg class="icon"><use href="#icon-info"></use></svg>
    </button>
  </div>

Reuse the existing #icon-info sprite symbol (already defined in
ui/index.html and already rendered once, in the first-run welcome dialog -
it is not currently unused, just not yet reused for this purpose).

SINGLETON: exactly one tooltip bubble node exists at a time, created on
open and removed on close, modeled on Components.Dropdown's own portalled-
menu lifecycle. It always carries the same constant id ("app-tooltip");
every trigger's aria-describedby points at that one constant id. This is
spec-valid: while nothing is open the id simply does not resolve to
anything, exactly like Dropdown's own remove-on-close pattern already
behaves.

CSS (tokens only, no new hardcoded colors):
  .info-tip {
    display: inline-flex; align-items: center; justify-content: center;
    width: 16px; height: 16px; margin-left: 6px; padding: 0;
    vertical-align: -3px; border: none; background: transparent;
    border-radius: var(--radius-sm); color: var(--text-faint);
    cursor: pointer; transition: color var(--fast);
  }
  .info-tip .icon { width: 14px; height: 14px; }
  .info-tip:hover, .info-tip:focus-visible { color: var(--text); }
  .info-tip:focus-visible { outline: 2px solid var(--focus-ring);
    outline-offset: 1px; }
  .tooltip-bubble {
    position: fixed; max-width: 320px; width: max-content;
    background: var(--bg-1); border: 1px solid var(--border);
    color: var(--text); border-radius: var(--radius);
    box-shadow: 0 8px 20px rgba(0,0,0,.35); padding: 8px 10px;
    font-size: 12.5px; line-height: 1.4; z-index: 95;
  }
(z-index 95 sits above .dropdown-menu's 90, since a tooltip can render on
top of an open dropdown.)

JS BEHAVIOUR:
- Hover or focus of .info-tip opens the bubble after a ~400ms show-delay
  (cancelled if the pointer leaves before it elapses), so incidental mouse
  travel across a row of controls does not flash tooltips constantly.
  Hides immediately on mouseleave/blur, no hide-delay needed.
- Also bind mouseenter on the sibling label text to the same open handler,
  so hovering the plain text opens the same bubble - but there is still
  only one focusable tab stop per row (the icon button itself).
- Click/tap on .info-tip toggles it open/closed; reuse the existing
  document-level "click outside closes it" pattern already used by
  Components.Dropdown.
- Escape hides the open tooltip without moving focus elsewhere. Wire this
  into the EXISTING global Escape-key dispatcher as the FIRST, highest-
  priority branch (ahead of Dropdown/Lightbox/Dialog/Drawer), since a
  tooltip can render on top of any of those:
      if (Components.Tooltip.isOpen()) { Components.Tooltip.close();
        return; }
- One tooltip open at a time: opening a new one closes any other that is
  already open (this falls out naturally from the singleton-bubble
  design above).

PLACEMENT/CLAMPING: portal the bubble to document.body, position:fixed.
Reuse Components.Dropdown's own reposition()/clamp/flip algorithm
verbatim: clamp left within the viewport with an 8px margin, default to
opening below the trigger (6px gap), flip above when there is not enough
room below. Re-run positioning on scroll (capture) and resize exactly
like Dropdown already does.

OVERLAY TRACKING: Tooltip.open()/close() MUST call the existing
OverlayTracker.open()/close(), exactly like Components.Dropdown already
does, and for the same documented reason - a WebView2 child window always
paints above ordinary HTML regardless of z-index. This matters because
this same tooltip component is reused on "Get new addons" (see below),
where the embedded CurseForge pane is visible; skipping OverlayTracker
there would render a tooltip invisibly behind that pane. This costs
nothing in plain Settings, where OverlayTracker's listeners are already
correctly no-op'd everywhere the CurseForge pane isn't showing.

ARIA: trigger gets aria-describedby="app-tooltip" (constant) plus its own
per-row aria-label="More about {row label}"; the bubble itself gets
role="tooltip".

REDUCED MOTION: default a 120ms opacity + 4px slide-in (matching this
app's existing 120ms "fast" transition token), collapsed to an instant
show under `@media (prefers-reduced-motion: reduce)`.

DO NOT REUSE: the app's existing native title="" attributes on icon-only
buttons (Back/Forward/Close/Dismiss) are a different, lesser mechanism
(unstyled, no touch support, no role="tooltip") and should be left as-is
for those buttons - do not convert them to the new component this round,
and do not use bare title="" for any NEW settings tooltip either.

DO NOT build a hook toward reusing Components.Chip's unused third `title`
param for My Addons' status pills. That parameter's one use case (the old
Compat hover tooltip) was already deliberately, permanently deleted per
UX-SPEC.md's own acceptance checklist ("not just hidden - removed"). A
proposal to resurrect it via this new mechanism was checked and rejected
this round - see Section 7, tooltips:status-pill-reuse.

-------------------------------------------------------------------------
Non-Settings places that get a tooltip in this same round
-------------------------------------------------------------------------
My Addons status pills: NONE this round. A proposal to reuse the new
mechanism there was rejected (wrong call site, and it would have
resurrected the deleted Compat tooltip). Do not add tooltips to status
pills.

Get new addons (CurseForge browsing pane): ONE tooltip, on the existing
unexplained fallback line that shows outside the native host ("CurseForge
browsing happens inside the Furphy desktop window."):
  "There's no CurseForge tab here to browse - only the Furphy desktop
  window has one."
This mirrors the identical fallback-line tooltip already specified for
the Settings > CurseForge > ad-filter row's own fallback (Row 8 above),
for consistency between the two analogous "not available outside the
native host" messages.

===============================================================================
4. WORDING RULES
===============================================================================

VOICE: plain, direct, second person where natural ("you", "your"). Furphy
refers to itself in first person by name ("Furphy checks...", "Furphy
reads and writes..."), matching existing copy like "Folders Furphy doesn't
manage yet."

CAPITALIZATION: sentence case everywhere. Only proper nouns are
capitalized: CurseForge, WoW, Furphy, Windows, Battle.net, World of
Warcraft, Wago. Never capitalize a common noun mid-sentence for emphasis.

TOOLTIP SHAPE (every new tooltip in this spec follows this fixed shape,
no exceptions):
  1. What it does - one plain clause, no jargon.
  2. When/why it matters, or a coupling with another control - only if not
     already obvious from (1).
  3. For a toggle/checkbox row only, its default, always the LAST clause,
     always literally "On by default." or "Off by default." Non-toggle
     controls (selects, path rows, Spacing/Theme pickers, action buttons)
     end after clause (2) instead - they have no boolean default to state,
     never force that sentence onto them.
Target length ~30 words; a genuinely coupled control (Beta/Experimental,
Start with Windows/Background updates) may run to ~40-45 words rather than
omit the coupling fact - do not compress a coupling explanation into
incomprehensibility just to hit the word count.
Hard caps: no bullet lists, no bold text, no "Note:"/"Warning:" prefixes,
never a wall of text.

MECHANISM: native `title=` is reserved for the pre-existing icon-button
labels it is already used for; every new explanatory tooltip in Settings
(and the two non-Settings tooltips above) uses the new Components.Tooltip
component from Section 3, not a bare attribute.

PUNCTUATION: use an em dash (real "-" character, not a hyphen with
spaces) as the connector inside a two-clause sentence, matching this
screen's own established house style (e.g. the ad-filter row's own
locked sentence, the background-updates status line). This document is
ASCII-only, so every " - " you see above inside quoted copy must become a
real em dash in the shipped strings, per the note at the top of this
file.

BANNED TERMS (never appear in any label, helper line, or tooltip, per
UX-SPEC.md section 11's acceptance-checklist list): project id, file id,
release type, toc, interface version, compat, digest, stale, adopt,
untracked, keyless, indexed, instawow-data, addon-radar.com, any literal
HTTP status code (e.g. "HTTP 200"), Port. Additionally, and specific to
this round: never write the literal string "curseforge://" or any other
raw protocol/scheme identifier in any tooltip or helper line - this was a
real leak caught and reverted once already on the install-links row (see
Section 7).

DO-NOT-TOUCH VISIBLE TEXT (must stay exactly as shipped, no tooltip added
on top, no rewording): (Round 34, 2026-09-07: the two locked "Update addons
before WoW starts" helper lines that used to be listed here were removed
along with the row itself - see CHANGELOG.md); the ad-filter rationale
sentence (Row 8, wording-
tightened only to drop "in Settings", otherwise unchanged); the "Show
test realms (PTR/Beta)" label including its parenthetical; the "Show only
search results on CurseForge" row's zero-helper-sentence rule (it gets a
tooltip, never a permanent sentence); the Force-reinstall-all confirm
dialog text; every diagnostic result-row's live pass/fail phrase.

STATUS-LINE RULES: the tray's own status sentence (computeCoreText() in
ui/app.js, mirrored byte-for-byte by ComputeCore() in host/FurphyHost.cs)
is reused verbatim across the tray tooltip, the tray context-menu line,
the balloon notification, AND the Settings status line (Row 4). Do not
edit this text as a Settings-only fix - any wording change to this string
must be applied to both ui/app.js and host/FurphyHost.cs identically, or
the four surfaces will drift out of sync. The one confirmed change in
this round is the "done_updated" pluralization fix in Row 4 - see Section
5 for the required mirrored host-side edit. Do not touch any other branch
of computeCoreText()/backgroundStatusText() this round - a broader
em-dash-normalization pass across those functions was proposed and
rejected (see Section 7, copy:f9) because it would require touching
shared native-host code out of scope for a Settings-copy audit.

===============================================================================
5. SERVER/HOST CHANGES NEEDED
===============================================================================

1. host/FurphyHost.cs - MinimumSize change (HIGH, confirmed):
   Change `MinimumSize = new Size(900, 600);` to a value with real
   headroom over the CSS app's own documented 1000px floor once native
   window chrome and DPI scaling are subtracted, e.g.
   `MinimumSize = new Size(1040, 660);` as a starting point - verify
   empirically against this host's actual FormBorderStyle and DPI-scaling
   behavior before finalizing the exact numbers, since the true client-
   area/CSS-px relationship depends on both. This is a real, reproducible
   bug today: dragging the native window down to its currently-permitted
   minimum (900x600) pushes every Settings toggle switch off the visible
   right edge with no scroll escape (html/body carry overflow-x:hidden).
   Verify the fix with the same DOM-measurement check that caught the bug
   (element.getBoundingClientRect() against window.innerWidth), not a
   visual glance.

2. host/FurphyHost.cs's ComputeCore() - mirror the "done_updated"
   pluralization fix from ui/app.js's computeCoreText() (Row 4 above):
   the string must read "Updated N addon(s) at HH:MM: names", matching
   the existing pluralization idiom already used one branch below it
   ("N addon(s) failed...") and in Actions.updateAll. This is required in
   BOTH files to keep the tray tooltip/menu/balloon text identical to what
   Settings shows - shipping the fix only in ui/app.js will make the SPA
   and the tray disagree.

3. No settings.json key renames. Every visible-label rename in this spec
   (Density -> Spacing, Client build -> WoW client build, Server uptime ->
   Running for, "Also include alpha/experimental versions" -> "Also
   include experimental versions") is copy-only; the underlying keys,
   DOM ids, and internal variable names are unchanged. Migration needed:
   NONE.

4. Known, separately-flagged wiring bug (NOT required to fix this round,
   flag only): the "World of Warcraft folder" row's Open button actually
   opens the AddOns folder (not the WoW install folder), and the "AddOns
   folder" row's Open button actually opens addons.json in Notepad (not
   the folder in Explorer). Row 11/12's tooltip text above was
   deliberately written to avoid asserting specific Explorer/Notepad
   behavior for this exact reason. This bug should be fixed as its own,
   separate task before or alongside this round - do not let a tooltip
   ship that describes the intended-but-not-actual button behavior.
   FIXED (Round 33, merged into this build root from the checkout's
   commit 50c3698 on 2026-09-06): new 'wowfolder' /api/open target opens
   Get-WowRootPath (the path Row 11 displays); Row 12's button now calls
   'folder' (the AddOns folder in Explorer); multi-flavour per-row Open
   buttons send ?flavour=<id> so each opens its own folder; the old
   'addons' target (addons.json in Notepad) is demoted to Backup &
   troubleshooting as "Open addon list file" with its own tooltip.
   Covered by five Handle-Open unit tests (tests\unit\Server.Handlers.
   Tests.ps1) and verified live; CHANGELOG Round 33 has the details.

===============================================================================
6. ACCEPTANCE CHECKLIST
===============================================================================

LAYOUT
[ ] At 1040x660 (or whatever final MinimumSize is chosen per Section 5),
    every Settings control - every toggle switch, every button, the
    Spacing/Theme controls - has its full bounding rect on-screen; no
    element's right edge exceeds window.innerWidth. Verify with
    getBoundingClientRect(), not a screenshot glance.
[ ] At the previously-broken 900x600, confirm the native host now refuses
    to shrink below its new MinimumSize (the bug is structurally
    prevented, not papered over).
[ ] Re-measure total Essentials+Advanced-collapsed scroll height at
    845x539 CSS after the box consolidation (baseline before this round:
    ~1033px total content height at that width, Advanced's <summary> row
    reachable at ~398px of scroll, roughly 0.74 of one screen height).
    Record the new number; it should not have grown, and should likely
    have shrunk given fewer Advanced box borders/headings once the
    reorganization in Section 2 ships.

ROW COUNT
[ ] Advanced now contains 5 groups on a single-flavour, no-PTR machine
    (CurseForge, Also include experimental versions, Game folders,
    Folders Furphy doesn't manage yet, Backup & troubleshooting) plus one
    unboxed footer line - down from today's 9 separate bordered boxes
    (CurseForge install links, alpha toggle, Game folders, Browsing,
    Folders doesn't manage yet, Save/load, Troubleshooting, Diagnostics,
    About). On a PTR/Beta machine, add the conditional "WoW versions"
    group for 6.

COPY / HARNESS ASSERTIONS (add to tests/spa/harness.js)
[ ] No visible row anywhere in Settings shows a trailing "- On" or
    "- Off" (or "-On"/"-Off") suffix baked into its own label sentence -
    scan #view-settings for the literal pattern and fail if found.
[ ] Every settings row identified in Section 2 as having a tooltip
    actually renders an .info-tip button with a non-empty aria-label,
    and every row explicitly marked "tooltip: none" in Section 2 does
    NOT have one (positive AND negative assertions - both directions
    matter).
[ ] Banned-term scan (Section 4's list, plus "curseforge://") returns
    zero hits across every label, helper line, and tooltip string in
    #view-settings, checked by reading the actual DOM text plus every
    .info-tip's computed tooltip content, not just the static HTML source
    (tooltip text may be JS-generated).
[ ] The Diagnostics section shows exactly ONE sentence before Run is
    clicked (not two near-duplicate sentences stacked back to back).
[ ] The "About" footer line renders with no enclosing .settings-group
    border and no <h3> - just plain text/spans below the Advanced
    disclosure.
[ ] The CurseForge install-links row's switch and its own label text
    never both encode the same on/off state at once (i.e. the label
    string is byte-identical regardless of the toggle's checked state,
    except for the one conditional "another program" helper line).
[ ] computeCoreText()'s "done_updated" branch and host/FurphyHost.cs's
    ComputeCore() produce byte-identical pluralized output for both N=1
    and N>1.
[ ] Escape closes an open tooltip without also closing/affecting any
    other open overlay (dropdown/dialog/drawer/lightbox) that happens to
    be open underneath it.

SCREENSHOTS TO CAPTURE
[ ] Essentials, light and dark, at the new MinimumSize-derived viewport.
[ ] Essentials at 845x539 CSS, before/after comparison (or as close to
    "before" as can be reconstructed from the current build).
[ ] Advanced expanded, showing the consolidated CurseForge and Backup &
    troubleshooting groups with their dividers.
[ ] The CurseForge install-links row in all three states (on / off-
    unclaimed / off-another-program), showing the label is unchanged
    across the first two and the helper line appears only in the third.
[ ] A tooltip bubble open via hover on at least one Essentials row and
    one Advanced row, plus one open via keyboard focus (to confirm the
    focus-visible outline and aria wiring).
[ ] The Advanced <summary> row's own hover tooltip.
[ ] The new unboxed About footer line.

===============================================================================
7. APPENDIX - REJECTED FINDINGS AND WHY
===============================================================================
Do not re-open any of these in the build round. Each was checked against
the real code/spec and found to not clear the bar (contradicts a
documented decision, factually wrong, targets the wrong element, or the
underlying problem isn't real for a normal user).

first-time:ad-filter-simplify - the current ad-filter helper sentence is
  not incidental copy, it is Eric's own Round 16 rewrite tied to the
  ad-filter-default-ON decision; the proposed replacement grows the
  sentence from 25 to 35 words and restates the label before reaching any
  new information. No change beyond the narrow "in Settings" trim already
  applied in Row 8 above.

first-time:about-version-tooltip - "Version" is already the clearest row
  in About with no real ambiguity; the proposed tooltip is filler that
  contradicts the "nothing over a sentence that states the obvious"
  principle and the "no extra textual fluff" brief. No tooltip on Version.

copy:f3-untracked-heading-restates-paragraph - the heading + sentence
  pair under "Folders Furphy doesn't manage yet" is a documented, already-
  simplified product decision (UX-SPEC.md section 6.2 and its copy table),
  matches the same pattern used by every other Advanced sub-group, and
  Eric's own verbatim paste of this exact text carried no complaint about
  it. No change.

copy:f9-status-line-log-style-and-dash-mismatch - bundled two different
  fixes. The em-dash-vs-hyphen observation is real but narrowly scoped to
  backgroundStatusText's rarely-hit legacy fallback switch, not
  computeCoreText/ComputeCore (which is a documented, cross-surface,
  byte-for-byte contract per SPEC.md and would require an out-of-scope
  native-host edit to keep in sync). The proposed "done_updated reads
  like a log, hide the details in a tooltip" rewrite directly contradicts
  SPEC.md's locked per-status string table and would desync the SPA from
  the tray balloon notification, which shows the identical string with no
  hover affordance at all. Only the narrower, separately-confirmed
  pluralization fix (Section 5, item 2) ships this round.

copy:f4-backup-paragraph-restates-heading - the "Save your addon list to
  a file, or load one you saved before." sentence is a documented,
  already-trimmed final wording (UX-SPEC.md section 6.2 and its copy
  table); the lexical overlap with the heading is not fluff, it adds the
  two facts (portable file, reloadable later) the heading alone doesn't
  convey. No change to the visible sentence; see Row 15 for the added
  tooltip instead.

copy:f16-test-realms-tooltip-preseed - "Show test realms (PTR/Beta)" is
  spec-locked in two documents as deliberately explainer-free, and this
  exact move (bolt a title tooltip onto a "no explainer sentence" row) was
  already tried and reverted once on the sibling CurseForge install-links
  row for the same reasons. Superseded anyway: Row 13 above does add a
  tooltip to this row via the new component (not a bare title=), per
  Eric's explicit ask this round overriding the older "no tooltip at all"
  reading - see structure:final-order's reasoning and the confirmed
  tooltips:row-test-realms finding.

structure:essentials-exceeds-viewport - cites a UX-SPEC.md quote that does
  not exist in the document, and its own scroll-height measurement is
  overstated by roughly 2-3x versus the actual rendered DOM (real
  scroll-to-Advanced distance is ~0.74 of one screen height, not "1.5-2
  screen-heights"). Its proposed fix also relies on a CSS class
  (indented "settings-row-col" nesting) that does not behave the way the
  finding claims. No structural change from this finding; see Section 6
  for the real, re-measured baseline instead.

structure:curseforge-group-merge - a narrower, standalone version of the
  CurseForge-group merge, rejected on separation-of-concerns grounds
  (protocol handoff works even outside the native host; ad-filter/
  cf-focus toggles are native-host-only) and because it also proposed
  changing the install-links row's label, which is out of its own scope.
  NOTE: the broader structure:final-order finding revisited this same
  merge as part of a full reorganization and IS shipping it (Section 2,
  Group 3) - see "Conflicts resolved during synthesis," item 2, for why
  the two findings reach different conclusions and which one this spec
  follows.

structure:versions-merge-beta-alpha - proposed collapsing Beta and
  Experimental into one 3-way control. Rejected (reason field was a
  placeholder in the source material, but the proposal itself directly
  contradicts UX-SPEC.md's explicit, deliberate choice, independently
  confirmed by structure:final-order, to keep "Everything (incl. Alpha)"
  a rare Advanced-only toggle rather than a daily Essentials choice). Do
  not merge these two controls.

structure:background-status-reposition - proposed moving the status line
  to sit only under the background-updates+interval rows, excluding
  Start with Windows. Contradicts UX-SPEC.md's explicit "one muted status
  line below all three" rule, and the coupling between Start with Windows
  and background updates means the status line legitimately needs to
  summarize all three rows together. No change - status line stays below
  all three (Row 4).

structure:wow-starts-tooltip-convert - proposed converting the two locked
  "Update addons before WoW starts" lines into a hover tooltip to save
  space. Contradicted a deliberate, Eric-requested exception to the
  zero-prose rule (UX-SPEC.md 6.1, Round 17) at the time this conflict was
  resolved. Moot as of Round 34, 2026-09-07: the row itself, both locked
  lines included, was removed entirely at Eric's request - see CHANGELOG.md.

structure:about-footer-condense - argued About's box/heading was
  disproportionate versus its content. Checked and found NOT
  disproportionate (identical .settings-group treatment to every sibling
  Advanced box); also collides with a planned future per-flavour client-
  build list documented in UX-SPEC.md that needs the current dt/dl
  structure. Superseded anyway: structure:final-order's footer-line
  demotion (which this spec ships) achieves the same visual-weight
  reduction while preserving discrete per-item spans for tooltips and
  future per-flavour rows - see Section 2's footer entry.

tooltips:row-game-folders - traced the actual server-side wiring
  (addon-server.ps1's Handle-Open) and found the "World of Warcraft
  folder" button actually opens the AddOns folder, and the "AddOns
  folder" button actually opens addons.json in Notepad - neither matches
  what a tooltip describing "shows it in File Explorer" would promise.
  The specific tooltip text in that finding is rejected; the underlying
  bug is flagged separately in Section 5, item 4. Row 11/12 above ship
  tooltip text that avoids the false claim.

tooltips:status-pill-reuse - proposed wiring new tooltips into My Addons'
  status pills via Components.Chip.build's unused title param. Rejected:
  wrong call site (that qualified form has exactly one caller, the detail
  drawer's Compat row, not the table's status pill), and for the compat-
  derived tiers specifically it would resurrect the old Compat hover
  tooltip that UX-SPEC.md's acceptance checklist requires be permanently
  absent, not just hidden. No new tooltips on status pills this round.

tooltips:escape-dispatcher-integration - written as if a Components.
  Tooltip module already existed and needed an integration fix. It does
  not exist yet; this is forward guidance for a component being built
  fresh this round, and Section 3 above already specifies the correct
  Escape-dispatcher integration directly. No separate action needed.

tooltips:theme-group-tooltip - proposed a "does this need a save step"
  reassurance on the Theme grid. Rejected: live-testing shows every
  swatch click repaints the whole app instantly, which is a stronger,
  earlier signal than any hover tooltip could give, and UX-SPEC.md
  section 6.2 explicitly forecloses ANY added instructional content on
  this control ("the only affordance"). This is a different concern from
  the CONFIRMED Theme tooltip in Row 6 above (first-time:theme-grid-
  tooltip), which addresses a different question (does this affect the
  live game, not "do I need to save") and does not add picker
  instructions - only a scope disclaimer.
