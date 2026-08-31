import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [ResumeSession] = []
    @Published private(set) var storageError: String?

    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let directory = applicationSupport.appendingPathComponent("Reprise", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("sessions.json")
        load()
    }

    func add(_ session: ResumeSession) {
        sessions.insert(session, at: 0)
        save()
    }

    func delete(_ session: ResumeSession) {
        sessions.removeAll { $0.id == session.id }
        save()
    }

    func count(for model: AssistantModel) -> Int {
        sessions.count { $0.model == model }
    }

    func flush() {
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var migrated = false
            sessions = try decoder.decode([ResumeSession].self, from: data)
                .map { session in
                    var updated = session
                    let canonicalCommand = CommandParser.canonicalize(session.command)
                    if canonicalCommand != session.command {
                        updated.command = canonicalCommand
                        migrated = true
                    }
                    if updated.projectDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                        updated.projectDirectory = nil
                        migrated = true
                    }
                    return updated
                }
                .sorted { $0.createdAt > $1.createdAt }
            if migrated { save() }
        } catch {
            storageError = "Your saved sessions could not be opened."
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            try data.write(to: fileURL, options: .atomic)
            storageError = nil
        } catch {
            storageError = "Reprise could not save this change."
        }
    }
}
