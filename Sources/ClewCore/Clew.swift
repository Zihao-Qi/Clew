import ClewDomain
import Foundation

public enum ClewError: Error, Equatable, Sendable {
    case emptyTitle
    case titleTooLong(max: Int)
    case invalidURL
    case invalidTarget
    case invalidSchedule
    case pickCount
    /// A counted goal has reached its target: start a next round or raise it first.
    case goalReached
    case itemNotFound
    case checkInNotFound
    /// The command does not apply to this item in its current kind or state.
    case notAllowed
    /// An import batch is larger than any list the site offers.
    case tooManyEntries(max: Int)
}

/// What the user chose in `+ add`. Each case is a valid shape, so invalid
/// kind/schedule combinations cannot be expressed.
public enum NewItemShape: Hashable, Sendable {
    /// A once-item for today.
    case today
    /// Into the Later pile: a `link` if it has a URL, otherwise a `once`.
    case later
    case habit(Schedule)
    case goal(target: Int, schedule: Schedule)
}

public struct NewItem: Hashable, Sendable {
    public var title: String
    public var titleOrigin: TitleOrigin
    public var url: URL?
    public var shape: NewItemShape

    public init(title: String, titleOrigin: TitleOrigin = .typed, url: URL? = nil, shape: NewItemShape) {
        self.title = title
        self.titleOrigin = titleOrigin
        self.url = url
        self.shape = shape
    }
}

/// The editable fields of an item, as a full replacement. `schedule` applies to
/// habits and goals, `target` to goals; both must be nil otherwise.
public struct ItemEdit: Hashable, Sendable {
    public var title: String
    public var url: URL?
    public var schedule: Schedule?
    public var target: Int?

    public init(title: String, url: URL?, schedule: Schedule? = nil, target: Int? = nil) {
        self.title = title
        self.url = url
        self.schedule = schedule
        self.target = target
    }
}

/// The command and query layer (ARCHITECTURE §5). Every mutation is a named command
/// with validation, one transaction and an attributed `source`. Every client (UI,
/// notifications, later the Gateway) goes through here.
public final class Clew: Sendable {
    public static let maxTitleLength = 200
    public static let maxTarget = 100_000
    public static let maxPicks = 3

    private let store: any ClewStore
    private let clock: any Clock
    var storeForQueries: any ClewStore { store }
    var clockForQueries: any Clock { clock }
    var zonesForQueries: any TimeZoneSource { zones }
    func newID() -> UUID { makeID() }
    private let zones: any TimeZoneSource
    private let makeID: @Sendable () -> UUID
    /// Day rollover hour (default 04:00, ARCHITECTURE §4.3).
    public let rolloverHour: Int

    public init(
        store: any ClewStore, clock: any Clock, zones: any TimeZoneSource,
        rolloverHour: Int = 4, makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        precondition((0...23).contains(rolloverHour))
        self.store = store
        self.clock = clock
        self.zones = zones
        self.rolloverHour = rolloverHour
        self.makeID = makeID
    }

    // MARK: - Time

    public func currentDay() -> LocalDay {
        LocalDay(of: clock.now(), in: zones.current(), rolloverHour: rolloverHour)
    }

    public func nextRolloverInstant() -> Date {
        nextRollover(after: clock.now(), in: zones.current(), rolloverHour: rolloverHour)
    }

    // MARK: - Queries

    public func today() throws -> TodayList {
        let day = currentDay()
        return try store.read { r in
            let items = try r.items(inStates: [.active]).filter { !Self.isCollectionItem($0) }
            let ids = items.map(\.id)
            let recent = Dictionary(grouping: try r.checkIns(itemIds: ids, from: day.weekStart), by: \.itemId)
            let progress = try r.progressAmounts(itemIds: ids)
            let rounds = try r.roundStarts(itemIds: ids)
            var facts: [UUID: ItemFacts] = [:]
            for id in ids {
                facts[id] = ItemFacts(recent: recent[id] ?? [], progressAmount: progress[id] ?? 0, roundStart: rounds[id])
            }
            return todayList(items: items, facts: facts, on: day)
        }
    }

    /// One item by id, if it exists and is not deleted.
    public func item(id: UUID) throws -> Item? {
        try store.read { try $0.item(id: id) }.flatMap { $0.deletedAt == nil ? $0 : nil }
    }

    /// The Later pile, newest first. Its contents are shown only when picking.
    public func laterItems() throws -> [Item] {
        try store.read { r in
            try r.items(inStates: [.later]).filter { !Self.isCollectionItem($0) }.sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
        }
    }

