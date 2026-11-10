import ClewCore
import ClewDomain
import SwiftUI

/// What `+ add` creates. Mirrors `NewItemShape` for the picker.
enum AddKind: Hashable, CaseIterable {
    case today, habit, goal, later
}

/// Editable form of a habit or goal schedule.
struct ScheduleDraft: Equatable {
    enum Mode: Hashable { case daily, days, perWeek }
    var mode: Mode = .daily
    var days: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    var times = 3

    init() {}

    init(_ schedule: Schedule) {
        switch schedule {
        case .daily, .unscheduled: mode = .daily
        case .weekdays(let d): mode = .days; days = d
        case .timesPerWeek(let n): mode = .perWeek; times = n
        }
    }

    var schedule: Schedule {
        switch mode {
        case .daily: .daily
        case .days: .weekdays(days)
        case .perWeek: .timesPerWeek(times)
        }
    }
}

struct ScheduleEditor: View {
    @Binding var draft: ScheduleDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(selection: $draft.mode) {
                Text("Daily").tag(ScheduleDraft.Mode.daily)
                Text("Days").tag(ScheduleDraft.Mode.days)
                Text("Per week").tag(ScheduleDraft.Mode.perWeek)
            } label: {
                Text("Repeats")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Repeats"))

            switch draft.mode {
            case .daily:
                EmptyView()
            case .days:
                HStack(spacing: 4) {
                    ForEach(Weekday.allCases, id: \.self) { day in
                        Toggle(isOn: binding(for: day)) {
                            Text(verbatim: Self.shortName(day))
                                .frame(minWidth: 18)
                        }
                        .toggleStyle(.button)
                        .accessibilityLabel(Text(verbatim: Self.fullName(day)))
                    }
                }
            case .perWeek:
                Stepper(value: $draft.times, in: 1...7) {
                    Text("\(draft.times)× a week")
                }
                .accessibilityLabel(Text("Times a week"))
                .accessibilityValue(Text("\(draft.times)"))
            }
        }
    }

    private func binding(for day: Weekday) -> Binding<Bool> {
        Binding(
            get: { draft.days.contains(day) },
            set: { on in if on { draft.days.insert(day) } else { draft.days.remove(day) } }
        )
    }

    /// Display only, in the user's language. Monday-first order comes from `Weekday`;
    /// Calendar's symbol arrays start on Sunday.
    private static func symbolIndex(_ day: Weekday) -> Int { day.rawValue % 7 }
    static func shortName(_ day: Weekday) -> String {
        Calendar.current.veryShortStandaloneWeekdaySymbols[symbolIndex(day)]
    }
    static func shortWeekdayName(_ day: Weekday) -> String {
        Calendar.current.shortStandaloneWeekdaySymbols[symbolIndex(day)]
    }
    static func fullName(_ day: Weekday) -> String {
        Calendar.current.standaloneWeekdaySymbols[symbolIndex(day)]
    }
}

struct TargetField: View {
    @Binding var target: Int

    var body: some View {
        HStack {
            Text("Total")
            TextField(value: $target, format: .number) { Text("Total") }
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text("Total"))
            Stepper(value: $target, in: 1...Clew.maxTarget) { EmptyView() }
                .labelsHidden()
                .accessibilityLabel(Text("Total"))
        }
    }
}

struct AddView: View {
    let model: AppModel
    let done: () -> Void

