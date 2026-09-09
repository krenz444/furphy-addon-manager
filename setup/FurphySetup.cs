// Furphy Addon Manager Setup - one-file GUI installer bootstrapper.
// SETUP-SPEC.md section 4: exactly four responsibilities - show a splash,
// extract the embedded FurphyPayload.zip resource, launch the existing,
// unmodified install.ps1 wizard (hidden or visible per mode), relay its
// exit code. This file writes no registry key of its own, creates no
// shortcut of its own, and registers no Add/Remove Programs entry of its
// own - every bit of install logic (WoW detection, flavours, adopt scan,
// protocol registration, tray, the Installed-Apps entry) stays inside
// install.ps1, unchanged, and is reused verbatim.
//
// C# 5 / .NET Framework only: no string interpolation, no ?., no
// expression-bodied members, no async/await, no nameof, no using static.
// Anonymous delegate(...) { } blocks are fine and used throughout instead
// of lambdas with expression bodies. Compiled at release-build time via
// Add-Type + csc.exe (see setup\build-setup.ps1) - keep this file self
// contained and free of anything beyond System.*, System.Windows.Forms,
// System.Drawing and System.IO.Compression.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// SETUP-SPEC.md section 4.8: setup\build-setup.ps1 substitutes the token
// below for the real VERSION file content (plus a literal ".0" fourth
// part for the two Assembly*Version attributes) before this source text
// is ever handed to Add-Type - a compiled assembly cannot re-open an
// external VERSION file at its own runtime, so this is a build-time-only
// step. AssemblyProduct/AssemblyTitle/AssemblyCompany/AssemblyDescription
// are set too, so Explorer's own Properties > Details tab shows a real
// name instead of a blank one.
[assembly: AssemblyVersion(FurphySetupApp.SetupVersionInfo.Version + ".0")]
[assembly: AssemblyFileVersion(FurphySetupApp.SetupVersionInfo.Version + ".0")]
[assembly: AssemblyInformationalVersion(FurphySetupApp.SetupVersionInfo.Version)]
[assembly: AssemblyProduct("Furphy Addon Manager")]
[assembly: AssemblyTitle("Furphy Addon Manager Setup")]
[assembly: AssemblyCompany("krenz444")]
[assembly: AssemblyDescription("Installs Furphy Addon Manager. Extracts a bundled copy of the app; makes no network connections of its own.")]

namespace FurphySetupApp
{
    // Kept as its own tiny class (rather than a bare const on Program) so
    // the assembly-attribute lines above - which must appear before any
    // namespace member is defined in this same compilation unit - have a
    // fully-qualified, unambiguous constant to reference regardless of
    // declaration order elsewhere in the file.
    internal static class SetupVersionInfo
    {
        public const string Version = "__FURPHY_SETUP_VERSION__";
    }

    internal static class Program
    {
        // Doubles as the FindWindow target for second-instance activation
        // (section 4.5) and as every dialog's MessageBox caption (4.3) -
        // one literal, one source of truth.
        private const string WindowTitle = "Furphy Addon Manager Setup";

        // No "Global\" prefix - matches host\FurphyHost.cs's own
        // ResolveMutexName convention for its tray single-instance mutex.
        // Section 4.2 step 3: FurphySetup has no port of its own to scope
        // by (it runs before any install exists to read a port from), so
        // it mirrors this codebase's FURPHY_TEST_* environment-variable
        // seam instead - a real player's install never sets this variable
        // and gets the one true global name, which is exactly correct (a
        // player really should only ever have one Setup.exe running at a
        // time); a test sets it to something test-run-unique so it can
        // never collide with a real interactive Setup.exe or with another
        // concurrently-running copy of the same test.
        private const string MutexBaseName = "FurphyAddonManagerSetup";
        private const string MutexSuffixEnvVar = "FURPHY_TEST_SETUP_MUTEX_SUFFIX";

        private const string PayloadResourceName = "FurphyPayload.zip";
        private const string EnvLaunchedBySetup = "FURPHY_INSTALL_LAUNCHED_BY_SETUP";

