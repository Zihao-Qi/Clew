import Foundation

/// Dragging near the top or bottom edge of a list that scrolls (Today and Goals & Later
/// past the screen's height; user, 2026-11-18): the list scrolls by itself, faster the
/// deeper the pointer is in the edge band, and a pointer past the edge scrolls fastest.
public enum ListAutoScroll {
    /// The edge band, in points.
    public static let edge: Double = 28
    /// The fastest scroll, in points per tick (a tick is 1/60 s).
    public static let maxStep: Double = 9

    /// How far to scroll on this tick: negative scrolls up, positive down, 0 not at all.
    public static func step(pointerY: Double, viewport: (minY: Double, maxY: Double)) -> Double {
        guard viewport.maxY - viewport.minY > 2 * edge else { return 0 }
        if pointerY < viewport.minY + edge {
            return -speed(depth: (viewport.minY + edge - pointerY) / edge)
        }
        if pointerY > viewport.maxY - edge {
            return speed(depth: (pointerY - (viewport.maxY - edge)) / edge)
        }
        return 0
    }

    /// From 1 point at the band's inner line to `maxStep` at the edge and beyond.
    private static func speed(depth: Double) -> Double {
        max(1, min(1, depth) * maxStep)
    }

    /// A new scroll offset, kept between the top (0) and the end of the content.
    public static func clamp(_ offset: Double, maxOffset: Double) -> Double {
        min(max(offset, 0), max(maxOffset, 0))
    }
}
