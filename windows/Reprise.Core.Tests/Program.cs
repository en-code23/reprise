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
Check(SessionNames.Clean(" \n\t") == null && SessionNames.Clean("  Fix\n checkout\t👩‍💻  ") == "Fix checkout 👩‍💻", "Name normalization must preserve Unicode and remove control whitespace");
var legacy = JsonSerializer.Deserialize<Session>(JsonSerializer.Serialize(session, SessionStore.Json), SessionStore.Json)!;
Check(legacy.Name == null && legacy.DisplayName == "Session · 205b836a", "Unnamed libraries must keep a readable ID fallback");
var named = session with { Name = "Checkout work" };
Check(named.Command == session.Command && named.Identity == session.Identity, "Names must not change resume commands or identity");
Check(ProjectGroup.Group([named], query: "checkout work").Count == 1, "Names must be searchable without changing project grouping");
var nameIndex = JsonSerializer.Serialize(new { id = identifier, thread_name = "Original" }) + "\nbroken\n" + JsonSerializer.Serialize(new { id = identifier, thread_name = "Newest" }) + "\n{\"id\":";
Check(SessionNames.ParseCodexIndex(nameIndex)[identifier] == "Newest", "Last valid Codex rename must win");
var title = JsonSerializer.Serialize(new { type = "custom-title", sessionId = identifier, customTitle = "Checkout retries" });
var wrongTitle = JsonSerializer.Serialize(new { type = "custom-title", sessionId = Guid.NewGuid().ToString(), customTitle = "Wrong session" });
Check(SessionDiscovery.Parse(claude + "\n" + title + "\n" + wrongTitle, "claude", DateTimeOffset.UtcNow)?.DetectedName == "Checkout retries", "Claude names must match the session ID");
var grokWithTitle = JsonSerializer.Serialize(new { info = new { id = identifier, cwd = @"C:\Projects\Grok" }, generated_title = "Webhook tests", session_summary = "Private conversation summary" });
var namedGrok = SessionDiscovery.Parse(grokWithTitle, "grok", DateTimeOffset.UtcNow)!;
Check(namedGrok.DisplayName == "Webhook tests" && !JsonSerializer.Serialize(namedGrok).Contains("Private conversation summary"), "Import the Grok title without retaining its summary");
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
    var namesFolder = Path.Combine(temporary, "names");
    var nameStore = new SessionStore(namesFolder);
    var imported = session with { DetectedName = "Original title" };
    nameStore.Merge([imported with { }]);
    nameStore.Upsert(nameStore.Sessions[0] with { Name = " My checkout work ", Note = "Keep my note" });
    imported.DetectedName = "Renamed upstream"; nameStore.Merge([imported with { }]);
    Check(nameStore.Sessions[0].DisplayName == "My checkout work" && nameStore.Sessions[0].DetectedName == "Renamed upstream" && nameStore.Sessions[0].Note == "Keep my note", "Sync must update imported names and preserve custom names and notes");
    Check(new SessionStore(namesFolder).Sessions[0].DisplayName == "My checkout work", "Names must persist across restart");
    nameStore.Upsert(session with { Id = Guid.NewGuid() });
    Check(nameStore.Sessions.Count == 1 && nameStore.Sessions[0].DisplayName == "My checkout work", "Duplicate capture must preserve the session name");
    nameStore.Upsert(nameStore.Sessions[0] with { Name = " " });
    Check(nameStore.Sessions[0].DisplayName == "Renamed upstream", "Clearing a custom name must restore the imported name");
    var boundedIndex = Path.Combine(temporary, "large-index.jsonl");
    File.WriteAllText(boundedIndex, new string('x', SessionNames.MaximumIndexBytes + 100) + "\n" + nameIndex);
    Check(SessionNames.ReadCodexIndex(boundedIndex)[identifier] == "Newest", "Codex index reads must reach recent names while bounded");
    var home = Path.Combine(temporary, "discovery");
    var roots = new Dictionary<string, string?> { ["CODEX_HOME"] = Path.Combine(home, "codex"), ["CLAUDE_CONFIG_DIR"] = Path.Combine(home, "claude"), ["GROK_HOME"] = Path.Combine(home, "grok") };
    Directory.CreateDirectory(Path.Combine(roots["CODEX_HOME"]!, "sessions", "subagents"));
    Directory.CreateDirectory(Path.Combine(roots["CLAUDE_CONFIG_DIR"]!, "projects"));
    Directory.CreateDirectory(Path.Combine(roots["GROK_HOME"]!, "sessions", "one"));
    Directory.CreateDirectory(Path.Combine(roots["GROK_HOME"]!, "sessions", "oversize"));
    File.WriteAllText(Path.Combine(roots["CODEX_HOME"]!, "sessions", "main.jsonl"), codex + "\n" + new string('x', 300_000));
    File.WriteAllText(Path.Combine(roots["CODEX_HOME"]!, "session_index.jsonl"), nameIndex);
    File.WriteAllText(Path.Combine(roots["CODEX_HOME"]!, "sessions", "subagents", "child.jsonl"), codex);
    File.WriteAllText(Path.Combine(roots["CLAUDE_CONFIG_DIR"]!, "projects", "main.jsonl"), claude + "\n" + new string('x', 400_000) + "\n" + title);
    File.WriteAllText(Path.Combine(roots["GROK_HOME"]!, "sessions", "one", "summary.json"), grok);
    File.WriteAllText(Path.Combine(roots["GROK_HOME"]!, "sessions", "oversize", "summary.json"), new string('x', 1024 * 1024 + 1));
    var scan = SessionDiscovery.Scan(home, roots);
    Check(scan.Sessions.Count == 3, "Discovery must skip subagents and oversized metadata");
    Check(scan.Sessions.All(s => s.Note.Length == 0), "Discovery must not retain conversation content");
    Check(scan.Sessions.Single(s => s.Model == "codex").DetectedName == "Newest" && scan.Sessions.Single(s => s.Model == "claude").DetectedName == "Checkout retries", "Discovery must join the Codex name index and bounded Claude rename tail");
    Check(scan.Warnings.Count == 1, "Oversized summaries should be reported");
}
finally { if (Directory.Exists(temporary)) Directory.Delete(temporary, true); }
Console.WriteLine($"Passed {passed} Windows core checks.");
