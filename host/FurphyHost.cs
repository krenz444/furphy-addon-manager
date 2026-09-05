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
using Microsoft.Win32;

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

            // Auto-updater tray mode (E24): --tray runs silently with no
            // main window, just a NotifyIcon; --tray-selftest runs one
            // cycle and writes a marker like the existing --selftest does
            // for the main window. Routed here, before MainForm is ever
            // touched, so the normal window path below is unaffected.
            if (options.Tray || options.TraySelftestActive)
            {
                return TrayProgram.Run(options, dpiAware);
            }

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

        // Auto-updater tray mode (E24). --tray: run headless with just a
        // NotifyIcon (TrayProgram.Run), never MainForm. --tray-selftest
        // <markerPath>: like --selftest but for the tray - runs one cycle
        // then writes a JSON marker and exits. --wow-fake <processName>
        // lets --tray-selftest prove the WoW-running skip without the
        // real game by treating a process of that name as WoW.
        public bool Tray;
        public bool TraySelftestActive;
        public string TraySelftestMarkerPath;
        public string WowFakeProcessName;

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
                else if (string.Equals(a, "--tray", StringComparison.OrdinalIgnoreCase))
                {
                    o.Tray = true;
                }
                else if (string.Equals(a, "--tray-selftest", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    o.TraySelftestActive = true;
                    o.TraySelftestMarkerPath = args[i + 1];
                    i++;
                }
                else if (string.Equals(a, "--wow-fake", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    o.WowFakeProcessName = args[i + 1];
                    i++;
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
    // App-wide constants shared between MainForm and the tray classes
    // below (E24) - kept in one place so the window title the tray looks
    // for via FindWindow can never drift from the one MainForm sets.
    // ------------------------------------------------------------------
    internal static class AppConstants
    {
        public const string WindowTitle = "Furphy Addon Manager";
    }

    // ------------------------------------------------------------------
    // Small JSON-value coercion helpers, shared by MainForm (whose own
    // ToInt/ToBool/ToDouble/DictGet below delegate here - see those
    // methods) and the tray classes (E24), which read the same
    // settings.json via HostFiles.LoadJsonObject but live outside
    // MainForm.
    // ------------------------------------------------------------------
    internal static class JsonUtil
    {
        public static int ToInt(object o, int fallback)
        {
            if (o is long) return (int)(long)o;
            if (o is int) return (int)o;
            if (o is double) return (int)(double)o;
            int parsed;
            if (o is string && int.TryParse((string)o, out parsed)) return parsed;
            return fallback;
        }

        public static bool ToBool(object o, bool fallback)
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

        public static double ToDouble(object o, double fallback)
        {
            if (o is double) return (double)o;
            if (o is long) return (long)o;
            if (o is int) return (int)o;
            double parsed;
            if (o is string && double.TryParse((string)o, NumberStyles.Float, CultureInfo.InvariantCulture, out parsed)) return parsed;
            return fallback;
        }

        public static object DictGet(Dictionary<string, object> d, string key)
        {
            object v;
            return (d != null && d.TryGetValue(key, out v)) ? v : null;
        }
    }

    // ------------------------------------------------------------------
    // host.log appender. MainForm.LogHost (instance method, tied to
    // _hostLogPath) delegates here; the tray classes (E24) - which run
    // with no MainForm at all in --tray/--tray-selftest - call this
    // directly with their own resolved log path so every "[tray] ..."
    // line lands in the same host.log a user would already look at.
    // ------------------------------------------------------------------
    internal static class LogWriter
    {
        private static readonly object _lock = new object();

        public static void Append(string path, string message)
        {
            if (string.IsNullOrEmpty(path)) return;
            try
            {
                lock (_lock)
                {
                    string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) +
                        "  " + message + Environment.NewLine;
                    File.AppendAllText(path, line, new UTF8Encoding(false));
                }
            }
            catch { }
        }
    }

    // ------------------------------------------------------------------
    // Port resolution: command-line --port wins, else settings.json's
    // "port", else the default. MainForm.ResolvePort (instance method)
    // delegates here; the tray classes (E24) call it directly since they
    // have no MainForm.
    // ------------------------------------------------------------------
    internal static class PortResolver
    {
        public static int Resolve(HostOptions options, string settingsPath)
        {
            if (options.Port > 0) return options.Port;
            Dictionary<string, object> settings = HostFiles.LoadJsonObject(settingsPath);
            object portObj;
            if (settings.TryGetValue("port", out portObj) && portObj != null)
            {
                int p = JsonUtil.ToInt(portObj, 0);
                if (p > 0) return p;
            }
            return 47831;
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
                // Round 20 (adversarial bug pass, security-2): addon-server.ps1
                // now rejects any state-changing request whose Origin/Referer
                // does not resolve to its own http://localhost:<port> origin
                // (a CSRF guard - see Test-SameOriginRequest). This direct
                // HttpWebRequest call (used by the tray to POST /api/jobs)
                // never carried either header the way a browser fetch() does,
                // so it would otherwise be rejected as a foreign origin -
                // Referer is a trusted, dedicated HttpWebRequest property, so
                // set it to this same request's own URL to satisfy that check.
                req.Referer = url;
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
        private const string WindowTitle = AppConstants.WindowTitle;
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

        // Chrome colors track the app's CURRENT theme (any of the SPA's
        // theme picker entries - Vaporwave, Lofi Night, Dark, Light, etc.)
        // instead of a hard-coded palette - see ROADMAP.md "E19"/"theme
        // sync". Instance (not static readonly) fields so ApplyTheme(name,
        // colors) can repaint them live from a "theme" WebMessage posted
        // by the page; InitializeDefaultTheme seeds them with Vaporwave
        // (the app's current default theme, round 12/18) before
        // LoadPersistedTheme overlays any settings.json hostTheme.
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

        // Round 16 (E22 - CurseForge focus view): _cfFocusScriptRegistered
        // guards the ONE-TIME AddScriptToExecuteOnDocumentCreatedAsync
        // registration (EnsureCfFocusInfra), mirroring _cfAdCssInjected's
        // pattern above. _cfFocusEnabled is the host's current view of the
        // setting - seeded from settings.json (ReadCfFocusSetting, like
        // _adFilterEnabled/ReadAdFilterSetting) and kept live by both an
        // in-app toggle (HandleCfFocusMessage) and a re-read on every CF
        // navigation start (CfWebView_NavigationStarting, same spot the ad
        // filter re-reads its own setting) in case it changed out-of-band
        // (e.g. the plain-browser-tab Settings page, which has no host to
        // message).
        private bool _cfFocusScriptRegistered;
        private bool _cfFocusEnabled;

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

            // Seed the chrome palette with Vaporwave, then overlay any
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

        // Round 20 fix (host-2): per-monitor-v2 awareness is declared
        // (DpiAwareness.TryEnable) but nothing in this file ever handled
        // WM_DPICHANGED, and there is no app.config opting into
        // EnableWindowsFormsHighDpiAutoResizing, so WinForms never resized
        // this window's physical bounds when it was dragged to a monitor
        // with a different DPI - it kept its old pixel size instead of the
        // OS-suggested one for the new monitor. Per Microsoft's documented
        // per-monitor-v2 handling, WM_DPICHANGED's lParam carries the
        // suggested new window rect; applying it here is the standard fix.
        // Deliberately NOT touched: CoreWebView2Controller.RasterizationScale
        // for either webview - both default to
        // ShouldDetectMonitorScaleChanges=true (see
        // Microsoft.Web.WebView2.Core.xml), so the runtime already retargets
        // its own rendering scale to the new monitor DPI on its own; setting
        // it manually here would fight that default instead of complementing
        // it. Resizing the window (below) changes _contentPanel's
        // (Dock=Fill) client size, which the SPA's existing
        // ResizeObserver/'resize' listeners (ui/app.js ensureCfObservers)
        // pick up exactly like any other resize and answer with a fresh
        // cf-rect/cf-show carrying the new devicePixelRatio - so
        // _cfWebView.Bounds re-syncs through the same page-driven ApplyCfRect
        // path already used everywhere else, no new host->page channel
        // needed.
        private const int WM_DPICHANGED = 0x02E0;

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT
        {
            public int left;
            public int top;
            public int right;
            public int bottom;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_DPICHANGED)
            {
                try
                {
                    int newDpi = m.WParam.ToInt32() & 0xFFFF;
                    RECT suggested = (RECT)Marshal.PtrToStructure(m.LParam, typeof(RECT));
                    _effectiveDpi = newDpi;
                    LogHost("WM_DPICHANGED: dpi=" + newDpi.ToString(CultureInfo.InvariantCulture) +
                        " suggested=" + suggested.left.ToString(CultureInfo.InvariantCulture) +
                        "," + suggested.top.ToString(CultureInfo.InvariantCulture) +
                        " " + (suggested.right - suggested.left).ToString(CultureInfo.InvariantCulture) +
                        "x" + (suggested.bottom - suggested.top).ToString(CultureInfo.InvariantCulture));
                    SetBounds(suggested.left, suggested.top,
                        suggested.right - suggested.left, suggested.bottom - suggested.top);
                }
                catch (Exception ex)
                {
                    LogHost("WM_DPICHANGED handling failed: " + ex.Message);
                }
            }
            base.WndProc(ref m);
        }

        // -------------------------------------------------------- setup

        private int ResolvePort()
        {
            return PortResolver.Resolve(_options, _settingsPath);
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
            return JsonUtil.ToInt(o, fallback);
        }

        private static bool ToBool(object o, bool fallback)
        {
            return JsonUtil.ToBool(o, fallback);
        }

        // Used for cf-show/cf-rect's rect{x,y,w,h}/dpr fields, which the
        // page sends as JSON numbers (MiniJson parses them as double or
        // long depending on whether a decimal point was present).
        private static double ToDouble(object o, double fallback)
        {
            return JsonUtil.ToDouble(o, fallback);
        }

        private static object DictGet(Dictionary<string, object> d, string key)
        {
            return JsonUtil.DictGet(d, key);
        }

        private bool ReadAdFilterSetting()
        {
            Dictionary<string, object> settings = HostFiles.LoadJsonObject(_settingsPath);
            object v;
            if (settings.TryGetValue("adFilter", out v) && v != null)
            {
                return ToBool(v, true);
            }
            return true;
        }

        // Round 16 (E22): mirrors ReadAdFilterSetting exactly, except the
        // default is TRUE (per spec) when settings.json has no "cfFocus"
        // key yet, rather than false.
        private bool ReadCfFocusSetting()
        {
            Dictionary<string, object> settings = HostFiles.LoadJsonObject(_settingsPath);
            object v;
            if (settings.TryGetValue("cfFocus", out v) && v != null)
            {
                return ToBool(v, true);
            }
            return true;
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

        // Vaporwave - the app's default theme again as of round 12/18
        // (ui/style.css data-theme="vaporwave": --bg-0.. --bg-3, --border,
        // --text, --text-muted, --accent - verbatim from THEMES-SPEC.md
        // section 2's "Vaporwave's 8-color host palette", unmodified from
        // the existing, unmodified Vaporwave token block in style.css).
        // Superseded round 11's flip to Lofi Night as the built-in
        // cold-start default. Overwritten by LoadPersistedTheme
        // (settings.json hostTheme) and, live, by ApplyTheme whenever a
        // "theme" WebMessage arrives (HandleThemeMessage) - an existing
        // user's persisted hostTheme (Lofi Night or otherwise) still wins,
        // this only changes what a brand-new profile paints before the
        // page reports in.
        private void InitializeDefaultTheme()
        {
            ChromeBg = Color.FromArgb(0x12, 0x08, 0x1f);       // --bg-0
            ChromeBgAlt = Color.FromArgb(0x1a, 0x0b, 0x2e);    // --bg-1
            ChromeBgActive = Color.FromArgb(0x24, 0x16, 0x40); // --bg-2
            ChromeHover = Color.FromArgb(0x2d, 0x1b, 0x4e);    // --bg-3
            _chromeBorder = Color.FromArgb(0x3a, 0x2a, 0x5c);  // --border
            ChromeText = Color.FromArgb(0xf3, 0xe9, 0xff);     // --text
            ChromeMuted = Color.FromArgb(0xb9, 0xa6, 0xd6);    // --text-muted
            ChromeAccent = Color.FromArgb(0xff, 0x71, 0xce);   // --accent
            _themeName = "vaporwave";
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
        // Round 16 (E22) adds cf-focus to this same Furphy-webview-only
        // set - the CurseForge focus view toggle is app chrome (a
        // Settings > Advanced row), never something the untrusted CF page
        // itself should be able to flip.
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
                else if (type == "cf-focus")
                {
                    HandleCfFocusMessage(msg);
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
                // theme/cf-show around t=1s, cf-nav+cf-hide at t~5s,
                // cf-show again at t~5.5s) has already left the pane
                // visible again. (Round-22 fix: cf-hide was moved from
                // t~3s to t~5s specifically to stop racing
                // EnsureSelftestDeepLinkInjection's own fire time - see
                // that method's comment.)
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
            _cfFocusEnabled = ReadCfFocusSetting();

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
            EnsureCfFocusInfra();
            SyncCfFocusToPage("init");

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
        // fires a test curseforge:// deep link shortly after that
        // document is created - the navigation gets cancelled by
        // CfWebView_NavigationStarting exactly like a real "Install"
        // click's would, so the marker's `intercepted`/`jobPostStatus`
        // fields end up populated by a live run of this same
        // interception code, not by a special-cased test path.
        //
        // Round-22 fix (T5, was a T3-documented known finding): this used
        // to fire 2000ms after document-created, which landed almost
        // exactly on top of selftest.html's own cf-hide (also ~2000ms
        // after cf-show) - a hidden WebView2 pane's pending page timer
        // never resumed in time, so sawDeepLink was always false.
        // Shortened to 500ms here (document-created follows cf-show by
        // well under a second in every observed run) AND selftest.html's
        // cf-hide was pushed out from t~3s to t~5s, so there is now a
        // multi-second margin on both sides instead of a coincidence.
        private void EnsureSelftestDeepLinkInjection()
        {
            if (_cfSelftestDeepLinkInjected) return;
            if (_cfWebView.CoreWebView2 == null) return;
            try
            {
                string script =
                    "(function(){try{setTimeout(function(){try{" +
                    "location.href='curseforge://install?addonId=999999001&fileId=999999002';" +
                    "}catch(e){}}, 500);}catch(e){}})();";
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
            // Round 18 fix: settings.json is authoritative over the CF
            // pane's own localStorage 'cfFocusEnabled' cache - see
            // SyncCfFocusToPage's comment for why this must run on every
            // completed navigation, not just when the host's own in-memory
            // view of the setting happens to change.
            SyncCfFocusToPage("navigation-completed");
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
            PushAdFilterCssLive(_adFilterEnabled);

            // Round 16 (E22): same re-read-on-every-navigation-start idea
            // as the ad filter above, but cfFocus can also change out from
            // under this navigation without a fresh document ever loading
            // (the setting is normally toggled live via cf-focus messages
            // instead) - this only catches the out-of-band case (settings
            // changed elsewhere while a CF page was already up) and pushes
            // it live via ApplyCfFocusToggle exactly like an in-app toggle
            // would.
            bool freshCfFocus = ReadCfFocusSetting();
            if (freshCfFocus != _cfFocusEnabled)
            {
                ApplyCfFocusToggle(freshCfFocus);
            }

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
                    // Round 20 fix (host-1): mirrors the cf-focus live-toggle
                    // pattern (EnsureCfFocusInfra/PushCfFocusLive above) so
                    // turning the setting off actually stops the CSS from
                    // hiding matching elements, instead of the style staying
                    // unconditionally active forever once ever injected.
                    // The <style> element is still appended on every
                    // document, but its `disabled` state now follows
                    // window.localStorage['adFilterCssEnabled'] (falling
                    // back to the enabled state baked in at first
                    // registration), and PushAdFilterCssLive keeps that
                    // localStorage value - and the currently loaded page's
                    // style, via window.__adFilterCssSetEnabled - in sync
                    // with settings.json on every navigation start.
                    string enabledLiteral = _adFilterEnabled ? "true" : "false";
                    string css =
                        "(function(){try{" +
                        "var ENABLED=" + enabledLiteral + ";" +
                        "function readStored(){try{var v=window.localStorage.getItem('adFilterCssEnabled');" +
                        "if(v==='1'){return true;}if(v==='0'){return false;}}catch(e){}return ENABLED;}" +
                        "ENABLED=readStored();" +
                        "var s=document.createElement('style');" +
                        "s.textContent='[class*=\"adsbygoogle\"],[id*=\"adsbygoogle\"],[data-ad-slot]{" +
                        "display:none !important;visibility:hidden !important;}';" +
                        // s.disabled must be set AFTER appendChild, not before -
                        // setting it on a <style> element before it is connected
                        // to the document does not reliably take effect (no
                        // associated CSSStyleSheet yet to carry the flag),
                        // verified against this WebView2 build's Chromium engine.
                        "(document.head||document.documentElement).appendChild(s);" +
                        "s.disabled=!ENABLED;" +
                        "window.__adFilterCssSetEnabled=function(v){" +
                        "ENABLED=!!v;" +
                        "try{window.localStorage.setItem('adFilterCssEnabled',ENABLED?'1':'0');}catch(e){}" +
                        "s.disabled=!ENABLED;" +
                        "};" +
                        "}catch(e){}})();";
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

        // Fire-and-forget ExecuteScriptAsync (never awaited, same shape as
        // PushCfFocusLive below): pushes the current _adFilterEnabled value
        // into the CF pane's own localStorage (picked up by the NEXT
        // document-created run of the script above) and, if a document has
        // already booted the script, flips its live style element via the
        // exposed window.__adFilterCssSetEnabled so an already-open CF page
        // reacts immediately without a reload. No-op if the persistent
        // script was never registered (ad filter never turned on this
        // webview lifetime) - harmless, since there is no CSS to toggle yet.
        private void PushAdFilterCssLive(bool enabled)
        {
            if (_cfWebView.CoreWebView2 == null) return;
            try
            {
                string storeVal = enabled ? "1" : "0";
                string boolVal = enabled ? "true" : "false";
                string script =
                    "(function(){try{window.localStorage.setItem('adFilterCssEnabled','" + storeVal + "');" +
                    "if(window.__adFilterCssSetEnabled){window.__adFilterCssSetEnabled(" + boolVal + ");}}catch(e){}})();";
                System.Threading.Tasks.Task<string> execTask = _cfWebView.CoreWebView2.ExecuteScriptAsync(script);
                GC.KeepAlive(execTask);
            }
            catch (Exception ex)
            {
                LogHost("ad filter CSS live push failed: " + ex.Message);
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

        // -------------------------------------------------------- cf focus

        // Round 16 (E22 - CurseForge focus view). On CurseForge LISTING and
        // SEARCH pages (location.pathname === "/wow/search" - both share
        // the exact same markup, per recon) this hides the promo banner
        // strip, global site header/nav, hero/title block, in-site
        // Discover/Browse-All + search row, and the LEFT FILTER SIDEBAR,
        // then collapses .search-page/.ads-layout from grid to block so
        // the results column (starting at the "1 of 500 / 10,000+
        // Projects / Relevancy" row) fills the freed width. On PROJECT/
        // ADDON pages (pathname starts with "/wow/addons/") only the
        // promo strip/header/nav/footer are hidden - all project content
        // (title, description, tabs, the download/stats panel) stays.
        // Any other URL is left completely untouched apart from the
        // overlay hiding described next.
        //
        // Overlay hiding (Eric, 2026-09-04 follow-up: "get rid of cookie
        // banner, and the other banner that appears on top, and anything
        // else other than the content"): hideOverlaysApply runs on EVERY
        // page kind, including "other" - unlike the listing/project rules
        // above, a consent banner or promo interstitial can appear on any
        // CurseForge URL, not just the two scoped ones. It is VISUAL
        // HIDING ONLY - display:none via CSS/inline style, nothing is
        // clicked, no form is submitted, and no consent cookie or
        // localStorage value is ever written (the only localStorage key
        // this script touches is its own 'cfFocusEnabled'). Two layers,
        // both scoped narrowly so they cannot catch real page content:
        //   (a) OVERLAY_CSS - known widget selectors (#cookiebar/
        //       .cookiebar, OneTrust, Quantcast Choice, Cookiebot,
        //       Usercentrics, Sourcepoint's #sp_message_* pattern, an
        //       "ncmp-banner" pattern matching the "ncmp-consent-link"
        //       footer link actually observed live on curseforge.com in
        //       this round's testing) PLUS a generic body>[id/class*=
        //       cookie|consent|gdpr|onetrust] rule - scoped to DIRECT
        //       CHILDREN OF <body> only, because every consent/interstitial
        //       widget this codebase has ever observed on this site (both
        //       this round and Round 15) injects as a late, top-level
        //       sibling of the app's own root div, never nested inside
        //       .search-page/.project-page/.content - so this cannot
        //       accidentally hide real results/project content even if a
        //       future CurseForge class happened to contain one of these
        //       words deeper in the tree.
        //   (b) scanTextOverlays - a live-DOM text-content heuristic for
        //       whatever CSS doesn't already catch: any position:fixed or
        //       sticky element within two levels of <body> whose visible
        //       text contains "cookie" plus one of consent/policy/"we
        //       use"/"got it" gets display:none set directly (tracked in
        //       overlayHidden[] so ENABLED=false can put it back). This is
        //       the layer that targets the specific bar Eric's screenshot
        //       shows ("We use cookies to improve your experience...
        //       Got it") - candidate elements are limited to <body>'s
        //       children and grandchildren (not a full document scan) for
        //       the same "overlays inject shallow" reasoning as (a), kept
        //       cheap enough to run on every debounced mutation/poll tick.
        // restoreScrollIfNeeded then clears an inline overflow:hidden the
        // widget may have set on <html>/<body> (only inline styles this
        // script itself would find, never anything CurseForge's own CSS
        // sets for unrelated reasons) - the "restore scroll" half of
        // Eric's ask, so a trimmed page never becomes unscrollable because
        // its dismissed banner left a lock behind.
        //
        // VERIFIED LIVE (2026-09-04, this round): against the app's OWN
        // fresh WebView2 profile (host\bin's FurphyHost.exe.WebView2
        // folder deleted first, to rule out an already-answered consent
        // cookie from an earlier test run), the CF pane's real DOM
        // produced <div id="cookiebar" class="cookiebar"> containing "We
        // use cookies to improve your experience and increase the
        // relevancy of content when using CurseForge. Our coo[kies...]" -
        // an exact match for Eric's screenshot, confirming an earlier
        // recon pass's #cookiebar/.cookiebar finding (position:fixed,
        // z-index 2147483001, direct child of <body>). It rendered late
        // (present by ~4s after navigation, absent at ~2s), which is why
        // a single-shot dump at NavigationCompleted can miss it - this is
        // exactly what the debounced MutationObserver/poll re-application
        // in cfFocusApply's caller chain is for, not a one-time check. Both
        // (a)'s static #cookiebar/.cookiebar rule and (b)'s text heuristic
        // catch it (confirmed via the live data-cf-focus-hidden marker and
        // the element's own id/class/text, captured with a temporary
        // verification probe during this session and removed afterward,
        // matching TempDumpConsentDom's own "recon-only, removed before
        // final compile" convention). Layer (b) stays in place as defense
        // in depth for whatever future CMP swap or A/B variant does not
        // carry that exact id/class.
        //
        // Fail-safe (hard requirement): before hiding anything on a
        // listing/search page, cfFocusApply confirms .search-page exists
        // (else this isn't actually a listing/search page's real shell -
        // "skipped-no-shell") and that .results-container or .options
        // exists with a non-trivial size (else "skipped-no-results" / a
        // literal 0-results search, or "skipped-empty"), checks none of
        // the hide-candidates already CONTAINS the results/options nodes
        // ("skipped-selector-conflict" - a future CurseForge redesign
        // nesting them), and re-measures .search-page .content one frame
        // after enabling the stylesheet, reverting immediately if it is
        // still near-empty ("skipped-post-check-failed"). Any failure
        // leaves the style element's `disabled` at true, i.e. nothing
        // hidden at all - a blank pane is a worse failure than an
        // untrimmed one. The live state is recorded on the injected
        // <style data-cf-focus="1"> element as data-cf-focus-state (one
        // of: applied, disabled, skipped-no-shell, skipped-no-results,
        // skipped-selector-conflict, skipped-empty,
        // skipped-post-check-failed, error) and data-cf-focus-checked-at
        // (epoch ms), queryable via ExecuteScriptAsync for verification.
        //
        // Self-healing across CurseForge's own client-side routing
        // (pagination/sort/search are React re-renders, not full
        // navigations): a MutationObserver on document.body (150ms
        // trailing debounce) plus wrapped history.pushState/replaceState
        // and a popstate listener re-run cfFocusApply, backed by a
        // bounded 8-tick/400ms fallback poll that stops itself once two
        // consecutive checks agree. Because the hide/collapse rules are
        // CSS selectors (not per-node inline styles), React swapping
        // nodes in/out under an already-hidden ancestor needs no
        // re-application at all - only the guard's PASS/FAIL verdict
        // ever needs re-deciding.
        //
        // Live bidirectional toggle without a reload: this needs to flip
        // on/off instantly while a CurseForge page is already showing (the
        // SPA's Settings > Advanced toggle applies live) - same requirement
        // Round 20 gave EnsureAdFilterInfra's CSS above (PushAdFilterCssLive
        // mirrors PushCfFocusLive below). Re-registering (or removing) the
        // AddScriptToExecuteOnDocumentCreatedAsync registration itself
        // would need its returned Task<string> id, and blocking on that
        // Task's result from this UI thread risks a classic WebView2
        // deadlock (its continuation is marshalled back onto this same
        // thread's message loop) - this codebase has no async/await
        // anywhere (see Http's own comment) specifically to avoid that
        // trap. So the persistent document-created script is registered
        // exactly ONCE per _cfWebView lifetime (EnsureCfFocusInfra, same
        // guarded-once shape as EnsureAdFilterInfra's CSS injection) with
        // a baked-in cold-start default, and on every FUTURE document it
        // creates it instead reads its actual enabled state from
        // window.localStorage['cfFocusEnabled'] (persists per-origin
        // across navigations within the same WebView2 profile).
        // Toggling (ApplyCfFocusToggle/PushCfFocusLive) writes that same
        // localStorage key AND calls the already-loaded page's exposed
        // window.__cfFocusSetEnabled directly via a second, ordinary
        // fire-and-forget ExecuteScriptAsync - both the current page and
        // every future navigation stay in sync, with no Task ever
        // awaited/blocked-on.

        private const string CfFocusScriptPrefix =
@"(function(){
try{
if(window.__cfFocusInit){return;}
window.__cfFocusInit=true;
var ENABLED=";

        private const string CfFocusScriptSuffix =
@";
var VERSION='3';
var HIDE_LISTING=['.top-banner','.curseforge-header','.game-navbar','.game-header','.game-description','.search-filters','.site-footer','.side-container-right','.mobile-sort-overlay','.filter-reflection-bar','.search-tags-and-count','nav.mobile-footer-nav'];
var HIDE_PROJECT=['.top-banner','.curseforge-header','.game-navbar','.game-header','.site-footer','nav.mobile-footer-nav','.shelf','.side-container-left','.side-container-right'];
var OVERLAY_CSS='#cookiebar,.cookiebar,#onetrust-banner-sdk,#onetrust-consent-sdk,.ot-sdk-container,#onetrust-pc-sdk,.qc-cmp2-container,#usercentrics-root,#CybotCookiebotDialog,#CybotCookiebotDialogBodyUnderlay,[id^=sp_message i],[class*=sp_message i],[id*=ncmp-banner i],[class*=ncmp-banner i],body>[id*=cookie i],body>[class*=cookie i],body>[id*=consent i],body>[class*=consent i],body>[id*=gdpr i],body>[class*=gdpr i],body>[id*=onetrust i],body>[class*=onetrust i]{display:none !important;}';
var styleEl=null;
var overlayStyleEl=null;
var overlayHidden=[];
var pending=null;
var fallbackTimer=null;
var applyGen=0;
function readStoredEnabled(){
try{
var v=window.localStorage.getItem('cfFocusEnabled');
if(v==='1'){return true;}
if(v==='0'){return false;}
}catch(e){}
return ENABLED;
}
ENABLED=readStoredEnabled();
function ensureStyleEl(){
if(styleEl&&styleEl.parentNode){return styleEl;}
styleEl=document.createElement('style');
styleEl.setAttribute('data-cf-focus','1');
styleEl.setAttribute('data-cf-focus-version',VERSION);
(document.head||document.documentElement).appendChild(styleEl);
return styleEl;
}
function setState(s){
try{
var el=ensureStyleEl();
el.setAttribute('data-cf-focus-state',s);
el.setAttribute('data-cf-focus-checked-at',String(Date.now()));
}catch(e){}
window.__cfFocusState=s;
}
function ensureOverlayStyleEl(){
if(overlayStyleEl&&overlayStyleEl.parentNode){return overlayStyleEl;}
overlayStyleEl=document.createElement('style');
overlayStyleEl.setAttribute('data-cf-focus-overlay','1');
overlayStyleEl.textContent=OVERLAY_CSS;
(document.head||document.documentElement).appendChild(overlayStyleEl);
return overlayStyleEl;
}
function collectShallowCandidates(){
var out=[];
try{
var kids=document.body?document.body.children:null;
if(!kids){return out;}
var i;var j;
for(i=0;i<kids.length;i++){
out.push(kids[i]);
var gk=kids[i].children;
for(j=0;j<gk.length;j++){out.push(gk[j]);}
}
}catch(e){}
return out;
}
function scanTextOverlays(){
try{
var cands=collectShallowCandidates();
for(var i=0;i<cands.length;i++){
var el=cands[i];
if(!el||(el.getAttribute&&el.getAttribute('data-cf-focus-hidden'))){continue;}
var cs=null;try{cs=window.getComputedStyle(el);}catch(e){}
if(!cs){continue;}
var pos=cs.position;
if(pos!=='fixed'&&pos!=='sticky'){continue;}
var txt='';
try{txt=(el.innerText||'').trim().slice(0,160).toLowerCase();}catch(e){}
if(txt.length===0||txt.indexOf('cookie')===-1){continue;}
if(txt.indexOf('consent')===-1&&txt.indexOf('policy')===-1&&txt.indexOf('we use')===-1&&txt.indexOf('got it')===-1){continue;}
try{
el.setAttribute('data-cf-focus-hidden','1');
el.style.setProperty('display','none','important');
overlayHidden.push(el);
}catch(e){}
}
}catch(e){}
}
function restoreScrollIfNeeded(){
try{
if(overlayHidden.length===0){return;}
var deEl=document.documentElement;
var b=document.body;
if(deEl&&deEl.style&&deEl.style.overflow==='hidden'){deEl.style.removeProperty('overflow');}
if(b&&b.style&&b.style.overflow==='hidden'){b.style.removeProperty('overflow');}
}catch(e){}
}
function revertOverlayHides(){
try{
for(var i=0;i<overlayHidden.length;i++){
try{
var h=overlayHidden[i];
h.style.removeProperty('display');
h.removeAttribute('data-cf-focus-hidden');
}catch(e){}
}
overlayHidden=[];
}catch(e){}
}
function hideOverlaysApply(){
try{
var el=ensureOverlayStyleEl();
el.disabled=!ENABLED;
if(!ENABLED){revertOverlayHides();el.setAttribute('data-cf-focus-overlay-hidden-count','0');return;}
scanTextOverlays();
restoreScrollIfNeeded();
el.setAttribute('data-cf-focus-overlay-hidden-count',String(overlayHidden.length));
}catch(e){}
}
function pageKind(){
var p=location.pathname;
if(p==='/wow/search'){return 'listing';}
if(p.indexOf('/wow/addons/')===0){return 'project';}
return 'other';
}
function cssFor(kind){
if(kind==='listing'){
return HIDE_LISTING.join(',')+'{display:none !important;}.search-page,.ads-layout{display:block !important;}';
}
if(kind==='project'){
return HIDE_PROJECT.join(',')+'{display:none !important;}.ads-layout{display:block !important;}';
}
return '';
}
function cfFocusApply(){
try{
hideOverlaysApply();
var el=ensureStyleEl();
applyGen++;var myGen=applyGen;
if(!ENABLED){el.disabled=true;setState('disabled');return;}
var kind=pageKind();
if(kind==='other'){el.disabled=true;setState('disabled');return;}
if(kind==='listing'){
var searchPage=document.querySelector('.search-page');
if(!searchPage){el.disabled=true;setState('skipped-no-shell');return;}
var results=document.querySelector('.results-container');
var options=document.querySelector('.options');
if(!results&&!options){el.disabled=true;setState('skipped-no-results');return;}
var i;
for(i=0;i<HIDE_LISTING.length;i++){
var cand=document.querySelector(HIDE_LISTING[i]);
if(cand&&((results&&cand.contains(results))||(options&&cand.contains(options)))){
el.disabled=true;setState('skipped-selector-conflict');return;
}
}
var rHeight=results?results.getBoundingClientRect().height:0;
var oHeight=options?options.getBoundingClientRect().height:0;
if(rHeight<=40&&oHeight<=0){el.disabled=true;setState('skipped-empty');return;}
el.textContent=cssFor('listing');
el.disabled=false;
setState('applied');
try{
window.requestAnimationFrame(function(){
if(myGen!==applyGen||pageKind()!=='listing'){return;}
var c=document.querySelector('.search-page .content');
var h=c?c.getBoundingClientRect().height:0;
if(h<40){el.disabled=true;setState('skipped-post-check-failed');}
});
}catch(e){}
return;
}
if(kind==='project'){
var header=document.querySelector('.project-header')||document.querySelector('.project-details-box');
if(!header){el.disabled=true;setState('skipped-no-shell');return;}
el.textContent=cssFor('project');
el.disabled=false;
setState('applied');
return;
}
}catch(e){
try{if(styleEl){styleEl.disabled=true;}}catch(e2){}
setState('error');
}
}
function startPoll(){
try{clearInterval(fallbackTimer);}catch(e){}
var ticks=0;
var last=null;
fallbackTimer=setInterval(function(){
cfFocusApply();
ticks++;
var s=window.__cfFocusState;
if(s===last||ticks>=8){try{clearInterval(fallbackTimer);}catch(e){}}
last=s;
},400);
}
function boot(){
if(!document.body){setTimeout(boot,20);return;}
cfFocusApply();
try{
var mo=new MutationObserver(function(){
clearTimeout(pending);
pending=setTimeout(cfFocusApply,150);
});
mo.observe(document.body,{childList:true,subtree:true});
}catch(e){}
try{
var origPush=history.pushState;
var origReplace=history.replaceState;
history.pushState=function(){var r=origPush.apply(history,arguments);setTimeout(cfFocusApply,0);startPoll();return r;};
history.replaceState=function(){var r=origReplace.apply(history,arguments);setTimeout(cfFocusApply,0);startPoll();return r;};
window.addEventListener('popstate',function(){cfFocusApply();startPoll();});
}catch(e){}
}
window.__cfFocusSetEnabled=function(v){
ENABLED=!!v;
try{window.localStorage.setItem('cfFocusEnabled',ENABLED?'1':'0');}catch(e){}
cfFocusApply();
};
window.__cfFocusGetState=function(){return window.__cfFocusState||'unknown';};
if(document.readyState==='loading'){
document.addEventListener('DOMContentLoaded',boot);
}else{
boot();
}
}catch(e){}
})();
";

        private static string BuildCfFocusScript(bool defaultEnabled)
        {
            string enabledLiteral = defaultEnabled ? "true" : "false";
            return CfFocusScriptPrefix + enabledLiteral + CfFocusScriptSuffix;
        }

        // Registers the persistent per-document injection exactly once
        // (see the region comment above for why this never re-registers
        // on a toggle). _cfFocusEnabled must already be set by the caller
        // (CfWebView_InitCompleted seeds it from ReadCfFocusSetting before
        // calling this) - it becomes the cold-start default baked into
        // the script, used only until the CF pane's origin-local
        // localStorage has its own value (i.e. effectively only for the
        // very first document this webview ever loads).
        private void EnsureCfFocusInfra()
        {
            if (_cfWebView.CoreWebView2 == null) return;
            if (_cfFocusScriptRegistered) return;

            try
            {
                string script = BuildCfFocusScript(_cfFocusEnabled);
                System.Threading.Tasks.Task<string> scriptTask =
                    _cfWebView.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(script);
                GC.KeepAlive(scriptTask);
                _cfFocusScriptRegistered = true;
                LogHost("cf-focus CSS injection registered, default enabled=" +
                    _cfFocusEnabled.ToString(CultureInfo.InvariantCulture));
            }
            catch (Exception ex)
            {
                LogHost("failed to register cf-focus CSS: " + ex.Message);
            }
        }

        // {type:"cf-focus", enabled:<bool>}: the SPA's Settings > Advanced
        // "Show only search results on CurseForge" toggle. Furphy webview
        // only - see HostWebView_WebMessageReceived's own comment.
        private void HandleCfFocusMessage(Dictionary<string, object> msg)
        {
            object v;
            bool enabled = ToBool(msg.TryGetValue("enabled", out v) ? v : null, true);
            ApplyCfFocusToggle(enabled);
        }

        // Shared by HandleCfFocusMessage (an explicit in-app toggle) and
        // CfWebView_NavigationStarting's out-of-band re-sync above -
        // updates the host's view of the setting, makes sure the
        // persistent injection is registered at least once (first-ever
        // call), and pushes the new value live to whatever the CF pane
        // currently has loaded.
        private void ApplyCfFocusToggle(bool enabled)
        {
            _cfFocusEnabled = enabled;
            EnsureCfFocusInfra();
            PushCfFocusLive(enabled);
            LogHost("cf-focus set enabled=" + enabled.ToString(CultureInfo.InvariantCulture));
        }

        // Round 18 fix: settings.json must be AUTHORITATIVE over the CF
        // pane's own localStorage 'cfFocusEnabled' cache. Before this fix,
        // the injected script's readStoredEnabled() let a stale localStorage
        // value silently win forever (e.g. after toggling off once in the
        // page, or leftover state from an earlier test/profile) while
        // settings.json - and Settings' own display of it - said otherwise,
        // because the host only ever pushed a fresh value when its OWN
        // in-memory _cfFocusEnabled changed (CfWebView_NavigationStarting's
        // freshCfFocus != _cfFocusEnabled check), never merely because the
        // page might have a different, out-of-sync value it never told the
        // host about.
        //
        // Fix: called unconditionally on every CF-pane NavigationCompleted
        // (and once after CfWebView_InitCompleted) so settings.json's
        // current value is re-pushed into the page every time - idempotent,
        // via the same PushCfFocusLive that both a live in-app toggle and
        // NavigationStarting's out-of-band resync already use (writes
        // localStorage['cfFocusEnabled'] and calls the page's own
        // window.__cfFocusSetEnabled if it's already booted). The page's
        // stored flag becomes purely a cache of the setting, never a
        // second source of truth. Logs one line only when the freshly-read
        // value differs from the host's own last-known value, so a normal
        // run (setting unchanged) stays silent on every navigation.
        private void SyncCfFocusToPage(string context)
        {
            bool fresh = ReadCfFocusSetting();
            bool changed = fresh != _cfFocusEnabled;
            _cfFocusEnabled = fresh;
            EnsureCfFocusInfra();
            PushCfFocusLive(fresh);
            if (changed)
            {
                LogHost("cf-focus resynced from settings.json (" + context + "): enabled=" +
                    fresh.ToString(CultureInfo.InvariantCulture));
            }
        }

        // Fire-and-forget ExecuteScriptAsync (GC.KeepAlive, never awaited -
        // see the region comment above): writes the new value into the CF
        // pane's own localStorage (so the NEXT document-created run of the
        // persistent script above picks it up) and, if that page's
        // bootstrap has already run, calls its exposed
        // window.__cfFocusSetEnabled directly so the CURRENTLY loaded page
        // applies the change immediately with no reload.
        private void PushCfFocusLive(bool enabled)
        {
            if (_cfWebView.CoreWebView2 == null) return;
            try
            {
                string storeVal = enabled ? "1" : "0";
                string boolVal = enabled ? "true" : "false";
                string script =
                    "(function(){try{window.localStorage.setItem('cfFocusEnabled','" + storeVal + "');" +
                    "if(window.__cfFocusSetEnabled){window.__cfFocusSetEnabled(" + boolVal + ");}}catch(e){}})();";
                System.Threading.Tasks.Task<string> execTask = _cfWebView.CoreWebView2.ExecuteScriptAsync(script);
                GC.KeepAlive(execTask);
            }
            catch (Exception ex)
            {
                LogHost("cf-focus live push failed: " + ex.Message);
            }
        }

        // -------------------------------------------------------- logging

        private void LogHost(string message)
        {
            LogWriter.Append(_hostLogPath, message);
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

            // Round 16 (E22). Deliberately NOT also querying the injected
            // <style data-cf-focus> element's live data-cf-focus-state
            // here via ExecuteScriptAsync: that call is async with no
            // await in this codebase (see the cf-focus region's own
            // comment), and blocking this synchronous marker write on its
            // Task's result from the UI thread risks the exact WebView2
            // deadlock that design avoids elsewhere - not worth
            // destabilising an otherwise-reliable marker write for one
            // more field. _cfFocusEnabled (the host's own in-memory view
            // of the setting, no IPC needed) is safe to include as-is.
            marker["cfFocusEnabled"] = _cfFocusEnabled;

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

    // ------------------------------------------------------------------
    // E24 - auto-updater tray mode. Everything below runs when Program.Main
    // sees --tray or --tray-selftest and never touches MainForm at all.
    // ------------------------------------------------------------------

    // Win32 window activation - used by the tray's click handler to bring
    // an already-open main window to the foreground instead of starting a
    // second one, keyed on MainForm's exact window title (AppConstants.
    // WindowTitle) since that is the one thing every FurphyHost.exe window
    // (normal launch, deep link, whatever --view/--tab it was given) has
    // in common and the tray process itself never creates.
    internal static class WindowActivation
    {
        private const int SW_RESTORE = 9;

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr hWnd);

        public static bool WindowExists(string title)
        {
            try { return FindWindow(null, title) != IntPtr.Zero; }
            catch { return false; }
        }

        // Finds a top-level window with the given exact title and, if one
        // exists, restores it (if minimized) and brings it to the
        // foreground. Returns true iff a window was found (regardless of
        // whether SetForegroundWindow itself succeeded - Windows can
        // refuse focus-stealing from a background process in ways that
        // are not this tray's problem to solve).
        public static bool ActivateWindowByTitle(string title)
        {
            IntPtr hwnd;
            try { hwnd = FindWindow(null, title); }
            catch { return false; }
            if (hwnd == IntPtr.Zero) return false;
            try
            {
                if (IsIconic(hwnd)) { ShowWindow(hwnd, SW_RESTORE); }
                SetForegroundWindow(hwnd);
            }
            catch { }
            return true;
        }
    }

    // HKCU\...\Run "FurphyAddonManager" = "<quoted exe path>" --tray - the
    // literal value text is part of the stage A/B contract (stage B's own
    // server endpoint writes the identical string), so BuildRunValue is
    // the one place that format lives.
    internal static class StartupRegistry
    {
        private const string RunKeyPath = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        private const string ValueName = "FurphyAddonManager";

        public static string BuildRunValue(string exePath)
        {
            return "\"" + exePath + "\" --tray";
        }

        public static bool Exists()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false))
                {
                    if (key == null) return false;
                    return key.GetValue(ValueName) != null;
                }
            }
            catch { return false; }
        }

        public static string ReadValue()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false))
                {
                    if (key == null) return null;
                    object v = key.GetValue(ValueName);
                    return v as string;
                }
            }
            catch { return null; }
        }

        public static bool Enable(string exePath)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKeyPath))
                {
                    key.SetValue(ValueName, BuildRunValue(exePath), RegistryValueKind.String);
                }
                return true;
            }
            catch { return false; }
        }

        public static bool Disable()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKeyPath, true))
                {
                    if (key != null && key.GetValue(ValueName) != null)
                    {
                        key.DeleteValue(ValueName, false);
                    }
                }
                return true;
            }
            catch { return false; }
        }
    }

    // "any process named 'Wow' is running" (contract step 5a). --wow-fake
    // lets --tray-selftest substitute a harmless process name so the skip
    // path can be proven without launching the real game.
    internal static class WowDetector
    {
        // Process.GetProcessesByName does an exact, whole-name match (no
        // substring/wildcard), so retail-only "Wow" misses Classic/PTR/Beta
        // clients, which ship under their own exe names. Check every known
        // client name so the "never touch addon files while the game is
        // running" guarantee holds regardless of which client is open.
        private static readonly string[] KnownWowNames = new string[]
        {
            "Wow",
            "Wow-64",
            "WowClassic",
            "WowClassicT",
            "WowClassicB",
            "WowT",
            "WowB"
        };

        public static bool IsRunning(string fakeProcessName)
        {
            string[] names = string.IsNullOrEmpty(fakeProcessName) ? KnownWowNames : new string[] { fakeProcessName };
            for (int n = 0; n < names.Length; n++)
            {
                Process[] procs = null;
                try
                {
                    procs = Process.GetProcessesByName(names[n]);
                    if (procs.Length > 0)
                    {
                        return true;
                    }
                }
                catch
                {
                    // ignore and check the next known name
                }
                finally
                {
                    if (procs != null)
                    {
                        for (int i = 0; i < procs.Length; i++)
                        {
                            try { procs[i].Dispose(); } catch { }
                        }
                    }
                }
            }
            return false;
        }
    }

    // settings.json's background-updater keys, with the contract's
    // defaults and interval clamp applied once here so every reader (the
    // scheduling loop, --tray-selftest, the once-a-minute disabled check)
    // sees the same values.
    internal class TrayBackgroundSettings
    {
        public bool BackgroundUpdates;
        public int IntervalMinutes;
        public bool RunAtStartup;
    }

    internal static class TraySettingsReader
    {
        public const int DefaultIntervalMinutes = 120;
        public const int MinIntervalMinutes = 30;
        public const int MaxIntervalMinutes = 1440;

        public static TrayBackgroundSettings Read(string settingsPath)
        {
            Dictionary<string, object> settings = HostFiles.LoadJsonObject(settingsPath);
            TrayBackgroundSettings result = new TrayBackgroundSettings();

            object v;
            result.BackgroundUpdates = (settings.TryGetValue("backgroundUpdates", out v) && v != null)
                ? JsonUtil.ToBool(v, false)
                : false;

            int interval = DefaultIntervalMinutes;
            if (settings.TryGetValue("backgroundIntervalMinutes", out v) && v != null)
            {
                interval = JsonUtil.ToInt(v, DefaultIntervalMinutes);
            }
            if (interval < MinIntervalMinutes) interval = MinIntervalMinutes;
            if (interval > MaxIntervalMinutes) interval = MaxIntervalMinutes;
            result.IntervalMinutes = interval;

            result.RunAtStartup = (settings.TryGetValue("runAtStartup", out v) && v != null)
                ? JsonUtil.ToBool(v, false)
                : false;

            return result;
        }
    }

    // Process-level entry point for tray mode: owns the single-instance
    // mutex (contract: a second --tray exits immediately with code 0
    // after logging) and hands off to TrayForm, which does the real work
    // under a normal Application.Run message loop (needed for the
    // NotifyIcon, its context menu, and System.Windows.Forms.Timer/
    // Control.Invoke marshaling from the background cycle thread).
    internal static class TrayProgram
    {
        public const string MutexName = "FurphyAddonManager.Tray";
        public const string StopEventName = "FurphyAddonManager.TrayStop";

        public static int Run(HostOptions options, bool dpiAware)
        {
            bool createdNew = false;
            Mutex mutex = null;
            try
            {
                mutex = new Mutex(true, MutexName, out createdNew);
            }
            catch
            {
                mutex = null;
                createdNew = false;
            }

            if (mutex == null || !createdNew)
            {
                string exeDir = HostFiles.ExeDir();
                string settingsPath = HostFiles.FindUpward(exeDir, "settings.json", 4);
                string logDir = settingsPath != null ? Path.GetDirectoryName(settingsPath) : exeDir;
                LogWriter.Append(Path.Combine(logDir, "host.log"),
                    "[tray] another tray instance already holds the mutex - exiting");
                if (options.TraySelftestActive)
                {
                    WriteMutexBusyMarker(options);
                }
                if (mutex != null) { try { mutex.Close(); } catch { } }
                return 0;
            }

            try
            {
                using (TrayForm form = new TrayForm(options, dpiAware))
                {
                    Application.Run(form);
                    return form.ExitCode;
                }
            }
            finally
            {
                try { mutex.ReleaseMutex(); } catch { }
                try { mutex.Close(); } catch { }
            }
        }

        // Best-effort marker for the (untested-by-design, but must not
        // hang whoever is waiting on the marker file) case where
        // --tray-selftest is run while a real --tray already owns the
        // mutex. Every field the real marker writes is present, just
        // reflecting "did nothing" (mutexHeld=false is the tell).
        private static void WriteMutexBusyMarker(HostOptions options)
        {
            if (string.IsNullOrEmpty(options.TraySelftestMarkerPath)) return;
            Dictionary<string, object> marker = new Dictionary<string, object>();
            marker["iconShown"] = false;
            marker["tooltip"] = null;
            marker["lastResult"] = null;
            marker["updatedNames"] = new List<string>();
            marker["failedNames"] = new List<string>();
            marker["jobId"] = null;
            marker["jobPostStatus"] = null;
            // FLAVORS-SPEC.md CS-F6: same shape as the real marker below,
            // reflecting "no jobs were ever created" for this (untested-by-
            // design) mutex-busy case.
            marker["flavourJobs"] = new List<object>();
            marker["serverStarted"] = false;
            marker["clickAction"] = null;
            marker["runValueWritten"] = null;
            marker["runValueRemoved"] = false;
            marker["stateFileWritten"] = false;
            marker["mutexHeld"] = false;
            marker["exitCode"] = (long)0;
            try
            {
                string json = MiniJson.Write(marker);
                string tmpPath = options.TraySelftestMarkerPath + ".tmp";
                File.WriteAllText(tmpPath, json, new UTF8Encoding(false));
                if (File.Exists(options.TraySelftestMarkerPath))
                {
                    try { File.Delete(options.TraySelftestMarkerPath); } catch { }
                }
                File.Move(tmpPath, options.TraySelftestMarkerPath);
            }
            catch { }
        }
    }

    // Outcome of one sync cycle, surfaced on the --tray-selftest marker
    // (jobId/jobPostStatus/serverStarted) in addition to updating the
    // TrayForm instance fields that feed tray-state.json and the tooltip.
    // FLAVORS-SPEC.md CS-F6/S5.6: JobId stays the single job's id when the
    // cycle produced exactly one flavour job (byte-identical marker shape
    // to before this change set on a single-flavour machine); FlavourResults
    // always carries one entry per flavour job the cycle actually created,
    // for --tray-selftest to assert against on a multi-flavour fixture.
    internal class TrayCycleOutcome
    {
        public string JobId;
        public int? JobPostStatus;
        public bool ServerStarted;
        public List<FlavourJobResult> FlavourResults = new List<FlavourJobResult>();
    }

    // FLAVORS-SPEC.md CS-F6: one installed flavour's own job from a
    // {kind:"update-all-flavours"} fan-out (S5.4/S5.6). ErrorMessage set
    // with State still null means the server never created/found a job for
    // this flavour at all (JobId is null in that case) or the flavour's job
    // finished in a job-level failure with no addon-level results (or timed
    // out) - RunCycle/CompleteMultiFlavourCycle read that combination the
    // same way the old single-job code read a job-level "failed" state with
    // empty results.
    internal class FlavourJobResult
    {
        public string FlavourId;
        public string JobId;
        public string ErrorMessage;
        public bool Busy;
        public string State;
        public List<string> Updated = new List<string>();
        public List<string> Failed = new List<string>();
    }

    // FLAVORS-SPEC.md S2.1's fixed label table, duplicated here the same
    // way install.ps1 keeps its own small copy of $Script:FlavourDefs -
    // the tray only ever needs a flavour's player-facing label for the
    // multi-flavour tooltip breakdown, never the folder/Product mapping
    // addon-sync.ps1/addon-server.ps1's own copies carry.
    internal static class FlavourLabels
    {
        private static readonly Dictionary<string, string> Labels = BuildLabels();

        private static Dictionary<string, string> BuildLabels()
        {
            Dictionary<string, string> d = new Dictionary<string, string>();
            d["retail"] = "Retail";
            d["classic"] = "Classic";
            d["classic_era"] = "Classic Era";
            d["ptr"] = "PTR";
            d["xptr"] = "PTR (2)";
            d["beta"] = "Beta";
            return d;
        }

        public static string Get(string flavourId)
        {
            string label;
            if (flavourId != null && Labels.TryGetValue(flavourId, out label)) return label;
            return flavourId;
        }
    }

    // The tray itself: a Form that is never shown (SetVisibleCore/
    // CreateParams below) so Application.Run(form) still gives the
    // NotifyIcon, its ContextMenuStrip, and Control.Invoke marshaling a
    // real message loop, exactly like MainForm gets for the main window,
    // without ever creating a visible window of its own.
    internal class TrayForm : Form
    {
        private readonly HostOptions _options;
        private readonly bool _dpiAware;
        private readonly int _pid;
        private readonly string _exePath;
        private readonly string _exeDir;
        private readonly string _settingsPath;
        private readonly string _hostLogPath;
        private readonly string _trayStatePath;
        private readonly string _addonServerScriptPath;
        private readonly int _port;

        private NotifyIcon _icon;
        private ContextMenuStrip _menu;
        private ToolStripMenuItem _startupMenuItem;

        private EventWaitHandle _stopEvent;
        private readonly AutoResetEvent _manualTrigger = new AutoResetEvent(false);
        private Thread _workerThread;

        private readonly object _launchLock = new object();
        private DateTime _lastLaunchAttemptUtc = DateTime.MinValue;

        private readonly object _stateLock = new object();
        private string _tooltipCurrent;
        private string _lastResult;
        private List<string> _updatedNames = new List<string>();
        private List<string> _failedNames = new List<string>();
        private string _message;
        private DateTime? _lastRunAtUtc;
        private DateTime? _nextRunAtUtc;
        private bool _stateFileWritten;

        public int ExitCode;

        public TrayForm(HostOptions options, bool dpiAware)
        {
            _options = options;
            _dpiAware = dpiAware;

            // Never actually shown - see SetVisibleCore/CreateParams -
            // but give it sane bounds anyway in case some future code
            // path forgets and calls Show().
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.FixedToolWindow;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            Size = new Size(1, 1);

            _pid = Process.GetCurrentProcess().Id;
            _exePath = Application.ExecutablePath;
            _exeDir = HostFiles.ExeDir();
            _settingsPath = HostFiles.FindUpward(_exeDir, "settings.json", 4);
            string logDir = _settingsPath != null ? Path.GetDirectoryName(_settingsPath) : _exeDir;
            _hostLogPath = Path.Combine(logDir, "host.log");
            _trayStatePath = Path.Combine(logDir, "tray-state.json");
            _addonServerScriptPath = HostFiles.FindUpward(_exeDir, "addon-server.ps1", 4);
            _port = PortResolver.Resolve(_options, _settingsPath);

            bool createdNewEvent;
            try
            {
                _stopEvent = new EventWaitHandle(false, EventResetMode.ManualReset, TrayProgram.StopEventName, out createdNewEvent);
            }
            catch
            {
                // Falls back to an unnamed handle so the tray still runs
                // (just not externally stoppable by name) rather than
                // crashing outright on some locked-down environment.
                _stopEvent = new EventWaitHandle(false, EventResetMode.ManualReset);
            }

            BuildTrayIcon();
            BuildContextMenu();
            _icon.ContextMenuStrip = _menu;

            LogHost("[tray] starting pid=" + _pid.ToString(CultureInfo.InvariantCulture) +
                " port=" + _port.ToString(CultureInfo.InvariantCulture) +
                " selftest=" + _options.TraySelftestActive.ToString());

            WriteStateFile(true);

            FormClosing += new FormClosingEventHandler(TrayForm_FormClosing);

            // Force the native window handle to exist right now instead
            // of relying on the Show()/Load choreography Application.Run
            // normally drives - SetVisibleCore below always substitutes
            // false for the real OS-level show, so waiting on Load here
            // would be one more thing depending on WinForms internals
            // this file has no control over. BeginInvoke/Control.Invoke
            // marshaling and the background work started right after just
            // need IsHandleCreated to already be true, which referencing
            // Handle guarantees for a standalone top-level form like this.
            IntPtr forceHandle = Handle;
            StartBackgroundWork();
        }

        private void StartBackgroundWork()
        {
            if (_options.TraySelftestActive)
            {
                ThreadPool.QueueUserWorkItem(delegate(object state) { RunSelftestSequenceSafe(); });
            }
            else
            {
                _workerThread = new Thread(new ThreadStart(WorkerLoop));
                _workerThread.IsBackground = true;
                _workerThread.Name = "FurphyTrayWorker";
                _workerThread.Start();
            }
        }

        // Keeps the form permanently invisible regardless of who calls
        // Show()/Visible=true (Application.Run(form) calls Show() itself)
        // - the standard "tray-only, no window" WinForms idiom.
        protected override void SetVisibleCore(bool value)
        {
            base.SetVisibleCore(false);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x80; // WS_EX_TOOLWINDOW - keeps it out of the taskbar/alt-tab
                return cp;
            }
        }

        private void TrayForm_FormClosing(object sender, FormClosingEventArgs e)
        {
            try { if (_icon != null) { _icon.Visible = false; } } catch { }
            try { if (_icon != null) { _icon.Dispose(); } } catch { }
            try { if (_stopEvent != null) { _stopEvent.Close(); } } catch { }
        }

        // -------------------------------------------------- tray icon/menu

        private void BuildTrayIcon()
        {
            _icon = new NotifyIcon();
            string iconPath = HostFiles.FindUpward(_exeDir, "icon.ico", 1);
            if (iconPath != null)
            {
                try { _icon.Icon = new Icon(iconPath); }
                catch { _icon.Icon = SystemIcons.Application; }
            }
            else
            {
                _icon.Icon = SystemIcons.Application;
            }
            string startupText = TruncateTooltip("Furphy - Starting...");
            _icon.Text = startupText;
            _tooltipCurrent = startupText;
            _message = startupText;
            _icon.MouseClick += new MouseEventHandler(Icon_MouseClick);
            _icon.MouseDoubleClick += new MouseEventHandler(Icon_MouseDoubleClick);
            _icon.Visible = true;
        }

        private void BuildContextMenu()
        {
            _menu = new ContextMenuStrip();

            ToolStripMenuItem openItem = new ToolStripMenuItem("Open Furphy Addon Manager");
            openItem.Click += new EventHandler(MenuOpen_Click);
            _menu.Items.Add(openItem);

            ToolStripMenuItem checkItem = new ToolStripMenuItem("Check now");
            checkItem.Click += new EventHandler(MenuCheckNow_Click);
            _menu.Items.Add(checkItem);

            _menu.Items.Add(new ToolStripSeparator());

            _startupMenuItem = new ToolStripMenuItem("Start with Windows");
            _startupMenuItem.CheckOnClick = false;
            _startupMenuItem.Checked = StartupRegistry.Exists();
            _startupMenuItem.Click += new EventHandler(MenuStartup_Click);
            _menu.Items.Add(_startupMenuItem);

            _menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem quitItem = new ToolStripMenuItem("Quit");
            quitItem.Click += new EventHandler(MenuQuit_Click);
            _menu.Items.Add(quitItem);

            _menu.Opening += new System.ComponentModel.CancelEventHandler(Menu_Opening);
        }

        private void Menu_Opening(object sender, System.ComponentModel.CancelEventArgs e)
        {
            try { _startupMenuItem.Checked = StartupRegistry.Exists(); } catch { }
        }

        private void MenuOpen_Click(object sender, EventArgs e)
        {
            ActivateOrLaunch(false);
        }

        private void MenuCheckNow_Click(object sender, EventArgs e)
        {
            LogHost("[tray] check-now requested from menu");
            try { _manualTrigger.Set(); } catch { }
        }

        private void MenuStartup_Click(object sender, EventArgs e)
        {
            bool currentlyOn = StartupRegistry.Exists();
            if (currentlyOn)
            {
                StartupRegistry.Disable();
                LogHost("[tray] Start with Windows disabled via menu");
            }
            else
            {
                StartupRegistry.Enable(_exePath);
                LogHost("[tray] Start with Windows enabled via menu");
            }
            try { _startupMenuItem.Checked = StartupRegistry.Exists(); } catch { }
        }

        private void MenuQuit_Click(object sender, EventArgs e)
        {
            LogHost("[tray] quit selected");
            try { _stopEvent.Set(); } catch { }
        }

        private void Icon_MouseClick(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                ActivateOrLaunch(false);
            }
        }

        private void Icon_MouseDoubleClick(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                ActivateOrLaunch(false);
            }
        }

        // Brings an existing main window to the front, or starts a new
        // one - never both, and never two new processes for one rapid
        // double-click (the 5s cooldown below covers the gap between
        // Process.Start returning and the new process's window actually
        // existing for FindWindow to see). dryRun (--tray-selftest) skips
        // the actual Process.Start but still reports what would happen.
        private string ActivateOrLaunch(bool dryRun)
        {
            lock (_launchLock)
            {
                bool activated = WindowActivation.ActivateWindowByTitle(AppConstants.WindowTitle);
                if (activated)
                {
                    LogHost("[tray] activated existing window");
                    return "activate";
                }

                if (dryRun)
                {
                    return "launch";
                }

                if ((DateTime.UtcNow - _lastLaunchAttemptUtc).TotalSeconds < 5)
                {
                    return "launch";
                }
                _lastLaunchAttemptUtc = DateTime.UtcNow;
                StartMainProcess();
                LogHost("[tray] launched main window process");
                return "launch";
            }
        }

        private void StartMainProcess()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(_exePath,
                    "--port " + _port.ToString(CultureInfo.InvariantCulture));
                psi.WorkingDirectory = Path.GetDirectoryName(_exePath);
                psi.UseShellExecute = false;
                Process p = Process.Start(psi);
                if (p != null) { p.Dispose(); }
            }
            catch (Exception ex)
            {
                LogHost("[tray] failed to launch main window: " + ex.Message);
            }
        }

        // -------------------------------------------------- scheduling

        private void WorkerLoop()
        {
            try
            {
                LogHost("[tray] background loop started - first cycle in ~90s");
                if (WaitForNextCycle(90))
                {
                    FinalizeExit();
                    return;
                }

                while (true)
                {
                    TrayBackgroundSettings settings = TraySettingsReader.Read(_settingsPath);
                    RunCycle(settings);

                    int waitSeconds;
                    lock (_stateLock)
                    {
                        if (_nextRunAtUtc.HasValue)
                        {
                            double secs = (_nextRunAtUtc.Value - DateTime.UtcNow).TotalSeconds;
                            waitSeconds = secs > 0 ? (int)secs : 0;
                        }
                        else
                        {
                            waitSeconds = settings.IntervalMinutes * 60;
                        }
                    }

                    if (WaitForNextCycle(waitSeconds))
                    {
                        break;
                    }
                }
            }
            catch (Exception ex)
            {
                LogHost("[tray] worker loop crashed: " + ex.Message);
            }
            FinalizeExit();
        }

        // Waits up to totalSeconds, checking every <=60s slice for the
        // stop event (returns true immediately - "stop the loop"), a
        // manual "check now" trigger (returns false early - "run a cycle
        // now"), or settings.json's backgroundUpdates having gone false
        // (returns true - contract's once-a-minute disabled check; here
        // effectively every slice, which only ever checks more often than
        // required).
        private bool WaitForNextCycle(int totalSeconds)
        {
            WaitHandle[] handles = new WaitHandle[] { _stopEvent, _manualTrigger };
            int remaining = totalSeconds;
            while (true)
            {
                int slice = remaining < 60 ? remaining : 60;
                if (slice < 1) slice = 1;
                int idx = WaitHandle.WaitAny(handles, slice * 1000);
                if (idx == 0)
                {
                    LogHost("[tray] stop event signaled");
                    return true;
                }
                if (idx == 1)
                {
                    LogHost("[tray] manual check-now trigger fired");
                    return false;
                }
                TrayBackgroundSettings s = TraySettingsReader.Read(_settingsPath);
                if (!s.BackgroundUpdates)
                {
                    LogHost("[tray] backgroundUpdates is now false - exiting");
                    return true;
                }
                remaining -= slice;
                if (remaining <= 0) return false;
            }
        }

        private void FinalizeExit()
        {
            WriteStateFile(false);
            LogHost("[tray] exiting");
            try
            {
                if (IsHandleCreated)
                {
                    BeginInvoke(new MethodInvoker(delegate() { ExitCode = 0; Close(); }));
                }
            }
            catch { }
        }

        // -------------------------------------------------- the cycle itself

        private TrayCycleOutcome RunCycle(TrayBackgroundSettings settings)
        {
            TrayCycleOutcome outcome = new TrayCycleOutcome();
            LogHost("[tray] cycle start");
            SetTooltip("Furphy - Checking...");

            // (a) WoW running check.
            if (WowDetector.IsRunning(_options.WowFakeProcessName))
            {
                LogHost("[tray] cycle skipped: WoW is running");
                CompleteCycle("skipped_wow_running", new List<string>(), new List<string>(),
                    "Furphy - Waiting: WoW is running", DateTime.UtcNow.AddMinutes(10), false);
                return outcome;
            }

            // (b) ensure the server answers /api/ping, starting it if not.
            bool pingOk = Http.GetString(PingUrl(), 3000) != null;
            if (!pingOk)
            {
                outcome.ServerStarted = TryStartServer();
                DateTime pingDeadline = DateTime.UtcNow.AddSeconds(20);
                while (DateTime.UtcNow < pingDeadline)
                {
                    if (Http.GetString(PingUrl(), 2000) != null) { pingOk = true; break; }
                    // Same responsiveness fix as the job-poll loop below:
                    // a stop request during the ping-wait should not add
                    // up to 20s of extra delay before the tray can exit.
                    if (_stopEvent.WaitOne(1000))
                    {
                        LogHost("[tray] stop requested while waiting for addon-server");
                        return outcome;
                    }
                }
            }
            if (!pingOk)
            {
                LogHost("[tray] cycle error: addon-server did not answer /api/ping");
                CompleteCycle("error", new List<string>(), new List<string>(),
                    "Furphy - Could not reach the addon server",
                    DateTime.UtcNow.AddMinutes(settings.IntervalMinutes), false);
                return outcome;
            }

            // (c) POST /api/jobs {"kind":"update-all-flavours"} - fans out
            // server-side (addon-server.ps1 Handle-JobsPost, FLAVORS-SPEC.md
            // S5.4/S5.6) into one 'sync' job per installed, non-hidden
            // flavour. On a single-flavour machine this still produces
            // exactly one job for that one flavour - the per-addon sync
            // behavior below is therefore unchanged from before this change
            // set; only the outer response shape (a jobs[] fan-out instead
            // of one bare job) is new, and only the "more than one flavour"
            // branch further down changes the tooltip text at all.
            HttpResult postResult = Http.PostJson(JobsUrl(), "{\"kind\":\"update-all-flavours\"}", 10000);
            outcome.JobPostStatus = postResult.StatusCode;
            if (postResult.StatusCode == 409)
            {
                LogHost("[tray] cycle skipped: server busy (409)");
                CompleteCycle("skipped_busy", new List<string>(), new List<string>(),
                    "Furphy - Waiting: another job is running", DateTime.UtcNow.AddMinutes(5), false);
                return outcome;
            }
            if (postResult.NetworkError || postResult.StatusCode != 202)
            {
                LogHost("[tray] cycle error: POST /api/jobs status=" + postResult.StatusCode.ToString(CultureInfo.InvariantCulture));
                CompleteCycle("error", new List<string>(), new List<string>(),
                    "Furphy - Sync request failed",
                    DateTime.UtcNow.AddMinutes(settings.IntervalMinutes), false);
                return outcome;
            }

            List<FlavourJobResult> flavourJobs = ExtractFlavourJobs(postResult.Body);
            if (flavourJobs.Count == 0)
            {
                LogHost("[tray] cycle error: POST /api/jobs returned no per-flavour jobs");
                CompleteCycle("error", new List<string>(), new List<string>(),
                    "Furphy - Sync request failed",
                    DateTime.UtcNow.AddMinutes(settings.IntervalMinutes), false);
                return outcome;
            }
            if (flavourJobs.Count == 1) { outcome.JobId = flavourJobs[0].JobId; }
            outcome.FlavourResults = flavourJobs;

            // (d) poll every flavour's own job (GET /api/jobs/<id> every
            // 2s), one shared 15-minute cap across the whole cycle - a slow
            // flavour does not get its own separate 15 minutes on top of
            // the others, matching the pre-CS-F6 single-job contract.
            DateTime pollDeadline = DateTime.UtcNow.AddMinutes(15);
            bool interrupted = false;
            while (true)
            {
                bool anyPending = false;
                for (int i = 0; i < flavourJobs.Count; i++)
                {
                    if (flavourJobs[i].JobId != null && flavourJobs[i].State == null) { anyPending = true; break; }
                }
                if (!anyPending) break;
                if (DateTime.UtcNow >= pollDeadline) break;

                // Wait on the stop event instead of a blind sleep so
                // Quit / a stage-B TrayStop signal during a sync is
                // honored within ~2s instead of blocking exit for up to
                // 15 minutes.
                if (_stopEvent.WaitOne(2000))
                {
                    LogHost("[tray] stop requested mid-cycle");
                    interrupted = true;
                    break;
                }

                for (int i = 0; i < flavourJobs.Count; i++)
                {
                    FlavourJobResult fr = flavourJobs[i];
                    if (fr.JobId == null || fr.State != null) continue;
                    string body = Http.GetString(JobUrl(fr.JobId), 5000);
                    if (string.IsNullOrEmpty(body)) continue;
                    Dictionary<string, object> job = MiniJson.Parse(body) as Dictionary<string, object>;
                    if (job == null) continue;

                    // Live per-job progress only makes sense to surface on
                    // the tooltip when there is exactly one flavour job to
                    // watch - a multi-flavour cycle's tooltip stays on
                    // "Checking..." until the combined result is ready
                    // (CompleteMultiFlavourCycle), never a single flavour's
                    // own in-progress count.
                    if (flavourJobs.Count == 1)
                    {
                        object progressObj;
                        if (job.TryGetValue("progress", out progressObj) && progressObj is Dictionary<string, object>)
                        {
                            SetTooltip(BuildProgressTooltip((Dictionary<string, object>)progressObj));
                        }
                    }

                    object stateObj;
                    string state = job.TryGetValue("state", out stateObj) ? stateObj as string : null;
                    if (state == "done" || state == "failed")
                    {
                        ApplyFinishedJob(fr, job);
                    }
                }
            }

            if (interrupted)
            {
                // Stop was requested mid-poll - exit quietly without
                // recording an "error" cycle; WorkerLoop/RunSelftestSequence
                // is about to shut the tray down anyway.
                return outcome;
            }

            // Anything still pending past the 15-minute cap becomes a
            // per-flavour timeout, exactly like the pre-CS-F6 single-job
            // "sync timed out" path.
            for (int i = 0; i < flavourJobs.Count; i++)
            {
                FlavourJobResult fr = flavourJobs[i];
                if (fr.JobId != null && fr.State == null && fr.ErrorMessage == null)
                {
                    fr.ErrorMessage = "sync job did not finish within 15 minutes";
                }
            }

            CompleteMultiFlavourCycle(flavourJobs, settings);
            return outcome;
        }

        // Parses {kind:"update-all-flavours", jobs:[{flavour,jobId}|
        // {flavour,error}|{flavour,jobId,busy:true}, ...]} (addon-server.ps1
        // Handle-JobsPost, FLAVORS-SPEC.md S5.4/S5.6). A row with no jobId
        // means the server could not create/find a job for that flavour at
        // all (its own .error explains why) - never polled, just carried
        // straight through as that flavour's ErrorMessage.
        private static List<FlavourJobResult> ExtractFlavourJobs(string body)
        {
            List<FlavourJobResult> list = new List<FlavourJobResult>();
            if (string.IsNullOrEmpty(body)) return list;
            Dictionary<string, object> obj = MiniJson.Parse(body) as Dictionary<string, object>;
            if (obj == null) return list;
            object jobsObj;
            if (!obj.TryGetValue("jobs", out jobsObj) || !(jobsObj is List<object>)) return list;
            List<object> jobs = (List<object>)jobsObj;
            for (int i = 0; i < jobs.Count; i++)
            {
                Dictionary<string, object> row = jobs[i] as Dictionary<string, object>;
                if (row == null) continue;
                FlavourJobResult fr = new FlavourJobResult();
                object flavourObj;
                fr.FlavourId = (row.TryGetValue("flavour", out flavourObj) && flavourObj != null)
                    ? Convert.ToString(flavourObj, CultureInfo.InvariantCulture)
                    : "retail";
                object jobIdObj;
                fr.JobId = (row.TryGetValue("jobId", out jobIdObj) && jobIdObj != null)
                    ? Convert.ToString(jobIdObj, CultureInfo.InvariantCulture)
                    : null;
                object errorObj;
                if (row.TryGetValue("error", out errorObj) && errorObj != null)
                {
                    fr.ErrorMessage = Convert.ToString(errorObj, CultureInfo.InvariantCulture);
                }
                object busyObj;
                fr.Busy = row.TryGetValue("busy", out busyObj) && JsonUtil.ToBool(busyObj, false);
                list.Add(fr);
            }
            return list;
        }

        // Classifies one finished (state=="done"|"failed") job's results
        // into fr.Updated/fr.Failed, exactly the way the pre-CS-F6 single-
        // job RunCycle classified its one job - a hard job-level failure
        // (sync CLI crashed, execution policy error, results never
        // populated) comes back as state=="failed" with an empty results
        // list, recorded as fr.ErrorMessage so CompleteMultiFlavourCycle
        // never silently reads that as "up to date".
        private static void ApplyFinishedJob(FlavourJobResult fr, Dictionary<string, object> job)
        {
            object stateObj;
            string state = job.TryGetValue("state", out stateObj) ? stateObj as string : null;
            fr.State = state ?? "done";

            List<string> updated = new List<string>();
            List<string> failed = new List<string>();
            object resultsObj;
            if (job.TryGetValue("results", out resultsObj) && resultsObj is List<object>)
            {
                List<object> results = (List<object>)resultsObj;
                for (int i = 0; i < results.Count; i++)
                {
                    Dictionary<string, object> row = results[i] as Dictionary<string, object>;
                    if (row == null) continue;
                    object statusObj;
                    object nameObj;
                    string status = row.TryGetValue("status", out statusObj) ? statusObj as string : null;
                    string name = row.TryGetValue("name", out nameObj) ? nameObj as string : null;
                    if (string.IsNullOrEmpty(name)) name = "?";
                    if (string.Equals(status, "Installed", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(status, "Updated", StringComparison.OrdinalIgnoreCase))
                    {
                        updated.Add(name);
                    }
                    else if (string.Equals(status, "Failed", StringComparison.OrdinalIgnoreCase))
                    {
                        failed.Add(name);
                    }
                }
            }
            fr.Updated = updated;
            fr.Failed = failed;

            if (string.Equals(state, "failed", StringComparison.OrdinalIgnoreCase) &&
                failed.Count == 0 && updated.Count == 0)
            {
                object errObj;
                fr.ErrorMessage = (job.TryGetValue("error", out errObj) && errObj != null)
                    ? Convert.ToString(errObj, CultureInfo.InvariantCulture)
                    : "sync job failed";
            }
        }

        // Builds the combined tooltip/lastResult/balloon for the whole
        // cycle. Exactly one flavour job (today's only case on this
        // machine, and every single-flavour install): byte-identical text
        // to the pre-CS-F6 single-job code - failed > updated > up_to_date,
        // same three message strings. More than one: FLAVORS-SPEC.md S5.6 -
        // a single combined line, never one sentence per flavour; "up to
        // date" stays one line even when every flavour agrees, and a mixed
        // result carries a "Label: count" breakdown for whichever flavours
        // actually had updates.
        private void CompleteMultiFlavourCycle(List<FlavourJobResult> flavourJobs, TrayBackgroundSettings settings)
        {
            string nowStamp = DateTime.Now.ToString("HH:mm", CultureInfo.InvariantCulture);

            if (flavourJobs.Count <= 1)
            {
                FlavourJobResult fr = flavourJobs.Count == 1 ? flavourJobs[0] : new FlavourJobResult();

                if (fr.ErrorMessage != null && fr.Updated.Count == 0 && fr.Failed.Count == 0)
                {
                    LogHost("[tray] cycle error: sync job failed: " + fr.ErrorMessage);
                    CompleteCycle("error", fr.Updated, fr.Failed,
                        "Furphy - Sync failed: " + fr.ErrorMessage,
                        DateTime.UtcNow.AddMinutes(settings.IntervalMinutes), true);
                    return;
                }

                string result;
                string message;
                bool balloon;
                if (fr.Failed.Count > 0)
                {
                    result = "failed";
                    message = (fr.Failed.Count == 1)
                        ? "Furphy - 1 addon failed to update at " + nowStamp + " - open for details"
                        : "Furphy - " + fr.Failed.Count.ToString(CultureInfo.InvariantCulture) +
                            " addons failed to update at " + nowStamp + " - open for details";
                    balloon = true;
                }
                else if (fr.Updated.Count > 0)
                {
                    result = "updated";
                    message = "Furphy - Updated " + fr.Updated.Count.ToString(CultureInfo.InvariantCulture) +
                        " at " + nowStamp + ": " + JoinNames(fr.Updated);
                    balloon = true;
                }
                else
                {
                    result = "up_to_date";
                    message = "Furphy - Everything's up to date - checked " + nowStamp;
                    balloon = false;
                }

                LogHost("[tray] cycle done result=" + result +
                    " updated=" + fr.Updated.Count.ToString(CultureInfo.InvariantCulture) +
                    " failed=" + fr.Failed.Count.ToString(CultureInfo.InvariantCulture));
                CompleteCycle(result, fr.Updated, fr.Failed, message, DateTime.UtcNow.AddMinutes(settings.IntervalMinutes), balloon);
                return;
            }

            List<string> allUpdated = new List<string>();
            List<string> allFailed = new List<string>();
            List<string> breakdownParts = new List<string>();
            int flavourErrorCount = 0;
            for (int i = 0; i < flavourJobs.Count; i++)
            {
                FlavourJobResult fr = flavourJobs[i];
                allUpdated.AddRange(fr.Updated);
                allFailed.AddRange(fr.Failed);
                if (fr.Updated.Count > 0)
                {
                    breakdownParts.Add(FlavourLabels.Get(fr.FlavourId) + ": " +
                        fr.Updated.Count.ToString(CultureInfo.InvariantCulture));
                }
                if (fr.ErrorMessage != null && fr.Updated.Count == 0 && fr.Failed.Count == 0)
                {
                    flavourErrorCount++;
                    LogHost("[tray] cycle error (" + fr.FlavourId + "): " + fr.ErrorMessage);
                }
            }

            string overallResult;
            string overallMessage;
            bool overallBalloon;
            if (allFailed.Count > 0 || flavourErrorCount > 0)
            {
                overallResult = "failed";
                int failCount = allFailed.Count + flavourErrorCount;
                overallMessage = (failCount == 1)
                    ? "Furphy - 1 addon failed to update at " + nowStamp + " - open for details"
                    : "Furphy - " + failCount.ToString(CultureInfo.InvariantCulture) +
                        " addons failed to update at " + nowStamp + " - open for details";
                overallBalloon = true;
            }
            else if (allUpdated.Count > 0)
            {
                overallResult = "updated";
                overallMessage = "Furphy - Updated " + allUpdated.Count.ToString(CultureInfo.InvariantCulture) +
                    " at " + nowStamp + " (" + JoinNames(breakdownParts) + ")";
                overallBalloon = true;
            }
            else
            {
                overallResult = "up_to_date";
                overallMessage = "Furphy - Everything's up to date - checked " + nowStamp;
                overallBalloon = false;
            }

            LogHost("[tray] cycle done (multi-flavour) result=" + overallResult +
                " updated=" + allUpdated.Count.ToString(CultureInfo.InvariantCulture) +
                " failed=" + allFailed.Count.ToString(CultureInfo.InvariantCulture) +
                " flavours=" + flavourJobs.Count.ToString(CultureInfo.InvariantCulture));
            CompleteCycle(overallResult, allUpdated, allFailed, overallMessage,
                DateTime.UtcNow.AddMinutes(settings.IntervalMinutes), overallBalloon);
        }

        private void CompleteCycle(string result, List<string> updated, List<string> failed, string message,
            DateTime nextRunAtUtc, bool balloon)
        {
            string truncated = TruncateTooltip(message);
            lock (_stateLock)
            {
                _lastResult = result;
                _updatedNames = updated;
                _failedNames = failed;
                _message = truncated;
                _lastRunAtUtc = DateTime.UtcNow;
                _nextRunAtUtc = nextRunAtUtc;
            }
            SetTooltip(truncated);
            WriteStateFile(true);
            if (balloon)
            {
                ShowBalloon(result, truncated);
            }
        }

        private static string JoinNames(List<string> names)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < names.Count; i++)
            {
                if (i > 0) sb.Append(", ");
                sb.Append(names[i]);
            }
            return sb.ToString();
        }

        private static string BuildProgressTooltip(Dictionary<string, object> progress)
        {
            object indexObj;
            object totalObj;
            int index = progress.TryGetValue("index", out indexObj) ? JsonUtil.ToInt(indexObj, 0) : 0;
            int total = progress.TryGetValue("total", out totalObj) ? JsonUtil.ToInt(totalObj, 0) : 0;
            if (total > 0)
            {
                return "Furphy - Updating " + index.ToString(CultureInfo.InvariantCulture) +
                    " of " + total.ToString(CultureInfo.InvariantCulture) + "...";
            }
            return "Furphy - Checking...";
        }

        private string PingUrl() { return "http://localhost:" + _port.ToString(CultureInfo.InvariantCulture) + "/api/ping"; }
        private string JobsUrl() { return "http://localhost:" + _port.ToString(CultureInfo.InvariantCulture) + "/api/jobs"; }
        private string JobUrl(string id) { return "http://localhost:" + _port.ToString(CultureInfo.InvariantCulture) + "/api/jobs/" + id; }

        // Starts addon-server.ps1 exactly as Addon Manager.vbs does, but
        // from C# with no window flash (UseShellExecute=false,
        // CreateNoWindow=true) instead of the .vbs's WindowStyle-hidden
        // sh.Run.
        private bool TryStartServer()
        {
            if (string.IsNullOrEmpty(_addonServerScriptPath))
            {
                LogHost("[tray] cannot start server: addon-server.ps1 not found");
                return false;
            }
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + _addonServerScriptPath + "\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WorkingDirectory = Path.GetDirectoryName(_addonServerScriptPath);
                Process p = Process.Start(psi);
                if (p != null) { p.Dispose(); }
                LogHost("[tray] started addon-server.ps1");
                return true;
            }
            catch (Exception ex)
            {
                LogHost("[tray] failed to start addon-server.ps1: " + ex.Message);
                return false;
            }
        }

        // -------------------------------------------------- tooltip/state

        private static string TruncateTooltip(string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            if (s.Length <= 118) return s;
            return s.Substring(0, 115) + "...";
        }

        // Marshals onto the UI thread since this is called from the
        // background worker/ThreadPool thread but NotifyIcon.Text must be
        // set from the thread that owns its window.
        private void SetTooltip(string text)
        {
            string t = TruncateTooltip(text);
            lock (_stateLock) { _tooltipCurrent = t; }
            try
            {
                if (IsHandleCreated)
                {
                    BeginInvoke(new MethodInvoker(delegate() { try { _icon.Text = t; } catch { } }));
                }
                else
                {
                    try { _icon.Text = t; } catch { }
                }
            }
            catch { }
        }

        private void ShowBalloon(string result, string tooltipText)
        {
            try
            {
                if (IsHandleCreated)
                {
                    BeginInvoke(new MethodInvoker(delegate()
                    {
                        try
                        {
                            _icon.BalloonTipTitle = AppConstants.WindowTitle;
                            _icon.BalloonTipText = tooltipText;
                            _icon.BalloonTipIcon = (result == "failed") ? ToolTipIcon.Warning : ToolTipIcon.Info;
                            _icon.ShowBalloonTip(8000);
                        }
                        catch { }
                    }));
                }
            }
            catch { }
        }

        // Rewrites tray-state.json atomically. Reuses HostFiles.
        // UpdateJsonObject's temp-file-then-move write by clearing the
        // dictionary it hands the mutator and refilling it from scratch -
        // this file is a full snapshot each cycle, not a merge.
        private void WriteStateFile(bool running)
        {
            string lastResult;
            List<string> updated;
            List<string> failed;
            string message;
            DateTime? lastRunAtUtc;
            DateTime? nextRunAtUtc;
            lock (_stateLock)
            {
                lastResult = _lastResult;
                updated = new List<string>(_updatedNames);
                failed = new List<string>(_failedNames);
                message = _message;
                lastRunAtUtc = _lastRunAtUtc;
                nextRunAtUtc = _nextRunAtUtc;
            }

            Dictionary<string, object> snapshot = new Dictionary<string, object>();
            snapshot["running"] = running;
            snapshot["pid"] = (long)_pid;
            snapshot["lastRunAt"] = lastRunAtUtc.HasValue ? (object)ToIso(lastRunAtUtc.Value) : null;
            snapshot["lastResult"] = lastResult;
            snapshot["updatedNames"] = updated;
            snapshot["failedNames"] = failed;
            snapshot["message"] = message;
            snapshot["nextRunAt"] = nextRunAtUtc.HasValue ? (object)ToIso(nextRunAtUtc.Value) : null;

            HostFiles.UpdateJsonObject(_trayStatePath, delegate(Dictionary<string, object> d)
            {
                d.Clear();
                foreach (KeyValuePair<string, object> kv in snapshot)
                {
                    d[kv.Key] = kv.Value;
                }
            });
            _stateFileWritten = true;
        }

        private static string ToIso(DateTime utc)
        {
            return utc.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
        }

        private void LogHost(string message)
        {
            LogWriter.Append(_hostLogPath, message);
        }

        // -------------------------------------------------- --tray-selftest

        // Guards the whole selftest sequence: an unhandled exception on a
        // ThreadPool thread would otherwise kill the process outright
        // (default .NET Framework behavior), skipping WriteMarker and
        // FinalizeExit - leaving a ghost tray icon and hanging whatever
        // test harness is waiting on the marker file. This mirrors the
        // guarantee WorkerLoop's own try/catch + FinalizeExit already
        // gives the real --tray path.
        private void RunSelftestSequenceSafe()
        {
            try
            {
                RunSelftestSequence();
            }
            catch (Exception ex)
            {
                LogHost("[tray] selftest sequence crashed: " + ex.Message);
                WriteSelftestCrashMarker(ex);
            }
            finally
            {
                FinalizeExit();
            }
        }

        // Best-effort marker for the case RunSelftestSequenceSafe's catch
        // handles - same field shape as the normal marker and
        // WriteMutexBusyMarker, but reflecting "started, then crashed"
        // (mutexHeld stays true since this process still holds it;
        // exitCode is 1 so a caller can tell the run did not complete
        // cleanly). Never includes exception detail beyond ex.Message,
        // which is already local file/path/status text, not a secret.
        private void WriteSelftestCrashMarker(Exception ex)
        {
            if (string.IsNullOrEmpty(_options.TraySelftestMarkerPath)) return;
            Dictionary<string, object> marker = new Dictionary<string, object>();
            marker["iconShown"] = false;
            try { marker["iconShown"] = _icon != null && _icon.Visible; } catch { }
            marker["tooltip"] = "selftest crashed: " + ex.Message;
            marker["lastResult"] = "error";
            marker["updatedNames"] = new List<string>();
            marker["failedNames"] = new List<string>();
            marker["jobId"] = null;
            marker["jobPostStatus"] = null;
            marker["flavourJobs"] = new List<object>();
            marker["serverStarted"] = false;
            marker["clickAction"] = null;
            marker["runValueWritten"] = null;
            marker["runValueRemoved"] = false;
            marker["stateFileWritten"] = _stateFileWritten;
            marker["mutexHeld"] = true;
            marker["exitCode"] = (long)1;
            WriteMarker(marker);
        }

        private void RunSelftestSequence()
        {
            bool iconShown = false;
            try { iconShown = _icon != null && _icon.Visible; } catch { }

            TrayBackgroundSettings settings = TraySettingsReader.Read(_settingsPath);
            TrayCycleOutcome outcome = RunCycle(settings);

            string clickAction = ActivateOrLaunch(true);

            // Toggle Start with Windows on, record the exact value text,
            // then always disable it again - the harness must not leave
            // the Run value behind after a test run.
            string runValueWritten = null;
            bool runValueRemoved = false;
            try
            {
                StartupRegistry.Enable(_exePath);
                runValueWritten = StartupRegistry.ReadValue();
            }
            finally
            {
                bool disabled = StartupRegistry.Disable();
                runValueRemoved = disabled && !StartupRegistry.Exists();
            }
            // Marshal onto the UI thread like SetTooltip/ShowBalloon do -
            // this runs on a ThreadPool thread and ToolStripMenuItem is
            // still UI state even though it won't throw the cross-thread
            // exception a Control would.
            try
            {
                if (IsHandleCreated)
                {
                    bool startupExists = StartupRegistry.Exists();
                    BeginInvoke(new MethodInvoker(delegate()
                    {
                        try { _startupMenuItem.Checked = startupExists; } catch { }
                    }));
                }
            }
            catch { }

            string tooltip;
            string lastResult;
            List<string> updated;
            List<string> failed;
            lock (_stateLock)
            {
                tooltip = _tooltipCurrent;
                lastResult = _lastResult;
                updated = new List<string>(_updatedNames);
                failed = new List<string>(_failedNames);
            }

            Dictionary<string, object> marker = new Dictionary<string, object>();
            marker["iconShown"] = iconShown;
            marker["tooltip"] = tooltip;
            marker["lastResult"] = lastResult;
            marker["updatedNames"] = updated;
            marker["failedNames"] = failed;
            marker["jobId"] = outcome.JobId;
            marker["jobPostStatus"] = outcome.JobPostStatus.HasValue ? (object)(long)outcome.JobPostStatus.Value : null;
            // FLAVORS-SPEC.md CS-F6: one row per flavour job the cycle
            // actually created (S8's acceptance checklist proves this is
            // exactly one row per installed, non-hidden flavour) - a
            // harness asserts against this list's length/flavour ids rather
            // than the single jobId/jobPostStatus fields above, which only
            // ever describe the outer POST /api/jobs call.
            List<object> flavourJobsMarker = new List<object>();
            for (int fi = 0; fi < outcome.FlavourResults.Count; fi++)
            {
                FlavourJobResult fr = outcome.FlavourResults[fi];
                Dictionary<string, object> row = new Dictionary<string, object>();
                row["flavour"] = fr.FlavourId;
                row["jobId"] = fr.JobId;
                row["state"] = fr.State;
                row["updatedNames"] = fr.Updated;
                row["failedNames"] = fr.Failed;
                row["error"] = fr.ErrorMessage;
                row["busy"] = fr.Busy;
                flavourJobsMarker.Add(row);
            }
            marker["flavourJobs"] = flavourJobsMarker;
            marker["serverStarted"] = outcome.ServerStarted;
            marker["clickAction"] = clickAction;
            marker["runValueWritten"] = runValueWritten;
            marker["runValueRemoved"] = runValueRemoved;
            marker["stateFileWritten"] = _stateFileWritten;
            marker["mutexHeld"] = true;
            marker["exitCode"] = (long)0;

            WriteMarker(marker);
            // FinalizeExit() is called by RunSelftestSequenceSafe's
            // finally block (both the normal-completion path here and
            // any crash path go through the same single call now).
        }

        private void WriteMarker(Dictionary<string, object> marker)
        {
            if (string.IsNullOrEmpty(_options.TraySelftestMarkerPath)) return;
            try
            {
                string json = MiniJson.Write(marker);
                string tmpPath = _options.TraySelftestMarkerPath + ".tmp";
                File.WriteAllText(tmpPath, json, new UTF8Encoding(false));
                if (File.Exists(_options.TraySelftestMarkerPath))
                {
                    try { File.Delete(_options.TraySelftestMarkerPath); } catch { }
                }
                File.Move(tmpPath, _options.TraySelftestMarkerPath);
                LogHost("[tray] selftest marker written: " + _options.TraySelftestMarkerPath);
            }
            catch (Exception ex)
            {
                LogHost("[tray] failed to write selftest marker: " + ex.Message);
            }
        }
    }
}
