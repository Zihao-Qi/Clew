import ClewDomain
import Foundation

/// What a planned notification says. Core decides *what*; the app turns it into
/// localized text, so this stays Foundation-only and testable on Linux.
public enum PlannedContent: Hashable, Sendable {
    /// Morning summary: "6 today".
    case morning(total: Int)
    /// Evening summary on a day with ticks: "5/6 done".
    case evening(done: Int, total: Int)
    /// Evening summary on a day with no ticks: one of the curated, kind lines
    /// (AGENT §6), never "0/6". Pre-scheduled for every future evening, so a static
    /// "0/6 done" can never fire (ARCHITECTURE §6).
    case eveningKindLine(index: Int)
    case reminder(itemId: UUID, title: String, canOpen: Bool, canMoveToLater: Bool)
    /// Focus time on a task is up (SPEC 2026-11-10).
    case focusEnded(itemId: UUID, title: String)
    /// The 5-minute break is over.
    case breakEnded(title: String)
}

public struct PlannedNotification: Hashable, Sendable {
    /// Stable, so re-planning replaces instead of duplicating.
    public let id: String
    public let fireAt: Date
    public let content: PlannedContent

    public init(id: String, fireAt: Date, content: PlannedContent) {
        self.id = id
        self.fireAt = fireAt
        self.content = content
    }
}

/// The reconciler's pure half (ARCHITECTURE §6): the notifications that *should* be
/// pending for a rolling window of days, computed from reminders, due state and
/// summary settings. The app diffs this against what is actually pending.
public enum NotificationPlanner {
    public static let idPrefix = "clew."
    public static let windowDays = 7
    /// macOS keeps at most 64 pending notifications per app; the earliest win.
    public static let maxPending = 64
    public static let kindLineCount = 6

    public static func plan(
        now: Date, zone: TimeZone, rolloverHour: Int, items: [Item], facts: [UUID: ItemFacts],
        reminders: [Reminder], summaries: SummarySettings
    ) -> [PlannedNotification] {
        let today = LocalDay(of: now, in: zone, rolloverHour: rolloverHour)
        let remindersByItem = Dictionary(
            reminders.filter { $0.enabled && $0.deletedAt == nil }.map { ($0.itemId, $0) },
            uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b }
        )
        var planned: [PlannedNotification] = []
        for offset in 0..<windowDays {
            let day = today.adding(days: offset)
            let list = todayList(items: items, facts: facts, on: day)
            func add(_ id: String, _ time: TimeOfDay, _ content: PlannedContent) {
                let fireAt = day.instant(at: time, in: zone, rolloverHour: rolloverHour)
                guard fireAt > now else { return }
                planned.append(PlannedNotification(id: "\(idPrefix)\(id).\(day)", fireAt: fireAt, content: content))
            }
            if list.total > 0 {
                if summaries.morningEnabled {
                    add("morning", summaries.morningTime, .morning(total: list.total))
                }
                if summaries.eveningEnabled {
                    let content: PlannedContent = list.done > 0
                        ? .evening(done: list.done, total: list.total)
                        : .eveningKindLine(index: kindLine(for: day))
                    add("evening", summaries.eveningTime, content)
                }
            }
            // A reminder fires on each day its item is on the list and not done yet.
            for row in list.rows where row.state == .due {
                guard let reminder = remindersByItem[row.id] else { continue }
                let item = row.item
                add("reminder.\(item.id.uuidString)", reminder.time, .reminder(
                    itemId: item.id, title: item.title, canOpen: item.url != nil,
                    canMoveToLater: item.kind == .once || item.kind == .link
                ))
            }
        }
        return Array(planned.sorted { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }.prefix(maxPending))
    }

    /// Rotates through the kind lines so two evenings in a row never repeat.
    public static func kindLine(for day: LocalDay) -> Int {
        ((day.ordinal % kindLineCount) + kindLineCount) % kindLineCount
    }

    /// What to remove and add so that `pending` becomes `desired`. Each side maps a
    /// notification id to a fingerprint of its time and text; ids outside Clew's
    /// prefix are never touched.
    public static func diff(desired: [String: String], pending: [String: String]) -> (remove: [String], add: [String]) {
        let ours = pending.filter { $0.key.hasPrefix(idPrefix) }
        let remove = ours.filter { desired[$0.key] != $0.value }.map(\.key).sorted()
        let add = desired.filter { ours[$0.key] != $0.value }.map(\.key).sorted()
        return (remove, add)
    }
}
