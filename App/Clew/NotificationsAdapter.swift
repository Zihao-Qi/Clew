import AppKit
import ClewCore
import ClewDomain
import Foundation
import UserNotifications

/// The reconciler's AppKit half (ARCHITECTURE §6). Core plans *what* should be pending;
/// this turns the plan into localized requests, diffs it against what is actually
/// pending, and changes only the difference. It schedules nothing on its own.
@MainActor
final class NotificationsAdapter: NSObject, UNUserNotificationCenterDelegate {
    /// `answer`: Done (or +1) on a slot block's "Done?", by block, so it never ticks a
    /// later day (SPEC 2026-11-10).
    enum Action: Sendable { case done(UUID), later(UUID), open(UUID), answer(UUID) }

    private let center = UNUserNotificationCenter.current()
    private let onAction: @MainActor (Action) -> Void
    private var running: Task<Void, Never>?
    private var queued: [PlannedNotification]?

    init(onAction: @escaping @MainActor (Action) -> Void) {
        self.onAction = onAction
        super.init()
        center.delegate = self
        center.setNotificationCategories(Self.categories)
    }

    // MARK: Permission

    /// Asked only when the user first turns on a summary or a reminder.
    func requestPermission() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    func isDenied() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Reconcile

    /// Runs one reconcile at a time; a plan that arrives meanwhile replaces any queued one.
    func reconcile(_ plan: [PlannedNotification]) {
        queued = plan
        guard running == nil else { return }
        running = Task { [weak self] in
            while let self, let next = self.queued {
                self.queued = nil
                await self.apply(next)
            }
            self?.running = nil
        }
    }

    /// Debug self-test hook: what `apply` changed last time.
    private(set) var lastChange: (removed: [String], added: [String]) = ([], [])

    func applyNow(_ plan: [PlannedNotification]) async { await apply(plan) }

