import AppKit
import SwiftUI
import UserNotifications
import IOKit.pwr_mgt
import ApplicationServices

@MainActor
final class FinishController: ObservableObject {
    static let shared = FinishController()
    @Published var preferences = FinishPreferences() { didSet { save(); if preferences != oldValue { cancel() }; if !preferences.enabled { machine = FinishStateMachine() }; updateMonitoring() } }
    @Published private(set) var machine = FinishStateMachine()
    @Published private(set) var status = "No action armed."
    @Published private(set) var secondsRemaining = 0
    @Published private(set) var error: String?
    @Published private(set) var executing = false
    @Published private(set) var connectionStatus: [String: String] = [:]
    let directory: URL
    private var writable = true
    private var loading = true
    private var polling: Task<Void, Never>?
    private var running = false
    private var lastLease = -Double.infinity
    private var identityTask: Task<Void, Never>?
    private var lastIdentityScan = -Double.infinity
    private var discoveredTargets = Set<FinishTarget>()
    private var sleepingObserver: NSObjectProtocol?
    private var panel: NSPanel?
    private var panelDelegate: FinishPanelDelegate?
    private let execute: @MainActor (FinishExecution) async throws -> Void
    private let presentUI: Bool
    private var knownSession: (FinishTarget) -> Bool = { _ in true }

    init(directory: URL = FinishFiles.defaultDirectory, presentUI: Bool = true,
         execute: @escaping @MainActor (FinishExecution) async throws -> Void = { try await MacFinishExecutor.execute($0) }) {
        self.directory = directory; self.execute = execute; self.presentUI = presentUI
        let file = directory.appendingPathComponent("finish-actions.json")
        if FileManager.default.fileExists(atPath: file.path) {
            if let saved = FinishFiles.preferences(in: directory), saved.valid { preferences = saved }
            else { writable = false; error = "Completion preferences could not be read. The original file is preserved." }
        }
        loading = false
    }

    var armed: Bool { machine.arm != nil }
    var pending: Bool { machine.pending != nil }
    var summary: String {
        guard let arm = machine.arm else { return "Do nothing · not armed" }
        return arm.preferences.action.title + (pending ? " in \(secondsRemaining)s" : " when finished")
    }

    func usesManagedSession(_ session: ResumeSession) -> Bool {
        guard let arm = machine.arm, preferences.enabled, arm.preferences.providers.contains(session.model.rawValue),
              session.hasLocalHistory != false, session.isSubagent != true, session.projectDirectory != nil,
              UUID(uuidString: session.sessionIdentifier) != nil,
              session.command.split(whereSeparator: \.isWhitespace).first.map(String.init) == session.model.rawValue else { return false }
        return arm.target == nil || arm.target == FinishTarget(provider: session.model.rawValue, sessionId: session.sessionIdentifier)
    }

    func start(store: SessionStore) {
        guard !running else { return }; running = true
        knownSession = { [weak store] target in
            store?.sessions.contains { $0.model.rawValue == target.provider && $0.sessionIdentifier.lowercased() == target.sessionId.lowercased() && $0.isSubagent != true } == true
        }
        sleepingObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
        updateMonitoring()
    }

