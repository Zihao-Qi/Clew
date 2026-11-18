import ClewCore
import ClewDomain
import SwiftUI

/// What `+ add` creates. Mirrors `NewItemShape` for the picker.
enum AddKind: Hashable, CaseIterable {
    case today, habit, goal, later

    /// The line under the choice (SPEC 2026-11-17, wording confirmed by the user).
    var explanation: LocalizedStringKey {
        switch self {
        case .today: "Done once. Stays on Today until you tick it."
        case .habit: "Comes back to Today when it repeats."
        case .goal: "A total to reach, one +1 at a time. Lives in Goals & Later."
        case .later: "For another day. Waits in Goals & Later until you get to it."
        }
    }

    /// With "On a day" switched on (SPEC 2026-11-17).
    static var laterOnADay: LocalizedStringKey { "Comes to Today on that day." }
}

/// Editable form of a habit's schedule.
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

    init(model: AppModel, done: @escaping () -> Void) {
        self.model = model
        self.done = done
    }

    #if DEBUG
    /// Snapshots: Add with a kind chosen and "On a day" on or off.
    init(model: AppModel, kind: AddKind, onADay: Bool, text: String = "", done: @escaping () -> Void) {
        self.model = model
        self.done = done
        _kind = State(initialValue: kind)
        _onADay = State(initialValue: onADay)
        _text = State(initialValue: text)
    }
    #endif

    @State private var text = ""
    @State private var kind: AddKind = .today
    @State private var schedule = ScheduleDraft()
    @State private var target = 30
    @State private var slot = SlotDraft()
    /// A Later task's day (SPEC 2026-11-17).
    @State private var onADay = false
    @State private var day = Date()
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

            // The type line sits close under the choice it explains (design review).
            VStack(alignment: .leading, spacing: 4) {
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

                // What each kind is, since it cannot be changed later (SPEC 2026-11-17).
                Text(kind == .later && onADay ? AddKind.laterOnADay : kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Goals have a total only; they live in Goals & Later (SPEC 2026-11-15).
            if kind == .habit {
                ScheduleEditor(draft: $schedule)
            }
            if kind == .goal {
                TargetField(target: $target)
            }
            if kind == .habit {
                SlotRow(draft: $slot)
            }
            if kind == .later {
                DayRow(model: model, on: $onADay, date: $day)
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
            .padding(.top, 4)
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
        case .goal: .goal(target: target)
        }
        let origin: TitleOrigin = parsed.title == fetchedTitle ? .fetched : .typed
        let timeSlot = kind == .habit ? slot.slot : nil
        let laterDay = kind == .later && onADay ? LocalDay(picked: day) : nil
        if model.add(NewItem(title: parsed.title, titleOrigin: origin, url: parsed.url, shape: shape, slot: timeSlot,
                             laterDay: laterDay)) {
            done()
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
    /// Today only, or every day (SPEC 2026-11-15).
    @State private var remindToday = false
    @State private var slot: SlotDraft
    private let existingReminder: Reminder?
    /// A day for Later (SPEC 2026-11-17): offered on a once task or link with no tick.
    private let canHaveDay: Bool
    private let existingDay: LocalDay?
    @State private var onADay: Bool
    @State private var day: Date

    init(model: AppModel, item: Item, done: @escaping () -> Void) {
        self.model = model
        self.item = item
        self.done = done
        _title = State(initialValue: item.title)
        _link = State(initialValue: item.url?.absoluteString ?? "")
        _schedule = State(initialValue: ScheduleDraft(item.schedule))
        _target = State(initialValue: item.progress.target ?? 30)
        _slot = State(initialValue: SlotDraft(item.slot))
        let reminder = model.reminder(for: item.id)
        existingReminder = reminder
        _remind = State(initialValue: reminder != nil)
        _remindToday = State(initialValue: reminder?.day != nil)
        _remindAt = State(initialValue: reminder?.time ?? TimeOfDay(hour: 18, minute: 0)!)
        canHaveDay = model.row(item.id).map(model.canHaveDay) ?? false
        existingDay = model.laterDay(item.id)
        _onADay = State(initialValue: existingDay != nil)
        _day = State(initialValue: existingDay?.noon ?? Date())
    }

    /// The day as it will be saved, if it differs from the one it has.
    private var dayChanged: Bool {
        guard canHaveDay else { return false }
        let wanted = onADay ? LocalDay(picked: day) : nil
        return wanted != existingDay
    }

    /// The reminder (on/off, time, Today / Every day) differs from the saved one.
    private var reminderChanged: Bool {
        let wanted: TimeOfDay? = remind ? remindAt : nil
        return wanted != existingReminder?.time || (wanted != nil && remindToday != (existingReminder?.day != nil))
    }

    /// Only habits repeat (goals lost "Repeats" and their slot, SPEC 2026-11-15).
    private var hasSchedule: Bool { item.kind == .habit }

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
            if hasSchedule {
                SlotRow(draft: $slot)
            }
            if canHaveDay {
                DayRow(model: model, on: $onADay, date: $day)
            }
            ReminderRow(enabled: $remind, time: $remindAt, today: $remindToday,
                        passed: reminderChanged && remind && remindToday && model.reminderTimePassed(remindAt))
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
            target: item.kind == .goal ? target : nil,
            slot: hasSchedule ? .set(slot.slot) : .keep
        )
        let wanted: TimeOfDay? = remind ? remindAt : nil
        // Today at a passed time: nothing is saved until the time or the choice changes.
        // An unchanged Today reminder whose time has passed is left as it is (Gemini
        // review: it blocked every other edit that day).
        if reminderChanged, let wanted, remindToday, model.reminderTimePassed(wanted) {
            model.notice = AppModel.message(for: .reminderTimePassed)
            return
        }
        guard model.edit(item.id, edit) else { return }
        if reminderChanged {
            guard model.setReminder(item.id, wanted, todayOnly: remindToday) else { return }
        }
        if dayChanged {
            guard model.setLaterDay(item.id, onADay ? LocalDay(picked: day) : nil) else { return }
        }
        done()
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

/// A repeating task's time slot as edited: on or off, a start and a length.
struct SlotDraft: Equatable {
    var enabled = false
    var hour = 8
    var quarter = 0
    var minutes = 60

    init() {}

    init(_ slot: TimeSlot?) {
        guard let slot else { return }
        enabled = true
        hour = slot.hour
        quarter = slot.minute / 15
        minutes = slot.minutes
    }

    var slot: TimeSlot? { enabled ? TimeSlot(hour: hour, minute: quarter * 15, minutes: minutes) : nil }
}

/// "On the timeline [8 AM] [:00] [60 min]": the block Clew places by itself each day the
/// task is due (SPEC 2026-11-10). Moving it on the timeline changes only that day.
struct SlotRow: View {
    @Binding var draft: SlotDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("On the timeline", isOn: $draft.enabled)
                .accessibilityLabel(Text("Put it on the timeline each day it is due"))
            if draft.enabled {
                HStack(spacing: 6) {
                    Picker(selection: $draft.hour) {
                        ForEach(0..<24, id: \.self) { h in Text(verbatim: Self.hourText(h)).tag(h) }
                    } label: { EmptyView() }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(Text("Slot hour"))
                    Picker(selection: $draft.quarter) {
                        ForEach(0..<4, id: \.self) { q in Text(verbatim: String(format: ":%02d", q * 15)).tag(q) }
                    } label: { EmptyView() }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(Text("Slot minutes"))
                    Picker(selection: $draft.minutes) {
                        ForEach(TimeSlot.lengths, id: \.self) { m in Text("\(m) min").tag(m) }
                    } label: { EmptyView() }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(Text("Slot length"))
                    Spacer()
                }
            }
        }
    }

    static func hourText(_ hour: Int) -> String {
        (Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()).formatted(.dateTime.hour())
    }
}

/// "Remind me [18:00] [Today | Every day]": one gentle notification, today only or on
/// each day the item is in a list and not done (SPEC 2026-11-15).
struct ReminderRow: View {
    @Binding var enabled: Bool
    @Binding var time: TimeOfDay
    @Binding var today: Bool
    /// Today at a time already past: said under the row, and Save is refused.
    var passed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Remind me", isOn: $enabled)
                    .fixedSize()
                    .accessibilityLabel(Text("Remind me"))
                if enabled {
                    TimePicker(time: $time)
                        .fixedSize()
                        .accessibilityLabel(Text("Reminder time"))
                }
                Spacer()
            }
            if enabled {
                // On its own line, under the switch's label, so "Remind me" never wraps.
                Picker(selection: $today) {
                    Text("Today").tag(true)
                    Text("Every day").tag(false)
                } label: {
                    Text("Repeat")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .padding(.leading, 20)
                .accessibilityLabel(Text("Remind today or every day"))
            }
            if passed {
                Text("That time has passed today.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