    public func laterCount() throws -> Int {
        try store.read { try $0.items(inStates: [.later]).filter { !Self.isCollectionItem($0) }.count }
    }

    public func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> any StoreObservation {
        store.observeChanges(onChange)
    }

    // MARK: - Commands

    @discardableResult
    public func addItem(_ new: NewItem, source: Source = .user) throws -> Item {
        let title = try Self.validTitle(new.title)
        let url = try new.url.map(Self.validURL)
        let now = clock.now()
        let day = currentDay()

        let kind: ItemKind, schedule: Schedule, progress: ProgressSpec, state: ItemState, planned: LocalDay?
        switch new.shape {
        case .today:
            (kind, schedule, progress, state, planned) = (.once, .unscheduled, .none, .active, day)
        case .later:
            (kind, schedule, progress, state, planned) = (url == nil ? .once : .link, .unscheduled, .none, .later, nil)
        case .habit(let s):
            (kind, schedule, progress, state, planned) = (.habit, try Self.validSchedule(s), .none, .active, nil)
        case .goal(let target, let s):
            (kind, schedule, progress, state, planned) =
                (.goal, try Self.validSchedule(s), .counter(target: try Self.validTarget(target)), .active, nil)
        }

        return try store.write { w in
            let item = Item(
                id: makeID(), kind: kind, title: title, titleOrigin: new.titleOrigin, url: url,
                schedule: schedule, progress: progress,
                state: state, plannedDay: planned, sortKey: (try w.maxSortKey() ?? 0) + 1, source: source,
                createdAt: now, updatedAt: now
            )
            try w.insert(item)
            return item
        }
    }

    @discardableResult
    public func editItem(id: UUID, _ edit: ItemEdit) throws -> Item {
        let title = try Self.validTitle(edit.title)
        let url = try edit.url.map(Self.validURL)
        let now = clock.now()
        return try store.write { w in
            guard var item = try w.item(id: id), item.deletedAt == nil else { throw ClewError.itemNotFound }
            switch item.kind {
            case .once, .link:
                guard edit.schedule == nil, edit.target == nil else { throw ClewError.notAllowed }
            case .habit:
                guard edit.target == nil, let s = edit.schedule else { throw ClewError.invalidSchedule }
                item.schedule = try Self.validSchedule(s)
            case .goal:
                guard let s = edit.schedule else { throw ClewError.invalidSchedule }
                guard let t = edit.target else { throw ClewError.invalidTarget }
                item.schedule = try Self.validSchedule(s)
                item.progress = .counter(target: try Self.validTarget(t))
            }
            if title != item.title { item.titleOrigin = .typed }
            item.title = title
            item.url = url
            item.updatedAt = now
            try w.update(item)
            return item
        }
    }

    /// One click on `○`. Once-items and habits record at most one check-in per day,
    /// so a double click is harmless. A counted goal records `+1` every time until
    /// its target is reached; then the user chooses a next round or a higher target.
    @discardableResult
    public func checkIn(itemId: UUID, source: Source = .user) throws -> CheckIn {
        let now = clock.now()
        let zone = zones.current()
        let day = LocalDay(of: now, in: zone, rolloverHour: rolloverHour)
        return try store.write { w in
            guard let item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
            // Today's items, and a collection's videos and posts, ticked from its page.
            guard item.state == .active || Self.isCollectionItem(item) else { throw ClewError.notAllowed }
            if let target = item.progress.target {
                if (try w.progressAmounts(itemIds: [itemId])[itemId] ?? 0) >= target {
                    throw ClewError.goalReached
                }
            } else {
                if let existing = try w.checkIns(itemIds: [itemId], from: day).first(where: { $0.localDay == day }) {
                    return existing
                }
                if item.kind == .once || item.kind == .link,
                   (try w.progressAmounts(itemIds: [itemId])[itemId] ?? 0) > 0 {
                    throw ClewError.notAllowed // already done on an earlier day
                }
            }
            let checkIn = CheckIn(
                id: makeID(), itemId: itemId, localDay: day, at: now, timeZoneId: zone.identifier,
                amount: 1, source: source
            )
            try w.insert(checkIn)
            return checkIn
        }
    }

    /// Undo: voids the most recent of today's check-ins for the item. For a goal that
    /// is one `+1` of the current round. Returns nil if there was nothing to undo today.
    @discardableResult
    public func undoToday(itemId: UUID) throws -> CheckIn? {
        let now = clock.now()
        let day = currentDay()
        return try store.write { w in
            let roundStart = try w.roundStarts(itemIds: [itemId])[itemId]
            let todays = try w.checkIns(itemIds: [itemId], from: day)
                .filter { c in c.localDay == day && (roundStart.map { c.at >= $0 } ?? true) }
            guard let last = todays.max(by: { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }) else {
                return nil
            }
            try w.voidCheckIn(id: last.id, at: now, reason: "undo")
            return try w.checkIn(id: last.id)
        }
    }

