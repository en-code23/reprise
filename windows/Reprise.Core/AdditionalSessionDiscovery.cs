using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace Reprise.Core;

/// <summary>Read-only local indexes. No assistant processes, credentials, or imported message bodies.</summary>
public static class AdditionalSessionDiscovery
{
    public static DiscoveryResult Scan(string home, IReadOnlyDictionary<string, string?>? environment = null)
    {
        string Root(string key, string fallback) => (environment?.GetValueOrDefault(key) ?? Environment.GetEnvironmentVariable(key)) is { Length: > 0 } value ? value : fallback;
        var sessions = new List<Session>(); var warnings = new List<string>();
        var sources = new (string Name, Func<List<Session>> Read)[] {
            ("Gemini", () => Gemini(Path.Combine(Root("GEMINI_CLI_HOME", home), ".gemini"))),
            ("Gemini", () => Gemini(Path.Combine(Root("GEMINI_CLI_HOME", home), ".cache", ".gemini"))),
            ("Kimi", () => Kimi(Path.Combine(Root("KIMI_SHARE_DIR", Path.Combine(home, ".kimi"))))),
            ("Kimi Code", () => KimiCode(Root("KIMI_CODE_HOME", Path.Combine(home, ".kimi-code")))),
            ("OpenCode", () => OpenCode(Path.Combine(Root("XDG_DATA_HOME", Path.Combine(home, ".local", "share")), "opencode"))),
            ("Antigravity", () => Antigravity(Path.Combine(home, ".gemini", "antigravity-cli")))
        };
        foreach (var source in sources)
        {
            try { sessions.AddRange(source.Read()); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or SqliteException)
            { warnings.Add($"Some {source.Name} session metadata could not be read (unavailable, unsupported, or over the import limit)."); }
        }
        return new(sessions, warnings);
    }

    public static Session? Create(string client, string? id, string? directory, string? title, string? updated = null, DateTimeOffset? modified = null, string? provider = null, string origin = "CLI")
    {
        if (id == null || id.Length > 200 || !Regex.IsMatch(id, @"^[A-Za-z0-9][A-Za-z0-9_-]{5,}$")) return null;
        directory = ProjectPaths.IsWindowsAbsolute(directory) ? directory : null;
        return new() { Model = provider ?? client, Project = directory == null ? "Unknown project" : ProjectPaths.Name(directory),
            ProjectDirectory = directory, Command = Commands.Build(client, id), DetectedName = SessionNames.Clean(title),
            CreatedAt = Date(updated) ?? modified ?? DateTimeOffset.UtcNow, DetectedAutomatically = true,
            DetectedOrigin = origin, IsSubagent = false, HasLocalHistory = true };
    }

