import Foundation

enum FinishAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, notify, sleep, lock, shortcut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Do nothing"
        case .notify: "Notify me"
        case .sleep: "Put Mac to sleep"
        case .lock: "Lock screen"
        case .shortcut: "Run a macOS Shortcut"
        }
    }
}

struct FinishPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var action = FinishAction.none
    var delaySeconds = 60
    var shortcutName = ""
    var providers: Set<String> = ["codex", "claude", "grok"]
    var valid: Bool {
        (15...600).contains(delaySeconds) && providers.isSubset(of: ["codex", "claude", "grok"])
    }
    var ready: Bool {
        valid && action != .none &&
        (action != .shortcut || (!shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && shortcutName.count <= 200 && !shortcutName.hasPrefix("-") && !shortcutName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })))
    }
}

struct FinishTarget: Codable, Equatable, Hashable, Sendable {
    var provider: String
    var sessionId: String
    init(provider: String, sessionId: String) { self.provider = provider; self.sessionId = sessionId.lowercased() }
    var key: String { provider + ":" + sessionId.lowercased() }
    var valid: Bool { ["codex", "claude", "grok"].contains(provider) && Self.validIdentifier(sessionId) }
    static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"#, options: .regularExpression) != nil
    }
}

/// Only lifecycle metadata crosses the bridge. Prompts, output, and commands are discarded.
struct FinishEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case started, active, waiting, completed, idle, candidate, failed, cancelled, closed, childStarted, childFinished
    }
    var id: String
    var provider: String
    var sessionId: String
    var turnId: String?
    var kind: Kind
    var source: String
    var occurredAt: Double
    var childId: String?
    var backgroundWork = false
    var target: FinishTarget { FinishTarget(provider: provider, sessionId: sessionId) }
    var valid: Bool {
        UUID(uuidString: id) != nil && target.valid && ["managed", "hook"].contains(source) && occurredAt.isFinite &&
        (turnId == nil || FinishTarget.validIdentifier(turnId!)) && (childId == nil || FinishTarget.validIdentifier(childId!))
    }
}

struct FinishExecution: Equatable, Sendable {
    var action: FinishAction
    var shortcutName: String
    var target: FinishTarget
}

/// Arming and countdowns deliberately never survive a restart or a Mac sleep.
struct FinishStateMachine {
    struct Activity {
        var turnId: String?
        var busy = false
        var waiting = false
        var failed = false
        var children = Set<String>()
        var candidate = false
        var candidateAt: Double?
        var completedAt: Double?
        var lastEventAt = 0.0
        var managedOpen = false
    }
    struct Arm: Equatable {
        var preferences: FinishPreferences
        var target: FinishTarget?
        var armedAt: Double
    }
    struct Pending: Equatable {
        var target: FinishTarget
        var deadline: Double // Monotonic uptime; wall-clock changes cannot advance sleep.
    }
    private(set) var arm: Arm?
    private(set) var pending: Pending?
    private(set) var activities: [FinishTarget: Activity] = [:]
    private var handled = Set<String>()
    private var order: [String] = []
    private var completedTurns = Set<String>()

    mutating func enable(_ preferences: FinishPreferences, target: FinishTarget?, now: Double) -> Bool {
        guard preferences.enabled, preferences.ready, !preferences.providers.isEmpty, target?.valid != false,
              target == nil || preferences.providers.contains(target!.provider) else { return false }
        arm = Arm(preferences: preferences, target: target, armedAt: now)
        pending = nil
        for key in activities.keys { activities[key]?.completedAt = nil }
        return true
    }
    mutating func cancel() { arm = nil; pending = nil }