        [STAThread]
        private static int Main(string[] args)
        {
            // Literal ordering constraint (section 4.1): must run before
            // any Form/Control is constructed anywhere below.
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            TryCleanupStaleTempFolders();

            bool silent;
            string[] passThroughArgs;
            ParseArgs(args, out silent, out passThroughArgs);

            string mutexName = ResolveMutexName();
            bool createdNew = false;
            Mutex mutex = null;
            try
            {
                mutex = new Mutex(true, mutexName, out createdNew);
            }
            catch
            {
                mutex = null;
                createdNew = false;
            }

            try
            {
                if (!createdNew)
                {
                    return HandleSecondInstance(silent);
                }
                return RunSetup(silent, passThroughArgs);
            }
            finally
            {
                if (mutex != null)
                {
                    if (createdNew)
                    {
                        try { mutex.ReleaseMutex(); } catch { }
                    }
                    try { mutex.Close(); } catch { }
                }
            }
        }

        private static string ResolveMutexName()
        {
            string suffix = null;
            try { suffix = Environment.GetEnvironmentVariable(MutexSuffixEnvVar); } catch { }
            if (!string.IsNullOrEmpty(suffix))
            {
                return MutexBaseName + "." + suffix;
            }
            return MutexBaseName;
        }

        // Only the literal token "/S" (case-insensitive), as the FIRST
        // argument, triggers silent mode (section 4.4) - no /SILENT,
        // -S or /VERYSILENT alias. Everything after it is captured
        // verbatim, in order, and forwarded after "-Console -Quiet".
        private static void ParseArgs(string[] args, out bool silent, out string[] passThroughArgs)
        {
            silent = false;
            passThroughArgs = new string[0];
            if (args != null && args.Length > 0 && string.Equals(args[0], "/S", StringComparison.OrdinalIgnoreCase))
            {
                silent = true;
                if (args.Length > 1)
                {
                    passThroughArgs = new string[args.Length - 1];
                    Array.Copy(args, 1, passThroughArgs, 0, args.Length - 1);
                }
            }
        }

        // Section 4.2 step 2: a light, best-effort backstop for the rare
        // crash/kill that skips the normal per-run cleanup below - nothing
        // else in this project proactively sweeps stray %TEMP% folders
        // either. Never allowed to fail the run it is called from.
        private static void TryCleanupStaleTempFolders()
        {
            try
            {
                string tempDir = Path.GetTempPath();
                string[] dirs = Directory.GetDirectories(tempDir, "FurphySetup-*");
                DateTime cutoffUtc = DateTime.UtcNow.AddHours(-24);
                for (int i = 0; i < dirs.Length; i++)
                {
                    try
                    {
                        DateTime createdUtc = Directory.GetCreationTimeUtc(dirs[i]);
                        if (createdUtc < cutoffUtc)
                        {
                            Directory.Delete(dirs[i], true);
                        }
                    }
                    catch { }
                }
            }
            catch { }
        }

        // Section 4.5 / 4.3's dialog table. Silent (/S) never shows a
        // dialog - it exits 4, a code distinct from the interactive case's
        // exit 1, so a scripted deployment can tell "another Setup was
        // already running" apart from "a real failure" without parsing
        // text.
        private static int HandleSecondInstance(bool silent)
        {
            if (silent)
            {
                return 4;
            }
            IntPtr hwnd = SafeFindWindow(WindowTitle);
            if (hwnd != IntPtr.Zero)
            {
                try { SetForegroundWindow(hwnd); } catch { }
                return 1;
            }
            ShowErrorDialog("Furphy Setup is already running.");
            return 1;
        }

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        private static IntPtr SafeFindWindow(string title)
        {
            try { return FindWindow(null, title); }
            catch { return IntPtr.Zero; }
        }

