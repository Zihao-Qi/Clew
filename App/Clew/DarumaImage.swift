import AppKit

/// The menu bar Daruma (SPEC 2026-11-18): five faces for how the day is going, drawn
/// as a template image so the system tints it like the other menu bar icons. The
/// design is Gemini Neon's, rounded by the user (a narrower base, a fuller middle, a
/// face narrower at the top, belly stripes leaning in).
@MainActor
enum DarumaImage {
    /// In the menu bar: 20 pt (user, 2026-11-18: 16 looked small; 22 is the most the
    /// bar holds). Drawn on a 16 pt grid and scaled, so the face keeps its spacing.
    static let menuBarSize: CGFloat = 20
    private struct Key: Hashable { let stage: Int; let size: CGFloat }
    private static var cache: [Key: NSImage] = [:]

    /// Stage 1…5 (`DarumaStage.of`); `size` 16 for a preview inside text (Settings).
    static func image(stage: Int, size: CGFloat = menuBarSize) -> NSImage {
        let key = Key(stage: stage, size: size)
        if let image = cache[key] { return image }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: size / 16, y: size / 16)
            draw(stage: stage)
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    private static func draw(stage: Int) {
        let clampedStage = min(max(stage, 1), 5)

        NSGraphicsContext.current!.compositingOperation = .sourceOver
        NSColor.black.setFill()
        darumaBodyPath().fill()

        NSGraphicsContext.current!.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSColor.black.setStroke()
        darumaFaceWindowPath().fill()
        for stripe in darumaBellyStripePaths() {
            stripe.stroke()
        }

        NSGraphicsContext.current!.compositingOperation = .sourceOver
        NSColor.black.setFill()
        NSColor.black.setStroke()

        darumaBrowPath(stage: clampedStage, mirrored: false).stroke()
        darumaBrowPath(stage: clampedStage, mirrored: true).stroke()

        drawDarumaEye(center: NSPoint(x: 5.50, y: 6.55), painted: clampedStage == 5)
        drawDarumaEye(center: NSPoint(x: 10.50, y: 6.55), painted: clampedStage >= 2)

        drawDarumaMouth(stage: clampedStage)
    }

    private static func darumaBodyPath() -> NSBezierPath {
        // Neon's body, rounder below (user): the sides curve in to a narrower base.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8.0, y: 0.30))
        path.curve(to: NSPoint(x: 15.80, y: 8.40),
                   controlPoint1: NSPoint(x: 13.00, y: 0.30), controlPoint2: NSPoint(x: 15.85, y: 4.20))
        path.curve(to: NSPoint(x: 9.90, y: 15.60),
                   controlPoint1: NSPoint(x: 15.80, y: 12.30), controlPoint2: NSPoint(x: 13.10, y: 15.50))
        path.curve(to: NSPoint(x: 6.10, y: 15.60),
                   controlPoint1: NSPoint(x: 8.90, y: 15.72), controlPoint2: NSPoint(x: 7.10, y: 15.72))
        path.curve(to: NSPoint(x: 0.20, y: 8.40),
                   controlPoint1: NSPoint(x: 2.90, y: 15.50), controlPoint2: NSPoint(x: 0.20, y: 12.30))
        path.curve(to: NSPoint(x: 8.0, y: 0.30),
                   controlPoint1: NSPoint(x: 0.15, y: 4.20), controlPoint2: NSPoint(x: 3.00, y: 0.30))
        path.close()
        return path
    }

    private static func darumaFaceWindowPath() -> NSBezierPath {
        // Neon's window, narrower toward the top (user): the upper corners pulled in.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8.0, y: 1.85))
        path.curve(to: NSPoint(x: 14.15, y: 7.05),
                   controlPoint1: NSPoint(x: 11.90, y: 1.85), controlPoint2: NSPoint(x: 13.95, y: 3.30))
        path.curve(to: NSPoint(x: 8.0, y: 11.75),
                   controlPoint1: NSPoint(x: 14.15, y: 10.30), controlPoint2: NSPoint(x: 12.20, y: 11.75))
        path.curve(to: NSPoint(x: 1.85, y: 7.05),
                   controlPoint1: NSPoint(x: 3.80, y: 11.75), controlPoint2: NSPoint(x: 1.85, y: 10.30))
        path.curve(to: NSPoint(x: 8.0, y: 1.85),
                   controlPoint1: NSPoint(x: 2.05, y: 3.30), controlPoint2: NSPoint(x: 4.10, y: 1.85))
        path.close()
        return path
    }

