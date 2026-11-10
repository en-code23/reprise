using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Reprise.Core;

public static class SessionNames
{
    public const int MaximumIndexBytes = 8 * 1024 * 1024;
    public const int MaximumClaudeTailBytes = 256 * 1024;

    public static string? Clean(string? value)
    {
        if (value == null) return null;
        var name = Regex.Replace(value, @"[\p{Cc}\s]+", " ").Trim();
        return name.Length == 0 ? null : string.Concat(name.EnumerateRunes().Take(200).Select(rune => rune.ToString()));
    }

    public static Dictionary<string, string> ReadCodexIndex(string file)
    {
        if (!File.Exists(file)) return new(StringComparer.OrdinalIgnoreCase);
        using var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return ParseCodexIndex(ReadTail(input, MaximumIndexBytes));
    }

    public static Dictionary<string, string> ParseCodexIndex(string data)
    {
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in data.Split('\n'))
        {
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                var id = Text(root, "id"); var title = Text(root, "thread_name");
                if (!Guid.TryParse(id, out _) || title == null) continue;
                if (Clean(title) is { } name) names[id!] = name;
                else names.Remove(id!);
            }
            catch (JsonException) { }
        }
        return names;
    }

    public static string ClaudeTitleTail(Stream input)
    {
        if (input.Length <= 256 * 1024) return "";
        var titles = new StringBuilder();
        foreach (var line in ReadTail(input, MaximumClaudeTailBytes, 256 * 1024).Split('\n'))
        {
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (!Guid.TryParse(Text(root, "sessionId"), out _)) continue;
                var keys = new[] { "type", "sessionId", "cwd", "entrypoint", "isSidechain", "agentId", "customTitle", "aiTitle" };
                var metadata = root.EnumerateObject().Where(p => keys.Contains(p.Name)).ToDictionary(p => p.Name, p => (object?)p.Value.Clone());
                foreach (var key in new[] { "customTitle", "aiTitle" })
                    if (Text(root, key) is { } name) metadata[key] = Clean(name);
                titles.Append('\n').Append(JsonSerializer.Serialize(metadata));
            }
            catch (JsonException) { }
        }
        return titles.ToString();
    }

    private static string ReadTail(Stream input, int limit, long minimumStart = 0)
    {
        var start = Math.Max(minimumStart, input.Length - limit);
        input.Seek(start, SeekOrigin.Begin);
        var bytes = new byte[Math.Min(input.Length - start, limit)];
        var count = input.ReadAtLeast(bytes, bytes.Length, false);
        var offset = start == 0 ? 0 : Array.IndexOf(bytes, (byte)'\n', 0, count) + 1;
        if (start > 0 && offset == 0) return "";
        return Encoding.UTF8.GetString(bytes, offset, count - offset);
    }

    private static string? Text(JsonElement element, string key) => element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
