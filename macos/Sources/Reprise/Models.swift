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

    init(
        id: UUID = UUID(),
        model: AssistantModel,
        project: String,
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
        self.projectDirectory = projectDirectory
        self.note = note
        self.command = command
        self.createdAt = createdAt
        self.sourceFileName = sourceFileName
        self.detectedAutomatically = detectedAutomatically
    }

    var identityKey: String { discoveryKey ?? "\(model.rawValue):\(CommandParser.canonicalize(command))" }
    var origin: SessionOrigin { originOverride ?? detectedOrigin ?? .unknown }
}

struct ParsedResumeCommand: Sendable {
    var model: AssistantModel
    var command: String
    var projectDirectory: String?
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
        let projectDirectory = detectProjectDirectory(in: normalized)
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
                command: resumeCommand(model: model, identifier: identifier),
                projectDirectory: projectDirectory,
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
        let pattern = #"(?i)^(codex|claude|grok)\s+(?:--resume|resume)\s+[\"']?([A-Za-z0-9_./:@-]+)[\"']?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: trimmed,
                  range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              let toolRange = Range(match.range(at: 1), in: trimmed),
              let idRange = Range(match.range(at: 2), in: trimmed) else {
            return trimmed
        }

        let model = AssistantModel(rawValue: trimmed[toolRange].lowercased()) ?? .other
        return resumeCommand(model: model, identifier: String(trimmed[idRange]))
    }

    static func resumeCommand(model: AssistantModel, identifier: String) -> String {
        "\(model.commandName) \(model == .codex || model == .other ? "resume" : "--resume") \(identifier)"
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
            let precedesResumeCommand = ["codex", "claude", "grok"].contains {
                followingLine.contains($0) && followingLine.contains("resume")
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
