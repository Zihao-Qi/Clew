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
        case general, summaries, progress, browser, data
        var id: String { rawValue }
        var title: Text {
            switch self {
            case .general: Text("General")
            case .summaries: Text("Summaries")
            case .progress: Text("Progress")
            case .browser: Text("Browser")
            case .data: Text("Data")
            }
        }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .summaries: "bell"
            case .progress: "chart.bar"
            case .browser: "puzzlepiece.extension"
            case .data: "externaldrive"
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
        .frame(width: 620, height: 440)
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
