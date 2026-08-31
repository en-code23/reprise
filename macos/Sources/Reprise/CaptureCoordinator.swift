import AppKit
import Foundation
import UniformTypeIdentifiers

enum CapturePhase: Equatable {
    case idle
    case reading
    case review
}

@MainActor
final class CaptureCoordinator: ObservableObject {
    @Published var phase: CapturePhase = .idle
    @Published var previewImage: NSImage?
    @Published var model: AssistantModel = .codex
    @Published var command = ""
    @Published var project = ""
    @Published var projectDirectory = ""
    @Published var note = ""
    @Published var detectedAutomatically = false
    @Published var errorMessage: String?
    @Published var isDropTargeted = false

    private weak var store: SessionStore?
    private var sourceURL: URL?

    init(store: SessionStore) {
        self.store = store
    }

    var canSave: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a terminal screenshot"
        panel.prompt = "Read Screenshot"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .tiff]

        if panel.runModal() == .OK, let url = panel.url {
            receive(url: url)
        }
    }

    func receive(url: URL) {
        guard isSupportedImage(url) else {
            errorMessage = "Drop a PNG, JPG, HEIC, WebP, or TIFF screenshot."
            phase = .idle
            return
        }

        reset(keepingPhase: true)
        sourceURL = url
        previewImage = NSImage(contentsOf: url)
        project = suggestedProjectName(from: url)
        phase = .reading

        Task {
            do {
                let text = try await OCRService.recognizeText(from: url)
                let parsed = CommandParser.parse(text)
                model = parsed.model
                command = parsed.command
                projectDirectory = parsed.projectDirectory ?? ""
                detectedAutomatically = parsed.wasDetected
                if !parsed.wasDetected {
                    errorMessage = "The resume command needs a quick manual check."
                }
                phase = .review
            } catch {
                errorMessage = error.localizedDescription
                phase = .review
            }
        }
    }

    func save() {
        guard canSave else {
            errorMessage = "Add the resume command before saving."
            return
        }

        let session = ResumeSession(
            model: model,
            project: project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled project"
                : project.trimmingCharacters(in: .whitespacesAndNewlines),
            projectDirectory: normalizedDirectory,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceFileName: sourceURL?.lastPathComponent,
            detectedAutomatically: detectedAutomatically
        )
        store?.add(session)
        reset()
    }

    func reset(keepingPhase: Bool = false) {
        if !keepingPhase { phase = .idle }
        previewImage = nil
        model = .codex
        command = ""
        project = ""
        projectDirectory = ""
        note = ""
        detectedAutomatically = false
        errorMessage = nil
        sourceURL = nil
        isDropTargeted = false
    }

    func isSupportedImage(_ url: URL) -> Bool {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private func suggestedProjectName(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(
            of: #"(?i)^screenshot[\s_-]*(\d{4}[-_.]\d{2}[-_.]\d{2})?[\s_-]*"#,
            with: "",
            options: .regularExpression
        )
        return name.isEmpty ? "Untitled project" : name
    }

    private var normalizedDirectory: String? {
        let value = projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
