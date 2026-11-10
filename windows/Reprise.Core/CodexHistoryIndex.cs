using Microsoft.Data.Sqlite;
using System.Text.Json;

namespace Reprise.Core;

public static class CodexHistoryIndex
{
    public static DiscoveryResult Scan(string home)
    {
        var sessions = new List<Session>();
        if (!Directory.Exists(home)) return new(sessions, []);
        try
        {
            var file = Directory.EnumerateFiles(home, "state_*.sqlite")
                .Select(path => (Path: path, Version: int.TryParse(Path.GetFileNameWithoutExtension(path)[6..], out var v) ? v : -1))
                .Where(item => item.Version >= 0).OrderByDescending(item => item.Version).FirstOrDefault().Path;
            if (file == null) return new(sessions, []);
            using var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = file, Mode = SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 1 }.ToString());
            db.Open();
            var columns = new HashSet<string>();
            using (var schema = db.CreateCommand())
            {
                schema.CommandText = "PRAGMA table_info(threads)";
                using var rows = schema.ExecuteReader();
                while (rows.Read()) columns.Add(rows.GetString(1));
            }
            if (!columns.Contains("id") || !columns.Contains("cwd")) return new(sessions, []);
            string Column(string name) => columns.Contains(name) ? name : "NULL";
            var updated = columns.Contains("updated_at_ms") ? $"COALESCE(updated_at_ms, {Column("updated_at")} * 1000)" : $"{Column("updated_at")} * 1000";
            using var command = db.CreateCommand();
            // Legacy app indexes leave has_user_event at zero for valid user conversations.
            command.CommandText = $"SELECT id,cwd,{Column("rollout_path")},{Column("name")},{Column("title")},{Column("source")},{Column("originator")},{updated} FROM threads ORDER BY 8 DESC LIMIT 5000";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                string? Text(int index) => reader.IsDBNull(index) ? null : reader.GetString(index);
                var id = Text(0); var cwd = Text(1); var source = Text(5);
                if (!Guid.TryParse(id, out _) || !ProjectPaths.IsWindowsAbsolute(cwd)) continue;
                var child = source?.StartsWith("subagent", StringComparison.OrdinalIgnoreCase) == true;
                if (source?.StartsWith('{') == true)
                    try { using var metadata = JsonDocument.Parse(source); child |= metadata.RootElement.TryGetProperty("subagent", out _); } catch (JsonException) { }
                var milliseconds = reader.IsDBNull(7) ? 0 : reader.GetInt64(7);
                sessions.Add(new Session { Model = "codex", Project = ProjectPaths.Name(cwd), ProjectDirectory = cwd,
                    Command = Commands.Build("codex", id!), DetectedAutomatically = true,
                    DetectedName = SessionNames.Clean(Text(3)) ?? SessionNames.Clean(Text(4)),
                    DetectedOrigin = SessionDiscovery.CodexOrigin(Text(6), source), IsSubagent = child,
                    HasLocalHistory = Text(2) is { } rollout && File.Exists(rollout),
                    CreatedAt = milliseconds >= -62135596800000 && milliseconds <= 253402300799999 ? DateTimeOffset.FromUnixTimeMilliseconds(milliseconds) : DateTimeOffset.UnixEpoch });
            }
            return new(sessions, []);
        }
        catch (Exception error) when (error is SqliteException or IOException or UnauthorizedAccessException)
        { return new(sessions, ["Some Codex history index entries could not be read."]); }
    }
}
