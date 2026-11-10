import AppKit
import ClewCore
import ClewDomain
import ClewStore
import Foundation
import Observation
import SwiftUI

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
    /// How much of each video on today's list was watched (0–1), from Watch Later.
    private(set) var watched: [UUID: Double] = [:]
    /// Imported lists (YouTube Watch Later), shown below the tasks.
    private(set) var collections: [CollectionSummary] = []
    /// How rows draw progress (Settings › General).
    private(set) var barStyle = Clew.defaultBarStyle
    /// Set when the database cannot be opened; the list is replaced by this message.
    private(set) var fatalMessage: String?
    /// A short, transient message for a rejected action.
    var notice: String?
    /// A short confirmation that fades by itself, e.g. "Saved to Later (13)".
    private(set) var confirmation: String?
    @ObservationIgnored private var confirmationTask: Task<Void, Never>?
    /// Goals whose "goal reached" line was closed with Done. UI-only; the goal leaves
    /// the list at rollover anyway.
    private(set) var dismissedCelebrations: Set<UUID> = []

    /// The Chrome extension's connection (live app only).
    private(set) var browser: BrowserConnection?

    /// True when the user turned Clew's notifications off in System Settings.
    private(set) var notificationsDenied = false

    @ObservationIgnored private var clew: Clew?
    /// Set only for the real database (not for previews or the debug snapshot).
    @ObservationIgnored private var store: SQLiteStore?
    @ObservationIgnored private(set) var backups: Backups?
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    @ObservationIgnored private var notifications: NotificationsAdapter?
    @ObservationIgnored private var observation: (any StoreObservation)?
    @ObservationIgnored private var rolloverTimer: Timer?
    @ObservationIgnored private var focusEndTimer: Timer?
    @ObservationIgnored private var focusTick: Timer?
    /// The current second while a timer runs, so the timed row and the menu bar count
    /// down. A TimelineView inside the menu bar label made SwiftUI redraw the status
    /// item without end (100% CPU, seen 2026-11-10); one tick a second does not.
    private(set) var clockTick = Date()
    /// The running focus timer or break (SPEC 2026-11-10), if any.
    private(set) var focus: FocusTimer?
    private(set) var focusOffersBreak = true
    @ObservationIgnored private var systemObservers: [NSObjectProtocol] = []

    /// The live app: the database in the sandbox container.
    convenience init() {
        do {
            self.init(databaseAt: try Self.databaseURL())
            if let clew { browser = BrowserConnection(clew: clew) }
        } catch {
            self.init(clew: nil)
            fatalMessage = String(localized: "Clew couldn't open its data. Quit and reopen Clew.")
        }
    }

    /// The real app's model for the database at `url` (the debug restore test passes a
    /// temporary one).
    convenience init(databaseAt url: URL, notify: Bool = true) {
        do {
            let store = try SQLiteStore.open(at: url)
            self.init(clew: Clew(store: store, clock: SystemClock(), zones: SystemTimeZone()), notify: notify)
            self.store = store
            self.backups = Backups(databaseURL: url)
            refresh() // now with backups attached: makes today's backup if needed
        } catch {
            self.init(clew: nil)
            fatalMessage = String(localized: "Clew couldn't open its data. Quit and reopen Clew.")
        }
    }

    /// `notify: false` keeps a model (e.g. the debug snapshot's) away from real notifications.
    init(clew: Clew?, notify: Bool = true) {
        self.clew = clew
        if notify, clew != nil {
            notifications = NotificationsAdapter { [weak self] action in self?.handle(action) }
        }
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
            ratingsOn = (try? clew.ratingsEnabled()) ?? false
            laterCount = try clew.laterCount()
            watched = try clew.watchProgress(itemIds: list.rows.map(\.id))
            barStyle = (try? clew.barStyle()) ?? Clew.defaultBarStyle
            collections = try clew.collections()
            focusOffersBreak = (try? clew.focusOffersBreak()) ?? true
            focus = try clew.focusTimer()
            if let running = focus {
                // A break that is over simply ends; a timer whose task left Today (done
                // elsewhere, deleted, moved to Later) ends with it.
                let over = running.phase == .rest && running.isOver(at: Date())
                if over || !list.rows.contains(where: { $0.id == running.itemId }) {
                    _ = try? clew.stopFocus()
                    focus = nil
                }
            }
            // A closed congratulation stays closed only while that goal stays reached, so
            // reaching a raised target or a next round congratulates again.
            let reached = Set(list.rows.filter(\.isGoalReached).map(\.id))
            dismissedCelebrations.formIntersection(reached)
        } catch {
            notice = String(localized: "Couldn't load today's list.")
        }
        scheduleRollover()
        scheduleFocusEnd()
        tickWhileFocusing()
        reconcileNotifications()
        backUpIfNeeded()
    }

    // MARK: - Backups (ARCHITECTURE §7)

    /// Once a day, off the main thread: launch, rollover, wake and every refresh check.
    private func backUpIfNeeded() {
        guard let store, let backups, let clew, backupTask == nil else { return }
        let today = clew.currentDay()
        backupTask = Task.detached(priority: .utility) { [weak self] in
            _ = try? backups.backUpIfNeeded(store, today: today)
            await MainActor.run { self?.backupTask = nil }
        }
    }

    func backupList() -> [Backups.Entry] { backups?.list() ?? [] }

    /// Restore: a safety copy of the current data, then the chosen backup is staged and
    /// checked, the database is closed, swapped and reopened. Nothing is swapped under
    /// an open database. Returns a sentence for the user.
    func restore(_ entry: Backups.Entry) async -> String {
        // A backup still running would finish after the swap and save the old data as
        // today's backup; wait for it first.
        await backupTask?.value
        guard let store, let backups, let clew else { return String(localized: "Restore isn't available.") }
        do {
            try backups.stageRestore(entry, current: store, today: clew.currentDay())
        } catch {
            return String(localized: "That backup is damaged, so nothing was changed.")
        }
        observation?.cancel()
        observation = nil
        browser?.use(nil)
        self.clew = nil
        self.store = nil
        do {
            try store.close()
            let reopened = try SQLiteStore.open(at: backups.databaseURL)
            let fresh = Clew(store: reopened, clock: SystemClock(), zones: SystemTimeZone())
            self.store = reopened
            self.clew = fresh
            browser?.use(fresh)
            observation = fresh.observeChanges { [weak self] in Task { @MainActor in self?.refresh() } }
            refresh()
            let date = SettingsView.dayText(entry.day)
            return String(localized: "Restored the backup from \(date). Your data from before is saved as a backup too.")
        } catch {
            fatalMessage = String(localized: "Clew couldn't open its data. Quit and reopen Clew.")
            return String(localized: "Restore failed. Quit and reopen Clew.")
        }
    }

    /// Runs after every refresh: launch, every command, rollover, wake, and clock or
    /// time-zone change (ARCHITECTURE §6).
    private func reconcileNotifications() {
        guard let clew, let notifications, let plan = try? clew.plannedNotifications() else { return }
        notifications.reconcile(plan)
    }

    // MARK: - Notifications

    func reminder(for itemId: UUID) -> Reminder? { try? clew?.reminder(forItem: itemId) }
    func summaries() -> SummarySettings { (try? clew?.summaries()) ?? .defaults }

    @discardableResult
    func setReminder(_ itemId: UUID, _ time: TimeOfDay?) -> Bool {
        if time != nil { askForNotifications() }
        return run { try $0.setReminder(itemId: itemId, time: time) }
    }

    func setSummaries(_ settings: SummarySettings) {
        if settings.morningEnabled || settings.eveningEnabled { askForNotifications() }
        run { try $0.setSummaries(settings) }
    }

    /// Permission is asked the first time something could notify, never at launch.
    private func askForNotifications() {
        guard let notifications else { return }
        Task {
            let granted = await notifications.requestPermission()
            notificationsDenied = !granted
            if granted { refresh() }
        }
    }

    func checkNotificationPermission() {
        guard let notifications, let clew, (try? clew.wantsNotifications()) == true else {
            notificationsDenied = false
            return
        }
        Task { notificationsDenied = await notifications.isDenied() }
    }

    private func handle(_ action: NotificationsAdapter.Action) {
        switch action {
        case .done(let id): run { try $0.checkIn(itemId: id, source: .notification) }
        case .later(let id): run { try $0.moveToLater(itemId: id) }
        case .open(let id):
            // From the database, not today's rows: the notification may be clicked after
            // rollover, or for an item that is not on today's list any more.
            if let url = (try? clew?.item(id: id))??.url { open(url) }
        }
    }

    func activeDays() -> ActiveDays? { try? clew?.activeDays() }

    /// Read fresh on every render; the details page is small.
    func details(for itemId: UUID) -> ItemDetails? { (try? clew?.details(itemId: itemId)) ?? nil }

    func exportData() -> Data? { try? clew?.exportDocument().encoded() }

    func laterPile() -> [LaterEntry] { (try? clew?.laterPile()) ?? [] }
    func lettingGoCount() -> Int { (try? clew?.lettingGoCount()) ?? 0 }
    func keepLater(_ id: UUID) { run { try $0.keepLater(itemId: id) } }

    /// Letting go is a win (SPEC §5), and the line says so.
    func letGo(_ id: UUID) {
        guard run({ try $0.letGo(itemId: id) }) else { return }
        showConfirmation(String(localized: "Let go — that's a win too."))
    }


    // MARK: - Commands

    /// One click on a row's circle: `+1` for a goal, otherwise done ↔ undo.
    func tap(_ row: TodayRow) {
        if row.item.kind == .goal || !row.isDone {
            var tick: CheckIn?
            guard run({ tick = try $0.checkIn(itemId: row.id) }), tick != nil else { return }
            if Clew.hintsRatingAfterTick(row.item) { offerRating(itemId: row.id) }
        } else {
            run { try $0.undoToday(itemId: row.id) }
            if ratingPrompt?.itemId == row.id { ratingPrompt = nil }
        }
    }

    // MARK: - Collections (SPEC 2026-11-09)

    func collection(_ source: Source) -> CollectionDetails? { (try? clew?.collection(source)) ?? nil }

    /// The circle on a collection's video: tick it, or undo a tick made today.
    func toggleFinished(_ entry: CollectionEntry) {
        if entry.doneToday {
            run { try $0.undoToday(itemId: entry.id) }
        } else if entry.doneAt == nil {
            run { try $0.checkIn(itemId: entry.id) }
        }
    }

    /// A video that left the list counted as finished; the user says it wasn't.
    func markNotFinished(_ id: UUID) { run { try $0.markNotFinished(itemId: id) } }

    func collectionsOff() -> Set<Source> { (try? clew?.collectionsOff()) ?? [] }
    func setCollection(_ source: Source, on: Bool) { run { try $0.setCollection(source, on: on) } }

    // MARK: - Focus timer (SPEC 2026-11-10)

    func startFocus(_ row: TodayRow, minutes: Int) {
        askForNotifications()
        run { try $0.startFocus(itemId: row.id, minutes: minutes) }
    }
    func pauseFocus() { run { try $0.pauseFocus() } }
    func resumeFocus() { run { try $0.resumeFocus() } }
    func extendFocus() { run { try $0.extendFocus() } }
    func startBreak() { run { try $0.startBreak() } }
    func stopFocus() { run { try $0.stopFocus() } }
    /// "Done" when time is up: the tick (or +1) the user asked for, never an undo, then
    /// the timer ends.
    func finishFocus(_ row: TodayRow) {
        var tick: CheckIn?
        guard run({ tick = try $0.finishFocus() }) else { return }
        if tick != nil { offerRating(itemId: row.id) }
    }
    func setFocusOffersBreak(_ on: Bool) { run { try $0.setFocusOffersBreak(on) } }

    // MARK: - Rating dots (SPEC §4; off by default)

    /// A row showing its rating dots as a hint after a tick (they also show on hover).
    struct RatingPrompt: Equatable {
        let itemId: UUID
        var rating: Int?
    }

    /// The row currently showing rating dots, if any.
    private(set) var ratingPrompt: RatingPrompt?
    private(set) var ratingsOn = false
    @ObservationIgnored private var ratingPromptTask: Task<Void, Never>?

    private func offerRating(itemId: UUID) {
        guard ratingsOn else { return }
        let prompt = RatingPrompt(itemId: itemId)
        ratingPrompt = prompt
        hideRatingPrompt(after: .seconds(4), unlessChangedFrom: prompt)
    }

    /// Rates today's latest live tick of the row (rating again changes it).
    func rate(_ row: TodayRow, _ rating: Int) {
        guard let tick = row.lastTickToday else { return }
        guard run({ try $0.rate(checkInId: tick.id, rating: rating) }) else { return }
        let prompt = RatingPrompt(itemId: row.id, rating: rating)
        ratingPrompt = prompt
        hideRatingPrompt(after: .milliseconds(1200), unlessChangedFrom: prompt)
    }

    private func hideRatingPrompt(after delay: Duration, unlessChangedFrom prompt: RatingPrompt) {
        ratingPromptTask?.cancel()
        ratingPromptTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self?.ratingPrompt == prompt else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.ratingPrompt = nil }
        }
    }

    func setRatingsEnabled(_ on: Bool) {
        run { try $0.setRatingsEnabled(on) }
    }

    func setBarStyle(_ style: ProgressBarStyle) {
        run { try $0.setBarStyle(style) }
    }

    func undo(_ row: TodayRow) {
        run { try $0.undoToday(itemId: row.id) }
        if ratingPrompt?.itemId == row.id { ratingPrompt = nil }
    }

    /// Drop `dragged` onto `target`: it takes the target's place. Coming from above it
    /// lands after the target; from below, before it.
    @discardableResult
    func drop(_ dragged: UUID, onto target: TodayRow) -> Bool {
        guard let order = today?.rows.map(\.id),
              let (above, below) = Clew.dropNeighbours(dragged: dragged, onto: target.id, in: order)
        else { return false }
        return run { try $0.moveItem(id: dragged, after: above, before: below) }
    }

    /// Move Up / Move Down: one place in today's list.
    func move(_ row: TodayRow, by step: Int) {
        guard let rows = today?.rows, let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let target = index + step
        guard rows.indices.contains(target) else { return }
        drop(row.id, onto: rows[target])
    }
    func moveToLater(_ row: TodayRow) { run { try $0.moveToLater(itemId: row.id) } }
    func delete(_ id: UUID) { run { try $0.deleteItem(itemId: id) } }
    func nextRound(_ row: TodayRow) { run { try $0.startNextRound(itemId: row.id) } }
    func dismissCelebration(_ row: TodayRow) { dismissedCelebrations.insert(row.id) }

    /// Later is hidden, so say where the item went (SPEC §5).
    func confirmSavedToLater() {
        showConfirmation(String(localized: "Saved to Later (\(laterCount))"))
    }

    private func showConfirmation(_ text: String) {
        confirmation = text
        confirmationTask?.cancel()
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.confirmation == text else { return }
            self?.confirmation = nil
        }
    }

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

    /// Replaced only by the debug click test, so it never opens a browser.
    @ObservationIgnored var urlOpener: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    func open(_ url: URL) {
        // Core only accepts http(s) URLs, so nothing but a web page can open here.
        urlOpener(url)
    }

    @discardableResult
    private func run(_ command: (Clew) throws -> Any?) -> Bool {
        guard let clew else { return false }
        do {
            _ = try command(clew)
            notice = nil
            confirmation = nil
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
        case .itemNotFound, .checkInNotFound, .notAllowed, .tooManyEntries: String(localized: "That can't be done right now.")
        case .listTurnedOff: String(localized: "That list is turned off in Settings › General.")
        case .focusRunning: String(localized: "A focus timer is already running. Stop it first.")
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

    /// Refreshes the moment focus or break time is up, so the row asks "Done?" and an
    /// over break ends even with the list closed.
    private func scheduleFocusEnd() {
        focusEndTimer?.invalidate()
        focusEndTimer = nil
        guard let endsAt = focus?.endsAt, endsAt > Date() else { return }
        let timer = Timer(fire: endsAt.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        focusEndTimer = timer
    }

    private func tickWhileFocusing() {
        guard focus != nil else {
            focusTick?.invalidate()
            focusTick = nil
            return
        }
        clockTick = Date()
        guard focusTick == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.clockTick = Date() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        focusTick = timer
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
