using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Reprise.Core;

public sealed class ModelSelectionPreferences
{
    public bool Enabled { get; set; }
    public bool Continuous { get; set; } = true;
    public double ReservePercent { get; set; } = 20;
    public bool UseExpiringHeadroom { get; set; } = true;
    public bool AllowFoundationMax { get; set; }
    public bool UseFableAllowance { get; set; }
    public Dictionary<string, string> WorkHints { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, int> ModelRoles { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public HashSet<string> DisabledProjects { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}
public sealed class SelectionModel
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public int Role { get; set; }
    public List<string> Efforts { get; set; } = [];
    [JsonPropertyName("quotaIDs")] public List<string> QuotaIds { get; set; } = [];
    public bool Included { get; set; } = true;
    public bool RequiresSpecialAllowance { get; set; }
    [JsonIgnore] public bool Valid => Regex.IsMatch(Id, @"^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,119}$") && Role is >= 0 and <= 3 && Efforts.Count > 0 && Efforts.All(e => ModelSelectionStore.Efforts.Contains(e));
}
public sealed class SelectionWindow
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public double UsedPercent { get; set; }
    public double ResetsAt { get; set; }
    public double? DurationMinutes { get; set; }
    [JsonPropertyName("modelIDs")] public List<string> ModelIds { get; set; } = [];
    public bool SpecialAllowance { get; set; }
    public double ObservedAt { get; set; }
    public bool Fresh(double now) => double.IsFinite(UsedPercent) && UsedPercent is >= 0 and <= 100 && ObservedAt <= now + 60 && now - ObservedAt <= 300 && ResetsAt > now;
}
public sealed class SelectionState
{
    public string Provider { get; set; } = "";
    public List<SelectionModel> Models { get; set; } = [];
    public List<SelectionWindow> Windows { get; set; } = [];
    public double? ObservedAt { get; set; }
    public string Status { get; set; } = "Usage has not been connected.";
    public bool Subscription { get; set; }
    public bool Blocked { get; set; }
}
public sealed class SelectionDecision
{
    public SelectionModel? Model { get; set; }
    public string? Effort { get; set; }
    public string Kind { get; set; } = "automatic";
    public List<string> Reasons { get; set; } = [];
    public bool Constrained { get; set; }
    public bool Blocked { get; set; }
    public bool Boosted { get; set; }
    public string[] Arguments(string provider)
    {
        if (Blocked || Model?.Valid != true || Effort == null || !Model.Efforts.Contains(Effort)) return [];
        return provider switch {
            "codex" => ["--model", Model.Id, "--config", $"model_reasoning_effort=\"{Effort}\""],
            "claude" => ["--model", Model.Id, "--effort", Effort],
            "grok" => ["--model", Model.Id, "--reasoning-effort", Effort], _ => []
        };
    }
}
public sealed class ManagedSessionDescriptor
{
    public string Provider { get; set; } = "";
    public string SessionId { get; set; } = "";
    public string Directory { get; set; } = "";
    public string ConfigPath { get; set; } = "";
    public string ProjectKey { get; set; } = "";
    public string? HostProbe { get; set; }
    public string Encoded() => Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(this, SessionStore.Json)));
}

public sealed class ModelSelectionStore
{
    public static readonly string[] Efforts = ["low", "medium", "high", "xhigh", "max"];
    public static readonly string[] Providers = ["codex", "claude", "grok"];
    public static readonly (string Id, string Label)[] WorkKinds = [("automatic", "Detect from project"), ("smallTask", "Small change"), ("interface", "UI / frontend"), ("backend", "Backend / debugging"), ("foundation", "Backend foundations")];
    private sealed class Saved
    {
        public ModelSelectionPreferences Preferences { get; set; } = new();
        public List<SelectionState> States { get; set; } = [];
        public bool ClaudeConnected { get; set; }
        [JsonPropertyName("fableWindowID")] public string FableWindowId { get; set; } = "";
    }
    private readonly string runner;
    private Saved saved = new();
    private bool writable = true;
    public string ConfigurationPath { get; }
    public string? Error { get; private set; }
    public ModelSelectionPreferences Preferences => saved.Preferences;
    public bool ClaudeConnected { get => saved.ClaudeConnected; set => saved.ClaudeConnected = value; }
    public string FableWindowId { get => saved.FableWindowId; set => saved.FableWindowId = value; }
    public IReadOnlyList<SelectionState> States => saved.States;

