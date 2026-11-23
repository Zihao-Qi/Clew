import AppKit
import ClewAgent
import ClewCore
import ClewDomain
import ClewStore
import Foundation
import os
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
    /// How much of each video on today's list was watched (0–1), from Watch Later.
    private(set) var watched: [UUID: Double] = [:]
    /// Imported lists (YouTube Watch Later), shown below the tasks.
    private(set) var collections: [CollectionSummary] = []
    /// How rows draw progress (Settings › General).
    private(set) var barStyle = Clew.defaultBarStyle
    /// Ring or Count in the menu bar (SPEC 2026-11-18).
    private(set) var menuBarStyle = Clew.defaultMenuBarStyle
    /// The global shortcut that opens the list (Settings › General). `nil` if cleared.
    private(set) var openListShortcut: OpenShortcut? = .default
    /// Set when the database cannot be opened; the list is replaced by this message.
    private(set) var fatalMessage: String?
    /// A short, transient message for a rejected action.
    var notice: String?
    /// Goals whose "goal reached" line was closed with Done. UI-only; the goal leaves
    /// the list at rollover anyway.
    private(set) var dismissedCelebrations: Set<UUID> = []

    /// The Chrome extension's connection (live app only).
    private(set) var browser: BrowserConnection?
    /// Clew's AI (docs/AGENT.md): the ChatGPT sign-in and its jobs (live app only).
    private(set) var ai: AIModel?
    #if DEBUG
    /// The debug AI check and render use an AI with recorded answers.
    func useAI(_ ai: AIModel) { self.ai = ai }
    #endif
    /// The About pane and the opt-in update check (SPEC 2026-11-13); per Mac.
    let updates: Updates

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
    /// Today's timeline (SPEC 2026-11-10), shown above the list when it is on.
    private(set) var timeline: TimelineDay?
    private(set) var timelineShown = true
    private(set) var blockAlerts = true
    /// The list's rows: today's tasks minus those on the timeline (SPEC 2026-11-10: a
    /// placed task lives on the timeline only). `today` keeps them all, for done/total.
    var listRows: [TodayRow] {
        let rows = today?.rows ?? []
        guard timelineShown, let placed = timeline?.placedItems, !placed.isEmpty else { return rows }
        return rows.filter { !placed.contains($0.id) }
    }
    /// Today's row for a task, wherever it is shown (Goals & Later too).
    func row(_ itemId: UUID) -> TodayRow? {
        today?.rows.first { $0.id == itemId } ?? today?.goalsAndLater.first { $0.id == itemId }
    }
    /// Goals & Later (SPEC 2026-11-15): goals and Later items, below Today.
    var goalsAndLater: [TodayRow] { today?.goalsAndLater ?? [] }
    func isBelow(_ row: TodayRow) -> Bool { goalsAndLater.contains { $0.id == row.id } }
    func isMoved(_ row: TodayRow) -> Bool { today?.moved.contains(row.id) == true }
    /// Today's calendar events laid out with the blocks (SPEC "Calendar events"), while
    /// calendar events are on and Clew may read Calendar.
    private(set) var calendarEvents: TimelineEvents?
    private(set) var calendarShown = false
    private(set) var calendarPromptClosed = false
    private(set) var calendarAccess: CalendarAccess = .notAsked
    /// macOS Calendar, read only. Replaced by made-up events in the debug snapshot.
    @ObservationIgnored var calendarSource: CalendarReading? = nil
    /// Tasks ticked by a block for an earlier day while the Mac slept.
    private(set) var lateTicks: [LateTick] = []
    @ObservationIgnored private var blockEdgeTimer: Timer?
    @ObservationIgnored private var systemObservers: [NSObjectProtocol] = []

    /// The live app: the database in the sandbox container.
    convenience init() {
        do {
            self.init(databaseAt: try Self.databaseURL())
            if let clew { browser = BrowserConnection(clew: clew) }
            ai = AIModel()
            calendarSource = EventKitCalendar()
            OpenShortcutHotkey.shared.start()
            updates.start()
            refresh()
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
    init(clew: Clew?, notify: Bool = true, updates: Updates? = nil) {
        self.clew = clew
        self.updates = updates ?? Updates()
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
        // Each step timed; a slow refresh writes one line to this Mac's log, step names
        // and milliseconds only (SPEC 2026-11-19).
        var timings = StepTimings(now: { ProcessInfo.processInfo.systemUptime })
        defer {
            if let line = timings.report("refresh") {
                Self.performanceLog.notice("\(line, privacy: .public)")
            }
        }
        do {
            // A block whose end passed ticks first (it writes only when something
            // changes, so the refresh its write causes does nothing more).
            _ = try? clew.settleBlocks()
            // A day for Later that has come goes to Today's end (SPEC 2026-11-17).
            _ = try? clew.settlePlans()
            timings.mark("settle")
            let list = try clew.today()
            today = list
            timings.mark("today")
            ratingsOn = (try? clew.ratingsEnabled()) ?? false
            watched = try clew.watchProgress(itemIds: list.rows.map(\.id))
            timings.mark("watched")
            barStyle = (try? clew.barStyle()) ?? Clew.defaultBarStyle
            menuBarStyle = (try? clew.menuBarStyle()) ?? Clew.defaultMenuBarStyle
            do { openListShortcut = try clew.openListShortcut() } catch { }
            OpenShortcutHotkey.shared.apply(openListShortcut)
            timings.mark("settings")
            steps = try clew.steps(taskIds: (list.rows + list.goalsAndLater).map(\.id))
            timings.mark("steps")
            collections = try clew.collections()
            timings.mark("collections")
            focusOffersBreak = (try? clew.focusOffersBreak()) ?? true
            timelineShown = (try? clew.timelineShown()) ?? true
            blockAlerts = (try? clew.blockAlerts()) ?? true
            timeline = try clew.timeline()
            timings.mark("timeline")
            lateTicks = try clew.lateTicks()
            timings.mark("lateTicks")
            readCalendar(clew)
            timings.mark("calendar")
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
            let reached = Set((list.rows + list.goalsAndLater).filter(\.isGoalReached).map(\.id))
            dismissedCelebrations.formIntersection(reached)
            timings.mark("focus")
        } catch {
            notice = String(localized: "Couldn't load today's list.")
            timings.mark("failed")   // the step that threw, not the next one (review)
        }
        scheduleRollover()
        scheduleFocusEnd()
        scheduleBlockEdge()
        tickWhileFocusing()
        timings.mark("schedule")
        reconcileNotifications()
        timings.mark("notifications")
        backUpIfNeeded()
        timings.mark("backup")
    }

    /// Slow refreshes (SPEC 2026-11-19): this Mac's own log, never sent anywhere.
    private static let performanceLog = Logger(subsystem: "io.github.zihao-qi.clew", category: "performance")

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
        if let asking = try? clew.askingBlockIds() {
            Task { await notifications.withdrawQuestions(keeping: asking) }
        }
    }

    // MARK: - Notifications

    func reminder(for itemId: UUID) -> Reminder? { try? clew?.reminder(forItem: itemId) }
    func summaries() -> SummarySettings { (try? clew?.summaries()) ?? .defaults }

    @discardableResult
    func setReminder(_ itemId: UUID, _ time: TimeOfDay?, todayOnly: Bool = false) -> Bool {
        if time != nil { askForNotifications() }
        return run { try $0.setReminder(itemId: itemId, time: time, todayOnly: todayOnly) }
    }

    /// "Today" at a time already past today (SPEC 2026-11-15): checked before Edit saves
    /// anything.
    func reminderTimePassed(_ time: TimeOfDay) -> Bool { clew?.isPastToday(time) ?? false }

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
        case .answer(let blockId): run { try $0.answerSlotBlock(id: blockId) }
        case .open(let id):
            // From the database, not today's rows: the notification may be clicked after
            // rollover, or for an item that is not on today's list any more.
            if let url = (try? clew?.item(id: id))??.url { open(url) }
        }
    }

    func activeDays() -> ActiveDays? { try? clew?.activeDays() }

    // MARK: - Last week's card (SPEC 2026-11-15)

    /// The card's lines, taken when the menu opened on the list; fixed for that opening.
    /// nil in a card that shows only "What Clew noticed".
    private(set) var weekCard: WeekRecap?
    /// The card is open in this opening, with or without last week's lines.
    private(set) var weekCardOpen = false
    /// "What Clew noticed" (SPEC, AI-N): the rows chosen when the card appeared; never refilled.
    private(set) var noticed: [Note] = []
    /// Only while AI is ready: losing it removes the section at once.
    var noticedShown: [Note] { ai?.isReady == true ? noticed : [] }
    /// A card is never left empty: a notes-only card closes when its section goes.
    var showsWeekCard: Bool { weekCardOpen && (weekCard != nil || !noticedShown.isEmpty) }
    /// Between the menu window becoming key and losing it: one opening.
    @ObservationIgnored private var menuSessionOpen = false
    /// Counts the menu's closings, so views that stay mounted (the details) can drop
    /// what must not greet the next opening, such as suggestions (SPEC "Suggest steps").
    private(set) var menuCloses = 0

    /// The menu's own window became key: a new opening. On the list, it takes last
    /// week's card if one is due, and marks the week shown only when it took one.
    func menuOpened(onList: Bool) {
        guard !menuSessionOpen else { return }
        menuSessionOpen = true
        closeWeekCard()
        // The one refresh of an opening, on any screen: the menu shows today as it is
        // now (SPEC 2026-11-19). Blocks settle first, so a Sunday block that ended counts.
        refresh()
        guard onList, let clew else { return }
        guard let due = try? clew.weekCardDue() else { return }
        let notes = ai.map { $0.isReady ? Memory.noticed($0.memory.notes) : [] } ?? []
        guard due.recap != nil || !notes.isEmpty else { return }
        weekCard = due.recap
        noticed = notes
        weekCardOpen = true
        try? clew.markWeekCardShown(lastWeek: due.lastWeek)
    }

    private func closeWeekCard() {
        weekCard = nil
        weekCardOpen = false
        noticed = []
    }

    /// True or Not really on a row of "What Clew noticed": the row leaves at once; the
    /// answer applies only if the note is still as it was shown.
    func answerNoticed(_ note: Note, true yes: Bool) {
        noticed.removeAll { $0.id == note.id }
        ai?.answer(note, true: yes)
        if !showsWeekCard { closeWeekCard() }
    }

    /// The menu window lost the keyboard or closed: the opening is over.
    func menuClosed() {
        menuSessionOpen = false
        menuCloses += 1
        renamingStep = nil
        closeWeekCard()
        // A refusal line never greets the next opening or the next day (SPEC 2026-11-17).
        notice = nil
    }

    /// × on the card, or leaving the list: it does not come back this week.
    func dropWeekCard() { closeWeekCard() }

    /// Settings › Progress: last week, whatever the switch says and whether shown.
    func lastWeek() -> WeekRecap? { (try? clew?.lastWeek()) ?? nil }
    /// Settings › Progress › Done so far (SPEC 2026-11-18).
    func doneSoFar() -> DoneSoFar? { try? clew?.doneSoFar() }
    func progressRange() -> ProgressRange { (try? clew?.progressRange()) ?? .all }
    func setProgressRange(_ range: ProgressRange) { run { try $0.setProgressRange(range) } }
    /// A goal's days as Bars or Heatmap, for all goals.
    func goalChart() -> GoalChart { (try? clew?.goalChart()) ?? .bars }
    func setGoalChart(_ chart: GoalChart) { run { try $0.setGoalChart(chart) } }
    func weekCardOn() -> Bool { (try? clew?.weekCardOn()) ?? true }
    func setWeekCardOn(_ on: Bool) { run { try $0.setWeekCardOn(on) } }

    #if DEBUG
    /// The snapshot shows the card without a real menu opening.
    func showWeekCardForSnapshot() {
        weekCard = (try? clew?.lastWeek()) ?? nil
        weekCardOpen = weekCard != nil
    }
    #endif

    /// Read fresh on every render; the details page is small.
    func details(for itemId: UUID) -> ItemDetails? { (try? clew?.details(itemId: itemId)) ?? nil }

    func exportData() -> Data? { try? clew?.exportDocument().encoded() }


    /// Letting go is a win (SPEC §5), and the line says so.


    // MARK: - Commands

    /// One click on a row's circle: `+1` for a goal, otherwise done ↔ undo.
    func tap(_ row: TodayRow) {
        if row.item.kind == .goal || !row.isDone {
            var tick: CheckIn?
            guard run({ tick = try $0.checkIn(itemId: row.id) }), let tick else { return }
            remember(.taskTicked, row.item, tick: tick.id)
            if Clew.hintsRatingAfterTick(row.item) { offerRating(itemId: row.id) }
        } else {
            let last = row.lastTickToday?.id
            var undone: CheckIn?
            if run({ undone = try $0.undoToday(itemId: row.id) }), undone != nil { ai?.untick(last) }
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
        // Focus on a Goals & Later row moves it to Today first (SPEC 2026-11-15).
        if isBelow(row) { guard run({ try $0.moveToToday(itemId: row.id) }) else { return } }
        run { try $0.startFocus(itemId: row.id, minutes: minutes) }
    }
    func pauseFocus() { run { try $0.pauseFocus() } }
    func resumeFocus() { run { try $0.resumeFocus() } }
    func extendFocus() { run { try $0.extendFocus() } }
    func startBreak() {
        let ended = focus
        guard run({ try $0.startBreak() }) else { return }
        rememberFocus(ended)   // the focus that just ended is time worked (review)
    }
    func stopFocus() {
        let ended = focus
        guard run({ try $0.stopFocus() }) else { return }
        rememberFocus(ended)
    }
    /// "Done" when time is up: the tick (or +1) the user asked for, never an undo, then
    /// the timer ends.
    func finishFocus(_ row: TodayRow) {
        let ended = focus
        // A task already done today gets its existing tick back: not a new one (review).
        let alreadyDone = row.isDone && row.item.kind != .goal
        var tick: CheckIn?
        guard run({ tick = try $0.finishFocus() }) else { return }
        rememberFocus(ended)
        if let tick, !alreadyDone { remember(.taskTicked, row.item, tick: tick.id) }
        if tick != nil { offerRating(itemId: row.id) }
    }

    /// Focus time ended, in whole minutes, if a focus (not a break) was running.
    private func rememberFocus(_ timer: FocusTimer?) {
        guard let timer, timer.phase == .focus, let item = item(timer.itemId) else { return }
        let spent = (timer.pausedAt ?? Date()).timeIntervalSince(timer.startedAt) - timer.pausedFor
        let minutes = Int((min(spent, timer.length) / 60).rounded())
        if minutes > 0 { remember(.focusEnded, item, value: minutes) }
    }
    func setFocusOffersBreak(_ on: Bool) { run { try $0.setFocusOffersBreak(on) } }

    // MARK: - Calendar events (SPEC 2026-11-10, day timeline step 2)

    private func readCalendar(_ clew: Clew) {
        calendarShown = (try? clew.calendarShown()) ?? false
        calendarPromptClosed = (try? clew.calendarPromptClosed()) ?? false
        guard let source = calendarSource else { calendarEvents = nil; return }
        calendarAccess = source.access
        guard calendarShown, calendarAccess == .granted, let day = timeline else { calendarEvents = nil; return }
        source.observe { [weak self] in self?.refresh() }
        let hidden = (try? clew.hiddenCalendars()) ?? []
        calendarEvents = Clew.timelineEvents(source.events(from: day.start, to: day.end), day: day, hidden: hidden)
    }

    /// "Show your calendar": turns calendar events on and asks macOS for access (only
    /// now, never at launch).
    func showCalendar() {
        run { try $0.setCalendarShown(true) }
        guard let source = calendarSource, source.access == .notAsked else { return }
        Task {
            _ = await source.requestAccess()
            refresh()
        }
    }

    func setCalendarShown(_ on: Bool) {
        if on { showCalendar() } else { run { try $0.setCalendarShown(false) } }
    }

    func closeCalendarPrompt() { run { try $0.closeCalendarPrompt() } }
    func calendars() -> [CalendarInfo] { calendarSource?.calendars() ?? [] }
    func hiddenCalendars() -> Set<String> { (try? clew?.hiddenCalendars()) ?? [] }
    func setCalendar(_ id: String, hidden: Bool) { run { try $0.setCalendar(id, hidden: hidden) } }

    // MARK: - Editing an event (SPEC 2026-11-19)

    /// A change to an event, before or after it is saved.
    struct EventChange: Equatable {
        enum Kind: Equatable { case moved, changed }
        let event: CalendarEvent
        let title: String
        let start: Date
        let end: Date
        let kind: Kind
    }

    /// A drag on a repeating event, waiting at its new place for "This event only / All
    /// future events".
    private(set) var pendingEventChange: EventChange?
    /// The change saved last, for a few seconds: "Moved “Standup” · Undo". `event` is the
    /// event as it is now; `title`, `start`, `end` what Undo puts back.
    private(set) var lastEventChange: (change: EventChange, span: EventSpan)?
    @ObservationIgnored private var lastEventChangeTask: Task<Void, Never>?

    /// A drag's change: saved at once, or for a repeating event held for the question.
    func proposeEventChange(_ change: EventChange) {
        guard change.start != change.event.start || change.end != change.event.end else { return }
        if change.event.repeats {
            pendingEventChange = change
        } else {
            changeEvent(change, span: .thisEvent)
        }
    }

    func answerPendingEventChange(_ span: EventSpan?) {
        guard let change = pendingEventChange else { return }
        pendingEventChange = nil
        if let span { changeEvent(change, span: span) }
    }

    /// Saves `change` in Calendar and offers Undo. False if Calendar refused it.
    @discardableResult
    func changeEvent(_ change: EventChange, span: EventSpan) -> Bool {
        guard let source = calendarSource,
              let id = source.change(change.event, title: change.title, start: change.start, end: change.end, span: span)
        else {
            notice = String(localized: "Calendar didn't take the change. The event may have changed elsewhere.")
            refresh()
            return false
        }
        let now = CalendarEvent(id: id, calendarId: change.event.calendarId, title: change.title, start: change.start,
                                end: change.end, isAllDay: false, color: change.event.color, canEdit: true,
                                repeats: change.event.repeats)
        let undo = EventChange(event: now, title: change.event.title, start: change.event.start,
                               end: change.event.end, kind: change.kind)
        lastEventChange = (undo, span)
        lastEventChangeTask?.cancel()
        lastEventChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.lastEventChange?.change.event.id == id else { return }
            self?.lastEventChange = nil
        }
        refresh()
        return true
    }

    /// Puts back the event's title and times, with the same choice for a repeating one.
    func undoEventChange() {
        guard let last = lastEventChange else { return }
        lastEventChange = nil
        lastEventChangeTask?.cancel()
        if calendarSource?.change(last.change.event, title: last.change.title, start: last.change.start,
                                  end: last.change.end, span: last.span) == nil {
            notice = String(localized: "Calendar didn't take the change. The event may have changed elsewhere.")
        }
        refresh()
    }

    // MARK: - Day timeline (SPEC 2026-11-10)

    /// A row dropped on an hour, or "Put on timeline…".
    @discardableResult
    func place(_ itemId: UUID, at start: Date, minutes: Int? = nil) -> Bool {
        if blockAlerts { askForNotifications() }
        return run { try $0.placeOnTimeline(itemId: itemId, start: start, minutes: minutes) }
    }
    /// A step dropped on an hour (SPEC 2026-11-21).
    @discardableResult
    func placeStep(_ stepId: UUID, at start: Date, minutes: Int? = nil) -> Bool {
        if blockAlerts { askForNotifications() }
        return run { try $0.placeStepOnTimeline(stepId: stepId, start: start, minutes: minutes) }
    }
    /// VoiceOver's "Put on timeline" on a step: the next quarter hour (the day's last one if
    /// none is left), 30 minutes cut at the day's end.
    func placeStepAtNextQuarter(_ stepId: UUID) {
        guard let day = timeline else { return }
        let minutes = Date().timeIntervalSince(day.start) / 60
        let next = (minutes / Double(Clew.blockStepMinutes)).rounded(.down) + 1
        placeStep(stepId, at: Clew.quarterStart(minutesIn: next * Double(Clew.blockStepMinutes), day: day))
    }
    /// The step a block or the Delete key refers to, if `id` is a step's.
    func stepEntry(_ id: UUID) -> TaskSteps.Entry? {
        steps.values.lazy.flatMap(\.entries).first { $0.id == id }
    }

    /// The timeline's name box, on Return (SPEC 2026-11-13): a today task and its block, in
    /// one step. A link's page title is kept as fetched unless it was edited.
    @discardableResult
    func addOnTimeline(_ text: String, fetchedTitle: String?, at start: Date, minutes: Int) -> Bool {
        let parsed = QuickEntry.parse(text)
        if blockAlerts { askForNotifications() }
        return run {
            try $0.addOnTimeline(title: parsed.title, titleOrigin: parsed.title == fetchedTitle ? .fetched : .typed,
                                 url: parsed.url, start: start, minutes: minutes)
        }
    }
    @discardableResult
    func moveBlock(_ id: UUID, to start: Date, minutes: Int? = nil) -> Bool {
        run { try $0.moveBlock(id: id, start: start, minutes: minutes) }
    }
    func resizeBlock(_ id: UUID, minutes: Int) { run { try $0.resizeBlock(id: id, minutes: minutes) } }
    func addBlock(after id: UUID) { run { try $0.addBlock(after: id) } }
    func canAddBlock(after block: TimeBlock) -> Bool { clew?.canAddBlock(after: block) ?? false }
    @discardableResult
    func removeBlock(_ id: UUID) -> Bool { run { try $0.removeBlock(id: id) } }
    /// The task's block of today that has not ended (Edit's "On today's timeline").
    func openBlock(_ itemId: UUID) -> TimeBlock? { (try? clew?.openBlock(itemId: itemId)) ?? nil }

    /// A block dragged onto the list: off the timeline, and the task (if it has no other
    /// blocks) lands in the gap it was dropped in, `slot` among the list's rows.
    func putBack(_ blockId: UUID, itemId: UUID, at slot: Int) {
        let visible = listRows.map(\.id)
        guard run({ try $0.removeBlock(id: blockId) }) else { return }
        guard listRows.contains(where: { $0.id == itemId }), let all = today?.rows.map(\.id) else { return }
        let (after, before) = Clew.insertNeighbours(at: slot, in: visible, within: all, excluding: itemId)
        run { try $0.place(itemId: itemId, in: .today, after: after, before: before) }
    }

    /// A block dragged onto Goals & Later (SPEC 2026-11-15): off the timeline; a moved
    /// item moves back, a once task or link with no tick goes to Later, in the gap
    /// (`slot` among Goals & Later's rows); anything else stays at Today's end.
    func putBackBelow(_ blockId: UUID, itemId: UUID, at slot: Int) {
        // Only what may go down does (decided before the block is removed, which would
        // undo an ended block's tick): a moved item, or an unticked once task or link.
        guard let row = row(itemId), isMoved(row)
                || ((row.item.kind == .once || row.item.kind == .link) && row.item.state == .active && row.progressAmount == 0)
        else {
            let reason = self.row(itemId).flatMap { StaysOnToday.reason(for: $0, moved: isMoved($0)) }
            putBack(blockId, itemId: itemId, at: listRows.count)
            // Only a habit's block says why; a task's block took its tick with it (SPEC
            // 2026-11-17). Not when putting it back failed: that line stays.
            if reason == .habit, notice == nil { notice = Self.message(for: .habit) }
            return
        }
        let below = goalsAndLater.map(\.id).filter { $0 != itemId }
        guard run({ try $0.removeBlock(id: blockId) }) else { return }
        let placed = (try? clew?.place(itemId: itemId, in: .goalsAndLater,
                                        after: slot > 0 && slot - 1 < below.count ? below[slot - 1] : nil,
                                        before: slot < below.count ? below[slot] : nil)) != nil
        if !placed, let last = today?.rows.last(where: { $0.id != itemId })?.id {
            run { try $0.place(itemId: itemId, in: .today, after: last, before: nil) }
        }
        refresh()
    }
    func blockNotFinished(_ id: UUID) { run { try $0.blockNotFinished(id: id) } }
    func undoLateTicks(_ itemId: UUID) { run { try $0.undoLateTicks(itemId: itemId) } }
    func dismissLateTicks(_ itemId: UUID) { run { try $0.dismissLateTicks(itemId: itemId) } }
    func setTimelineShown(_ on: Bool) { run { try $0.setTimelineShown(on) } }
    func setBlockAlerts(_ on: Bool) {
        if on { askForNotifications() }
        run { try $0.setBlockAlerts(on) }
    }

    // MARK: Focus time (SPEC 2026-11-10, step 2)

    func focusSummary(for itemId: UUID) -> FocusSummary? {
        _ = today   // read so the details page re-renders after every change
        return try? clew?.focusSummary(itemId: itemId)
    }

    /// Clew's today as a date for the picker: before the 4 a.m. rollover it is still
    /// yesterday, so the picker never offers a day Clew counts as the future (Gemini
    /// review 2026-11-10).
    var focusLatestDay: Date {
        guard let day = clew?.currentDay() else { return Date() }
        var c = DateComponents()
        c.year = day.year
        c.month = day.month
        c.day = day.day
        c.hour = 12
        return Calendar.current.date(from: c) ?? Date()
    }

    /// Time worked by hand on `date`'s calendar day.
    @discardableResult
    func addFocusTime(_ itemId: UUID, on date: Date, minutes: Int) -> Bool {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day, let day = LocalDay(year: y, month: m, day: d) else { return false }
        return run { try $0.addFocusTime(itemId: itemId, day: day, minutes: minutes) }
    }

    func removeFocusSession(_ id: UUID) { run { try $0.removeFocusSession(id: id) } }

    var focusRecordsTime: Bool { (try? clew?.focusRecordsTime()) ?? true }
    func setFocusRecordsTime(_ on: Bool) { run { try $0.setFocusRecordsTime(on) } }

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
        remember(.rated, row.item, value: rating, tick: tick.id)
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

    func setMenuBarStyle(_ style: MenuBarStyle) {
        run { try $0.setMenuBarStyle(style) }
    }

    func setOpenListShortcut(_ shortcut: OpenShortcut?) {
        run { try $0.setOpenListShortcut(shortcut) }
    }

    func undo(_ row: TodayRow) {
        let last = row.lastTickToday?.id
        var undone: CheckIn?
        if run({ undone = try $0.undoToday(itemId: row.id) }), undone != nil { ai?.untick(last) }
        if ratingPrompt?.itemId == row.id { ratingPrompt = nil }
    }

    /// Drop `dragged` onto `target`: it takes the target's place. Coming from above it
    /// lands after the target; from below, before it.
    @discardableResult
    func drop(_ dragged: UUID, onto target: TodayRow) -> Bool {
        guard let all = today?.rows.map(\.id),
              let (above, below) = Clew.dropNeighbours(dragged: dragged, onto: target.id, in: listRows.map(\.id),
                                                        within: all)
        else { return false }
        // `place` keeps a moved row's place in its plan (SPEC 2026-11-15).
        return run { try $0.place(itemId: dragged, in: .today, after: above, before: below) }
    }

    /// Move Up / Move Down: one place in the row's own list (they stop at its ends).
    func move(_ row: TodayRow, by step: Int) {
        withAnimation(Self.moveAnimation) { moveOne(row, by: step) }
    }
    private func moveOne(_ row: TodayRow, by step: Int) {
        if isBelow(row) {
            let rows = goalsAndLater
            guard let index = rows.firstIndex(where: { $0.id == row.id }), rows.indices.contains(index + step) else { return }
            let others = rows.filter { $0.id != row.id }.map(\.id)
            let slot = index + step
            run { try $0.place(itemId: row.id, in: .goalsAndLater,
                               after: slot > 0 ? others[slot - 1] : nil,
                               before: slot < others.count ? others[slot] : nil) }
            return
        }
        let rows = listRows
        guard let index = rows.firstIndex(where: { $0.id == row.id }), canMove(row, by: step) else { return }
        drop(row.id, onto: rows[index + step])
    }
    /// Move Up / Move Down stop at the row's own list's ends, and on Today at its group's
    /// (priorities first, SPEC 2026-11-19).
    func canMove(_ row: TodayRow, by step: Int) -> Bool {
        if isBelow(row) {
            guard let index = goalsAndLater.firstIndex(where: { $0.id == row.id }) else { return false }
            return goalsAndLater.indices.contains(index + step)
        }
        let rows = listRows
        guard let index = rows.firstIndex(where: { $0.id == row.id }), rows.indices.contains(index + step) else { return false }
        return rows[index + step].item.priority == row.item.priority
    }
    /// Moves chosen from a menu slide the row to its new place (user, 2026-11-18); a
    /// drag lands where it was dropped, so it is not animated.
    static let moveAnimation = Animation.snappy(duration: 0.3)
    func moveToLater(_ row: TodayRow) { withAnimation(Self.moveAnimation) { _ = run { try $0.moveToLater(itemId: row.id) } } }

    // MARK: A day for Later (SPEC 2026-11-17)

    /// The hour a Clew day starts (4 a.m.).
    var rolloverHour: Int { clew?.rolloverHour ?? 4 }
    /// Today's Clew day (it starts at the rollover).
    var currentDay: LocalDay? { clew?.currentDay() }
    func canHaveDay(_ row: TodayRow) -> Bool { clew != nil && Clew.canHaveDay(row) }
    /// The day a Goals & Later row waits for.
    func waitingDay(_ row: TodayRow) -> LocalDay? { today?.waiting[row.id] }
    @discardableResult
    func setLaterDay(_ itemId: UUID, _ day: LocalDay?) -> Bool {
        withAnimation(Self.moveAnimation) { run { try $0.setLaterDay(itemId: itemId, day: day) } }
    }
    func laterDay(_ itemId: UUID) -> LocalDay? { (try? clew?.laterDay(itemId: itemId)) ?? nil }
    // MARK: Priority tasks (SPEC 2026-11-19)

    /// Marking or unmarking moves the row to its group, so it slides there.
    func setPriority(_ row: TodayRow, _ on: Bool) {
        withAnimation(Self.moveAnimation) { _ = run { try $0.setPriority(itemId: row.id, on) } }
    }
    /// Edit offers Priority for a task on Today, a habit, or one already marked.
    func canBePriority(_ item: Item) -> Bool {
        item.priority || today?.rows.contains { $0.id == item.id } == true
            || (item.kind == .habit && item.state == .active)
    }
    /// The row shows the mark: a priority on Today (Goals & Later shows none).
    func showsPriority(_ row: TodayRow) -> Bool { row.item.priority && !isBelow(row) }

    func moveToToday(_ row: TodayRow) { withAnimation(Self.moveAnimation) { _ = run { try $0.moveToToday(itemId: row.id) } } }
    func moveBack(_ row: TodayRow) { withAnimation(Self.moveAnimation) { _ = run { try $0.moveBack(itemId: row.id) } } }

    /// A row dropped in the two lists shown as one (SPEC 2026-11-15): `order` is the
    /// visible rows top to bottom with nil for the "Goals & Later" label; the dragged row
    /// moved from `from` to `to`. Above the label it is Today, below it Goals & Later;
    /// it lands in the gap it was dropped in.
    @discardableResult
    func drop(_ dragged: UUID, in order: [UUID?], from: Int, to: Int) -> Bool {
        guard order.indices.contains(from), order.indices.contains(to), from != to, order[from] == dragged else { return false }
        var moved = order
        moved.remove(at: from)
        moved.insert(dragged, at: to)
        let label = moved.firstIndex(where: { $0 == nil }) ?? moved.count
        guard let at = moved.firstIndex(of: dragged) else { return false }
        if at < label {
            let visible = moved[..<label].compactMap { $0 }
            let all = today?.rows.map(\.id) ?? []
            let (after, before) = Clew.insertNeighbours(at: at, in: visible, within: all, excluding: dragged)
            return run { try $0.place(itemId: dragged, in: .today, after: after, before: before) }
        }
        let below = moved[(label + 1)...].compactMap { $0 }
        let slot = at - label - 1
        let placed = run { try $0.place(itemId: dragged, in: .goalsAndLater,
                                        after: slot > 0 ? below[slot - 1] : nil,
                                        before: slot + 1 < below.count ? below[slot + 1] : nil) }
        // Refused: say why, when it is a habit or a task done today (SPEC 2026-11-17).
        // Only in place of the general line (a failed save keeps its own), and asked of
        // the list as it is now (the rollover may have just passed).
        if !placed, notice == Self.message(for: ClewError.notAllowed) {
            refresh()
            if let row = row(dragged), !isBelow(row), let reason = StaysOnToday.reason(for: row, moved: isMoved(row)) {
                notice = Self.message(for: reason)
            }
        }
        return placed
    }
    /// The task deleted last, for a few seconds: "Deleted “…” · Undo" (SPEC 2026-11-10).
    private(set) var lastDeleted: (id: UUID, title: String, isStep: Bool)?
    @ObservationIgnored private var lastDeletedTask: Task<Void, Never>?

    func delete(_ id: UUID) {
        let title = (try? clew?.item(id: id))??.title
        guard run({ try $0.deleteItem(itemId: id) }) else { return }
        guard let title else { return }
        showDeleted(id, title, isStep: false)
    }

    /// "Deleted “…” · Undo" for a few seconds, for a task or a step.
    private func showDeleted(_ id: UUID, _ title: String, isStep: Bool) {
        lastDeleted = (id, title, isStep)
        lastDeletedTask?.cancel()
        lastDeletedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.lastDeleted?.id == id else { return }
            self?.lastDeleted = nil
        }
    }

    func undoDelete() {
        guard let deleted = lastDeleted else { return }
        lastDeleted = nil
        if deleted.isStep {
            run { try $0.undeleteStep(id: deleted.id) }
        } else {
            run { try $0.undeleteItem(itemId: deleted.id) }
        }
    }

    // MARK: - Steps in a task (SPEC 2026-11-21)

    /// The steps of the tasks on the list (tasks without steps are missing).
    private(set) var steps: [UUID: TaskSteps] = [:]
    func steps(of id: UUID) -> TaskSteps? { steps[id].flatMap { $0.isEmpty ? nil : $0 } }
    /// A task's steps for its details, also once it has left the list (the rollover).
    func allSteps(of id: UUID) -> [TaskSteps.Entry] {
        steps[id]?.entries ?? ((try? clew?.steps(taskId: id))?.entries ?? [])
    }

    /// Which tasks are unfolded: a setting of this Mac, not part of the task (SPEC).
    private(set) var unfolded: Set<UUID> = AppModel.loadUnfolded()
    private static let unfoldedKey = "unfoldedTasks"
    /// Where folds are kept; the debug harnesses use their own, never the app's.
    static var foldDefaults = UserDefaults.standard
    private static func loadUnfolded() -> Set<UUID> {
        Set((foldDefaults.stringArray(forKey: unfoldedKey) ?? []).compactMap(UUID.init(uuidString:)))
    }
    func isUnfolded(_ id: UUID) -> Bool { unfolded.contains(id) }
    /// The step being renamed in the list (right-click › Rename, SPEC 2026-11-22).
    var renamingStep: UUID?
    func setUnfolded(_ id: UUID, _ on: Bool) {
        guard on != unfolded.contains(id) else { return }
        if on { unfolded.insert(id) } else { unfolded.remove(id) }
        Self.foldDefaults.set(unfolded.map(\.uuidString).sorted(), forKey: Self.unfoldedKey)
    }

    /// Also on a task done today: adding a step reopens it (*changed* 2026-11-22, *user*).
    /// Never on a task done on an earlier day.
    func canAddStep(_ row: TodayRow) -> Bool {
        Clew.canHaveSteps(row.item) && (row.progressAmount == 0 || row.isDone)
    }

    @discardableResult
    func addStep(to taskId: UUID, title: String) -> Bool {
        // Reopening undoes the task's tick: its unsent memory events go too.
        let reopened = row(taskId).flatMap { $0.isDone ? $0.lastTickToday?.id : nil }
        guard run({ try $0.addStep(taskId: taskId, title: title) }) else { return false }
        ai?.untick(reopened)
        return true
    }

    /// + or Add all on a suggestion: added as typing it would, and remembered (SPEC "Memory").
    @discardableResult
    func addSuggestedStep(to taskId: UUID, title: String) -> Bool {
        let before = Set(allSteps(of: taskId).map(\.step.id))
        guard addStep(to: taskId, title: title) else { return false }
        if let added = allSteps(of: taskId).first(where: { !before.contains($0.step.id) }), let task = item(taskId) {
            ai?.suggested(added.step.id)
            remember(.suggestionAdded, task, step: added.step.title)
        }
        return true
    }

    // MARK: - Memory (SPEC "Memory")

    func item(_ id: UUID) -> Item? { row(id)?.item ?? ((try? clew?.item(id: id)) ?? nil) }

    /// What the person did, for Clew's notes: only while AI is ready, and text only for
    /// a task whose title they typed (docs/AGENT.md §7).
    func remember(_ kind: ActivityEvent.Kind, _ task: Item, step: String? = nil, value: Int? = nil, tick: UUID? = nil) {
        ai?.record(kind, task: task.title, typed: task.titleOrigin == .typed, step: step, value: value, tick: tick)
    }
    @discardableResult
    func renameStep(_ id: UUID, _ title: String) -> Bool { run { try $0.renameStep(id: id, title: title) } }
    func moveStep(_ id: UUID, toOpenIndex index: Int) { run { try $0.moveStep(id: id, toOpenIndex: index) } }

    func deleteStep(_ step: Step) {
        guard run({ try $0.deleteStep(id: step.id) }) else { return }
        if ai?.memory.activity.isSuggested(step.id) == true, let task = item(step.taskId) {
            remember(.suggestedStepDeleted, task, step: step.title)
        }
        showDeleted(step.id, step.title, isStep: true)
    }

    /// A step's circle: tick it, or untick it (on a done task that unticks the task too).
    func tapStep(_ entry: TaskSteps.Entry) {
        if entry.isDone {
            let taskTick = row(entry.step.taskId).flatMap { $0.isDone ? $0.lastTickToday?.id : nil }
            if run({ try $0.untickStep(id: entry.step.id) }) {
                ai?.untick(entry.step.id)
                ai?.untick(taskTick)
            }
            if ratingPrompt?.itemId == entry.step.taskId { ratingPrompt = nil }
        } else {
            var finished: CheckIn?
            guard run({ finished = try $0.tickStep(id: entry.step.id) }) else { return }
            if let task = item(entry.step.taskId) {
                // The last step finishing the task shares the task's tick, so unticking the
                // task drops both (review).
                remember(.stepTicked, task, step: entry.step.title, tick: finished?.id ?? entry.step.id)
                if let finished { remember(.taskTicked, task, tick: finished.id) }
            }
            // The last step finished the task: as its own tick does.
            if finished != nil, let row = row(entry.step.taskId), Clew.hintsRatingAfterTick(row.item) {
                offerRating(itemId: row.id)
            }
        }
    }
    func nextRound(_ row: TodayRow) { run { try $0.startNextRound(itemId: row.id) } }
    func dismissCelebration(_ row: TodayRow) { dismissedCelebrations.insert(row.id) }

    /// The page title for a pasted link, or nil.
    func fetchTitle(for url: URL) async -> String? {
        await TitleFetcher.title(for: url)
    }

    @discardableResult
    func add(_ new: NewItem) -> Bool {
        if new.slot != nil, blockAlerts { askForNotifications() }      // asked when a slot is saved
        return run { try $0.addItem(new) }
    }

    @discardableResult
    func edit(_ id: UUID, _ edit: ItemEdit) -> Bool {
        if case .set(let slot) = edit.slot, slot != nil, blockAlerts { askForNotifications() }
        return run { try $0.editItem(id: id, edit) }
    }

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

    static func message(for reason: StaysOnToday) -> String {
        switch reason {
        case .habit: String(localized: "Habits stay on Today. Change when it repeats in Edit.")
        case .doneToday: String(localized: "Done today. Undo the tick to move it.")
        }
    }

    static func message(for error: ClewError) -> String {
        switch error {
        case .emptyTitle: String(localized: "Give it a name.")
        case .titleTooLong(let max): String(localized: "Keep the name under \(max) characters.")
        case .invalidURL: String(localized: "Links must start with http:// or https://.")
        case .invalidTarget: String(localized: "Pick a total between 1 and 100,000.")
        case .invalidSchedule: String(localized: "Pick at least one day.")
        case .reminderTimePassed: String(localized: "That time has passed today.")
        case .goalReached: String(localized: "Goal reached! Start a next round or raise the target.")
        case .itemNotFound, .checkInNotFound, .notAllowed, .tooManyEntries: String(localized: "That can't be done right now.")
        case .listTurnedOff: String(localized: "That list is turned off in Settings › General.")
        case .focusRunning: String(localized: "A focus timer is already running. Stop it first.")
        case .invalidMinutes(let max): String(localized: "Pick between 1 and \(max) minutes.")
        case .tooManyPriorities(let max): String(localized: "Up to \(max) priorities. Finish or unmark one first.")
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

    /// Refreshes at the next block start or end, so a block ticks the moment it ends
    /// (and the timeline shows it running) even with the list closed.
    private func scheduleBlockEdge() {
        blockEdgeTimer?.invalidate()
        blockEdgeTimer = nil
        let now = Date()
        let edges = (timeline?.blocks ?? []).flatMap { [$0.block.start, $0.block.end] }.filter { $0 > now }
        guard let next = edges.min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        blockEdgeTimer = timer
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
