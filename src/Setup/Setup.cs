using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace SumiSetup
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            if (args.Any(a => a.Equals("/uninstall", StringComparison.OrdinalIgnoreCase)))
            {
                Installer.Uninstall(quiet: args.Any(a => a.Equals("/quiet", StringComparison.OrdinalIgnoreCase)));
                return;
            }
            if (args.Any(a => a.Equals("/quiet", StringComparison.OrdinalIgnoreCase)))
            {
                Installer.Install(associate: args.Any(a => a.Equals("/associate", StringComparison.OrdinalIgnoreCase)), desktop: false);
                return;
            }
            Application.Run(new SetupForm());
        }
    }

    static class Installer
    {
        public const string AppName = "Sumi";
        public const string Version = "1.1.0";
        const string ProgId = "Sumi.Markdown";
        const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Sumi";
        static readonly string[] Extensions = { ".md", ".markdown", ".mdown", ".mkd", ".mkdn" };

        public static readonly string InstallDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Sumi");
        public static string ExePath => Path.Combine(InstallDir, "Sumi.exe");

        static string StartMenuLink => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Sumi.lnk");
        static string DesktopLink => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Sumi.lnk");

        public static bool CloseRunning(bool quiet)
        {
            var running = Process.GetProcessesByName("Sumi")
                .Where(p => { try { return p.MainModule.FileName.StartsWith(InstallDir, StringComparison.OrdinalIgnoreCase); } catch { return false; } })
                .ToList();
            if (running.Count == 0) return true;
            if (!quiet && MessageBox.Show("Sumi is open. Close it to continue?", "Sumi",
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK)
                return false;
            foreach (var p in running)
            {
                try { p.CloseMainWindow(); if (!p.WaitForExit(2500)) p.Kill(); p.WaitForExit(2000); } catch { }
            }
            return true;
        }

        public static void Install(bool associate, bool desktop)
        {
            Directory.CreateDirectory(InstallDir);

            var asm = Assembly.GetExecutingAssembly();
            long total = 0;
            foreach (var res in asm.GetManifestResourceNames().Where(n => n.StartsWith("payload/")))
            {
                var target = Path.Combine(InstallDir, res.Substring("payload/".Length));
                using (var src = asm.GetManifestResourceStream(res))
                using (var dst = File.Create(target))
                {
                    src.CopyTo(dst);
                    total += dst.Length;
                }
            }

            var self = Assembly.GetExecutingAssembly().Location;
            var uninstaller = Path.Combine(InstallDir, "Uninstall.exe");
            if (!string.Equals(self, uninstaller, StringComparison.OrdinalIgnoreCase))
                File.Copy(self, uninstaller, overwrite: true);
            total += new FileInfo(uninstaller).Length;

            CreateShortcut(StartMenuLink);
            if (desktop) CreateShortcut(DesktopLink);

            using (var k = Registry.CurrentUser.CreateSubKey(UninstallKey))
            {
                k.SetValue("DisplayName", AppName);
                k.SetValue("DisplayVersion", Version);
                k.SetValue("Publisher", AppName);
                k.SetValue("DisplayIcon", ExePath + ",0");
                k.SetValue("InstallLocation", InstallDir);
                k.SetValue("UninstallString", "\"" + uninstaller + "\" /uninstall");
                k.SetValue("QuietUninstallString", "\"" + uninstaller + "\" /uninstall /quiet");
                k.SetValue("EstimatedSize", (int)(total / 1024), RegistryValueKind.DWord);
                k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }

            RegisterApplication(associate);
        }

        static void RegisterApplication(bool associate)
        {
            var command = "\"" + ExePath + "\" \"%1\"";

            using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Classes\" + ProgId))
            {
                k.SetValue("", "Markdown document");
                k.SetValue("FriendlyTypeName", "Markdown document");
                using (var icon = k.CreateSubKey("DefaultIcon")) icon.SetValue("", ExePath + ",0");
                using (var cmd = k.CreateSubKey(@"shell\open\command")) cmd.SetValue("", command);
            }

            using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Classes\Applications\Sumi.exe"))
            {
                k.SetValue("FriendlyAppName", AppName);
                using (var cmd = k.CreateSubKey(@"shell\open\command")) cmd.SetValue("", command);
                using (var types = k.CreateSubKey("SupportedTypes"))
                    foreach (var ext in Extensions) types.SetValue(ext, "");
            }

            // Capabilities make Sumi show up in Settings › Default apps.
            using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Sumi\Capabilities"))
            {
                k.SetValue("ApplicationName", AppName);
                k.SetValue("ApplicationDescription", "A quiet Markdown reader");
                k.SetValue("ApplicationIcon", ExePath + ",0");
                using (var fa = k.CreateSubKey("FileAssociations"))
                    foreach (var ext in Extensions) fa.SetValue(ext, ProgId);
            }
            using (var k = Registry.CurrentUser.CreateSubKey(@"Software\RegisteredApplications"))
                k.SetValue(AppName, @"Software\Sumi\Capabilities");

            foreach (var ext in Extensions)
            {
                using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Classes\" + ext))
                {
                    using (var ow = k.CreateSubKey("OpenWithProgids")) ow.SetValue(ProgId, new byte[0], RegistryValueKind.None);
                    var previous = k.GetValue("") as string;
                    if (associate && previous != ProgId)
                    {
                        if (!string.IsNullOrEmpty(previous)) k.SetValue("Sumi.Previous", previous);
                        k.SetValue("", ProgId);
                    }
                }
            }

            SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); // SHCNE_ASSOCCHANGED
        }

        static void CreateShortcut(string linkPath)
        {
            var shellType = Type.GetTypeFromProgID("WScript.Shell");
            dynamic shell = Activator.CreateInstance(shellType);
            try
            {
                dynamic link = shell.CreateShortcut(linkPath);
                link.TargetPath = ExePath;
                link.WorkingDirectory = InstallDir;
                link.IconLocation = ExePath + ",0";
                link.Description = "A quiet Markdown reader";
                link.Save();
                Marshal.FinalReleaseComObject(link);
            }
            finally { Marshal.FinalReleaseComObject(shell); }
        }

        public static void Uninstall(bool quiet)
        {
            if (!quiet && MessageBox.Show("Remove Sumi from this PC?", "Sumi",
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK)
                return;
            if (!CloseRunning(quiet)) return;

            TryDelete(StartMenuLink);
            TryDelete(DesktopLink);

            var hkcu = Registry.CurrentUser;
            hkcu.DeleteSubKeyTree(UninstallKey, false);
            hkcu.DeleteSubKeyTree(@"Software\Classes\" + ProgId, false);
            hkcu.DeleteSubKeyTree(@"Software\Classes\Applications\Sumi.exe", false);
            hkcu.DeleteSubKeyTree(@"Software\Sumi", false);
            using (var k = hkcu.OpenSubKey(@"Software\RegisteredApplications", true)) k?.DeleteValue(AppName, false);
            foreach (var ext in Extensions)
            {
                using (var k = hkcu.OpenSubKey(@"Software\Classes\" + ext, true))
                {
                    if (k == null) continue;
                    if ((k.GetValue("") as string) == ProgId)
                    {
                        if (k.GetValue("Sumi.Previous") is string previous) k.SetValue("", previous);
                        else k.DeleteValue("", false);
                    }
                    k.DeleteValue("Sumi.Previous", false);
                    using (var ow = k.OpenSubKey("OpenWithProgids", true)) ow?.DeleteValue(ProgId, false);
                }
            }
            SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero);

            // Settings and the WebView cache.
            try { Directory.Delete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sumi"), true); } catch { }

            // The uninstaller lives in the folder it removes, so let a detached shell finish the job.
            foreach (var f in Directory.Exists(InstallDir) ? Directory.GetFiles(InstallDir) : new string[0])
                if (!f.EndsWith("Uninstall.exe", StringComparison.OrdinalIgnoreCase)) TryDelete(f);
            Process.Start(new ProcessStartInfo("cmd.exe",
                "/c ping 127.0.0.1 -n 3 > nul & rmdir /s /q \"" + InstallDir + "\"")
            { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden });

            if (!quiet) MessageBox.Show("Sumi has been removed.", "Sumi", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }

        [DllImport("shell32.dll")]
        static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
    }

    // ---------- A small, quiet installer window ----------

    sealed class SetupForm : Form
    {
        static readonly Color Paper = Color.FromArgb(0xfa, 0xf8, 0xf4);
        static readonly Color Ink = Color.FromArgb(0x2c, 0x2b, 0x28);
        static readonly Color Muted = Color.FromArgb(0x9a, 0x95, 0x8b);

        readonly PillButton action;
        readonly CheckBox associate, desktop;
        readonly Icon appIcon;
        readonly float k;
        string status = "";
        bool installed;

        public SetupForm()
        {
            using (var screen = Graphics.FromHwnd(IntPtr.Zero)) k = screen.DpiX / 96f; // system DPI (see setup.manifest)
            Text = "Install Sumi";
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Paper;
            ClientSize = new Size(S(440), S(400));
            DoubleBuffered = true;
            Font = new Font("Segoe UI", 9.5f);

            appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            Icon = appIcon;

            associate = MakeCheck("Open Markdown files with Sumi", S(236));
            desktop = MakeCheck("Add a desktop shortcut", S(264));
            associate.Checked = true;

            action = new PillButton
            {
                Text = "Install",
                Size = new Size(S(168), S(42)),
                Location = new Point((ClientSize.Width - S(168)) / 2, S(316)),
                Font = new Font("Segoe UI Semibold", 10f),
            };
            action.Click += OnAction;
            Controls.Add(action);
            AcceptButton = null;
        }

        int S(int v) => (int)Math.Round(v * k);

        CheckBox MakeCheck(string text, int y)
        {
            var c = new CheckBox
            {
                Text = text,
                AutoSize = true,
                ForeColor = Color.FromArgb(0x4a, 0x48, 0x42),
                BackColor = Paper,
                Cursor = Cursors.Hand,
            };
            Controls.Add(c);
            c.Location = new Point((ClientSize.Width - S(236)) / 2, y);
            return c;
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            int caption = Paper.R | (Paper.G << 8) | (Paper.B << 16);
            DwmSetWindowAttribute(Handle, 35, ref caption, 4);
            DwmSetWindowAttribute(Handle, 34, ref caption, 4);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

            int iconSize = S(84);
            using (var png = Assembly.GetExecutingAssembly().GetManifestResourceStream("art/icon.png"))
            using (var bmp = new Bitmap(png))
                g.DrawImage(bmp, new Rectangle((ClientSize.Width - iconSize) / 2, S(34), iconSize, iconSize));

            var center = new StringFormat { Alignment = StringAlignment.Center };
            using (var title = new Font(FontExists("Segoe UI Variable Display") ? "Segoe UI Variable Display" : "Segoe UI Light", 22f, FontStyle.Regular))
            using (var ink = new SolidBrush(Ink))
                g.DrawString("Sumi", title, ink, new RectangleF(0, S(132), ClientSize.Width, S(50)), center);

            using (var sub = new Font("Georgia", 10.5f, FontStyle.Italic))
            using (var muted = new SolidBrush(Muted))
                g.DrawString("A quiet place to read Markdown.", sub, muted, new RectangleF(0, S(182), ClientSize.Width, S(24)), center);

            if (status.Length > 0)
                using (var small = new Font("Segoe UI", 8.5f))
                using (var muted = new SolidBrush(Muted))
                    g.DrawString(status, small, muted, new RectangleF(0, S(368), ClientSize.Width, S(20)), center);
        }

        static bool FontExists(string name)
        {
            using (var f = new Font(name, 10f)) return f.Name.Equals(name, StringComparison.OrdinalIgnoreCase);
        }

        void OnAction(object sender, EventArgs e)
        {
            if (installed)
            {
                Process.Start(new ProcessStartInfo(Installer.ExePath) { UseShellExecute = true });
                Close();
                return;
            }
            if (!Installer.CloseRunning(quiet: false)) return;

            action.Enabled = false;
            action.Text = "Installing…";
            status = "";
            Refresh();
            try
            {
                Installer.Install(associate.Checked, desktop.Checked);
                installed = true;
                action.Text = "Open Sumi";
                associate.Visible = desktop.Visible = false;
                status = "Installed. Find it in the Start menu any time.";
            }
            catch (Exception ex)
            {
                action.Text = "Try again";
                status = "Couldn’t install — " + ex.Message;
            }
            action.Enabled = true;
            Invalidate();
        }

        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    }

    sealed class PillButton : Control
    {
        bool hover, down;

        public PillButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            Cursor = Cursors.Hand;
            BackColor = Color.Transparent;
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            g.Clear(Parent?.BackColor ?? Color.White);

            var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            float r = rect.Height;
            using (var path = new GraphicsPath())
            {
                path.AddArc(rect.X, rect.Y, r, r, 90, 180);
                path.AddArc(rect.Right - r, rect.Y, r, r, 270, 180);
                path.CloseFigure();
                var fill = !Enabled ? Color.FromArgb(0x8a, 0x86, 0x7e)
                         : down ? Color.FromArgb(0x15, 0x15, 0x14)
                         : hover ? Color.FromArgb(0x3b, 0x39, 0x35)
                         : Color.FromArgb(0x2c, 0x2b, 0x28);
                using (var b = new SolidBrush(fill)) g.FillPath(b, path);
            }
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, Color.FromArgb(0xfa, 0xf8, 0xf4),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }
}
