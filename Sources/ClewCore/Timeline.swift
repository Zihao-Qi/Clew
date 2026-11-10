import ClewDomain
import Foundation

/// What a block's end did (ARCHITECTURE §6 "Day timeline"), derived from the stored
/// block and its tick.
public enum BlockState: String, Sendable, Hashable {
    /// Its end has not passed (or has, and `settleBlocks` has not run yet).
    case pending
    /// It ticked the task, and that tick stands.
    case ticked
    /// It ticked, and the tick was undone (Not finished, or the row's undo).
    case undone
    /// A tick made by hand covered it.
    case covered
    /// The task needed nothing when it ended.
    case skipped
}

/// A block as the timeline shows it.
public struct TimelineBlock: Hashable, Sendable, Identifiable {
    public let block: TimeBlock
    public let title: String
    public let state: BlockState
    /// False when its tick belongs to a goal round that has since closed: it can be
    /// removed (the tick stays), not moved, resized or un-finished.
    public let canChange: Bool
    /// Overlapping blocks sit side by side: this one's column, and how many columns
    /// its group of overlapping blocks needs.
    public let lane: Int
    public let lanes: Int

    public var id: UUID { block.id }
}

/// Today's timeline: Clew's day (rollover to rollover) and its blocks.
public struct TimelineDay: Hashable, Sendable {
    public let day: LocalDay
    public let start: Date
    public let end: Date
    public let blocks: [TimelineBlock]

    /// The start of the task's next block that has not ended, for its row ("10:00").
    public func nextStart(of itemId: UUID, now: Date) -> Date? {
        blocks.filter { $0.block.itemId == itemId && $0.block.end > now }.map(\.block.start).min()
    }
}

/// A task ticked by a time block for an earlier day, made today (the Mac slept through
/// the block's end): "Ticked for yesterday: Write intro · Not finished".
public struct LateTick: Hashable, Sendable, Identifiable {
    public let itemId: UUID
    public let title: String
    /// The latest day ticked that way.
    public let day: LocalDay
    public let tickIds: [UUID]
    /// False when a goal round has closed over one of them: Not finished is left out.
    public let canUndo: Bool

    public var id: UUID { itemId }
}

extension Clew {
    /// Blocks snap to quarter hours and are at least this long.
    public static let blockStepMinutes = 15
    /// A dropped task's length (SPEC 2026-11-10).
    public static let blockDefaultMinutes = 30
    /// Lengths offered without dragging.
    public static let blockLengths = [15, 30, 45, 60, 90]
    /// How far back a block may tick late (the Mac asleep for weeks is still covered).
    static let lateTickWindowDays = 60

    static let timelineShownKey = "timelineShown"
    static let blockAlertsKey = "blockAlerts"
    static let lateTicksSeenKey = "lateTicksSeen"

    /// Clew's day `day`: from its rollover to the next one (23 or 25 hours on DST days).
    public func dayBounds(_ day: LocalDay) -> (start: Date, end: Date) {
        let zone = zonesForQueries.current()
        let rollover = TimeOfDay(hour: rolloverHour, minute: 0)!
        return (day.instant(at: rollover, in: zone, rolloverHour: rolloverHour),
                day.adding(days: 1).instant(at: rollover, in: zone, rolloverHour: rolloverHour))
    }

    // MARK: - Queries

    public func timeline() throws -> TimelineDay {
        let today = currentDay()
        let (start, end) = dayBounds(today)
        return try storeForQueries.read { r in
            let rows = Dictionary(uniqueKeysWithValues: try todayList(r, on: today).rows.map { ($0.id, $0) })
            let live = try r.timeBlocks(from: today)
                .filter { $0.localDay == today && $0.removedAt == nil && rows[$0.itemId] != nil }
                .sorted { ($0.start, $0.placedAt, $0.id.uuidString) < ($1.start, $1.placedAt, $1.id.uuidString) }
            let lanes = Self.lanes(live.map { ($0.start, $0.end) })
            let rounds = try r.roundStarts(itemIds: Array(Set(live.map(\.itemId))))
            var blocks: [TimelineBlock] = []
            for (b, lane) in zip(live, lanes) {
                let tick = try b.tickId.flatMap { try r.checkIn(id: $0) }
                let cover = try b.coverId.flatMap { try r.checkIn(id: $0) }
                let state: BlockState = b.decidedAt == nil ? .pending
                    : tick.map { $0.isVoided ? .undone : .ticked }
                    ?? (cover.map { !$0.isVoided } == true ? .covered : .skipped)
                blocks.append(TimelineBlock(
                    block: b, title: rows[b.itemId]?.item.title ?? "", state: state,
                    canChange: !Self.roundClosed(over: tick, roundStart: rounds[b.itemId]),
                    lane: lane.lane, lanes: lane.lanes))
            }
            return TimelineDay(day: today, start: start, end: end, blocks: blocks)
        }
    }