        // The whole state machine, section 4.2 steps 5-12. Runs on the
        // main (STA) thread with periodic Application.DoEvents() calls
        // rather than a second thread/runspace - the same "fewest moving
        // parts" choice the wizard's own progress pump already made.
        private static int RunSetup(bool silent, string[] passThroughArgs)
        {
            SplashForm splash = null;
            string extractDir = null;
            bool sawChildWindow = false;
            try
            {
                if (!silent)
                {
                    splash = new SplashForm();
                    splash.Show();
                    Application.DoEvents();
                }

                try
                {
                    extractDir = ExtractPayload();
                }
                catch
                {
                    if (!silent)
                    {
                        ShowErrorDialog("Furphy Setup could not prepare its installer files. Make sure you have enough free disk space and try again.");
                    }
                    return 5;
                }

                if (!silent) { Application.DoEvents(); }

                Process child;
                try
                {
                    child = LaunchInstall(extractDir, silent, passThroughArgs);
                }
                catch (Win32Exception)
                {
                    if (!silent)
                    {
                        ShowErrorDialog("Furphy Setup could not find PowerShell, which Windows normally includes. Please contact support.");
                    }
                    return 3;
                }

                using (child)
                {
                    if (silent)
                    {
                        child.WaitForExit();
                    }
                    else
                    {
                        // Section 4.2 step 8: poll for up to ~5 seconds,
                        // hiding the splash the instant a window appears
                        // or after the timeout, whichever comes first -
                        // then keep polling at the same interval for the
                        // rest of the run (cheap - the same Process.
                        // Refresh() call already running on a timer) so
                        // sawChildWindow correctly latches true even if
                        // the wizard's window only appears well after the
                        // 5-second ceiling on a slow machine.
                        DateTime pollStartUtc = DateTime.UtcNow;
                        while (!child.HasExited)
                        {
                            try { child.Refresh(); } catch { }
                            IntPtr mainWindow = IntPtr.Zero;
                            try { mainWindow = child.MainWindowHandle; } catch { }
                            if (mainWindow != IntPtr.Zero)
                            {
                                sawChildWindow = true;
                                if (splash != null && splash.Visible) { splash.Hide(); }
                            }
                            else if (splash != null && splash.Visible &&
                                     (DateTime.UtcNow - pollStartUtc).TotalMilliseconds >= 5000)
                            {
                                splash.Hide();
                            }
                            Application.DoEvents();
                            Thread.Sleep(150);
                        }
                        if (!sawChildWindow)
                        {
                            try
                            {
                                child.Refresh();
                                if (child.MainWindowHandle != IntPtr.Zero) { sawChildWindow = true; }
                            }
                            catch { }
                        }
                    }

                    int exitCode = child.ExitCode;

                    if (!silent)
                    {
                        if (exitCode == 0 && !sawChildWindow)
                        {
                            // Section 4.2 step 11 / section 10's new row:
                            // Form construction failed but WoW was found -
                            // install.ps1 falls straight through to
                            // Invoke-FurphyInstallSteps and exits 0 with no
                            // console and no wizard ever shown. Without
                            // this, a real, successful install would leave
                            // a Setup-launched player looking at nothing.
                            MessageBox.Show(
                                "Furphy Addon Manager is installed. Look for the 'Furphy Addon Manager' shortcut on your Desktop to open it.",
                                WindowTitle, MessageBoxButtons.OK, MessageBoxIcon.Information);
                        }
                        else if (exitCode != 0 && exitCode != 2)
                        {
                            // Exit code 2 (WoW not found) is deliberately
                            // excluded here - in the interactive path it
                            // essentially never reaches this generic
                            // handler, because the wizard's own Browse-
                            // folder screen is the real recovery UI for
                            // that case.
                            ShowErrorDialog(string.Format(CultureInfo.InvariantCulture,
                                "Setup did not finish successfully (code {0}). Nothing may have been installed. Try running the downloaded file again, or ask for help and mention this code.",
                                exitCode));
                        }
                    }

                    return exitCode;
                }
            }
            finally
            {
                if (splash != null)
                {
                    try { splash.Close(); } catch { }
                    try { splash.Dispose(); } catch { }
                }
                if (extractDir != null)
                {
                    try { if (Directory.Exists(extractDir)) { Directory.Delete(extractDir, true); } } catch { }
                }
            }
        }

