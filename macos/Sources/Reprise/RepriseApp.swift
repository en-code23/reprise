import AppKit
import SwiftUI

@main
struct RepriseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SessionStore?
    private var coordinator: CaptureCoordinator?
    private var statusBarController: StatusBarController?
    private var libraryWindowController: LibraryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let store = SessionStore()
        let coordinator = CaptureCoordinator(store: store)
        let library = LibraryWindowController(store: store)
        let statusBar = StatusBarController(
            coordinator: coordinator,
            store: store,
            onOpenLibrary: { [weak library] in library?.show() }
        )

        library.onNewCapture = { [weak statusBar] in
            statusBar?.openCapture()
        }

        self.store = store
        self.coordinator = coordinator
        self.libraryWindowController = library
        self.statusBarController = statusBar
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flush()
    }
}
