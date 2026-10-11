import AppKit

/// Menu bar glyph: a closed eye while the Mac may sleep, an open one while Insomnia keeps it up.
enum StatusIcon {
    static func image(open: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let lid = NSBezierPath()
            lid.lineWidth = 1.5
            lid.lineCapStyle = .round
            lid.lineJoinStyle = .round
            if open {
                lid.move(to: NSPoint(x: 1.75, y: 9))
                lid.curve(to: NSPoint(x: 16.25, y: 9), controlPoint1: NSPoint(x: 5, y: 14.6), controlPoint2: NSPoint(x: 13, y: 14.6))
                lid.curve(to: NSPoint(x: 1.75, y: 9), controlPoint1: NSPoint(x: 13, y: 3.4), controlPoint2: NSPoint(x: 5, y: 3.4))
                lid.close()
                lid.stroke()
                NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 6, height: 6)).fill()
            } else {
                lid.move(to: NSPoint(x: 1.75, y: 12))
                lid.curve(to: NSPoint(x: 16.25, y: 12), controlPoint1: NSPoint(x: 5, y: 7.5), controlPoint2: NSPoint(x: 13, y: 7.5))
                for (from, to) in [((4.2, 9.84), (3.1, 7.8)), ((9, 8.63), (9, 6.3)), ((13.8, 9.84), (14.9, 7.8))] {
                    lid.move(to: NSPoint(x: from.0, y: from.1))
                    lid.line(to: NSPoint(x: to.0, y: to.1))
                }
                lid.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Insomnia"
        return image
    }
}
