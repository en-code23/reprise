import Foundation
import Security
import CryptoKit
import Darwin

enum RoutingProbeError: Error { case missingTool, unavailable, invalidResponse, timedOut, loginNeeded }

enum RoutingTool {
    static func locate(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) +
            ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin", home + "/.bun/bin"]
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Bounded metadata subprocess. Never starts a model turn or executes a project script.
    static func run(_ tool: String, arguments: [String], timeout: TimeInterval = 12,
                    initial: Data? = nil, onLine: ((Data) -> Data?)? = nil) throws -> Data {
        guard let executable = locate(tool) else { throw RoutingProbeError.missingTool }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe(), input = Pipe()
        process.standardOutput = output; process.standardInput = input; process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate(); Darwin.kill(process.processIdentifier, SIGKILL) }
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
        if let initial { try input.fileHandleForWriting.write(contentsOf: initial) }
        else { try input.fileHandleForWriting.close() }
        let descriptor = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var all = Data(), pending = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = Darwin.poll(&poller, 1, 50)
            if ready < 0 { throw RoutingProbeError.unavailable }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count <= 0 {
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                guard !process.isRunning else { throw RoutingProbeError.timedOut }
                guard process.terminationStatus == 0 else { throw RoutingProbeError.unavailable }
                return all
            }
            all.append(contentsOf: bytes.prefix(count)); pending.append(contentsOf: bytes.prefix(count))
            guard all.count <= 2 * 1024 * 1024 else { throw RoutingProbeError.invalidResponse }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                if let reply = onLine?(line) {
                    if reply.isEmpty { return all }
                    try input.fileHandleForWriting.write(contentsOf: reply)
                }
            }
        }
        throw RoutingProbeError.timedOut
    }
}

