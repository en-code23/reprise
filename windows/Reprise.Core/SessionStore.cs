using System.Text.Json;

namespace Reprise.Core;

public sealed class Preferences
{
    public bool AutoDiscovery { get; set; } = true;
    public string Terminal { get; set; } = "Windows Terminal";
    public string? EditorPath { get; set; }
    public HashSet<string> Dismissed { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class SessionStore
{
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    private readonly string directory;
    private bool canWrite = true;
    private bool canWritePreferences = true;
    public List<Session> Sessions { get; private set; } = [];
    public Preferences Preferences { get; private set; } = new();
    public string? StorageError { get; private set; }
    public string DataDirectory => directory;

    public SessionStore(string directory)
    {
        this.directory = directory;
        System.IO.Directory.CreateDirectory(directory);
        var file = Path.Combine(directory, "sessions.json");
        if (File.Exists(file))
        {
            try
            {
                Sessions = JsonSerializer.Deserialize<List<Session>>(File.ReadAllText(file), Json) ?? throw new JsonException();
                Sessions = Sessions.Select(s => s with { Command = Commands.Canonicalize(s.Command) }).ToList();
            }
            catch { canWrite = false; StorageError = "Your saved library could not be read. It will not be overwritten. Open the data folder to restore a backup."; }
        }
        var settings = Path.Combine(directory, "preferences.json");
        if (File.Exists(settings))
        {
            try { Preferences = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(settings), Json) ?? new(); }
            catch { canWritePreferences = false; StorageError ??= "Preferences could not be read. Defaults are being used; the original preferences will be preserved."; }
        }
        Preferences.Dismissed = new(Preferences.Dismissed, StringComparer.OrdinalIgnoreCase);
    }
    private void AtomicWrite(string name, string data)
    {
        var destination = Path.Combine(directory, name);
        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, data); File.Move(temporary, destination, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public void Save()
    {
        if (!canWrite) return;
        try { AtomicWrite("sessions.json", JsonSerializer.Serialize(Sessions, Json)); StorageError = canWritePreferences ? null : "Preferences could not be read. Defaults are being used; the original preferences will be preserved."; }
        catch { StorageError = "Your changes could not be saved. The previous library remains on disk."; }
    }
    public void SavePreferences() { if (canWritePreferences) AtomicWrite("preferences.json", JsonSerializer.Serialize(Preferences, Json)); }
    public void Upsert(Session session)
    {
        session.Command = Commands.Canonicalize(session.Command);
        session.Name = SessionNames.Clean(session.Name);
        var index = Sessions.FindIndex(s => s.Id == session.Id || s.Identity.Equals(session.Identity, StringComparison.OrdinalIgnoreCase));
        if (index >= 0) Sessions[index] = session with { Id = Sessions[index].Id,
            Name = session.Id == Sessions[index].Id ? session.Name : session.Name ?? Sessions[index].Name,
            DetectedName = session.DetectedName ?? Sessions[index].DetectedName,
            IsSubagent = session.IsSubagent ?? Sessions[index].IsSubagent,
            HasLocalHistory = session.HasLocalHistory ?? Sessions[index].HasLocalHistory };
        else Sessions.Add(session);
        Preferences.Dismissed.Remove(session.Identity);
        Save(); SavePreferences();
    }
    public void Merge(IEnumerable<Session> incoming)
    {
        foreach (var session in incoming)
        {
            if (Preferences.Dismissed.Contains(session.Identity)) continue;
            var previous = Sessions.FirstOrDefault(s => s.Identity.Equals(session.Identity, StringComparison.OrdinalIgnoreCase));
            if (previous == null) Sessions.Add(session);
            else
            {
                if (ProjectPaths.Normalize(previous.ProjectDirectory) == null && ProjectPaths.Normalize(session.ProjectDirectory) != null)
                {
                    previous.ProjectDirectory = session.ProjectDirectory;
                    if (string.IsNullOrWhiteSpace(previous.Project) || System.Text.RegularExpressions.Regex.IsMatch(previous.Project, @"^(screenshot|bildschirmfoto|screen shot|untitled project)", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                        previous.Project = session.Project;
                }
                previous.CreatedAt = session.CreatedAt;
                previous.DetectedOrigin = session.DetectedOrigin;
                if (session.IsSubagent is { } isSubagent) previous.IsSubagent = isSubagent;
                if (session.HasLocalHistory is { } available) previous.HasLocalHistory = available;
                if (SessionNames.Clean(session.DetectedName) is { } name) previous.DetectedName = name;
            }
        }
        Sessions = Sessions.OrderByDescending(s => s.CreatedAt).ToList(); Save();
    }
    public void Remove(Session session)
    {
        Preferences.Dismissed.Add(session.Identity); Sessions.RemoveAll(s => s.Id == session.Id);
        SavePreferences(); Save();
    }
    public void RestoreRemoved() { Preferences.Dismissed.Clear(); SavePreferences(); }
}
