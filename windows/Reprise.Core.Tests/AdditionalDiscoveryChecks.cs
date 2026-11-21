using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using Reprise.Core;

static class AdditionalDiscoveryChecks
{
    public static int Run()
    {
        var passed = 0;
        void Check(bool value, string message) { if (!value) throw new Exception(message); passed++; }
        var root = Path.Combine(Path.GetTempPath(), "reprise-assistants-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        void Write(string path, object data)
        {
            var file = Path.Combine(root, path); Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, JsonSerializer.Serialize(data));
        }
        void Sql(string path, string sql)
        {
            var file = Path.Combine(root, path); Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            using var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = file, Pooling = false }.ToString()); db.Open();
            using var command = db.CreateCommand(); command.CommandText = sql; command.ExecuteNonQuery();
        }
        try
        {
            const string id = "8d4b841b-1552-4b11-9a32-33b9205b836a";
            foreach (var (client, input, expected) in new[] { ("gemini", "gemini -r", "gemini --resume"), ("moonshot", "kimi -r", "kimi --session"), ("antigravity", "agy --conversation", "agy --conversation"), ("opencode", "opencode -s", "opencode --session") })
            {
                var parsed = Commands.Parse(input + " \"" + id + "\"");
                Check(parsed.Model == client && parsed.Command == expected + " " + id, "Native resume parsing: " + client);
                Check(Commands.ValidatedArguments(parsed.Command)[2] == id, "Native launch command: " + client);
                try { Commands.ValidatedArguments(parsed.Command + "; whoami"); throw new Exception("Shell injection accepted"); }
                catch (InvalidOperationException) { passed++; }
            }
            Check(Commands.Parse("GLM\nopencode --session ses_123456").Model == "glm", "Provider labels must preserve the host command");
            Write(".gemini/projects.json", new { projects = new Dictionary<string, string> { [@"C:\Work\Billing"] = "billing" } });
            Write(".gemini/tmp/billing/chats/session-old.json", new { sessionId = id, summary = "Checkout retry", lastUpdated = "2026-11-21T12:00:00Z", messages = new[] { new { content = "PRIVATE PROMPT" } } });
            Write(".gemini/tmp/billing/chats/session-child.json", new { sessionId = "child_123456", kind = "subagent" });
            File.WriteAllText(Path.Combine(root, ".gemini/tmp/billing/chats/session-bad.json"), "broken");
            var jsonl = Path.Combine(root, ".gemini/tmp/billing/chats/session-new.jsonl");
            File.WriteAllText(jsonl, JsonSerializer.Serialize(new { sessionId = "session_abcdef", projectHash = "billing", kind = "main" }) + "\n" + new string('x', 700_000) + "\n" + "{\"$set\":{\"summary\":\"Newest title\",\"lastUpdated\":\"2026-11-21T12:30:00Z\"}}\n");
            var gemini = AdditionalSessionDiscovery.Gemini(Path.Combine(root, ".gemini"));
            Check(gemini.Count == 2 && gemini.All(s => s.ProjectDirectory == @"C:\Work\Billing"), "Gemini JSON/JSONL project association and child filtering");
            Check(gemini.Single(s => s.SessionIdentifier == "session_abcdef").DetectedName == "Newest title", "Gemini tail metadata updates");
            Check(!JsonSerializer.Serialize(gemini).Contains("PRIVATE PROMPT"), "Gemini prompt content must not be imported");

            var hash = Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(@"C:\Work\Kimi"))).ToLowerInvariant();
            Write(".kimi/kimi.json", new { work_dirs = new[] { new { path = @"C:\Work\Kimi", kaos = "local" } } });
            Write($".kimi/sessions/{hash}/{id}/state.json", new { custom_title = "Kimi retry" });
            File.WriteAllText(Path.Combine(root, $".kimi/sessions/{hash}/{id}/context.jsonl"), "PRIVATE CONTEXT");
            File.WriteAllText(Path.Combine(root, $".kimi/sessions/{hash}/legacy_123456.jsonl"), "PRIVATE LEGACY");
            Write(".kimi-code/sessions/wd_hash/session_abcdef/state.json", new { id = "session_abcdef", cwd = @"C:\Work\Kimi", title = "New Kimi", updatedAt = 1795262400000L });
            var wire = Path.Combine(root, ".kimi-code/sessions/wd_hash/session_abcdef/agents/main/wire.jsonl"); Directory.CreateDirectory(Path.GetDirectoryName(wire)!); File.WriteAllText(wire, "PRIVATE WIRE");
            var kimi = AdditionalSessionDiscovery.Kimi(Path.Combine(root, ".kimi"));
            var kimiCode = AdditionalSessionDiscovery.KimiCode(Path.Combine(root, ".kimi-code"));
            Check(kimi.Count == 2 && kimiCode.Count == 1, "Both Kimi formats and legacy context files");
            Check(kimi.Single(s => s.SessionIdentifier == id).DetectedName == "Kimi retry", "Kimi custom title");
            Check(kimiCode[0].Command == "kimi --session session_abcdef" && kimiCode[0].Model == "moonshot", "Kimi Code native resume");

            Sql("opencode/opencode.db", """
                CREATE TABLE session(id TEXT,directory TEXT,title TEXT,time_updated INTEGER,parent_id TEXT);
                CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT);
                INSERT INTO session VALUES ('ses_deepseek','C:\Work\App','Old title',1000000000000,NULL);
                INSERT INTO message VALUES ('msg_1','ses_deepseek',1,'{"role":"assistant","modelID":"deepseek-chat","providerID":"deepseek"}');
                INSERT INTO session VALUES ('ses_child','C:\Work\App','Child',1000000000000,'ses_deepseek');
                CREATE TABLE session_v2(id TEXT,directory TEXT,title TEXT,time_updated INTEGER,parent_id TEXT,model TEXT);
                CREATE TABLE session_message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT);
                INSERT INTO session_v2 VALUES ('ses_deepseek','C:\Work\App','Latest title',1795262400000,NULL,'{"id":"glm-5","providerID":"zai-coding-plan"}');
                INSERT INTO session_v2 VALUES ('ses_kimi123','C:\Work\App','Kimi',1795262400000,NULL,'{"id":"moonshotai/kimi-k2","providerID":"openrouter"}');
                INSERT INTO session_v2 VALUES ('ses_generic','C:\Work\App','Generic',1795262400000,NULL,'{"id":"gpt-6","providerID":"openai"}');
                INSERT INTO session_message VALUES ('msg_2','ses_generic',1,'{"role":"assistant","modelID":"deepseek-chat","providerID":"deepseek"}');
                """);
            var dbFile = Path.Combine(root, "opencode/opencode.db"); var before = File.ReadAllBytes(dbFile);
            var openCode = AdditionalSessionDiscovery.OpenCode(Path.Combine(root, "opencode"));
            Check(openCode.Count == 3 && openCode.Single(s => s.Model == "glm").DetectedName == "Latest title", "OpenCode migration deduplication and model detection");
            Check(openCode.Single(s => s.SessionIdentifier == "ses_generic").Model == "opencode", "Current model metadata must win over an older reply's provider");
            Check(openCode.Single(s => s.Model == "glm").Command == "opencode --session ses_deepseek", "GLM must reopen through its recorded client");
            Check(before.SequenceEqual(File.ReadAllBytes(dbFile)), "OpenCode database must remain unchanged");
            var glm = openCode.Single(s => s.Model == "glm"); var identity = glm.Identity; glm.Model = "deepseek";
            Check(glm.Identity == identity, "Provider changes must not change session identity");
            Write("legacy/storage/session/project/ses_legacy.json", new { id = "ses_legacy", directory = @"C:\Work\Legacy", title = "Legacy", time = new { updated = 1795262400000L } });
            Write("legacy/storage/message/ses_legacy/msg_latest.json", new { role = "assistant", modelID = "deepseek-v4", content = "PRIVATE MESSAGE" });
            var old = AdditionalSessionDiscovery.OpenCode(Path.Combine(root, "legacy"));
            Check(old.Count == 1 && old[0].Model == "deepseek", "OpenCode pre-database history");

            Sql("agy/conversation_summaries.db", $"""
                CREATE TABLE conversation_summaries(conversation_id TEXT,title TEXT,workspace_uris TEXT,last_modified_time TEXT,parent_conversation_id TEXT,nesting_depth INTEGER,source TEXT);
                INSERT INTO conversation_summaries VALUES ('{id}','CLI work','["file:///C:/Work/Billing%20Portal"]','2026-11-21 12:30:00.123456+00:00','',0,'cli');
                INSERT INTO conversation_summaries VALUES ('child_123456','Child','[]','2026-11-21T12:00:00Z','{id}',1,'cli');
                """);
            var agy = AdditionalSessionDiscovery.Antigravity(Path.Combine(root, "agy"));
            Check(agy.Count == 1 && agy[0].Command == "agy --conversation " + id, "Antigravity native command and child filtering");
            Check(agy[0].CreatedAt.Year == 2026 && agy[0].DetectedOrigin == "CLI", "Antigravity timestamps and source");

            var header = JsonSerializer.Serialize(new { type = "user", sessionId = id, cwd = @"C:\Work\Billing", entrypoint = "cli" }) + "\n";
            var reply = JsonSerializer.Serialize(new { type = "assistant", sessionId = id, message = new { model = "glm-5", content = "PRIVATE REPLY" } }) + "\n";
            var imported = SessionDiscovery.Parse(header + reply, "claude", DateTimeOffset.UtcNow)!;
            Check(imported.Model == "glm" && imported.Command == "claude --resume " + id, "Claude Code provider metadata");
            Check(SessionDiscovery.Parse(header + reply + reply.Replace("glm-5", "claude-sonnet"), "claude", DateTimeOffset.UtcNow)!.Model == "claude", "Latest recorded model must win");
            var store = new SessionStore(Path.Combine(root, "store")); store.Merge([imported with { Model = "claude", Name = "My name", Note = "Keep note" }]); store.Merge([imported]);
            Check(store.Sessions.Count == 1 && store.Sessions[0].Model == "glm" && store.Sessions[0].Name == "My name" && store.Sessions[0].Note == "Keep note", "Reclassification must preserve library data");
            store.Upsert(store.Sessions[0] with { AssistantOverride = "deepseek", Model = "deepseek" }); store.Merge([imported with { }]);
            Check(store.Sessions[0].Model == "deepseek", "Manual assistant override must survive sync");
            store.Upsert(store.Sessions[0] with { AssistantOverride = null, Model = store.Sessions[0].DetectedAssistant! });
            Check(store.Sessions[0].Model == "glm" && store.Sessions[0].AssistantOverride == null, "Automatic assistant classification can be restored");
            using var stream = new MemoryStream(Encoding.UTF8.GetBytes(header + new string('x', 600_000) + "\n" + reply.Replace("glm-5", "deepseek-chat")));
            var tail = SessionNames.ClaudeTitleTail(stream);
            Check(!tail.Contains("PRIVATE REPLY") && SessionDiscovery.Parse(header + tail, "claude", DateTimeOffset.UtcNow)!.Model == "deepseek", "Bounded provider tail must retain metadata only");
            Check(AdditionalSessionDiscovery.Create("opencode", "bad;rm", @"C:\Work", null) == null, "Unsafe session identifier rejected");
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
        return passed;
    }
}
