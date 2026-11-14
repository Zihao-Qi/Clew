import AppKit
import ClewCore
import ClewDomain
import ClewStore
import SwiftUI
import UniformTypeIdentifiers

/// The small Settings window (SPEC §9): launch at login, active days ("done means
/// used", shown only here), and one-click export.
struct SettingsView: View {
    static let windowID = "settings"
    let model: AppModel

    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginMessage: String?
    @State private var activeDays: ActiveDays?
    @State private var letGoCount = 0
    @State private var ratingDots = false
    @State private var barStyle = Clew.defaultBarStyle
    @State private var listsOff: Set<Source> = []
    @State private var offersBreak = true
    @State private var timelineShown = true
    @State private var blockAlerts = true
    @State private var recordsTime = true
    @State private var pane: Pane?

    /// A plain column of sections; selected one highlighted, keyboard and VoiceOver
    /// reachable as buttons.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Pane.allCases) { item in
                let selected = (pane ?? .general) == item
                Button { pane = item } label: {
                    Label { item.title } icon: { Image(systemName: item.icon).frame(width: 18) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Color.accentColor.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 170)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
    }

    init(model: AppModel, pane: Pane = .general) {
        self.model = model
        _pane = State(initialValue: pane)
    }

    /// The sidebar's sections.
    enum Pane: String, CaseIterable, Identifiable {
        case general, summaries, progress, calendar, browser, data, about
        var id: String { rawValue }
        var title: Text {
            switch self {
            case .general: Text("General")
            case .summaries: Text("Summaries")
            case .progress: Text("Progress")
            case .calendar: Text("Calendar")
            case .browser: Text("Browser")
            case .data: Text("Data")
            case .about: Text("About")
            }
        }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .summaries: "bell"
            case .progress: "chart.bar"
            case .calendar: "calendar"
            case .browser: "puzzlepiece.extension"
            case .data: "externaldrive"
            case .about: "info.circle"
            }
        }
    }
    @State private var exportMessage: String?
    @State private var summaries = SummarySettings.defaults
    @State private var backupList: [Backups.Entry] = []
    @State private var showingRestore = false
    @State private var restoreMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Form {
                switch pane ?? .general {
                case .general:
                Section {
                    // An explicit closure, not `set: setOpenAtLogin`: Swift 6.3 crashes generating the
                    // isolated thunk for the method reference.
                    Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
                    if let loginMessage {
                        HStack {
                            Text(loginMessage).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                        }
                    }
                }

                Section {
                    OpenShortcutRecorder(shortcut: Binding(
                        get: { model.openListShortcut },
                        set: { model.setOpenListShortcut($0) }
                    ))
                } header: {
                    Text("Open the list")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Opens or closes today's list from the keyboard, even when the menu is closed. The default is ⌘.")
                        if let openListShortcutError = OpenShortcutHotkey.shared.registrationError {
                            Text(openListShortcutError)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Rating dots after a tick", isOn: Binding(get: { ratingDots }, set: { on in
                        ratingDots = on
                        model.setRatingsEnabled(on)
                    }))
                } footer: {
                    Text("Five dots for how it felt: rough, meh, okay, good, great. They show after a tick and when you hover there, so you can rate or change it later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Progress bars", selection: Binding(get: { barStyle }, set: { style in
                        barStyle = style
                        model.setBarStyle(style)
                    })) {
                        Text("Behind the title").tag(ProgressBarStyle.behindTitle)
                        Text("Under the title").tag(ProgressBarStyle.underTitle)
                        Text("No bar").tag(ProgressBarStyle.off)
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text("How counted goals and started videos show their progress: the row fills up behind its name, a long bar runs under it, or no bar (goals keep their count).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Offer a break after focusing", isOn: Binding(get: { offersBreak }, set: { on in
                        offersBreak = on
                        model.setFocusOffersBreak(on)
                    }))
                    Toggle("Record focus time", isOn: Binding(get: { recordsTime }, set: { on in
                        recordsTime = on
                        model.setFocusRecordsTime(on)
                    }))
                } header: {
                    Text("Focus timer")
                } footer: {
                    Text("Right-click a task and choose Focus to work on it for 10, 25 or 45 minutes. When time is up, it asks whether you're done; it never ticks by itself. Recorded time shows on the task's details, where you can also add time you worked without the timer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Show the day timeline", isOn: Binding(get: { timelineShown }, set: { on in
                        timelineShown = on
                        model.setTimelineShown(on)
                    }))
                    Toggle("Block alerts", isOn: Binding(get: { blockAlerts }, set: { on in
                        blockAlerts = on
                        model.setBlockAlerts(on)
                    }))
                    if model.notificationsDenied, blockAlerts {
                        NotificationsOffNotice()
                    }
                } header: {
                    Text("Day timeline")
                } footer: {
                    Text("Today's hours above the list. Drag a task onto an hour; when its block ends, the task is ticked. A habit or goal can have its own time in Edit: it appears there each day and asks \"Done?\" at its end. Block alerts: when a block starts, and that question.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(Clew.collectionSources, id: \.self) { source in
                        Toggle(CollectionStyle.name(source), isOn: Binding(get: { !listsOff.contains(source) }, set: { on in
                            if on { listsOff.remove(source) } else { listsOff.insert(source) }
                            model.setCollection(source, on: on)
                        }))
                    }
                } header: {
                    Text("Lists")
                } footer: {
                    Text("A list that's off is hidden from the menu and stops importing. What's in it stays, and comes back when you turn it on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Quit Clew") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                        .accessibilityLabel(Text("Quit Clew"))
                }
                case .summaries:
                Section {
                    summaryRow(Text("Morning"), enabled: \.morningEnabled, time: \.morningTime)
                    summaryRow(Text("Evening"), enabled: \.eveningEnabled, time: \.eveningTime)
                    if model.notificationsDenied {
                        NotificationsOffNotice()
                    }
                } header: {
                    Text("Summaries")
                } footer: {
                    Text("Morning: how many are on today's list. Evening: how many are done.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                case .progress:
                Section {
                    LabeledContent {
                        if let days = activeDays {
                            Text("\(days.last7) of the last 7 · \(days.last14) of the last 14")
                                .monospacedDigit()
                        }
                    } label: {
                        Text("Active days")
                    }
                    LabeledContent {
                        Text(verbatim: "\(letGoCount)").monospacedDigit()
                    } label: {
                        Text("Let go from Later")
                    }
                } footer: {
                    Text("A day with at least one tick. Letting go of what you no longer want counts as a win.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                case .calendar:
                CalendarSettings(model: model)

                case .browser:
                if let browser = model.browser {
                    BrowserSettings(connection: browser)
                } else {
                    Text("Not available in this window.").foregroundStyle(.secondary)
                }

                case .data:
                Section {
                    LabeledContent {
                        Text(verbatim: backupList.first(where: { !$0.isSafetyCopy }).map { Self.dayText($0.day) }
                             ?? String(localized: "Not yet"))
                    } label: {
                        Text("Last backup")
                    }
                    HStack {
                        Button("Restore…") { showingRestore = true }
                            .disabled(backupList.isEmpty)
                        if let restoreMessage {
                            Text(restoreMessage).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Backups")
                } footer: {
                    Text("Clew keeps a copy every day on this Mac: the last 14 days and 8 weeks before that.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Button("Export…", action: export)
                        if let exportMessage {
                            Text(exportMessage).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Everything Clew stores, as one JSON file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                case .about:
                AboutPane(updates: model.updates)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingRestore) {
            RestoreSheet(entries: backupList) { entry in
                showingRestore = false
                Task {
                    restoreMessage = await model.restore(entry)
                    reload()
                }
            } cancel: {
                showingRestore = false
            }
        }
        .frame(width: 720, height: 520)
        // The gear asks for About while a newer version is known (SPEC 2026-11-13).
        .onAppear(perform: takePaneRequest)
        .onChange(of: model.updates.paneRequest) { _, _ in takePaneRequest() }
        // A menu bar app shows no window at launch, so macOS must not restore this one
        // if it was open when Clew quit.
        .background(NonRestorableWindow())
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
    }

    private func summaryRow(_ label: Text, enabled: WritableKeyPath<SummarySettings, Bool>,
                            time: WritableKeyPath<SummarySettings, TimeOfDay>) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { summaries[keyPath: enabled] }, set: { on in
                summaries[keyPath: enabled] = on
                model.setSummaries(summaries)
            })) { label }
            Spacer()
            TimePicker(time: Binding(get: { summaries[keyPath: time] }, set: { newTime in
                summaries[keyPath: time] = newTime
                model.setSummaries(summaries)
            }), isEnabled: summaries[keyPath: enabled])
                .fixedSize()
                .accessibilityLabel(Text("Time"))
        }
    }

    private func takePaneRequest() {
        guard let request = model.updates.paneRequest else { return }
        pane = request
        model.updates.paneRequest = nil
    }

    private func reload() {
        summaries = model.summaries()
        model.checkNotificationPermission()
        openAtLogin = LoginItem.isEnabled
        if LoginItem.needsApproval {
            loginMessage = String(localized: "Allow Clew in System Settings › General › Login Items.")
        }
        activeDays = model.activeDays()
        backupList = model.backupList()
        letGoCount = model.lettingGoCount()
        ratingDots = model.ratingsOn
        barStyle = model.barStyle
        listsOff = model.collectionsOff()
        offersBreak = model.focusOffersBreak
        timelineShown = model.timelineShown
        blockAlerts = model.blockAlerts
        recordsTime = model.focusRecordsTime
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginMessage = LoginItem.setEnabled(on)
        openAtLogin = LoginItem.isEnabled
    }

    private func export() {
        guard let data = model.exportData() else {
            exportMessage = String(localized: "Export failed. Try again.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Clew \(model.today?.day.description ?? "export").json"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            exportMessage = String(localized: "Saved.")
        } catch {
            exportMessage = String(localized: "Export failed. Try again.")
        }
    }
}

extension SettingsView {
    /// "Mon, Nov 9" in the user's language.
    static func dayText(_ day: LocalDay) -> String {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour) = (day.year, day.month, day.day, 12)
        guard let date = Calendar.current.date(from: c) else { return day.description }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// Pick a backup to restore; each asks once before replacing today's data.
private struct RestoreSheet: View {
    let entries: [Backups.Entry]
    let restore: (Backups.Entry) -> Void
    let cancel: () -> Void
    @State private var confirming: Backups.Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Restore a backup").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Your current data is saved as a backup first, so a restore can be undone.")
                .font(.callout).foregroundStyle(.secondary)
            List(entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: SettingsView.dayText(entry.day))
                        if entry.isSafetyCopy {
                            Text("Saved before a restore").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Restore") { confirming = entry }
                        .accessibilityLabel(Text("Restore the backup from \(SettingsView.dayText(entry.day))"))
                }
            }
            .frame(height: 260)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .confirmationDialog(
            Text("Replace your current data with this backup?"),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { entry in
            Button("Restore", role: .destructive) { restore(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("The backup from \(SettingsView.dayText(entry.day)) replaces today's list and history. Your current data is saved first.")
        }
    }
}

/// Marks its hosting window as not restorable (works on macOS 14, unlike the macOS 15
/// `restorationBehavior` scene modifier).
private struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isRestorable = false
        }
    }
}

/// Settings › Calendar (SPEC "Calendar events"): turn calendar events on the timeline on
/// or off, and untick calendars. Clew only reads them; only the unticked ids are saved.
struct CalendarSettings: View {
    let model: AppModel
    @State private var hidden: Set<String> = []

    var body: some View {
        Section {
            Toggle("Show calendar events on the timeline", isOn: Binding(get: { model.calendarShown },
                                                                        set: { model.setCalendarShown($0) }))
            if model.calendarShown, model.calendarAccess == .denied {
                HStack {
                    Text("Clew isn't allowed to read your calendar.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Privacy Settings…") { EventKitCalendar.openPrivacySettings() }
                        .accessibilityLabel(Text("Open calendar privacy settings"))
                }
            }
        } footer: {
            Text("Today's events appear on the timeline next to your tasks. Clew only reads them: it never changes a calendar, and never saves or sends your events anywhere. Google, iCloud and other accounts show once added in System Settings › Internet Accounts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if model.calendarShown, model.calendarAccess == .granted {
            let calendars = model.calendars()
            ForEach(Array(Dictionary(grouping: calendars, by: \.source).keys.sorted()), id: \.self) { source in
                Section {
                    ForEach(calendars.filter { $0.source == source }) { calendar in
                        Toggle(isOn: Binding(get: { !hidden.contains(calendar.id) }, set: { on in
                            if on { hidden.remove(calendar.id) } else { hidden.insert(calendar.id) }
                            model.setCalendar(calendar.id, hidden: !on)
                        })) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(.sRGB, red: calendar.color[0], green: calendar.color[1], blue: calendar.color[2]))
                                    .frame(width: 8, height: 8)
                                Text(calendar.title)
                            }
                        }
                        .accessibilityLabel(Text("Show \(calendar.title)"))
                    }
                } header: {
                    Text(source)
                }
            }
            .onAppear { hidden = model.hiddenCalendars() }
        }
    }
}