    /// Ticks made today by blocks of earlier days, one entry per task, minus the ones
    /// dismissed.
    public func lateTicks() throws -> [LateTick] {
        let today = currentDay()
        return try storeForQueries.read { r in
            let seen = Set(try Self.lateTicksSeen(r))
            let late = try lateBlockTicks(r, today: today).filter { !seen.contains($0.tick.id) }
            let rounds = try r.roundStarts(itemIds: Array(Set(late.map(\.block.itemId))))
            return try Dictionary(grouping: late, by: \.block.itemId).compactMap { itemId, ticks -> LateTick? in
                guard let item = try r.item(id: itemId), item.deletedAt == nil else { return nil }
                return LateTick(
                    itemId: itemId, title: item.title, day: ticks.map(\.block.localDay).max()!,
                    tickIds: ticks.map(\.tick.id).sorted { $0.uuidString < $1.uuidString },
                    canUndo: !ticks.contains { Self.roundClosed(over: $0.tick, roundStart: rounds[itemId]) })
            }
            .sorted { ($0.title, $0.itemId.uuidString) < ($1.title, $1.itemId.uuidString) }
        }
    }

    /// Live block ticks for an earlier day, made today.
    func lateBlockTicks(_ r: any StoreReader, today: LocalDay) throws -> [(block: TimeBlock, tick: CheckIn)] {
        let zone = zonesForQueries.current()
        return try r.timeBlocks(from: today.adding(days: -Self.lateTickWindowDays)).compactMap { b in
            guard b.localDay < today, let decided = b.decidedAt,
                  LocalDay(of: decided, in: zone, rolloverHour: rolloverHour) == today,
                  let id = b.tickId, let tick = try r.checkIn(id: id), !tick.isVoided
            else { return nil }
            return (b, tick)
        }
    }

    // MARK: - Settling (a block's end ticks the task)

    /// Removes today's blocks whose task left Today, then lets every block whose end has
    /// passed decide, once. Writes only when something changes, so the app can call it
    /// on every refresh. Returns whether anything changed.
    @discardableResult
    public func settleBlocks() throws -> Bool {
        let now = clockForQueries.now()
        let zone = zonesForQueries.current()
        let today = LocalDay(of: now, in: zone, rolloverHour: rolloverHour)
        return try storeForQueries.write { w in
            var changed = false
            let onList = Set(try todayList(w, on: today).rows.map(\.id))
            for var b in try w.timeBlocks(from: today)
            where b.localDay == today && b.removedAt == nil && !onList.contains(b.itemId) {
                b.removedAt = now
                b.updatedAt = now
                try w.save(b)
                changed = true
            }
            for b in try w.pendingTimeBlocks() where b.end <= now {
                try decide(b, now: now, zone: zone, w)
                changed = true
            }
            return changed
        }
    }

    /// One block's end: tick, or skip when the task needs nothing (SPEC 2026-11-10).
    private func decide(_ block: TimeBlock, now: Date, zone: TimeZone, _ w: any StoreWriter) throws {
        var b = block
        b.updatedAt = now
        guard let item = try w.item(id: b.itemId), item.deletedAt == nil, item.state == .active else {
            b.removedAt = now
            try w.save(b)
            return
        }
        b.decidedAt = now
        let progress = try w.progressAmounts(itemIds: [b.itemId])[b.itemId] ?? 0
        let onDay = try w.checkIns(itemIds: [b.itemId], from: b.localDay).filter { $0.localDay == b.localDay }
        if let target = item.progress.target {
            if progress >= target {
                try w.save(b)
                return
            }
            // Each hand tick covers one block: the earliest one made since this block was
            // placed that no other block (removed ones too) used. The one this block used
            // before a move is still its own, so it covers it again.
            let others = try w.timeBlocks(from: b.localDay).filter { $0.itemId == b.itemId && $0.id != b.id }
            let used = Set(others.compactMap(\.coverId))
            if let hand = onDay.filter({ $0.source != .timeline && $0.at >= b.placedAt && !used.contains($0.id) })
                .min(by: { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }) {
                b.coverId = hand.id
                try w.save(b)
                return
            }
        } else {
            // A once-task or link done on any day, or a habit ticked on the block's day.
            let done = item.kind == .once || item.kind == .link ? progress > 0 : !onDay.isEmpty
            if done {
                try w.save(b)
                return
            }
        }
        let tick = CheckIn(id: newID(), itemId: b.itemId, localDay: b.localDay, at: now,
                           timeZoneId: zone.identifier, amount: 1, source: .timeline)
        try w.insert(tick)
        b.tickId = tick.id
        try w.save(b)
    }

