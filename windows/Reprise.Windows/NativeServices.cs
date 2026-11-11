using System.Diagnostics;
using System.Reflection;
using System.Text;
using Reprise.Core;
using Tesseract;
using Velopack;
using Velopack.Sources;

namespace Reprise.Windows;

internal static class NativeServices
{
    internal static string Version => Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "1.9.1";
    internal static readonly string[] Terminals = ["Windows Terminal", "PowerShell", "Command Prompt"];
    internal static readonly string[] Origins = ["Unknown", "Desktop app", "CLI", "IDE extension", "SDK / automation", "Multiple clients"];
    internal static Icon LoadIcon()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Reprise.Icon")!;
        using var icon = new Icon(stream); return (Icon)icon.Clone();
    }
    internal static string? FindExecutable(string name)
    {
        var paths = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps"));
        return paths.Where(p => !string.IsNullOrWhiteSpace(p)).Select(p => Path.Combine(p.Trim('"'), name)).FirstOrDefault(File.Exists);
    }
    internal static string? DefaultEditor() => new[] {
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Microsoft VS Code", "Code.exe"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Microsoft VS Code", "Code.exe"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "cursor", "Cursor.exe"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Windsurf", "Windsurf.exe")
    }.FirstOrDefault(File.Exists);
    internal static string EditorName(string? path) => string.IsNullOrEmpty(path) ? "Choose editor…" : Path.GetFileNameWithoutExtension(path).Equals("Code", StringComparison.OrdinalIgnoreCase) ? "VS Code" : Path.GetFileNameWithoutExtension(path);
    internal static string RequireDirectory(Session session)
    {
        if (!ProjectPaths.IsWindowsAbsolute(session.ProjectDirectory) || !Directory.Exists(session.ProjectDirectory))
            throw new InvalidOperationException("The Windows project folder is missing. Use Edit details to choose its current location.");
        return Path.GetFullPath(session.ProjectDirectory!);
    }
    internal static void Resume(Session session, string terminal, string[]? managed = null, SelectionDecision? decision = null)
    {
        if (session.HasLocalHistory == false) throw new InvalidOperationException("This conversation’s history is not on this PC. Open it in Codex first, then sync Reprise.");
        var directory = RequireDirectory(session);
        if (decision?.Blocked == true) throw new InvalidOperationException(string.Join(" ", decision.Reasons));
        var arguments = managed ?? [.. Commands.ValidatedArguments(session.Command), .. decision?.Arguments(session.Model) ?? []];
        var executable = managed != null ? arguments[0] : FindExecutable(arguments[0] + ".exe") ?? FindExecutable(arguments[0] + ".cmd")
            ?? throw new InvalidOperationException($"{arguments[0]} was not found on your Windows PATH. Install and sign in to its Windows CLI first.");
        var script = "$ErrorActionPreference = 'Stop'; Set-Location -LiteralPath " + Commands.PowerShellLiteral(directory) + "; & " + Commands.PowerShellLiteral(executable) + " " + string.Join(" ", arguments.Skip(1).Select(Commands.PowerShellLiteral));
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        ProcessStartInfo info;
        if (terminal == "Command Prompt" && managed == null && decision == null)
        {
            info = new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"));
            foreach (var argument in new[] { "/D", "/K", string.Join(" ", arguments) }) info.ArgumentList.Add(argument);
        }
        else
        {
            var shell = FindExecutable("pwsh.exe") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            if (terminal == "Command Prompt")
            {
                info = new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"));
                foreach (var argument in new[] { "/D", "/K", $"powershell.exe -NoProfile -EncodedCommand {encoded}" }) info.ArgumentList.Add(argument);
            }
            else if (terminal == "Windows Terminal")
            {
                info = new(FindExecutable("wt.exe") ?? throw new InvalidOperationException("Windows Terminal was not found. Install it or choose PowerShell in Settings."));
                foreach (var argument in new[] { "-w", "new", "new-tab", shell, "-NoExit", "-EncodedCommand", encoded }) info.ArgumentList.Add(argument);
            }
            else
            {
                info = new(shell);
                foreach (var argument in new[] { "-NoExit", "-EncodedCommand", encoded }) info.ArgumentList.Add(argument);
            }
        }
        info.WorkingDirectory = directory; info.UseShellExecute = false;
        info.Environment["NoDefaultCurrentDirectoryInExePath"] = "1";
        Process.Start(info)?.Dispose();
    }
    internal static void OpenEditor(Session session, string? editor, string? resumeCommand = null)
    {
        var directory = RequireDirectory(session);
        if (editor == null || !File.Exists(editor)) throw new InvalidOperationException("Choose an installed editor executable (.exe) in Settings first.");
        var start = new ProcessStartInfo(editor) { UseShellExecute = false, WorkingDirectory = directory };
        start.ArgumentList.Add(directory);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("The editor could not be started.");
        Clipboard.SetText(resumeCommand ?? session.Command);
    }
    internal static Task<string> ReadScreenshot(string file) => Task.Run(() =>
    {
        if (new FileInfo(file).Length > 30 * 1024 * 1024) throw new InvalidOperationException("Choose an image smaller than 30 MB.");
        using var image = Pix.LoadFromFile(file);
        if ((long)image.Width * image.Height > 32_000_000) throw new InvalidOperationException("Choose an image smaller than 32 megapixels.");
        using var engine = new TesseractEngine(Path.Combine(AppContext.BaseDirectory, "tessdata"), "eng", EngineMode.Default);
        using var page = engine.Process(image);
        return page.GetText();
    });
    internal static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose();
    internal static UpdateManager UpdateManager() => new(new GithubSource("https://github.com/en-code23/reprise", null, false));
}

internal static class Theme
{
    internal static readonly Color Paper = ColorTranslator.FromHtml("#f7f8f5");
    internal static readonly Color Ink = ColorTranslator.FromHtml("#20271f");
    internal static readonly Color Green = ColorTranslator.FromHtml("#306744");
    internal static readonly Color Sage = ColorTranslator.FromHtml("#e9eee5");
    internal static readonly Color Secondary = ColorTranslator.FromHtml("#626c60");
    internal static Button Button(string text, EventHandler action, bool primary = false)
    {
        var button = new Button { Text = text, AutoSize = true, MinimumSize = new Size(110, 40), Padding = new Padding(10, 4, 10, 4), FlatStyle = FlatStyle.Flat, Cursor = Cursors.Hand,
            BackColor = primary ? Green : Color.White, ForeColor = primary ? Color.White : Ink, Margin = new Padding(0, 0, 10, 8) };
        button.FlatAppearance.BorderColor = ColorTranslator.FromHtml("#dfe4da"); button.Click += action; return button;
    }
    internal static Label Label(string text, float size = 10, bool bold = false) => new() { Text = text, UseMnemonic = false, AutoSize = true, MaximumSize = new Size(720, 0), Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular), ForeColor = Ink, Margin = new Padding(0, 0, 0, 8) };
    internal static ComboBox Combo(IEnumerable<string> values)
    {
        var combo = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 170, IntegralHeight = false, DropDownHeight = 260, Margin = new Padding(0, 0, 0, 10) };
        combo.Items.AddRange(values.Cast<object>().ToArray()); combo.SelectedIndex = 0; return combo;
    }
}