enum RoutingPayload {
    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double, seconds.isFinite { return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func codex(models: [String: Any], usage: [String: Any], now: Date) -> ProviderRoutingState {
        var state = ProviderRoutingState(provider: .codex, observedAt: now)
        let rows = models["data"] as? [[String: Any]] ?? []
        state.models = rows.compactMap { row in
            guard let id = row["model"] as? String ?? row["id"] as? String, row["hidden"] as? Bool != true else { return nil }
            let efforts = (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
                .filter { ["low", "medium", "high", "xhigh", "max"].contains($0) }
            let lower = id.lowercased()
            let role: ModelRole = lower.contains("astra") ? .frontier : lower.contains("luna") || lower.contains("mini") ? .economy : lower.contains("sol") || row["isDefault"] as? Bool == true ? .strong : .balanced
            let model = RoutingModel(id: id, name: row["displayName"] as? String ?? id, role: role, efforts: efforts)
            return model.valid ? model : nil
        }
        // Prefer the current model in each family, without guessing a version that is not in model/list.
        state.models = state.models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedDescending }
            .reduce(into: [RoutingModel]()) { selected, model in
                let family = model.id.replacingOccurrences(of: #"[0-9]+(?:\.[0-9]+)*"#, with: "#", options: .regularExpression)
                if !selected.contains(where: { $0.id.replacingOccurrences(of: #"[0-9]+(?:\.[0-9]+)*"#, with: "#", options: .regularExpression) == family }) { selected.append(model) }
            }
        let buckets = usage["rateLimitsByLimitId"] as? [String: [String: Any]] ??
            (usage["rateLimits"] as? [String: Any]).map { ["codex": $0] } ?? [:]
        for (id, bucket) in buckets {
            if let plan = bucket["planType"] as? String { state.subscription = plan != "api" }
            if bucket["spendControlReached"] as? Bool == true { state.blocked = true }
            for key in ["primary", "secondary"] {
                guard let row = bucket[key] as? [String: Any], let used = row["usedPercent"] as? Double,
                      let reset = date(row["resetsAt"]) else { continue }
                let slug = bucket["normalModelSlug"] as? String
                let specific = slug.flatMap { slug in state.models.contains { $0.id == slug } ? [slug] : nil } ?? []
                state.windows.append(QuotaWindow(id: id + "." + key, label: (bucket["limitName"] as? String ?? id) + (key == "primary" ? " · short window" : " · weekly window"),
                    usedPercent: used, resetsAt: reset, durationMinutes: row["windowDurationMins"] as? Double, modelIDs: specific, observedAt: now))
            }
        }
        state.blocked = state.blocked || usage["ordinaryUsageAllowed"] as? Bool == false
        state.status = state.windows.isEmpty ? "Codex did not return subscription usage. Existing tool settings will be used conservatively." : "Usage and available models read from Codex."
        return state
    }

    static func claude(_ payload: [String: Any], subscription: Bool, fableKey: String?, now: Date) -> ProviderRoutingState {
        var state = ProviderRoutingState(provider: .claude, models: [
            RoutingModel(id: "haiku", name: "Claude Haiku", role: .economy, efforts: ["low", "medium", "high"]),
            RoutingModel(id: "sonnet", name: "Claude Sonnet", role: .balanced, efforts: ["low", "medium", "high"]),
            RoutingModel(id: "opus", name: "Claude Opus", role: .strong, efforts: ["low", "medium", "high", "xhigh", "max"]),
            RoutingModel(id: "claude-fable-5-2", name: "Claude Fable 5.2", role: .frontier, efforts: ["low", "medium", "high", "xhigh", "max"], requiresSpecialAllowance: true)
        ], observedAt: now, subscription: subscription)
        for (key, value) in payload {
            guard let row = value as? [String: Any], let used = row["utilization"] as? Double ?? row["used_percentage"] as? Double,
                  let reset = date(row["resets_at"]) else { continue }
            let special = key.lowercased().contains("fable") || key == fableKey
            let modelIDs = special ? ["claude-fable-5-2"] : key == "seven_day_opus" ? ["opus"] : key == "seven_day_sonnet" ? ["sonnet"] : []
            // Unknown windows are displayed and conservatively constrain all models. Never guess which one is Fable.
            let label = special ? "Fable allowance" : key == "five_hour" ? "Claude · 5 hours" : key == "seven_day" ? "Claude · all models weekly" : key
            state.windows.append(QuotaWindow(id: key, label: label, usedPercent: used, resetsAt: reset,
                durationMinutes: key == "five_hour" ? 300 : key.hasPrefix("seven_day") ? 10080 : nil,
                modelIDs: modelIDs, specialAllowance: special, observedAt: now))
        }
        state.status = state.windows.isEmpty ? "Claude did not return usable quota windows." : "Claude usage refreshed. Fable also needs a confirmed separate allowance."
        return state
    }

    static func grok(models text: String, usage: [String: Any], now: Date) -> ProviderRoutingState {
        var state = ProviderRoutingState(provider: .grok, observedAt: now)
        state.models = text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* "), let id = trimmed.dropFirst(2).split(separator: " ").first.map(String.init) else { return nil }
            let model = RoutingModel(id: id, name: id, role: id.contains("fast") || id.contains("mini") ? .economy : .strong, efforts: ["low", "medium", "high", "xhigh"])
            return model.valid ? model : nil
        }
        // Accept the CLI's structured plan-limit fields only, not token totals or dollar spend.
        func inspect(_ object: [String: Any], prefix: String = "") {
            if let used = object["used_percentage"] as? Double ?? object["usedPercent"] as? Double ?? object["utilization"] as? Double,
               let reset = date(object["resets_at"] ?? object["resetsAt"] ?? object["reset_at"]) {
                state.windows.append(QuotaWindow(id: prefix.isEmpty ? "grok.weekly" : prefix, label: "Grok · plan usage", usedPercent: used,
                    resetsAt: reset, durationMinutes: object["windowDurationMins"] as? Double ?? 10080, observedAt: now))
            }
            if prefix.split(separator: ".").count < 4 {
                for (key, value) in object { if let nested = value as? [String: Any], key != "extra_usage" { inspect(nested, prefix: prefix + "." + key) } }
            }
        }
        inspect(usage)
        state.subscription = !state.windows.isEmpty
        if text.contains("not authenticated") { state.models = []; state.status = "Sign in to Grok Build to read its available models." }
        else { state.status = state.windows.isEmpty ? "Grok's CLI did not expose a usable plan limit. Usage stays unknown." : "Grok plan usage and models refreshed." }
        return state
    }
}

enum RoutingProviders {
    static func codex(now: Date = .now) throws -> ProviderRoutingState {
        func message(_ object: [String: Any]) -> Data { var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data(); data.append(10); return data }
        var models: [String: Any]?, usage: [String: Any]?
        _ = try RoutingTool.run("codex", arguments: ["app-server"], initial: message(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "reprise", "title": "Reprise", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"]]])) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int else { return nil }
            if id == 1 {
                return message(["method": "initialized", "params": [:]]) + message(["id": 2, "method": "model/list", "params": ["limit": 100, "includeHidden": false]]) + message(["id": 3, "method": "account/rateLimits/read"])
            }
            if id == 2 { models = object["result"] as? [String: Any] ?? [:] }
            if id == 3 { usage = object["result"] as? [String: Any] ?? [:] }
            return models != nil && usage != nil ? Data() : nil
        }
        guard let models, let usage else { throw RoutingProbeError.invalidResponse }
        return RoutingPayload.codex(models: models, usage: usage, now: now)
    }

    static func grok(now: Date = .now) throws -> ProviderRoutingState {
        let models = try RoutingTool.run("grok", arguments: ["models"])
        let usage = (try? RoutingTool.run("grok", arguments: ["usage", "--json"])) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: usage) as? [String: Any]) ?? [:]
        return RoutingPayload.grok(models: String(decoding: models, as: UTF8.self), usage: object, now: now)
    }

    /// Uses Claude Code's existing subscription login only after the user explicitly connects it.
    /// Tokens are neither logged nor written into Reprise's settings or cache.
    static func claude(fableKey: String?, now: Date = .now) async throws -> ProviderRoutingState {
        let credentials = try await Task.detached { () throws -> (String, Bool) in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
            var data: Data?
            let file = root.appendingPathComponent(".credentials.json")
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 64 * 1024 { data = try? Data(contentsOf: file) }
            if data == nil {
                var services = ["Claude Code-credentials"]
                if ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] != nil {
                    let hash = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
                    services.insert("Claude Code-credentials-" + hash.prefix(8), at: 0)
                }
                for service in services {
                    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: service, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
                    var item: CFTypeRef?
                    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let found = item as? Data { data = found; break }
                }
            }
            guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty else { throw RoutingProbeError.loginNeeded }
            if let expiry = RoutingPayload.date(oauth["expiresAt"]), expiry <= Date() { throw RoutingProbeError.loginNeeded }
            let plan = oauth["subscriptionType"] as? String ?? ""
            return (token, ["pro", "max", "ultra", "team", "enterprise"].contains(plan.lowercased()))
        }.value
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 10
        request.setValue("Bearer " + credentials.0, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 512 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RoutingProbeError.unavailable }
        var state = RoutingPayload.claude(object, subscription: credentials.1, fableKey: fableKey, now: now)
        let version = try? RoutingTool.run("claude", arguments: ["--version"], timeout: 3)
        let text = version.map { String(decoding: $0, as: UTF8.self).split(separator: " ").first.map(String.init) ?? "" } ?? ""
        if text.compare("2.1.321", options: .numeric) == .orderedAscending { state.models.removeAll { $0.requiresSpecialAllowance } }
        return state
    }
}
