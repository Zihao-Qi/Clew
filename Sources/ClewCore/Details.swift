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
}

extension Clew {
    /// Weeks in the details heatmap: 16 columns fit the 340 pt list window.
    public static let heatmapWeeks = 16

    public func details(itemId: UUID) throws -> ItemDetails? {
        let today = currentDay()
        return try storeForQueries.read { r in
            guard let item = try r.item(id: itemId), item.deletedAt == nil else { return nil }
            let allTime = LocalDay(year: 1, month: 1, day: 1)!
            let checkIns = try r.checkIns(itemIds: [itemId], from: allTime)
            let progress = try r.progressAmounts(itemIds: [itemId])[itemId] ?? 0
            let stats = ItemStats(item: item, checkIns: checkIns, rounds: try r.goalRounds(itemId: itemId),
                                  currentRoundAmount: progress, today: today)
            return ItemDetails(item: item, today: today, stats: stats, progressAmount: progress,
                               reminder: try r.reminders().first { $0.itemId == itemId })
        }
    }
}