    public static DateTimeOffset? Date(string? text)
    {
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
        {
            number = number > 100_000_000_000 ? number / 1000 : number;
            if (double.IsFinite(number) && number > 0 && number < 253402300799) return DateTimeOffset.UnixEpoch.AddSeconds(number);
            return null;
        }
        return DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date) ? date : null;
    }

    public static List<Session> Gemini(string root)
    {
        var sessions = new List<Session>(); var paths = new Dictionary<string, string>();
        if (Object(Path.Combine(root, "projects.json")) is { } registry && Property(registry, "projects") is { ValueKind: JsonValueKind.Object } projects)
            foreach (var item in projects.EnumerateObject())
                if (item.Value.ValueKind == JsonValueKind.String && item.Value.GetString() is { } slug)
                {
                    paths[slug] = item.Name;
                    paths[Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(item.Name))).ToLowerInvariant()] = item.Name;
                }
        foreach (var project in Children(Path.Combine(root, "tmp"), true))
        {
            var marker = Read(Path.Combine(project, ".project_root"), 16 * 1024)?.Trim();
            var directory = marker ?? paths.GetValueOrDefault(Path.GetFileName(project));
            foreach (var file in Children(Path.Combine(project, "chats"), false).Where(f => Path.GetFileName(f).StartsWith("session-") && Path.GetExtension(f) is ".json" or ".jsonl"))
            {
                var metadata = new Dictionary<string, JsonElement>();
                if (Path.GetExtension(file) == ".jsonl")
                {
                    foreach (var row in Records(file))
                    {
                        if (metadata.Count == 0 && Text(row, "sessionId") != null) metadata = row.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone());
                        if (Property(row, "$set") is { ValueKind: JsonValueKind.Object } update)
                            foreach (var key in new[] { "summary", "lastUpdated", "kind" }) if (Property(update, key) is { } value) metadata[key] = value.Clone();
                    }
                }
                else if (Object(file, 16 * 1024 * 1024) is { } row) metadata = row.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone());
                string? Value(string key) => metadata.TryGetValue(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
                if (Value("kind") == "subagent") continue;
                if (Create("gemini", Value("sessionId"), directory, Value("summary"), Value("lastUpdated"), File.GetLastWriteTimeUtc(file)) is { } session) sessions.Add(session);
            }
        }
        return sessions;
    }

    public static List<Session> Kimi(string root)
    {
        var sessions = new List<Session>();
        if (Object(Path.Combine(root, "kimi.json")) is not { } metadata || Property(metadata, "work_dirs") is not { ValueKind: JsonValueKind.Array } workDirs) return sessions;
        foreach (var work in workDirs.EnumerateArray())
        {
            if (Text(work, "path") is not { } path || (Text(work, "kaos") ?? "local") != "local") continue;
            var hash = Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(path))).ToLowerInvariant();
            var folder = Path.Combine(root, "sessions", hash);
            foreach (var entry in Children(folder, true))
            {
                var context = Path.Combine(entry, "context.jsonl");
                if (!IsFile(context) || new FileInfo(context).Length == 0) continue;
                var state = Object(Path.Combine(entry, "state.json")) ?? Object(Path.Combine(entry, "metadata.json"));
                if (Create("moonshot", Path.GetFileName(entry), path, state is { } row ? Text(row, "custom_title") ?? Text(row, "title") : null, modified: File.GetLastWriteTimeUtc(context)) is { } session) sessions.Add(session);
            }
            foreach (var file in Children(folder, false).Where(f => Path.GetExtension(f) == ".jsonl" && new FileInfo(f).Length > 0))
                if (Create("moonshot", Path.GetFileNameWithoutExtension(file), path, null, modified: File.GetLastWriteTimeUtc(file)) is { } session) sessions.Add(session);
        }
        return sessions;
    }

    public static List<Session> KimiCode(string root)
    {
        var sessions = new List<Session>(); var directories = new Dictionary<string, string>();
        foreach (var row in Records(Path.Combine(root, "session_index.jsonl")))
            if (Text(row, "sessionId") is { } id && Text(row, "workDir") is { } directory) directories[id] = directory;
        foreach (var work in Children(Path.Combine(root, "sessions"), true))
            foreach (var entry in Children(work, true))
            {
                var file = Path.Combine(entry, "state.json");
                if (Object(file) is not { } state || Text(state, "id") is not { } id || id != Path.GetFileName(entry) || !IsFile(Path.Combine(entry, "agents", "main", "wire.jsonl"))) continue;
                if (Create("moonshot", id, Text(state, "cwd") ?? directories.GetValueOrDefault(id), Text(state, "title"), Scalar(state, "updatedAt"), File.GetLastWriteTimeUtc(file)) is { } session) sessions.Add(session);
            }
        return sessions;
    }

    public static List<Session> OpenCode(string root)
    {
        var sessions = new List<Session>(); var database = Path.Combine(root, "opencode.db");
        if (IsFile(database))
        {
            using var db = OpenDatabase(database);
            foreach (var (table, messages) in new[] { ("session", "message"), ("session_v2", "session_message") })
            {
                var columns = Columns(db, table);
                if (!new[] { "id", "directory", "title", "time_updated" }.All(columns.Contains)) continue;
                var model = columns.Contains("model") ? "s.model" : "NULL";
                var parent = columns.Contains("parent_id") ? "s.parent_id" : "NULL";
                var messageColumns = Columns(db, messages);
                var fallback = new[] { "session_id", "data", "time_created" }.All(messageColumns.Contains)
                    ? $"(SELECT json_object('providerID',json_extract(data,'$.providerID'),'modelID',json_extract(data,'$.modelID')) FROM {messages} m WHERE m.session_id=s.id AND json_valid(data) AND json_extract(data,'$.role')='assistant' ORDER BY time_created DESC LIMIT 1)" : "NULL";
                foreach (var row in Rows(db, $"SELECT s.id,s.directory,s.title,s.time_updated,{model},{fallback},{parent} FROM {table} s ORDER BY s.time_updated DESC LIMIT 5000"))
                {
                    if (!string.IsNullOrEmpty(row[6])) continue;
                    var provider = string.IsNullOrEmpty(row[4]) || row[4] == "null" ? OpenCodeProvider(row[5]) : OpenCodeProvider(row[4]);
                    if (Create("opencode", row[0], row[1], row[2], row[3], provider: provider, origin: "Unknown") is { } session) sessions.Add(session);
                }
            }
        }
        foreach (var project in Children(Path.Combine(root, "storage", "session"), true))
            foreach (var file in Children(project, false).Where(f => Path.GetExtension(f) == ".json"))
            {
                if (Object(file) is not { } info || !string.IsNullOrEmpty(Text(info, "parentID")) || Text(info, "id") is not { } id || id.Length > 200 || !Regex.IsMatch(id, @"^[A-Za-z0-9][A-Za-z0-9_-]{5,}$")) continue;
                string? provider = null;
                foreach (var fileName in Children(Path.Combine(root, "storage", "message", id), false).OrderByDescending(Path.GetFileName, StringComparer.Ordinal).Take(20))
                    if (Object(fileName) is { } value && Text(value, "role") == "assistant")
                    { provider = Commands.RecordedProvider(Text(value, "modelID")) ?? Commands.RecordedProvider(Text(value, "providerID")); break; }
                var updated = Property(info, "time") is { } time ? Scalar(time, "updated") : null;
                if (Create("opencode", id, Text(info, "directory"), Text(info, "title"), updated, File.GetLastWriteTimeUtc(file), provider, "Unknown") is { } session) sessions.Add(session);
            }
        return sessions.GroupBy(s => s.Identity).Select(g => g.Aggregate((first, last) => last.CreatedAt >= first.CreatedAt ? last : first)).ToList();
    }

    private static string? OpenCodeProvider(string? value)
    {
        if (value == null) return null;
        try
        {
            using var document = JsonDocument.Parse(value); var row = document.RootElement;
            return Commands.RecordedProvider(Text(row, "modelID") ?? Text(row, "id")) ?? Commands.RecordedProvider(Text(row, "providerID"));
        }
        catch (JsonException) { return Commands.RecordedProvider(value); }
    }

    public static List<Session> Antigravity(string root)
    {
        var database = Path.Combine(root, "conversation_summaries.db");
        if (!IsFile(database)) return [];
        using var db = OpenDatabase(database); var columns = Columns(db, "conversation_summaries");
        if (!new[] { "conversation_id", "title", "workspace_uris", "last_modified_time" }.All(columns.Contains)) throw new IOException("Unsupported Antigravity metadata index.");
        string Column(string name) => columns.Contains(name) ? name : "NULL";
        var sessions = new List<Session>();
        foreach (var row in Rows(db, $"SELECT conversation_id,title,workspace_uris,last_modified_time,{Column("parent_conversation_id")},{Column("nesting_depth")},{Column("source")} FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 5000"))
        {
            if (!string.IsNullOrEmpty(row[4]) || int.TryParse(row[5], out var depth) && depth != 0) continue;
            string? directory = null;
            try
            {
                var uris = JsonSerializer.Deserialize<string[]>(row[2] ?? "[]") ?? [];
                directory = uris.Select(s => Uri.TryCreate(s, UriKind.Absolute, out var uri) ? uri : null).FirstOrDefault(u => u?.IsFile == true)?.LocalPath;
            }
            catch (JsonException) { }
            var origin = row[6]?.ToLowerInvariant() switch { "cli" or "antigravity-cli" => "CLI", "ide" or "antigravity-ide" => "IDE extension", _ => "Unknown" };
            if (Create("antigravity", row[0], directory, row[1], row[3], origin: origin) is { } session) sessions.Add(session);
        }
        return sessions;
    }

    private static SqliteConnection OpenDatabase(string file)
    {
        var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = file, Mode = SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 1 }.ToString());
        try { db.Open(); return db; } catch { db.Dispose(); throw; }
    }
    private static HashSet<string> Columns(SqliteConnection db, string table) => Rows(db, $"PRAGMA table_info({table})").Select(r => r[1]!).ToHashSet();
    private static List<string?[]> Rows(SqliteConnection db, string sql)
    {
        using var command = db.CreateCommand(); command.CommandText = sql;
        using var reader = command.ExecuteReader(); var rows = new List<string?[]>();
        while (reader.Read()) rows.Add(Enumerable.Range(0, reader.FieldCount).Select(i => reader.IsDBNull(i) ? null : Convert.ToString(reader.GetValue(i), CultureInfo.InvariantCulture) is { Length: <= 16384 } value ? value : null).ToArray());
        return rows;
    }
    private static string? Text(JsonElement row, string key) => Property(row, key) is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;
    private static string? Scalar(JsonElement row, string key) => Property(row, key) is { } value && value.ValueKind is JsonValueKind.String or JsonValueKind.Number ? value.ToString() : null;
    private static JsonElement? Property(JsonElement row, string key) => row.ValueKind == JsonValueKind.Object && row.TryGetProperty(key, out var value) ? value : null;
    private static bool IsFile(string file) => File.Exists(file) && (File.GetAttributes(file) & FileAttributes.ReparsePoint) == 0;
    private static IEnumerable<string> Children(string folder, bool directories)
    {
        if (!Directory.Exists(folder) || (File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0) return [];
        return Directory.EnumerateFileSystemEntries(folder).Where(p => (File.GetAttributes(p) & FileAttributes.ReparsePoint) == 0 && Directory.Exists(p) == directories).ToArray();
    }
    private static string? Read(string file, int limit = 1024 * 1024)
    {
        if (!IsFile(file)) return null;
        try
        {
            using var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (input.Length > limit) return null;
            var bytes = new byte[Math.Min(input.Length, limit)]; var count = input.ReadAtLeast(bytes, bytes.Length, false);
            return Encoding.UTF8.GetString(bytes, 0, count);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
    }
    private static JsonElement? Object(string file, int limit = 1024 * 1024)
    {
        if (Read(file, limit) is not { } data) return null;
        try { using var document = JsonDocument.Parse(data); return document.RootElement.ValueKind == JsonValueKind.Object ? document.RootElement.Clone() : null; }
        catch (JsonException) { return null; }
    }
    private static List<JsonElement> Records(string file)
    {
        var records = new List<JsonElement>();
        if (!IsFile(file)) return records;
        using var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        const int bound = 256 * 1024;
        string Slice(bool tail)
        {
            var start = tail ? Math.Max(bound, input.Length - bound) : 0;
            input.Seek(start, SeekOrigin.Begin); var bytes = new byte[Math.Min(input.Length - start, bound)];
            var count = input.ReadAtLeast(bytes, bytes.Length, false); var offset = tail ? Array.IndexOf(bytes, (byte)'\n', 0, count) + 1 : 0;
            return tail && offset == 0 ? "" : Encoding.UTF8.GetString(bytes, offset, count - offset);
        }
        var text = Slice(false); if (input.Length > bound) text += "\n" + Slice(true);
        foreach (var line in text.Split('\n'))
            try { using var document = JsonDocument.Parse(line); if (document.RootElement.ValueKind == JsonValueKind.Object) records.Add(document.RootElement.Clone()); }
            catch (JsonException) { }
        return records;
    }
}
