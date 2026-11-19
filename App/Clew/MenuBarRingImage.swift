import AppKit
import ClewCore

/// The menu bar ring (SPEC 2026-11-18), drawn as a template image: the system tints
/// it for the menu bar (light, dark, highlighted), as it does the SF Symbols.
@MainActor
enum MenuBarRingImage {
    /// In the menu bar: 18 pt (user, 2026-11-18: 16 looked small in a notch Mac's
    /// 33 pt bar). Drawn on a 16 pt grid and scaled, so the parts keep their shape.
    static let menuBarSize: CGFloat = 18
    private struct Key: Hashable { let ring: MenuBarRing; let size: CGFloat }
    private static var cache: [Key: NSImage] = [:]

    /// `size` 16 for a preview inside text (Settings).
    static func image(_ ring: MenuBarRing, size: CGFloat = menuBarSize) -> NSImage {
        let key = Key(ring: ring, size: size)
        if let image = cache[key] { return image }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: size / 16, y: size / 16)
            draw(ring, in: NSRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    private static func draw(_ ring: MenuBarRing, in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let line: CGFloat = 2.2
        let radius = (min(rect.width, rect.height) - line) / 2 - 0.5
        // Clockwise from 12 o'clock (AppKit angles run anticlockwise from 3 o'clock).
        func arc(from start: Double, to end: Double, alpha: CGFloat) {
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: radius,
                           startAngle: 90 - start * 360, endAngle: 90 - end * 360, clockwise: true)
            path.lineWidth = line
            path.lineCapStyle = .butt
            NSColor.black.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
        // 0.4: at 0.3 the parts left were too faint to count (review: 1.85:1).
        let left: CGFloat = 0.4
        switch ring {
        case .parts(let done, let total):
            if total == 1 {
                arc(from: 0, to: 1, alpha: left)
                return
            }
            // A gap of about 1.6 pt between parts.
            let gap = 1.6 / (2 * .pi * radius)
            for i in 0..<total {
                let start = Double(i) / Double(total) + gap / 2
                let end = Double(i + 1) / Double(total) - gap / 2
                arc(from: start, to: end, alpha: i < done ? 1 : left)
            }
        case .share(let share):
            arc(from: 0, to: 1, alpha: left)
            if share > 0 { arc(from: 0, to: share, alpha: 1) }
        case .finished:
            // A filled circle with the ✓ cut out of it.
            let disc = NSBezierPath(ovalIn: NSRect(x: center.x - radius - line / 2, y: center.y - radius - line / 2,
                                                   width: 2 * radius + line, height: 2 * radius + line))
            NSColor.black.setFill()
            disc.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: center.x - 3.4, y: center.y + 0.1))
            check.line(to: NSPoint(x: center.x - 1.0, y: center.y - 2.4))
            check.line(to: NSPoint(x: center.x + 3.6, y: center.y + 2.6))
            check.lineWidth = 1.7
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            check.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
    }
}
