using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Reprise.Core;

public static class SessionNames
{
    public const int MaximumIndexBytes = 8 * 1024 * 1024;
    public const int MaximumClaudeTailBytes = 64 * 1024;

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
                if (Text(root, "type") != "custom-title" ||
                    root.TryGetProperty("isSidechain", out var sidechain) && sidechain.ValueKind == JsonValueKind.True) continue;
                var id = Text(root, "sessionId"); var name = Clean(Text(root, "customTitle"));
                if (!Guid.TryParse(id, out _) || name == null) continue;
                titles.Append('\n').Append(JsonSerializer.Serialize(new { type = "custom-title", sessionId = id, customTitle = name }));
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
