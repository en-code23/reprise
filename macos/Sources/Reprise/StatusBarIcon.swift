import AppKit

/// Stacked session cards with a play cutout, simplified for the 18pt menu bar.
@MainActor
enum StatusBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let back = NSBezierPath()
            back.lineWidth = 1.5
            back.lineCapStyle = .round
            back.lineJoinStyle = .round
            back.move(to: NSPoint(x: 2.5, y: 6))
            back.line(to: NSPoint(x: 2.5, y: 12))
            back.curve(to: NSPoint(x: 4.5, y: 14), controlPoint1: NSPoint(x: 2.5, y: 13.1), controlPoint2: NSPoint(x: 3.4, y: 14))
            back.line(to: NSPoint(x: 12, y: 14))
            back.stroke()

            NSColor.black.setFill()
            let front = NSBezierPath(roundedRect: NSRect(x: 5, y: 3, width: 11.5, height: 9), xRadius: 2, yRadius: 2)
            front.windingRule = .evenOdd
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 9, y: 5.25))
            play.line(to: NSPoint(x: 13, y: 7.5))
            play.line(to: NSPoint(x: 9, y: 9.75))
            play.close()
            front.append(play)
            front.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Reprise — resume your work"
        return image
    }
}
