/* ==========================================================================
   tests\spa\theme-audit.js

   THEMES-SPEC.md section 5 Set A #2 / section 6's "live-computed contrast"
   acceptance item, automated: for each of the 14 themes (order copied
   verbatim from ui\app.js's own THEMES array - the sole source of slug
   ordering per that spec), loads a same-origin COPY of ui\index.html in an
   iframe with ?mock=1&test=1&theme=<slug>, reads the live COMPUTED style
   values (never the spec's hand-math, matching the spec's own instruction)
   for every base token pair in the Status-Chip Surface Inventory plus all
   5 status chips (each composited over both --bg-1 and --bg-2, since a
   chip's own background is a semi-transparent tint - see ui\style.css's
   *-tint custom properties), and asserts every pairing is >= 4.5:1 (WCAG
   AA for normal text) via the same relative-luminance formula used by
   this repo's own earlier ad-hoc shots\contrast2.js script.

   Writes one aggregated JSON object into <pre id="results"> the same way
   tests\spa\harness.js does, for Run-ThemeAudit.ps1 to read back out of a
   --dump-dom capture. Never throws out of a single theme's pass - one bad
   theme is recorded as a failure and the loop continues, so the <pre>
   always holds a best-effort result for every theme that got a chance to
   run before any harness-level timeout.
   ========================================================================== */
