import AppKit

/// A deliberately simplified version of the app mark for the 18pt menu bar.
@MainActor
enum StatusBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let mark = NSBezierPath()
            mark.lineWidth = 2.4
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.move(to: NSPoint(x: 4, y: 14))
            mark.line(to: NSPoint(x: 9, y: 9))
            mark.line(to: NSPoint(x: 4, y: 4))
            mark.curve(to: NSPoint(x: 6, y: 2.5), controlPoint1: NSPoint(x: 2.5, y: 2.5), controlPoint2: NSPoint(x: 4.5, y: 2.5))
            mark.line(to: NSPoint(x: 11.5, y: 2.5))
            mark.curve(to: NSPoint(x: 14, y: 5), controlPoint1: NSPoint(x: 13.3, y: 2.5), controlPoint2: NSPoint(x: 14, y: 3.2))
            mark.line(to: NSPoint(x: 14, y: 8))
            mark.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 12.5, y: 9.5, width: 3, height: 3), xRadius: 0.8, yRadius: 0.8).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Reprise — resume your work"
        return image
    }
}
