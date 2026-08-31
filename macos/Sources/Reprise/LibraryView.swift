import AppKit
import SwiftUI

private enum LibraryFilter: Hashable {
    case all
    case model(AssistantModel)
}

@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    var onNewCapture: (() -> Void)?

    private let store: SessionStore
    private var window: NSWindow?

    init(store: SessionStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let rootView = LibraryView(store: store) { [weak self] in
                self?.onNewCapture?()
            }
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Reprise Library"
            window.setContentSize(NSSize(width: 980, height: 640))
            window.minSize = NSSize(width: 760, height: 500)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct LibraryView: View {
    @ObservedObject var store: SessionStore
    let newCapture: () -> Void

    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @State private var copiedID: UUID?

    private var filteredSessions: [ResumeSession] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.sessions.filter { session in
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .model(let model): session.model == model
            }
            let haystack = [
                session.project,
                session.projectDirectory ?? "",
                session.note,
                session.command,
                session.model.displayName
            ]
                .joined(separator: " ")
                .lowercased()
            return matchesFilter && (needle.isEmpty || haystack.contains(needle))
        }
    }

    private var groupedSessions: [(AssistantModel, [ResumeSession])] {
        AssistantModel.allCases.compactMap { model in
            let matches = filteredSessions.filter { $0.model == model }
            return matches.isEmpty ? nil : (model, matches)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            VStack(spacing: 0) {
                libraryHeader
                Divider()
                content
            }
            .background(Color.repriseSurface)
        }
        .background(Color.repriseCanvas)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reprise")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Session notebook")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 28)
            .padding(.bottom, 16)

            List(selection: $filter) {
                Section("WORKSPACE") {
                    Label {
                        HStack {
                            Text("All Sessions")
                            Spacer()
                            Text("\(store.sessions.count)")
                                .foregroundStyle(.tertiary)
                        }
                    } icon: {
                        Image(systemName: "books.vertical")
                    }
                    .tag(LibraryFilter.all)
                }

                Section("ASSISTANTS") {
                    ForEach(AssistantModel.allCases) { model in
                        Label {
                            HStack {
                                Text(model.displayName)
                                Spacer()
                                Text("\(store.count(for: model))")
                                    .foregroundStyle(.tertiary)
                            }
                        } icon: {
                            Image(systemName: model.symbol)
                                .foregroundStyle(model.tint)
                        }
                        .tag(LibraryFilter.model(model))
                    }
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 7) {
                Circle().fill(Color.repriseGreen).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stored locally")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Nothing is uploaded.")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(14)
        }
    }

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Resume library")
                    .font(.system(size: 25, weight: .semibold))
                    .tracking(-0.6)
                Text("\(store.sessions.count) saved \(store.sessions.count == 1 ? "session" : "sessions")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Search projects or commands", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
            Button(action: newCapture) {
                Label("Capture Session", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.repriseGreen)
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var content: some View {
        if filteredSessions.isEmpty {
            ContentUnavailableView {
                Label(
                    store.sessions.isEmpty ? "No saved sessions" : "No matching sessions",
                    systemImage: store.sessions.isEmpty ? "terminal" : "magnifyingglass"
                )
            } description: {
                Text(store.sessions.isEmpty
                     ? "Drop a terminal screenshot on the Reprise menubar icon to begin."
                     : "Try a different search or assistant filter.")
            } actions: {
                if store.sessions.isEmpty {
                    Button("Capture a Session", action: newCapture)
                } else {
                    Button("Clear Search") { search = "" }
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(groupedSessions, id: \.0) { model, sessions in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: model.symbol)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(model.tint)
                                    .frame(width: 26, height: 26)
                                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                                Text(model.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text("\(sessions.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.primary.opacity(0.05), in: Capsule())
                            }

                            VStack(spacing: 0) {
                                ForEach(sessions) { session in
                                    SessionLibraryRow(
                                        session: session,
                                        copied: copiedID == session.id,
                                        copy: { copy(session) },
                                        delete: { store.delete(session) }
                                    )
                                    if session.id != sessions.last?.id { Divider() }
                                }
                            }
                            .background(Color.repriseCanvas.opacity(0.48), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
    }

    private func copy(_ session: ResumeSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.command, forType: .string)
        copiedID = session.id
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if copiedID == session.id { copiedID = nil }
        }
    }
}

private struct SessionLibraryRow: View {
    let session: ResumeSession
    let copied: Bool
    let copy: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.project)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let directory = session.projectDirectory, !directory.isEmpty {
                    Label(directory, systemImage: "folder")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(session.note.isEmpty ? "No project note" : session.note)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(minWidth: 180, maxWidth: 240, alignment: .leading)

            HStack(spacing: 8) {
                Text("$")
                    .foregroundStyle(Color.repriseGreen)
                Text(session.command)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Copy resume command")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Color.repriseBone)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Color.repriseTerminal, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .trailing, spacing: 3) {
                Text(session.createdAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(session.detectedAutomatically ? "AUTO" : "MANUAL")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(session.detectedAutomatically ? Color.repriseGreen : Color.secondary)
            }
            .frame(width: 62, alignment: .trailing)

            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete session")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 74)
        .contextMenu {
            Button("Copy Command", action: copy)
            Button("Delete Session", role: .destructive, action: delete)
        }
    }
}
