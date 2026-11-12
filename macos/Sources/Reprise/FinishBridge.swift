import Foundation

enum FinishFiles {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Reprise")
    }
    static func preferences(in directory: URL) -> FinishPreferences? {
        let file = directory.appendingPathComponent("finish-actions.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 65536,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(FinishPreferences.self, from: data)
    }
    static func write(_ event: FinishEvent, in directory: URL) throws {
        let lease = directory.appendingPathComponent("finish-monitor.json")
        guard event.valid, preferences(in: directory)?.enabled == true,
              let leaseData = try? Data(contentsOf: lease), leaseData.count < 1024,
              let active = try? JSONSerialization.jsonObject(with: leaseData) as? [String: Any],
              let updated = active["updatedAt"] as? Double,
              updated <= Date().timeIntervalSince1970 + 5, Date().timeIntervalSince1970 - updated < 15 else { return }
        let queue = directory.appendingPathComponent("finish-events")
        if (try? queue.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return }
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = queue.appendingPathComponent(event.id + ".json")
        try JSONEncoder().encode(event).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum FinishHookPayload {
    static func event(provider: String, payload: [String: Any], notify: Bool = false,
                      environment: [String: String] = [:], now: Date = .now) -> FinishEvent? {
        let name = payload["hook_event_name"] as? String ?? ""
        let childEvent = ["SubagentStart", "SubagentStop"].contains(name)
        let transcript = payload["transcript_path"] as? String ?? ""
        if !childEvent && (payload["subagentType"] as? String != nil || (provider == "codex" && payload["agent_type"] as? String != nil) ||
            payload["isSidechain"] as? Bool == true || transcript.contains("/subagents/") || transcript.contains("/agent-")) { return nil }
        let session = payload["session_id"] as? String ?? payload["sessionId"] as? String ??
            payload["thread-id"] as? String ?? (provider == "grok" ? environment["GROK_SESSION_ID"] : nil) ?? ""
        let target = FinishTarget(provider: provider, sessionId: session)
        guard target.valid else { return nil }
        let turn = payload["turn_id"] as? String ?? payload["turn-id"] as? String ?? payload["promptId"] as? String
        let kind: FinishEvent.Kind
        if notify {
            guard provider == "codex", payload["type"] as? String == "agent-turn-complete" else { return nil }
            kind = .completed
        } else {
            switch name {
            case "UserPromptSubmit": kind = .started
            case "PreModelRequest", "PostToolUse": kind = .active
            case "PreToolUse": kind = ["AskUserQuestion", "request_user_input"].contains(payload["tool_name"] as? String ?? "") ? .waiting : .active
            case "PermissionRequest", "PermissionDenied": kind = .waiting
            case "Stop":
                if provider == "codex" { return nil } // Codex notify is the post-turn signal.
                if provider == "grok", let reason = payload["reason"] as? String, reason != "end_turn" { return nil }
                kind = .candidate
            case "StopFailure": kind = .failed
            case "StopCancelled", "Interrupt": kind = .cancelled
            case "SessionEnd": kind = .closed
            case "SubagentStart": kind = .childStarted
            case "SubagentStop": kind = .childFinished
            case "Notification":
                let type = payload["notification_type"] as? String ?? payload["notificationType"] as? String ?? ""
                if type == "idle_prompt" { kind = .idle }
                else if ["permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog"].contains(type) { kind = .waiting }
                else { return nil }
            default: return nil
            }
        }
        let event = FinishEvent(id: UUID().uuidString, provider: provider, sessionId: session.lowercased(), turnId: turn,
            kind: kind, source: "hook", occurredAt: now.timeIntervalSince1970,
            childId: childEvent ? (payload["agent_id"] as? String ?? payload["agentId"] as? String) : nil,
            backgroundWork: !(payload["background_tasks"] as? [Any] ?? payload["backgroundTasks"] as? [Any] ?? []).isEmpty ||
                !(payload["session_crons"] as? [Any] ?? payload["sessionCrons"] as? [Any] ?? []).isEmpty)
        return event.valid ? event : nil
    }
}

enum FinishCommandLine {
    /// Hooks only enqueue metadata. The foreground Reprise app owns all actions.
    static func handle(_ args: [String]) -> Bool {
        guard let mode = args.dropFirst().first, ["--completion-hook", "--completion-notify"].contains(mode) else { return false }
        let notify = mode == "--completion-notify"
        guard args.count >= 3 else { return true }
        let provider = args[2]
        let base: URL
        if let index = args.firstIndex(of: "--base"), index + 1 < args.count, args[index + 1].hasPrefix("/") {
            base = URL(fileURLWithPath: args[index + 1])
        } else { base = FinishFiles.defaultDirectory }
        let raw: Data
        if notify {
            guard let last = args.last, last.utf8.count <= 1_048_576 else { return true }
            raw = Data(last.utf8)
            forwardCodexNotification(raw, directory: base)
        } else {
            var data = Data()
            while data.count <= 524288 {
                do {
                    guard let chunk = try FileHandle.standardInput.read(upToCount: min(8192, 524289 - data.count)), !chunk.isEmpty else { break }
                    data.append(chunk)
                } catch { return true }
            }
            guard data.count <= 524288 else { return true }; raw = data
        }
        guard FinishFiles.preferences(in: base)?.enabled == true,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let event = FinishHookPayload.event(provider: provider, payload: payload, notify: notify, environment: ProcessInfo.processInfo.environment) else { return true }
        try? FinishFiles.write(event, in: base)
        return true // Silent success: never block, approve, or alter a coding tool's work.
    }

    private static func forwardCodexNotification(_ data: Data, directory: URL) {
        let file = directory.appendingPathComponent("native-connections/codex-notify.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 65536,
              let backup = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              let original = backup["original"] as? [String], let tool = original.first, !tool.isEmpty,
              !original.contains("--completion-notify") else { return }
        let process = Process()
        if tool.hasPrefix("/") { process.executableURL = URL(fileURLWithPath: tool); process.arguments = Array(original.dropFirst()) + [String(decoding: data, as: UTF8.self)] }
        else { process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = original + [String(decoding: data, as: UTF8.self)] }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run() // Preserve the existing notifier even while Reprise detection is off.
    }
}
