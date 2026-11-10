import ClewDomain
import Foundation

extension Clew {
    static let summariesKey = "summaries"

    // MARK: - Queries

    public func reminder(forItem itemId: UUID) throws -> Reminder? {
        try storeForQueries.read { try $0.reminders().first { $0.itemId == itemId } }
    }

    public func summaries() throws -> SummarySettings {
        try storeForQueries.read { r in
            guard let json = try r.setting(Self.summariesKey) else { return .defaults }
            return try JSONDecoder().decode(SummarySettings.self, from: Data(json.utf8))
        }
    }

    /// Whether anything could ever notify: used to ask for permission only when needed.
    public func wantsNotifications() throws -> Bool {
        let s = try summaries()
        let anyReminder = try storeForQueries.read { r in
            let live = Set(try r.items(inStates: [.active, .later, .paused]).map(\.id))
            return try r.reminders().contains { $0.enabled && live.contains($0.itemId) }
        }
        return s.morningEnabled || s.eveningEnabled || anyReminder
    }

    /// The notifications that should be pending now (ARCHITECTURE §6).
    public func plannedNotifications() throws -> [PlannedNotification] {
        let now = clockForQueries.now()
        let zone = zonesForQueries.current()
        let today = LocalDay(of: now, in: zone, rolloverHour: rolloverHour)
        let summaries = try summaries()
        return try storeForQueries.read { r in
            let items = try r.items(inStates: [.active]).filter { !Self.isCollectionItem($0) }
            let ids = items.map(\.id)
            let recent = Dictionary(grouping: try r.checkIns(itemIds: ids, from: today.weekStart), by: \.itemId)
            let progress = try r.progressAmounts(itemIds: ids)
            let rounds = try r.roundStarts(itemIds: ids)
            var facts: [UUID: ItemFacts] = [:]
            for id in ids {
                facts[id] = ItemFacts(recent: recent[id] ?? [], progressAmount: progress[id] ?? 0, roundStart: rounds[id])
            }
            let planned = NotificationPlanner.plan(
                now: now, zone: zone, rolloverHour: rolloverHour, items: items, facts: facts,
                reminders: try r.reminders(), summaries: summaries
            )
            // The running timer's end comes first: it is minutes away and asked for.
            guard let focus = try focusNotification(r, now: now) else { return planned }
            return [focus] + planned.prefix(NotificationPlanner.maxPending - 1)
        }
    }

    // MARK: - Commands

    /// Sets the item's one reminder to `time`, or removes it (a tombstone) when nil.
    @discardableResult
    public func setReminder(itemId: UUID, time: TimeOfDay?) throws -> Reminder? {
        let now = clockForQueries.now()
        return try storeForQueries.write { w in
            guard let item = try w.item(id: itemId), item.deletedAt == nil else { throw ClewError.itemNotFound }
            let existing = try w.reminders().first { $0.itemId == itemId }
            guard let time else {
                guard var gone = existing else { return nil }
                gone.deletedAt = now
                gone.updatedAt = now
                try w.save(gone)
                return nil
            }
            var reminder = existing ?? Reminder(id: newID(), itemId: itemId, time: time, updatedAt: now)
            reminder.time = time
            reminder.enabled = true
            reminder.updatedAt = now
            try w.save(reminder)
            return reminder
        }
    }

    public func setSummaries(_ settings: SummarySettings) throws {
        let now = clockForQueries.now()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(settings), as: UTF8.self)
        try storeForQueries.write { try $0.saveSetting(Self.summariesKey, json: json, updatedAt: now) }
    }
}
