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
    private static let bundleID = "app.reprise.macos"
    private static let showLibraryNotification = Notification.Name("app.reprise.macos.showLibrary")
    private var instanceLock: SingleInstanceLock?
    private var store: SessionStore?
    private var coordinator: CaptureCoordinator?
    private var statusBarController: StatusBarController?
    private var libraryWindowController: LibraryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard becomePrimaryInstance() else { return }

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

    @objc private func showExistingLibrary(_ notification: Notification) {
        libraryWindowController?.show()
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
