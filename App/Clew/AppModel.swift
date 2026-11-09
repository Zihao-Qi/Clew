import AppKit
import ClewCore
import ClewDomain
import ClewStore
import Foundation
import Observation

struct SystemClock: Clock {
    func now() -> Date { Date() }
}

struct SystemTimeZone: TimeZoneSource {
    func current() -> TimeZone { TimeZone.current }
}

/// The composition root's view model. It holds no business logic: every action is a
/// ClewCore command, and every value shown comes from a ClewCore query.
@MainActor @Observable
final class AppModel {
    private(set) var today: TodayList?
    private(set) var laterCount = 0
    /// Set when the database cannot be opened; the list is replaced by this message.
    private(set) var fatalMessage: String?
    /// A short, transient message for a rejected action.
    var notice: String?
    /// Goals whose "goal reached" line was closed with Done. UI-only; the goal leaves
    /// the list at rollover anyway.
    private(set) var dismissedCelebrations: Set<UUID> = []

    @ObservationIgnored private var clew: Clew?
    @ObservationIgnored private var observation: (any StoreObservation)?
    @ObservationIgnored private var rolloverTimer: Timer?
    @ObservationIgnored private var systemObservers: [NSObjectProtocol] = []

    /// The live app: the database in the sandbox container.
    convenience init() {
        do {
            let store = try SQLiteStore.open(at: Self.databaseURL())
            self.init(clew: Clew(store: store, clock: SystemClock(), zones: SystemTimeZone()))
        } catch {
            self.init(clew: nil)
            fatalMessage = String(localized: "Clew couldn't open its data. Quit and reopen Clew.")
        }
    }

    init(clew: Clew?) {
        self.clew = clew
        observation = clew?.observeChanges { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        observeSystemTime()
    }

    static func databaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return support.appendingPathComponent("Clew", isDirectory: true).appendingPathComponent("clew.sqlite")
    }

    // MARK: - Queries

    func refresh() {
        guard let clew else { return }
        do {
            let list = try clew.today()
            today = list
            laterCount = try clew.laterCount()
            // A closed congratulation stays closed only while that goal stays reached, so
            // reaching a raised target or a next round congratulates again.
            let reached = Set(list.rows.filter(\.isGoalReached).map(\.id))
            dismissedCelebrations.formIntersection(reached)
        } catch {
            notice = String(localized: "Couldn't load today's list.")
        }
        scheduleRollover()
    }

    func laterItems() -> [Item] {
        (try? clew?.laterItems()) ?? []
    }

    // MARK: - Commands

    /// One click on a row's circle: `+1` for a goal, otherwise done ↔ undo.
    func tap(_ row: TodayRow) {
        run {
            if row.item.kind == .goal || !row.isDone {
                try $0.checkIn(itemId: row.id)
            } else {
                try $0.undoToday(itemId: row.id)
            }
        }
    }

    func undo(_ row: TodayRow) { run { try $0.undoToday(itemId: row.id) } }
    func moveToLater(_ row: TodayRow) { run { try $0.moveToLater(itemId: row.id) } }
    func delete(_ id: UUID) { run { try $0.deleteItem(itemId: id) } }
    func nextRound(_ row: TodayRow) { run { try $0.startNextRound(itemId: row.id) } }
    func dismissCelebration(_ row: TodayRow) { dismissedCelebrations.insert(row.id) }

    /// The page title for a pasted link, or nil.
    func fetchTitle(for url: URL) async -> String? {
        await TitleFetcher.title(for: url)
    }

    @discardableResult
    func add(_ new: NewItem) -> Bool { run { try $0.addItem(new) } }

    @discardableResult
    func edit(_ id: UUID, _ edit: ItemEdit) -> Bool { run { try $0.editItem(id: id, edit) } }

    @discardableResult
    func pick(_ ids: [UUID]) -> Bool { run { try $0.planForToday(itemIds: ids) } }

    func open(_ url: URL) {
        // Core only accepts http(s) URLs, so nothing but a web page can open here.
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    private func run(_ command: (Clew) throws -> Any?) -> Bool {
        guard let clew else { return false }
        do {
            _ = try command(clew)
            notice = nil
            refresh()
            return true
        } catch let error as ClewError {
            notice = Self.message(for: error)
            return false
        } catch {
            notice = String(localized: "That didn't save. Try again.")
            return false
        }
    }

    static func message(for error: ClewError) -> String {
        switch error {
        case .emptyTitle: String(localized: "Give it a name.")
        case .titleTooLong(let max): String(localized: "Keep the name under \(max) characters.")
        case .invalidURL: String(localized: "Links must start with http:// or https://.")
        case .invalidTarget: String(localized: "Pick a total between 1 and 100,000.")
        case .invalidSchedule: String(localized: "Pick at least one day.")
        case .pickCount: String(localized: "Pick 1 to 3 items.")
        case .goalReached: String(localized: "Goal reached! Start a next round or raise the target.")
        case .itemNotFound, .checkInNotFound, .notAllowed: String(localized: "That can't be done right now.")
        }
    }

    // MARK: - Time

    /// Today's list changes at the rollover hour. Timers can be late after sleep or App
    /// Nap, so wake, clock and time-zone changes, and opening the list also refresh.
    private func scheduleRollover() {
        guard let clew else { return }
        rolloverTimer?.invalidate()
        let fireAt = clew.nextRolloverInstant().addingTimeInterval(1)
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        rolloverTimer = timer
    }

    private func observeSystemTime() {
        let workspace = NSWorkspace.shared.notificationCenter
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        let center = NotificationCenter.default
        systemObservers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            NSTimeZone.resetSystemTimeZone()
            Task { @MainActor in self?.refresh() }
        })
        systemObservers.append(center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }
}
