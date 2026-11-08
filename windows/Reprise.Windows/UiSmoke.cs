using System.Drawing.Imaging;
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
                window.Show(); Application.DoEvents();
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
            File.WriteAllText(Path.Combine(output, "smoke-result.txt"), $"UI rendered; local OCR recognized the resume command; app version {NativeServices.Version}.");
        }
        finally { if (Directory.Exists(temporary)) Directory.Delete(temporary, true); }
    }
}