    // MARK: - Commands

    /// Drag a row onto an hour, or "Put on timeline…": moves the task's earliest block
    /// that has not ended, else adds one (30 minutes, cut at the day's end).
    @discardableResult
    public func placeOnTimeline(itemId: UUID, start: Date, minutes: Int? = nil) throws -> TimeBlock {
        let now = clockForQueries.now()
        let today = currentDay()
        let bounds = dayBounds(today)
        try Self.checkStart(start, bounds)
        return try storeForQueries.write { w in
            guard try todayList(w, on: today).rows.contains(where: { $0.id == itemId }) else {
                throw ClewError.notAllowed
            }
            let open = try w.timeBlocks(from: today)
                .filter { $0.itemId == itemId && $0.localDay == today && $0.removedAt == nil && $0.end > now }
                .min { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
            if let open {
                return try change(open, start: start, minutes: minutes ?? open.minutes, today: today, now: now, w)
            }
            let room = Int(bounds.end.timeIntervalSince(start) / 60)
            let length = minutes ?? min(Self.blockDefaultMinutes, room)
            try Self.checkLength(length, start: start, bounds)
            let block = TimeBlock(id: newID(), itemId: itemId, localDay: today, start: start, minutes: length,
                                  placedAt: now, updatedAt: now)
            try w.save(block)
            return try decideIfEnded(block, now: now, w)
        }
    }

    /// Move to… or a drag of the block: a new start, and optionally a new length.
    @discardableResult
    public func moveBlock(id: UUID, start: Date, minutes: Int? = nil) throws -> TimeBlock {
        let now = clockForQueries.now()
        let today = currentDay()
        return try storeForQueries.write { w in
            let b = try liveBlock(id, today: today, w)
            return try change(b, start: start, minutes: minutes ?? b.minutes, today: today, now: now, w)
        }
    }

    /// Length, or a drag of the block's bottom edge.
    @discardableResult
    public func resizeBlock(id: UUID, minutes: Int) throws -> TimeBlock {
        let now = clockForQueries.now()
        let today = currentDay()
        return try storeForQueries.write { w in
            let b = try liveBlock(id, today: today, w)
            return try change(b, start: b.start, minutes: minutes, today: today, now: now, w)
        }
    }

    /// "Add another block": the same length, right after this one.
    @discardableResult
    public func addBlock(after id: UUID) throws -> TimeBlock {
        let now = clockForQueries.now()
        let today = currentDay()
        let bounds = dayBounds(today)
        return try storeForQueries.write { w in
            let b = try liveBlock(id, today: today, w)
            guard try todayList(w, on: today).rows.contains(where: { $0.id == b.itemId }) else {
                throw ClewError.notAllowed
            }
            try Self.checkLength(b.minutes, start: b.end, bounds)
            let next = TimeBlock(id: newID(), itemId: b.itemId, localDay: today, start: b.end, minutes: b.minutes,
                                 placedAt: now, updatedAt: now)
            try w.save(next)
            return try decideIfEnded(next, now: now, w)
        }
    }

    /// Whether "Add another block" fits before the day ends.
    public func canAddBlock(after block: TimeBlock) -> Bool {
        block.end.addingTimeInterval(TimeInterval(block.minutes * 60)) <= dayBounds(block.localDay).end
    }

    /// Takes a block off the timeline. Its tick goes with it, unless a goal round has
    /// closed over it; ticks made by hand are never touched.
    public func removeBlock(id: UUID) throws {
        let now = clockForQueries.now()
        let today = currentDay()
        try storeForQueries.write { w in
            var b = try liveBlock(id, today: today, w)
            if let tick = try liveTick(of: b, w),
               !Self.roundClosed(over: tick, roundStart: try w.roundStarts(itemIds: [b.itemId])[b.itemId]) {
                try w.voidCheckIn(id: tick.id, at: now, reason: "blockRemoved")
            }
            b.removedAt = now
            b.updatedAt = now
            try w.save(b)
        }
    }

    /// Not finished: undoes the block's tick. The block stays and does not tick again.
    public func blockNotFinished(id: UUID) throws {
        let now = clockForQueries.now()
        let today = currentDay()
        try storeForQueries.write { w in
            var b = try liveBlock(id, today: today, w)
            guard let tick = try liveTick(of: b, w),
                  !Self.roundClosed(over: tick, roundStart: try w.roundStarts(itemIds: [b.itemId])[b.itemId])
            else { throw ClewError.notAllowed }
            try w.voidCheckIn(id: tick.id, at: now, reason: "notFinished")
            b.updatedAt = now
            try w.save(b)
        }
    }

    /// The earlier-days line's Not finished: undoes every late tick of the task.
    public func undoLateTicks(itemId: UUID) throws {
        let now = clockForQueries.now()
        let today = currentDay()
        try storeForQueries.write { w in
            let late = try lateBlockTicks(w, today: today).filter { $0.block.itemId == itemId }
            guard !late.isEmpty else { throw ClewError.notAllowed }
            let roundStart = try w.roundStarts(itemIds: [itemId])[itemId]
            guard !late.contains(where: { Self.roundClosed(over: $0.tick, roundStart: roundStart) }) else {
                throw ClewError.notAllowed
            }
            for (_, tick) in late { try w.voidCheckIn(id: tick.id, at: now, reason: "notFinished") }
        }
    }

    /// Closes the earlier-days line for the task (until it ticks late again).
    public func dismissLateTicks(itemId: UUID) throws {
        let now = clockForQueries.now()
        let today = currentDay()
        try storeForQueries.write { w in
            let late = try lateBlockTicks(w, today: today)
            let still = Set(late.map(\.tick.id))
            // Only ids still late today are kept, so the setting never grows.
            let seen = Set(try Self.lateTicksSeen(w)).intersection(still)
                .union(late.filter { $0.block.itemId == itemId }.map(\.tick.id))
            let json = String(decoding: try JSONEncoder().encode(seen.map(\.uuidString).sorted()), as: UTF8.self)
            try w.saveSetting(Self.lateTicksSeenKey, json: json, updatedAt: now)
        }
    }

    // MARK: - Settings

    /// Settings › General › "Show the day timeline" (default on).
    public func timelineShown() throws -> Bool { try flag(Self.timelineShownKey) }
    public func setTimelineShown(_ on: Bool) throws { try setFlag(Self.timelineShownKey, on) }
    /// Settings › Notifications › "Alert when a block starts" (default on).
    public func blockAlerts() throws -> Bool { try flag(Self.blockAlertsKey) }
    public func setBlockAlerts(_ on: Bool) throws { try setFlag(Self.blockAlertsKey, on) }

    private func flag(_ key: String) throws -> Bool {
        try storeForQueries.read { try $0.setting(key) != "false" }
    }

    private func setFlag(_ key: String, _ on: Bool) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { try $0.saveSetting(key, json: on ? "true" : "false", updatedAt: now) }
    }

