import SwiftUI

extension Color {
    static let repriseCanvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.10, alpha: 1)
            : NSColor(calibratedRed: 0.965, green: 0.957, blue: 0.932, alpha: 1)
    })
    static let repriseSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.145, alpha: 1)
            : NSColor(calibratedRed: 0.992, green: 0.988, blue: 0.975, alpha: 1)
    })
    static let repriseGreen = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.46, green: 0.76, blue: 0.55, alpha: 1)
            : NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.32, alpha: 1)
    })
    static let repriseTerminal = Color(red: 0.12, green: 0.135, blue: 0.12)
    static let repriseBone = Color(red: 0.94, green: 0.93, blue: 0.88)
}

extension AssistantModel {
    var tint: Color {
        switch self {
        case .codex: .primary
        case .claude: Color(red: 0.71, green: 0.36, blue: 0.24)
        case .grok: Color(red: 0.27, green: 0.36, blue: 0.46)
        case .other: .secondary
        }
    }
}
