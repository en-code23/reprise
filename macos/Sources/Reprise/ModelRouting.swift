import Foundation

enum WorkKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, smallTask, interface, backend, foundation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Detect from project"
        case .smallTask: "Small change"
        case .interface: "UI / frontend"
        case .backend: "Backend / debugging"
        case .foundation: "Backend foundations"
        }
    }
}

enum ModelRole: Int, Codable, CaseIterable, Sendable { case economy, balanced, strong, frontier }

struct RoutingModel: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var role: ModelRole
    var efforts: [String]
    var quotaIDs: [String] = []
    var included = true
    var requiresSpecialAllowance = false

    var valid: Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,119}$"#, options: .regularExpression) != nil &&
        !efforts.isEmpty && efforts.allSatisfy { ["low", "medium", "high", "xhigh", "max"].contains($0) }
    }
}

struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var usedPercent: Double
    var resetsAt: Date
    var durationMinutes: Double?
    var modelIDs: [String] = []
    var specialAllowance = false
    var observedAt: Date

    func fresh(at now: Date) -> Bool {
        usedPercent.isFinite && (0...100).contains(usedPercent) &&
        observedAt <= now.addingTimeInterval(60) && now.timeIntervalSince(observedAt) <= 300 && resetsAt > now
    }
    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

struct ProviderRoutingState: Codable, Equatable, Sendable {
    var provider: AssistantModel
    var models: [RoutingModel] = []
    var windows: [QuotaWindow] = []
    var observedAt: Date?
    var status = "Usage has not been connected."
    var subscription = false
    var blocked = false
}

struct ProjectAssessment: Codable, Equatable, Sendable {
    var sourceFiles: Int
    var backendFiles: Int
    var interfaceFiles: Int
    var testFiles: Int
    var manifests: Int
    var earlyProject: Bool
    var recentBackendFiles: Int = 0
    var recentInterfaceFiles: Int = 0
    var truncated = false

    var large: Bool { sourceFiles >= 180 || manifests >= 5 }
    func workKind(hint: WorkKind) -> WorkKind {
        if hint != .automatic { return hint }
        if earlyProject && backendFiles > 0 && testFiles < max(4, backendFiles / 10) &&
            (interfaceFiles == 0 || recentBackendFiles > recentInterfaceFiles) { return .foundation }
        if recentInterfaceFiles > recentBackendFiles && recentInterfaceFiles > 0 { return .interface }
        if recentBackendFiles > recentInterfaceFiles && recentBackendFiles > 0 { return .backend }
        if interfaceFiles > backendFiles && interfaceFiles > 0 { return .interface }
        return backendFiles > 0 ? .backend : .smallTask
    }
}

struct RoutingPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var reservePercent = 20.0
    var useExpiringHeadroom = true
    var allowFoundationMax = false
    var useFableAllowance = false
    var workHints: [String: WorkKind] = [:]
    var modelRoles: [String: ModelRole] = [:]
    var disabledProjects: Set<String> = []
    var continuous = true

    init() {}
    private enum CodingKeys: String, CodingKey { case enabled, reservePercent, useExpiringHeadroom, allowFoundationMax, useFableAllowance, workHints, modelRoles, disabledProjects, continuous }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        reservePercent = try c.decodeIfPresent(Double.self, forKey: .reservePercent) ?? 20
        useExpiringHeadroom = try c.decodeIfPresent(Bool.self, forKey: .useExpiringHeadroom) ?? true
        allowFoundationMax = try c.decodeIfPresent(Bool.self, forKey: .allowFoundationMax) ?? false
        useFableAllowance = try c.decodeIfPresent(Bool.self, forKey: .useFableAllowance) ?? false
        workHints = try c.decodeIfPresent([String: WorkKind].self, forKey: .workHints) ?? [:]
        modelRoles = try c.decodeIfPresent([String: ModelRole].self, forKey: .modelRoles) ?? [:]
        disabledProjects = try c.decodeIfPresent(Set<String>.self, forKey: .disabledProjects) ?? []
        continuous = try c.decodeIfPresent(Bool.self, forKey: .continuous) ?? true
    }
}