    /// "Write intro · now until 10:30" at each of today's blocks that has not started,
    /// for a task that still needs something.
    func blockNotifications(_ r: any StoreReader, now: Date, today: LocalDay) throws -> [PlannedNotification] {
        guard try r.setting(Self.blockAlertsKey) != "false" else { return [] }
        let rows = Dictionary(uniqueKeysWithValues: try todayList(r, on: today).rows.map { ($0.id, $0) })
        return try r.timeBlocks(from: today).compactMap { b in
            guard b.localDay == today, b.removedAt == nil, b.start > now, let row = rows[b.itemId],
                  row.item.progress.target != nil ? !row.isGoalReached : !row.isDone
            else { return nil }
            return PlannedNotification(id: NotificationPlanner.idPrefix + "block." + b.id.uuidString, fireAt: b.start,
                                       content: .blockStarts(itemId: b.itemId, title: row.item.title, until: b.end))
        }
    }

    // MARK: - Helpers

    private func liveBlock(_ id: UUID, today: LocalDay, _ r: any StoreReader) throws -> TimeBlock {
        guard let b = try r.timeBlock(id: id), b.removedAt == nil, b.localDay == today else {
            throw ClewError.notAllowed
        }
        return b
    }

    private func liveTick(of b: TimeBlock, _ r: any StoreReader) throws -> CheckIn? {
        guard let id = b.tickId, let tick = try r.checkIn(id: id), !tick.isVoided else { return nil }
        return tick
    }

