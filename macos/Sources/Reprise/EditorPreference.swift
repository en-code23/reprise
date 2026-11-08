import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CodeEditor: Codable, Equatable, Identifiable, Sendable {
    let bundleID: String
    let name: String
    var path: String?
    var id: String { bundleID }

    static let known: [CodeEditor] = [
        .init(bundleID: "com.microsoft.VSCode", name: "VS Code"),
        .init(bundleID: "com.microsoft.VSCodeInsiders", name: "VS Code Insiders"),
        .init(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        .init(bundleID: "com.exafunction.windsurf", name: "Windsurf"),
        .init(bundleID: "com.google.antigravity", name: "Antigravity"),
        .init(bundleID: "dev.zed.Zed", name: "Zed"),
        .init(bundleID: "com.sublimetext.4", name: "Sublime Text"),
        .init(bundleID: "com.panic.Nova", name: "Nova"),
        .init(bundleID: "com.barebones.bbedit", name: "BBEdit"),
        .init(bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA")
    ]

    @MainActor var applicationURL: URL? {
        if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let executable = Bundle(url: installed)?.executableURL,
           FileManager.default.isExecutableFile(atPath: executable.path) { return installed }
        guard let path, let bundle = Bundle(url: URL(fileURLWithPath: path)),
              bundle.bundleIdentifier == bundleID, let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return bundle.bundleURL
    }

    static func application(at url: URL) throws -> CodeEditor {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let bundleID = bundle.bundleIdentifier, let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw EditorLaunchError.invalidApplication
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return CodeEditor(bundleID: bundleID, name: name, path: url.path)
    }
}

@MainActor
final class EditorPreference: ObservableObject {
    static let shared = EditorPreference()
    static let key = "preferredCodeEditor"
    @Published private(set) var selected: CodeEditor?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, initialEditor: CodeEditor? = nil) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(CodeEditor.self, from: data) {
            selected = saved
        } else {
            selected = initialEditor ?? CodeEditor.known.first { $0.applicationURL != nil }
        }
    }

    var installedEditors: [CodeEditor] {
        var editors = CodeEditor.known.filter { $0.applicationURL != nil }
        if let selected, !editors.contains(where: { $0.id == selected.id }) { editors.insert(selected, at: 0) }
        return editors
    }

    func select(_ editor: CodeEditor) {
        guard let data = try? JSONEncoder().encode(editor) else { return }
        defaults.set(data, forKey: Self.key)
        selected = editor
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose your code editor"
        panel.prompt = "Use Editor"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { select(try CodeEditor.application(at: url)) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Choose an application"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

struct EditorPreferenceMenu: View {
    @ObservedObject var preference: EditorPreference = .shared

    var body: some View {
        Menu {
            ForEach(preference.installedEditors) { editor in
                Button {
                    preference.select(editor)
                } label: {
                    if preference.selected?.id == editor.id { Label(editor.name, systemImage: "checkmark") }
                    else { Text(editor.name) }
                }
            }
            Divider()
            Button("Choose another editor…") { preference.chooseApplication() }
        } label: {
            Text(preference.selected?.name ?? "Choose editor…")
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Default code editor")
    }
}
