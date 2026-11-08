import AppKit

enum EditorLaunchError: LocalizedError {
    case missingDirectory, invalidDirectory, noEditor, notInstalled(String), invalidApplication

    var errorDescription: String? {
        switch self {
        case .missingDirectory: "Choose a project folder before opening it in an editor."
        case .invalidDirectory: "The project folder no longer exists. Choose its new location."
        case .noEditor: "Choose a code editor under Default editor in the sidebar."
        case .notInstalled(let name): "\(name) could not be found. Choose its application again or select another editor."
        case .invalidApplication: "Select an installed editor application (.app), such as Visual Studio Code."
        }
    }
}

struct EditorOpenRequest: Equatable {
    let directory: URL
    let application: URL
    let resumeCommand: String

    init(session: ResumeSession, application: URL) throws {
        guard let directory = session.projectDirectory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EditorLaunchError.missingDirectory
        }
        let path = (directory as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EditorLaunchError.invalidDirectory
        }
        self.directory = URL(fileURLWithPath: path, isDirectory: true)
        self.application = application
        resumeCommand = CommandParser.canonicalize(session.command)
    }
}

@MainActor
enum EditorLauncher {
    static func open(_ session: ResumeSession, editor: CodeEditor?,
        openApplication: ((EditorOpenRequest) async throws -> Void)? = nil,
        copyCommand: ((String) -> Void)? = nil) async throws {
        guard let editor else { throw EditorLaunchError.noEditor }
        guard let application = editor.applicationURL else { throw EditorLaunchError.notInstalled(editor.name) }
        let request = try EditorOpenRequest(session: session, application: application)
        if let openApplication { try await openApplication(request) }
        else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([request.directory], withApplicationAt: request.application, configuration: configuration)
        }
        // Copy only after the editor successfully opens. No clipboard changes on error.
        if let copyCommand { copyCommand(request.resumeCommand) }
        else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(request.resumeCommand, forType: .string)
        }
    }
}
