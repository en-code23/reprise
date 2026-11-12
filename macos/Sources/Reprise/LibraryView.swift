import AppKit
import SwiftUI

@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    var onNewCapture: (() -> Void)?
    private let store: SessionStore
    private var window: NSWindow?
    init(store: SessionStore) { self.store = store }
    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: LibraryView(store: store) { [weak self] in self?.onNewCapture?() })
            let window = NSWindow(contentViewController: controller)
            window.title = "Reprise"
            window.setContentSize(NSSize(width: 1040, height: 720))
            window.minSize = NSSize(width: 860, height: 600)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct LibraryView: View {
    @ObservedObject var store: SessionStore
    let newCapture: () -> Void
    @State private var area: LibraryArea = .projects
    @State private var model: AssistantModel?
    @State private var sourceFilter: SessionSourceFilter = .mainSessions
    @State private var search = ""
    @State private var projectID: String?
    @State private var sessionID: UUID?
    @State private var editing: ResumeSession?
    @State private var removing: ResumeSession?
    @State private var errorMessage: String?
    @State private var finishTarget: FinishTarget?
    @ObservedObject var finish: FinishController = .shared
    @State private var launching = false
    @State private var openingEditor = false
    @State private var editorStatus: String?
    @State private var copied = false
    @State private var showDetails = false
    @ObservedObject private var editorPreference = EditorPreference.shared
    @ObservedObject var routing: RoutingStore = .shared
    @AppStorage(TerminalPreference.key) private var terminalRaw = TerminalApp.terminal.rawValue
    private var terminal: TerminalApp { TerminalApp(rawValue: terminalRaw) ?? .terminal }
    private var groups: [ProjectGroup] {
        ProjectLibrary.groups(store.sessions, model: model, query: search, origin: sourceFilter.origin,
            includeAutomation: sourceFilter.includesAutomation).filter { $0.area == area }
    }
    private var project: ProjectGroup? { groups.first { $0.id == projectID } }
    private var session: ResumeSession? { project?.sessions.first { $0.id == sessionID } ?? project?.latest }
    private var filtered: Bool { model != nil || sourceFilter != .mainSessions }

    var body: some View {
        HSplitView {
            projectSidebar.frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
            VStack(spacing: 0) {
                libraryToolbar
                if finish.armed {
                    HStack {
                        Label(finish.summary, systemImage: "moon").lineLimit(1)
                        Spacer()
                        Button("Cancel action", role: .cancel) { finish.cancel() }
                    }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color.repriseGreen.opacity(0.07))
                }
                Divider()
                projectContent
                if let error = store.storageError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(minWidth: 480).background(Color.repriseSurface)
        }
        .sheet(item: $editing) { SessionEditor(session: $0) { store.update($0) } }
        .sheet(isPresented: Binding(get: { finishTarget != nil }, set: { if !$0 { finishTarget = nil } })) {
            FinishSettingsView(controller: finish, target: finishTarget, sessionName: session?.displayName)
        }
        .alert("Remove this session?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let removing { store.delete(removing) }; removing = nil }
        } message: {
            Text("The original conversation stays on disk. You can restore removed entries from Library options.")
        }
        .alert("Could not open session", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: groups.map(\.id), initial: true) { _, ids in
            if !ids.contains(projectID ?? "") { projectID = ids.first; sessionID = nil }
        }
        .onChange(of: projectID) { _, _ in sessionID = nil; copied = false; editorStatus = nil }
        .onChange(of: sessionID) { _, _ in copied = false; editorStatus = nil }
        .task {
            while !Task.isCancelled {
                routing.readRunnerCaches()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Library", selection: $area) {
                    ForEach(LibraryArea.allCases) { Text($0 == .internalSessions ? "Internal" : $0.title).tag($0) }
                }.labelsHidden().pickerStyle(.menu).font(.system(size: 14, weight: .semibold))
                Spacer()
                Menu {
                    Button("Restore removed sessions") { Task { await store.restoreHiddenSessions() } }
                    Text(store.syncMessage)
                } label: { Image(systemName: "ellipsis").frame(width: 40, height: 40) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("Library options")
            }.padding(.horizontal, 12).frame(height: 52)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search folder names", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Search folder names")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }.font(.system(size: 13)).padding(10)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12).padding(.bottom, 12)
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Text(search.isEmpty ? "No projects" : "No matching folders").font(.system(size: 13, weight: .medium))
                    Button("Clear filters") { search = ""; model = nil; sourceFilter = .mainSessions }
                        .font(.system(size: 12))
                }.foregroundStyle(.secondary).padding(20)
                Spacer()
            } else {
                List(selection: $projectID) {
                    ForEach(groups) { group in
                        HStack(spacing: 10) {
                            Image(systemName: area == .unassigned ? "tray" : "folder")
                                .foregroundStyle(projectID == group.id ? Color.repriseGreen : .secondary)
                                .font(.system(size: 16)).frame(width: 20)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(group.displayDirectory).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            Text("\(group.sessions.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        }.padding(.vertical, 8).tag(group.id)
                            .accessibilityIdentifier("library.project.\(group.id)")
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden).tint(.repriseGreen)
            }
            Divider()
            HStack(spacing: 4) {
                if store.isSyncing { ProgressView().controlSize(.mini) }
                Text("\(groups.count) \(area == .unassigned ? "entries" : "projects")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await store.sync() } } label: { Image(systemName: "arrow.clockwise").frame(width: 32, height: 32) }
                    .buttonStyle(.borderless).disabled(store.isSyncing).help("Sync local sessions").accessibilityLabel("Sync now")
                Button { openSettings() } label: { Image(systemName: "gearshape").frame(width: 32, height: 32) }
                    .buttonStyle(.borderless).help("Settings").accessibilityLabel("Settings")
            }.padding(.horizontal, 12).frame(height: 44)
        }.background(Color.repriseCanvas)
    }

    private var libraryToolbar: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Assistant", selection: $model) {
                    Text("All assistants").tag(nil as AssistantModel?)
                    ForEach(AssistantModel.allCases) { Text($0.displayName).tag(Optional($0)) }
                }
                Divider()
                Picker("Source", selection: $sourceFilter) {
                    Text("Main sessions").tag(SessionSourceFilter.mainSessions)
                    Text("All sources").tag(SessionSourceFilter.allSources)
                    ForEach(SessionOrigin.allCases) { Text($0.title).tag(SessionSourceFilter.source($0)) }
                }
                if filtered { Divider(); Button("Reset filters") { model = nil; sourceFilter = .mainSessions } }
            } label: {
                Label(model?.displayName ?? (sourceFilter == .mainSessions ? "Filter" : "Filtered"), systemImage: "line.3.horizontal.decrease")
                    .foregroundStyle(filtered ? Color.repriseGreen : .primary)
            }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Filter sessions")
            Spacer()
            Button(action: newCapture) { Label("Add session", systemImage: "plus") }.keyboardShortcut("n")
        }.font(.system(size: 13)).padding(.horizontal, 20).frame(height: 52)
    }

    @ViewBuilder private var projectContent: some View {
        if let project, let session {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(project.title).font(.system(size: 20, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                            Text(project.displayDirectory).font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        sessionMenu(session, project: project)
                    }
                    HStack(spacing: 8) {
                        Button { resume(session, project: project) } label: {
                            Label(project.directory == nil ? "Choose folder" : launching ? "Opening…" : "Resume in \(terminal.name)", systemImage: "terminal")
                        }.buttonStyle(.borderedProminent).tint(.repriseGreen).controlSize(.large)
                            .disabled(launching || session.hasLocalHistory == false).keyboardShortcut(.return, modifiers: .command)
                        Button(copied ? "Copied" : "Copy command") { copy(session) }
                            .controlSize(.large)
                            .help(routing.usesManagedSession(session) || finish.usesManagedSession(session) ? "Copy the managed-session command" : "Copy the saved CLI command")
                        Button { openInEditor(session, project: project) } label: {
                            Text(openingEditor ? "Opening…" : "Open in \(editorPreference.selected?.name ?? "editor")")
                        }.controlSize(.large).disabled(openingEditor)
                            .help("Opens the folder and copies this session’s resume command")
                    }.font(.system(size: 12))
                    if let editorStatus { Text(editorStatus).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if routing.preferences.enabled, project.directory != nil {
                        ProjectRoutingView(routing: routing, session: session)
                    }
                    if session.hasLocalHistory == false {
                        Text("History is not on this Mac. Open this conversation in Codex to make it available locally.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if project.directory == nil {
                        Text("Choose a project folder to resume this saved capture.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text("Sessions").font(.system(size: 13, weight: .semibold))
                    Text("\(project.sessions.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Newest first").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.vertical, 8)
                List(selection: Binding<UUID?>(get: { sessionID ?? project.latest.id }, set: { sessionID = $0 })) {
                    ForEach(project.sessions) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.model.symbol).foregroundStyle(item.model.tint).frame(width: 20)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1).help(item.displayName)
                                Text("\(item.model.displayName) · \(item.hasLocalHistory == false ? "History not local" : item.origin.title)").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.vertical, 8).tag(item.id)
                            .accessibilityIdentifier("library.session.\(item.id)")
                            .contextMenu {
                                Button("Rename…") { editing = item }
                                Button("Copy command") { copy(item) }
                                Divider()
                                Button("Remove from library", role: .destructive) { removing = item }
                            }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden).tint(.repriseGreen).frame(minHeight: 140)
                Divider()
                DisclosureGroup("Session details", isExpanded: $showDetails) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(session.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .accessibilityIdentifier("session.command").frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Text(session.origin.title).foregroundStyle(.secondary)
                                Spacer()
                                Button("Edit details…") { editing = session }
                            }.font(.system(size: 12))
                            if !session.note.isEmpty { Text(session.note).font(.system(size: 13)).textSelection(.enabled) }
                            else { Button("Add note…") { editing = session }.font(.system(size: 12)) }
                        }.padding(.top, 12)
                    }.frame(maxHeight: 180)
                }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 12)
            }
        } else {
            ContentUnavailableView("Select a project", systemImage: "folder",
                description: Text("Your local sessions appear here after discovery."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sessionMenu(_ session: ResumeSession, project: ProjectGroup) -> some View {
        Menu {
            Button("Rename session…") { editing = session }
            Button("Edit details…") { editing = session }
            if session.model != .other && session.isSubagent != true && session.hasLocalHistory != false {
                Button("When this session finishes…") { finishTarget = FinishTarget(provider: session.model.rawValue, sessionId: session.sessionIdentifier) }
            }
            Button("Copy original CLI command") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.command, forType: .string)
            }
            Button("Choose project folder…") { chooseDirectory(project) }
            if let directory = project.directory {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory) }
            }
            Divider()
            Button("Remove from library", role: .destructive) { removing = session }
        } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("Session actions")
    }

    private func openSettings() {
        NSApp.sendAction(NSSelectorFromString("showPreferences:"), to: nil, from: nil)
    }
    private func copy(_ session: ResumeSession) {
        let command: String
        do { command = try ManagedSessionCommand.clipboardCommand(for: session, routing: routing, finish: finish) }
        catch { errorMessage = error.localizedDescription; return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
    private func resume(_ session: ResumeSession, project: ProjectGroup) {
        guard project.directory != nil else { chooseDirectory(project); return }
        launching = true
        Task {
            defer { launching = false }
            do { try await TerminalLauncher.launch(session) } catch { errorMessage = error.localizedDescription }
        }
    }
    private func chooseDirectory(_ project: ProjectGroup) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Use Project Folder"
        if panel.runModal() == .OK, let path = panel.url?.path {
            store.assignDirectory(path, to: Set(project.sessions.map(\.id)))
            area = ProjectLibrary.area(for: path)
            projectID = "directory:" + (ProjectLibrary.normalizedDirectory(path) ?? path)
        }
    }
    private func openInEditor(_ session: ResumeSession, project: ProjectGroup) {
        guard project.directory != nil else { chooseDirectory(project); return }
        if editorPreference.selected == nil { editorPreference.chooseApplication() }
        guard let editor = editorPreference.selected else { return }
        openingEditor = true
        Task {
            defer { openingEditor = false }
            do {
                let command = try ManagedSessionCommand.clipboardCommand(for: session, routing: routing)
                try await EditorLauncher.open(session, editor: editor, resumeCommand: command)
                if projectID == project.id { editorStatus = "Project opened. Resume command copied." }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct SessionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var session: ResumeSession
    @FocusState private var nameFocused: Bool
    let save: (ResumeSession) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Session details").font(.title2.weight(.semibold))
            Form {
                TextField("Session name", text: Binding(get: { session.name ?? "" }, set: { session.name = $0 }),
                    prompt: Text(session.detectedName ?? "Fix checkout retries"))
                    .focused($nameFocused).accessibilityIdentifier("sessionEditor.name")
                Text("Leave blank to use the imported name or session ID.").font(.caption).foregroundStyle(.secondary)
                TextField("Project name", text: $session.project)
                Picker("Session source", selection: $session.originOverride) {
                    Text("Automatic (\((session.detectedOrigin ?? .unknown).title))").tag(nil as SessionOrigin?)
                    ForEach(SessionOrigin.allCases) { Text($0.title).tag(Optional($0)) }
                }
                if let evidence = session.sourceEvidence, !evidence.isEmpty {
                    Text(evidence.joined(separator: " · ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                TextField("Directory", text: Binding(get: { session.projectDirectory ?? "" }, set: { session.projectDirectory = $0 }))
                TextField("Command", text: $session.command)
                TextField("Note", text: $session.note, axis: .vertical).lineLimit(3...6)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(session); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(session.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 560).onAppear { nameFocused = true }
    }
}
