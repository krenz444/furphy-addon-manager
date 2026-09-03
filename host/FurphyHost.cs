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
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            HostOptions options = HostOptions.Parse(args);
            using (MainForm form = new MainForm(options))
            {
                Application.Run(form);
                return form.ExitCode;
            }
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

        private readonly HostOptions _options;
        private readonly string _settingsPath;
        private readonly string _adFilterListPath;
        private readonly string _hostLogPath;
        private readonly int _port;

        private TabControl _tabs;
        private TabPage _furphyTab;
        private TabPage _cfTab;
        private WebView2 _furphyWebView;
        private WebView2 _cfWebView;
        private Panel _cfToolbar;
        private TextBox _cfSearchBox;

        private bool _furphyReady;
        private bool _cfReady;
        private bool _cfFilterInfraRegistered;
        private bool _cfAdCssInjected;
        private bool _adFilterEnabled;
        private List<string> _adFilterHosts;

        private System.Windows.Forms.Timer _selftestTimer;
        private bool _selftestMarkerWritten;
        private readonly List<string> _selftestBlocked = new List<string>();
        private readonly List<string> _selftestAllowed = new List<string>();
        private readonly List<string> _selftestIntercepted = new List<string>();
        private int? _selftestJobPostStatus;
        private string _webviewVersion;

        public int ExitCode;

        public MainForm(HostOptions options)
        {
            _options = options;
            string exeDir = HostFiles.ExeDir();
            _settingsPath = HostFiles.FindUpward(exeDir, "settings.json", 4);
            _adFilterListPath = HostFiles.FindUpward(exeDir, "adfilter-hosts.txt", 4);
            string logDir = _settingsPath != null ? Path.GetDirectoryName(_settingsPath) : exeDir;
            _hostLogPath = Path.Combine(logDir, "host.log");

            _port = ResolvePort();

            Text = WindowTitle;
            StartPosition = FormStartPosition.Manual;
            MinimumSize = new Size(900, 600);

            string iconPath = HostFiles.FindUpward(exeDir, "icon.ico", 1);
            if (iconPath != null)
            {
                try { Icon = new Icon(iconPath); } catch { }
            }

            ApplyWindowBounds();

            BuildUi();

            Load += new EventHandler(MainForm_Load);
            FormClosing += new FormClosingEventHandler(MainForm_FormClosing);
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

        private void BuildUi()
        {
            _tabs = new TabControl();
            _tabs.Dock = DockStyle.Fill;
            _tabs.Alignment = TabAlignment.Left;
            _tabs.SizeMode = TabSizeMode.Fixed;
            _tabs.ItemSize = new Size(28, 110);

            _furphyTab = new TabPage("Furphy");
            _cfTab = new TabPage("CurseForge");

            _furphyWebView = new WebView2();
            _furphyWebView.Dock = DockStyle.Fill;
            _furphyTab.Controls.Add(_furphyWebView);

            _cfWebView = new WebView2();
            _cfWebView.Dock = DockStyle.Fill;

            _cfToolbar = BuildCfToolbar();
            _cfTab.Controls.Add(_cfWebView);
            _cfTab.Controls.Add(_cfToolbar);

            _tabs.TabPages.Add(_furphyTab);
            _tabs.TabPages.Add(_cfTab);

            Controls.Add(_tabs);
        }

        private Panel BuildCfToolbar()
        {
            Panel bar = new Panel();
            bar.Dock = DockStyle.Top;
            bar.Height = 34;
            bar.Padding = new Padding(4);

            Button back = new Button();
            back.Text = "<";
            back.Width = 30;
            back.Location = new Point(4, 4);
            back.Click += new EventHandler(CfBack_Click);

            Button fwd = new Button();
            fwd.Text = ">";
            fwd.Width = 30;
            fwd.Location = new Point(38, 4);
            fwd.Click += new EventHandler(CfForward_Click);

            Button home = new Button();
            home.Text = "Home";
            home.Width = 50;
            home.Location = new Point(72, 4);
            home.Click += new EventHandler(CfHome_Click);

            _cfSearchBox = new TextBox();
            _cfSearchBox.Location = new Point(130, 6);
            _cfSearchBox.Width = 220;
            _cfSearchBox.KeyDown += new KeyEventHandler(CfSearchBox_KeyDown);

            Button go = new Button();
            go.Text = "Go";
            go.Width = 40;
            go.Location = new Point(356, 4);
            go.Click += new EventHandler(CfGo_Click);

            bar.Controls.Add(back);
            bar.Controls.Add(fwd);
            bar.Controls.Add(home);
            bar.Controls.Add(_cfSearchBox);
            bar.Controls.Add(go);
            return bar;
        }

        // ------------------------------------------------------ toolbar

        private void CfBack_Click(object sender, EventArgs e)
        {
            if (_cfWebView.CoreWebView2 != null && _cfWebView.CoreWebView2.CanGoBack)
            {
                _cfWebView.CoreWebView2.GoBack();
            }
        }

        private void CfForward_Click(object sender, EventArgs e)
        {
            if (_cfWebView.CoreWebView2 != null && _cfWebView.CoreWebView2.CanGoForward)
            {
                _cfWebView.CoreWebView2.GoForward();
            }
        }

        private void CfHome_Click(object sender, EventArgs e)
        {
            NavigateCf("https://www.curseforge.com/wow/addons");
        }

        private void CfGo_Click(object sender, EventArgs e)
        {
            RunCfSearch();
        }

        private void CfSearchBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter)
            {
                RunCfSearch();
                e.Handled = true;
                e.SuppressKeyPress = true;
            }
        }

        private void RunCfSearch()
        {
            string term = _cfSearchBox.Text == null ? string.Empty : _cfSearchBox.Text.Trim();
            if (term.Length == 0) return;
            string encoded = Uri.EscapeDataString(term);
            NavigateCf("https://www.curseforge.com/wow/search?search=" + encoded + "&class=addons");
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
                string furphyUrl = "http://localhost:" + _port.ToString(CultureInfo.InvariantCulture) + "/?host=webview2";
                _furphyWebView.Source = new Uri(furphyUrl);

                string cfInitialUrl = _options.SelftestActive
                    ? _options.SelftestTestPageUrl
                    : "https://www.curseforge.com/wow/addons";
                _cfWebView.Source = new Uri(cfInitialUrl);
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
            _cfWebView.CoreWebView2.NewWindowRequested +=
                new EventHandler<CoreWebView2NewWindowRequestedEventArgs>(CfWebView_NewWindowRequested);
            _cfWebView.CoreWebView2.WebResourceRequested +=
                new EventHandler<CoreWebView2WebResourceRequestedEventArgs>(CfWebView_WebResourceRequested);

            EnsureAdFilterInfra();
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
                SwitchToFurphyTab();
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

            SwitchToFurphyTab();
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
                SwitchToFurphyTab();
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

        private void SwitchToFurphyTab()
        {
            if (_tabs.InvokeRequired)
            {
                _tabs.BeginInvoke(new MethodInvoker(SwitchToFurphyTab));
                return;
            }
            _tabs.SelectedTab = _furphyTab;
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

        private void WriteSelftestMarker(bool initSucceeded)
        {
            if (_selftestMarkerWritten) return;
            _selftestMarkerWritten = true;

            string cfTitle = null;
            try
            {
                if (_cfWebView != null && _cfWebView.CoreWebView2 != null)
                {
                    cfTitle = _cfWebView.CoreWebView2.DocumentTitle;
                }
            }
            catch { }

            Dictionary<string, object> marker = new Dictionary<string, object>();
            marker["init"] = initSucceeded && _furphyReady && _cfReady;
            marker["version"] = _webviewVersion;
            marker["cfTabTitle"] = cfTitle;

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
