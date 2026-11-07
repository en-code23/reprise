import Foundation

enum SessionOrigin: String, Codable, CaseIterable, Identifiable, Sendable {
    case desktopApp, cli, ide, sdk, multiple, unknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .desktopApp: "Desktop app"
        case .cli: "CLI"
        case .ide: "IDE extension"
        case .sdk: "SDK / automation"
        case .multiple: "Multiple clients"
        case .unknown: "Unknown"
        }
    }
}

struct OriginDetection {
    let origin: SessionOrigin
    let evidence: [String]
}

enum SessionOriginDetector {
    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
    }
    static func evidence(_ key: String, _ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return "\(key): " + String(value.filter { !$0.isNewline && !$0.isASCIIControl }.prefix(120))
    }

    static func codex(originator: String?, source: String?) -> OriginDetection {
        let explicit = originator.map(normalized) ?? ""
        let broad = source.map(normalized) ?? ""
        let origin: SessionOrigin
        // Desktop currently shares the broad 'vscode' source. Prefer the specific client marker.
        switch explicit {
        case "codex desktop", "codex-desktop", "codex-app", "codex desktop app": origin = .desktopApp
        case "codex-tui", "codex-cli-rs", "codex-cli", "codex cli": origin = .cli
        case "vscode", "codex-vscode", "codex-ide", "cursor": origin = .ide
        case "codex-sdk", "sdk": origin = .sdk
        default:
            switch broad {
            case "cli": origin = .cli
            // 'vscode' alone is shared by Desktop; without a specific originator it is ambiguous.
            case "ide": origin = .ide
            case "desktop", "app": origin = .desktopApp
            case "sdk", "exec": origin = .sdk
            default: origin = .unknown
            }
        }
        return OriginDetection(origin: origin, evidence: [evidence("originator", originator), evidence("source", source)].compactMap { $0 })
    }

    static func claude(entrypoints: Set<String>) -> OriginDetection {
        let kinds = Set(entrypoints.compactMap { value -> SessionOrigin? in
            switch normalized(value) {
            case "claude-desktop", "desktop", "claude desktop": return .desktopApp
            case "cli", "claude-cli": return .cli
            case "vscode", "ide", "claude-vscode", "jetbrains": return .ide
            case "sdk-cli", "sdk-py", "sdk-ts", "sdk": return .sdk
            default: return nil
            }
        })
        let origin: SessionOrigin = kinds.count > 1 ? .multiple : kinds.first ?? .unknown
        return OriginDetection(origin: origin, evidence: entrypoints.sorted().compactMap { evidence("entrypoint", $0) })
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}