    /// A new start or length changes the block's end: its tick is undone and it decides
    /// again (at once, if the new end has passed).
    private func change(_ block: TimeBlock, start: Date, minutes: Int, today: LocalDay, now: Date,
                        _ w: any StoreWriter) throws -> TimeBlock {
        let bounds = dayBounds(today)
        try Self.checkStart(start, bounds)
        try Self.checkLength(minutes, start: start, bounds)
        guard start != block.start || minutes != block.minutes else { return block }
        var b = block
        if let tick = try liveTick(of: b, w) {
            guard !Self.roundClosed(over: tick, roundStart: try w.roundStarts(itemIds: [b.itemId])[b.itemId]) else {
                throw ClewError.notAllowed
            }
            try w.voidCheckIn(id: tick.id, at: now, reason: "blockMoved")
        }
        b.start = start
        b.minutes = minutes
        b.decidedAt = nil
        b.tickId = nil
        b.updatedAt = now
        try w.save(b)
        return try decideIfEnded(b, now: now, w)
    }

    private func decideIfEnded(_ b: TimeBlock, now: Date, _ w: any StoreWriter) throws -> TimeBlock {
        guard b.end <= now else { return b }
        try decide(b, now: now, zone: zonesForQueries.current(), w)
        return try w.timeBlock(id: b.id) ?? b
    }

    /// A tick made before the goal's current round started belongs to a closed round.
    static func roundClosed(over tick: CheckIn?, roundStart: Date?) -> Bool {
        guard let tick, !tick.isVoided, let roundStart else { return false }
        return tick.at < roundStart
    }

    static func checkStart(_ start: Date, _ bounds: (start: Date, end: Date)) throws {
        let offset = start.timeIntervalSince(bounds.start)
        guard start >= bounds.start, start < bounds.end,
              offset.truncatingRemainder(dividingBy: TimeInterval(blockStepMinutes * 60)) == 0
        else { throw ClewError.notAllowed }
    }

    static func checkLength(_ minutes: Int, start: Date, _ bounds: (start: Date, end: Date)) throws {
        let room = Int(bounds.end.timeIntervalSince(start) / 60)
        guard minutes >= blockStepMinutes, minutes % blockStepMinutes == 0, minutes <= room else {
            throw ClewError.invalidMinutes(max: max(0, room))
        }
    }

    private static func lateTicksSeen(_ r: any StoreReader) throws -> [UUID] {
        guard let json = try r.setting(lateTicksSeenKey),
              let ids = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return ids.compactMap(UUID.init(uuidString:))
    }

    /// The quarter hour `minutes` after the day's start (where a dragged row is over the
    /// hours), kept inside the day.
    public static func quarterStart(minutesIn minutes: Double, day: TimelineDay) -> Date {
        let quarters = Int(day.end.timeIntervalSince(day.start) / 60) / blockStepMinutes
        let q = min(max(Int((minutes / Double(blockStepMinutes)).rounded(.down)), 0), quarters - 1)
        return day.start.addingTimeInterval(TimeInterval(q * blockStepMinutes * 60))
    }

    /// A drag of `minutes` as whole quarter hours, to the nearest one.
    public static func snapMinutes(_ minutes: Double) -> Int {
        Int((minutes / Double(blockStepMinutes)).rounded()) * blockStepMinutes
    }

    /// Columns for overlapping spans (sorted by start): each span takes the first column
    /// free at its start; a group of spans that overlap one another shares a count.
    public static func lanes(_ spans: [(start: Date, end: Date)]) -> [(lane: Int, lanes: Int)] {
        var result: [(lane: Int, lanes: Int)] = []
        var group: [Int] = []          // indexes in the current overlapping group
        var columnEnds: [Date] = []
        var groupEnd = Date.distantPast
        func closeGroup() {
            let count = columnEnds.count
            for i in group { result[i].lanes = count }
            group = []
            columnEnds = []
        }
        for (i, span) in spans.enumerated() {
            if span.start >= groupEnd { closeGroup() }
            let lane = columnEnds.firstIndex { $0 <= span.start } ?? columnEnds.count
            if lane == columnEnds.count { columnEnds.append(span.end) } else { columnEnds[lane] = span.end }
            result.append((lane, 0))
            group.append(i)
            groupEnd = max(groupEnd, span.end)
        }
        closeGroup()
        return result
    }
}
