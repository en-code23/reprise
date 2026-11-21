using System.Text.RegularExpressions;

namespace Reprise.Core;

public sealed record Session
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Model { get; set; } = "codex";
    public string Project { get; set; } = "";
    public string? Name { get; set; }
    public string? DetectedName { get; set; }
    public bool? IsSubagent { get; set; }
    public bool? HasLocalHistory { get; set; }
    public string? DetectedAssistant { get; set; }
    public string? AssistantOverride { get; set; }
    public string? ProjectDirectory { get; set; }
    public string Note { get; set; } = "";
    public string Command { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public string? SourceFileName { get; set; }
    public bool DetectedAutomatically { get; set; }
    public string DetectedOrigin { get; set; } = "Unknown";
    public string? OriginOverride { get; set; }
    public string Origin => OriginOverride ?? DetectedOrigin;
    public string SourceLabel => Commands.Client(Command) is { } client && client != Model ?
        (client switch { "claude" => "Claude Code", "opencode" => "OpenCode", "moonshot" => "Kimi", "antigravity" => "Antigravity", "gemini" => "Gemini", "codex" => "Codex", "grok" => "Grok", _ => client }) + " · " + Origin : Origin;
    public string Identity => (Commands.Client(Command) ?? Model.ToLowerInvariant()) + ":" + Commands.Canonicalize(Command);
    [System.Text.Json.Serialization.JsonIgnore]
    public string SessionIdentifier => Command.Split(' ', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? Id.ToString();
    [System.Text.Json.Serialization.JsonIgnore]
    public string DisplayName => SessionNames.Clean(Name) ?? SessionNames.Clean(DetectedName) ?? "Session · " + SessionIdentifier[^Math.Min(8, SessionIdentifier.Length)..];
}

public static class Commands
{
    public static readonly string[] Models = ["codex", "claude", "grok", "gemini", "moonshot", "deepseek", "glm", "antigravity", "opencode", "other"];
    private static readonly Regex Resume = new(@"\b(codex|claude|grok|gemini|kimi|agy|opencode)\s+(?:--resume|resume|--session|-s|-r|--conversation)\s+[""']?([A-Za-z0-9_-]{6,})[""']?", RegexOptions.IgnoreCase);
    public static string? Client(string command) => command.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToLowerInvariant() switch {
        "kimi" => "moonshot", "agy" => "antigravity", "codex" => "codex", "claude" => "claude", "grok" => "grok", "gemini" => "gemini", "opencode" => "opencode", _ => null
    };
    public static string Build(string model, string identifier)
    {
        model = model.ToLowerInvariant();
        var tool = model switch { "moonshot" or "kimi" => "kimi", "antigravity" or "agy" => "agy", "glm" or "deepseek" => "opencode", _ => model };
        var flag = tool switch { "codex" => "resume", "kimi" or "opencode" => "--session", "agy" => "--conversation", _ => "--resume" };
        return $"{tool} {flag} {identifier}";
    }
    public static string? RecordedProvider(string? value)
    {
        value = value?.ToLowerInvariant();
        if (value == null) return null;
        if (value.Contains("deepseek")) return "deepseek";
        if (Regex.IsMatch(value, @"(?:^|[/_.:\s-])glm(?:$|[-_0-9.\s])") || new[] { "zai", "z.ai", "zhipu", "zhipuai", "zai-coding-plan" }.Contains(value)) return "glm";
        if (value.Contains("moonshot") || value.Contains("kimi")) return "moonshot";
        return value.Contains("gemini") ? "gemini" : null;
    }
    public static string Canonicalize(string command)
    {
        var match = Resume.Match(command.Trim());
        return match.Success && match.Index == 0 && match.Length == command.Trim().Length
            ? Build(match.Groups[1].Value, match.Groups[2].Value) : command.Trim();
    }
    public static (string Model, string Command, string? Directory) Parse(string text)
    {
        var normalized = text.Replace('“', '"').Replace('”', '"').Replace('‘', '\'').Replace('’', '\'');
        var match = Resume.Match(normalized);
        var model = match.Success ? Client(match.Groups[1].Value)!
            : normalized.Contains("claude", StringComparison.OrdinalIgnoreCase) ? "claude"
            : normalized.Contains("grok", StringComparison.OrdinalIgnoreCase) ? "grok" : "codex";
        string? folder = null;
        foreach (var line in normalized.Split('\n'))
        {
            var candidate = line.Trim().Trim('"', '\'');
            candidate = Regex.Replace(candidate, @"^(?:PS\s+|(?:cwd|directory|project directory|path)\s*[:=]\s*)", "", RegexOptions.IgnoreCase).Trim();
            candidate = candidate.TrimEnd('>', '$', '%', ' ').Trim('"', '\'');
            if (ProjectPaths.IsWindowsAbsolute(candidate)) { folder = candidate; break; }
        }
        var command = match.Success ? Build(model, match.Groups[2].Value) : "";
        if (model is "claude" or "opencode") model = RecordedProvider(normalized) ?? model;
        return (model, command, folder);
    }
    public static string[] ValidatedArguments(string command)
    {
        var parts = Canonicalize(command).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 3 || Client(parts[0]) is not { } client ||
            Canonicalize(command) != Build(client, parts[2]) ||
            !Regex.IsMatch(parts[2], @"^[A-Za-z0-9][A-Za-z0-9_-]*$"))
            throw new InvalidOperationException("Resume requires a supported coding-tool command with a single session ID. Custom commands can still be copied.");
        return parts;
    }
    public static string PowerShellLiteral(string value) => "'" + value.Replace("'", "''") + "'";
    public static string PowerShellScript(Session session, string? executable = null)
    {
        if (session.HasLocalHistory == false) throw new InvalidOperationException("This conversation’s history is not on this PC. Open it in Codex first, then sync Reprise.");
        if (string.IsNullOrWhiteSpace(session.ProjectDirectory)) throw new InvalidOperationException("Choose a project folder first.");
        var arguments = ValidatedArguments(session.Command);
        return "$ErrorActionPreference = 'Stop'; Set-Location -LiteralPath " + PowerShellLiteral(session.ProjectDirectory) +
            "; & " + PowerShellLiteral(executable ?? arguments[0]) + " " + string.Join(" ", arguments.Skip(1).Select(PowerShellLiteral));
    }
}

