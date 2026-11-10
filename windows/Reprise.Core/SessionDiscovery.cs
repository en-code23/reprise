using System.Text;
using System.Text.Json;

namespace Reprise.Core;

public sealed record DiscoveryResult(List<Session> Sessions, List<string> Warnings);

public static class SessionDiscovery
{
    public static DiscoveryResult Scan(string home, IReadOnlyDictionary<string, string?>? environment = null)
    {
        string Root(string key, string fallback) => (environment?.GetValueOrDefault(key) ?? Environment.GetEnvironmentVariable(key)) is { Length: > 0 } value ? value : Path.Combine(home, fallback);
        var sessions = new List<Session>(); var warnings = new HashSet<string>();
        var codexHome = Root("CODEX_HOME", ".codex");
        var indexed = CodexHistoryIndex.Scan(codexHome);
        sessions.AddRange(indexed.Sessions); warnings.UnionWith(indexed.Warnings);
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try { names = SessionNames.ReadCodexIndex(Path.Combine(codexHome, "session_index.jsonl")); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { warnings.Add("Some Codex session names could not be read."); }
        foreach (var (model, root, pattern, limit) in new[] {
            ("codex", Path.Combine(codexHome, "sessions"), "*.jsonl", 256 * 1024),
            ("codex", Path.Combine(codexHome, "archived_sessions"), "*.jsonl", 256 * 1024),
            ("claude", Path.Combine(Root("CLAUDE_CONFIG_DIR", ".claude"), "projects"), "*.jsonl", 256 * 1024),
            ("grok", Path.Combine(Root("GROK_HOME", ".grok"), "sessions"), "summary.json", 1024 * 1024) })
        {
            if (!Directory.Exists(root)) continue;
            try
            {
                var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint | FileAttributes.Hidden | FileAttributes.System };
                foreach (var file in Directory.EnumerateFiles(root, pattern, options))
                {
                    if (Path.GetRelativePath(root, file).Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Contains("subagents", StringComparer.OrdinalIgnoreCase)) continue;
                    if (model == "claude" && Path.GetFileName(file).StartsWith("agent-", StringComparison.OrdinalIgnoreCase)) continue;
                    try
                    {
                        using var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                        if (model == "grok" && input.Length > limit) { warnings.Add("A Grok summary exceeded the 1 MB metadata limit."); continue; }
                        var data = new byte[Math.Min(input.Length, limit)];
                        var count = input.ReadAtLeast(data, data.Length, false);
                        var metadata = Encoding.UTF8.GetString(data, 0, count);
                        if (model == "claude") metadata += SessionNames.ClaudeTitleTail(input);
                        if (Parse(metadata, model, File.GetLastWriteTimeUtc(file), includeSubagents: true) is { } session)
                        {
                            if (model == "codex") session.DetectedName = names.GetValueOrDefault(session.SessionIdentifier);
                            sessions.Add(session);
                        }
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { warnings.Add($"Some {model} metadata could not be read."); }
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { warnings.Add($"The {model} metadata folder could not be read."); }
        }
        var unique = sessions.GroupBy(s => s.Identity, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.OrderBy(s => s.IsSubagent == true ? 1 : 0).ThenBy(s => s.HasLocalHistory == true ? 0 : 1).ThenByDescending(s => s.CreatedAt).First()).ToList();
        foreach (var session in unique.Where(s => s.Model == "codex"))
            session.DetectedName = names.GetValueOrDefault(session.SessionIdentifier) ?? indexed.Sessions.FirstOrDefault(s => s.Identity.Equals(session.Identity, StringComparison.OrdinalIgnoreCase))?.DetectedName ?? session.DetectedName;
        return new(unique, warnings.ToList());
    }
    private static string? Text(JsonElement element, string key) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    public static Session? Parse(string data, string model, DateTimeOffset modified, bool includeSubagents = false)
    {
        string? id = null, directory = null; var origin = "Unknown"; var entrypoints = new HashSet<string>();
        string? detectedName = null;
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var automaticNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var isSubagent = false; var classifiedClaudeConversation = false;
        if (model == "grok")
        {
            using var document = JsonDocument.Parse(data);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("info", out var info)) return null;
            id = Text(info, "id"); directory = Text(info, "cwd");
            detectedName = SessionNames.Clean(Text(root, "generated_title"));
            var dates = new[] { Text(root, "last_active_at"), Text(root, "updated_at") }.Select(value => DateTimeOffset.TryParse(value, out var date) ? (DateTimeOffset?)date : null).Where(date => date != null).ToList();
            if (dates.Count > 0) modified = dates.Max()!.Value;
        }
        else foreach (var line in data.Split('\n'))
        {
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object) continue;
                if (model == "codex" && Text(root, "type") == "session_meta" && root.TryGetProperty("payload", out var payload))
                {
                    id = Text(payload, "id") ?? Text(payload, "session_id"); directory = Text(payload, "cwd");
                    isSubagent = (payload.TryGetProperty("source", out var sessionSource) && sessionSource.ValueKind == JsonValueKind.Object && sessionSource.TryGetProperty("subagent", out _)) ||
                        Text(payload, "source")?.StartsWith("subagent", StringComparison.OrdinalIgnoreCase) == true;
                    origin = CodexOrigin(Text(payload, "originator"), Text(payload, "source")); break;
                }
                if (model == "claude" && !classifiedClaudeConversation &&
                    (Text(root, "type") is "user" or "assistant" || Text(root, "type") == null && Text(root, "cwd") != null))
                {
                    classifiedClaudeConversation = true;
                    isSubagent = root.TryGetProperty("isSidechain", out var flag) && flag.ValueKind is JsonValueKind.True or JsonValueKind.False
                        ? flag.ValueKind == JsonValueKind.True : !string.IsNullOrEmpty(Text(root, "agentId"));
                }
                if (model == "claude" && (!(root.TryGetProperty("isSidechain", out var sidechain) && sidechain.ValueKind == JsonValueKind.True) || includeSubagents && isSubagent))
                {
                    var candidate = Text(root, "sessionId");
                    if (id != null && candidate != null && id != candidate) continue;
                    id = candidate ?? id; directory = Text(root, "cwd") ?? directory;
                    if (Text(root, "entrypoint") is { } entrypoint) entrypoints.Add(entrypoint);
                    if (Text(root, "type") == "custom-title" && candidate != null && SessionNames.Clean(Text(root, "customTitle")) is { } name) names[candidate] = name;
                    if (Text(root, "type") == "ai-title" && candidate != null && SessionNames.Clean(Text(root, "aiTitle")) is { } aiName) automaticNames[candidate] = aiName;
                }
            }
            catch (JsonException) { }
        }
        if (model == "claude")
        {
            var sources = entrypoints.Select(ClaudeOrigin).Where(s => s != "Unknown").Distinct().ToList();
            origin = sources.Count > 1 ? "Multiple clients" : sources.FirstOrDefault() ?? "Unknown";
            if (id != null) detectedName = names.GetValueOrDefault(id) ?? automaticNames.GetValueOrDefault(id);
        }
        if (isSubagent && !includeSubagents || !Guid.TryParse(id, out _) || !ProjectPaths.IsWindowsAbsolute(directory)) return null;
        return new Session { Model = model, Project = ProjectPaths.Name(directory), ProjectDirectory = directory, Command = Commands.Build(model, id!), CreatedAt = modified, DetectedAutomatically = true, DetectedOrigin = origin, DetectedName = detectedName, IsSubagent = isSubagent, HasLocalHistory = true };
    }
    private static string Normalize(string? value) => (value ?? "").Trim().ToLowerInvariant().Replace('_', '-');
    public static string CodexOrigin(string? originator, string? source) => Normalize(originator) switch {
        "codex desktop" or "codex-desktop" or "codex-app" or "codex desktop app" => "Desktop app",
        "codex-tui" or "codex-cli-rs" or "codex-cli" or "codex cli" => "CLI",
        "vscode" or "codex-vscode" or "codex-ide" or "cursor" => "IDE extension",
        "codex-sdk" or "sdk" => "SDK / automation",
        _ => Normalize(source) switch { "cli" => "CLI", "ide" => "IDE extension", "desktop" or "app" => "Desktop app", "sdk" or "exec" => "SDK / automation", _ => "Unknown" }
    };
    public static string ClaudeOrigin(string value) => Normalize(value) switch {
        "claude-desktop" or "desktop" or "claude desktop" => "Desktop app",
        "cli" or "claude-cli" => "CLI",
        "vscode" or "ide" or "claude-vscode" or "jetbrains" => "IDE extension",
        "sdk-cli" or "sdk-py" or "sdk-ts" or "sdk" => "SDK / automation", _ => "Unknown"
    };
}
