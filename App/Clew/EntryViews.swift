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
    @State private var kindChosenByUser = false
    @State private var schedule = ScheduleDraft()
    @State private var target = 30
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(text: $text) { Text("Name or link") }
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .accessibilityLabel(Text("Name or link"))
                .onChange(of: text) {
                    // SPEC §5: a pasted link goes to Later unless you chose otherwise.
                    guard !kindChosenByUser else { return }
                    kind = QuickEntry.parse(text).isBareLink ? .later : .today
                }

            Picker(selection: Binding(get: { kind }, set: { kind = $0; kindChosenByUser = true })) {
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

    private func save() {
        let parsed = QuickEntry.parse(text)
        let shape: NewItemShape = switch kind {
        case .today: .today
        case .later: .later
        case .habit: .habit(schedule.schedule)
        case .goal: .goal(target: target, schedule: schedule.schedule)
        }
        if model.add(NewItem(title: parsed.title, url: parsed.url, shape: shape)) {
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

    init(model: AppModel, item: Item, done: @escaping () -> Void) {
        self.model = model
        self.item = item
        self.done = done
        _title = State(initialValue: item.title)
        _link = State(initialValue: item.url?.absoluteString ?? "")
        _schedule = State(initialValue: ScheduleDraft(item.schedule))
        _target = State(initialValue: item.progress.target ?? 30)
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
        if model.edit(item.id, edit) { done() }
    }
}

struct PickView: View {
    let model: AppModel
    let done: () -> Void

    @State private var items: [Item] = []
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

            NoticeView(text: model.notice)

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
        .onAppear { items = model.laterItems() }
    }

    private var pickList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                            Toggle(isOn: binding(for: item.id)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).lineLimit(1)
                                    if let host = item.url?.host {
                                        Text(verbatim: host).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!picked.contains(item.id) && picked.count >= Clew.maxPicks)
                            .accessibilityLabel(Text(item.title))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
