import AppKit
import ClewCore
import SwiftUI

/// The priority gold (SPEC 2026-11-19): kin-iro (金色), flat like the other marks. Light
/// mode is a little deeper (3.1:1 on white; pure kin-iro #C99A12 is 2.6:1), dark mode is
/// kin-iro itself.
enum PriorityGold {
    static func ns(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0xE6 / 255.0, green: 0xB4 / 255.0, blue: 0x22 / 255.0, alpha: 1)
             : NSColor(srgbRed: 0xB8 / 255.0, green: 0x8A / 255.0, blue: 0x0E / 255.0, alpha: 1)
    }
    static let nsColor = NSColor(name: "PriorityGold") { appearance in
        ns(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
    static let color = Color(nsColor: nsColor)
}

/// The menu bar ring (SPEC 2026-11-18), drawn as a template image: the system tints
/// it for the menu bar (light, dark, highlighted), as it does the SF Symbols. With gold
/// parts (done priorities, SPEC 2026-11-19) it is coloured instead, and the rest is
/// drawn in the menu bar's own text colour, read when it is drawn.
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
        let coloured = ring.hasGold
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: size / 16, y: size / 16)
            // Not a template: nothing tints it, so it follows the appearance it is drawn
            // in (the menu bar's), which a drawing handler sees each time it draws.
            let appearance = NSAppearance.currentDrawing()
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // The colour the system tints a template with, so a gold ring matches the rest.
            var ink = NSColor.black
            if coloured {
                appearance.performAsCurrentDrawingAppearance {
                    ink = NSColor.labelColor.usingColorSpace(.sRGB) ?? (dark ? .white : .black)
                }
            }
            draw(ring, in: NSRect(x: 0, y: 0, width: 16, height: 16), ink: ink, gold: PriorityGold.ns(dark: dark))
            return true
        }
        image.isTemplate = !coloured
        cache[key] = image
        return image
    }

    private static func draw(_ ring: MenuBarRing, in rect: NSRect, ink: NSColor, gold: NSColor) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let line: CGFloat = 2.2
        let radius = (min(rect.width, rect.height) - line) / 2 - 0.5
        // Clockwise from 12 o'clock (AppKit angles run anticlockwise from 3 o'clock).
        func arc(from start: Double, to end: Double, _ color: NSColor) {
            guard end > start else { return }
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: radius,
                           startAngle: 90 - start * 360, endAngle: 90 - end * 360, clockwise: true)
            path.lineWidth = line
            path.lineCapStyle = .butt
            color.setStroke()
            path.stroke()
        }
        // 0.4: at 0.3 the parts left were too faint to count (review: 1.85:1).
        let left = ink.withAlphaComponent(ink.alphaComponent * 0.4)
        switch ring {
        case .parts(let done, let total, let golds):
            if total == 1 {
                arc(from: 0, to: 1, left)
                return
            }
            // A gap of about 1.6 pt between parts.
            let gap = 1.6 / (2 * .pi * radius)
            for i in 0..<total {
                let start = Double(i) / Double(total) + gap / 2
                let end = Double(i + 1) / Double(total) - gap / 2
                // Done priorities first (they are Today's first rows), then the others.
                arc(from: start, to: end, i < golds ? gold : i < done ? ink : left)
            }
        case .share(let share, let golds):
            // Each stretch drawn once: ink over the faint ring would darken it (review).
            arc(from: share, to: 1, left)
            arc(from: golds, to: share, ink)
            arc(from: 0, to: golds, gold)
        case .finished:
            // A filled circle with the ✓ cut out of it.
            let disc = NSBezierPath(ovalIn: NSRect(x: center.x - radius - line / 2, y: center.y - radius - line / 2,
                                                   width: 2 * radius + line, height: 2 * radius + line))
            ink.setFill()
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
