import AppKit

@main
struct RepriseApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = makeMainMenu()
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor private static func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        func addMenu(_ title: String, items: [(String, String, String)]) -> NSMenu {
            let submenu = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
            for (title, action, key) in items {
                if title.isEmpty { submenu.addItem(.separator()) }
                else { submenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key) }
            }
            return submenu
        }
        _ = addMenu("Reprise", items: [
            ("About Reprise", "orderFrontStandardAboutPanel:", ""),
            ("", "", ""),
            ("Settings…", "showPreferences:", ","),
            ("", "", ""),
            ("Hide Reprise", "hide:", "h"),
            ("Show All", "unhideAllApplications:", ""),
            ("", "", ""),
            ("Quit Reprise", "terminate:", "q")
        ])
        _ = addMenu("File", items: [("Close Window", "performClose:", "w")])
        let edit = addMenu("Edit", items: [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "z"),
            ("", "", ""),
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ])
        edit.items.first { $0.action == NSSelectorFromString("redo:") }?.keyEquivalentModifierMask = [.command, .shift]
        NSApp.windowsMenu = addMenu("Window", items: [
            ("Minimize", "performMiniaturize:", "m"), ("Zoom", "performZoom:", ""),
            ("", "", ""), ("Bring All to Front", "arrangeInFront:", "")
        ])
        return menu
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let bundleID = "app.reprise.macos"
    private static let showLibraryNotification = Notification.Name("app.reprise.macos.showLibrary")
    private var instanceLock: SingleInstanceLock?
    private var store: SessionStore?
    private var coordinator: CaptureCoordinator?
    private var statusBarController: StatusBarController?
    private var libraryWindowController: LibraryWindowController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard becomePrimaryInstance() else { return }
        NSApp.setActivationPolicy(.regular)

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
        self.settingsWindowController = SettingsWindowController(store: store)
        self.statusBarController = statusBar
        AppUpdater.shared.start()
        store.startDiscovery()
        library.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flush()
        store?.stopDiscovery()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        libraryWindowController?.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showExistingLibrary(_ notification: Notification) {
        libraryWindowController?.show()
    }

    @objc func showPreferences(_ sender: Any?) {
        settingsWindowController?.show()
    }

    private func becomePrimaryInstance() -> Bool {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Reprise", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let lock = try SingleInstanceLock(at: directory.appendingPathComponent("instance.lock")) else {
                forwardToExistingInstance()
                NSApp.terminate(nil)
                return false
            }

            // Older releases have no lock. Hand off to them instead of adding a
            // second menu item. New releases coordinate exclusively via flock,
            // so two simultaneous launches cannot both decide to quit.
            let legacy = otherInstances.first { application in
                guard application.isFinishedLaunching, let url = application.bundleURL else { return false }
                return Bundle(url: url)?.object(forInfoDictionaryKey: "RepriseSingleInstanceProtocol") == nil
            }
            if let legacy {
                forwardToExistingInstance(legacy)
                NSApp.terminate(nil)
                return false
            }

            instanceLock = lock
            DistributedNotificationCenter.default().addObserver(self,
                selector: #selector(showExistingLibrary(_:)),
                name: Self.showLibraryNotification, object: Self.bundleID,
                suspensionBehavior: .deliverImmediately)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Reprise couldn’t start"
            alert.informativeText = "The app couldn’t reserve its running instance. \(error.localizedDescription)"
            alert.runModal()
            NSApp.terminate(nil)
            return false
        }
    }

    private var otherInstances: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            .sorted { $0.processIdentifier < $1.processIdentifier }
    }

    private func forwardToExistingInstance(_ application: NSRunningApplication? = nil) {
        DistributedNotificationCenter.default().postNotificationName(Self.showLibraryNotification,
            object: Self.bundleID, userInfo: nil, deliverImmediately: true)
        (application ?? otherInstances.first)?.activate(options: [])
    }
}