/// Settings › About (SPEC 2026-11-13): who made Clew, its version, how to upgrade, and
/// the opt-in update check.
struct AboutPane: View {
    let updates: Updates
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Clew").font(.title2.weight(.semibold))
                    Text("Version \(updates.versionText) (\(updates.buildText))")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 4) {
                        Text("Made by Zihao Qi")
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Link(destination: Updates.author) { Text(verbatim: "github.com/Zihao-Qi") }
                    }
                    Link(destination: Updates.repository) { Text("Clew on GitHub") }
                }
            }
            .padding(.vertical, 4)
        }
        // Showing About clears the dot (SPEC: open on About and not minimized).
        .background(AboutVisibility(updates: updates))

        Section {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updates.state.isOn },
                set: { updates.setOn($0) }))
            if let newer = updates.available {
                HStack {
                    Text("Clew \(newer.description) is available.")
                    Link(destination: Updates.releasePage(newer)) { Text("Release notes") }
                }
            }
            LabeledContent {
                Text(verbatim: updates.state.lastSuccess.map {
                    $0.formatted(date: .abbreviated, time: .shortened)
                } ?? String(localized: "Never"))
            } label: {
                Text("Last checked")
            }
            HStack {
                Button { updates.checkNow() } label: {
                    updates.checking ? Text("Checking…") : Text("Check Now")
                }
                .disabled(updates.checking)
                if let message = updates.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Clew asks GitHub for its latest release, at most once a day. Nothing about you or your data is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("With Homebrew")
                HStack {
                    Text(verbatim: Updates.brewCommand)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(action: copy) { copied ? Text("Copied") : Text("Copy") }
                        .accessibilityLabel(copied ? Text("Copied") : Text("Copy the Homebrew command"))
                }
            }
            HStack(spacing: 4) {
                Text("Otherwise")
                Link(destination: Updates.latestPage) { Text("Download the latest release") }
            }
        } header: {
            Text("How to upgrade")
        } footer: {
            Text("The browser extension is on the same page (Clew-Extension zip); load the new one in your browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Updates.brewCommand, forType: .string)
        copied = true
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}

/// Tells `Updates` while About is on screen in a window that is not minimized.
private struct AboutVisibility: NSViewRepresentable {
    let updates: Updates

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.updates = updates
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { probe.updates = updates }

    static func dismantleNSView(_ probe: Probe, coordinator: ()) {
        // Another section was picked (or the window closed): About is not on screen.
        probe.stop()
        probe.updates?.aboutShowing = false
    }

    final class Probe: NSView {
        weak var updates: Updates?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willCloseNotification] {
                let closing = name == NSWindow.willCloseNotification
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(closing: closing) }
                })
            }
            report(closing: false)
        }

        func report(closing: Bool) {
            guard let updates else { return }
            let showing = !closing && window != nil && window?.isMiniaturized == false
            if updates.aboutShowing != showing { updates.aboutShowing = showing }
        }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if window == nil, updates?.aboutShowing == true { updates?.aboutShowing = false }
        }
    }
}