(function () {
  "use strict";

  // Verbatim copy of ui\app.js's THEMES array order (THEMES-SPEC.md section
  // 3.4/6: "THEMES array in app.js is the sole source of slug+label
  // ordering" - this harness does not re-derive it live from the iframe
  // since __furphyTest exposes App/Store, not the THEMES array itself;
  // keeping this list in sync with app.js is a plain textual copy, same
  // as install.ps1's own documented duplication of FlavourDefs elsewhere
  // in this codebase).
  const THEME_SLUGS = [
    "vaporwave", "lofi", "dark", "light", "terminal-green", "arctic-ice",
    "art-deco-gold", "alpine-dawn", "matcha", "desert-night", "tokyo-rain",
    "brushed-steel", "aurora-sky", "strawberry-cream"
  ];

  const BASE_TOKENS = ["--bg-0", "--bg-1", "--bg-2", "--bg-3", "--border", "--text", "--text-muted", "--text-faint", "--accent", "--accent-text"];
  const HEX6 = /^#[0-9a-fA-F]{6}$/;
  const CHIP_CLASSES = ["chip-success", "chip-warning", "chip-info", "chip-muted", "chip-danger"];

  const results = { themes: [], startedAt: new Date().toISOString(), complete: false };

  function statusEl() { return document.getElementById("status"); }
  function resultsEl() { return document.getElementById("results"); }
  function writeResults() { try { resultsEl().textContent = JSON.stringify(results); } catch (e) { } }

  function wait(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }

  function iframeEl() { return document.getElementById("spa-frame"); }

  function loadFrame(query) {
    return new Promise(function (resolve, reject) {
      const frame = iframeEl();
      let settled = false;
      function onLoad() {
        frame.removeEventListener("load", onLoad);
        settled = true;
        resolve(frame.contentWindow);
      }
      frame.addEventListener("load", onLoad);
      frame.src = "/index.html" + query;
      setTimeout(function () { if (!settled) reject(new Error("iframe did not fire load within 10s: " + query)); }, 10000);
    });
  }

  function waitForReady(win, timeoutMs) {
    return new Promise(function (resolve, reject) {
      const start = Date.now();
      (function poll() {
        try {
          if (win.__furphyTest && win.__furphyTest.ready) { resolve(); return; }
        } catch (e) { }
        if (Date.now() - start > timeoutMs) { reject(new Error("__furphyTest.ready never became true within " + timeoutMs + "ms")); return; }
        setTimeout(poll, 100);
      })();
    });
  }

  // ---- WCAG contrast math (same formula as shots\contrast2.js) ----------
  function parseColor(s) {
    if (!s) return [0, 0, 0, 0];
    const m = s.match(/rgba?\(([^)]+)\)/);
    if (!m) return [0, 0, 0, 1];
    const parts = m[1].split(",").map(function (x) { return parseFloat(x); });
    return [parts[0], parts[1], parts[2], parts.length > 3 ? parts[3] : 1];
  }
  function hexToRgb(hex) {
    const m = /^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/.exec(hex || "");
    if (!m) return null;
    return [parseInt(m[1], 16), parseInt(m[2], 16), parseInt(m[3], 16)];
  }
  function luminance(rgb) {
    const a = rgb.map(function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2];
  }
  function contrastRatio(rgb1, rgb2) {
    const l1 = luminance(rgb1), l2 = luminance(rgb2);
    const lighter = Math.max(l1, l2), darker = Math.min(l1, l2);
    return (lighter + 0.05) / (darker + 0.05);
  }
  function compositeOver(fgRgba, bgRgb) {
    const a = fgRgba[3];
    return [
      fgRgba[0] * a + bgRgb[0] * (1 - a),
      fgRgba[1] * a + bgRgb[1] * (1 - a),
      fgRgba[2] * a + bgRgb[2] * (1 - a)
    ];
  }

  function readTokens(win) {
    const cs = win.getComputedStyle(win.document.documentElement);
    const out = {};
    BASE_TOKENS.forEach(function (t) { out[t] = cs.getPropertyValue(t).trim(); });
    return out;
  }

  function auditTheme(win, slug) {
    const theme = { slug: slug, tokenShapeChecks: [], contrastChecks: [], error: null };
    try {
      const dataTheme = win.document.documentElement.getAttribute("data-theme");
      theme.tokenShapeChecks.push({ name: "data-theme attribute == " + slug, passed: dataTheme === slug, detail: "was " + dataTheme });

      const tokens = readTokens(win);
      const rgb = {};
      BASE_TOKENS.forEach(function (t) {
        const val = tokens[t];
        const isBorder = (t === "--border");
        // --border is allowed to be an hsla()/rgba() value on some themes
        // (a translucent divider) - only the 9 solid-color tokens listed in
        // THEMES-SPEC section 6's own checklist bullet must be literal hex
        // (that's the bullet Host.reportTheme()'s regex depends on).
        if (!isBorder) {
          theme.tokenShapeChecks.push({ name: t + " is a literal 6-digit hex value", passed: HEX6.test(val), detail: val });
        }
        const asHex = hexToRgb(val);
        if (asHex) { rgb[t] = asHex; }
      });

      function pushRatio(name, fg, bg) {
        if (!fg || !bg) { theme.contrastChecks.push({ name: name, passed: false, ratio: null, detail: "missing token value" }); return; }
        const ratio = contrastRatio(fg, bg);
        theme.contrastChecks.push({ name: name, passed: ratio >= 4.5, ratio: Math.round(ratio * 100) / 100, detail: null });
      }

      pushRatio("text vs bg-0", rgb["--text"], rgb["--bg-0"]);
      pushRatio("text vs bg-1", rgb["--text"], rgb["--bg-1"]);
      pushRatio("text vs bg-2", rgb["--text"], rgb["--bg-2"]);
      pushRatio("text vs bg-3", rgb["--text"], rgb["--bg-3"]);
      pushRatio("text-muted vs bg-1", rgb["--text-muted"], rgb["--bg-1"]);
      pushRatio("text-muted vs bg-2", rgb["--text-muted"], rgb["--bg-2"]);
      pushRatio("text-faint vs bg-1", rgb["--text-faint"], rgb["--bg-1"]);
      pushRatio("text-faint vs bg-2", rgb["--text-faint"], rgb["--bg-2"]);
      pushRatio("text-faint vs bg-3", rgb["--text-faint"], rgb["--bg-3"]);
      pushRatio("accent-text vs accent", rgb["--accent-text"], rgb["--accent"]);

      // Chips: each chip's real class supplies color (opaque) and
      // background (a semi-transparent *-tint) - render two synthetic
      // hosts (solid bg-1, solid bg-2) and read the CASCADE-COMPUTED
      // values (never the spec's own hex table) so a future CSS edit to
      // any chip rule is caught here automatically.
      ["--bg-1", "--bg-2"].forEach(function (hostBgVar) {
        const hostBgRgb = rgb[hostBgVar];
        if (!hostBgRgb) return;
        const host = win.document.createElement("div");
        host.style.background = tokens[hostBgVar];
        win.document.body.appendChild(host);
        CHIP_CLASSES.forEach(function (cls) {
          const span = win.document.createElement("span");
          span.className = "chip " + cls;
          span.textContent = "Sample";
          host.appendChild(span);
          const cs = win.getComputedStyle(span);
          const fgOpaque = parseColor(cs.color).slice(0, 3);
          const bgRgba = parseColor(cs.backgroundColor);
          const compositedBg = bgRgba[3] < 1 ? compositeOver(bgRgba, hostBgRgb) : bgRgba.slice(0, 3);
          pushRatio(cls + " vs " + hostBgVar, fgOpaque, compositedBg);
          span.remove();
        });
        host.remove();
      });

      theme.allPass = theme.tokenShapeChecks.every(function (c) { return c.passed; }) &&
        theme.contrastChecks.every(function (c) { return c.passed; });
    } catch (e) {
      theme.error = "threw: " + (e && e.message ? e.message : e);
      theme.allPass = false;
    }
    return theme;
  }

  async function main() {
    for (let i = 0; i < THEME_SLUGS.length; i++) {
      const slug = THEME_SLUGS[i];
      statusEl().textContent = "theme " + (i + 1) + "/" + THEME_SLUGS.length + ": " + slug;
      try {
        const win = await loadFrame("?mock=1&test=1&theme=" + encodeURIComponent(slug) + "&view=my-addons");
        await waitForReady(win, 10000);
        // One extra tick so the theme-application/render pass triggered by
        // applyInitialViewFromQuery's Prefs.setTheme call has fully painted
        // before computed styles are read.
        await wait(150);
        results.themes.push(auditTheme(win, slug));
      } catch (e) {
        results.themes.push({ slug: slug, error: "harness-level: " + (e && e.message ? e.message : e), allPass: false, tokenShapeChecks: [], contrastChecks: [] });
      }
      writeResults();
    }
    results.complete = true;
    writeResults();
    statusEl().textContent = "done";
  }

  main().catch(function (e) {
    results.harnessError = "threw: " + (e && e.message ? e.message : e);
    writeResults();
  });
})();
