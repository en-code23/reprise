import SwiftUI

struct RoutingSettingsView: View {
    @ObservedObject var routing: RoutingStore
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AssistantModel = .codex
    private var state: ProviderRoutingState? { routing.states[provider] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Automatic model selection").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Chooses within the session’s provider. Managed sessions reassess each new task and switch between turns. Local analysis uses project structure, activity, and the task text; it does not upload source code to another model.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Toggle("Enable automatic selection", isOn: $routing.preferences.enabled)
                Toggle("Switch between turns in managed sessions", isOn: $routing.preferences.continuous)
                Toggle("Use more capability when a reset is near", isOn: $routing.preferences.useExpiringHeadroom)
                Stepper("Conserve below \(Int(routing.preferences.reservePercent))% remaining", value: $routing.preferences.reservePercent, in: 5...50, step: 5)
            }.formStyle(.columns)
            Divider()
            Picker("Provider", selection: $provider) {
                ForEach([AssistantModel.codex, .claude, .grok]) { Text($0.displayName).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(state?.status ?? "Connect usage to see current limits and reset times.")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        if routing.refreshing.contains(provider) { ProgressView().controlSize(.small) }
                        Button(provider == .claude && !routing.claudeConnected ? "Connect Claude usage…" : "Refresh") {
                            if provider == .claude { routing.claudeConnected = true }
                            Task { await routing.refresh(provider) }
                        }.disabled(!routing.preferences.enabled || routing.refreshing.contains(provider))
                    }
                    if provider == .claude {
                        Text("Uses Claude Code’s subscription login. macOS may ask for Keychain access. Only quota percentages and reset times are saved. The usage connection depends on Claude’s own endpoint and may need an update when it changes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let state {
                        ForEach(state.windows) { window in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(window.label).fontWeight(.medium)
                                    Spacer()
                                    Text("\(Int(window.remainingPercent))% left").monospacedDigit()
                                }
                                ProgressView(value: min(100, max(0, window.usedPercent)), total: 100).tint(.repriseGreen)
                                HStack {
                                    Text(window.resetsAt > Date() ? "Resets \(window.resetsAt.formatted(.relative(presentation: .named)))" : "Reset passed · refresh required")
                                    Spacer()
                                    if !window.fresh(at: .now) { Text("Stale").foregroundStyle(.orange) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }.font(.system(size: 12)).padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    if provider == .claude {
                        Toggle("Allow Fable when its included allowance has room", isOn: $routing.preferences.useFableAllowance)
                        Text("Fable must pass both the shared and model-specific limits. Unused reset credits are not treated as automatic capacity, and Reprise does not redeem them.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let windows = state?.windows, windows.contains(where: { $0.id.hasPrefix("seven_day_") && !$0.specialAllowance && !["seven_day_opus", "seven_day_sonnet"].contains($0.id) }) {
                            Picker("Fable allowance field", selection: $routing.fableWindowID) {
                                Text("Automatic · named Fable field only").tag("")
                                ForEach(windows.filter { $0.id.hasPrefix("seven_day_") && $0.id != "seven_day" }) { Text($0.id).tag($0.id) }
                            }
                            Text("If Claude uses an unnamed model allowance, select its field only after matching it to Fable in Claude’s Usage screen, then refresh. Reprise never guesses that association.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("Model roles and advanced options") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let state {
                                ForEach(state.models) { model in
                                    Picker(model.name, selection: Binding(get: { routing.states[provider]?.models.first(where: { $0.id == model.id })?.role ?? model.role }, set: { routing.setRole($0, model: model, provider: provider) })) {
                                        Text("Economy").tag(ModelRole.economy)
                                        Text("Everyday").tag(ModelRole.balanced)
                                        Text("Strong").tag(ModelRole.strong)
                                        Text("Architecture").tag(ModelRole.frontier)
                                    }
                                }
                            }
                            Toggle("Allow max only for large, early backend foundations", isOn: $routing.preferences.allowFoundationMax)
                            Text("Normally capped at high. This exception also needs at least 75% shared quota remaining. Reset timing alone never enables max or ultra.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }
                    if let error = routing.storageError { Text(error).foregroundStyle(.red).font(.callout) }
                    Text("Selections are estimates, not a prediction of exact usage. Each provider remains responsible for enforcing its limits and billing settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.trailing, 4)
            }
        }.padding(24).frame(width: 660, height: 650).background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ProjectRoutingView: View {
    @ObservedObject var routing: RoutingStore
    let session: ResumeSession
    @State private var decision: RoutingDecision?
    @State private var expanded = false
    @State private var revision = 0
    private var directory: String { session.projectDirectory ?? "" }
    private var key: String { ProjectLibrary.normalizedDirectory(directory) ?? directory }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use automatic selection for this project", isOn: Binding(get: { !routing.preferences.disabledProjects.contains(key) }, set: { enabled in
                    if enabled { routing.preferences.disabledProjects.remove(key) } else { routing.preferences.disabledProjects.insert(key) }
                    revision += 1
                }))
                Picker("Work type", selection: Binding(get: { routing.preferences.workHints[key] ?? .automatic }, set: { routing.setHint($0, directory: directory); revision += 1 })) {
                    ForEach(WorkKind.allCases) { Text($0.title).tag($0) }
                }
                if let decision { ForEach(Array(decision.reasons.enumerated()), id: \.offset) { Text($0.element).foregroundStyle(.secondary) } }
                if routing.preferences.continuous { Text("Project preview. The managed session also considers each new task before choosing its model.").foregroundStyle(.secondary) }
                HStack {
                    Button("Refresh usage") { Task { await routing.refresh(session.model); revision += 1 } }
                        .disabled(routing.refreshing.contains(session.model))
                    Spacer()
                    if routing.refreshing.contains(session.model) { ProgressView().controlSize(.mini) }
                }
            }.font(.system(size: 12)).padding(.top, 10)
        } label: {
            Label(decision.map { "Auto · " + $0.label } ?? (routing.preferences.disabledProjects.contains(key) ? "Using the tool’s model" : "Automatic model selection"), systemImage: "slider.horizontal.3")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        .task(id: session.identityKey + ":\(revision):\(routing.preferences):\(routing.states[session.model]?.observedAt?.timeIntervalSince1970 ?? 0)") {
            let selected = await routing.decision(for: session)
            guard !Task.isCancelled else { return }
            decision = selected
        }
    }
}
