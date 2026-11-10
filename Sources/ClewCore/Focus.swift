import ClewDomain
import Foundation

/// The focus timer (SPEC decision 2026-11-10): one at a time, attached to a task on
/// Today. It fills the task's bar as time passes; when time is up the task asks
/// "Done?" and never ticks by itself. A 5-minute break can follow.
///
/// It is not a fact: it is the one running timer, kept in settings so it survives
/// sleep and quitting. Times are absolute, so a closed lid loses nothing.
public struct FocusTimer: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case focus
        /// The break after a focus ("break" is a Swift keyword).
        case rest
    }

    public var phase: Phase
    public var itemId: UUID
    /// When this phase started.
    public var startedAt: Date
    /// The phase's length in seconds, extensions included.
    public var length: TimeInterval
    /// Set while paused.
    public var pausedAt: Date?
    /// Time spent paused before `pausedAt`.
    public var pausedFor: TimeInterval

    public init(phase: Phase, itemId: UUID, startedAt: Date, length: TimeInterval,
                pausedAt: Date? = nil, pausedFor: TimeInterval = 0) {
        self.phase = phase
        self.itemId = itemId
        self.startedAt = startedAt
        self.length = length
        self.pausedAt = pausedAt
        self.pausedFor = pausedFor
    }

    public var isPaused: Bool { pausedAt != nil }

    /// Time counted so far (pauses left out), never negative even if the clock moved back.
    public func elapsed(at now: Date) -> TimeInterval {
        let end = pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedFor)
    }

    public func remaining(at now: Date) -> TimeInterval { max(0, length - elapsed(at: now)) }

    /// 0–1, for the bar.
    public func fraction(at now: Date) -> Double { length <= 0 ? 1 : min(1, elapsed(at: now) / length) }

    public func isOver(at now: Date) -> Bool { elapsed(at: now) >= length }

    /// When time will be up, unless paused.
    public var endsAt: Date? { isPaused ? nil : startedAt.addingTimeInterval(length + pausedFor) }
}

extension Clew {
    /// The lengths offered when starting (user, 2026-11-10: fixed choices).
    public static let focusMinutes = [10, 25, 45]
    public static let breakMinutes = 5
    /// "5 more min" when time is up.
    public static let extraMinutes = 5

    static let focusTimerKey = "focusTimer"
    static let focusOffersBreakKey = "focusOffersBreak"

    /// The running timer, if any.
    public func focusTimer() throws -> FocusTimer? {
        try storeForQueries.read { try Self.focusTimer($0) }
    }

    static func focusTimer(_ r: any StoreReader) throws -> FocusTimer? {
        guard let json = try r.setting(focusTimerKey), json != "null" else { return nil }
        // A timer that cannot be read (e.g. from a newer version) is no timer.
        return try? JSONDecoder().decode(FocusTimer.self, from: Data(json.utf8))
    }

    private static func save(_ timer: FocusTimer?, now: Date, _ w: any StoreWriter) throws {
        let json = try timer.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "null"
        try w.saveSetting(focusTimerKey, json: json, updatedAt: now)
    }

    /// Starts focusing on a task on Today for one of `focusMinutes`. A running focus
    /// must be stopped first (`focusRunning`), so it is never replaced silently; a break
    /// is simply replaced.
    @discardableResult
    public func startFocus(itemId: UUID, minutes: Int) throws -> FocusTimer {
        guard Self.focusMinutes.contains(minutes) else { throw ClewError.notAllowed }
        let now = clockForQueries.now()
        return try storeForQueries.write { w in
            guard let item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
            guard item.state == .active, !Self.isCollectionItem(item) else { throw ClewError.notAllowed }
            if try Self.focusTimer(w)?.phase == .focus { throw ClewError.focusRunning }
            let timer = FocusTimer(phase: .focus, itemId: itemId, startedAt: now, length: TimeInterval(minutes * 60))
            try Self.save(timer, now: now, w)
            return timer
        }
    }

    public func pauseFocus() throws { try changeTimer { t, now in if t.pausedAt == nil { t.pausedAt = now } } }

    public func resumeFocus() throws {
        try changeTimer { t, now in
            guard let pausedAt = t.pausedAt else { return }
            t.pausedFor += max(0, now.timeIntervalSince(pausedAt))
            t.pausedAt = nil
        }
    }

    /// "5 more min": the phase now ends 5 minutes from now (or from where it stands,
    /// if time is not up yet).
    public func extendFocus() throws {
        try changeTimer { t, now in
            t.length = max(t.length, t.elapsed(at: now)) + TimeInterval(Self.extraMinutes * 60)
        }
    }

    /// The break after a focus: same task, 5 minutes. Only from a focus, and only when
    /// breaks are offered.
    public func startBreak() throws {
        guard try focusOffersBreak() else { throw ClewError.notAllowed }
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard let running = try Self.focusTimer(w), running.phase == .focus else { throw ClewError.notAllowed }
            try Self.save(FocusTimer(phase: .rest, itemId: running.itemId, startedAt: now,
                                     length: TimeInterval(Self.breakMinutes * 60)), now: now, w)
        }
    }

    /// Ends the timer, whatever its phase. Returns what was running.
    @discardableResult
    public func stopFocus() throws -> FocusTimer? {
        let now = clockForQueries.now()
        return try storeForQueries.write { w in
            let running = try Self.focusTimer(w)
            if running != nil { try Self.save(nil, now: now, w) }
            return running
        }
    }

    private func changeTimer(_ change: (inout FocusTimer, Date) -> Void) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard var timer = try Self.focusTimer(w) else { throw ClewError.notAllowed }
            change(&timer, now)
            try Self.save(timer, now: now, w)
        }
    }

    // MARK: Settings › General › Focus timer

    /// Offer a 5-minute break when focus time is up (default on).
    public func focusOffersBreak() throws -> Bool {
        try storeForQueries.read { r in
            guard let json = try r.setting(Self.focusOffersBreakKey) else { return true }
            return json != "false"
        }
    }

    public func setFocusOffersBreak(_ on: Bool) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { try $0.saveSetting(Self.focusOffersBreakKey, json: on ? "true" : "false", updatedAt: now) }
    }

    /// The notification for the end of the running phase, if it is running and not over.
    func focusNotification(_ r: any StoreReader, now: Date) throws -> PlannedNotification? {
        guard let timer = try Self.focusTimer(r), let endsAt = timer.endsAt, endsAt > now,
              let item = try r.item(id: timer.itemId), item.deletedAt == nil
        else { return nil }
        return PlannedNotification(
            id: NotificationPlanner.idPrefix + "focus",
            fireAt: endsAt,
            content: timer.phase == .focus ? .focusEnded(itemId: item.id, title: item.title) : .breakEnded(title: item.title)
        )
    }
}
