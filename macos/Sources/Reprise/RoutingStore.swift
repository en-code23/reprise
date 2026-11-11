import Foundation

@MainActor
final class RoutingStore: ObservableObject {
    static let shared = RoutingStore()
    @Published var preferences = RoutingPreferences() { didSet { save() } }
    @Published private(set) var states: [AssistantModel: ProviderRoutingState] = [:]
    @Published private(set) var refreshing: Set<AssistantModel> = []
    @Published var claudeConnected = false { didSet { save() } }
    @Published var fableWindowID = "" { didSet { save() } }
    @Published private(set) var storageError: String?
    private let file: URL
    var configurationURL: URL { file }
    private var writable = true
    private var loading = true
    private var assessments: [String: (Date, ProjectAssessment)] = [:]
    private struct Saved: Codable {
        var preferences: RoutingPreferences
        var states: [ProviderRoutingState]
        var claudeConnected: Bool
        var fableWindowID: String
    }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Reprise")
        file = base.appendingPathComponent("model-routing.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2 * 1024 * 1024 else { throw RoutingProbeError.invalidResponse }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
                let saved = try decoder.decode(Saved.self, from: Data(contentsOf: file))
                preferences = saved.preferences; claudeConnected = saved.claudeConnected; fableWindowID = saved.fableWindowID
                states = Dictionary(saved.states.map { ($0.provider, $0) }, uniquingKeysWith: { _, last in last })
            } catch { writable = false; storageError = "Model-selection settings could not be read. The original file is preserved." }
        }
        loading = false
    }

    private func save() {
        guard !loading, writable else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Saved(preferences: preferences, states: Array(states.values), claudeConnected: claudeConnected, fableWindowID: fableWindowID)).write(to: file, options: .atomic)
        } catch { storageError = "Model-selection preferences could not be saved." }
    }

    func refresh(_ provider: AssistantModel) async {
        guard preferences.enabled, provider != .other, !refreshing.contains(provider) else { return }
        guard provider != .claude || claudeConnected else {
            states[provider] = ProviderRoutingState(provider: provider, status: "Connect Claude usage in Model selection settings."); return
        }
        refreshing.insert(provider); defer { refreshing.remove(provider) }
        do {
            let state: ProviderRoutingState
            if provider == .claude { state = try await RoutingProviders.claude(fableKey: fableWindowID.isEmpty ? nil : fableWindowID) }
            else { state = try await Task.detached { try provider == .codex ? RoutingProviders.codex() : RoutingProviders.grok() }.value }
            var adjusted = state
            for index in adjusted.models.indices {
                if let role = preferences.modelRoles[provider.rawValue + ":" + adjusted.models[index].id] { adjusted.models[index].role = role }
            }
            states[provider] = adjusted
        } catch {
            var state = states[provider] ?? ProviderRoutingState(provider: provider)
            state.observedAt = .now
            for index in state.windows.indices { state.windows[index].observedAt = .distantPast }
            state.status = error as? RoutingProbeError == .missingTool ? "Install the \(provider.displayName) CLI to connect usage." : "Usage could not be refreshed. Check the CLI login and try again; cached values may be stale."
            states[provider] = state
        }
        save()
    }

    func assessment(for directory: String) async -> ProjectAssessment {
        if let (date, assessment) = assessments[directory], Date().timeIntervalSince(date) < 60 { return assessment }
        let result = await Task.detached { ProjectAssessor.assess(directory: URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)) }.value
        assessments[directory] = (Date(), result); return result
    }

    func decision(for session: ResumeSession, refresh: Bool = false) async -> RoutingDecision? {
        guard preferences.enabled, let directory = session.projectDirectory, session.model != .other,
              session.command.split(separator: " ").first.map(String.init) == session.model.rawValue,
              !preferences.disabledProjects.contains(ProjectLibrary.normalizedDirectory(directory) ?? directory) else { return nil }
        if refresh || (states[session.model]?.observedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true) ||
            states[session.model]?.windows.contains(where: { $0.resetsAt <= Date() }) == true { await self.refresh(session.model) }
        let assessment = await assessment(for: directory)
        let hint = preferences.workHints[ProjectLibrary.normalizedDirectory(directory) ?? directory] ?? .automatic
        return ModelRouter.decide(project: assessment, state: states[session.model] ?? ProviderRoutingState(provider: session.model), preferences: preferences, hint: hint)
    }

    func setHint(_ hint: WorkKind, directory: String) {
        preferences.workHints[ProjectLibrary.normalizedDirectory(directory) ?? directory] = hint
        assessments[directory] = nil
    }

    func setRole(_ role: ModelRole, model: RoutingModel, provider: AssistantModel) {
        preferences.modelRoles[provider.rawValue + ":" + model.id] = role
        if let index = states[provider]?.models.firstIndex(where: { $0.id == model.id }) { states[provider]?.models[index].role = role }
        save()
    }

    func usesManagedSession(_ session: ResumeSession) -> Bool {
        guard preferences.enabled, preferences.continuous, session.model != .other, let directory = session.projectDirectory,
              session.hasLocalHistory != false, UUID(uuidString: session.sessionIdentifier) != nil,
              session.command.split(separator: " ").first.map(String.init) == session.model.rawValue else { return false }
        return !preferences.disabledProjects.contains(ProjectLibrary.normalizedDirectory(directory) ?? directory)
    }

    func readRunnerCaches() {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        for provider in [AssistantModel.codex, .claude, .grok] {
            let path = file.deletingLastPathComponent().appendingPathComponent("routing-usage/\(provider.rawValue).json")
            guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2 * 1024 * 1024,
                  let data = try? Data(contentsOf: path), let state = try? decoder.decode(ProviderRoutingState.self, from: data),
                  state.provider == provider, (state.observedAt ?? .distantPast) > (states[provider]?.observedAt ?? .distantPast) else { continue }
            states[provider] = state
        }
    }
}