struct RoutingDecision: Codable, Equatable, Sendable {
    var model: RoutingModel?
    var effort: String?
    var kind: WorkKind
    var reasons: [String]
    var constrained = false
    var blocked = false
    var boosted = false
    var label: String { model.map { "\($0.name) · \(effort ?? "default")" } ?? (blocked ? "Wait for usage to reset" : "Keep the tool’s model") }

    func arguments(provider: AssistantModel) -> [String] {
        guard let model, model.valid, let effort, model.efforts.contains(effort), !blocked else { return [] }
        switch provider {
        case .codex: return ["--model", model.id, "--config", "model_reasoning_effort=\"\(effort)\""]
        case .claude: return ["--model", model.id, "--effort", effort]
        case .grok: return ["--model", model.id, "--reasoning-effort", effort]
        case .other: return []
        }
    }
}

enum ModelRouter {
    static func decide(project: ProjectAssessment, state: ProviderRoutingState,
                       preferences: RoutingPreferences, hint: WorkKind = .automatic, now: Date = .now) -> RoutingDecision {
        let kind = project.workKind(hint: hint)
        var decision = RoutingDecision(kind: kind, reasons: [])
        guard preferences.enabled else { decision.reasons = ["Automatic model selection is off."]; return decision }
        guard !state.blocked else { decision.blocked = true; decision.reasons = ["The provider reports that included usage is unavailable."]; return decision }
        let candidates = state.models.filter { $0.valid && $0.included }
        guard !candidates.isEmpty else { decision.blocked = true; decision.reasons = ["No verified model is available. Refresh its catalog or explicitly turn off automatic selection."]; return decision }
        let shared = state.windows.filter { $0.modelIDs.isEmpty && !$0.specialAllowance }
        let sharedFresh = !shared.isEmpty && shared.allSatisfy { $0.fresh(at: now) }
        if shared.contains(where: { $0.fresh(at: now) && $0.usedPercent >= 100 }) {
            decision.blocked = true; decision.reasons = ["A shared usage limit is exhausted. Refresh after its reset."]; return decision
        }
        let reserve = min(50, max(5, preferences.reservePercent.isFinite ? preferences.reservePercent : 20))
        let headroom = sharedFresh ? shared.map(\.remainingPercent).min() ?? 0 : 0
        let critical = sharedFresh && headroom <= reserve
        let paceTight = sharedFresh && shared.contains { window in
            guard let minutes = window.durationMinutes, minutes > 0 else { return false }
            let timeLeft = min(1, window.resetsAt.timeIntervalSince(now) / (minutes * 60))
            return timeLeft > 0.2 && (window.remainingPercent - reserve) / 100 < timeLeft * (1 - reserve / 100) * 0.6
        }
        let constrained = !sharedFresh || headroom < reserve + 15 || paceTight
        decision.constrained = constrained
        var desired: ModelRole
        var effort: String
        switch kind {
        case .foundation: desired = .frontier; effort = "high"
        case .backend: desired = project.large ? .strong : .balanced; effort = project.large ? "high" : "medium"
        case .interface: desired = .strong; effort = "medium"
        case .smallTask, .automatic: desired = .balanced; effort = "low"
        }
        decision.reasons.append("\(kind.title) · \(project.sourceFiles) source files\(project.earlyProject ? " · early project" : "")")
        if !sharedFresh {
            desired = .balanced; effort = "low"
            decision.reasons.append("Usage is missing, stale, or awaiting reset confirmation. Use a conservative choice.")
        } else if critical {
            desired = .economy; effort = "low"
            decision.reasons.append("Conserve usage below the \(Int(reserve))% remaining threshold.")
        } else if constrained {
            desired = min(desired, kind == .foundation ? .strong : .balanced); effort = "medium"
            decision.reasons.append(paceTight ? "Conserve usage so it lasts until the reset." : "Shared usage is running low. Prefer a less expensive model.")
        }
        func windows(for model: RoutingModel) -> [QuotaWindow] {
            shared + state.windows.filter { !$0.modelIDs.isEmpty && ($0.modelIDs.contains(model.id) || model.quotaIDs.contains($0.id)) }
        }
        func eligible(_ model: RoutingModel) -> Bool {
            let applicable = windows(for: model)
            if applicable.contains(where: { $0.fresh(at: now) && $0.usedPercent >= 100 }) { return false }
            if model.requiresSpecialAllowance {
                guard preferences.useFableAllowance, state.subscription, sharedFresh, !constrained else { return false }
                guard shared.contains(where: { ($0.durationMinutes ?? 0) >= 10080 || $0.id == "seven_day" }) else { return false }
                let special = applicable.filter(\.specialAllowance)
                guard !special.isEmpty, special.allSatisfy({ $0.fresh(at: now) && $0.remainingPercent > reserve + 10 }) else { return false }
            }
            // A stale model-specific window must not silently stop constraining its model.
            if applicable.contains(where: { !$0.fresh(at: now) && !$0.modelIDs.isEmpty }) { return false }
            return true
        }
        let eligibleModels = candidates.filter(eligible)
        guard !eligibleModels.isEmpty else { decision.blocked = true; decision.reasons.append("No included model has confirmed available usage."); return decision }
        let relevant = sharedFresh && !constrained && preferences.useExpiringHeadroom && shared.allSatisfy { $0.remainingPercent >= reserve + 20 }
        let expiring = relevant && shared.contains { window in
            guard let minutes = window.durationMinutes, minutes > 0 else { return false }
            return window.remainingPercent >= 60 && window.resetsAt.timeIntervalSince(now) <= min(3600, minutes * 60 * 0.1)
        }
        if expiring && kind != .smallTask {
            desired = ModelRole(rawValue: min(ModelRole.frontier.rawValue, desired.rawValue + 1)) ?? desired
            effort = "high"; decision.boosted = true
            decision.reasons.append("A reset is near with substantial unused allowance, and the other shared windows have room.")
        }
        let atOrBelow = eligibleModels.filter { $0.role.rawValue <= desired.rawValue }
        let selected = (atOrBelow.isEmpty ? eligibleModels : atOrBelow).sorted {
            if $0.role != $1.role { return atOrBelow.isEmpty ? $0.role.rawValue < $1.role.rawValue : $0.role.rawValue > $1.role.rawValue }
            return $0.id < $1.id
        }.first!
        if selected.requiresSpecialAllowance { decision.reasons.append("Both the shared quota and the separate Fable allowance have confirmed headroom.") }
        else if kind == .foundation && state.provider == .claude && !preferences.useFableAllowance {
            decision.reasons.append("Fable is excluded until you enable use of its included allowance.")
        }
        let order = ["low", "medium", "high", "xhigh", "max"]
        if kind == .foundation && project.earlyProject && project.large && !constrained && preferences.allowFoundationMax && !decision.boosted && headroom >= 75 {
            effort = "max"
            decision.reasons.append("Maximum effort is allowed only for this large, early backend foundation task.")
        }
        let target = order.firstIndex(of: effort) ?? 1
        let allowed = selected.efforts.filter { (order.firstIndex(of: $0) ?? 99) <= target }
        // Never promote an effort just because the preferred level is unsupported.
        guard let supported = allowed.max(by: { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }) else {
            decision.blocked = true; decision.reasons.append("No suitable advertised effort is available. Refresh the model catalog."); return decision
        }
        decision.model = selected; decision.effort = supported
        return decision
    }
}

private func min(_ lhs: ModelRole, _ rhs: ModelRole) -> ModelRole { lhs.rawValue <= rhs.rawValue ? lhs : rhs }
