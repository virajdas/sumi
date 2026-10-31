using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace Sumi
{
    sealed class MainForm : Form
    {
        const string AppHost = "https://app.local/";
        const string DocHost = "doc.local";

        static readonly string DataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sumi");
        static readonly string BoundsFile = Path.Combine(DataDir, "window.txt");
        static readonly string SettingsFile = Path.Combine(DataDir, "settings.ini");
        static readonly Regex PrefKey = new Regex("^[a-z]{1,24}$");

        readonly WebView2 web;
        readonly SortedDictionary<string, string> prefs = LoadPrefs();
        string prefsScriptId;
        readonly Timer reloadTimer = new Timer { Interval = 180 };
        FileSystemWatcher watcher;
        string currentPath;
        bool pageReady;

        public MainForm(string path)
        {
            currentPath = string.IsNullOrEmpty(path) ? null : Path.GetFullPath(path);

            Text = "Sumi";
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            StartPosition = FormStartPosition.Manual;
            var scale = MonitorScale(Cursor.Position);
            MinimumSize = new Size((int)(420 * scale), (int)(360 * scale));
            LoadBounds();

            bool dark = SystemPrefersDark();
            BackColor = dark ? Color.FromArgb(0x1b, 0x1b, 0x1d) : Color.FromArgb(0xfa, 0xf8, 0xf4);

            web = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = BackColor };
            Controls.Add(web);

            reloadTimer.Tick += (s, e) => { reloadTimer.Stop(); SendDocument(reload: true); };

            HandleCreated += (s, e) => SetCaption(dark, BackColor);
            Load += async (s, e) => await InitAsync();
            FormClosing += (s, e) => SaveBounds();
        }

        async System.Threading.Tasks.Task InitAsync()
        {
            Directory.CreateDirectory(DataDir);
            var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(DataDir, "WebView2"));
            await web.EnsureCoreWebView2Async(env);

            var core = web.CoreWebView2;
            var st = core.Settings;
            st.AreDevToolsEnabled = false;
            st.IsStatusBarEnabled = false;
            st.IsZoomControlEnabled = false;
            st.IsPinchZoomEnabled = false;
            st.AreBrowserAcceleratorKeysEnabled = true;
            st.IsPasswordAutosaveEnabled = false;
            st.IsGeneralAutofillEnabled = false;

            core.AddWebResourceRequestedFilter(AppHost + "*", CoreWebView2WebResourceContext.All);
            core.AddWebResourceRequestedFilter("https://" + DocHost + "/*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += (s, e) =>
            {
                if (new Uri(e.Request.Uri).Host.Equals(DocHost, StringComparison.OrdinalIgnoreCase)) ServeDocumentFile(env, e);
                else ServeEmbedded(env, e);
            };
            core.NavigationStarting += OnNavigationStarting;
            core.NewWindowRequested += (s, e) => { e.Handled = true; OpenLink(e.Uri); };
            core.WebMessageReceived += OnWebMessage;
            core.DocumentTitleChanged += (s, e) =>
            {
                var t = core.DocumentTitle;
                Text = string.IsNullOrEmpty(t) || t == "Sumi" ? "Sumi" : t;
            };

            await InjectPrefsAsync();
            core.Navigate(AppHost + "index.html");
        }

        // ---------- Reading preferences ----------
        // Theme, typeface, text size and so on live in settings.ini as key=value lines. They're handed to the
        // page before any of its scripts run, so it opens already looking the way it was left.

        static SortedDictionary<string, string> LoadPrefs()
        {
            var result = new SortedDictionary<string, string>(StringComparer.Ordinal);
            try
            {
                if (!File.Exists(SettingsFile)) return result;
                foreach (var line in File.ReadAllLines(SettingsFile))
                {
                    var i = line.IndexOf('=');
                    if (i <= 0) continue;
                    var key = line.Substring(0, i).Trim();
                    var value = line.Substring(i + 1).Trim();
                    if (PrefKey.IsMatch(key) && value.Length <= 64) result[key] = value;
                }
            }
            catch { }
            return result;
        }

        void SetPref(string key, string value)
        {
            if (!PrefKey.IsMatch(key) || value.Length > 64 || value.IndexOfAny(new[] { '\r', '\n' }) >= 0) return;
            if (prefs.TryGetValue(key, out var old) && old == value) return;
            prefs[key] = value;
            try
            {
                Directory.CreateDirectory(DataDir);
                var lines = new List<string>();
                foreach (var kv in prefs) lines.Add(kv.Key + "=" + kv.Value);
                File.WriteAllLines(SettingsFile, lines);
            }
            catch { }
            _ = InjectPrefsAsync(); // so a reload of the page sees the new value too
        }

        async System.Threading.Tasks.Task InjectPrefsAsync()
        {
            var core = web.CoreWebView2;
            if (prefsScriptId != null) core.RemoveScriptToExecuteOnDocumentCreated(prefsScriptId);
            var sb = new StringBuilder("window.__sumiPrefs = {");
            var first = true;
            foreach (var kv in prefs)
            {
                if (!first) sb.Append(',');
                sb.Append(Json(kv.Key)).Append(':').Append(Json(kv.Value));
                first = false;
            }
            sb.Append("};");
            prefsScriptId = await core.AddScriptToExecuteOnDocumentCreatedAsync(sb.ToString());
        }

        // ---------- Serving the UI ----------

        static void ServeEmbedded(CoreWebView2Environment env, CoreWebView2WebResourceRequestedEventArgs e)
        {
            var uri = new Uri(e.Request.Uri);
            var name = "web/" + uri.AbsolutePath.TrimStart('/');
            var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name);
            if (stream == null)
            {
                e.Response = env.CreateWebResourceResponse(null, 404, "Not Found", "");
                return;
            }
            var mem = new MemoryStream();
            using (stream) stream.CopyTo(mem);
            mem.Position = 0;
            e.Response = env.CreateWebResourceResponse(mem, 200, "OK",
                "Content-Type: " + MimeFor(name) + "\r\nCache-Control: no-cache");
        }

        // Images and media next to the open document. Only files inside its folder are served.
        void ServeDocumentFile(CoreWebView2Environment env, CoreWebView2WebResourceRequestedEventArgs e)
        {
            try
            {
                var dir = Path.GetDirectoryName(currentPath);
                var rel = Uri.UnescapeDataString(new Uri(e.Request.Uri).AbsolutePath).TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
                var file = Path.GetFullPath(Path.Combine(dir, rel));
                var root = dir.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                if (file.StartsWith(root, StringComparison.OrdinalIgnoreCase) && File.Exists(file))
                {
                    var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    e.Response = env.CreateWebResourceResponse(stream, 200, "OK",
                        "Content-Type: " + MimeFor(file) + "\r\nCache-Control: no-cache");
                    return;
                }
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException || ex is ArgumentException || ex is NotSupportedException) { }
            e.Response = env.CreateWebResourceResponse(null, 404, "Not Found", "");
        }

        static string MimeFor(string name)
        {
            switch (Path.GetExtension(name).ToLowerInvariant())
            {
                case ".html": return "text/html; charset=utf-8";
                case ".css": return "text/css; charset=utf-8";
                case ".js": return "text/javascript; charset=utf-8";
                case ".woff2": return "font/woff2";
                case ".svg": return "image/svg+xml";
                case ".png": return "image/png";
                case ".jpg": case ".jpeg": return "image/jpeg";
                case ".gif": return "image/gif";
                case ".webp": return "image/webp";
                case ".avif": return "image/avif";
                case ".bmp": return "image/bmp";
                case ".ico": return "image/x-icon";
                case ".mp4": return "video/mp4";
                case ".webm": return "video/webm";
                case ".mp3": return "audio/mpeg";
                case ".ogg": return "audio/ogg";
                case ".wav": return "audio/wav";
                default: return "application/octet-stream";
            }
        }

        // ---------- Documents ----------

        void OpenFile(string path)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return;
            currentPath = Path.GetFullPath(path);
            SendDocument(reload: false);
        }

        void SendDocument(bool reload)
        {
            if (!pageReady || currentPath == null) return;

            string md;
            try { md = ReadShared(currentPath); }
            catch (IOException) { if (reload) reloadTimer.Start(); return; }
            catch (Exception ex) { SendToast("Couldn’t open file — " + ex.Message); return; }

            var core = web.CoreWebView2;
            var name = Path.GetFileName(currentPath);
            core.PostWebMessageAsJson(
                "{\"type\":\"doc\",\"name\":" + Json(name) +
                ",\"md\":" + Json(md) +
                ",\"reload\":" + (reload ? "true" : "false") + "}");

            Watch(currentPath);
        }

        static string ReadShared(string path)
        {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var sr = new StreamReader(fs, Encoding.UTF8, detectEncodingFromByteOrderMarks: true))
                return sr.ReadToEnd();
        }

        void Watch(string path)
        {
            var dir = Path.GetDirectoryName(path);
            var file = Path.GetFileName(path);
            if (watcher != null && watcher.Path == dir && watcher.Filter == file) return;

            watcher?.Dispose();
            watcher = new FileSystemWatcher(dir, file)
            {
                NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName,
                SynchronizingObject = this,
                EnableRaisingEvents = true,
            };
            FileSystemEventHandler changed = (s, e) => { reloadTimer.Stop(); reloadTimer.Start(); };
            watcher.Changed += changed;
            watcher.Created += changed;
            watcher.Renamed += (s, e) => { reloadTimer.Stop(); reloadTimer.Start(); };
        }

        void ShowOpenDialog()
        {
            using (var dlg = new OpenFileDialog
            {
                Title = "Open",
                Filter = "Markdown|*.md;*.markdown;*.mdown;*.mkd;*.mkdn;*.mdx;*.txt|All files|*.*",
                InitialDirectory = currentPath != null ? Path.GetDirectoryName(currentPath) : null,
            })
            {
                if (dlg.ShowDialog(this) == DialogResult.OK) OpenFile(dlg.FileName);
            }
        }

        void SendToast(string text)
        {
            if (pageReady) web.CoreWebView2.PostWebMessageAsJson("{\"type\":\"toast\",\"text\":" + Json(text) + "}");
        }

        // ---------- Messages from the page ----------

        void OnWebMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            string msg;
            try { msg = e.TryGetWebMessageAsString(); } catch { return; }
            if (msg == null) return;

            if (msg == "ready")
            {
                pageReady = true;
                if (currentPath != null) SendDocument(reload: false);
            }
            else if (msg == "open") ShowOpenDialog();
            else if (msg == "drop")
            {
                var objs = e.AdditionalObjects;
                if (objs == null) return;
                foreach (var o in objs)
                {
                    if (o is CoreWebView2File f) { OpenFile(f.Path); break; }
                }
            }
            else if (msg.StartsWith("chrome:"))
            {
                var parts = msg.Split(':');
                if (parts.Length == 3 && TryParseHex(parts[2], out var color))
                {
                    BackColor = color;
                    web.DefaultBackgroundColor = color;
                    SetCaption(parts[1] == "1", color);
                }
            }
            else if (msg.StartsWith("link:")) OpenLink(msg.Substring(5));
            else if (msg.StartsWith("pref:"))
            {
                var i = msg.IndexOf('=');
                if (i > 5) SetPref(msg.Substring(5, i - 5), msg.Substring(i + 1));
            }
        }

        void OnNavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs e)
        {
            if (e.Uri.StartsWith(AppHost, StringComparison.OrdinalIgnoreCase))
            {
                pageReady = false; // a reload re-sends "ready"
                return;
            }
            e.Cancel = true;
            OpenLink(e.Uri);
        }

        void OpenLink(string href)
        {
            if (!Uri.TryCreate(href, UriKind.Absolute, out var uri)) return;

            if (uri.Host.Equals(DocHost, StringComparison.OrdinalIgnoreCase) && currentPath != null)
            {
                var rel = Uri.UnescapeDataString(uri.AbsolutePath).TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
                var target = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(currentPath), rel));
                if (!File.Exists(target)) { SendToast("File not found"); return; }
                if (IsMarkdown(target)) OpenFile(target);
                else Shell(target);
                return;
            }

            if (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeMailto)
                Shell(uri.AbsoluteUri);
            else if (uri.IsFile && File.Exists(uri.LocalPath))
            {
                if (IsMarkdown(uri.LocalPath)) OpenFile(uri.LocalPath);
            }
        }

        static bool IsMarkdown(string path)
        {
            var ext = Path.GetExtension(path).ToLowerInvariant();
            return ext == ".md" || ext == ".markdown" || ext == ".mdown" || ext == ".mkd" || ext == ".mkdn" || ext == ".mdx";
        }

        static void Shell(string target)
        {
            try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch { }
        }

        // ---------- Window chrome ----------

        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        [DllImport("user32.dll")]
        static extern IntPtr MonitorFromPoint(Point pt, uint flags);

        [DllImport("shcore.dll")]
        static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);

        static float MonitorScale(Point pt)
        {
            try
            {
                var mon = MonitorFromPoint(pt, 2); // MONITOR_DEFAULTTONEAREST
                if (GetDpiForMonitor(mon, 0, out var x, out _) == 0 && x > 0) return x / 96f;
            }
            catch { }
            return 1f;
        }

        void SetCaption(bool dark, Color bg)
        {
            if (!IsHandleCreated) return;
            int on = dark ? 1 : 0;
            DwmSetWindowAttribute(Handle, 20, ref on, 4);            // immersive dark mode
            int caption = bg.R | (bg.G << 8) | (bg.B << 16);
            DwmSetWindowAttribute(Handle, 35, ref caption, 4);       // caption colour (Win11)
            int text = dark ? 0x00B4B8BC : 0x00707A82;
            DwmSetWindowAttribute(Handle, 36, ref text, 4);          // caption text colour
            int border = caption;
            DwmSetWindowAttribute(Handle, 34, ref border, 4);        // border colour
        }

        static bool SystemPrefersDark()
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                    return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
            }
            catch { return false; }
        }

        static bool TryParseHex(string s, out Color color)
        {
            color = Color.Empty;
            s = s.Trim().TrimStart('#');
            if (s.Length != 6 || !int.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) return false;
            color = Color.FromArgb((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
            return true;
        }

        void LoadBounds()
        {
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            float k = MonitorScale(Cursor.Position);
            var w = Math.Min((int)(940 * k), area.Width - (int)(80 * k));
            var h = Math.Min((int)(1000 * k), area.Height - (int)(80 * k));
            Bounds = new Rectangle(area.Left + (area.Width - w) / 2, area.Top + (area.Height - h) / 2, w, h);

            try
            {
                if (!File.Exists(BoundsFile)) return;
                var p = File.ReadAllText(BoundsFile).Split(',');
                var r = new Rectangle(int.Parse(p[0]), int.Parse(p[1]), int.Parse(p[2]), int.Parse(p[3]));
                foreach (var screen in Screen.AllScreens)
                {
                    if (screen.WorkingArea.IntersectsWith(r))
                    {
                        Bounds = r;
                        if (p.Length > 4 && p[4] == "1") WindowState = FormWindowState.Maximized;
                        break;
                    }
                }
            }
            catch { }
        }

        void SaveBounds()
        {
            try
            {
                var r = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
                Directory.CreateDirectory(DataDir);
                File.WriteAllText(BoundsFile, string.Join(",", r.X, r.Y, r.Width, r.Height,
                    WindowState == FormWindowState.Maximized ? "1" : "0"));
            }
            catch { }
        }

        // ---------- Helpers ----------

        static string Json(string s)
        {
            var sb = new StringBuilder(s.Length + 16);
            sb.Append('"');
            foreach (var c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20 || c == (char)0x2028 || c == (char)0x2029) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            return sb.Append('"').ToString();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                watcher?.Dispose();
                reloadTimer.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
