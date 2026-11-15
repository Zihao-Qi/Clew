import ClewDomain
import Foundation

/// Last week's card (SPEC 2026-11-15): the recap of the Monday-to-Sunday before this
/// week, shown once at the top of the menu and always in Settings › Progress.
extension Clew {
    static let weekCardOnKey = "weekCard.on"
    static let weekCardShownKey = "weekCard.shown"

    /// Last week's recap for Settings › Progress: nil when nothing would show. Ignores
    /// the switch and whether the card was shown.
    public func lastWeek() throws -> WeekRecap? {
        try recap(today: currentDay())
    }

    /// The card for the menu: last week's recap, unless the switch is off or the card
    /// was already shown this week. Reads the clock once.
    public func weekCard() throws -> WeekRecap? {
        let today = currentDay()
        guard try weekCardOn() else { return nil }
        let shown = try storeForQueries.read { try $0.setting(Self.weekCardShownKey) }
        // Equality, not "on or after": a clock set back never hides another week's card.
        if shown == "\"\(today.weekStart.description)\"" { return nil }
        return try recap(today: today)
    }

    /// The card was shown: not again in the week it was shown in (the week after the
    /// recap's).
    public func markWeekCardShown(_ recap: WeekRecap) throws {
        let now = clockForQueries.now()
        let week = recap.weekStart.adding(days: 7).description
        try storeForQueries.write { try $0.saveSetting(Self.weekCardShownKey, json: "\"\(week)\"", updatedAt: now) }
    }

    /// Settings › General › "Last week's card" (default on).
    public func weekCardOn() throws -> Bool {
        try storeForQueries.read { try $0.setting(Self.weekCardOnKey) } != "false"
    }

    public func setWeekCardOn(_ on: Bool) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { try $0.saveSetting(Self.weekCardOnKey, json: on ? "true" : "false", updatedAt: now) }
    }

    private func recap(today: LocalDay) throws -> WeekRecap? {
        let monday = today.weekStart.adding(days: -7)
        let sunday = monday.adding(days: 6)
        let off = try collectionsOff()
        return try storeForQueries.read { r in
            let checkIns = try r.checkIns(from: monday, through: sunday)
            var items: [UUID: Item] = [:]
            for id in Set(checkIns.map(\.itemId)) { items[id] = try r.item(id: id) }
            let ticks = checkIns.compactMap { c in items[c.itemId].map { (checkIn: c, item: $0) } }
            // A collection item's deletedAt alone cannot tell "the user deleted it" from
            // "it left the site's list" (removed with its tick); the latest let-go can.
            var userDeleted: Set<UUID> = []
            for source in WeekRecap.collectionSources {
                let removed = items.values.filter { $0.source == source && $0.deletedAt != nil }
                let left = try Self.leftTheList(removed, source: source, r)
                userDeleted.formUnion(removed.map(\.id).filter { !left.contains($0) })
            }
            return WeekRecap.make(weekStart: monday, ticks: ticks,
                                  focus: try r.focusSessions(from: monday, through: sunday),
                                  userDeleted: userDeleted, listsOff: off)
        }
    }
}
