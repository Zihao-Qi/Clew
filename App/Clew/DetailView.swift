import ClewCore
import ClewDomain
import SwiftUI

/// A task's details (opened by clicking its row). Habits and goals: how it is going,
/// a GitHub-style heatmap, and Edit / Delete. One-off items (once-tasks, saved links,
/// videos): where it is, how much was watched, and a short history (SPEC decision
/// 2026-11-09). Only what got done is shown: no streaks, no "missed", no red (SPEC
/// design rules).
struct DetailView: View {
    let model: AppModel
    let itemId: UUID
    let onEdit: (Item) -> Void
    let onBack: () -> Void

    /// False for a double-click's length after opening: the second click of a
    /// double-click on a block or row lands here and must not hit Delete or Back (SPEC
    /// 2026-11-13).
    @State private var takesClicks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onBack) {
                Label("Today", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Back to today's list"))

            if let details = model.details(for: itemId) {
                header(details)
                if details.isOneOff {
                    if Clew.canHaveSteps(details.item) {
                        DetailSteps(model: model, task: details.item)
                    }
                    OneOffDetails(moved: model.today?.moved.contains(itemId) == true, details: details)
                } else if details.item.kind == .goal {
                    // Bars or Heatmap, the user's choice (SPEC 2026-11-18).
                    GoalDaysSection(model: model, details: details)
                    statTiles(details)
                } else {
                    Heatmap(details: details)
                    statTiles(details)
                }
                FocusSection(model: model, itemId: itemId)
                HStack {
                    if details.isOneOff, let url = details.item.url {
                        Button(Self.isVideo(details.item) ? "Open video" : "Open link") { model.open(url) }
                            .keyboardShortcut(.defaultAction)
                    }
                    Button("Edit…") { onEdit(details.item) }
                    Spacer()
                    Button("Delete", role: .destructive) {
                        model.delete(itemId)
                        onBack()
                    }
                }
            } else {
                Text("This item is gone.").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .overlay {
            if !takesClicks {
                Color.clear.contentShape(Rectangle()).accessibilityHidden(true)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            takesClicks = true
        }
    }

    private func header(_ d: ItemDetails) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(d.item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let url = d.item.url {
                    Button { model.open(url) } label: { Image(systemName: "link") }
                        .buttonStyle(.borderless)
                        .help(url.absoluteString)
                        .accessibilityLabel(Text("Open link for \(d.item.title)"))
                }
            }
            Text(Self.summary(of: d))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !d.stats.feltCounts.isEmpty {
                // Counts only, never a score.
                Text(verbatim: String(localized: "Felt:") + " " + d.stats.feltHighFirst.map { "\(RatingDots.word($0.rating)) \($0.count)" }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statTiles(_ d: ItemDetails) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let target = d.item.progress.target {
                tile(value: "\(d.progressAmount)/\(target)", label: Text("This round"))
                tile(value: "\(d.stats.roundsFinished ?? 0)", label: Text("Rounds done"))
                tile(value: "\(d.stats.totalAmount)", label: Text("All time"))
            } else {
                tile(value: "\(d.stats.daysThisWeek)", label: Text("Days this week"))
                tile(value: "\(d.stats.daysLast30)", label: Text("Last 30 days"))
                tile(value: "\(d.stats.daysAllTime)", label: Text("All time"))
            }
        }
    }

    private func tile(value: String, label: Text) -> some View {
        StatTile(value: value, label: label)
    }
}

/// A number with a caption, as on the details pages.
struct StatTile: View {
    let value: String
    let label: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value).font(.title3.monospacedDigit().weight(.semibold))
            label.font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
}

extension DetailView {
    static func isVideo(_ item: Item) -> Bool {
        item.source == .extensionYouTube || item.url?.host?.hasSuffix("youtube.com") == true
    }

    /// "Goal · Daily · Reminder 6:00 PM", in the user's language.
    static func summary(of d: ItemDetails) -> String {
        var parts: [String] = []
        switch d.item.kind {
        case .once: parts.append(String(localized: "Once"))
        case .link: parts.append(String(localized: "Saved link"))
            if d.item.source == .extensionYouTube { parts.append(String(localized: "YouTube Watch Later")) }
        case .habit: parts.append(String(localized: "Habit"))
        case .goal: parts.append(String(localized: "Goal"))
        }
        switch d.item.schedule {
        case .daily: parts.append(String(localized: "Daily"))
        case .weekdays(let days):
            parts.append(days.sorted().map { ScheduleEditor.shortWeekdayName($0) }.joined(separator: " "))
        case .timesPerWeek(let n): parts.append(String(localized: "\(n)× a week"))
        case .unscheduled: break
        }
        if let r = d.reminder {
            let time = r.time.pickerDate.formatted(date: .omitted, time: .shortened)
            parts.append(r.day == nil ? String(localized: "Reminder \(time)") : String(localized: "Reminder \(time) today"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A one-off item's page body: watch progress (videos), where it is now, and what
/// happened to it, newest last.
struct OneOffDetails: View {
    /// Moved to Today for today (SPEC 2026-11-15).
    var moved = false
    let details: ItemDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let watch = details.watch, watch.fraction > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        ProgressLine(fraction: watch.fraction).frame(width: 180)
                        Text("\(Int((watch.fraction * 100).rounded()))% watched")
                            .font(.callout.monospacedDigit())
                    }
                    Text("As of \(Self.day(watch.observedAt)), from Watch Later")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let status = status {
                Text(status).font(.callout)
            }
            if !details.history.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(Array(details.history.enumerated()), id: \.offset) { _, entry in
                        GridRow {
                            Text(verbatim: Self.day(entry.at))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(verbatim: line(entry.event))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Done Nov 9", "On Today" or "In Goals & Later" (SPEC 2026-11-15).
    private var status: String? {
        if let done = details.history.last(where: { if case .done = $0.event { true } else { false } }) {
            return String(localized: "Done \(Self.day(done.at))")
        }
        switch details.item.state {
        case .active: return String(localized: "On Today")
        case .later:
            if moved { return String(localized: "On Today") }
            // A day for Later (SPEC 2026-11-17).
            if let day = details.waitingFor {
                return String(localized: "Comes to Today \(day.noon.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
            }
            return String(localized: "In Goals & Later")
        case .paused, .archived: return nil
        }
    }

    private func line(_ event: HistoryEntry.Event) -> String {
        switch event {
        case .added(.extensionYouTube): String(localized: "Saved from Watch Later")
        case .added: details.item.kind == .link ? String(localized: "Saved") : String(localized: "Added")
        case .picked: String(localized: "Moved to Today")
        case .done(let rating?): String(localized: "Done · felt \(RatingDots.word(rating))")
        case .done(nil): String(localized: "Done")
        case .kept: String(localized: "Kept in Later")
        }
    }

    /// "Nov 9", in the user's language.
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// 16 Monday-to-Sunday columns ending with this week. Ticked days are filled; other
/// days are a quiet gray, never red; days after today are left blank.
struct Heatmap: View {
    let today: LocalDay
    let amountByDay: [LocalDay: Int]
    /// Goals get lighter single ticks, so days with many +1s stand out.
    var graded = false

    init(details: ItemDetails) {
        self.init(today: details.today, amountByDay: details.stats.amountByDay, graded: details.item.kind == .goal)
    }

    init(today: LocalDay, amountByDay: [LocalDay: Int], graded: Bool = false) {
        self.today = today
        self.amountByDay = amountByDay
        self.graded = graded
    }
    /// Fills the 316 pt content width exactly (the tiles' width):
    /// 10 pt labels + 16 cells + 16 gaps of 2.5 pt → cell = (316 − 10 − 40) / 16.
    private let gap: CGFloat = Self.gap
    private var cell: CGFloat { Self.cell }
    static let gap: CGFloat = 2.5
    static let cell: CGFloat = (316 - 10 - gap * CGFloat(Clew.heatmapWeeks)) / CGFloat(Clew.heatmapWeeks)
    /// Seven rows: a goal's Bars take the same height, so switching does not resize the menu.
    static let height: CGFloat = 7 * cell + 6 * gap

    var body: some View {
        let columns = heatmapColumns(endingAt: today, weeks: Clew.heatmapWeeks)
        let doneDays = columns.joined().compactMap { $0 }.filter { (amountByDay[$0] ?? 0) > 0 }.count
        let shown = columns.joined().compactMap { $0 }.count
        HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .trailing, spacing: gap) {
                ForEach(Weekday.allCases, id: \.self) { day in
                    Text(verbatim: day == .monday || day == .wednesday || day == .friday
                         ? ScheduleEditor.shortName(day) : "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 10, height: cell)
                }
            }
            ForEach(columns.indices, id: \.self) { c in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { r in
                        square(columns[c][r])
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Done on \(doneDays) of the last \(shown) days"))
    }

    @ViewBuilder private func square(_ day: LocalDay?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        if let day {
            shape
                .fill(fill(amountByDay[day] ?? 0))
                .overlay { if day == today { shape.stroke(Color.primary.opacity(0.5), lineWidth: 1) } }
                .frame(width: cell, height: cell)
                .help(Text(verbatim: day.description))
        } else {
            Color.clear.frame(width: cell, height: cell)
        }
    }

    /// One shade for a done day; goals get deeper shades for more +1s in a day.
    private func fill(_ amount: Int) -> Color {
        switch amount {
        case 0: Color.primary.opacity(0.07)
        case 1: Color.accentColor.opacity(graded ? 0.45 : 0.8)
        case 2...3: Color.accentColor.opacity(0.7)
        default: Color.accentColor.opacity(0.95)
        }
    }
}

/// A task's focus time (SPEC decision 2026-11-10): this week and all time, the latest
/// sessions (each removable), and "Add time…" for work done without the timer.
struct FocusSection: View {
    let model: AppModel
    let itemId: UUID

    @State private var adding = false
    @State private var day = Date()
    @State private var minutes = 25

    var body: some View {
        // Reading the summary through the model re-renders after every change.
        let summary = model.focusSummary(for: itemId)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Focus").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !adding {
                    Button("Add time…") {
                        day = model.focusLatestDay
                        minutes = 25
                        adding = true
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Add focus time by hand"))
                }
            }
            if let summary, summary.total > 0 {
                Text(verbatim: String(localized: "\(Self.duration(summary.thisWeek)) this week") + " · "
                    + String(localized: "\(Self.duration(summary.total)) in all"))
                    .font(.callout)
                ForEach(summary.recent) { session in
                    HStack(spacing: 6) {
                        Text(verbatim: Self.dayLabel(session.localDay) + " · " + Self.duration(session.minutes)
                             + (session.kind == .manual ? " · " + String(localized: "by hand") : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { model.removeFocusSession(session.id) } label: {
                            Image(systemName: "xmark").imageScale(.small)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Remove \(Self.duration(session.minutes)) on \(Self.dayLabel(session.localDay))"))
                    }
                }
            } else if !adding {
                Text("No focus time yet. Use the timer (right-click the task → Focus), or add time you worked without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if adding { form }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            DatePicker("Day", selection: $day, in: ...model.focusLatestDay, displayedComponents: .date)
                .datePickerStyle(.field)
            Stepper(value: $minutes, in: 1...Clew.maxFocusMinutes, step: 5) {
                HStack(spacing: 4) {
                    Text("Minutes")
                    TextField("Minutes", value: $minutes, format: .number)
                        .frame(width: 52)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(Text("Minutes worked"))
                }
            }
            HStack {
                Button("Add") {
                    if model.addFocusTime(itemId, on: day, minutes: minutes) { adding = false }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel") { adding = false }
            }
            .controlSize(.small)
        }
    }

    /// "25 min", "1 h", "2 h 5 min".
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return String(localized: "\(m) min") }
        return m == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(m) min")
    }

    /// "Nov 9", in the user's language.
    static func dayLabel(_ day: LocalDay) -> String {
        var c = DateComponents()
        c.year = day.year
        c.month = day.month
        c.day = day.day
        guard let date = Calendar.current.date(from: c) else { return day.description }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A task's steps on its details (SPEC 2026-11-21): tick, rename and delete them, and add
/// one (not on a done task). Shown when it has steps or can take one. Nothing here takes
/// the keyboard until clicked, so typing on the page never renames a step by accident.
struct DetailSteps: View {
    let model: AppModel
    let task: Item

    @State private var adding = false
    @State private var newStep = ""
    @State private var ask = SuggestionAsk()
    @FocusState private var addFocused: Bool

    private var steps: [TaskSteps.Entry] { model.allSteps(of: task.id) }
    private var canAdd: Bool { model.row(task.id).map(model.canAddStep) ?? false }

    var body: some View {
        if !steps.isEmpty || canAdd {
            VStack(alignment: .leading, spacing: 4) {
                Text("Steps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(steps) { entry in
                    DetailStepRow(model: model, entry: entry)
                }
                // Suggestions go under the steps (SPEC "Suggest steps").
                SuggestionList(ask: ask, leading: 0, trailing: 0) { model.addSuggestedStep(to: task.id, title: $0) }
                if canAdd {
                    if adding {
                        HStack(spacing: 6) {
                            Image(systemName: "circle")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            TextField(text: $newStep) { Text("New step") }
                                .textFieldStyle(.plain)
                                .focused($addFocused)
                                .debugFrame("detailNew:\(task.id)")
                                .onSubmit(add)
                                .onExitCommand { adding = false; newStep = ""; ask.cancel() }
                                .accessibilityLabel(Text("New step of \(task.title)"))
                            if model.canSuggestSteps(task.id) || ask.isThinking {
                                SuggestButton(ask: ask, title: false, start: suggest)
                            }
                        }
                        .onAppear { DispatchQueue.main.async { addFocused = true } }
                    } else {
                        HStack(spacing: 12) {
                            Button { adding = true } label: { Label("Add Step", systemImage: "plus") }
                                .buttonStyle(.borderless)
                                .debugFrame("detailAdd:\(task.id)")
                                .accessibilityLabel(Text("Add a step to \(task.title)"))
                            if model.canSuggestSteps(task.id) || ask.isThinking {
                                SuggestButton(ask: ask, title: true, start: suggest)
                            }
                        }
                    }
                }
                // A refused name (too long) says why here too (review).
                NoticeView(text: model.notice).padding(.horizontal, -12)
            }
            // The task got done (its last step, its circle): the line goes and drops its text (review),
            // and no suggestion appears later.
            .onChange(of: canAdd) { _, now in if !now { adding = false; newStep = ""; ask.cancel() } }
            // Leaving the details or the rollover drops them too (SPEC "Suggest steps").
            .onDisappear { ask.cancel() }
            .onChange(of: model.today?.day) { ask.cancel() }
            // The details stay mounted while the menu is closed (review).
            .onChange(of: model.menuCloses) { ask.cancel() }
        }
    }

    private func suggest() {
        guard let ai = model.ai, model.canSuggestSteps(task.id), let input = model.suggestInput(task.id) else { return }
        ask.ask(ai, input)
    }

    /// Return adds the step and keeps the line for another; Return on an empty line closes it.
    private func add() {
        guard !newStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            adding = false
            ask.cancel()
            return
        }
        if model.addStep(to: task.id, title: newStep) {
            newStep = ""
            DispatchQueue.main.async { addFocused = true }
        }
    }
}

/// One step on the details: its circle, its title (click to rename in place), and Delete.
private struct DetailStepRow: View {
    let model: AppModel
    let entry: TaskSteps.Entry

    @State private var editing = false
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { model.tapStep(entry) } label: {
                Image(systemName: entry.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(entry.isDone ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(entry.isDone ? Text("Undo \(entry.step.title)") : Text("Mark \(entry.step.title) done"))
            if editing {
                TextField(text: $title) { Text(verbatim: entry.step.title) }
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(rename)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, now in if !now { rename() } }
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .accessibilityLabel(Text("Name of the step \(entry.step.title)"))
            } else {
                Text(entry.step.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(entry.isDone ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { title = entry.step.title; editing = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Rename"))
                    .accessibilityAction { title = entry.step.title; editing = true }
            }
            Button { model.deleteStep(entry.step) } label: {
                Image(systemName: "xmark").imageScale(.small).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Text("Delete"))
            .accessibilityLabel(Text("Delete \(entry.step.title)"))
        }
    }

    /// An empty name goes back to the step's own; a refused one (too long) stays open
    /// with its text, and the notice says why.
    private func rename() {
        guard editing else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.step.title else { editing = false; return }
        if model.renameStep(entry.step.id, trimmed) { editing = false }
    }
}
