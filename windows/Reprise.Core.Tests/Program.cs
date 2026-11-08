using System.Text.Json;
using Reprise.Core;

var passed = 0;
void Check(bool condition, string message) { if (!condition) throw new Exception(message); passed++; }
var identifier = "8d4b841b-1552-4b11-9a32-33b9205b836a";
foreach (var tool in new[] { "codex", "claude", "grok" })
{
    var parsed = Commands.Parse($"PS C:\\Projects\\Billing Portal>\n{tool} --resume \"{identifier}\"");
    Check(parsed.Command == Commands.Build(tool, identifier), "OCR command canonicalization failed: " + tool);
    Check(parsed.Directory == @"C:\Projects\Billing Portal", "Windows prompt folder not found");
}
Check(ProjectPaths.Normalize(@"c:\Work\app\..\Project\") == ProjectPaths.Normalize("C:/WORK/Project"), "Windows directory normalization failed");
Check(ProjectPaths.Area(@"C:\Users\you\.codex\internal") == "Internal", "Internal sessions must be separate");
Check(ProjectPaths.Area(null) == "Unassigned", "Folderless captures must be separate");
var session = new Session { Model = "codex", Project = "Billing", ProjectDirectory = @"C:\Work\O'Brien; Stop-Process", Command = Commands.Build("codex", identifier) };
Check(Commands.PowerShellScript(session).Contains("'C:\\Work\\O''Brien; Stop-Process'"), "Folder must be a PowerShell literal");
try { Commands.ValidatedArguments(session.Command + "; whoami"); throw new Exception("Injected command accepted"); } catch (InvalidOperationException) { passed++; }
var codex = JsonSerializer.Serialize(new { type = "session_meta", payload = new { id = identifier, cwd = @"C:\Projects\Billing", originator = "codex-desktop", source = "vscode" } });
Check(SessionDiscovery.Parse(codex, "codex", DateTimeOffset.UtcNow)?.DetectedOrigin == "Desktop app", "Specific desktop origin must win over shared vscode source");
Check(SessionDiscovery.CodexOrigin(null, "vscode") == "Unknown", "Ambiguous origin should remain unknown");
var claude = JsonSerializer.Serialize(new { sessionId = identifier, cwd = @"C:\Projects\Billing", entrypoint = "cli" }) + "\n" + JsonSerializer.Serialize(new { sessionId = identifier, entrypoint = "claude-desktop" });
Check(SessionDiscovery.Parse(claude, "claude", DateTimeOffset.UtcNow)?.DetectedOrigin == "Multiple clients", "Claude mixed entrypoints not found");
Check(SessionDiscovery.Parse("[]\n{}\nbroken", "claude", DateTimeOffset.UtcNow) == null, "Malformed metadata must be skipped");
var grok = JsonSerializer.Serialize(new { info = new { id = identifier, cwd = @"C:\Projects\Grok" }, updated_at = "2026-01-01T01:02:03.123Z" });
var discoveredGrok = SessionDiscovery.Parse(grok, "grok", DateTimeOffset.UtcNow)!;
Check(discoveredGrok.Command == "grok --resume " + identifier && discoveredGrok.CreatedAt.Year == 2026 && discoveredGrok.DetectedOrigin == "Unknown", "Grok metadata invalid");
var grouped = ProjectGroup.Group([session, session with { Id = Guid.NewGuid(), Model = "claude", ProjectDirectory = @"c:\work\O'Brien; Stop-Process", Command = Commands.Build("claude", identifier) }]);
Check(grouped.Count == 1 && grouped[0].Sessions.Count == 2, "Different assistants must share one project row");
Check(ProjectGroup.Group([session, session with { Id = Guid.NewGuid(), ProjectDirectory = @"C:\Other\Billing" }]).Count == 2, "Equal names in different folders must stay separate");
var temporary = Path.Combine(Path.GetTempPath(), "RepriseCoreTests-" + Guid.NewGuid());
try
{
    var store = new SessionStore(temporary);
    store.Merge([session, session]); Check(store.Sessions.Count == 1, "Imports duplicated");
    store.Upsert(store.Sessions[0] with { Note = "Keep my edits", OriginOverride = "IDE extension" });
    store.Merge([session]); Check(store.Sessions[0].Note == "Keep my edits" && store.Sessions[0].Origin == "IDE extension", "Sync overwrote edits");
    store.Remove(store.Sessions[0]); store.Merge([session]); Check(store.Sessions.Count == 0, "Removed session re-imported");
    store.RestoreRemoved(); store.Merge([session]); Check(store.Sessions.Count == 1, "Removed session could not be restored");
    Check(new SessionStore(temporary).Sessions.Count == 1, "Persistence failed");
    var file = Path.Combine(temporary, "sessions.json"); File.WriteAllText(file, "broken library");
    var broken = new SessionStore(temporary); broken.Merge([session]); broken.Save();
    Check(File.ReadAllText(file) == "broken library" && broken.StorageError != null, "Unreadable library was overwritten");
    var preferences = Path.Combine(temporary, "preferences.json"); File.WriteAllText(preferences, "broken preferences");
    new SessionStore(temporary).SavePreferences(); Check(File.ReadAllText(preferences) == "broken preferences", "Unreadable preferences were overwritten");
}
finally { if (Directory.Exists(temporary)) Directory.Delete(temporary, true); }
Console.WriteLine($"Passed {passed} Windows core checks.");
