import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [ResumeSession] = []
    @Published private(set) var storageError: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncMessage = "Automatic discovery is ready."
    @Published var autoDiscovery: Bool {
        didSet { UserDefaults.standard.set(autoDiscovery, forKey: "autoDiscovery") }
    }

    private let fileURL: URL
    private var canWrite = true
    private var discoveryTask: Task<Void, Never>?
    private var dismissed: Set<String>

    init(fileManager: FileManager = .default, directory overrideDirectory: URL? = nil) {
        autoDiscovery = UserDefaults.standard.object(forKey: "autoDiscovery") as? Bool ?? true
        dismissed = Set(UserDefaults.standard.stringArray(forKey: "dismissedSessions") ?? [])
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let directory = overrideDirectory ?? applicationSupport.appendingPathComponent("Reprise", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("sessions.json")
        load()
    }

    func add(_ session: ResumeSession) {
        var session = session
        session.command = CommandParser.canonicalize(session.command)
        if let index = sessions.firstIndex(where: { $0.identityKey == session.identityKey }) {
            session = ResumeSession(id: sessions[index].id, model: session.model, project: session.project,
                projectDirectory: session.projectDirectory, note: session.note, command: session.command,
                createdAt: session.createdAt, sourceFileName: session.sourceFileName,
                detectedAutomatically: session.detectedAutomatically)
            sessions[index] = session
        } else { sessions.insert(session, at: 0) }
        save()
    }

    func update(_ session: ResumeSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        var updated = session
        updated.command = CommandParser.canonicalize(session.command)
        sessions[index] = updated
        save()
    }

    func startDiscovery() {
        guard discoveryTask == nil else { return }
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.autoDiscovery { await self.sync() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stopDiscovery() { discoveryTask?.cancel(); discoveryTask = nil }

    func restoreHiddenSessions() async {
        dismissed.removeAll()
        UserDefaults.standard.removeObject(forKey: "dismissedSessions")
        await sync()
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        let result = await Task.detached(priority: .utility) { SessionDiscovery.scan() }.value
        mergeDiscovered(result.sessions)
        lastSync = .now
        syncMessage = result.warnings.isEmpty ? "Local sessions are up to date." : result.warnings.joined(separator: " ")
        isSyncing = false
    }

    func mergeDiscovered(_ incoming: [ResumeSession]) {
        var changed = false
        var indices = Dictionary(sessions.enumerated().map { ($0.element.identityKey, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for session in incoming where !dismissed.contains(session.identityKey) {
            if let index = indices[session.identityKey] {
                if sessions[index].discoveryKey != nil && sessions[index].createdAt != session.createdAt {
                    sessions[index].createdAt = session.createdAt
                    changed = true
                }
            } else {
                indices[session.identityKey] = sessions.count
                sessions.append(session)
                changed = true
            }
        }
        if changed { sessions.sort { $0.createdAt > $1.createdAt }; save() }
    }

    func delete(_ session: ResumeSession) {
        dismissed.insert(session.identityKey)
        UserDefaults.standard.set(Array(dismissed), forKey: "dismissedSessions")
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
            canWrite = false
            storageError = "Your saved sessions could not be opened."
        }
    }

    private func save() {
        guard canWrite else { return }
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
