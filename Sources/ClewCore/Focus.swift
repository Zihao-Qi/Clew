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

/// A task's focus time, for its details page.
public struct FocusSummary: Hashable, Sendable {
    public let thisWeek: Int
    public let total: Int
    public let recent: [FocusSession]

    public init(thisWeek: Int, total: Int, recent: [FocusSession]) {
        self.thisWeek = thisWeek
        self.total = total
        self.recent = recent
    }
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
        // On today's list, not just active (an active item can be planned for another
        // day; Gemini review 2026-11-10).
        guard try today().rows.contains(where: { $0.id == itemId }) else {
            let exists = try storeForQueries.read { try $0.item(id: itemId).map { $0.deletedAt == nil } ?? false }
            throw exists ? ClewError.notAllowed : ClewError.itemNotFound
        }
        let now = clockForQueries.now()
        return try storeForQueries.write { w in
            // Today's list holds only active tasks, never a collection's items.
            guard let item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
            _ = item
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
        guard try focusTimer()?.phase == .focus else { throw ClewError.notAllowed }   // breaks stay 5 minutes
        try changeTimer { t, now in
            t.length = max(t.length, t.elapsed(at: now)) + TimeInterval(Self.extraMinutes * 60)
        }
    }

    /// The break after a focus: same task, 5 minutes. Only from a focus, and only when
    /// breaks are offered.
    public func startBreak() throws {
        guard try focusOffersBreak() else { throw ClewError.notAllowed }
        let now = clockForQueries.now()
        let records = try focusRecordsTime()
        let zone = zonesForQueries.current()
        try storeForQueries.write { w in
            // From a focus whose time is up (the row offers it then, SPEC 2026-11-10).
            guard let running = try Self.focusTimer(w), running.phase == .focus, running.isOver(at: now)
            else { throw ClewError.notAllowed }
            // The focus that just ended is time worked, even though no Stop was pressed.
            if records { try record(running, at: now, zone: zone, w) }
            try Self.save(FocusTimer(phase: .rest, itemId: running.itemId, startedAt: now,
                                     length: TimeInterval(Self.breakMinutes * 60)), now: now, w)
        }
    }

    /// "Done" (or "+1") when focus time is up: ticks the task the way the circle would,
    /// but never un-ticks it (a task ticked during the focus stays ticked; a goal at its
    /// target gets no +1), then ends the timer (Gemini review 2026-11-10: it toggled).
    @discardableResult
    public func finishFocus() throws -> CheckIn? {
        guard let running = try focusTimer(), running.phase == .focus else { throw ClewError.notAllowed }
        var tick: CheckIn?
        // One sitting, one tick: a time block of this task that ticked while the timer ran
        // already counted it, if that tick still stands (SPEC 2026-11-10).
        let now = clockForQueries.now()
        let blockTicked = try storeForQueries.read { r in
            try r.timeBlocks(from: currentDay().adding(days: -1)).contains { b in
                // A block's tick, or the answer to a slot block's "Done?".
                let id = b.tickId ?? (b.origin == .slot ? b.coverId : nil)
                guard b.itemId == running.itemId, let id, let t = try r.checkIn(id: id) else { return false }
                return !t.isVoided && t.at >= running.startedAt && t.at <= now
            }
        }
        if !blockTicked {
            do {
                // CheckIn is idempotent for a day's once-task or habit: an existing tick is kept.
                tick = try checkIn(itemId: running.itemId)
            } catch ClewError.goalReached {
                tick = nil
            }
        }
        try stopFocus()
        return tick
    }

    /// Ends the timer, whatever its phase. Returns what was running. A focus is
    /// recorded as a session of its real minutes (pauses left out) when Settings ›
    /// "Record focus time" is on and it ran at least half a minute; a break never is.
    @discardableResult
    public func stopFocus() throws -> FocusTimer? {
        let now = clockForQueries.now()
        let records = try focusRecordsTime()
        let zone = zonesForQueries.current()
        return try storeForQueries.write { w in
            guard let running = try Self.focusTimer(w) else { return nil }
            try Self.save(nil, now: now, w)
            if records { try record(running, at: now, zone: zone, w) }
            return running
        }
    }