        // Section 4.2 step 6. Writes the embedded resource to a small
        // temp .zip first, then extracts it with System.IO.Compression.
        // ZipFile.ExtractToDirectory - any failure (missing resource,
        // disk full, a corrupt/truncated embedded zip) is left to
        // propagate to RunSetup's own catch, which maps it uniformly to
        // exit 5. On failure, best-effort deletes whatever partial
        // extraction folder may already exist so a corrupt-build test run
        // does not strand it past the 24-hour sweep.
        private static string ExtractPayload()
        {
            string dirName = "FurphySetup-" + SetupVersionInfo.Version + "-" + Guid.NewGuid().ToString("N").Substring(0, 8);
            string extractDir = Path.Combine(Path.GetTempPath(), dirName);
            string tempZipPath = Path.Combine(Path.GetTempPath(), dirName + "-payload.zip");

            try
            {
                Assembly asm = Assembly.GetExecutingAssembly();
                using (Stream resourceStream = asm.GetManifestResourceStream(PayloadResourceName))
                {
                    if (resourceStream == null)
                    {
                        throw new InvalidOperationException("Embedded payload resource not found: " + PayloadResourceName);
                    }
                    using (FileStream fs = new FileStream(tempZipPath, FileMode.Create, FileAccess.Write))
                    {
                        resourceStream.CopyTo(fs);
                    }
                }
                Directory.CreateDirectory(extractDir);
                ZipFile.ExtractToDirectory(tempZipPath, extractDir);
                return extractDir;
            }
            catch
            {
                try { if (Directory.Exists(extractDir)) { Directory.Delete(extractDir, true); } } catch { }
                throw;
            }
            finally
            {
                try { if (File.Exists(tempZipPath)) { File.Delete(tempZipPath); } } catch { }
            }
        }

        // Section 5.1/5.2: the exact child command line. -WowPath is never
        // added here (auto-detection runs, identical to a plain "Install
        // Furphy.cmd" double-click) - only the raw pass-through arguments
        // already captured verbatim from Setup's own command line ever
        // add one, on the /S path.
        private static Process LaunchInstall(string extractDir, bool silent, string[] passThroughArgs)
        {
            string scriptPath = Path.Combine(extractDir, "install.ps1");
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = BuildInstallArguments(scriptPath, silent, passThroughArgs);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.WorkingDirectory = extractDir;
            psi.EnvironmentVariables[EnvLaunchedBySetup] = "1";
            return Process.Start(psi);
        }

        private static string BuildInstallArguments(string scriptPath, bool silent, string[] passThroughArgs)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ");
            sb.Append(QuoteArg(scriptPath));
            if (silent)
            {
                sb.Append(" -Console -Quiet");
                for (int i = 0; i < passThroughArgs.Length; i++)
                {
                    sb.Append(' ');
                    sb.Append(QuoteArg(passThroughArgs[i]));
                }
            }
            return sb.ToString();
        }

        // Sufficient quoting for this project's own argument shapes
        // (paths and install.ps1 flag values): wrap in double quotes,
        // escape any embedded double quote. Every pass-through token
        // becomes its own quoted argument in the rebuilt command line,
        // exactly preserving the split the OS already gave Setup's own
        // args[] array.
        private static string QuoteArg(string value)
        {
            if (value == null) { value = string.Empty; }
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static void ShowErrorDialog(string text)
        {
            try
            {
                MessageBox.Show(text, WindowTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            catch { }
        }

        // Section 4.1: the transient splash window. No buttons - there is
        // nothing for a player to click on it.
        private sealed class SplashForm : Form
        {
            public SplashForm()
            {
                FormBorderStyle = FormBorderStyle.FixedDialog;
                MaximizeBox = false;
                MinimizeBox = false;
                ShowInTaskbar = true;
                AutoScaleMode = AutoScaleMode.Font;
                ClientSize = new Size(360, 140);
                StartPosition = FormStartPosition.CenterScreen;
                Text = WindowTitle;
                try
                {
                    Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                }
                catch { }

                Label label = new Label();
                label.AutoSize = false;
                label.Text = "Preparing Furphy Addon Manager Setup...";
                label.TextAlign = ContentAlignment.MiddleCenter;
                label.Location = new Point(20, 30);
                label.Size = new Size(320, 40);
                Controls.Add(label);

                ProgressBar progress = new ProgressBar();
                progress.Style = ProgressBarStyle.Marquee;
                progress.MarqueeAnimationSpeed = 30;
                progress.Location = new Point(20, 80);
                progress.Size = new Size(320, 20);
                Controls.Add(progress);
            }
        }
    }
}
