import Foundation

enum AssistantModel: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case codex
    case claude
    case grok
    case gemini, moonshot, deepseek, glm, antigravity, opencode
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .grok: "Grok"
        case .gemini: "Gemini"
        case .moonshot: "Moonshot / Kimi"
        case .deepseek: "DeepSeek"
        case .glm: "GLM"
        case .antigravity: "Antigravity"
        case .opencode: "OpenCode"
        case .other: "Other"
        }
    }

    var commandName: String {
        switch self {
        case .moonshot: "kimi"
        case .antigravity: "agy"
        case .deepseek, .glm: "opencode"
        case .other: "tool"
        default: rawValue
        }
    }

    var symbol: String {
        switch self {
        case .codex: "terminal.fill"
        case .claude: "sparkle"
        case .grok: "bolt.horizontal.fill"
        case .gemini: "sparkles"
        case .moonshot: "moon.fill"
        case .deepseek: "water.waves"
        case .glm: "cube.fill"
        case .antigravity: "arrow.up.circle.fill"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        case .other: "chevron.right"
        }
    }

    var supportsManagedSessions: Bool { [.codex, .claude, .grok].contains(self) }

    static func recordedProvider(_ value: String?) -> AssistantModel? {
        guard let value = value?.lowercased() else { return nil }
        if value.contains("deepseek") { return .deepseek }
        if value.range(of: #"(?:^|[/_.:\s-])glm(?:$|[-_0-9.\s])"#, options: .regularExpression) != nil || ["zai", "z.ai", "zhipu", "zhipuai", "zai-coding-plan"].contains(value) { return .glm }
        if value.contains("moonshot") || value.contains("kimi") { return .moonshot }
        if value.contains("gemini") { return .gemini }
        return nil
    }
}

struct ResumeSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var model: AssistantModel
    var project: String
    var projectDirectory: String?
    var note: String
    var command: String
    var createdAt: Date
    var sourceFileName: String?
    var detectedAutomatically: Bool
    var discoveryKey: String?
    var detectedOrigin: SessionOrigin?
    var originOverride: SessionOrigin?
    var sourceEvidence: [String]?
    var name: String?
    var detectedName: String?
    var isSubagent: Bool?
    var hasLocalHistory: Bool?
    var detectedAssistant: AssistantModel?
    var assistantOverride: AssistantModel?

    init(
        id: UUID = UUID(),
        model: AssistantModel,
        project: String,
        name: String? = nil,
        projectDirectory: String? = nil,
        note: String,
        command: String,
        createdAt: Date = .now,
        sourceFileName: String? = nil,
        detectedAutomatically: Bool
    ) {
        self.id = id
        self.model = model
        self.project = project
        self.name = SessionName.clean(name)
        self.projectDirectory = projectDirectory
        self.note = note
        self.command = command
        self.createdAt = createdAt
        self.sourceFileName = sourceFileName
        self.detectedAutomatically = detectedAutomatically
        self.detectedAssistant = detectedAutomatically ? model : nil
    }

    var identityKey: String {
        discoveryKey ?? "\(CommandParser.client(command)?.rawValue ?? model.rawValue):\(CommandParser.canonicalize(command))"
    }
    var origin: SessionOrigin { originOverride ?? detectedOrigin ?? .unknown }
    var sourceLabel: String {
        guard let client = CommandParser.client(command), client != model else { return origin.title }
        return "\(client == .claude ? "Claude Code" : client.displayName) · \(origin.title)"
    }
    var sessionIdentifier: String { command.split(separator: " ").last.map(String.init) ?? id.uuidString }
    var displayName: String { SessionName.clean(name) ?? SessionName.clean(detectedName) ?? "Session · \(sessionIdentifier.suffix(8))" }
}

enum SessionName {
    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let words = value.components(separatedBy: .whitespacesAndNewlines.union(.controlCharacters).subtracting(CharacterSet(charactersIn: "\u{200D}")))
            .filter { !$0.isEmpty }.joined(separator: " ")
        return words.isEmpty ? nil : String(words.prefix(200))
    }
}

struct ParsedResumeCommand: Sendable {
    var model: AssistantModel
    var command: String
    var projectDirectory: String?
    var wasDetected: Bool
}

enum CommandParser {
    static let tools = "codex|claude|grok|gemini|kimi|agy|opencode"
    static func client(_ command: String) -> AssistantModel? {
        switch command.split(whereSeparator: \.isWhitespace).first?.lowercased() {
        case "kimi": .moonshot
        case "agy": .antigravity
        case let tool?: AssistantModel(rawValue: tool)
        default: nil
        }
    }

