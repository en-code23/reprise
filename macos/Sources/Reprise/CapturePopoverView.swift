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

            Divider()
            footer
        }
        .frame(width: 420, height: 520)
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
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if coordinator.phase != .idle {
                Button {
                    coordinator.reset()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Cancel capture")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var headerSubtitle: String {
        switch coordinator.phase {
        case .idle: "Resume your AI coding sessions"
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

            if let error = coordinator.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }

            if !store.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("RECENT")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Open library", action: openLibrary)
                            .buttonStyle(.link)
                            .font(.system(size: 10, weight: .semibold))
                    }

                    ForEach(store.sessions.prefix(3)) { session in
                        CompactSessionRow(session: session)
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
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(16)
    }

    private var reviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Image(systemName: coordinator.detectedAutomatically ? "checkmark.circle.fill" : "pencil.circle.fill")
                    Text(coordinator.detectedAutomatically ? "Resume command detected" : "Check the details manually")
                    Spacer()
                    if coordinator.detectedAutomatically {
                        Text("AUTO")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.6), in: Capsule())
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(coordinator.detectedAutomatically ? Color.repriseGreen : Color.orange)
                .padding(10)
                .background(
                    (coordinator.detectedAutomatically ? Color.repriseGreen : Color.orange)
                        .opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

                if let error = coordinator.errorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 12) {
                    ScreenshotPreview(image: coordinator.previewImage)
                        .frame(width: 128, height: 96)

                    VStack(spacing: 10) {
                        LabeledContent("Assistant") {
                            Picker("Assistant", selection: $coordinator.model) {
                                ForEach(AssistantModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 132)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("RESUME COMMAND")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 7) {
                                Text("$")
                                    .foregroundStyle(Color.repriseGreen)
                                TextField(
                                    "\(coordinator.model.commandName) --resume \"session-id\"",
                                    text: $coordinator.command
                                )
                                .textFieldStyle(.plain)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.repriseBone)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(Color.repriseTerminal, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }

                FieldLabel("PROJECT NAME") {
                    TextField("Billing portal", text: $coordinator.project)
                }

                FieldLabel("PROJECT NOTE · OPTIONAL") {
                    TextEditor(text: $coordinator.note)
                        .font(.system(size: 11))
                        .frame(height: 54)
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }

                HStack {
                    Button("Choose another…") {
                        coordinator.chooseImage()
                    }
                    Spacer()
                    Button("Save to Library") {
                        coordinator.save()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.repriseGreen)
                    .disabled(!coordinator.canSave)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.repriseGreen)
                .frame(width: 6, height: 6)
            Text("Stored only on this Mac")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Open Library", action: openLibrary)
                Divider()
                Button("Quit Reprise", action: quit)
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
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
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Button("Choose Screenshot…", action: chooseImage)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Text("PNG · JPG · HEIC · WEBP · TIFF")
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.45)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 235)
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(session.model.tint)
                .frame(width: 24, height: 24)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Text(session.command)
                    .font(.system(size: 8, design: .monospaced))
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
            .buttonStyle(.borderless)
            .help("Copy resume command")
        }
    }
}

private struct FieldLabel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content
        }
    }
}