    private static func darumaBellyStripePaths() -> [NSBezierPath] {
        let segments: [(NSPoint, NSPoint)] = [
            // Upside down (user): the outer stripes lean in toward the base.
            (NSPoint(x: 5.15, y: 12.90), NSPoint(x: 5.50, y: 14.30)),
            (NSPoint(x: 8.00, y: 12.75), NSPoint(x: 8.00, y: 14.15)),
            (NSPoint(x: 10.85, y: 12.90), NSPoint(x: 10.50, y: 14.30)),
        ]
        return segments.map { start, end in
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = 0.76
            path.lineCapStyle = .round
            return path
        }
    }

    private static func darumaBrowPath(stage: Int, mirrored: Bool) -> NSBezierPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: mirrored ? 16.0 - x : x, y: y)
        }

        let path = NSBezierPath()
        path.lineWidth = 1.08
        path.lineCapStyle = .round

        switch stage {
        case 1:
            path.move(to: point(4.65, 3.72))
            path.curve(
                to: point(6.80, 4.30),
                controlPoint1: point(5.48, 3.68),
                controlPoint2: point(6.15, 3.92)
            )
        case 2:
            path.move(to: point(4.40, 3.90))
            path.curve(
                to: point(6.80, 3.85),
                controlPoint1: point(5.25, 3.70),
                controlPoint2: point(6.05, 3.75)
            )
        case 3:
            path.move(to: point(4.40, 4.00))
            path.curve(
                to: point(6.80, 3.70),
                controlPoint1: point(5.20, 3.40),
                controlPoint2: point(6.05, 3.40)
            )
        default:
            path.move(to: point(4.40, 4.05))
            path.curve(
                to: point(6.80, 3.60),
                controlPoint1: point(5.15, 3.15),
                controlPoint2: point(6.10, 3.15)
            )
        }

        return path
    }

    private static func drawDarumaEye(center: NSPoint, painted: Bool) {
        if painted {
            let r: CGFloat = 1.32
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
        } else {
            let r: CGFloat = 1.02
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = 0.60
            ring.stroke()
        }
    }

    private static func drawDarumaMouth(stage: Int) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch stage {
        case 1:
            path.lineWidth = 0.98
            path.move(to: NSPoint(x: 5.90, y: 10.32))
            path.curve(
                to: NSPoint(x: 10.10, y: 10.32),
                controlPoint1: NSPoint(x: 7.05, y: 9.12),
                controlPoint2: NSPoint(x: 8.95, y: 9.12)
            )
            path.stroke()
        case 2:
            path.lineWidth = 0.96
            path.move(to: NSPoint(x: 6.35, y: 9.60))
            path.line(to: NSPoint(x: 9.65, y: 9.60))
            path.stroke()
        case 3:
            path.lineWidth = 1.00
            path.move(to: NSPoint(x: 5.70, y: 9.28))
            path.curve(
                to: NSPoint(x: 10.30, y: 9.28),
                controlPoint1: NSPoint(x: 6.75, y: 10.85),
                controlPoint2: NSPoint(x: 9.25, y: 10.85)
            )
            path.stroke()
        default:
            let yTop: CGFloat = 8.92
            let xLeft: CGFloat = 5.55
            let xRight: CGFloat = 10.45
            let corner: CGFloat = 0.30
            path.move(to: NSPoint(x: xLeft + corner, y: yTop))
            path.line(to: NSPoint(x: xRight - corner, y: yTop))
            path.curve(
                to: NSPoint(x: xRight, y: yTop + corner),
                controlPoint1: NSPoint(x: xRight - corner * 0.25, y: yTop),
                controlPoint2: NSPoint(x: xRight, y: yTop + corner * 0.25)
            )
            path.curve(
                to: NSPoint(x: xLeft, y: yTop + corner),
                controlPoint1: NSPoint(x: xRight - 0.25, y: 11.35),
                controlPoint2: NSPoint(x: xLeft + 0.25, y: 11.35)
            )
            path.curve(
                to: NSPoint(x: xLeft + corner, y: yTop),
                controlPoint1: NSPoint(x: xLeft, y: yTop + corner * 0.25),
                controlPoint2: NSPoint(x: xLeft + corner * 0.25, y: yTop)
            )
            path.close()
            path.fill()
        }
    }
}