    /// Voids one check-in. Voids are monotonic, so voiding an already voided
    /// check-in changes nothing.
    public func voidCheckIn(id: UUID, reason: String) throws {
        let now = clock.now()
        try store.write { w in
            guard let checkIn = try w.checkIn(id: id) else { throw ClewError.checkInNotFound }
            guard !checkIn.isVoided else { return }
            try w.voidCheckIn(id: id, at: now, reason: reason)
        }
    }

    /// "Pick 1–3 for today": moves Later items onto Today's list and records a
    /// `Plan` fact for each, so pick history survives later re-planning.
    public func planForToday(itemIds: [UUID], source: Source = .user) throws {
        var seen = Set<UUID>()
        let ids = itemIds.filter { seen.insert($0).inserted }
        guard (1...Self.maxPicks).contains(ids.count) else { throw ClewError.pickCount }
        let now = clock.now()
        let day = currentDay()
        try store.write { w in
            var sortKey = (try w.maxSortKey() ?? 0)
            for id in ids {
                guard var item = try w.item(id: id), item.deletedAt == nil else { throw ClewError.itemNotFound }
                // A collection's items stay in their collection (SPEC 2026-11-09).
                guard item.state == .later, !Self.isCollectionItem(item) else { throw ClewError.notAllowed }
                sortKey += 1
                item.state = .active
                item.plannedDay = day
                item.sortKey = sortKey
                item.updatedAt = now
                try w.update(item)
                try w.insert(Plan(id: makeID(), itemId: id, localDay: day, at: now, source: source))
            }
        }
    }

    /// Distractibility delay: an unfinished once-item or link goes back to Later.
    /// Habits and goals cannot; they are paused or archived instead.
    public func moveToLater(itemId: UUID) throws {
        let now = clock.now()
        try store.write { w in
            guard var item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
            guard item.kind == .once || item.kind == .link, item.state == .active,
                  (try w.progressAmounts(itemIds: [itemId])[itemId] ?? 0) == 0
            else { throw ClewError.notAllowed }
            item.state = .later
            item.plannedDay = nil
            item.updatedAt = now
            try w.update(item)
        }
    }

    /// "Next round" after a counted goal reached its target: the bar starts again
    /// from zero with the same target. Earlier rounds stay in the history.
    @discardableResult
    public func startNextRound(itemId: UUID, source: Source = .user) throws -> GoalRound {
        let now = clock.now()
        let day = currentDay()
        return try store.write { w in
            guard let item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
            guard item.state == .active, let target = item.progress.target,
                  (try w.progressAmounts(itemIds: [itemId])[itemId] ?? 0) >= target
            else { throw ClewError.notAllowed }
            let round = GoalRound(id: makeID(), itemId: itemId, startedAt: now, localDay: day, target: target,
                                  source: source)
            try w.insert(round)
            return round
        }
    }

    /// Manual order: puts the item between two neighbours (either may be nil at the
    /// ends of the list) by giving it a sort key between theirs. Only this item's row
    /// changes; nothing else is renumbered.
    public func moveItem(id: UUID, after above: UUID?, before below: UUID?) throws {
        let now = clock.now()
        try store.write { w in
            guard var item = try w.item(id: id), item.deletedAt == nil else { throw ClewError.itemNotFound }
            func key(_ neighbour: UUID?) throws -> Double? {
                guard let neighbour else { return nil }
                guard neighbour != id, let other = try w.item(id: neighbour), other.deletedAt == nil else {
                    throw ClewError.notAllowed
                }
                return other.sortKey
            }
            let low = try key(above), high = try key(below)
            switch (low, high) {
            case let (low?, high?):
                guard low < high else { throw ClewError.notAllowed }
                let middle = (low + high) / 2
                if low < middle, middle < high {
                    item.sortKey = middle
                } else {
                    // Out of floating-point room (about 50 moves into one gap): renumber
                    // every item 1, 2, 3… in its current order, then place this one.
                    try Self.renumber(w, now: now)
                    let fresh = try w.item(id: above!)!.sortKey
                    item.sortKey = fresh + 0.5
                }
            case let (low?, nil): item.sortKey = low + 1
            case let (nil, high?): item.sortKey = high - 1
            case (nil, nil): return
            }
            item.updatedAt = now
            try w.update(item)
        }
    }

