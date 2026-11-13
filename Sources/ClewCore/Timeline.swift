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
    /// A slot block that ended and asks "Done?" (it never ticks by itself).
    case asking
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

    /// Tasks with a block today: they live on the timeline, not in the list (SPEC
    /// 2026-11-10, changed after first use).
    /// A goal that reached its total goes back to the list (its blocks are released).
    public var placedItems: Set<UUID> { Set(blocks.filter { $0.block.releasedAt == nil }.map(\.block.itemId)) }

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
    public static let blockLengths = TimeSlot.lengths
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
                let state: BlockState = b.decidedAt == nil ? (b.askedAt == nil ? .pending : .asking)
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

    /// In this order: blocks of earlier days decide (a slot block's question ends);
    /// today's blocks whose task left Today are removed; goals reached on the timeline go
    /// back to the list; every block whose end has passed decides once (a slot block
    /// asks instead of ticking); slot blocks are placed. Writes only when something
    /// changes, so the app can call it on every refresh. Returns whether anything changed.
    @discardableResult
    public func settleBlocks() throws -> Bool {
        let now = clockForQueries.now()
        let zone = zonesForQueries.current()
        let today = LocalDay(of: now, in: zone, rolloverHour: rolloverHour)
        return try storeForQueries.write { w in
            var changed = false
            let shown = try w.setting(Self.timelineShownKey) != "false"
            for b in try w.pendingTimeBlocks().filter({ $0.end <= now })
                .sorted(by: { ($0.localDay, $0.start, $0.id.uuidString) < ($1.localDay, $1.start, $1.id.uuidString) })
            where b.localDay < today {
                changed = try decide(b, now: now, zone: zone, today: today, asks: shown, w) || changed
            }
            let rows = Dictionary(uniqueKeysWithValues: try todayList(w, on: today).rows.map { ($0.id, $0) })
            for var b in try w.timeBlocks(from: today) where b.localDay == today && b.removedAt == nil {
                if rows[b.itemId] == nil {
                    b.removedAt = now
                } else if b.releasedAt == nil, rows[b.itemId]?.isGoalReached == true {
                    b.releasedAt = now          // a reached goal goes back to the list
                } else {
                    continue
                }
                b.updatedAt = now
                try w.save(b)
                changed = true
            }
            for b in try w.pendingTimeBlocks() where b.localDay == today && b.end <= now {
                changed = try decide(b, now: now, zone: zone, today: today, asks: shown, w) || changed
            }
            if shown { changed = try placeSlotBlocks(rows: try todayList(w, on: today).rows, today: today, now: now, w) || changed }
            return changed
        }
    }

    /// What a block's end does when it decides now.
    private enum Outcome { case skip, cover(UUID), tick }

    private func outcome(_ b: TimeBlock, item: Item, _ r: any StoreReader) throws -> Outcome {
        let progress = try r.progressAmounts(itemIds: [b.itemId])[b.itemId] ?? 0
        let onDay = try r.checkIns(itemIds: [b.itemId], from: b.localDay).filter { $0.localDay == b.localDay }
        if let target = item.progress.target {
            if progress >= target { return .skip }
            // Each hand tick covers one block: the earliest one made since this block was
            // placed that no other block (removed ones too) used. The one this block used
            // before a move is still its own, so it covers it again.
            let others = try r.timeBlocks(from: b.localDay).filter { $0.itemId == b.itemId && $0.id != b.id }
            let used = Set(others.compactMap(\.coverId))
            if let hand = onDay.filter({ $0.source != .timeline && $0.at >= b.placedAt && !used.contains($0.id) })
                .min(by: { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }) {
                return .cover(hand.id)
            }
            return .tick
        }
        // A once-task or link done on any day, or a habit ticked on the block's day.
        let done = item.kind == .once || item.kind == .link ? progress > 0 : !onDay.isEmpty
        return done ? .skip : .tick
    }

    /// One block's end (SPEC 2026-11-10). A hand block ticks, or skips when the task
    /// needs nothing, or is covered by a hand tick. A slot block never ticks: where a
    /// hand block would tick it asks "Done?" (only while the timeline shows), and any
    /// later hand tick answers it; its question ends at the rollover. Returns whether
    /// anything was written.
    private func decide(_ block: TimeBlock, now: Date, zone: TimeZone, today: LocalDay, asks: Bool,
                        _ w: any StoreWriter) throws -> Bool {
        var b = block
        b.updatedAt = now
        guard let item = try w.item(id: b.itemId), item.deletedAt == nil, item.state == .active else {
            b.removedAt = now
            try w.save(b)
            return true
        }
        let result = try outcome(b, item: item, w)
        if b.origin == .slot {
            switch result {
            case .skip:
                b.decidedAt = now
            case .cover(let id):
                b.coverId = id
                b.decidedAt = now
            case .tick where b.localDay < today:
                b.decidedAt = now               // the question ends at the rollover
            case .tick:
                guard asks, b.askedAt == nil else { return false }
                b.askedAt = now
            }
            try w.save(b)
            return true
        }
        b.decidedAt = now
        switch result {
        case .skip: break
        case .cover(let id): b.coverId = id
        case .tick:
            let tick = CheckIn(id: newID(), itemId: b.itemId, localDay: b.localDay, at: now,
                               timeZoneId: zone.identifier, amount: 1, source: .timeline)
            try w.insert(tick)
            b.tickId = tick.id
        }
        try w.save(b)
        return true
    }

    // MARK: - Time slots (SPEC 2026-11-10)

    /// Where `slot` falls on `day`: its wall-clock start (a time a DST change skipped
    /// moves to the first time after the gap), cut at the day's end. Nil when nothing of
    /// it fits.
    public func slotPlacement(_ slot: TimeSlot, on day: LocalDay) -> (start: Date, minutes: Int)? {
        let zone = zonesForQueries.current()
        var start = day.instant(at: slot.time, in: zone, rolloverHour: rolloverHour)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let wall = calendar.dateComponents([.hour, .minute], from: start)
        if wall.hour != slot.hour || wall.minute != slot.minute,
           let gapEnd = zone.nextDaylightSavingTimeTransition(after: start.addingTimeInterval(-4 * 3600)),
           gapEnd <= start {
            start = gapEnd
        }
        let bounds = dayBounds(day)
        let room = Int(bounds.end.timeIntervalSince(start) / 60)
        let minutes = min(slot.minutes, room / Self.blockStepMinutes * Self.blockStepMinutes)
        guard (try? Self.checkStart(start, bounds)) != nil, minutes >= Self.blockStepMinutes else { return nil }
        return (start, minutes)
    }

    /// Places today's slot blocks: a task with a slot, on Today and still needing
    /// something, whose slot has not started, and that has had no block today.
    private func placeSlotBlocks(rows: [TodayRow], today: LocalDay, now: Date, _ w: any StoreWriter) throws -> Bool {
        let had = Set(try w.timeBlocks(from: today).filter { $0.localDay == today }.map(\.itemId))
        var changed = false
        for row in rows where row.item.slot != nil && !had.contains(row.id) {
            let needs = row.item.progress.target != nil ? !row.isGoalReached : !row.isDone
            guard needs, let slot = row.item.slot, let place = slotPlacement(slot, on: today), place.start > now
            else { continue }
            try w.save(TimeBlock(id: newID(), itemId: row.id, localDay: today, start: place.start,
                                 minutes: place.minutes, placedAt: now, updatedAt: now, origin: .slot))
            changed = true
        }
        return changed
    }

    /// Edit changed a task's slot: today's slot block follows only if it is untouched
    /// and has not started (moved to the new slot, or removed if that has started or
    /// the slot is off). Called inside Edit's write.
    func slotChanged(_ item: Item, now: Date, _ w: any StoreWriter) throws {
        let today = LocalDay(of: now, in: zonesForQueries.current(), rolloverHour: rolloverHour)
        guard var b = try w.timeBlocks(from: today).first(where: {
            $0.itemId == item.id && $0.localDay == today && $0.origin == .slot && $0.removedAt == nil
        }), b.touchedAt == nil, b.start > now else { return }
        if let slot = item.slot, let place = slotPlacement(slot, on: today), place.start > now {
            b.start = place.start
            b.minutes = place.minutes
        } else {
            b.removedAt = now
        }
        b.updatedAt = now
        try w.save(b)
    }

    /// The notification's Done on an asking (or still waiting) slot block of today: a
    /// hand tick, which answers it. Never for an earlier day.
    public func answerSlotBlock(id: UUID, source: Source = .notification) throws {
        let today = currentDay()
        guard let b = try storeForQueries.read({ try $0.timeBlock(id: id) }), b.origin == .slot,
              b.localDay == today, b.removedAt == nil, b.decidedAt == nil else { throw ClewError.notAllowed }
        do {
            _ = try checkIn(itemId: b.itemId, source: source)
        } catch ClewError.goalReached {}
        try settleBlocks()
    }

    /// Today's slot blocks asking "Done?": their delivered notifications stay; others go.
    public func askingBlockIds() throws -> Set<UUID> {
        let today = currentDay()
        return try storeForQueries.read { r in
            Set(try r.timeBlocks(from: today).filter {
                $0.localDay == today && $0.removedAt == nil && $0.decidedAt == nil && $0.askedAt != nil
            }.map(\.id))
        }
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
            // A reached goal stays in the list until a next round or a higher target.
            guard let row = try todayList(w, on: today).rows.first(where: { $0.id == itemId }), !row.isGoalReached else {
                throw ClewError.notAllowed
            }
            let open = try w.timeBlocks(from: today)
                .filter { $0.itemId == itemId && $0.localDay == today && $0.removedAt == nil && $0.end > now }
                .min { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
            let room = Int(bounds.end.timeIntervalSince(start) / 60)
            if let open {
                // Its length goes with it, cut at the day's end like a new block's.
                return try change(open, start: start, minutes: minutes ?? min(open.minutes, room), today: today,
                                  now: now, w)
            }
            let length = minutes ?? min(Self.blockDefaultMinutes, room)
            try Self.checkLength(length, start: start, bounds)
            let block = TimeBlock(id: newID(), itemId: itemId, localDay: today, start: start, minutes: length,
                                  placedAt: now, updatedAt: now)
            try w.save(block)
            return try decideIfEnded(block, now: now, w)
        }
    }

    /// A double-click on the timeline (SPEC 2026-11-13): a today task and its 30-minute
    /// block at `start` (cut at the day's end), in one write, so nothing is half made. A
    /// block that has already ended decides at once, as a dropped row's does.
    @discardableResult
    public func addOnTimeline(title: String, titleOrigin: TitleOrigin = .typed, url: URL? = nil,
                              start: Date) throws -> (item: Item, block: TimeBlock) {
        // One clock read: the task's day and the block's day are the same day.
        let now = clockForQueries.now()
        let today = LocalDay(of: now, in: zonesForQueries.current(), rolloverHour: rolloverHour)
        let bounds = dayBounds(today)
        try Self.checkStart(start, bounds)
        // 15 or 30: a start on a quarter hour inside the day always leaves room for that.
        let length = min(Self.blockDefaultMinutes, Int(bounds.end.timeIntervalSince(start) / 60))
        return try storeForQueries.write { w in
            let item = try insertNewItem(NewItem(title: title, titleOrigin: titleOrigin, url: url, shape: .today),
                                         source: .user, now: now, day: today, w)
            let block = TimeBlock(id: newID(), itemId: item.id, localDay: today, start: start, minutes: length,
                                  placedAt: now, updatedAt: now)
            try w.save(block)
            return (item, try decideIfEnded(block, now: now, w))
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
            b.touchedAt = now
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
    /// Settings › General › Day timeline › "Block alerts": a block's start, and a slot
    /// block's "Done?" (default on).
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
        } + slotQuestions(r, now: now, today: today, rows: rows)
    }

    /// "Done with Write intro?" at the end of each of today's slot blocks still waiting,
    /// while the timeline shows and the task still needs something.
    private func slotQuestions(_ r: any StoreReader, now: Date, today: LocalDay,
                               rows: [UUID: TodayRow]) throws -> [PlannedNotification] {
        guard try r.setting(Self.timelineShownKey) != "false" else { return [] }
        return try r.timeBlocks(from: today).compactMap { b in
            guard b.localDay == today, b.origin == .slot, b.removedAt == nil, b.decidedAt == nil, b.end > now,
                  let row = rows[b.itemId], row.item.progress.target != nil ? !row.isGoalReached : !row.isDone
            else { return nil }
            return PlannedNotification(id: NotificationPlanner.idPrefix + "ask." + b.id.uuidString, fireAt: b.end,
                                       content: .slotAsks(blockId: b.id, itemId: b.itemId, title: row.item.title,
                                                          isGoal: row.item.progress.target != nil))
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
        b.askedAt = nil             // a moved slot block asks again at its new end
        b.touchedAt = now           // today's own now: Edit no longer moves it
        b.releasedAt = nil          // placed again: the task lives on the timeline again
        b.updatedAt = now
        try w.save(b)
        return try decideIfEnded(b, now: now, w)
    }

    private func decideIfEnded(_ b: TimeBlock, now: Date, _ w: any StoreWriter) throws -> TimeBlock {
        guard b.end <= now else { return b }
        _ = try decide(b, now: now, zone: zonesForQueries.current(), today: b.localDay,
                       asks: try w.setting(Self.timelineShownKey) != "false", w)
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

    /// Where a dragged block starts when its top is `minutesIn` after the day's start (the
    /// pointer's place on the hours, less where the block was grabbed): the nearest
    /// quarter hour, kept so that the whole block fits in the day. Measured on the hours,
    /// not from how far the pointer moved, so it stays under the pointer while the
    /// timeline scrolls (user, 2026-11-10).
    public static func blockStart(minutesIn: Double, minutes: Int, day: TimelineDay) -> Date {
        let length = Int(day.end.timeIntervalSince(day.start) / 60)
        let offset = min(max(snapMinutes(minutesIn), 0), max(0, length - minutes))
        return day.start.addingTimeInterval(TimeInterval(offset * 60))
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