    /// Saves a focus that ended as a session of its real minutes, if it ran at least
    /// half a minute; a break is never time worked.
    private func record(_ timer: FocusTimer, at now: Date, zone: TimeZone, _ w: any StoreWriter) throws {
        let minutes = min(Self.maxFocusMinutes, Int((timer.elapsed(at: now) / 60).rounded()))
        guard timer.phase == .focus, minutes >= 1,
              let item = try w.item(id: timer.itemId), item.deletedAt == nil else { return }
        try w.insert(FocusSession(
            id: newID(), itemId: item.id,
            localDay: LocalDay(of: timer.startedAt, in: zone, rolloverHour: rolloverHour),
            at: timer.startedAt, minutes: minutes, kind: .timer))
    }

    // MARK: Focus time (SPEC 2026-11-10, step 2)

    /// The most one session can hold: 12 hours.
    public static let maxFocusMinutes = 720

    /// Adds time worked by hand ("I forgot the timer", "the Mac wasn't there"): always
    /// allowed, even with recording off, since it is a deliberate act. 1–720 minutes,
    /// on a day up to today, for a task (not a collection's video or post).
    @discardableResult
    public func addFocusTime(itemId: UUID, day: LocalDay, minutes: Int) throws -> FocusSession {
        guard (1...Self.maxFocusMinutes).contains(minutes) else { throw ClewError.invalidMinutes(max: Self.maxFocusMinutes) }
        guard day <= currentDay() else { throw ClewError.notAllowed }
        let now = clockForQueries.now()
        return try storeForQueries.write { w in
            guard let item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
            guard !Self.isCollectionItem(item) else { throw ClewError.notAllowed }
            let session = FocusSession(id: newID(), itemId: itemId, localDay: day, at: now, minutes: minutes, kind: .manual)
            try w.insert(session)
            return session
        }
    }

    /// Removes a session (timer or by hand): a void, so the fact stays. Removing one
    /// already removed changes nothing.
    public func removeFocusSession(id: UUID) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard let session = try w.focusSession(id: id) else { throw ClewError.notAllowed }
            guard session.voidedAt == nil else { return }
            try w.voidFocusSession(id: id, at: now)
        }
    }

    /// What a task's details show: minutes this week and all time (days up to today),
    /// and the latest sessions, newest first.
    public func focusSummary(itemId: UUID, recent: Int = 10) throws -> FocusSummary {
        let today = currentDay()
        let sessions = try storeForQueries.read { try $0.focusSessions(itemIds: [itemId]) }.filter { $0.localDay <= today }
        return FocusSummary(
            thisWeek: sessions.filter { $0.localDay.isInSameWeek(as: today) }.reduce(0) { $0 + $1.minutes },
            total: sessions.reduce(0) { $0 + $1.minutes },
            recent: Array(sessions.sorted { ($0.localDay, $0.at, $0.id.uuidString) > ($1.localDay, $1.at, $1.id.uuidString) }.prefix(recent))
        )
    }

    static let focusRecordsTimeKey = "focusRecordsTime"

    /// Settings › Focus timer › "Record focus time" (default on). Off: the timer saves
    /// nothing new; sessions already saved and time added by hand stay.
    public func focusRecordsTime() throws -> Bool {
        try storeForQueries.read { r in
            guard let json = try r.setting(Self.focusRecordsTimeKey) else { return true }
            return json != "false"
        }
    }

    public func setFocusRecordsTime(_ on: Bool) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { try $0.saveSetting(Self.focusRecordsTimeKey, json: on ? "true" : "false", updatedAt: now) }
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
              let item = try r.item(id: timer.itemId), item.deletedAt == nil, item.state == .active
        else { return nil }
        return PlannedNotification(
            id: NotificationPlanner.idPrefix + "focus",
            fireAt: endsAt,
            content: timer.phase == .focus ? .focusEnded(itemId: item.id, title: item.title) : .breakEnded(title: item.title)
        )
    }
}