    func pendingIds() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier).sorted()
    }

    private func apply(_ plan: [PlannedNotification]) async {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        var desired: [String: UNNotificationRequest] = [:]
        for planned in plan {
            desired[planned.id] = request(for: planned)
        }
        let pending = await center.pendingNotificationRequests()
        let pendingPrints = Dictionary(
            pending.map { ($0.identifier, $0.content.userInfo["fp"] as? String ?? "") },
            uniquingKeysWith: { a, _ in a }
        )
        let desiredPrints = desired.mapValues { $0.content.userInfo["fp"] as? String ?? "" }
        let (remove, add) = NotificationPlanner.diff(desired: desiredPrints, pending: pendingPrints)
        lastChange = (remove, add)
        if !remove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: remove)
        }
        for id in add {
            if let request = desired[id] { try? await center.add(request) }
        }
    }

    private func request(for planned: PlannedNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        var category = ""
        switch planned.content {
        case .morning(let total):
            content.title = String(localized: "\(total) today")
        case .evening(let done, let total):
            content.title = String(localized: "\(done)/\(total) done")
        case .eveningKindLine(let index):
            content.title = Self.kindLines[index % Self.kindLines.count]
        case .reminder(let itemId, let title, let canOpen, let canMoveToLater):
            content.title = title
            content.sound = .default
            content.userInfo["itemId"] = itemId.uuidString
            category = Self.category(open: canOpen, later: canMoveToLater)
        case .focusEnded(let itemId, let title):
            content.title = String(localized: "Time's up: \(title)")
            content.body = String(localized: "Open Clew to tick it, add 5 minutes or take a break.")
            content.sound = .default
            content.userInfo["itemId"] = itemId.uuidString
        case .breakEnded(let title):
            content.title = String(localized: "Break's over")
            content.body = String(localized: "Back to \(title) when you're ready.")
            content.sound = .default
        case .slotAsks(let blockId, let itemId, let title, let isGoal):
            content.title = String(localized: "Done with \(title)?")
            content.sound = .default
            content.userInfo["itemId"] = itemId.uuidString
            content.userInfo["blockId"] = blockId.uuidString
            category = isGoal ? Self.askGoalCategory : Self.askCategory
        case .blockStarts(let itemId, let title, let until):
            // "Write intro · now until 10:30" (SPEC 2026-11-10); clicking it opens Clew.
            content.title = title
            content.body = String(localized: "Now until \(until.formatted(date: .omitted, time: .shortened))")
            content.sound = .default
            content.userInfo["itemId"] = itemId.uuidString
        }
        content.categoryIdentifier = category
        // The fingerprint: same time and text means nothing to change (the body too: a
        // resized block's "until" changes only there).
        content.userInfo["fp"] = "\(Int(planned.fireAt.timeIntervalSince1970))|\(content.title)|\(content.body)|\(category)"

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let when = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: planned.fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        return UNNotificationRequest(identifier: planned.id, content: content, trigger: trigger)
    }

    /// Curated, rotating lines for an evening with no ticks (AGENT §6): never "0/6",
    /// never guilt, no model involved.
    static let kindLines: [String] = [
        String(localized: "Rest is part of the plan."),
        String(localized: "Tomorrow's list is ready when you are."),
        String(localized: "Quiet days count too."),
        String(localized: "Be gentle with yourself tonight."),
        String(localized: "A fresh start is waiting tomorrow."),
        String(localized: "Some days are for resting."),
    ]

    // MARK: Actions

    private static let doneAction = UNNotificationAction(identifier: "done", title: String(localized: "Done"))
    private static let laterAction = UNNotificationAction(identifier: "later", title: String(localized: "Later"))
    private static let openAction = UNNotificationAction(identifier: "open", title: String(localized: "Open"),
                                                         options: [.foreground])

    private static let askCategory = "clew.ask"
    private static let askGoalCategory = "clew.ask.goal"
    private static let plusOneAction = UNNotificationAction(identifier: "done", title: String(localized: "+1"))

    /// A slot block's question goes once it is answered or its day is over: delivered
    /// "Done?" notifications for blocks no longer asking are removed.
    func withdrawQuestions(keeping asking: Set<UUID>) async {
        let delivered = await center.deliveredNotifications()
        let stale = delivered.map(\.request.identifier).filter { id in
            id.hasPrefix(NotificationPlanner.idPrefix + "ask.")
                && !asking.contains { id == NotificationPlanner.idPrefix + "ask." + $0.uuidString }
        }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }

    private static func category(open: Bool, later: Bool) -> String {
        "clew.reminder\(open ? ".open" : "")\(later ? ".later" : "")"
    }

    private static var categories: Set<UNNotificationCategory> {
        var result = Set<UNNotificationCategory>()
        for open in [false, true] {
            for later in [false, true] {
                var actions: [UNNotificationAction] = []
                if open { actions.append(openAction) }
                actions.append(doneAction)
                if later { actions.append(laterAction) }
                result.insert(UNNotificationCategory(identifier: category(open: open, later: later),
                                                     actions: actions, intentIdentifiers: []))
            }
        }
        result.insert(UNNotificationCategory(identifier: askCategory, actions: [doneAction], intentIdentifiers: []))
        result.insert(UNNotificationCategory(identifier: askGoalCategory, actions: [plusOneAction], intentIdentifiers: []))
        return result
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let actionId = response.actionIdentifier
        if actionId == "done", let raw = response.notification.request.content.userInfo["blockId"] as? String,
           let blockId = UUID(uuidString: raw) {
            await MainActor.run { onAction(.answer(blockId)) }
            return
        }
        guard let raw = response.notification.request.content.userInfo["itemId"] as? String,
              let itemId = UUID(uuidString: raw) else { return }
        let action: Action? = switch actionId {
        case "done": .done(itemId)
        case "later": .later(itemId)
        case "open": .open(itemId)
        default: nil
        }
        guard let action else { return }
        await MainActor.run { onAction(action) }
    }

    /// Show the banner even while Clew's list is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
