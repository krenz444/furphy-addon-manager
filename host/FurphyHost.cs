// Furphy Addon Manager - native host (WebView2).
//
// C# 5 / .NET Framework only: no string interpolation, no ?., no
// expression-bodied members, no async/await, no nameof, no using static.
// Anonymous delegate(...) { } blocks are fine and used throughout instead
// of lambdas with expression bodies. Compiled at install time via
// Add-Type + csc.exe (see build-host.ps1) - keep this file self contained
// and free of anything beyond System.*, System.Windows.Forms and the two
// WebView2 SDK assemblies referenced by that build script.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Furphy
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            // Must run before any Form/Control is created - see
            // DpiAwareness below and ROADMAP.md "E19" DPI fix notes.
            bool dpiAware = DpiAwareness.TryEnable();

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            HostOptions options = HostOptions.Parse(args);
            using (MainForm form = new MainForm(options, dpiAware))
            {
                Application.Run(form);
                return form.ExitCode;
            }
        }
    }

    // ------------------------------------------------------------------
    // Per-monitor-v2 DPI awareness. Declared via P/Invoke (the Add-Type/
    // csc.exe compile path produces no app.manifest) so the process opts
    // out of Windows' default bitmap-stretch scaling - the cause of the
    // whole window looking blurry on a >100% scaled display. Tries
    // newest-to-oldest API in a fallback chain; each call is isolated in
    // its own try/catch since the newer entry points do not exist on
    // older Windows and would otherwise throw EntryPointNotFoundException.
    // ------------------------------------------------------------------
    internal static class DpiAwareness
    {
        private static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("shcore.dll")]
        private static extern int SetProcessDpiAwareness(int value);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        public static bool TryEnable()
        {
            try
            {
                if (SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2))
                {
                    return true;
                }
            }
            catch { }

            try
            {
                // PROCESS_PER_MONITOR_DPI_AWARE = 2; S_OK = 0.
                if (SetProcessDpiAwareness(2) == 0)
                {
                    return true;
                }
            }
            catch { }

            try
            {
                if (SetProcessDPIAware())
                {
                    return true;
                }
            }
            catch { }

            return false;
        }
    }

    // ------------------------------------------------------------------
    // Command-line / settings-derived options
    // ------------------------------------------------------------------
    internal class HostOptions
    {
        public int Port;
        public bool SelftestActive;
        public string SelftestMarkerPath;
        public string SelftestTestPageUrl;
        // Optional deep-link params (E20/G): appended to the SPA URL as
        // ?view=..&tab=.. when given. Used for verification and future
        // deep linking; absent (null) means "let the page use its own
        // default", matching every existing launch.
        public string View;
        public string Tab;

        public static HostOptions Parse(string[] args)
        {
            HostOptions o = new HostOptions();
            o.Port = 0; // 0 means "not given on the command line"
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                if (string.Equals(a, "--port", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    int p;
                    if (int.TryParse(args[i + 1], NumberStyles.Integer, CultureInfo.InvariantCulture, out p))
                    {
                        o.Port = p;
                    }
                    i++;
                }
                else if (string.Equals(a, "--selftest", StringComparison.OrdinalIgnoreCase) && i + 2 < args.Length)
                {
                    o.SelftestActive = true;
                    o.SelftestMarkerPath = args[i + 1];
                    o.SelftestTestPageUrl = args[i + 2];
                    i += 2;
                }
                else if (string.Equals(a, "--view", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    o.View = args[i + 1];
                    i++;
                }
                else if (string.Equals(a, "--tab", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    o.Tab = args[i + 1];
                    i++;
                }
            }
            return o;
        }
    }

    // ------------------------------------------------------------------
    // Small ASCII-safe JSON reader/writer (no external assembly - keeps
    // the compile recipe to System.dll/System.Drawing.dll/
    // System.Windows.Forms.dll plus the two WebView2 assemblies).
    // Objects -> Dictionary<string,object>; arrays -> List<object>;
    // numbers -> double or long; strings -> string; true/false -> bool;
    // null -> null.
    // ------------------------------------------------------------------
    internal static class MiniJson
    {
        public static object Parse(string json)
        {
            if (json == null) return null;
            int i = 0;
            object result = ParseValue(json, ref i);
            return result;
        }

        private static void SkipWhitespace(string s, ref int i)
        {
            while (i < s.Length)
            {
                char c = s[i];
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n') { i++; }
                else { break; }
            }
        }

        private static object ParseValue(string s, ref int i)
        {
            SkipWhitespace(s, ref i);
            if (i >= s.Length) return null;
            char c = s[i];
            if (c == '{') return ParseObject(s, ref i);
            if (c == '[') return ParseArray(s, ref i);
            if (c == '"') return ParseString(s, ref i);
            if (c == 't' && Match(s, i, "true")) { i += 4; return true; }
            if (c == 'f' && Match(s, i, "false")) { i += 5; return false; }
            if (c == 'n' && Match(s, i, "null")) { i += 4; return null; }
            return ParseNumber(s, ref i);
        }

        private static bool Match(string s, int i, string literal)
        {
            if (i + literal.Length > s.Length) return false;
            for (int k = 0; k < literal.Length; k++)
            {
                if (s[i + k] != literal[k]) return false;
            }
            return true;
        }

        private static Dictionary<string, object> ParseObject(string s, ref int i)
        {
            Dictionary<string, object> obj = new Dictionary<string, object>();
            i++; // {
            SkipWhitespace(s, ref i);
            if (i < s.Length && s[i] == '}') { i++; return obj; }
            while (i < s.Length)
            {
                SkipWhitespace(s, ref i);
                string key = ParseString(s, ref i);
                SkipWhitespace(s, ref i);
                if (i < s.Length && s[i] == ':') i++;
                object val = ParseValue(s, ref i);
                obj[key] = val;
                SkipWhitespace(s, ref i);
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == '}') { i++; break; }
                break;
            }
            return obj;
        }

        private static List<object> ParseArray(string s, ref int i)
        {
            List<object> arr = new List<object>();
            i++; // [
            SkipWhitespace(s, ref i);
            if (i < s.Length && s[i] == ']') { i++; return arr; }
            while (i < s.Length)
            {
                object val = ParseValue(s, ref i);
                arr.Add(val);
                SkipWhitespace(s, ref i);
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == ']') { i++; break; }
                break;
            }
            return arr;
        }

        private static string ParseString(string s, ref int i)
        {
            SkipWhitespace(s, ref i);
            StringBuilder sb = new StringBuilder();
            if (i >= s.Length || s[i] != '"') return string.Empty;
            i++; // opening quote
            while (i < s.Length)
            {
                char c = s[i];
                if (c == '"') { i++; break; }
                if (c == '\\' && i + 1 < s.Length)
                {
                    char n = s[i + 1];
                    switch (n)
                    {
                        case '"': sb.Append('"'); i += 2; break;
                        case '\\': sb.Append('\\'); i += 2; break;
                        case '/': sb.Append('/'); i += 2; break;
                        case 'b': sb.Append('\b'); i += 2; break;
                        case 'f': sb.Append('\f'); i += 2; break;
                        case 'n': sb.Append('\n'); i += 2; break;
                        case 'r': sb.Append('\r'); i += 2; break;
                        case 't': sb.Append('\t'); i += 2; break;
                        case 'u':
                            if (i + 5 < s.Length)
                            {
                                string hex = s.Substring(i + 2, 4);
                                int code;
                                if (int.TryParse(hex, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out code))
                                {
                                    sb.Append((char)code);
                                }
                                i += 6;
                            }
                            else
                            {
                                i += 2;
                            }
                            break;
                        default:
                            sb.Append(n);
                            i += 2;
                            break;
                    }
                }
                else
                {
                    sb.Append(c);
                    i++;
                }
            }
            return sb.ToString();
        }

        private static object ParseNumber(string s, ref int i)
        {
            int start = i;
            bool isFloat = false;
            if (i < s.Length && (s[i] == '-' || s[i] == '+')) i++;
            while (i < s.Length && char.IsDigit(s[i])) i++;
            if (i < s.Length && s[i] == '.')
            {
                isFloat = true;
                i++;
                while (i < s.Length && char.IsDigit(s[i])) i++;
            }
            if (i < s.Length && (s[i] == 'e' || s[i] == 'E'))
            {
                isFloat = true;
                i++;
                if (i < s.Length && (s[i] == '-' || s[i] == '+')) i++;
                while (i < s.Length && char.IsDigit(s[i])) i++;
            }
            string token = s.Substring(start, i - start);
            if (token.Length == 0) return null;
            if (!isFloat)
            {
                long l;
                if (long.TryParse(token, NumberStyles.Integer, CultureInfo.InvariantCulture, out l)) return l;
            }
            double d;
            if (double.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out d)) return d;
            return null;
        }

        public static string Write(object value)
        {
            StringBuilder sb = new StringBuilder();
            WriteValue(value, sb);
            return sb.ToString();
        }

        private static void WriteValue(object value, StringBuilder sb)
        {
            if (value == null) { sb.Append("null"); return; }
            if (value is Dictionary<string, object>)
            {
                Dictionary<string, object> obj = (Dictionary<string, object>)value;
                sb.Append('{');
                bool first = true;
                foreach (KeyValuePair<string, object> kv in obj)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    WriteString(kv.Key, sb);
                    sb.Append(':');
                    WriteValue(kv.Value, sb);
                }
                sb.Append('}');
                return;
            }
            if (value is List<object>)
            {
                List<object> arr = (List<object>)value;
                sb.Append('[');
                for (int i = 0; i < arr.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    WriteValue(arr[i], sb);
                }
                sb.Append(']');
                return;
            }
            if (value is List<string>)
            {
                List<string> arr = (List<string>)value;
                sb.Append('[');
                for (int i = 0; i < arr.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    WriteString(arr[i], sb);
                }
                sb.Append(']');
                return;
            }
            if (value is string) { WriteString((string)value, sb); return; }
            if (value is bool) { sb.Append(((bool)value) ? "true" : "false"); return; }
            if (value is int) { sb.Append(((int)value).ToString(CultureInfo.InvariantCulture)); return; }
            if (value is long) { sb.Append(((long)value).ToString(CultureInfo.InvariantCulture)); return; }
            if (value is double) { sb.Append(((double)value).ToString("R", CultureInfo.InvariantCulture)); return; }
            // Fallback: treat as string.
            WriteString(Convert.ToString(value, CultureInfo.InvariantCulture), sb);
        }

        private static void WriteString(string s, StringBuilder sb)
        {
            sb.Append('"');
            if (s != null)
            {
                for (int i = 0; i < s.Length; i++)
                {
                    char c = s[i];
                    switch (c)
                    {
                        case '"': sb.Append("\\\""); break;
                        case '\\': sb.Append("\\\\"); break;
                        case '\b': sb.Append("\\b"); break;
                        case '\f': sb.Append("\\f"); break;
                        case '\n': sb.Append("\\n"); break;
                        case '\r': sb.Append("\\r"); break;
                        case '\t': sb.Append("\\t"); break;
                        default:
                            if (c < 0x20 || c > 0x7e)
                            {
                                sb.Append("\\u");
                                sb.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                            }
                            else
                            {
                                sb.Append(c);
                            }
                            break;
                    }
                }
            }
            sb.Append('"');
        }
    }

    // ------------------------------------------------------------------
    // Filesystem helpers: locate settings.json / adfilter-hosts.txt /
    // icon.ico relative to the running exe, and write settings.json
    // atomically (tmp file + move).
    // ------------------------------------------------------------------
    internal static class HostFiles
    {
        public static string ExeDir()
        {
            return Path.GetDirectoryName(Application.ExecutablePath);
        }

        // Looks in the exe's own directory first, then walks up to
        // maxLevels ancestor directories, returning the first path where
        // fileName exists. Used for settings.json (exe dir, then the
        // parent AddonSync folder) and adfilter-hosts.txt (lives in
        // host\, one level above host\bin\ where the exe is built).
        public static string FindUpward(string startDir, string fileName, int maxLevels)
        {
            string dir = startDir;
            for (int level = 0; level <= maxLevels; level++)
            {
                if (string.IsNullOrEmpty(dir)) break;
                try
                {
                    string candidate = Path.Combine(dir, fileName);
                    if (File.Exists(candidate)) return candidate;
                }
                catch { }
                DirectoryInfo parent = null;
                try { parent = Directory.GetParent(dir); }
                catch { }
                if (parent == null) break;
                dir = parent.FullName;
            }
            return null;
        }

        public static Dictionary<string, object> LoadJsonObject(string path)
        {
            if (string.IsNullOrEmpty(path)) return new Dictionary<string, object>();
            try
            {
                string text = File.ReadAllText(path, Encoding.UTF8);
                object parsed = MiniJson.Parse(text);
                Dictionary<string, object> dict = parsed as Dictionary<string, object>;
                if (dict != null) return dict;
            }
            catch { }
            return new Dictionary<string, object>();
        }

        // Read-modify-write: merges mutator's changes into whatever is
        // currently on disk at path (so we never clobber keys written by
        // the PowerShell server or another host instance), then writes
        // atomically via a temp file + move. Swallows all failures -
        // window-position persistence must never crash the host.
        public static void UpdateJsonObject(string path, Action<Dictionary<string, object>> mutator)
        {
            if (string.IsNullOrEmpty(path)) return;
            try
            {
                Dictionary<string, object> current = LoadJsonObject(path);
                mutator(current);
                string json = MiniJson.Write(current);
                string tmpPath = path + ".tmp";
                File.WriteAllText(tmpPath, json, new UTF8Encoding(false));
                if (File.Exists(path))
                {
                    try { File.Delete(path); } catch { }
                }
                File.Move(tmpPath, path);
            }
            catch { }
        }

        public static List<string> LoadHostList(string path)
        {
            List<string> hosts = new List<string>();
            if (string.IsNullOrEmpty(path)) return hosts;
            try
            {
                string[] lines = File.ReadAllLines(path, Encoding.UTF8);
                for (int i = 0; i < lines.Length; i++)
                {
                    string line = lines[i].Trim();
                    if (line.Length == 0) continue;
                    if (line[0] == '#') continue;
                    hosts.Add(line.ToLowerInvariant());
                }
            }
            catch { }
            return hosts;
        }
    }

    // ------------------------------------------------------------------
    // Minimal, timeout-bounded HTTP helpers over HttpWebRequest (no
    // async/await available in C# 5, so these block briefly - all calls
    // target localhost so that is fine).
    // ------------------------------------------------------------------
    internal class HttpResult
    {
        public int StatusCode;
        public string Body;
        public bool NetworkError;
    }

    internal static class Http
    {
        public static string GetString(string url, int timeoutMs)
        {
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                req.Method = "GET";
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                using (Stream s = resp.GetResponseStream())
                using (StreamReader sr = new StreamReader(s, Encoding.UTF8))
                {
                    return sr.ReadToEnd();
                }
            }
            catch
            {
                return null;
            }
        }

        public static HttpResult PostJson(string url, string jsonBody, int timeoutMs)
        {
            HttpResult result = new HttpResult();
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                req.Method = "POST";
                req.ContentType = "application/json";
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                byte[] data = Encoding.UTF8.GetBytes(jsonBody);
                req.ContentLength = data.Length;
                using (Stream reqStream = req.GetRequestStream())
                {
                    reqStream.Write(data, 0, data.Length);
                }
                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                {
                    result.StatusCode = (int)resp.StatusCode;
                    using (Stream s = resp.GetResponseStream())
                    using (StreamReader sr = new StreamReader(s, Encoding.UTF8))
                    {
                        result.Body = sr.ReadToEnd();
                    }
                }
            }
            catch (WebException wex)
            {
                HttpWebResponse hresp = wex.Response as HttpWebResponse;
                if (hresp != null)
                {
                    result.StatusCode = (int)hresp.StatusCode;
                    try
                    {
                        using (Stream s = hresp.GetResponseStream())
                        using (StreamReader sr = new StreamReader(s, Encoding.UTF8))
                        {
                            result.Body = sr.ReadToEnd();
                        }
                    }
                    catch { }
                }
                else
                {
                    result.NetworkError = true;
                }
            }
            catch
            {
                result.NetworkError = true;
            }
            return result;
        }
    }

    // ------------------------------------------------------------------
    // Main window.
    // ------------------------------------------------------------------
    internal class MainForm : Form
    {
        private const string WindowTitle = "Furphy Addon Manager";
        // Hard allow-list: never blocked by the ad filter regardless of
        // what adfilter-hosts.txt contains.
        private static readonly string[] HardAllowHosts = new string[]
        {
            "curseforge.com",
            "forgecdn.net",
            "overwolf.com",
            "cloudflare.com",
            "cloudflareinsights.com",
            "localhost"
        };

        // Chrome colors track the app's CURRENT theme (Lofi Night, Dark,
        // Light or Vaporwave) instead of a hard-coded palette - see
        // ROADMAP.md "E19"/"theme sync". Instance (not static readonly)
        // fields so ApplyTheme(name, colors) can repaint them live from a
        // "theme" WebMessage posted by the page; InitializeDefaultTheme
        // seeds them with Lofi Night (the app's current default theme)
        // before LoadPersistedTheme overlays any settings.json hostTheme.
        // bg0/bg1/bg2/bg3/border/text/muted/accent below are the exact
        // names used in the WebMessage/settings.json "colors" object.
        private Color ChromeBg;       // bg0
        private Color ChromeBgAlt;    // bg1
        private Color ChromeBgActive; // bg2
        private Color ChromeHover;    // bg3
        private Color _chromeBorder;  // border (DWM title bar border only)
        private Color ChromeText;     // text
        private Color ChromeMuted;    // muted
        private Color ChromeAccent;   // accent

        private string _themeName;
        private string _lastSavedThemeName;
        private Dictionary<string, object> _lastSavedThemeColors;

        private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
        private const int DWMWA_BORDER_COLOR = 34;
        private const int DWMWA_CAPTION_COLOR = 35;
        private const int DWMWA_TEXT_COLOR = 36;

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int pvAttribute, int cbAttribute);

        private int _lastDarkModeHresult;
        private int _lastCaptionHresult;
        private int _lastTextHresult;
        private int _lastBorderHresult;

        // Home URL for the embedded CurseForge pane (contract E's cf-nav
        // "home" action and the pane's initial cf-show fallback).
        private const string CfHomeUrl = "https://www.curseforge.com/wow/addons";

        private readonly HostOptions _options;
        private readonly string _settingsPath;
        private readonly string _adFilterListPath;
        private readonly string _hostLogPath;
        private readonly int _port;
        private readonly bool _dpiAware;
        private int _effectiveDpi;

        // Round 15 (E20 - embedded CurseForge pane): the left nav strip /
        // WinForms tab layout and the WinForms CurseForge toolbar are gone.
        // _contentPanel fills the whole form; _furphyWebView (the SPA,
        // always the only thing the player sees chrome-wise) docks Fill
        // inside it, and _cfWebView is a second, independently positioned
        // child of the SAME panel - invisible until the page tells the
        // host to show it (cf-show), moved/resized on cf-rect, and drawn
        // over the SPA's own placeholder element via BringToFront. The
        // page now draws its own CurseForge toolbar (back/forward/home/
        // search) in HTML; the host only executes cf-nav actions.
        private Panel _contentPanel;
        private WebView2 _furphyWebView;
        private WebView2 _cfWebView;

        private bool _furphyReady;
        private bool _cfReady;
        private bool _cfFilterInfraRegistered;
        private bool _cfAdCssInjected;
        private bool _cfSelftestDeepLinkInjected;
        private bool _adFilterEnabled;
        private List<string> _adFilterHosts;

        // cf-pane state (contract E/F): whether the CF view has ever been
        // navigated (cf-show only auto-navigates the FIRST time, or when
        // the message explicitly carries navigate:true), whether its most
        // recent NavigationStarting/NavigationCompleted pair is still
        // in flight (for cf-state's "loading" field), the last URL the
        // host actually navigated it to, and counters/last-applied-bounds
        // surfaced on the --selftest marker.
        private bool _cfHasNavigated;
        private bool _cfLoading;
        private string _cfLastUrl;
        private int _cfShowCount;
        private int _cfHideCount;
        private int _cfStateMessageCount;
        private Rectangle _cfPaneBoundsDevicePx;

        // host-ready (contract F): sent once after the Furphy webview's
        // CoreWebView2 finishes initializing, and again on every
        // page-sent {type:"hello"} so a reloaded page can re-discover the
        // host and its capabilities.
        private bool _hostReadySent;
        private string _hostVersion;

        private System.Windows.Forms.Timer _selftestTimer;
        private System.Windows.Forms.Timer _selftestCaptureTimer;
        private bool _selftestMarkerWritten;
        private readonly List<string> _selftestBlocked = new List<string>();
        private readonly List<string> _selftestAllowed = new List<string>();
        private readonly List<string> _selftestIntercepted = new List<string>();
        private int? _selftestJobPostStatus;
        private string _webviewVersion;
        private int _selftestThemeMessageCount;
        private string _selftestOpenCurseforgeUrl;
        private string _selftestCapturePath;

        public int ExitCode;

        public MainForm(HostOptions options, bool dpiAware)
        {
            _options = options;
            _dpiAware = dpiAware;

            // Lets WinForms rescale child control fonts/bounds
            // automatically if the window is later dragged to a monitor
            // with a different DPI; must be set before any control exists.
            AutoScaleMode = AutoScaleMode.Dpi;

            string exeDir = HostFiles.ExeDir();
            _settingsPath = HostFiles.FindUpward(exeDir, "settings.json", 4);
            _adFilterListPath = HostFiles.FindUpward(exeDir, "adfilter-hosts.txt", 4);
            string logDir = _settingsPath != null ? Path.GetDirectoryName(_settingsPath) : exeDir;
            _hostLogPath = Path.Combine(logDir, "host.log");

            _port = ResolvePort();
            _hostVersion = ResolveHostVersion(exeDir);

            // Seed the chrome palette with Lofi Night, then overlay any
            // persisted settings.json hostTheme - BEFORE BuildUi() below so
            // every control is constructed with the right colors from the
            // start instead of flashing default then repainting. A live
            // "theme" WebMessage later calls ApplyTheme to update both the
            // WinForms chrome and the DWM title-bar attributes (see
            // OnHandleCreated and HandleThemeMessage).
            InitializeDefaultTheme();
            LoadPersistedTheme();

            Text = WindowTitle;
            StartPosition = FormStartPosition.Manual;
            MinimumSize = new Size(900, 600);
            BackColor = ChromeBg;

            string iconPath = HostFiles.FindUpward(exeDir, "icon.ico", 1);
            if (iconPath != null)
            {
                try { Icon = new Icon(iconPath); } catch { }
            }

            ApplyWindowBounds();

            // DeviceDpi reflects the DPI of the monitor the form will be
            // created on now that per-monitor-v2 awareness is declared
            // (DpiAwareness.TryEnable, called before this form existed).
            _effectiveDpi = DeviceDpi;

            BuildUi();

            LogHost("dpi=" + _effectiveDpi.ToString(CultureInfo.InvariantCulture) +
                " dpiAware=" + _dpiAware.ToString());

            Load += new EventHandler(MainForm_Load);
            FormClosing += new FormClosingEventHandler(MainForm_FormClosing);
        }

        // Windows creates the native window handle before Load fires (per
        // the standard HandleCreated -> Load -> Shown order), so this is
        // the first point the DWMWA_* title-bar attributes can actually be
        // set - see ApplyTitleBarColors. Also re-applied on every live
        // "theme" WebMessage (HandleThemeMessage -> ApplyTheme).
        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            ApplyTitleBarColors();
        }

        // -------------------------------------------------------- setup

        private int ResolvePort()
        {
            if (_options.Port > 0) return _options.Port;
            Dictionary<string, object> settings = HostFiles.LoadJsonObject(_settingsPath);
            object portObj;
            if (settings.TryGetValue("port", out portObj) && portObj != null)
            {
                int p = ToInt(portObj, 0);
                if (p > 0) return p;
            }
            return 47831;
        }

        // host-ready's "version" field (contract F) is the app's own
        // VERSION file (E18's single source of truth - see SPEC.md), NOT
        // the WebView2 runtime version (that is _webviewVersion, reported
        // separately on the --selftest marker). Located the same way
        // settings.json/adfilter-hosts.txt already are; falls back to a
        // placeholder rather than blocking startup on a dev checkout with
        // no VERSION file.
        private static string ResolveHostVersion(string exeDir)
        {
            string path = HostFiles.FindUpward(exeDir, "VERSION", 4);
            if (path != null)
            {
                try
                {
                    string text = File.ReadAllText(path, Encoding.UTF8).Trim();
                    if (text.Length > 0) return text;
                }
                catch { }
            }
            return "0.0.0-dev";
        }

        private static int ToInt(object o, int fallback)
        {
            if (o is long) return (int)(long)o;
            if (o is int) return (int)o;
            if (o is double) return (int)(double)o;
            int parsed;
            if (o is string && int.TryParse((string)o, out parsed)) return parsed;
            return fallback;
        }

        private static bool ToBool(object o, bool fallback)
        {
            if (o is bool) return (bool)o;
            if (o is string)
            {
                string s = ((string)o).Trim().ToLowerInvariant();
                if (s == "true") return true;
                if (s == "false") return false;
            }
            return fallback;
        }

        // Used for cf-show/cf-rect's rect{x,y,w,h}/dpr fields, which the
        // page sends as JSON numbers (MiniJson parses them as double or
        // long depending on whether a decimal point was present).
        private static double ToDouble(object o, double fallback)
        {
            if (o is double) return (double)o;
            if (o is long) return (long)o;
            if (o is int) return (int)o;
            double parsed;
            if (o is string && double.TryParse((string)o, NumberStyles.Float, CultureInfo.InvariantCulture, out parsed)) return parsed;
            return fallback;
        }

        private static object DictGet(Dictionary<string, object> d, string key)
        {
            object v;
            return (d != null && d.TryGetValue(key, out v)) ? v : null;
        }

        private bool ReadAdFilterSetting()
        {
            Dictionary<string, object> settings = HostFiles.LoadJsonObject(_settingsPath);
            object v;
            if (settings.TryGetValue("adFilter", out v) && v != null)
            {
                return ToBool(v, false);
            }
            return false;
        }

        private void ApplyWindowBounds()
        {
            Rectangle def = new Rectangle(0, 0, 1320, 900);
            bool haveSaved = false;
            Dictionary<string, object> settings = HostFiles.LoadJsonObject(_settingsPath);
            object hw;
            if (settings.TryGetValue("hostWindow", out hw) && hw is Dictionary<string, object>)
            {
                Dictionary<string, object> win = (Dictionary<string, object>)hw;
                try
                {
                    int x = ToInt(win.ContainsKey("x") ? win["x"] : null, int.MinValue);
                    int y = ToInt(win.ContainsKey("y") ? win["y"] : null, int.MinValue);
                    int w = ToInt(win.ContainsKey("w") ? win["w"] : 0, 0);
                    int h = ToInt(win.ContainsKey("h") ? win["h"] : 0, 0);
                    if (w >= 400 && h >= 300 && x > int.MinValue && y > int.MinValue)
                    {
                        Rectangle candidate = new Rectangle(x, y, w, h);
                        if (IsOnAnyScreen(candidate))
                        {
                            def = candidate;
                            haveSaved = true;
                        }
                    }
                }
                catch { }
            }
            Size = new Size(def.Width, def.Height);
            if (haveSaved)
            {
                Location = new Point(def.X, def.Y);
            }
            else
            {
                StartPosition = FormStartPosition.CenterScreen;
            }
        }

        private static bool IsOnAnyScreen(Rectangle r)
        {
            Screen[] screens = Screen.AllScreens;
            for (int i = 0; i < screens.Length; i++)
            {
                if (screens[i].Bounds.IntersectsWith(r)) return true;
            }
            return false;
        }

        private void SaveWindowBounds()
        {
            Rectangle b = (WindowState == FormWindowState.Normal) ? Bounds : RestoreBounds;
            if (b.Width < 400 || b.Height < 300) return;
            HostFiles.UpdateJsonObject(_settingsPath, delegate(Dictionary<string, object> dict)
            {
                Dictionary<string, object> win = new Dictionary<string, object>();
                win["x"] = (long)b.X;
                win["y"] = (long)b.Y;
                win["w"] = (long)b.Width;
                win["h"] = (long)b.Height;
                dict["hostWindow"] = win;
            });
        }

        // ------------------------------------------------------- theming

        // Lofi Night - the app's current default theme (ui/style.css
        // data-theme="lofi": --bg-0.. --bg-3, --border, --text,
        // --text-muted, --accent). Overwritten by LoadPersistedTheme
        // (settings.json hostTheme) and, live, by ApplyTheme whenever a
        // "theme" WebMessage arrives (HandleThemeMessage).
        private void InitializeDefaultTheme()
        {
            ChromeBg = Color.FromArgb(0x0f, 0x12, 0x26);       // --bg-0
            ChromeBgAlt = Color.FromArgb(0x16, 0x1b, 0x34);    // --bg-1
            ChromeBgActive = Color.FromArgb(0x1e, 0x24, 0x45); // --bg-2
            ChromeHover = Color.FromArgb(0x26, 0x2d, 0x55);    // --bg-3
            _chromeBorder = Color.FromArgb(0x34, 0x3b, 0x66);  // --border
            ChromeText = Color.FromArgb(0xf2, 0xee, 0xe6);     // --text
            ChromeMuted = Color.FromArgb(0xb3, 0xb1, 0xc9);    // --text-muted
            ChromeAccent = Color.FromArgb(0xff, 0xb8, 0x6b);   // --accent
            _themeName = "lofi";
        }

        // Reads settings.json's optional hostTheme = {name, colors} and, if
        // present, overlays it onto the InitializeDefaultTheme() values.
        // Called once from the constructor, before BuildUi(), so the
        // window opens already painted in the last theme the page reported
        // - mirrors how ApplyWindowBounds reads hostWindow up front.
        private void LoadPersistedTheme()
        {
            Dictionary<string, object> settings = HostFiles.LoadJsonObject(_settingsPath);
            object hostThemeObj;
            if (!settings.TryGetValue("hostTheme", out hostThemeObj)) return;
            Dictionary<string, object> hostTheme = hostThemeObj as Dictionary<string, object>;
            if (hostTheme == null) return;

            object nameObj;
            string name = hostTheme.TryGetValue("name", out nameObj) ? nameObj as string : null;
            object colorsObj;
            Dictionary<string, object> colors = null;
            if (hostTheme.TryGetValue("colors", out colorsObj))
            {
                colors = colorsObj as Dictionary<string, object>;
            }

            SetThemeColorFields(colors);
            if (IsValidThemeName(name)) _themeName = name;

            // Record what is already on disk as "last saved" so the first
            // live "theme" message that happens to match it does not
            // trigger a redundant re-save (PersistThemeIfChanged below),
            // while a message that actually differs still gets saved.
            if (colors != null)
            {
                _lastSavedThemeName = _themeName;
                _lastSavedThemeColors = CurrentThemeColorsDict();
            }
        }

        // Applies a theme (from a live WebMessage - see HandleThemeMessage)
        // to the in-memory palette, the already-built WinForms chrome, and
        // the DWM title-bar attributes; optionally persists it to
        // settings.json when it actually changed. colors may be null or
        // missing keys - each key present and matching #rrggbb overwrites
        // the corresponding field, everything else keeps its current
        // value (tolerates a partial/malformed message).
        private void ApplyTheme(string name, Dictionary<string, object> colors, bool persistIfChanged)
        {
            SetThemeColorFields(colors);
            if (IsValidThemeName(name)) _themeName = name;

            RecolorChrome();
            ApplyTitleBarColors();

            if (persistIfChanged)
            {
                PersistThemeIfChanged();
            }
        }

        // Adversarial-review fix: PersistThemeIfChanged writes _themeName
        // straight to settings.json's hostTheme.name via the direct
        // HostFiles.UpdateJsonObject path (see its own comment above),
        // which - unlike a PUT /api/settings call - never passes through
        // addon-server.ps1's Test-HostTheme validation
        // (^[a-z0-9-]+$, 1-32 chars). Enforcing the identical rule here
        // keeps that invariant true regardless of which path wrote the
        // file, and also stops an untrusted postMessage (see
        // CfWebView_InitCompleted's comment) from landing an arbitrary
        // string in _themeName/settings.json even where the message-source
        // gap above is ever reopened.
        private static readonly Regex ThemeNameRegex = new Regex("^[a-z0-9-]{1,32}$", RegexOptions.None);

        private static bool IsValidThemeName(string name)
        {
            return !string.IsNullOrEmpty(name) && ThemeNameRegex.IsMatch(name);
        }

        private void SetThemeColorFields(Dictionary<string, object> colors)
        {
            ChromeBg = ColorFromDict(colors, "bg0", ChromeBg);
            ChromeBgAlt = ColorFromDict(colors, "bg1", ChromeBgAlt);
            ChromeBgActive = ColorFromDict(colors, "bg2", ChromeBgActive);
            ChromeHover = ColorFromDict(colors, "bg3", ChromeHover);
            _chromeBorder = ColorFromDict(colors, "border", _chromeBorder);
            ChromeText = ColorFromDict(colors, "text", ChromeText);
            ChromeMuted = ColorFromDict(colors, "muted", ChromeMuted);
            ChromeAccent = ColorFromDict(colors, "accent", ChromeAccent);
        }

        // Repaints every already-built chrome control from the current
        // Chrome* fields. Safe to call before BuildUi has run (no-op) -
        // ApplyTheme is only expected to reach live controls after the
        // window is up; the initial palette is picked up by BuildUi
        // constructing controls directly from the fields instead.
        // Round 15 (E20 - embedded CurseForge pane): there is no more
        // WinForms nav strip or CurseForge toolbar to recolor - the page
        // draws its own CurseForge toolbar in HTML now - so this is just
        // the form background, the one content panel, and both WebView2s'
        // DefaultBackgroundColor (the CF pane's own page content paints
        // itself; this only affects the color visible before/around it).
        private void RecolorChrome()
        {
            if (_contentPanel == null) return;

            BackColor = ChromeBg;
            _contentPanel.BackColor = ChromeBg;

            try { _furphyWebView.DefaultBackgroundColor = ChromeBg; } catch { }
            try { _cfWebView.DefaultBackgroundColor = ChromeBg; } catch { }
        }

        // Windows title bar (DWM). Attribute 20 (dark mode) is applied
        // before/alongside the explicit colours per spec; every call is
        // independently try/caught (older Windows returns E_INVALIDARG for
        // 34/35/36, and dwmapi.dll's entry points could in principle be
        // absent) and the raw HRESULTs are kept for the --selftest marker.
        private void ApplyTitleBarColors()
        {
            if (!IsHandleCreated) return;
            IntPtr hwnd = Handle;

            int darkMode = RelativeLuminance(ChromeBg) < 0.5 ? 1 : 0;
            _lastDarkModeHresult = TrySetDwmAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, darkMode);
            _lastCaptionHresult = TrySetDwmAttribute(hwnd, DWMWA_CAPTION_COLOR, ColorToColorRef(ChromeBg));
            _lastTextHresult = TrySetDwmAttribute(hwnd, DWMWA_TEXT_COLOR, ColorToColorRef(ChromeText));
            _lastBorderHresult = TrySetDwmAttribute(hwnd, DWMWA_BORDER_COLOR, ColorToColorRef(_chromeBorder));

            LogHost("title bar theme applied: dark=" + darkMode.ToString(CultureInfo.InvariantCulture) +
                " darkHr=" + _lastDarkModeHresult.ToString(CultureInfo.InvariantCulture) +
                " captionHr=" + _lastCaptionHresult.ToString(CultureInfo.InvariantCulture) +
                " textHr=" + _lastTextHresult.ToString(CultureInfo.InvariantCulture) +
                " borderHr=" + _lastBorderHresult.ToString(CultureInfo.InvariantCulture));
        }

        private static int TrySetDwmAttribute(IntPtr hwnd, int attribute, int value)
        {
            try
            {
                int v = value;
                return DwmSetWindowAttribute(hwnd, attribute, ref v, sizeof(int));
            }
            catch
            {
                // dwmapi.dll or the specific entry point is unavailable -
                // treat like any other unsupported-attribute HRESULT.
                return unchecked((int)0x80004005); // E_FAIL
            }
        }

        // COLORREF is 0x00BBGGRR - blue in the high byte.
        private static int ColorToColorRef(Color c)
        {
            return (c.B << 16) | (c.G << 8) | c.R;
        }

        // WCAG relative luminance (0..1); < 0.5 is treated as "dark".
        private static double RelativeLuminance(Color c)
        {
            double r = ChannelToLinear(c.R);
            double g = ChannelToLinear(c.G);
            double b = ChannelToLinear(c.B);
            return 0.2126 * r + 0.7152 * g + 0.0722 * b;
        }

        private static double ChannelToLinear(int channel8)
        {
            double c = channel8 / 255.0;
            if (c <= 0.03928) return c / 12.92;
            return Math.Pow((c + 0.055) / 1.055, 2.4);
        }

        // Persistence: mirrors SaveWindowBounds exactly - hostWindow is
        // written by FurphyHost.exe directly to settings.json via
        // HostFiles.UpdateJsonObject (see addon-server.ps1's
        // Handle-SettingsPut comment: "hostWindow is set almost
        // exclusively by FurphyHost.exe writing settings.json directly,
        // bypassing this endpoint entirely"), NOT through PUT /api/settings
        // - so hostTheme goes through the exact same direct, atomic
        // read-modify-write-merge instead of an HTTP call.
        private void PersistThemeIfChanged()
        {
            Dictionary<string, object> current = CurrentThemeColorsDict();
            bool changed = _lastSavedThemeColors == null
                || !string.Equals(_lastSavedThemeName, _themeName, StringComparison.Ordinal)
                || !ThemeDictEquals(current, _lastSavedThemeColors);
            if (!changed) return;

            string nameToSave = _themeName;
            HostFiles.UpdateJsonObject(_settingsPath, delegate(Dictionary<string, object> dict)
            {
                Dictionary<string, object> theme = new Dictionary<string, object>();
                theme["name"] = nameToSave;
                theme["colors"] = current;
                dict["hostTheme"] = theme;
            });
            _lastSavedThemeName = nameToSave;
            _lastSavedThemeColors = current;
            LogHost("hostTheme saved: " + (nameToSave == null ? "(null)" : nameToSave));
        }

        private Dictionary<string, object> CurrentThemeColorsDict()
        {
            Dictionary<string, object> d = new Dictionary<string, object>();
            d["bg0"] = ColorToHex(ChromeBg);
            d["bg1"] = ColorToHex(ChromeBgAlt);
            d["bg2"] = ColorToHex(ChromeBgActive);
            d["bg3"] = ColorToHex(ChromeHover);
            d["border"] = ColorToHex(_chromeBorder);
            d["text"] = ColorToHex(ChromeText);
            d["muted"] = ColorToHex(ChromeMuted);
            d["accent"] = ColorToHex(ChromeAccent);
            return d;
        }

        private static bool ThemeDictEquals(Dictionary<string, object> a, Dictionary<string, object> b)
        {
            if (a == null || b == null) return a == b;
            if (a.Count != b.Count) return false;
            foreach (KeyValuePair<string, object> kv in a)
            {
                object other;
                if (!b.TryGetValue(kv.Key, out other)) return false;
                string sa = kv.Value as string;
                string sb = other as string;
                if (!string.Equals(sa, sb, StringComparison.OrdinalIgnoreCase)) return false;
            }
            return true;
        }

        private static Color ColorFromDict(Dictionary<string, object> colors, string key, Color fallback)
        {
            if (colors == null) return fallback;
            object v;
            if (!colors.TryGetValue(key, out v)) return fallback;
            string s = v as string;
            Color parsed;
            if (s != null && TryParseHexColor(s, out parsed)) return parsed;
            return fallback;
        }

        private static bool TryParseHexColor(string hex, out Color color)
        {
            color = Color.Empty;
            if (string.IsNullOrEmpty(hex)) return false;
            string h = hex.Trim();
            if (h.Length != 7 || h[0] != '#') return false;
            int r, g, b;
            if (!int.TryParse(h.Substring(1, 2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out r)) return false;
            if (!int.TryParse(h.Substring(3, 2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out g)) return false;
            if (!int.TryParse(h.Substring(5, 2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out b)) return false;
            color = Color.FromArgb(r, g, b);
            return true;
        }

        private static string ColorToHex(Color c)
        {
            return string.Format(CultureInfo.InvariantCulture, "#{0:x2}{1:x2}{2:x2}", c.R, c.G, c.B);
        }

        // ---------------------------------------------- page -> host messages

        // Contract E: attached to _furphyWebView ONLY (FurphyWebView_InitCompleted)
        // - the trusted app SPA, gated page-side by
        // App.getServerHost() === "webview2". Round 15 (E20) simplifies this
        // from earlier rounds: --selftest's host\selftest.html now loads AS
        // _furphyWebView's own page during --selftest (see MainForm_Load),
        // in place of the real server-hosted SPA, specifically so it can
        // exercise this same contract (hello/theme/cf-show/cf-rect/cf-hide/
        // cf-nav) from the one webview these messages are ever honored
        // from - so there is no longer a second, --selftest-only listener
        // on _cfWebView, and no dual-source race to guard against.
        // _cfWebView loads live, untrusted curseforge.com content in
        // production and is deliberately left unwired for this event
        // entirely (adversarial-review precedent from Round 13: an
        // untrusted CF-pane page must not be able to drive host chrome,
        // theme, or the pane's own position/navigation via postMessage).
        private void HostWebView_WebMessageReceived(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            try
            {
                string json = e.WebMessageAsJson;
                Dictionary<string, object> msg = MiniJson.Parse(json) as Dictionary<string, object>;
                if (msg == null) return;

                object typeObj;
                string type = msg.TryGetValue("type", out typeObj) ? typeObj as string : null;
                if (string.IsNullOrEmpty(type)) return;

                if (type == "hello")
                {
                    SendHostReady();
                }
                else if (type == "open-curseforge")
                {
                    object urlObj;
                    string url = msg.TryGetValue("url", out urlObj) ? urlObj as string : null;
                    HandleOpenCurseforgeMessage(url);
                }
                else if (type == "cf-show")
                {
                    HandleCfShow(msg);
                }
                else if (type == "cf-rect")
                {
                    ApplyCfRect(msg);
                }
                else if (type == "cf-hide")
                {
                    HideCfPane();
                }
                else if (type == "cf-nav")
                {
                    HandleCfNav(msg);
                }
                else if (type == "theme")
                {
                    object nameObj;
                    string name = msg.TryGetValue("name", out nameObj) ? nameObj as string : null;
                    object colorsObj;
                    Dictionary<string, object> colors = null;
                    if (msg.TryGetValue("colors", out colorsObj))
                    {
                        colors = colorsObj as Dictionary<string, object>;
                    }
                    _selftestThemeMessageCount++;

                    // Adversarial-review fix (finding: --selftest permanently
                    // corrupts the user's real persisted hostTheme):
                    // persistIfChanged must never be true during --selftest,
                    // or selftest.html's synthetic test palette gets written
                    // straight into settings.json via PersistThemeIfChanged
                    // -> HostFiles.UpdateJsonObject, the same file a real,
                    // non-selftest launch reads on startup.
                    bool persist = !_options.SelftestActive;
                    ApplyTheme(name, colors, persist);
                }
                else
                {
                    LogHost("unknown webmessage type: " + type);
                }
            }
            catch (Exception ex)
            {
                LogHost("WebMessageReceived failed: " + ex.Message);
            }
        }

        private static bool IsAllowedCfUrl(string url)
        {
            return !string.IsNullOrEmpty(url) &&
                url.StartsWith("https://www.curseforge.com/", StringComparison.OrdinalIgnoreCase);
        }

        // Contract E's {type:"open-curseforge", url} - kept for backward
        // compatibility with a page that hasn't adopted cf-show yet: just
        // navigates the CF pane and reports its new state, WITHOUT
        // changing visibility/bounds (the page is expected to have already
        // shown the pane itself via cf-show if it wants it visible).
        private void HandleOpenCurseforgeMessage(string url)
        {
            if (!IsAllowedCfUrl(url))
            {
                LogHost("open-curseforge ignored, bad url: " + (url == null ? "(null)" : url));
                return;
            }

            NavigateCf(url);
            _cfHasNavigated = true;
            _cfLastUrl = url;
            _selftestOpenCurseforgeUrl = url;
            SendCfState();
        }

        // {type:"cf-show", rect:{x,y,w,h}, dpr, url?, navigate?}: position/
        // size the pane (ApplyCfRect), navigate it when it has never had a
        // page yet (about:blank) or the message explicitly asks to
        // (navigate:true), then make it visible and report its state.
        private void HandleCfShow(Dictionary<string, object> msg)
        {
            ApplyCfRect(msg);

            object urlObj;
            string url = msg.TryGetValue("url", out urlObj) ? urlObj as string : null;
            object navObj;
            bool navigate = msg.TryGetValue("navigate", out navObj) && ToBool(navObj, false);

            if (!string.IsNullOrEmpty(url) && (!_cfHasNavigated || navigate))
            {
                if (IsAllowedCfUrl(url))
                {
                    NavigateCf(url);
                    _cfHasNavigated = true;
                    _cfLastUrl = url;
                }
                else
                {
                    LogHost("cf-show url rejected (not allow-listed): " + url);
                }
            }

            ShowCfPane();
            SendCfState();

            LogHost("cf-show rect=" + _cfPaneBoundsDevicePx.X.ToString(CultureInfo.InvariantCulture) +
                "," + _cfPaneBoundsDevicePx.Y.ToString(CultureInfo.InvariantCulture) +
                " " + _cfPaneBoundsDevicePx.Width.ToString(CultureInfo.InvariantCulture) +
                "x" + _cfPaneBoundsDevicePx.Height.ToString(CultureInfo.InvariantCulture) +
                " url=" + (string.IsNullOrEmpty(url) ? (_cfLastUrl == null ? "(unchanged)" : _cfLastUrl) : url));
        }

        // {type:"cf-rect", rect, dpr}: move/resize only, sent rAF-throttled
        // by the page on ResizeObserver/window-resize/scroll/layout
        // changes. Shared with cf-show above, which also repositions
        // before showing.
        private void ApplyCfRect(Dictionary<string, object> msg)
        {
            object rectObj;
            if (!msg.TryGetValue("rect", out rectObj)) return;
            Dictionary<string, object> rect = rectObj as Dictionary<string, object>;
            if (rect == null) return;

            double dpr = ToDouble(DictGet(msg, "dpr"), 1.0);
            if (dpr <= 0) dpr = 1.0;

            double x = ToDouble(DictGet(rect, "x"), 0);
            double y = ToDouble(DictGet(rect, "y"), 0);
            double w = ToDouble(DictGet(rect, "w"), 0);
            double h = ToDouble(DictGet(rect, "h"), 0);

            int dx = (int)Math.Round(x * dpr);
            int dy = (int)Math.Round(y * dpr);
            int dw = Math.Max(0, (int)Math.Round(w * dpr));
            int dh = Math.Max(0, (int)Math.Round(h * dpr));

            // Bounds are relative to _contentPanel - _furphyWebView also
            // docks Fill inside that same panel, so its client origin IS
            // the panel origin the page's getBoundingClientRect() values
            // are measured against.
            _cfWebView.Bounds = new Rectangle(dx, dy, dw, dh);
            _cfPaneBoundsDevicePx = _cfWebView.Bounds;

            LogHost("cf-rect applied x=" + dx.ToString(CultureInfo.InvariantCulture) +
                " y=" + dy.ToString(CultureInfo.InvariantCulture) +
                " w=" + dw.ToString(CultureInfo.InvariantCulture) +
                " h=" + dh.ToString(CultureInfo.InvariantCulture) +
                " dpr=" + dpr.ToString(CultureInfo.InvariantCulture));
        }

        private void ShowCfPane()
        {
            _cfWebView.Visible = true;
            _cfWebView.BringToFront();
            _cfShowCount++;
        }

        private void HideCfPane()
        {
            // Keeps the page loaded (Source untouched) so back/forward
            // state survives, per contract E.
            _cfWebView.Visible = false;
            _cfHideCount++;
        }

        // {type:"cf-nav", action:"back"|"forward"|"reload"|"home"|"go", url?}
        private void HandleCfNav(Dictionary<string, object> msg)
        {
            object actionObj;
            string action = msg.TryGetValue("action", out actionObj) ? actionObj as string : null;
            if (string.IsNullOrEmpty(action)) return;
            action = action.Trim().ToLowerInvariant();

            if (action == "back")
            {
                if (_cfWebView.CoreWebView2 != null && _cfWebView.CoreWebView2.CanGoBack)
                {
                    _cfWebView.CoreWebView2.GoBack();
                }
            }
            else if (action == "forward")
            {
                if (_cfWebView.CoreWebView2 != null && _cfWebView.CoreWebView2.CanGoForward)
                {
                    _cfWebView.CoreWebView2.GoForward();
                }
            }
            else if (action == "reload")
            {
                if (_cfWebView.CoreWebView2 != null)
                {
                    _cfWebView.CoreWebView2.Reload();
                }
            }
            else if (action == "home")
            {
                NavigateCf(CfHomeUrl);
                _cfHasNavigated = true;
                _cfLastUrl = CfHomeUrl;
            }
            else if (action == "go")
            {
                object urlObj;
                string url = msg.TryGetValue("url", out urlObj) ? urlObj as string : null;
                if (IsAllowedCfUrl(url))
                {
                    NavigateCf(url);
                    _cfHasNavigated = true;
                    _cfLastUrl = url;
                }
                else
                {
                    LogHost("cf-nav go url rejected (not allow-listed): " + (url == null ? "(null)" : url));
                }
            }
            else
            {
                LogHost("unknown cf-nav action: " + action);
                return;
            }

            SendCfState();
        }

        // ---------------------------------------------- host -> page messages

        private void PostToFurphy(Dictionary<string, object> msg)
        {
            try
            {
                if (_furphyWebView != null && _furphyWebView.CoreWebView2 != null)
                {
                    _furphyWebView.CoreWebView2.PostWebMessageAsJson(MiniJson.Write(msg));
                }
            }
            catch (Exception ex)
            {
                LogHost("PostToFurphy failed: " + ex.Message);
            }
        }

        // Contract F: sent once the Furphy webview's CoreWebView2 is ready
        // (FurphyWebView_InitCompleted), and again on every page-sent
        // {type:"hello"} so a reloaded page can re-discover the host and
        // its capabilities. This host always supports the CF pane, so
        // capabilities is always exactly ["cf-pane"].
        private void SendHostReady()
        {
            Dictionary<string, object> msg = new Dictionary<string, object>();
            msg["type"] = "host-ready";
            msg["version"] = _hostVersion;
            List<string> caps = new List<string>();
            caps.Add("cf-pane");
            msg["capabilities"] = caps;
            PostToFurphy(msg);
            _hostReadySent = true;
        }

        // Contract F: sent on the CF pane's NavigationStarting (loading
        // true), NavigationCompleted (loading false), HistoryChanged,
        // DocumentTitleChanged, and right after cf-show/cf-nav (called
        // directly from HandleCfShow/HandleCfNav above).
        private void SendCfState()
        {
            string url = null;
            string title = null;
            bool canGoBack = false;
            bool canGoForward = false;
            try
            {
                if (_cfWebView.CoreWebView2 != null)
                {
                    url = _cfWebView.CoreWebView2.Source;
                    title = _cfWebView.CoreWebView2.DocumentTitle;
                    canGoBack = _cfWebView.CoreWebView2.CanGoBack;
                    canGoForward = _cfWebView.CoreWebView2.CanGoForward;
                }
            }
            catch { }

            Dictionary<string, object> msg = new Dictionary<string, object>();
            msg["type"] = "cf-state";
            msg["url"] = url;
            msg["title"] = title;
            msg["canGoBack"] = canGoBack;
            msg["canGoForward"] = canGoForward;
            msg["loading"] = _cfLoading;
            PostToFurphy(msg);
            _cfStateMessageCount++;
        }

        // Contract F: {type:"cf-job", jobId, status} - posted the instant
        // the host itself intercepts an install link and posts /api/jobs
        // (HandleCurseforgeProtocol/HandleSlugInstall below), so the SPA
        // can open its job panel immediately instead of waiting for the
        // next poll.
        private void SendCfJob(string jobId, string status)
        {
            if (string.IsNullOrEmpty(jobId)) return;
            Dictionary<string, object> msg = new Dictionary<string, object>();
            msg["type"] = "cf-job";
            msg["jobId"] = jobId;
            msg["status"] = status;
            PostToFurphy(msg);
        }

        // Round 15 (E20): the DPI-derived Scaled()/DpiScale() pixel-math
        // helpers that used to size the hand-built WinForms nav strip and
        // CurseForge toolbar are gone along with that chrome - the page
        // draws its own (CSS-driven, already DPI-correct) toolbar in HTML
        // now. _effectiveDpi/_dpiAware themselves are kept (DpiAwareness,
        // OnHandleCreated's DPI-aware window placement, and the
        // dpi/dpiAware --selftest marker fields all still need them).

        // -------------------------------------------------------- layout

        // Round 15 (E20): no more left nav strip / WinForms tab layout and
        // no more WinForms CurseForge toolbar - the page draws its own
        // toolbar in HTML now (contract C). _contentPanel fills the whole
        // form; _furphyWebView (the SPA) docks Fill inside it; _cfWebView
        // is a second child of the SAME panel, invisible and unpositioned
        // (no Source set - see MainForm_Load) until the page's first
        // cf-show message.
        private void BuildUi()
        {
            BackColor = ChromeBg;

            _contentPanel = new Panel();
            _contentPanel.Dock = DockStyle.Fill;
            _contentPanel.BackColor = ChromeBg;

            _furphyWebView = new WebView2();
            _furphyWebView.Dock = DockStyle.Fill;
            try { _furphyWebView.DefaultBackgroundColor = ChromeBg; } catch { }

            _cfWebView = new WebView2();
            _cfWebView.Visible = false;
            try { _cfWebView.DefaultBackgroundColor = ChromeBg; } catch { }

            // _furphyWebView added first (Dock=Fill claims the whole
            // panel), _cfWebView added second so it sits above it in
            // z-order once ShowCfPane calls BringToFront - its own Bounds
            // (set by ApplyCfRect) are what actually position it; Dock is
            // deliberately left at its default (None) since it is
            // explicitly, independently positioned by the page.
            _contentPanel.Controls.Add(_furphyWebView);
            _contentPanel.Controls.Add(_cfWebView);

            Controls.Add(_contentPanel);
        }

        private void NavigateCf(string url)
        {
            if (_cfWebView.CoreWebView2 != null)
            {
                _cfWebView.CoreWebView2.Navigate(url);
            }
            else
            {
                _cfWebView.Source = new Uri(url);
            }
        }

        // --------------------------------------------------- lifecycle

        private void MainForm_Load(object sender, EventArgs e)
        {
            LogHost("starting, port=" + _port.ToString(CultureInfo.InvariantCulture) +
                " selftest=" + _options.SelftestActive.ToString());

            _furphyWebView.CoreWebView2InitializationCompleted +=
                new EventHandler<CoreWebView2InitializationCompletedEventArgs>(FurphyWebView_InitCompleted);
            _cfWebView.CoreWebView2InitializationCompleted +=
                new EventHandler<CoreWebView2InitializationCompletedEventArgs>(CfWebView_InitCompleted);

            try
            {
                // Round 15 (E20): --selftest's host\selftest.html now loads
                // AS the Furphy webview's own page, replacing the real
                // server-hosted SPA for the duration of the test - it is
                // exercising the page->host messages (hello/theme/cf-show/
                // cf-rect/cf-hide/cf-nav) that contract E says are ONLY
                // ever honored from that webview, so it has to actually be
                // that webview's content to reach HostWebView_WebMessageReceived
                // at all (see that method's own comment). In production
                // this is the real app, with --view/--tab (G) appended
                // when given.
                if (_options.SelftestActive)
                {
                    _furphyWebView.Source = new Uri(_options.SelftestTestPageUrl);
                }
                else
                {
                    string furphyUrl = "http://localhost:" + _port.ToString(CultureInfo.InvariantCulture) + "/?host=webview2";
                    if (!string.IsNullOrEmpty(_options.View))
                    {
                        furphyUrl += "&view=" + Uri.EscapeDataString(_options.View);
                    }
                    if (!string.IsNullOrEmpty(_options.Tab))
                    {
                        furphyUrl += "&tab=" + Uri.EscapeDataString(_options.Tab);
                    }
                    _furphyWebView.Source = new Uri(furphyUrl);
                }

                // The CF pane (contract A) starts with no page at all - it
                // is navigated/shown entirely by cf-show/cf-nav messages
                // from the Furphy webview, never pre-navigated here. Kick
                // off its CoreWebView2 initialization now (rather than
                // waiting for the first such message) so
                // CfWebView_InitCompleted's ad-filter/interception wiring
                // is already in place the first time the player switches
                // to the CurseForge segment.
                System.Threading.Tasks.Task cfInitTask = _cfWebView.EnsureCoreWebView2Async(null);
                GC.KeepAlive(cfInitTask);
            }
            catch (Exception ex)
            {
                HandleRuntimeMissing(ex);
                return;
            }

            if (_options.SelftestActive)
            {
                _selftestTimer = new System.Windows.Forms.Timer();
                _selftestTimer.Interval = 8000;
                _selftestTimer.Tick += new EventHandler(SelftestTimer_Tick);
                _selftestTimer.Start();

                // capturePath's screenshot (WriteSelftestMarker) is taken
                // ~1s before the marker is written, while the pane is
                // visible - by 7s in, selftest.html's own timeline (hello/
                // theme/cf-show around t=1s, cf-nav+cf-hide at t~3s,
                // cf-show again shortly after) has already left the pane
                // visible again.
                _selftestCaptureTimer = new System.Windows.Forms.Timer();
                _selftestCaptureTimer.Interval = 7000;
                _selftestCaptureTimer.Tick += new EventHandler(SelftestCaptureTimer_Tick);
                _selftestCaptureTimer.Start();
            }
        }

        private void MainForm_FormClosing(object sender, FormClosingEventArgs e)
        {
            SaveWindowBounds();
        }

        private void FurphyWebView_InitCompleted(object sender, CoreWebView2InitializationCompletedEventArgs e)
        {
            if (!e.IsSuccess)
            {
                HandleRuntimeMissing(e.InitializationException);
                return;
            }
            _furphyReady = true;
            CaptureVersionIfNeeded();

            // Contract E: the app SPA (always loaded here, except during
            // --selftest when host\selftest.html loads here instead - see
            // MainForm_Load) posts hello/theme/open-curseforge/cf-show/
            // cf-rect/cf-hide/cf-nav messages via
            // window.chrome.webview.postMessage; see
            // HostWebView_WebMessageReceived. This is the ONLY webview
            // that handler is ever wired to.
            _furphyWebView.CoreWebView2.WebMessageReceived +=
                new EventHandler<CoreWebView2WebMessageReceivedEventArgs>(HostWebView_WebMessageReceived);

            // Contract F: sent once the moment this webview is ready, and
            // again on every page-sent {type:"hello"} (handled inline in
            // HostWebView_WebMessageReceived above).
            SendHostReady();
        }

        private void CfWebView_InitCompleted(object sender, CoreWebView2InitializationCompletedEventArgs e)
        {
            if (!e.IsSuccess)
            {
                HandleRuntimeMissing(e.InitializationException);
                return;
            }
            _cfReady = true;
            CaptureVersionIfNeeded();

            _adFilterHosts = HostFiles.LoadHostList(_adFilterListPath);
            _adFilterEnabled = ReadAdFilterSetting();

            _cfWebView.CoreWebView2.NavigationStarting +=
                new EventHandler<CoreWebView2NavigationStartingEventArgs>(CfWebView_NavigationStarting);
            _cfWebView.CoreWebView2.NavigationCompleted +=
                new EventHandler<CoreWebView2NavigationCompletedEventArgs>(CfWebView_NavigationCompleted);
            _cfWebView.CoreWebView2.HistoryChanged +=
                new EventHandler<object>(CfWebView_HistoryChanged);
            _cfWebView.CoreWebView2.DocumentTitleChanged +=
                new EventHandler<object>(CfWebView_DocumentTitleChanged);
            _cfWebView.CoreWebView2.NewWindowRequested +=
                new EventHandler<CoreWebView2NewWindowRequestedEventArgs>(CfWebView_NewWindowRequested);
            _cfWebView.CoreWebView2.WebResourceRequested +=
                new EventHandler<CoreWebView2WebResourceRequestedEventArgs>(CfWebView_WebResourceRequested);
            // Deliberately NOT wired here (adversarial-review precedent,
            // see HostWebView_WebMessageReceived's own comment): _cfWebView
            // loads live, untrusted curseforge.com pages in production and,
            // via CfWebView_NewWindowRequested's catch-all (NavigateCf(uri)
            // for anything that is not a curseforge:// link or an install
            // link), can be navigated to essentially any URL a page on
            // curseforge.com links to. An untrusted page there must not be
            // able to drive host chrome, theme, or the CF pane's own
            // position/navigation via postMessage.

            EnsureAdFilterInfra();

            if (_options.SelftestActive)
            {
                EnsureSelftestDeepLinkInjection();
            }
        }

        // Selftest-only (never registered outside --selftest): the
        // Round-15 CF pane is navigated by the page's own cf-show/cf-nav
        // messages instead of by curseforge:// or /install/<fileId>
        // links directly, so nothing exercises
        // CfWebView_NavigationStarting's interception path
        // (HandleCurseforgeProtocol/HandleSlugInstall -> POST /api/jobs)
        // during a --selftest run any more. This injects a tiny script
        // into whatever document the CF pane loads (mirroring
        // EnsureAdFilterInfra's ad-hiding CSS injection above) that
        // fires a test curseforge:// deep link a couple of seconds after
        // that document is created - the navigation gets cancelled by
        // CfWebView_NavigationStarting exactly like a real "Install"
        // click's would, so the marker's `intercepted`/`jobPostStatus`
        // fields end up populated by a live run of this same
        // interception code, not by a special-cased test path.
        private void EnsureSelftestDeepLinkInjection()
        {
            if (_cfSelftestDeepLinkInjected) return;
            if (_cfWebView.CoreWebView2 == null) return;
            try
            {
                string script =
                    "(function(){try{setTimeout(function(){try{" +
                    "location.href='curseforge://install?addonId=999999001&fileId=999999002';" +
                    "}catch(e){}}, 2000);}catch(e){}})();";
                System.Threading.Tasks.Task<string> scriptTask =
                    _cfWebView.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(script);
                GC.KeepAlive(scriptTask);
                _cfSelftestDeepLinkInjected = true;
                LogHost("selftest deep-link injection registered");
            }
            catch (Exception ex)
            {
                LogHost("selftest deep-link injection failed: " + ex.Message);
            }
        }

        private void CfWebView_NavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            _cfLoading = false;
            SendCfState();
        }

        private void CfWebView_HistoryChanged(object sender, object e)
        {
            SendCfState();
        }

        private void CfWebView_DocumentTitleChanged(object sender, object e)
        {
            SendCfState();
        }

        private void CaptureVersionIfNeeded()
        {
            if (_webviewVersion != null) return;
            try
            {
                _webviewVersion = CoreWebView2Environment.GetAvailableBrowserVersionString();
            }
            catch { }
        }

        private void HandleRuntimeMissing(Exception ex)
        {
            LogHost("WebView2 runtime unavailable: " + (ex == null ? "(unknown)" : ex.Message));
            ExitCode = 3;
            if (_options.SelftestActive && !_selftestMarkerWritten)
            {
                WriteSelftestMarker(false);
            }
            if (!IsDisposed)
            {
                BeginInvoke(new MethodInvoker(delegate { Close(); }));
            }
        }

        // ---------------------------------------------- CF interception

        private void CfWebView_NavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs e)
        {
            string uri = e.Uri;
            if (string.IsNullOrEmpty(uri)) return;

            // Re-read the toggle on every navigation start, per spec. The
            // web-resource observer is registered unconditionally (see
            // EnsureAdFilterInfra) so telemetry/allowedRequests keeps
            // working even while the filter itself is off; only the CSS
            // ad-hiding injection is gated on the toggle.
            _adFilterEnabled = ReadAdFilterSetting();
            EnsureAdFilterInfra();

            if (uri.StartsWith("curseforge://", StringComparison.OrdinalIgnoreCase))
            {
                e.Cancel = true;
                HandleCurseforgeProtocol(uri);
                return;
            }

            string slug, fileId;
            if (TryParseInstallLink(uri, out slug, out fileId))
            {
                e.Cancel = true;
                HandleSlugInstall(uri, slug, fileId);
                return;
            }

            // A real navigation the CF pane will actually perform (not
            // cancelled above) - report it per contract F ("loading true");
            // CfWebView_NavigationCompleted flips it back to false.
            _cfLoading = true;
            SendCfState();
        }

        private void CfWebView_NewWindowRequested(object sender, CoreWebView2NewWindowRequestedEventArgs e)
        {
            string uri = e.Uri;
            if (string.IsNullOrEmpty(uri))
            {
                return;
            }
            if (uri.StartsWith("curseforge://", StringComparison.OrdinalIgnoreCase))
            {
                e.Handled = true;
                HandleCurseforgeProtocol(uri);
                return;
            }
            string slug, fileId;
            if (TryParseInstallLink(uri, out slug, out fileId))
            {
                e.Handled = true;
                HandleSlugInstall(uri, slug, fileId);
                return;
            }
            // Anything else that would have opened a separate popup window
            // is instead loaded in the same CurseForge tab, keeping this a
            // single-window app.
            e.Handled = true;
            NavigateCf(uri);
        }

        private static readonly Regex InstallLinkRegex = new Regex(
            "^https://www\\.curseforge\\.com/wow/addons/([a-zA-Z0-9\\-_]+)/install/([0-9]+)",
            RegexOptions.IgnoreCase);

        private static bool TryParseInstallLink(string uri, out string slug, out string fileId)
        {
            slug = null;
            fileId = null;
            Match m = InstallLinkRegex.Match(uri);
            if (!m.Success) return false;
            slug = m.Groups[1].Value;
            fileId = m.Groups[2].Value;
            return true;
        }

        private static string ExtractParam(string uri, string namePattern)
        {
            Regex r = new Regex("[?&](?:" + namePattern + ")=([0-9]+)", RegexOptions.IgnoreCase);
            Match m = r.Match(uri);
            if (m.Success) return m.Groups[1].Value;
            return null;
        }

        private void HandleCurseforgeProtocol(string uri)
        {
            LogHost("intercepted: " + uri);
            _selftestIntercepted.Add(uri);

            string projectId = ExtractParam(uri, "addonId|projectId");
            string fileId = ExtractParam(uri, "fileId");
            if (string.IsNullOrEmpty(projectId))
            {
                LogHost("no addon id found in " + uri);
                return;
            }

            bool tracked = IsProjectTracked(projectId);

            if (tracked && string.IsNullOrEmpty(fileId))
            {
                LogHost("projectId " + projectId + " already tracked, no fileId - nothing to do");
                return;
            }

            Dictionary<string, object> body = new Dictionary<string, object>();
            body["kind"] = tracked ? "install" : "add";
            body["projectId"] = ParseLongOrZero(projectId);
            if (!string.IsNullOrEmpty(fileId))
            {
                body["fileId"] = ParseLongOrZero(fileId);
            }

            string json = MiniJson.Write(body);
            HttpResult result = Http.PostJson(BaseUrl() + "/api/jobs", json, 4000);
            _selftestJobPostStatus = result.StatusCode;
            LogHost("POST /api/jobs " + json + " -> " + result.StatusCode.ToString(CultureInfo.InvariantCulture));

            // Contract F: push the new job id to the SPA immediately
            // (instead of it waiting for the next poll) so it can open its
            // job panel right away - it renders inline over the CF pane's
            // own placeholder while this segment is active, per contract C.
            // Guarded on a real 2xx success (matching HandleSlugInstall
            // below) rather than relying on the incidental fact that
            // addon-server.ps1's error bodies happen to omit jobId.
            if (!result.NetworkError && result.StatusCode >= 200 && result.StatusCode < 300)
            {
                PostJobIdIfAny(result);
            }
        }

        private void HandleSlugInstall(string uri, string slug, string fileId)
        {
            LogHost("intercepted install link: " + uri);
            _selftestIntercepted.Add(uri);

            Dictionary<string, object> body = new Dictionary<string, object>();
            body["kind"] = "add-by-slug";
            body["slug"] = slug;
            body["fileId"] = ParseLongOrZero(fileId);

            string json = MiniJson.Write(body);
            HttpResult result = Http.PostJson(BaseUrl() + "/api/jobs", json, 4000);
            _selftestJobPostStatus = result.StatusCode;
            LogHost("POST /api/jobs " + json + " -> " + result.StatusCode.ToString(CultureInfo.InvariantCulture));

            if (!result.NetworkError && result.StatusCode >= 200 && result.StatusCode < 300)
            {
                // Contract F: push the new job id to the SPA immediately -
                // see HandleCurseforgeProtocol's own comment.
                PostJobIdIfAny(result);
            }
            else
            {
                // The server does not (yet) understand add-by-slug, or the
                // request failed outright - fall back to the plain addon
                // page instead of leaving the user on a cancelled
                // navigation with nothing happening.
                LogHost("add-by-slug not accepted, falling back to addon page for " + slug);
                NavigateCf("https://www.curseforge.com/wow/addons/" + slug);
            }
        }

        // Parses {jobId} out of a successful POST /api/jobs response body
        // and forwards it as {type:"cf-job", jobId, status:"running"}
        // (contract F) - addon-server.ps1's jobs are created directly in
        // the "running" state (Handle-JobsPost's Start-Job, no separate
        // "queued" state exists server-side), so that is always accurate
        // for a job this call just successfully created.
        private void PostJobIdIfAny(HttpResult result)
        {
            if (result == null || result.NetworkError || string.IsNullOrEmpty(result.Body)) return;
            try
            {
                Dictionary<string, object> body = MiniJson.Parse(result.Body) as Dictionary<string, object>;
                if (body == null) return;
                object jobIdObj;
                string jobId = body.TryGetValue("jobId", out jobIdObj) ? Convert.ToString(jobIdObj, CultureInfo.InvariantCulture) : null;
                if (string.IsNullOrEmpty(jobId)) return;
                SendCfJob(jobId, "running");
            }
            catch (Exception ex)
            {
                LogHost("PostJobIdIfAny failed to parse /api/jobs response: " + ex.Message);
            }
        }

        private static long ParseLongOrZero(string s)
        {
            long v;
            if (long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) return v;
            return 0;
        }

        private bool IsProjectTracked(string projectId)
        {
            try
            {
                string bodyText = Http.GetString(BaseUrl() + "/api/state", 3000);
                if (bodyText == null) return false;
                Dictionary<string, object> root = MiniJson.Parse(bodyText) as Dictionary<string, object>;
                if (root == null) return false;
                object addonsObj;
                if (!root.TryGetValue("addons", out addonsObj)) return false;
                List<object> addons = addonsObj as List<object>;
                if (addons == null) return false;
                foreach (object item in addons)
                {
                    Dictionary<string, object> rec = item as Dictionary<string, object>;
                    if (rec == null) continue;
                    object pidObj;
                    if (rec.TryGetValue("projectId", out pidObj) && pidObj != null)
                    {
                        if (NumericEquals(pidObj, projectId)) return true;
                    }
                }
            }
            catch { }
            return false;
        }

        private static bool NumericEquals(object jsonNumber, string other)
        {
            double a, b;
            string sa = Convert.ToString(jsonNumber, CultureInfo.InvariantCulture);
            if (!double.TryParse(sa, NumberStyles.Float, CultureInfo.InvariantCulture, out a)) return false;
            if (!double.TryParse(other, NumberStyles.Float, CultureInfo.InvariantCulture, out b)) return false;
            return Math.Abs(a - b) < 0.5;
        }

        private string BaseUrl()
        {
            return "http://localhost:" + _port.ToString(CultureInfo.InvariantCulture);
        }

        // ------------------------------------------------------ ad filter

        // Registers the WebResourceRequested observer unconditionally (not
        // gated on _adFilterEnabled) - WebView2 only raises that event for
        // requests matching a registered filter, so if registration were
        // itself gated on the toggle, CfWebView_WebResourceRequested would
        // never fire at all while the filter is off, leaving zero telemetry
        // signal that requests were seen and passed through untouched (as
        // opposed to simply "not blocked"). The toggle instead gates only
        // (a) the CSS ad-hiding injection below, and (b) the actual
        // block/204 decision inside CfWebView_WebResourceRequested.
        private void EnsureAdFilterInfra()
        {
            if (_cfWebView.CoreWebView2 == null) return;

            if (!_cfFilterInfraRegistered)
            {
                try
                {
                    _cfWebView.CoreWebView2.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
                    _cfFilterInfraRegistered = true;
                    LogHost("web resource observer registered");
                }
                catch (Exception ex)
                {
                    LogHost("failed to register web resource filter: " + ex.Message);
                }
            }

            if (_adFilterEnabled && !_cfAdCssInjected)
            {
                try
                {
                    string css =
                        "(function(){try{var s=document.createElement('style');" +
                        "s.textContent='[class*=\"adsbygoogle\"],[id*=\"adsbygoogle\"],[data-ad-slot]{" +
                        "display:none !important;visibility:hidden !important;}';" +
                        "(document.head||document.documentElement).appendChild(s);}catch(e){}})();";
                    System.Threading.Tasks.Task<string> scriptTask =
                        _cfWebView.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(css);
                    GC.KeepAlive(scriptTask);
                    _cfAdCssInjected = true;
                    LogHost("ad filter CSS injection registered");
                }
                catch (Exception ex)
                {
                    LogHost("failed to register ad filter CSS: " + ex.Message);
                }
            }
        }

        private void CfWebView_WebResourceRequested(object sender, CoreWebView2WebResourceRequestedEventArgs e)
        {
            string host = GetHost(e.Request.Uri);
            if (host == null) return;

            if (_adFilterEnabled && !IsAllowlisted(host) && MatchesFilterList(host))
            {
                RecordBlocked(host);
                try
                {
                    e.Response = _cfWebView.CoreWebView2.Environment.CreateWebResourceResponse(
                        null, 204, "No Content", "");
                }
                catch { }
                return;
            }
            RecordAllowed(host);
        }

        private static string GetHost(string uri)
        {
            try { return new Uri(uri).Host.ToLowerInvariant(); }
            catch { return null; }
        }

        private static bool IsHostOrSubdomain(string host, string domain)
        {
            if (string.IsNullOrEmpty(host)) return false;
            if (string.Equals(host, domain, StringComparison.OrdinalIgnoreCase)) return true;
            return host.EndsWith("." + domain, StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsAllowlisted(string host)
        {
            if (host == "127.0.0.1") return true;
            for (int i = 0; i < HardAllowHosts.Length; i++)
            {
                if (IsHostOrSubdomain(host, HardAllowHosts[i])) return true;
            }
            return false;
        }

        private bool MatchesFilterList(string host)
        {
            if (_adFilterHosts == null) return false;
            for (int i = 0; i < _adFilterHosts.Count; i++)
            {
                if (IsHostOrSubdomain(host, _adFilterHosts[i])) return true;
            }
            return false;
        }

        private void RecordBlocked(string host)
        {
            LogHost("ad filter blocked " + host);
            if (_options.SelftestActive)
            {
                lock (_selftestBlocked)
                {
                    if (!_selftestBlocked.Contains(host)) _selftestBlocked.Add(host);
                }
            }
        }

        private void RecordAllowed(string host)
        {
            if (_options.SelftestActive)
            {
                lock (_selftestAllowed)
                {
                    if (!_selftestAllowed.Contains(host)) _selftestAllowed.Add(host);
                }
            }
        }

        // -------------------------------------------------------- logging

        private readonly object _logLock = new object();

        private void LogHost(string message)
        {
            if (string.IsNullOrEmpty(_hostLogPath)) return;
            try
            {
                lock (_logLock)
                {
                    string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) +
                        "  " + message + Environment.NewLine;
                    File.AppendAllText(_hostLogPath, line, new UTF8Encoding(false));
                }
            }
            catch { }
        }

        // -------------------------------------------------------- selftest

        private void SelftestTimer_Tick(object sender, EventArgs e)
        {
            _selftestTimer.Stop();
            WriteSelftestMarker(true);
            Close();
        }

        // Fires ~1s before the marker is written (see MainForm_Load) -
        // captures a PNG of the host's own on-screen window while the CF
        // pane should still be visible, per the --selftest sequence
        // selftest.html now drives (hello/theme/cf-show, then cf-nav
        // back + cf-hide, then cf-show again - the final cf-show is what
        // is expected to still be showing by the time this fires).
        private void SelftestCaptureTimer_Tick(object sender, EventArgs e)
        {
            _selftestCaptureTimer.Stop();
            CaptureSelftestScreenshot();
        }

        private void CaptureSelftestScreenshot()
        {
            if (string.IsNullOrEmpty(_options.SelftestMarkerPath)) return;
            try
            {
                string dir = Path.GetDirectoryName(_options.SelftestMarkerPath);
                string baseName = Path.GetFileNameWithoutExtension(_options.SelftestMarkerPath);
                string path = Path.Combine(string.IsNullOrEmpty(dir) ? "." : dir, baseName + ".png");

                // Bounds is already screen-relative for a top-level Form -
                // this captures the whole on-screen window (title bar
                // included), per spec ("Graphics.CopyFromScreen of the
                // form's screen rectangle").
                Rectangle formRect = Bounds;
                if (formRect.Width <= 0 || formRect.Height <= 0) return;

                // CopyFromScreen grabs whatever is actually composited at
                // those screen pixels, regardless of which window logically
                // owns them - force this window to the top of the z-order
                // first so the capture is actually evidence of what this
                // window shows (otherwise an unrelated foreground window
                // covering the same screen rectangle gets captured instead).
                bool wasTopMost = TopMost;
                TopMost = true;
                Activate();
                BringToFront();
                Application.DoEvents();

                using (Bitmap bmp = new Bitmap(formRect.Width, formRect.Height))
                {
                    using (Graphics g = Graphics.FromImage(bmp))
                    {
                        g.CopyFromScreen(formRect.Location, Point.Empty, formRect.Size);
                    }
                    bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
                }

                TopMost = wasTopMost;

                _selftestCapturePath = path;
                LogHost("selftest capture written: " + path);
            }
            catch (Exception ex)
            {
                LogHost("selftest capture failed: " + ex.Message);
            }
        }

        private void WriteSelftestMarker(bool initSucceeded)
        {
            if (_selftestMarkerWritten) return;
            _selftestMarkerWritten = true;

            // Belt-and-suspenders: normally SelftestCaptureTimer_Tick has
            // already run by the time this fires (7s vs. 8s - see
            // MainForm_Load), but if the marker is being written early
            // (e.g. WriteSelftestMarker(false) from HandleRuntimeMissing)
            // take the screenshot now instead of shipping capturePath=null.
            if (_selftestCapturePath == null && _options.SelftestActive)
            {
                CaptureSelftestScreenshot();
            }

            Dictionary<string, object> marker = new Dictionary<string, object>();
            marker["init"] = initSucceeded && _furphyReady && _cfReady;
            marker["version"] = _webviewVersion;
            marker["dpi"] = (long)_effectiveDpi;
            marker["dpiAware"] = _dpiAware;

            marker["themeMessages"] = (long)_selftestThemeMessageCount;
            marker["themeBg0"] = ColorToHex(ChromeBg);
            marker["captionHresult"] = (long)_lastCaptionHresult;
            marker["darkModeHresult"] = (long)_lastDarkModeHresult;
            marker["openCurseforgeUrl"] = _selftestOpenCurseforgeUrl;

            // Round 15 (E20 - embedded CurseForge pane) additions.
            marker["hostReadySent"] = _hostReadySent;
            marker["cfShowCount"] = (long)_cfShowCount;
            marker["cfHideCount"] = (long)_cfHideCount;
            marker["cfPaneVisible"] = _cfWebView != null && _cfWebView.Visible;
            Dictionary<string, object> bounds = new Dictionary<string, object>();
            bounds["x"] = (long)_cfPaneBoundsDevicePx.X;
            bounds["y"] = (long)_cfPaneBoundsDevicePx.Y;
            bounds["w"] = (long)_cfPaneBoundsDevicePx.Width;
            bounds["h"] = (long)_cfPaneBoundsDevicePx.Height;
            marker["cfPaneBounds"] = bounds;
            marker["cfStateMessages"] = (long)_cfStateMessageCount;
            marker["cfLastUrl"] = _cfLastUrl;
            marker["capturePath"] = _selftestCapturePath;

            List<string> blockedCopy;
            List<string> allowedCopy;
            lock (_selftestBlocked) { blockedCopy = new List<string>(_selftestBlocked); }
            lock (_selftestAllowed) { allowedCopy = new List<string>(_selftestAllowed); }
            marker["blockedRequests"] = blockedCopy;
            marker["allowedRequests"] = allowedCopy;
            marker["intercepted"] = new List<string>(_selftestIntercepted);
            marker["jobPostStatus"] = _selftestJobPostStatus.HasValue ? (object)(long)_selftestJobPostStatus.Value : null;

            try
            {
                string json = MiniJson.Write(marker);
                string tmpPath = _options.SelftestMarkerPath + ".tmp";
                File.WriteAllText(tmpPath, json, new UTF8Encoding(false));
                if (File.Exists(_options.SelftestMarkerPath))
                {
                    try { File.Delete(_options.SelftestMarkerPath); } catch { }
                }
                File.Move(tmpPath, _options.SelftestMarkerPath);
                LogHost("selftest marker written: " + _options.SelftestMarkerPath);
            }
            catch (Exception ex)
            {
                LogHost("failed to write selftest marker: " + ex.Message);
            }
        }
    }
}