public static class ProjectPaths
{
    public static bool IsWindowsAbsolute(string? value) => !string.IsNullOrWhiteSpace(value) &&
        (Regex.IsMatch(value, @"^[A-Za-z]:[\\/]") || Regex.IsMatch(value, @"^\\\\[^\\]+\\[^\\]+"));
    public static string? Normalize(string? value)
    {
        if (!IsWindowsAbsolute(value)) return null;
        var path = value!.Trim().Replace('/', '\\');
        var prefix = path.StartsWith("\\\\") ? "\\\\" : path[..3];
        var parts = new List<string>();
        foreach (var part in path[prefix.Length..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == ".") continue;
            if (part == "..") { if (parts.Count > 0) parts.RemoveAt(parts.Count - 1); }
            else parts.Add(part);
        }
        return (prefix + string.Join("\\", parts)).TrimEnd('\\').ToUpperInvariant();
    }
    public static string Name(string? path) => path?.TrimEnd('\\', '/').Split('\\', '/').LastOrDefault() ?? "Untitled project";
    public static string Area(string? path) => Normalize(path) == null ? "Unassigned" :
        path!.Replace('/', '\\').Split('\\').Any(p => new[] { ".codex", ".claude", ".grok", ".chatgpt", ".gemini", ".kimi", ".kimi-code", ".opencode" }.Contains(p.ToLowerInvariant())) ? "Internal" : "Projects";
}

public sealed record ProjectGroup(string Key, IReadOnlyList<Session> Sessions)
{
    public Session Latest => Sessions[0];
    public string Name => string.IsNullOrWhiteSpace(Latest.Project) ? ProjectPaths.Name(Latest.ProjectDirectory) : Latest.Project;
    public string Directory => Latest.ProjectDirectory ?? "Choose a project folder";
    public string Area => ProjectPaths.Area(Latest.ProjectDirectory);
    public override string ToString() => Name;
    public static List<ProjectGroup> Group(IEnumerable<Session> sessions, string area = "Projects", string model = "All assistants", string source = "Main sessions", string query = "") =>
        sessions.Where(s => s.IsSubagent != true && (model == "All assistants" || s.Model.Equals(model, StringComparison.OrdinalIgnoreCase)) &&
            (source == "All sources" || source == "Main sessions" && s.Origin != "SDK / automation" || s.Origin == source))
        .GroupBy(s => ProjectPaths.Normalize(s.ProjectDirectory) ?? "unassigned:" + s.Id, StringComparer.OrdinalIgnoreCase)
        .Select(g => new ProjectGroup(g.Key, g.OrderByDescending(s => s.CreatedAt).ToList()))
        .Where(g => g.Area == area && (string.IsNullOrWhiteSpace(query) ||
            ProjectPaths.Normalize(g.Latest.ProjectDirectory) is { } path && ProjectPaths.Name(path).Contains(query.Trim(), StringComparison.OrdinalIgnoreCase)))
        .OrderByDescending(g => g.Latest.CreatedAt).ToList();
}
