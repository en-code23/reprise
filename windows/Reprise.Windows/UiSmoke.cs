using System.Drawing.Imaging;
using System.Diagnostics;
using System.Text;
using Reprise.Core;

namespace Reprise.Windows;

internal static class UiSmoke
{
    internal static void Run(string output)
    {
        Directory.CreateDirectory(output);
        var temporary = Path.Combine(Path.GetTempPath(), "RepriseSmoke-" + Guid.NewGuid());
        try
        {
            var store = new SessionStore(temporary);
            foreach (var (project, folder) in new[] { ("Billing portal", @"C:\Projects\billing-portal"), ("Studio website", @"C:\Projects\studio"), ("Search service", @"C:\Projects\search") })
                foreach (var model in new[] { "codex", "claude", "grok" })
                    store.Upsert(new Session { Project = project, ProjectDirectory = folder, Model = model, Command = Commands.Build(model, Guid.NewGuid().ToString()), Note = "Continue the payment retry timeline. Tests are passing; next up is the failure state.", DetectedAutomatically = true, DetectedOrigin = model == "grok" ? "Unknown" : "CLI" });
            using (var window = new LibraryWindow(store, true))
            {
                window.Show();
                for (var i = 0; i < 10; i++) { Application.DoEvents(); Thread.Sleep(25); }
                File.WriteAllText(Path.Combine(output, "layout.txt"), window.LayoutReport());
                window.ValidateHorizontalLayout();
                using var image = new Bitmap(window.Width, window.Height); window.DrawToBitmap(image, new Rectangle(Point.Empty, window.Size));
                image.Save(Path.Combine(output, "windows-library.png"), ImageFormat.Png);
                window.Hide();
            }
            using (var capture = new CaptureWindow(store.Sessions[0]))
            {
                capture.Show(); Application.DoEvents();
                using var image = new Bitmap(capture.Width, capture.Height); capture.DrawToBitmap(image, new Rectangle(Point.Empty, capture.Size));
                image.Save(Path.Combine(output, "windows-capture.png"), ImageFormat.Png); capture.Hide();
            }
            var screenshot = Path.Combine(output, "ocr-fixture.png");
            using (var image = new Bitmap(1800, 260))
            using (var graphics = Graphics.FromImage(image))
            using (var font = new Font("Consolas", 27))
            {
                graphics.Clear(Color.White); graphics.DrawString("codex resume 8d4b841b-1552-4b11-9a32-33b9205b836a", font, Brushes.Black, 30, 80);
                image.Save(screenshot, ImageFormat.Png);
            }
            var text = NativeServices.ReadScreenshot(screenshot).GetAwaiter().GetResult();
            if (!Commands.Parse(text).Command.StartsWith("codex resume ", StringComparison.Ordinal)) throw new InvalidOperationException("OCR did not recognize the test resume command: " + text);
            var testFolder = Path.Combine(temporary, "Project's; folder"); Directory.CreateDirectory(testFolder);
            var shim = Path.Combine(temporary, "codex.cmd");
            File.WriteAllText(shim, "@echo off\r\necho %1 %2>\"%~dp0arguments.txt\"\r\ncd >\"%~dp0directory.txt\"\r\n");
            var testSession = new Session { ProjectDirectory = testFolder, Command = "codex resume 8d4b841b-1552-4b11-9a32-33b9205b836a" };
            var shell = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe")) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(Commands.PowerShellScript(testSession, shim))) }) shell.ArgumentList.Add(argument);
            using var process = Process.Start(shell)!;
            if (!process.WaitForExit(30000) || process.ExitCode != 0) throw new InvalidOperationException("PowerShell command test failed.");
            if (File.ReadAllText(Path.Combine(temporary, "directory.txt")).Trim() != testFolder || File.ReadAllText(Path.Combine(temporary, "arguments.txt")).Trim() != "resume 8d4b841b-1552-4b11-9a32-33b9205b836a") throw new InvalidOperationException("Project directory or command arguments were changed by shell parsing.");
            File.WriteAllText(Path.Combine(output, "smoke-result.txt"), $"UI rendered; local OCR recognized the resume command; PowerShell preserved the folder and arguments; app version {NativeServices.Version}.");
        }
        finally { if (Directory.Exists(temporary)) Directory.Delete(temporary, true); }
    }
}