    static func parse(_ text: String) -> ParsedResumeCommand {
        let normalized = text
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
        let lower = normalized.lowercased()
        let projectDirectory = detectProjectDirectory(in: normalized)
        let detectedModel: AssistantModel

        if let provider = AssistantModel.recordedProvider(lower) {
            detectedModel = provider
        } else if lower.contains("antigravity") || lower.contains("agy ") {
            detectedModel = .antigravity
        } else if lower.contains("opencode") {
            detectedModel = .opencode
        } else if lower.contains("claude") || lower.contains("anthropic") {
            detectedModel = .claude
        } else if lower.contains("grok") || lower.contains("x.ai") {
            detectedModel = .grok
        } else if lower.contains("codex") || lower.contains("openai") {
            detectedModel = .codex
        } else {
            detectedModel = .other
        }

        let pattern = "(?i)\\b(\(tools))\\s+(?:--resume|resume|--session|-s|-r|--conversation)\\s+[\"']?([A-Za-z0-9_-]{6,})[\"']?"
        if let expression = try? NSRegularExpression(pattern: pattern),
           let match = expression.firstMatch(
               in: normalized,
               range: NSRange(normalized.startIndex..., in: normalized)
           ),
           let toolRange = Range(match.range(at: 1), in: normalized),
           let idRange = Range(match.range(at: 2), in: normalized) {
            let tool = String(normalized[toolRange]).lowercased()
            let identifier = String(normalized[idRange])
            let client = client(tool) ?? .other
            let model = [.opencode, .claude].contains(client) && AssistantModel.recordedProvider(lower) != nil ? detectedModel : client
            return ParsedResumeCommand(
                model: model,
                command: resumeCommand(model: client, identifier: identifier),
                projectDirectory: projectDirectory,
                wasDetected: true
            )
        }

        let fallbackPattern = #"(?i)(?:resume|session\s*id)\s*[:=#-]?\s*[\"']?([A-Za-z0-9_-]{8,})[\"']?"#
        if ![.other, .deepseek, .glm, .opencode].contains(detectedModel),
           let expression = try? NSRegularExpression(pattern: fallbackPattern),
           let match = expression.firstMatch(
               in: normalized,
               range: NSRange(normalized.startIndex..., in: normalized)
           ),
           let idRange = Range(match.range(at: 1), in: normalized) {
            let identifier = String(normalized[idRange])
            return ParsedResumeCommand(
                model: detectedModel,
                command: resumeCommand(model: detectedModel, identifier: identifier),
                projectDirectory: projectDirectory,
                wasDetected: true
            )
        }

        return ParsedResumeCommand(
            model: detectedModel,
            command: "",
            projectDirectory: projectDirectory,
            wasDetected: false
        )
    }

    static func canonicalize(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "(?i)^(\(tools))\\s+(?:--resume|resume|--session|-s|-r|--conversation)\\s+[\"']?([A-Za-z0-9_-]+)[\"']?$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: trimmed,
                  range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              let toolRange = Range(match.range(at: 1), in: trimmed),
              let idRange = Range(match.range(at: 2), in: trimmed) else {
            return trimmed
        }

        let model = client(String(trimmed[toolRange])) ?? .other
        return resumeCommand(model: model, identifier: String(trimmed[idRange]))
    }

    static func resumeCommand(model: AssistantModel, identifier: String) -> String {
        let flag: String
        switch model {
        case .codex, .other: flag = "resume"
        case .moonshot, .opencode, .deepseek, .glm: flag = "--session"
        case .antigravity: flag = "--conversation"
        default: flag = "--resume"
        }
        return "\(model.commandName) \(flag) \(identifier)"
    }

    static func detectProjectDirectory(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = trimmed
                .replacingOccurrences(of: #"^[>$#%]\s*"#, with: "", options: .regularExpression)
                .lowercased()
            guard command == "pwd", lines.indices.contains(index + 1) else { continue }
            let candidate = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasPrefix("/") || candidate.hasPrefix("~/") {
                return cleanDirectory(candidate)
            }
        }

        for (index, line) in lines.enumerated() where lines.indices.contains(index + 1) {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let followingLine = lines[index + 1].lowercased()
            let isStandalonePath = (candidate.hasPrefix("/") || candidate.hasPrefix("~/"))
                && !candidate.contains(where: { $0.isWhitespace })
            let precedesResumeCommand = tools.split(separator: "|").contains {
                followingLine.contains($0) && ["resume", "--session", "--conversation", "-s ", "-r "].contains(where: followingLine.contains)
            }
            if isStandalonePath && precedesResumeCommand {
                return cleanDirectory(candidate)
            }
        }

        let promptPatterns = [
            #"(?m)((?:~|/)[^\s$%#>]+)\s*[$%#>]"#,
            #"(?m)^\s*➜\s+([^\s]+)"#
        ]

        for pattern in promptPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                      in: text,
                      range: NSRange(text.startIndex..., in: text)
                  ),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let candidate = cleanDirectory(String(text[range]))
            if !candidate.isEmpty { return candidate }
        }

        return nil
    }

    private static func cleanDirectory(_ value: String) -> String {
        value.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "\"'`"))
        )
    }
}
