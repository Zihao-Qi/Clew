import ClewDomain
import Foundation

/// A screen point and rectangle for the peek (AppKit screen coordinates: y grows
/// upwards). Core is Foundation only, so it does not use CoreGraphics' types.
public struct PeekPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct PeekRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
}

/// When the hover panel beside a collection row is open (SPEC 2026-11-13, "A peek on
/// hover"). Pure: the app feeds it pointer, panel and menu events with the time, and
/// calls `tick` at `deadline`. Positions are screen points (AppKit: y grows upwards).
public struct PeekState: Equatable, Sendable {
    public enum Side: Equatable, Sendable { case left, right }

    /// Rest on a row this long opens its panel.
    public static let openDelay: TimeInterval = 0.3
    /// Away from row and panel this long (and not heading for the panel) closes it.
    public static let closeDelay: TimeInterval = 0.2

    /// The collection whose panel is open.
    public private(set) var open: Source?
    /// The side of the menu the open panel is on, for "heading toward it".
    public private(set) var side: Side?

    /// The row under the pointer, and whether the pointer has moved on it (two different
    /// positions), so a row sliding under a still pointer never opens anything.
    private var row: Source?
    private var moved = false
    private var restSince: Date?
    private var last: PeekPoint?
    private var inPanel = false
    private var closingSince: Date?
    /// Clicked: no panel for this row until the pointer has left it.
    private var blocked: Source?
    private var dragging = false

    public init() {}

    /// When `tick` must be called next, if anything is waiting.
    public var deadline: Date? {
        if let closingSince, open != nil { return closingSince.addingTimeInterval(Self.closeDelay) }
        if let restSince, row != nil, row != open { return restSince.addingTimeInterval(Self.openDelay) }
        return nil
    }

    /// The pointer moved, on collection row `on` (nil: elsewhere in the menu), at `point`.
    public mutating func pointer(on: Source?, at point: PeekPoint, now: Date) {
        let previous = last
        last = point
        let heading = isHeadingToPanel(from: previous, to: point)
        if on != row {
            // A new row: nothing counts until the pointer moves on it.
            if row == blocked { blocked = nil }
            row = on
            moved = false
            restSince = nil
        } else if on != nil, let previous, previous != point {
            moved = true
            // Moving on a row with no panel of its own (yet, or again after one closed)
            // starts a rest.
            if restSince == nil, row != open { restSince = now }
        }
        // Heading for the open panel across another row is not rest on that row.
        if heading, let row, row != open, moved { restSince = now }
        updateClosing(now: now, heading: heading)
    }

    /// The pointer left the menu's rows (and is not in the panel).
    public mutating func pointerLeftRows(now: Date) {
        if row == blocked { blocked = nil }
        row = nil
        moved = false
        restSince = nil
        updateClosing(now: now, heading: false)
    }

    public mutating func panelHover(_ inside: Bool, now: Date) {
        inPanel = inside
        if inside {
            // In the panel, the pointer is on no row: no other row is resting.
            if row == blocked { blocked = nil }
            row = nil
            moved = false
            restSince = nil
        }
        updateClosing(now: now, heading: false)
    }

    /// The row was clicked: its page opens.
    public mutating func rowClicked() {
        blocked = row
        close()
    }

    public mutating func dragChanged(_ active: Bool) {
        dragging = active
        if active { close() }
    }

    /// The list screen went away (⌘N, ⌘L, details, a page): everything starts again.
    public mutating func listLeft() {
        self = PeekState()
    }

    /// The menu closed (or stopped being key).
    public mutating func menuClosed() {
        self = PeekState()
    }

    /// `source` has nothing left: its panel closes.
    public mutating func emptied(_ source: Source) {
        if open == source { close() }
    }

    /// The app reports where the panel opened (from `peekFrame`).
    public mutating func placed(on side: Side) {
        if open != nil { self.side = side }
    }

    public mutating func tick(now: Date) {
        if let closingSince, open != nil, now >= closingSince.addingTimeInterval(Self.closeDelay) {
            close()
        }
        if let row, row != open, row != blocked, moved, !dragging, let restSince,
           now >= restSince.addingTimeInterval(Self.openDelay) {
            open = row
            side = nil
            closingSince = nil
            self.restSince = nil
        }
    }

    private mutating func close() {
        open = nil
        side = nil
        closingSince = nil
    }

    /// Off the open row and out of the panel: the close wait runs, restarting while the
    /// pointer keeps heading for the panel.
    private mutating func updateClosing(now: Date, heading: Bool) {
        guard open != nil else { closingSince = nil; return }
        if row == open || inPanel {
            closingSince = nil
        } else if closingSince == nil || heading {
            closingSince = now
        }
    }

    private func isHeadingToPanel(from: PeekPoint?, to: PeekPoint) -> Bool {
        guard open != nil, let side, let from else { return false }
        return side == .left ? to.x < from.x : to.x > from.x
    }
}

/// Where the peek panel goes (SPEC 2026-11-13): `width` wide, flush against the menu
/// window on the side with room in the screen's visible frame (left first), its top at
/// the row's top, moved to stay inside the visible frame. AppKit screen coordinates.
public func peekFrame(menu: PeekRect, row: PeekRect, visible: PeekRect, width: Double, height: Double)
    -> (frame: PeekRect, side: PeekState.Side) {
    let side: PeekState.Side = menu.minX - width >= visible.minX ? .left : .right
    let x = side == .left ? menu.minX - width : min(menu.maxX, visible.maxX - width)
    let h = min(height, visible.height)
    var y = row.maxY - h
    if y < visible.minY { y = visible.minY }
    if y + h > visible.maxY { y = visible.maxY - h }
    return (PeekRect(x: x, y: y, width: width, height: h), side)
}
