import ClewDomain
import Foundation

/// Everything the details page shows for one item.
public struct ItemDetails: Hashable, Sendable {
    public let item: Item
    public let today: LocalDay
    public let stats: ItemStats
    /// Progress in the current round, for a goal.
    public let progressAmount: Int
    public let reminder: Reminder?
    /// How much of the video was watched, as last seen on Watch Later.
    public let watch: WatchProgress?
    /// For one-off items (once-tasks and saved links), what happened to it, oldest
    /// first, at most the last `Clew.historyLength`. Empty for habits and goals, whose
    /// page shows the heatmap instead.
    public let history: [HistoryEntry]
    /// The day a Later task waits for (SPEC 2026-11-17): "Comes to Today Thu, Nov 20".
    public var waitingFor: LocalDay?

    /// Once-tasks and saved links: a status and a short history, not a heatmap.
    public var isOneOff: Bool { item.kind == .once || item.kind == .link }
}

/// One line of a one-off item's history.
public struct HistoryEntry: Hashable, Sendable {
    public enum Event: Hashable, Sendable {
        /// Saved, by the user or by an import (`Source`).
        case added(Source)
        case picked
        /// Ticked, with the rating the user gave it, if any.
        case done(rating: Int?)
        /// "Still want this?" answered Keep.
        case kept
    }

    public let at: Date
    public let event: Event

    public init(at: Date, event: Event) {
        self.at = at
        self.event = event
    }
}

extension Clew {
    /// Weeks in the details heatmap: 16 columns fit the 340 pt list window.
    public static let heatmapWeeks = 16
    /// Lines of history on a one-off item's page: enough for its whole life, short
    /// enough to fit the list window.
    public static let historyLength = 6

    /// The latest watch fraction (0–1) of each of these items; missing means none seen.
    public func watchProgress(itemIds: [UUID]) throws -> [UUID: Double] {
        try storeForQueries.read { try $0.watchProgress(itemIds: itemIds).mapValues(\.fraction) }
    }

    public func details(itemId: UUID) throws -> ItemDetails? {
        let today = currentDay()
        return try storeForQueries.read { r in
            guard let item = try r.item(id: itemId), item.deletedAt == nil else { return nil }
            let allTime = LocalDay(year: 1, month: 1, day: 1)!
            let checkIns = try r.checkIns(itemIds: [itemId], from: allTime)
            let progress = try r.progressAmounts(itemIds: [itemId])[itemId] ?? 0
            let stats = ItemStats(item: item, checkIns: checkIns, rounds: try r.goalRounds(itemId: itemId),
                                  currentRoundAmount: progress, today: today)
            var history: [HistoryEntry] = []
            if item.kind == .once || item.kind == .link {
                history.append(HistoryEntry(at: item.createdAt, event: .added(item.source)))
                // Moved to Today: one line per day, its latest plan, live or not (a reorder
                // re-inserts the plan; moving back voids it; SPEC 2026-11-15). A day for
                // Later counts once its day has come, dated by that day; one changed or
                // removed before then never happened (SPEC 2026-11-17).
                let zone = zonesForQueries.current()
                let rollover = TimeOfDay(hour: rolloverHour, minute: 0)!
                func start(_ day: LocalDay) -> Date { day.instant(at: rollover, in: zone, rolloverHour: rolloverHour) }
                // A day after it was done (ticked while it waited) never came either.
                let doneOn = checkIns.filter { !$0.isVoided }.map(\.localDay).min()
                let came = try r.plans(itemId: itemId).filter { plan in
                    plan.localDay <= today && (plan.voidedAt.map { $0 >= start(plan.localDay) } ?? true)
                        && doneOn.map { plan.localDay <= $0 } ?? true
                }
                let plans = Dictionary(grouping: came, by: \.localDay)
                    .compactMapValues { $0.max { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) } }
                history += plans.values.map { HistoryEntry(at: max($0.at, start($0.localDay)), event: .picked) }
                history += checkIns.map { HistoryEntry(at: $0.at, event: .done(rating: $0.rating)) }
                history += try r.laterReviews(itemIds: [itemId]).filter { $0.decision == .keep }
                    .map { HistoryEntry(at: $0.at, event: .kept) }
                history = Array(history.sorted { $0.at < $1.at }.suffix(Self.historyLength))
            }
            var details = ItemDetails(item: item, today: today, stats: stats, progressAmount: progress,
                               // A spent one-day reminder shows nothing (SPEC 2026-11-15).
                               reminder: try r.reminders().first { $0.itemId == itemId && !$0.isSpent(today: today) },
                               watch: try r.watchProgress(itemIds: [itemId])[itemId], history: history)
            if item.state == .later, progress == 0 {
                details.waitingFor = try r.plans(from: today.adding(days: 1)).filter { $0.itemId == itemId }.map(\.localDay).min()
            }
            return details
        }
    }
}