    mutating func receive(_ event: FinishEvent, now: Double, uptime: Double) {
        guard event.valid, event.occurredAt <= now + 5, now - event.occurredAt < 300, !handled.contains(event.id) else { return }
        handled.insert(event.id); order.append(event.id)
        if order.count > 4096 { handled.remove(order.removeFirst()) }
        let target = event.target
        let affectsArm = arm?.preferences.providers.contains(event.provider) ?? true
        let previousPending = pending
        let turnKey = event.turnId.map { target.key + ":" + $0 }
        if event.kind == .completed, let turnKey, completedTurns.contains(turnKey) { return }
        var activity = activities[target] ?? Activity()
        if event.source == "hook" && activity.managedOpen && event.kind != .childStarted && event.kind != .childFinished { return }
        if event.source == "managed" { activity.managedOpen = event.kind != .closed }
        // Grok reports cancellations asynchronously. An old turn cannot settle a newer one.
        if ![.started, .childStarted, .childFinished].contains(event.kind), let turn = event.turnId, let current = activity.turnId, turn != current { return }
        if event.occurredAt < activity.lastEventAt { return }
        activity.lastEventAt = event.occurredAt
        switch event.kind {
        case .started:
            activity.turnId = event.turnId; activity.busy = true; activity.waiting = false
            activity.failed = false; activity.candidate = false; activity.candidateAt = nil; activity.completedAt = nil
            pending = nil
        case .active:
            activity.turnId = event.turnId ?? activity.turnId
            activity.busy = true; activity.waiting = false; activity.candidate = false; activity.completedAt = nil
            pending = nil
        case .waiting:
            activity.waiting = true; activity.completedAt = nil; activity.candidate = false; pending = nil
        case .candidate:
            // Stop hooks are gates, not proof of completion. Wait for a verified idle signal.
            activity.candidate = true; activity.candidateAt = event.occurredAt; activity.busy = true; activity.waiting = false
        case .completed:
            activity.busy = event.backgroundWork; activity.waiting = false; activity.failed = false
            activity.candidate = false; activity.completedAt = event.backgroundWork ? nil : event.occurredAt
            if !event.backgroundWork, let turnKey { completedTurns.insert(turnKey) }
        case .idle:
            if activity.candidate && !activity.failed && !activity.waiting && !event.backgroundWork {
                activity.busy = false; activity.completedAt = activity.candidateAt; activity.candidate = false
            }
        case .failed, .cancelled:
            activity.busy = false; activity.waiting = false; activity.failed = true
            activity.candidate = false; activity.completedAt = nil; activity.children.removeAll(); pending = nil
        case .closed:
            activity.busy = false; activity.waiting = false; activity.candidate = false; activity.children.removeAll()
            if activity.completedAt == nil { activity.failed = true; pending = nil }
            activity.turnId = nil
        case .childStarted:
            if let child = event.childId { activity.children.insert(child) }
            pending = nil
        case .childFinished:
            if let child = event.childId { activity.children.remove(child) }
        }
        activities[target] = activity
        if !affectsArm { pending = previousPending; return }
        prepare(uptime: uptime)
    }

    private mutating func prepare(uptime: Double) {
        guard let arm, pending == nil else { return }
        let watched = activities.filter { arm.preferences.providers.contains($0.key.provider) }
        guard !watched.values.contains(where: { $0.busy || $0.waiting || ($0.failed && $0.lastEventAt >= arm.armedAt) || !$0.children.isEmpty }) else { return }
        let finished = watched.filter {
            ($0.value.completedAt ?? -.infinity) > arm.armedAt && (arm.target == nil || arm.target == $0.key)
        }.max { ($0.value.completedAt ?? 0) < ($1.value.completedAt ?? 0) }
        guard let finished else { return }
        pending = Pending(target: finished.key, deadline: uptime + Double(arm.preferences.action == .notify ? 0 : arm.preferences.delaySeconds))
    }

    mutating func takeDue(uptime: Double) -> FinishExecution? {
        guard let arm, let pending, uptime >= pending.deadline else { return nil }
        // A suspended/blocked app must not run an old countdown upon returning.
        guard uptime - pending.deadline <= 5 else { cancel(); return nil }
        let result = FinishExecution(action: arm.preferences.action, shortcutName: arm.preferences.shortcutName, target: pending.target)
        cancel() // Consume the one-shot before performing anything, including failures.
        return result
    }
}