    private static func renumber(_ w: any StoreWriter, now: Date) throws {
        // Only the active list: Later items get a fresh place when picked, and touching
        // their updatedAt would restart their "still want this?" 6 weeks.
        let all = try w.items(inStates: [.active]).filter { !Self.isCollectionItem($0) }
            .sorted { ($0.sortKey, $0.createdAt, $0.id.uuidString) < ($1.sortKey, $1.createdAt, $1.id.uuidString) }
        for (index, var other) in all.enumerated() where other.sortKey != Double(index + 1) {
            other.sortKey = Double(index + 1)
            other.updatedAt = now
            try w.update(other)
        }
    }

    /// Where a dragged row would land: the index of the row (in the list as it was when
    /// the drag began) under the pointer. Above the first row is 0, below the last is
    /// the last index. `spans` are each row's (minY, maxY), top to bottom.
    public static func dragSlot(pointerY: Double, spans: [(minY: Double, maxY: Double)]) -> Int? {
        guard let first = spans.first, let last = spans.last else { return nil }
        if pointerY < first.minY { return 0 }
        if pointerY >= last.maxY { return spans.count - 1 }
        return spans.firstIndex { $0.minY <= pointerY && pointerY < $0.maxY }
    }

    /// Keeps a dragged row inside the list: it may move up until its top meets the first
    /// row's top, and down until its bottom meets the last row's bottom (never over the
    /// footer).
    public static func clampDrag(translation: Double, row: (minY: Double, maxY: Double),
                                 list: (minY: Double, maxY: Double)) -> Double {
        min(max(translation, list.minY - row.minY), list.maxY - row.maxY)
    }

    /// How far row `index` slides while the row at `from` is dragged to slot `to`: the
    /// rows in between make room by the dragged row's height, the rest stay put.
    public static func dragShift(index: Int, from: Int, to: Int, draggedHeight: Double) -> Double {
        if from < to, index > from, index <= to { return -draggedHeight }
        if to < from, index >= to, index < from { return draggedHeight }
        return 0
    }

    /// Where a dragged row lands when dropped onto `target` in `order` (today's visible
    /// ids): it takes the target's place, so coming from above it goes after the target
    /// and from below it goes before. Nil when the drop changes nothing.
    public static func dropNeighbours(dragged: UUID, onto target: UUID, in order: [UUID]) -> (after: UUID?, before: UUID?)? {
        guard dragged != target, let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return nil }
        return from < to
            ? (target, to + 1 < order.count ? order[to + 1] : nil)
            : (to > 0 ? order[to - 1] : nil, target)
    }

    /// Delete: a tombstone (`deletedAt`), never a hard delete. The item disappears
    /// everywhere; its check-ins and plans stay in the history (ARCHITECTURE §8).
    public func deleteItem(itemId: UUID) throws {
        let now = clock.now()
        try store.write { w in
            guard var item = try w.item(id: itemId) else { throw ClewError.itemNotFound }
            guard item.deletedAt == nil else { return }
            item.deletedAt = now
            item.updatedAt = now
            try w.update(item)
            // Its reminder goes with it, in the same transaction.
            if var reminder = try w.reminders().first(where: { $0.itemId == itemId }) {
                reminder.deletedAt = now
                reminder.updatedAt = now
                try w.save(reminder)
            }
        }
    }

    public func archive(itemId: UUID) throws {
        let now = clock.now()
        try store.write { w in
            guard var item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
            guard item.state != .archived else { return }
            item.state = .archived
            item.updatedAt = now
            try w.update(item)
        }
    }

    // MARK: - Validation

    static func validTitle(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ClewError.emptyTitle }
        guard title.count <= maxTitleLength else { throw ClewError.titleTooLong(max: maxTitleLength) }
        return title
    }

    /// Only web links: `↗` opens them in the browser, and nothing else should open.
    static func validURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { throw ClewError.invalidURL }
        return url
    }

    static func validTarget(_ target: Int) throws -> Int {
        guard (1...maxTarget).contains(target) else { throw ClewError.invalidTarget }
        return target
    }

    static func validSchedule(_ schedule: Schedule) throws -> Schedule {
        switch schedule {
        case .daily: return schedule
        case .weekdays(let days): guard !days.isEmpty else { throw ClewError.invalidSchedule }
        case .timesPerWeek(let n): guard (1...7).contains(n) else { throw ClewError.invalidSchedule }
        case .unscheduled: throw ClewError.invalidSchedule
        }
        return schedule
    }
}
