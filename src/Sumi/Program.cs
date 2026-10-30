using System;
using System.Diagnostics;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;

namespace Sumi
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                CoreWebView2Environment.GetAvailableBrowserVersionString();
            }
            catch (WebView2RuntimeNotFoundException)
            {
                var answer = MessageBox.Show(
                    "Sumi needs the Microsoft Edge WebView2 Runtime, which is not installed on this PC.\n\nOpen the download page now?",
                    "Sumi", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
                if (answer == DialogResult.Yes)
                    Process.Start("https://go.microsoft.com/fwlink/p/?LinkId=2124703");
                return;
            }

            string path = args.Length > 0 ? args[0] : null;
            Application.Run(new MainForm(path));
        }
    }
}
