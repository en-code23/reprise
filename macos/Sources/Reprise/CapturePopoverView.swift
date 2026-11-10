import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CapturePopoverView: View {
    @ObservedObject var coordinator: CaptureCoordinator
    @ObservedObject var store: SessionStore
    let openLibrary: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch coordinator.phase {
                case .idle:
                    idleView
                case .reading:
                    readingView
                case .review:
                    reviewView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if coordinator.phase == .review {
                Divider()
                reviewActions.padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 620)
        .background(Color.repriseSurface)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Reprise")
                    .font(.system(size: 13, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if coordinator.phase != .idle {
                Button {
                    coordinator.reset()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(RepriseQuietButtonStyle(tint: .primary))
                .accessibilityLabel("Cancel capture")
                .help("Cancel capture")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var headerSubtitle: String {
        switch coordinator.phase {
        case .idle: "Local coding sessions"
        case .reading: "Reading terminal screenshot"
        case .review: "Review before saving"
        }
    }

    private var idleView: some View {
        VStack(spacing: 14) {
            DropTargetCard(
                isTargeted: $coordinator.isDropTargeted,
                onDrop: { urls in
                    guard let url = urls.first else { return false }
                    coordinator.receive(url: url)
                    return true
                },
                chooseImage: coordinator.chooseImage
            )

            Button("Enter a command manually") { coordinator.startManual() }
                .buttonStyle(RepriseQuietButtonStyle())

            if let error = coordinator.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            if !store.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Recent projects")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    ForEach(Array(ProjectLibrary.groups(store.sessions).filter { $0.area == .projects }.prefix(3))) { project in
                        CompactSessionRow(session: project.latest)
                    }
                }
            }
        }
        .padding(16)
    }

    private var readingView: some View {
        VStack(spacing: 18) {
            ScreenshotPreview(image: coordinator.previewImage)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.repriseGreen)
                        .frame(height: 2)
                        .shadow(color: .repriseGreen.opacity(0.7), radius: 6)
                        .padding(.horizontal, 8)
                }

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finding the resume command…")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Apple Vision is reading the screenshot on this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(16)
    }

    private var reviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if coordinator.detectedAutomatically {
                    Label("Command detected. Review before saving.", systemImage: "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let error = coordinator.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red)
                }
                if coordinator.previewImage != nil {
                    ScreenshotPreview(image: coordinator.previewImage).frame(height: 90)
                }
                Form {
                    Picker("Assistant", selection: $coordinator.model) {
                        ForEach(AssistantModel.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Command", text: $coordinator.command,
                        prompt: Text(CommandParser.resumeCommand(model: coordinator.model, identifier: "session-id")))
                        .font(.system(size: 12, design: .monospaced))
                    TextField("Project name", text: $coordinator.project, prompt: Text("Billing portal"))
                    TextField("Session name", text: $coordinator.sessionName, prompt: Text("Optional"))
                        .accessibilityIdentifier("capture.sessionName")
                    LabeledContent("Project folder") {
                        HStack(spacing: 8) {
                            TextField("~/Developer/billing-portal", text: $coordinator.projectDirectory)
                                .labelsHidden()
                            Button("Choose…") { coordinator.chooseDirectory() }
                        }
                    }
                    TextField("Project note", text: $coordinator.note, axis: .vertical)
                        .lineLimit(3...5)
                }.formStyle(.columns)
                Text("The project folder is used when opening a terminal or editor.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                DisclosureGroup("Session source") {
                    Picker("Source", selection: $coordinator.originOverride) {
                        Text("Unknown / not specified").tag(nil as SessionOrigin?)
                        ForEach(SessionOrigin.allCases.filter { $0 != .unknown }) { Text($0.title).tag(Optional($0)) }
                    }.padding(.top, 8)
                }.font(.system(size: 12))
                Spacer(minLength: 0)
            }.padding(20)
        }
    }

    private var reviewActions: some View {
        HStack {
            Button("Choose another…") { coordinator.chooseImage() }
            Spacer()
            Button("Save to Library") { coordinator.save() }
                .buttonStyle(.borderedProminent).tint(.repriseGreen)
                .disabled(!coordinator.canSave).keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.repriseGreen)
                .frame(width: 6, height: 6)
            Text("Stored only on this Mac")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Library", action: openLibrary).buttonStyle(RepriseQuietButtonStyle())
            Menu {
                Button("Open Library", action: openLibrary)
                TerminalPreferencePicker()
                EditorPreferenceMenu()
                Divider()
                CheckForUpdatesButton()
                Divider()
                Button("Quit Reprise", action: quit)
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Reprise options")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }
}

private struct DropTargetCard: View {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Bool
    let chooseImage: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "photo.badge.arrow.down")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.repriseGreen)
                .frame(width: 46, height: 46)
                .background(.background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(spacing: 3) {
                Text(isTargeted ? "Drop to read screenshot" : "Drop a terminal screenshot")
                    .font(.system(size: 13, weight: .semibold))
                Text("Reprise detects Codex, Claude, and Grok commands.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button("Choose Screenshot…", action: chooseImage)
                .buttonStyle(.bordered)
                .controlSize(.small)


        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .background(
            (isTargeted ? Color.repriseGreen.opacity(0.12) : Color.repriseCanvas),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    Color.repriseGreen.opacity(isTargeted ? 0.65 : 0.28),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

private struct ScreenshotPreview: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.repriseTerminal)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(0.08))
        }
    }
}

private struct CompactSessionRow: View {
    let session: ResumeSession

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: session.model.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(session.model.tint)
                .frame(width: 24, height: 24)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(session.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(RepriseQuietButtonStyle(tint: .primary))
            .accessibilityLabel("Copy resume command")
            .help("Copy resume command")
        }
    }
}