    @State private var text = ""
    @State private var kind: AddKind = .today
    @State private var schedule = ScheduleDraft()
    @State private var target = 30
    /// The title fetched for the pasted link, if any; it is put into the field so it
    /// can be edited, and recorded as `.fetched` only if left as fetched.
    @State private var fetchedTitle: String?
    @State private var fetchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField(text: $text) { Text("Name or link") }
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityLabel(Text("Name or link"))
                if fetchTask != nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Fetching the title"))
                }
            }
            .onChange(of: text) { textChanged() }

            Picker(selection: $kind) {
                Text("Today").tag(AddKind.today)
                Text("Habit").tag(AddKind.habit)
                Text("Goal").tag(AddKind.goal)
                Text("Later").tag(AddKind.later)
            } label: {
                Text("Kind")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Kind"))

            if kind == .habit || kind == .goal {
                ScheduleEditor(draft: $schedule)
            }
            if kind == .goal {
                TargetField(target: $target)
            }

            NoticeView(text: model.notice)

            HStack {
                Spacer()
                Button("Cancel", action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func textChanged() {
        // A link is added to Today like anything else; Later only when chosen (SPEC §5).
        let parsed = QuickEntry.parse(text)
        if parsed.isBareLink, let url = parsed.url {
            fetchTitle(url, typed: text)
        }
    }

    /// Fills in the page title, unless the user has typed something else meanwhile.
    private func fetchTitle(_ url: URL, typed: String) {
        fetchTask?.cancel()
        fetchTask = Task {
            let title = await model.fetchTitle(for: url)
            guard !Task.isCancelled else { return }
            fetchTask = nil
            if let title, text == typed {
                fetchedTitle = title
                text = "\(title) \(url.absoluteString)"
            }
        }
    }

    private func save() {
        fetchTask?.cancel()
        fetchTask = nil
        let parsed = QuickEntry.parse(text)
        let shape: NewItemShape = switch kind {
        case .today: .today
        case .later: .later
        case .habit: .habit(schedule.schedule)
        case .goal: .goal(target: target, schedule: schedule.schedule)
        }
        let origin: TitleOrigin = parsed.title == fetchedTitle ? .fetched : .typed
        if model.add(NewItem(title: parsed.title, titleOrigin: origin, url: parsed.url, shape: shape)) {
            done()
            if kind == .later { model.confirmSavedToLater() }
        }
    }
}

struct EditView: View {
    let model: AppModel
    let item: Item
    let done: () -> Void

    @State private var title: String
    @State private var link: String
    @State private var schedule: ScheduleDraft
    @State private var target: Int
    @State private var remind: Bool
    @State private var remindAt: TimeOfDay
    private let existingReminder: Reminder?

    init(model: AppModel, item: Item, done: @escaping () -> Void) {
        self.model = model
        self.item = item
        self.done = done
        _title = State(initialValue: item.title)
        _link = State(initialValue: item.url?.absoluteString ?? "")
        _schedule = State(initialValue: ScheduleDraft(item.schedule))
        _target = State(initialValue: item.progress.target ?? 30)
        let reminder = model.reminder(for: item.id)
        existingReminder = reminder
        _remind = State(initialValue: reminder != nil)
        _remindAt = State(initialValue: reminder?.time ?? TimeOfDay(hour: 18, minute: 0)!)
    }

    private var hasSchedule: Bool { item.kind == .habit || item.kind == .goal }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(text: $title) { Text("Name") }
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Name"))
            TextField(text: $link) { Text("Link (optional)") }
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Link"))
            if hasSchedule {
                ScheduleEditor(draft: $schedule)
            }
            if item.kind == .goal {
                TargetField(target: $target)
            }
            ReminderRow(enabled: $remind, time: $remindAt)
            if model.notificationsDenied, remind {
                NotificationsOffNotice()
            }

            NoticeView(text: model.notice)

            HStack {
                Spacer()
                Button("Cancel", action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func save() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if trimmed.isEmpty {
            url = nil
        } else if let parsed = URL(string: trimmed) {
            url = parsed
        } else {
            model.notice = AppModel.message(for: .invalidURL)
            return
        }
        let edit = ItemEdit(
            title: title, url: url,
            schedule: hasSchedule ? schedule.schedule : nil,
            target: item.kind == .goal ? target : nil
        )
        guard model.edit(item.id, edit) else { return }
        let wanted: TimeOfDay? = remind ? remindAt : nil
        if wanted != existingReminder?.time {
            guard model.setReminder(item.id, wanted) else { return }
        }
        done()
    }
}

struct PickView: View {
    let model: AppModel
    let done: () -> Void

    @State private var items: [LaterEntry] = []
    @State private var picked: [UUID] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick 1–3 for today")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if items.isEmpty {
                Text("Later is empty.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if items.count <= 6 {
                pickList
            } else {
                // A menu bar window sizes to its content, so the scroll area needs a
                // fixed height or it collapses to one row.
                ScrollView { pickList }
                    .frame(height: 280)
            }

            NoticeView(text: model.notice ?? model.confirmation)

            HStack {
                Spacer()
                Button("Cancel", action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Add to today") {
                    if model.pick(picked) { done() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(12)
        .onAppear { items = model.laterPile() }
    }

    private var pickList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { entry in
                let item = entry.item
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Toggle(isOn: binding(for: item.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(1)
                                let host = item.url?.host
                                if host != nil || entry.asksStillWant {
                                    Text(verbatim: [host, entry.asksStillWant ? Self.weeks(entry.daysWaiting) : nil]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if model.barStyle == .underTitle, let watched = entry.watched, watched > 0 {
                                    ProgressLine(fraction: watched).padding(.top, 1)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!picked.contains(item.id) && picked.count >= Clew.maxPicks)
                        .accessibilityLabel(Text(item.title))
                        .accessibilityValue(Self.watchedValue(entry))
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button { delete(item) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Delete \(item.title)"))
                    }
                    // SPEC §5: waited 6+ weeks untouched. Saying no counts as a win.
                    if entry.asksStillWant {
                        HStack(spacing: 8) {
                            Text("Still want this?").font(.caption).foregroundStyle(.secondary)
                            Button("Keep") { keep(item) }
                                .accessibilityLabel(Text("Keep \(item.title)"))
                            Button("Let go") { letGo(item) }
                                .accessibilityLabel(Text("Let go of \(item.title)"))
                        }
                        .controlSize(.small)
                        .padding(.leading, 22)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background {
                    if model.barStyle == .behindTitle, let watched = entry.watched, watched > 0 {
                        ProgressFill(fraction: watched)
                    }
                }
                .contextMenu {
                    Button("Delete", role: .destructive) { delete(item) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "40 percent watched" for a started video, read with its title.
    static func watchedValue(_ entry: LaterEntry) -> Text {
        guard let watched = entry.watched, watched > 0 else { return Text(verbatim: "") }
        return Text("\(Int((watched * 100).rounded())) percent watched")
    }

    /// "7 weeks", in the user's language.
    static func weeks(_ days: Int) -> String {
        String(localized: "\(days / 7) weeks")
    }

    private func keep(_ item: Item) {
        model.keepLater(item.id)
        items = model.laterPile()
    }

    private func letGo(_ item: Item) {
        model.letGo(item.id)
        picked.removeAll { $0 == item.id }
        items = model.laterPile()
    }

    private func delete(_ item: Item) {
        model.delete(item.id)
        picked.removeAll { $0 == item.id }
        items = model.laterPile()
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { picked.contains(id) },
            set: { on in
                if on { if !picked.contains(id) { picked.append(id) } } else { picked.removeAll { $0 == id } }
            }
        )
    }
}

extension TimeOfDay {
    /// Today at this time, for a DatePicker (display only; Core works with TimeOfDay).
    var pickerDate: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    init(pickerDate date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        self = TimeOfDay(hour: c.hour ?? 9, minute: c.minute ?? 0) ?? TimeOfDay(hour: 9, minute: 0)!
    }
}

/// "Remind me [18:00]": one gentle notification on each day the item is on the list.
struct ReminderRow: View {
    @Binding var enabled: Bool
    @Binding var time: TimeOfDay

    var body: some View {
        HStack {
            Toggle("Remind me", isOn: $enabled)
                .accessibilityLabel(Text("Remind me"))
            if enabled {
                TimePicker(time: $time)
                    .fixedSize()
                    .accessibilityLabel(Text("Reminder time"))
            }
            Spacer()
        }
    }
}

struct NotificationsOffNotice: View {
    var body: some View {
        HStack {
            Text("Notifications are off for Clew.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Turn on…") { NotificationsAdapter.openSystemSettings() }
                .accessibilityLabel(Text("Open notification settings"))
        }
    }
}
