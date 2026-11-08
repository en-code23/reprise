import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?

    private init() {}

    // Start only after single-instance coordination, never in test/previews.
    func start() {
        guard controller == nil, Bundle.main.bundleIdentifier == "app.reprise.macos",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button(action: updater.checkForUpdates) {
            Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!updater.canCheckForUpdates)
        .help("Download and install the latest Reprise update")
    }
}
