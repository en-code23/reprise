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
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.minSize = NSSize(width: 1000, height: 640)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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
    @State private var launching = false
    @State private var openingEditor = false
    @State private var editorStatus: String?
    @ObservedObject private var editorPreference = EditorPreference.shared
    @State private var copied = false
    @State private var showAllSessions = false
    @AppStorage(TerminalPreference.key) private var terminalRaw = TerminalApp.terminal.rawValue
    private var terminal: TerminalApp { TerminalApp(rawValue: terminalRaw) ?? .terminal }

    private var allGroups: [ProjectGroup] { ProjectLibrary.groups(store.sessions, model: model, origin: sourceFilter.origin, includeAutomation: sourceFilter.includesAutomation) }
    private var groups: [ProjectGroup] {
        ProjectLibrary.groups(store.sessions, model: model, query: search, origin: sourceFilter.origin, includeAutomation: sourceFilter.includesAutomation).filter { $0.area == area }
    }
    private var project: ProjectGroup? { groups.first { $0.id == projectID } }
    private var session: ResumeSession? { project?.sessions.first { $0.id == sessionID } ?? project?.latest }
    private func count(_ area: LibraryArea) -> Int { allGroups.filter { $0.area == area }.count }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 184)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                HSplitView {
                    projectList.frame(minWidth: 250, idealWidth: 288, maxWidth: 340)
                    detail.frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
                if let error = store.storageError {
                    Text(error).font(.callout).foregroundStyle(.red).padding(10)
                }
            }.background(Color.repriseSurface)
        }
        .sheet(item: $editing) { SessionEditor(session: $0) { store.update($0) } }
        .alert("Remove this session?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let removing { store.delete(removing) }; removing = nil }
        } message: { Text("Only this session is removed from Reprise. Its original conversation stays on disk. You can restore it from the library menu.") }
        .alert("Could not open session", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: groups.map(\.id), initial: true) { _, ids in
            if !ids.contains(projectID ?? "") { projectID = ids.first; sessionID = nil }
        }
        .onChange(of: projectID) { _, _ in sessionID = nil; copied = false; showAllSessions = false; editorStatus = nil }
        .onChange(of: sessionID) { _, _ in editorStatus = nil }
        .onChange(of: sourceFilter) { _, _ in sessionID = nil; copied = false; showAllSessions = false }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text("Reprise").font(.system(size: 17, weight: .semibold))
            }.padding(.top, 24)
            ScrollView { sidebarNavigation }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(Color.repriseGreen).frame(width: 6, height: 6)
                    Text(store.isSyncing ? "Syncing…" : "Saved on this Mac").font(.system(size: 11, weight: .medium))
                }
                Toggle("Auto-save sessions", isOn: $store.autoDiscovery).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                VStack(alignment: .leading, spacing: 6) {
                    Text("DEFAULT TERMINAL").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    TerminalPreferencePicker().labelsHidden().font(.system(size: 12)).controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("DEFAULT EDITOR").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    EditorPreferenceMenu().font(.system(size: 12)).controlSize(.small)
                }
                CheckForUpdatesButton().buttonStyle(RepriseQuietButtonStyle(tint: .primary)).font(.system(size: 11))
                HStack {
                    Button("Sync now") { Task { await store.sync() } }.disabled(store.isSyncing)
                    Spacer()
                    Menu {
                        Text(store.syncMessage)
                        Button("Restore removed sessions") { Task { await store.restoreHiddenSessions() } }
                    } label: { Image(systemName: "ellipsis").frame(width: 40, height: 40).contentShape(Rectangle()) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("Library options")
                }.font(.system(size: 11))
            }
        }.padding(.horizontal, 14).padding(.bottom, 20).background(Color.repriseCanvas)
    }

    private var sidebarNavigation: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LIBRARY").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
                ForEach(LibraryArea.allCases) { item in
                    Button { area = item; model = nil; sourceFilter = .mainSessions } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol).frame(width: 16)
                            Text(item == .internalSessions ? "Internal" : item.title)
                            Spacer(minLength: 2)
                            Text("\(count(item))").monospacedDigit().foregroundStyle(.secondary)
                        }.font(.system(size: 12, weight: area == item ? .semibold : .regular))
                            .padding(.horizontal, 9).frame(height: 40)
                            .foregroundStyle(.primary)
                            .background(area == item ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(RepriseRowButtonStyle()).accessibilityIdentifier("library.area.\(item.id)")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ASSISTANTS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(AssistantModel.allCases.filter { store.count(for: $0) > 0 }) { assistant in
                    Button { model = model == assistant ? nil : assistant } label: {
                        HStack(spacing: 8) {
                            Circle().fill(assistant.tint).frame(width: 6, height: 6)
                            Text(assistant.displayName)
                            Spacer()
                            if model == assistant { Image(systemName: "checkmark") }
                        }.font(.system(size: 12)).foregroundStyle(.primary).frame(height: 40)
                    }.buttonStyle(RepriseRowButtonStyle()).accessibilityIdentifier("library.assistant.\(assistant.id)")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            Text(area.title).font(.system(size: 18, weight: .semibold))
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search folder names", text: $search).textFieldStyle(.plain).accessibilityLabel("Search folder names")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(RepriseQuietButtonStyle(minimumSize: 32, tint: .secondary))
                        .accessibilityLabel("Clear search")
                }
            }.font(.system(size: 12)).padding(8).frame(maxWidth: 260).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                Picker("Source", selection: $sourceFilter) {
                    Text("Main sessions").tag(SessionSourceFilter.mainSessions)
                    Text("All sources").tag(SessionSourceFilter.allSources)
                    ForEach(SessionOrigin.allCases) { Text($0.title).tag(SessionSourceFilter.source($0)) }
            }.labelsHidden().accessibilityLabel("Filter by session source").frame(width: 146)
            Button(action: newCapture) { Label("Add session", systemImage: "plus") }.keyboardShortcut("n")
        }.padding(.horizontal, 24).frame(height: 68)
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(groups.count) \(area == .unassigned ? "unassigned" : "projects")")
                Spacer()
                Text("Recent first")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(16)
            if groups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(search.isEmpty ? "Nothing here yet" : "No matches").font(.headline)
                    Text(area == .unassigned ? "Saved entries without a project folder appear here." : "Try another filter, sync your local sessions, or add a screenshot.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Clear filters") { search = ""; model = nil; sourceFilter = .mainSessions }
                }.padding(16)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(groups) { group in
                        Button { projectID = group.id } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: area == .unassigned ? "tray" : "folder")
                                    .foregroundStyle(projectID == group.id ? Color.repriseGreen : Color.secondary).font(.system(size: 16)).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(group.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text("\(group.sessions.count)").font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    Text(group.displayDirectory).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    HStack {
                                        Text(group.assistants.map(\.displayName).joined(separator: " · "))
                                        Spacer(minLength: 0)
                                        Text(group.latest.createdAt, format: .dateTime.month(.abbreviated).day())
                                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }.foregroundStyle(.primary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(projectID == group.id ? Color.repriseGreen.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(RepriseRowButtonStyle()).accessibilityIdentifier("library.project.\(group.id)")
                    }
                }.padding(.horizontal, 8)
            }
        }.background(Color.repriseSurface)
    }

    @ViewBuilder private var detail: some View {
        if let project, let session {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(area == .unassigned ? "NEEDS A PROJECT" : "PROJECT OVERVIEW")
                                .font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Button("Edit session details") { editing = session }
                                Button("Choose project folder…") { chooseDirectory(project) }
                                if let directory = project.directory { Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory) } }
                                Divider()
                                Button("Remove selected session", role: .destructive) { removing = session }
                            } label: { Image(systemName: "ellipsis").frame(width: 40, height: 40).contentShape(Rectangle()) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("Project options")
                        }
                        Text(project.title).font(.system(size: 30, weight: .semibold)).tracking(-0.7).textSelection(.enabled)
                        Text(project.displayDirectory).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        if area == .unassigned {
                            Text("This is an older saved capture or manual entry, not a project. Choose its folder to add it to Projects.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                            if let source = session.sourceFileName { Text("Source: \(source)").font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        if area == .internalSessions {
                            Text("This session runs inside an assistant's internal workspace. It is kept separate from your project folders.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
                            if project.directory == nil { chooseDirectory(project); return }
                            launching = true
                            Task {
                                defer { launching = false }
                                do { try await TerminalLauncher.launch(session) } catch { errorMessage = error.localizedDescription }
                            }
                        } label: {
                            Label(project.directory == nil ? "Choose project folder" : launching ? "Opening \(terminal.name)…" : "Resume in \(terminal.name)", systemImage: "terminal")
                                .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent).tint(.repriseGreen).disabled(launching).keyboardShortcut(.return, modifiers: .command)
                        Button(copied ? "Copied" : "Copy command") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.command, forType: .string)
                            copied = true; Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        }.buttonStyle(RepriseQuietButtonStyle()).font(.system(size: 12))
                        Button("Rename") { editing = session }
                            .buttonStyle(RepriseQuietButtonStyle()).font(.system(size: 12))
                            .help("Rename the selected session")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            openInEditor(session, project: project)
                        } label: {
                            Label(openingEditor ? "Opening editor…" : "Open in \(editorPreference.selected?.name ?? "editor")", systemImage: "curlybraces.square")
                                .font(.system(size: 13, weight: .medium)).padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered).disabled(openingEditor)
                        .help("Open this project in your editor and copy the selected resume command")
                        Text(editorStatus ?? "Opens the project and copies this session’s resume command.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Sessions").font(.system(size: 15, weight: .semibold))
                            Text("\(project.sessions.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Text("Latest first").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        ForEach(Array((showAllSessions ? project.sessions[...] : project.sessions.prefix(4)))) { item in
                            sessionRow(item, latest: item.id == project.latest.id, selected: item.id == session.id)
                        }
                        if project.sessions.count > 4 {
                            Button(showAllSessions ? "Show recent sessions" : "Show all \(project.sessions.count) sessions") { showAllSessions.toggle() }
                                .buttonStyle(RepriseQuietButtonStyle()).font(.system(size: 12))
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("COMMAND").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                            Spacer()
                            Text(session.displayName).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).help(session.displayName).accessibilityIdentifier("session.name")
                        }
                        Text(session.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .accessibilityIdentifier("session.command")
                            .foregroundStyle(Color.repriseBone).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.repriseTerminal, in: RoundedRectangle(cornerRadius: 8))
                        Text("Recorded source: \(session.origin.title)\(session.originOverride == nil ? "" : " (manual)")")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if session.origin == .unknown {
                            Text("The local record does not identify its client. Set a source in Session details if you know it.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Session note").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button(session.note.isEmpty ? "Add note" : "Edit") { editing = session }
                                .buttonStyle(RepriseQuietButtonStyle()).font(.system(size: 12))
                        }
                        Text(session.note.isEmpty ? "What would you like to pick up next?" : session.note)
                            .font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.padding(28)
            }.background(Color.repriseCanvas.opacity(0.4))
        } else {
            ContentUnavailableView("A place for every project", systemImage: "folder", description: Text("Select a project to resume its latest session or browse its history."))
        }
    }

    private func sessionRow(_ item: ResumeSession, latest: Bool, selected: Bool) -> some View {
        Button { sessionID = item.id; copied = false } label: {
            HStack(spacing: 10) {
                Image(systemName: item.model.symbol).foregroundStyle(item.model.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.displayName).fontWeight(.medium).lineLimit(1).help(item.displayName)
                        if latest { Text("Latest").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }.font(.system(size: 12))
                    HStack(spacing: 6) {
                        Text("\(item.model.displayName) · \(item.origin.title)")
                        Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if item.name != nil || item.detectedName != nil {
                    Text(String(item.sessionIdentifier.suffix(8)))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.repriseGreen : Color.secondary.opacity(0.4))
            }.foregroundStyle(.primary).padding(10).frame(maxWidth: .infinity)
                .background(selected ? Color.repriseGreen.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(RepriseRowButtonStyle()).accessibilityIdentifier("library.session.\(item.id)")
            .contextMenu { Button("Rename session…") { editing = item } }
    }

    private func chooseDirectory(_ project: ProjectGroup) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use Project Folder"
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
                try await EditorLauncher.open(session, editor: editor)
                if projectID == project.id { editorStatus = "Opened in \(editor.name). Resume command copied." }
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
