import Foundation

enum LibraryArea: String, CaseIterable, Identifiable {
    case projects, unassigned, internalSessions
    var id: String { rawValue }
    var title: String {
        switch self { case .projects: "Projects"; case .unassigned: "Unassigned"; case .internalSessions: "Internal workspaces" }
    }
    var symbol: String {
        switch self { case .projects: "square.grid.2x2"; case .unassigned: "tray"; case .internalSessions: "gearshape.2" }
    }
}

struct ProjectGroup: Identifiable {
    let id: String
    let directory: String?
    let area: LibraryArea
    let sessions: [ResumeSession]
    var latest: ResumeSession { sessions[0] }
    var title: String {
        guard let directory else { return "Unassigned session" }
        let name = latest.project
        if name.range(of: #"(?i)^(screenshot|bildschirmfoto|screen shot)"#, options: .regularExpression) != nil || name.isEmpty {
            return URL(fileURLWithPath: directory).lastPathComponent
        }
        return name
    }
    var assistants: [AssistantModel] { AssistantModel.allCases.filter { model in sessions.contains { $0.model == model } } }
    var displayDirectory: String {
        guard let directory else { return "Project folder needed" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return directory.hasPrefix(home + "/") ? "~" + directory.dropFirst(home.count) : directory
    }
}

enum ProjectLibrary {
    static func normalizedDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return (expanded as NSString).standardizingPath
    }

    static func area(for directory: String?) -> LibraryArea {
        guard let directory = normalizedDirectory(directory) else { return .unassigned }
        let components = URL(fileURLWithPath: directory).pathComponents
        return components.contains(where: { [".codex", ".claude", ".chatgpt"].contains($0) }) ? .internalSessions : .projects
    }

    static func groups(_ sessions: [ResumeSession], model: AssistantModel? = nil, query: String = "", origin: SessionOrigin? = nil) -> [ProjectGroup] {
        let candidates = sessions.filter { (model == nil || $0.model == model) && (origin == nil || $0.origin == origin) }
        let grouped = Dictionary(grouping: candidates) { session in
            normalizedDirectory(session.projectDirectory).map { "directory:" + $0 } ?? "unassigned:" + session.id.uuidString
        }
        return grouped.map { key, values in
            let ordered = values.sorted { $0.createdAt > $1.createdAt }
            let directory = normalizedDirectory(ordered[0].projectDirectory)
            return ProjectGroup(id: key, directory: directory, area: area(for: directory), sessions: ordered)
        }.filter { group in
            query.isEmpty || ([group.title, group.directory ?? ""] + group.sessions.flatMap { [$0.note, $0.command, $0.project, $0.origin.title] })
                .joined(separator: " ").localizedCaseInsensitiveContains(query)
        }.sorted { $0.latest.createdAt > $1.latest.createdAt }
    }
}
