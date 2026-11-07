import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let coordinator: CaptureCoordinator
    private let onOpenLibrary: () -> Void
    private weak var dropOverlay: StatusDropView?

    init(
        coordinator: CaptureCoordinator,
        store: SessionStore,
        onOpenLibrary: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.onOpenLibrary = onOpenLibrary
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 480, height: 620)
        popover.contentViewController = NSHostingController(
            rootView: CapturePopoverView(
                coordinator: coordinator,
                store: store,
                openLibrary: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.onOpenLibrary()
                },
                quit: { NSApp.terminate(nil) }
            )
        )

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Reprise")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Reprise — drop a terminal screenshot"

            let overlay = StatusDropView(frame: button.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.owner = self
            button.addSubview(overlay, positioned: .above, relativeTo: nil)
            dropOverlay = overlay
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func openCapture() {
        coordinator.reset()
        showPopover()
    }

    func acceptDroppedImage(_ url: URL) {
        setDropHighlighted(false)
        coordinator.receive(url: url)
        showPopover()
    }

    func canAccept(_ url: URL) -> Bool {
        coordinator.isSupportedImage(url)
    }

    func setDropHighlighted(_ highlighted: Bool) {
        dropOverlay?.isHighlighted = highlighted
        statusItem.button?.contentTintColor = highlighted
            ? NSColor.systemGreen
            : NSColor.labelColor
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

@MainActor
final class StatusDropView: NSView {
    weak var owner: StatusBarController?

    var isHighlighted = false {
        didSet {
            wantsLayer = true
            layer?.cornerRadius = 5
            layer?.backgroundColor = isHighlighted
                ? NSColor.systemGreen.withAlphaComponent(0.18).cgColor
                : NSColor.clear.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        toolTip = "Drop a terminal screenshot"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        owner?.togglePopover()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url = imageURL(from: sender), owner?.canAccept(url) == true else { return [] }
        owner?.setDropHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        owner?.setDropHighlighted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = imageURL(from: sender), owner?.canAccept(url) == true else {
            owner?.setDropHighlighted(false)
            return false
        }
        owner?.acceptDroppedImage(url)
        return true
    }

    private func imageURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL])?.first
    }
}
