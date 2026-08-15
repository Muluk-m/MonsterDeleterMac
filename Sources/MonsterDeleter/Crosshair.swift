import AppKit

/// The red targeting reticle from the original Qt build: 56pt box, radius 17,
/// 2pt stroke, with a 6pt gap where the cross meets the centre.
enum Crosshair {
    static let cursor: NSCursor = {
        let side: CGFloat = 56
        let center = side / 2
        let radius: CGFloat = 17
        let gap: CGFloat = 6
        let lineWidth: CGFloat = 2

        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.red.setStroke()

            let ring = NSBezierPath(
                ovalIn: NSRect(
                    x: center - radius,
                    y: center - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            ring.lineWidth = lineWidth
            ring.stroke()

            let cross = NSBezierPath()
            cross.lineWidth = lineWidth
            cross.move(to: NSPoint(x: center, y: center + gap))
            cross.line(to: NSPoint(x: center, y: side - 1))
            cross.move(to: NSPoint(x: center, y: center - gap))
            cross.line(to: NSPoint(x: center, y: 1))
            cross.move(to: NSPoint(x: center + gap, y: center))
            cross.line(to: NSPoint(x: side - 1, y: center))
            cross.move(to: NSPoint(x: center - gap, y: center))
            cross.line(to: NSPoint(x: 1, y: center))
            cross.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: center, y: center))
    }()
}