    private func updateMonitoring() {
        guard !loading else { return }
        guard running, preferences.enabled, writable else {
            polling?.cancel(); polling = nil
            let lease = directory.appendingPathComponent("finish-monitor.json")
            if let data = try? Data(contentsOf: lease), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier { try? FileManager.default.removeItem(at: lease) }
            return
        }
        writeLease(force: true)
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.poll()
                await self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        running = false; identityTask?.cancel(); identityTask = nil
        polling?.cancel(); polling = nil; cancel()
        updateMonitoring()
        if let sleepingObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepingObserver) }
        sleepingObserver = nil
    }

    @discardableResult func arm(target: FinishTarget? = nil, now: Date = .now) -> Bool {
        guard !executing else { error = "Wait for the current action to finish before arming another."; return false }
        guard writable, preferences.ready else { error = "Choose an action and, if needed, a Shortcut first."; return false }
        if !preferences.enabled { preferences.enabled = true }
        if let target { preferences.providers.insert(target.provider) }
        guard writable else { return false }
        writeLease(force: true)
        guard machine.enable(preferences, target: target, now: now.timeIntervalSince1970) else { error = "Enable the selected assistant in completion settings first."; return false }
        error = nil; status = "Waiting for \(target?.provider.capitalized ?? "a connected assistant") to finish. This action will run once."
        return true
    }
    func cancel() {
        machine.cancel(); secondsRemaining = 0; status = "No action armed."
        panel?.orderOut(nil); panel = nil; panelDelegate = nil
    }

    func receive(_ event: FinishEvent, now: Date = .now, uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard preferences.enabled, isKnown(event.target) else { return }
        let previous = machine.pending
        machine.receive(event, now: now.timeIntervalSince1970, uptime: uptime)
        if machine.arm != nil, machine.activities[event.target]?.lastEventAt == event.occurredAt {
            if event.kind == .waiting { status = "An assistant is waiting for input or permission. The action is paused." }
            if [.failed, .cancelled].contains(event.kind) { status = "An assistant stopped without completing. Waiting for a new successful reply." }
        }
        if previous != nil && machine.pending == nil {
            panel?.orderOut(nil); panel = nil
            status = "New work or an input request paused the completion action."
        }
        if let pending = machine.pending, previous != pending {
            status = "\(pending.target.provider.capitalized) finished. The action will run after the countdown."
            secondsRemaining = max(0, Int(ceil(pending.deadline - uptime)))
            if machine.arm?.preferences.action != .notify { showPanel() }
        }
    }

    func tick(uptime: Double = ProcessInfo.processInfo.systemUptime) async {
        guard !executing else { return }
        if let pending = machine.pending { secondsRemaining = max(0, Int(ceil(pending.deadline - uptime))) }
        let hadArm = armed
        guard let execution = machine.takeDue(uptime: uptime) else {
            if hadArm && !armed { cancel(); status = "The old countdown was cancelled. Arm a new action when ready." }
            return
        }
        panel?.orderOut(nil); panel = nil; status = "Running \(execution.action.title.lowercased())…"
        executing = true; defer { executing = false }
        do {
            try await execute(execution)
            status = execution.action == .notify ? "\(execution.target.provider.capitalized) finished. No action armed." : "Action completed. No action armed."
            if execution.action == .notify && presentUI {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional { showPanel(notification: true) }
            }
        } catch { self.error = error.localizedDescription; status = "The action could not run. No action armed."; showPanel(notification: true) }
    }

    private func poll() {
        guard preferences.enabled else { return }
        writeLease()
        let queue = directory.appendingPathComponent("finish-events")
        guard let files = try? FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey]) else { return }
        let decoder = JSONDecoder()
        let events = files.prefix(1000).compactMap { file -> (URL, FinishEvent)? in
            guard file.pathExtension == "json" else { return nil } // Never remove an in-flight atomic writer's .tmp file.
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 8192,
                  let data = try? Data(contentsOf: file), let event = try? decoder.decode(FinishEvent.self, from: data) else { try? FileManager.default.removeItem(at: file); return nil }
            return (file, event)
        }.sorted { $0.1.occurredAt < $1.1.occurredAt }
        for (file, event) in events {
            // Unknown new sessions can be discovered by the next library sync. Keep briefly.
            if !isKnown(event.target), Date().timeIntervalSince1970 - event.occurredAt < 60 { refreshIdentities(); continue }
            receive(event); try? FileManager.default.removeItem(at: file)
        }
    }

    private func isKnown(_ target: FinishTarget) -> Bool { knownSession(target) || discoveredTargets.contains(target) }

    private func refreshIdentities() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard identityTask == nil, uptime - lastIdentityScan > 30 else { return }
        lastIdentityScan = uptime
        identityTask = Task { [weak self] in
            // Read only identity metadata; completion monitoring does not turn auto-save on.
            let result = await Task.detached(priority: .utility) { SessionDiscovery.scan() }.value
            guard !Task.isCancelled else { return }
            self?.discoveredTargets = Set(result.sessions.filter { $0.isSubagent != true }.map { FinishTarget(provider: $0.model.rawValue, sessionId: $0.sessionIdentifier) })
            self?.identityTask = nil
        }
    }

    private func writeLease(force: Bool = false) {
        guard running, preferences.enabled, force || ProcessInfo.processInfo.systemUptime - lastLease >= 5 else { return }
        let value: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "updatedAt": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: value) {
            try? data.write(to: directory.appendingPathComponent("finish-monitor.json"), options: .atomic)
            lastLease = ProcessInfo.processInfo.systemUptime
        }
    }

    func connect(_ provider: String, remove: Bool = false) async {
        if remove { cancel() }
        guard let runner = ManagedSessionCommand.runnerURL, let host = Bundle.main.executableURL else { error = "The bundled session component is missing."; return }
        let stable = ["/Applications/Reprise.app", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Reprise.app").path]
        guard stable.contains(Bundle.main.bundleURL.path) else { error = "Install Reprise in Applications before connecting native sessions."; return }
        do {
            let args = ["completion-hooks", remove ? "remove" : "install", provider, "--host", host.path, "--base", directory.path]
            let result = try await MacFinishExecutor.capture(runner, args: args)
            connectionStatus[provider] = result
        } catch { connectionStatus[provider] = error.localizedDescription }
    }

    private func save() {
        guard !loading, writable else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("finish-actions.json")
            try JSONEncoder().encode(preferences).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { writable = false; self.error = "Completion preferences could not be saved." }
    }

    private func showPanel(notification: Bool = false) {
        guard presentUI else { return }
        panel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setContentSize(NSSize(width: 380, height: 220))
        panel.title = notification ? "Reprise · Finished" : "Reprise · When finished"
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FinishCountdownView(controller: self, notification: notification))
        let delegate = FinishPanelDelegate { [weak self] in self?.cancel() }
        panel.delegate = delegate; panelDelegate = delegate
        panel.center(); panel.orderFrontRegardless(); self.panel = panel
    }
}

