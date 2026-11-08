import AppKit
import SwiftUI
import XCTest
@testable import Reprise

@MainActor
final class HitAreaTests: XCTestCase {
    func testRowPaddingAndSpacerTriggerTheAction() {
        var presses = 0
        let button = Button { presses += 1 } label: {
            HStack {
                Text("Project name")
                Spacer()
            }.padding(16).frame(width: 300, height: 80)
        }.buttonStyle(RepriseRowButtonStyle())

        withWindow(button, size: NSSize(width: 300, height: 80)) { window in
            for (index, point) in [NSPoint(x: 5, y: 5), NSPoint(x: 295, y: 75), NSPoint(x: 250, y: 40)].enumerated() {
                click(point, in: window)
                XCTAssertEqual(presses, index + 1, "Blank row padding and Spacer must be clickable")
            }
        }
    }

    func testIconPaddingTriggersActionWithoutExtendingOutsideControl() {
        var presses = 0
        let button = Button { presses += 1 } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(RepriseQuietButtonStyle())
            .frame(width: 80, height: 80)
        withWindow(button, size: NSSize(width: 80, height: 80)) { window in
            click(NSPoint(x: 22, y: 22), in: window)
            XCTAssertEqual(presses, 1, "Padding around the small icon must be clickable")
            click(NSPoint(x: 5, y: 5), in: window)
            XCTAssertEqual(presses, 1, "The target must stop at the control's bounds")
        }
    }

    func testDisabledActionDoesNotRespondToPaddingClicks() {
        var presses = 0
        let button = Button { presses += 1 } label: { Text("Copy") }
            .buttonStyle(RepriseQuietButtonStyle())
            .disabled(true)
            .frame(width: 100, height: 80)
        withWindow(button, size: NSSize(width: 100, height: 80)) { window in
            click(NSPoint(x: 32, y: 22), in: window)
            XCTAssertEqual(presses, 0)
        }
    }

    private func withWindow<Content: View>(_ content: Content, size: NSSize, body: (NSWindow) -> Void) {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        settle()
        body(window)
        window.orderOut(nil)
    }

    private func click(_ point: NSPoint, in window: NSWindow) {
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: down.timestamp + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        settle()
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
