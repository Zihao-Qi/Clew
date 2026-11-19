import ClewDomain
import Foundation

/// What the menu bar shows (SPEC 2026-11-18, "The menu bar ring").
public enum MenuBarStyle: String, Codable, Sendable, CaseIterable {
    /// A ring that fills as today's tasks are ticked.
    case ring
    /// The icon plus `done/total`.
    case count
}

/// The ring for `done` of `total` tasks on Today.
public enum MenuBarRing: Hashable, Sendable {
    /// One part per task, `done` of them filled (0 done: the empty ring).
    case parts(done: Int, of: Int)
    /// Over `maxParts` tasks: one smooth ring filled by the share done.
    case share(Double)
    /// Everything done: a filled circle with a ✓.
    case finished

    /// Up to this many tasks the ring is split into parts.
    public static let maxParts = 8

    /// nil when there is nothing on Today (the plain icon shows).
    public init?(done: Int, total: Int) {
        guard total > 0 else { return nil }
        let done = max(0, done)
        if done >= total {
            self = .finished
        } else if total <= Self.maxParts {
            self = .parts(done: done, of: total)
        } else {
            self = .share(Double(done) / Double(total))
        }
    }
}

extension Clew {
    static let menuBarStyleKey = "menuBarStyle"
    public static let defaultMenuBarStyle = MenuBarStyle.ring

    public func menuBarStyle() throws -> MenuBarStyle {
        try storeForQueries.read { r in
            guard let json = try r.setting(Self.menuBarStyleKey) else { return Self.defaultMenuBarStyle }
            // An unknown value (e.g. from a newer version) falls back to the default.
            return (try? JSONDecoder().decode(MenuBarStyle.self, from: Data(json.utf8))) ?? Self.defaultMenuBarStyle
        }
    }

    public func setMenuBarStyle(_ style: MenuBarStyle) throws {
        let now = clockForQueries.now()
        let json = String(decoding: try JSONEncoder().encode(style), as: UTF8.self)
        try storeForQueries.write { try $0.saveSetting(Self.menuBarStyleKey, json: json, updatedAt: now) }
    }
}
