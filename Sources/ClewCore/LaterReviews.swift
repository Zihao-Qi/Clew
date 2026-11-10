import ClewDomain
import Foundation

/// A Later item with how long it has waited.
public struct LaterEntry: Hashable, Sendable, Identifiable {
    public let item: Item
    public let daysWaiting: Int
    /// How much of the video was watched (0–1), if seen.
    public var watched: Double?
    /// SPEC §5: waited 6+ weeks untouched, so the picker asks "still want this?".
    public var asksStillWant: Bool { LaterAge.asksStillWant(daysWaiting: daysWaiting) }
    public var id: UUID { item.id }

    /// The site shown under a saved link's title in Pick, e.g. "medium.com". None for
    /// YouTube: those are videos, which the title already says (user, 2026-11-09).
    public var siteLabel: String? {
        guard let host = item.url?.host?.lowercased(), !host.isEmpty else { return nil }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let youTube = site == "youtube.com" || site.hasSuffix(".youtube.com") || site == "youtu.be"
        return youTube ? nil : site
    }
}

extension Clew {
    /// The Later pile, newest first, each with its waiting time. An item's clock starts
    /// when it was last touched: saved, edited, moved to Later, or kept.
    public func laterPile() throws -> [LaterEntry] {
        let zone = zonesForQueries.current()
        let today = currentDay()
        return try storeForQueries.read { r in
            let items = try r.items(inStates: [.later])
            let watched = try r.watchProgress(itemIds: items.map(\.id))
            let kept = Dictionary(grouping: try r.laterReviews(itemIds: items.map(\.id)).filter { $0.decision == .keep },
                                  by: \.itemId)
            return items
                .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
                .map { item in
                    let lastKeep = kept[item.id]?.map(\.at).max()
                    let touched = max(item.updatedAt, lastKeep ?? item.updatedAt)
                    let day = LocalDay(of: touched, in: zone, rolloverHour: rolloverHour)
                    return LaterEntry(item: item, daysWaiting: LaterAge.daysWaiting(lastTouched: day, today: today),
                                      watched: watched[item.id]?.fraction)
                }
        }
    }

    public func lettingGoCount() throws -> Int {
        try storeForQueries.read { try $0.letGoCount() }
    }

    /// "Keep": the item stays in Later and its 6 weeks start again.
    public func keepLater(itemId: UUID, source: Source = .user) throws {
        try review(itemId, .keep, source: source)
    }

    /// "Let go": a win, not a failure. Recorded as a fact, then the item is removed (a
    /// tombstone, with its reminder) in the same transaction.
    public func letGo(itemId: UUID, source: Source = .user) throws {
        try review(itemId, .letGo, source: source)
    }

    private func review(_ itemId: UUID, _ decision: LaterReview.Decision, source: Source) throws {
        let now = clockForQueries.now()
        let day = currentDay()
        try storeForQueries.write { w in
            guard var item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
            guard item.state == .later else { throw ClewError.notAllowed }
            try w.insert(LaterReview(id: newID(), itemId: itemId, decision: decision, at: now, localDay: day, source: source))
            guard decision == .letGo else { return }
            item.deletedAt = now
            item.updatedAt = now
            try w.update(item)
            if var reminder = try w.reminders().first(where: { $0.itemId == itemId }) {
                reminder.deletedAt = now
                reminder.updatedAt = now
                try w.save(reminder)
            }
        }
    }
}
