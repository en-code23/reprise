import Foundation

enum AssistantModel: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case codex
    case claude
    case grok
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .grok: "Grok"
        case .other: "Other"
        }
    }

    var commandName: String {
        switch self {
        case .other: "tool"
        default: rawValue
        }
    }

    var symbol: String {
        switch self {
        case .codex: "terminal.fill"
        case .claude: "sparkle"
        case .grok: "bolt.horizontal.fill"
        case .other: "chevron.right"
        }
    }
}

struct ResumeSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var model: AssistantModel
    var project: String
    var note: String
    var command: String
    var createdAt: Date
    var sourceFileName: String?
    var detectedAutomatically: Bool

    init(
        id: UUID = UUID(),
        model: AssistantModel,
        project: String,
        note: String,
        command: String,
        createdAt: Date = .now,
        sourceFileName: String? = nil,
        detectedAutomatically: Bool
    ) {
        self.id = id
        self.model = model
        self.project = project
        self.note = note
        self.command = command
        self.createdAt = createdAt
        self.sourceFileName = sourceFileName
        self.detectedAutomatically = detectedAutomatically
    }
}

struct ParsedResumeCommand: Sendable {
    var model: AssistantModel
    var command: String
    var wasDetected: Bool
}

enum CommandParser {
    static func parse(_ text: String) -> ParsedResumeCommand {
        let normalized = text
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
        let lower = normalized.lowercased()
        let detectedModel: AssistantModel

        if lower.contains("claude") || lower.contains("anthropic") {
            detectedModel = .claude
        } else if lower.contains("grok") || lower.contains("x.ai") {
            detectedModel = .grok
        } else if lower.contains("codex") || lower.contains("openai") {
            detectedModel = .codex
        } else {
            detectedModel = .other
        }

        let pattern = #"(?i)(codex|claude|grok)\s+(?:--resume|resume)\s+[\"']?([A-Za-z0-9_./:@-]{6,})[\"']?"#
        if let expression = try? NSRegularExpression(pattern: pattern),
           let match = expression.firstMatch(
               in: normalized,
               range: NSRange(normalized.startIndex..., in: normalized)
           ),
           let toolRange = Range(match.range(at: 1), in: normalized),
           let idRange = Range(match.range(at: 2), in: normalized) {
            let tool = String(normalized[toolRange]).lowercased()
            let identifier = String(normalized[idRange])
            let model = AssistantModel(rawValue: tool) ?? detectedModel
            return ParsedResumeCommand(
                model: model,
                command: "\(tool) --resume \"\(identifier)\"",
                wasDetected: true
            )
        }

        let fallbackPattern = #"(?i)(?:resume|session\s*id)\s*[:=#-]?\s*[\"']?([A-Za-z0-9_-]{8,})[\"']?"#
        if detectedModel != .other,
           let expression = try? NSRegularExpression(pattern: fallbackPattern),
           let match = expression.firstMatch(
               in: normalized,
               range: NSRange(normalized.startIndex..., in: normalized)
           ),
           let idRange = Range(match.range(at: 1), in: normalized) {
            let identifier = String(normalized[idRange])
            return ParsedResumeCommand(
                model: detectedModel,
                command: "\(detectedModel.commandName) --resume \"\(identifier)\"",
                wasDetected: true
            )
        }

        return ParsedResumeCommand(model: detectedModel, command: "", wasDetected: false)
    }
}
