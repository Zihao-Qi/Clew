import ClewDomain
import Foundation

public enum ClewError: Error, Equatable, Sendable {
    case emptyTitle
    case titleTooLong(max: Int)
    case invalidURL
    case invalidTarget
    case invalidSchedule
    case pickCount
    case itemNotFound
    case checkInNotFound
    /// The command does not apply to this item in its current kind or state.
    case notAllowed
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
    public var url: URL?
    public var shape: NewItemShape

    public init(title: String, url: URL? = nil, shape: NewItemShape) {
        self.title = title
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
            let items = try r.items(inStates: [.active])
            let ids = items.map(\.id)
            let recent = Dictionary(grouping: try r.checkIns(itemIds: ids, from: day.weekStart), by: \.itemId)
            let lifetime = try r.lifetimeAmounts(itemIds: ids)
            var facts: [UUID: ItemFacts] = [:]
            for id in ids {
                facts[id] = ItemFacts(recent: recent[id] ?? [], lifetimeAmount: lifetime[id] ?? 0)
            }
            return todayList(items: items, facts: facts, on: day)
        }
    }

    /// The Later pile, newest first. Its contents are shown only when picking.
    public func laterItems() throws -> [Item] {
        try store.read { r in
            try r.items(inStates: [.later]).sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
        }
    }

    public func laterCount() throws -> Int {
        try store.read { try $0.items(inStates: [.later]).count }
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
                id: makeID(), kind: kind, title: title, url: url, schedule: schedule, progress: progress,
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
            item.title = title
            item.url = url
            item.updatedAt = now
            try w.update(item)
            return item
        }
    }

    /// One click on `○`. Once-items and habits record at most one check-in per day,
    /// so a double click is harmless. A counted goal records `+1` every time.
    @discardableResult
    public func checkIn(itemId: UUID, source: Source = .user) throws -> CheckIn {
        let now = clock.now()
        let zone = zones.current()
        let day = LocalDay(of: now, in: zone, rolloverHour: rolloverHour)
        return try store.write { w in
            guard let item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
            guard item.state == .active else { throw ClewError.notAllowed }
            if item.kind != .goal {
                if let existing = try w.checkIns(itemIds: [itemId], from: day).first(where: { $0.localDay == day }) {
                    return existing
                }
                if item.kind == .once || item.kind == .link,
                   (try w.lifetimeAmounts(itemIds: [itemId])[itemId] ?? 0) > 0 {
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
    /// is one `+1`. Returns nil if there was nothing to undo today.
    @discardableResult
    public func undoToday(itemId: UUID) throws -> CheckIn? {
        let now = clock.now()
        let day = currentDay()
        return try store.write { w in
            let todays = try w.checkIns(itemIds: [itemId], from: day).filter { $0.localDay == day }
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
                guard item.state == .later else { throw ClewError.notAllowed }
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
                  (try w.lifetimeAmounts(itemIds: [itemId])[itemId] ?? 0) == 0
            else { throw ClewError.notAllowed }
            item.state = .later
            item.plannedDay = nil
            item.updatedAt = now
            try w.update(item)
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
