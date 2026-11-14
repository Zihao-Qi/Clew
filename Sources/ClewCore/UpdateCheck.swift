import Foundation

/// A Clew version: dot-separated numbers (SPEC 2026-11-13, "About and updates").
/// Compared part by part; a missing part is 0, so `1.5` equals `1.5.0`.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    /// A release tag: `v` and numbers (`v1.5.1`); anything else is nil.
    public init?(tag: String) {
        guard tag.hasPrefix("v") else { return nil }
        self.init(running: String(tag.dropFirst()))
    }

    /// The running app's version: numbers only (`1.5.0`).
    public init?(running: String) {
        let pieces = running.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(piece) else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }
    public var tag: String { "v" + description }

    private var trimmed: [Int] {
        var p = parts
        while p.last == 0 { p.removeLast() }
        return p
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { a.trimmed == b.trimmed }
    public func hash(into hasher: inout Hasher) { hasher.combine(trimmed) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// When the opt-in update check runs and when the menu shows its dot (SPEC 2026-11-13).
/// Pure: the app passes the time and what it stored.
public enum UpdateCheck {
    public static let interval: TimeInterval = 24 * 3600

    /// Due when there was no attempt yet, the last one was 24 hours ago or more, or it
    /// is in the future (the clock was set back).
    public static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return lastAttempt > now || now.timeIntervalSince(lastAttempt) >= interval
    }

    /// The known release, if it is newer than the running app.
    public static func available(running: AppVersion?, latest: AppVersion?) -> AppVersion? {
        guard let running, let latest, latest > running else { return nil }
        return latest
    }

    /// A newer release is known and About has not shown it (or shown only an older one).
    public static func showsDot(running: AppVersion?, latest: AppVersion?, seen: AppVersion?) -> Bool {
        guard let newer = available(running: running, latest: latest) else { return false }
        guard let seen else { return true }
        return newer > seen
    }
}

/// What this Mac knows about updates (SPEC 2026-11-13): the switch, the attempts, the
/// latest release seen on GitHub, and the version About has shown. The app keeps it in
/// UserDefaults (per Mac, not Clew's data) and passes the time in.
public struct UpdateState: Equatable, Sendable {
    public var isOn: Bool
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var latest: AppVersion?
    public var seen: AppVersion?

    public enum Outcome: Equatable, Sendable { case upToDate, available(AppVersion), failed }

    public init(isOn: Bool = false, lastAttempt: Date? = nil, lastSuccess: Date? = nil,
                latest: AppVersion? = nil, seen: AppVersion? = nil) {
        self.isOn = isOn; self.lastAttempt = lastAttempt; self.lastSuccess = lastSuccess
        self.latest = latest; self.seen = seen
    }

    /// An automatic check runs only with the switch on.
    public func automaticCheckDue(now: Date) -> Bool {
        isOn && UpdateCheck.isDue(lastAttempt: lastAttempt, now: now)
    }

    /// A check (automatic or Check Now) is starting: it counts as an attempt whether it
    /// works or not.
    public mutating func began(now: Date) { lastAttempt = now }

    /// The check ended with GitHub's tag (nil: no network, an error reply, no release).
    /// A tag that is not `v` plus numbers is a failed check.
    public mutating func finished(tag: String?, now: Date, running: AppVersion?, aboutShowing: Bool) -> Outcome {
        guard let tag, let version = AppVersion(tag: tag) else { return .failed }
        latest = version
        lastSuccess = now
        if aboutShowing { aboutShown(running: running) }
        if let newer = UpdateCheck.available(running: running, latest: version) { return .available(newer) }
        return .upToDate
    }

    /// About was shown: the newer release it shows no longer needs the dot.
    public mutating func aboutShown(running: AppVersion?) {
        if let newer = UpdateCheck.available(running: running, latest: latest) { seen = newer }
    }

    public func available(running: AppVersion?) -> AppVersion? {
        UpdateCheck.available(running: running, latest: latest)
    }

    public func showsDot(running: AppVersion?) -> Bool {
        UpdateCheck.showsDot(running: running, latest: latest, seen: seen)
    }
}