@MainActor private final class FinishPanelDelegate: NSObject, NSWindowDelegate {
    let cancel: () -> Void
    init(cancel: @escaping () -> Void) { self.cancel = cancel }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return true }
}

enum MacFinishError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let text) = self { text } else { nil } }
}

@MainActor enum MacFinishExecutor {
    static func execute(_ execution: FinishExecution) async throws {
        switch execution.action {
        case .none: return
        case .sleep:
            let port = IOPMFindPowerManagement(0)
            guard port != 0 else { throw MacFinishError.unavailable("macOS power management is unavailable.") }
            defer { IOServiceClose(port) }
            guard IOPMSleepSystem(port) == kIOReturnSuccess else { throw MacFinishError.unavailable("macOS declined the sleep request. Check System Settings → Battery or Energy.") }
        case .lock:
            guard AXIsProcessTrusted() else { throw MacFinishError.unavailable("To lock the screen, allow Reprise in System Settings → Privacy & Security → Accessibility. You can also use a macOS Shortcut for locking.") }
            _ = try await capture(URL(fileURLWithPath: "/usr/bin/osascript"), args: ["-e", "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"])
        case .shortcut:
            guard !execution.shortcutName.isEmpty, !execution.shortcutName.hasPrefix("-") else { throw MacFinishError.unavailable("Choose a macOS Shortcut first.") }
            _ = try await capture(URL(fileURLWithPath: "/usr/bin/shortcuts"), args: ["run", execution.shortcutName], timeout: 300)
        case .notify:
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                let content = UNMutableNotificationContent()
                content.title = "\(execution.target.provider.capitalized) finished"
                content.body = "Your coding session is ready."; content.sound = .default
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            } else { NSSound.beep() } // The in-app completion panel works without notification permission.
        }
    }

    static func capture(_ executable: URL, args: [String], timeout: Double = 15) async throws -> String {
        try await Task.detached {
            let process = Process(); process.executableURL = executable; process.arguments = args
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            try process.run()
            let work = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); work.cancel()
            guard process.terminationStatus == 0, data.count < 524288 else {
                let detail = data.count < 524288 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                throw MacFinishError.unavailable(detail.isEmpty ? "The action or connection could not finish. Check its permissions and try again." : String(detail.prefix(500)))
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