    public ModelSelectionStore(string directory, string runner)
    {
        this.runner = runner; ConfigurationPath = Path.Combine(directory, "model-routing.json");
        if (File.Exists(ConfigurationPath))
            try {
                if (new FileInfo(ConfigurationPath).Length > 2 * 1024 * 1024) throw new JsonException();
                saved = JsonSerializer.Deserialize<Saved>(File.ReadAllText(ConfigurationPath), SessionStore.Json) ?? throw new JsonException();
                if (saved.Preferences == null || saved.States == null || saved.Preferences.WorkHints == null || saved.Preferences.ModelRoles == null || saved.Preferences.DisabledProjects == null) throw new JsonException();
                saved.Preferences.WorkHints = new(saved.Preferences.WorkHints, StringComparer.OrdinalIgnoreCase);
                saved.Preferences.DisabledProjects = new(saved.Preferences.DisabledProjects, StringComparer.OrdinalIgnoreCase);
            }
            catch { writable = false; saved = new(); Error = "Model-selection settings could not be read. The original file is preserved."; }
        ReadCaches();
    }
    public void Save()
    {
        if (!writable) return;
        var temporary = ConfigurationPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try {
            Directory.CreateDirectory(Path.GetDirectoryName(ConfigurationPath)!);
            File.WriteAllText(temporary, JsonSerializer.Serialize(saved, SessionStore.Json));
            File.Move(temporary, ConfigurationPath, true); Error = null;
        } catch { Error = "Model-selection preferences could not be saved."; }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public SelectionState? State(string provider) => saved.States.FirstOrDefault(s => s.Provider == provider);
    public void ReadCaches()
    {
        foreach (var provider in Providers)
            try {
                var file = Path.Combine(Path.GetDirectoryName(ConfigurationPath)!, "routing-usage", provider + ".json");
                if (!File.Exists(file) || new FileInfo(file).Length > 2 * 1024 * 1024) continue;
                var state = JsonSerializer.Deserialize<SelectionState>(File.ReadAllText(file), SessionStore.Json);
                if (state?.Provider == provider && (state.ObservedAt ?? 0) > (State(provider)?.ObservedAt ?? 0)) Replace(state);
            } catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { }
    }
    private void Replace(SelectionState state) { saved.States.RemoveAll(s => s.Provider == state.Provider); saved.States.Add(state); }
    public bool Eligible(Session session)
    {
        try { return Preferences.Enabled && Providers.Contains(session.Model) && ProjectPaths.IsWindowsAbsolute(session.ProjectDirectory) &&
            Guid.TryParse(session.SessionIdentifier, out _) && session.HasLocalHistory != false && !Preferences.DisabledProjects.Contains(ProjectPaths.Normalize(session.ProjectDirectory)!) &&
            Commands.ValidatedArguments(session.Command)[0] == session.Model; }
        catch (InvalidOperationException) { return false; }
    }
    public bool Managed(Session session) => Preferences.Continuous && Eligible(session);
    public ManagedSessionDescriptor Descriptor(Session session)
    {
        var parts = Commands.ValidatedArguments(session.Command);
        if (!Providers.Contains(session.Model) || parts[0] != session.Model || !Guid.TryParse(parts[2], out _) || !ProjectPaths.IsWindowsAbsolute(session.ProjectDirectory)) throw new InvalidOperationException("Choose a valid session and project directory first.");
        return new() { Provider = session.Model, SessionId = parts[2], Directory = session.ProjectDirectory!, ProjectKey = ProjectPaths.Normalize(session.ProjectDirectory)!, ConfigPath = ConfigurationPath };
    }
    public string[] ManagedArguments(Session session)
    {
        if (!File.Exists(runner)) throw new InvalidOperationException("The managed-session component is missing. Reinstall Reprise or turn off continuous switching.");
        return [runner, "run", "--request", Descriptor(session).Encoded()];
    }
    public string ClipboardCommand(Session session) => Managed(session) ? "& " + string.Join(" ", ManagedArguments(session).Select(Commands.PowerShellLiteral)) : session.Command;
    public async Task Refresh(string provider)
    {
        if (!Preferences.Enabled || !Providers.Contains(provider)) return;
        try {
            var text = await Run(["probe", provider, "--config", ConfigurationPath]);
            var state = JsonSerializer.Deserialize<SelectionState>(text, SessionStore.Json) ?? throw new JsonException();
            if (state.Provider != provider) throw new JsonException(); Replace(state); Save();
        } catch {
            var state = State(provider) ?? new SelectionState { Provider = provider };
            state.Status = "Usage could not be refreshed. Check the CLI login and retry. Cached windows are stale.";
            state.ObservedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(); foreach (var window in state.Windows) window.ObservedAt = 0;
            Replace(state); Save();
        }
    }
    public async Task<SelectionDecision?> Plan(Session session)
    {
        if (!Eligible(session)) return null;
        var text = await Run(["plan", "--request", Descriptor(session).Encoded()]);
        return JsonSerializer.Deserialize<SelectionDecision>(text, SessionStore.Json);
    }
    private async Task<string> Run(string[] arguments)
    {
        if (!File.Exists(runner)) throw new IOException("Managed-session component is unavailable.");
        var start = new ProcessStartInfo(runner) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in arguments) start.ArgumentList.Add(arg);
        using var process = Process.Start(start) ?? throw new IOException();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        var discardErrors = process.StandardError.BaseStream.CopyToAsync(Stream.Null, timeout.Token);
        var output = new StringBuilder(); var buffer = new char[8192];
        try {
            int count;
            while ((count = await process.StandardOutput.ReadAsync(buffer, timeout.Token)) > 0) {
                output.Append(buffer, 0, count); if (output.Length > 2 * 1024 * 1024) throw new IOException();
            }
            await process.WaitForExitAsync(timeout.Token); await discardErrors;
            if (process.ExitCode != 0) throw new IOException(); return output.ToString();
        } finally { if (!process.HasExited) process.Kill(true); }
    }
}
