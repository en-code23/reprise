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
            window.title = "Reprise — Session Library"
            window.setContentSize(NSSize(width: 1120, height: 740))
            window.minSize = NSSize(width: 920, height: 600)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct LibraryView: View {
    @ObservedObject var store: SessionStore
    let newCapture: () -> Void
    @State private var search = ""
    @State private var model: AssistantModel?
    @State private var selection: UUID?
    @State private var editing: ResumeSession?
    @State private var removing: ResumeSession?
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var launching = false
    private var matches: [ResumeSession] {
        store.sessions.filter { session in
            (model == nil || session.model == model) && (search.isEmpty ||
                [session.project, session.projectDirectory ?? "", session.command, session.note]
                    .joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }
    private var selected: ResumeSession? { matches.first { $0.id == selection } }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sessionList.frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
                detail.frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            syncBar
        }
        .background(Color.repriseSurface)
        .sheet(item: $editing) { session in SessionEditor(session: session) { store.update($0) } }
        .alert("Remove session from Reprise?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let session = removing { store.delete(session) }; removing = nil }
        } message: { Text("The original conversation stays on disk. Automatic discovery will not add this session again.") }
        .alert("Could not resume session", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: matches.map(\.id), initial: true) { _, ids in
            if selection == nil || !ids.contains(selection!) { selection = ids.first }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your work, ready to resume").font(.system(size: 26, weight: .semibold))
                    Text("\(store.sessions.count) sessions · Private on this Mac").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: newCapture) { Label("Add screenshot", systemImage: "photo.badge.plus") }.controlSize(.large).keyboardShortcut("n")
            }
            HStack(spacing: 12) {
                TextField("Search projects, folders, notes or commands", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel("Search sessions")
                Picker("Assistant", selection: $model) {
                    Text("All assistants").tag(nil as AssistantModel?)
                    ForEach(AssistantModel.allCases) { Text($0.displayName).tag(Optional($0)) }
                }.frame(width: 190)
            }
        }.padding(24)
    }
    private var sessionList: some View {
        Group {
            if matches.isEmpty {
                ContentUnavailableView("No sessions found", systemImage: "magnifyingglass", description: Text("Try another search, sync local sessions, or add a screenshot."))
            } else {
                ScrollView {
                  LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(AssistantModel.allCases) { assistant in
                        let group = matches.filter { $0.model == assistant }
                        if !group.isEmpty {
                            Text("\(assistant.displayName) · \(group.count)")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8)
                                ForEach(group) { session in
                                  Button { selection = session.id; copied = false } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(session.project).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                        Text(session.projectDirectory ?? "Choose a project folder").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        HStack {
                                            Text(session.discoveryKey != nil ? "Auto-saved" : "Screenshot / manual")
                                            Spacer()
                                            Text(session.createdAt, style: .date)
                                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                                    }.foregroundStyle(.primary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                      .background(selection == session.id ? Color.repriseGreen.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                  }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Edit details") { editing = session }
                                        Button("Remove from library", role: .destructive) { removing = session }
                                    }
                                }
                        }
                    }
                  }.padding(12)
                }.background(Color.repriseCanvas)
            }
        }
    }
    @ViewBuilder private var detail: some View {
        if let session = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Label(session.model.displayName, systemImage: session.model.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(session.model.tint)
                        Spacer()
                        Button("Edit details") { editing = session }
                    }
                    Text(session.project).font(.system(size: 28, weight: .semibold)).textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("PROJECT DIRECTORY")
                        Text(session.projectDirectory ?? "No folder selected").font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button("Choose folder…") { chooseDirectory(for: session) }
                            if let path = session.projectDirectory {
                                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (path as NSString).expandingTildeInPath) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("RESUME COMMAND")
                        Text(session.command).font(.system(size: 14, design: .monospaced)).foregroundStyle(Color.repriseBone).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(Color.repriseTerminal, in: RoundedRectangle(cornerRadius: 10))
                        HStack {
                            Button {
                                launching = true
                                Task {
                                    defer { launching = false }
                                    do { try await TerminalLauncher.launch(session) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            } label: { Label(launching ? "Opening Terminal…" : "Resume in Terminal", systemImage: "terminal") }
                                .buttonStyle(.borderedProminent).tint(.repriseGreen).controlSize(.large).disabled(launching).keyboardShortcut(.return, modifiers: .command)
                            Button(copied ? "Copied!" : "Copy command") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.command, forType: .string)
                                copied = true
                                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                            }.controlSize(.large)
                        }
                        Text("Opens a new Terminal session in the project folder. Your CLI handles sign-in and session loading.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("PROJECT NOTES")
                        Text(session.note.isEmpty ? "Add a note to remember where you left off." : session.note)
                            .font(.system(size: 14)).foregroundStyle(session.note.isEmpty ? .secondary : .primary).textSelection(.enabled)
                    }
                    Divider()
                    HStack {
                        Text("Last activity \(session.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", role: .destructive) { removing = session }
                    }
                }.padding(28)
            }
        } else {
            ContentUnavailableView("Ready when you are", systemImage: "terminal", description: Text("Select a saved session to see its project and resume your work."))
        }
    }
    private var syncBar: some View {
        HStack(spacing: 12) {
            Toggle("Auto-save local sessions", isOn: $store.autoDiscovery).toggleStyle(.switch).controlSize(.small)
            if store.isSyncing { ProgressView().controlSize(.small) }
            Text(store.storageError ?? store.syncMessage).font(.system(size: 12)).foregroundStyle(store.storageError == nil ? .secondary : Color.red).lineLimit(2)
            Spacer()
            Button("Sync now") { Task { await store.sync() } }.disabled(store.isSyncing)
            Menu {
                Button("Restore removed local sessions") { Task { await store.restoreHiddenSessions() } }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
    }
    private func chooseDirectory(for session: ResumeSession) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use Project Folder"
        if panel.runModal() == .OK, let url = panel.url {
            var updated = session; updated.projectDirectory = url.path; store.update(updated)
        }
    }
}

private struct SessionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var session: ResumeSession
    let save: (ResumeSession) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit session").font(.title2.weight(.semibold))
            Form {
                TextField("Project", text: $session.project)
                TextField("Directory", text: Binding(get: { session.projectDirectory ?? "" }, set: { session.projectDirectory = $0 }))
                TextField("Command", text: $session.command)
                TextField("Notes", text: $session.note, axis: .vertical).lineLimit(3...6)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save changes") { save(session); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(session.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 560)
    }
}
