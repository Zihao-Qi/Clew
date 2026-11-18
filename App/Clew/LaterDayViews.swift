import ClewCore
import ClewDomain
import SwiftUI

// A day for Later (SPEC 2026-11-17): the day a waiting row shows, the right-click
// "Later until ›" menu, the "Pick a day…" screen, and Add's and Edit's "On a day" row.

extension LocalDay {
    /// Noon on this calendar date, for date pickers and formatting (never for timing).
    var noon: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    /// The calendar date a date picker shows (the picker has no rollover).
    init(picked date: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self = LocalDay(year: c.year ?? 1, month: c.month ?? 1, day: c.day ?? 1) ?? LocalDay(ordinal: 0)
    }
}

/// "Tomorrow", "Thu" or "Nov 27".
func dayLabel(_ day: LocalDay, today: LocalDay) -> String {
    switch DayLabel(day, today: today) {
    case .tomorrow: String(localized: "Tomorrow")
    case .weekday(let d): d.noon.formatted(.dateTime.weekday(.abbreviated))
    case .date(let d): d.noon.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Right-click › Later until ›, for a row that can have a day.
struct LaterUntilMenu: View {
    let row: TodayRow
    let model: AppModel
    let onPick: () -> Void

    var body: some View {
        if let today = model.currentDay {
            Menu("Later until") {
                Button("Tomorrow") { model.setLaterDay(row.id, today.adding(days: 1)) }
                if Clew.nextMonday(after: today) != today.adding(days: 1) {
                    Button("Next Monday") { model.setLaterDay(row.id, Clew.nextMonday(after: today)) }
                }
                Button("Pick a day…", action: onPick)
                if model.waitingDay(row) != nil {
                    Divider()
                    Button("No day") { model.setLaterDay(row.id, nil) }
                }
            }
        }
    }
}

/// "Pick a day…": a date, from tomorrow on, and Save.
struct PickDayView: View {
    let model: AppModel
    let itemId: UUID
    let onDone: () -> Void

    @State private var selection: LocalDay?

    private var title: String { model.row(itemId)?.item.title ?? "" }
    private var tomorrow: LocalDay { (model.currentDay ?? LocalDay(picked: Date())).adding(days: 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).lineLimit(1)
            // As wide as the menu (user, 2026-11-18: the system calendar was too small).
            MonthCalendar(selection: Binding(get: { selection ?? tomorrow }, set: { selection = $0 }),
                          first: tomorrow)
            NoticeView(text: model.notice)
            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if model.setLaterDay(itemId, selection ?? tomorrow) { onDone() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(Text("Save the day for \(title)"))
            }
        }
        .padding(12)
        .onAppear { selection = model.laterDay(itemId) ?? tomorrow }
        // Open across the rollover: a day that is now today moves on to tomorrow.
        .onChange(of: tomorrow) { if let s = selection, s < tomorrow { selection = tomorrow } }
    }
}

/// A month of days filling the width it is given: a header with the month and arrows,
/// the weekdays (in the user's order), and a button per day. Days before `first` are
/// shown dimmed and cannot be chosen.
struct MonthCalendar: View {
    @Binding var selection: LocalDay
    let first: LocalDay

    /// The first of the month shown.
    @State private var month: LocalDay?

    /// Gregorian like `LocalDay` (Gemini review: a Persian or Hijri system calendar
    /// broke the grid); the user's first weekday and language are kept.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = .current
        c.timeZone = .current
        c.firstWeekday = Calendar.current.firstWeekday
        return c
    }
    private var shown: LocalDay { month ?? MonthGrid.month(of: selection) }
    private var cells: [LocalDay?] { MonthGrid.cells(of: shown, firstWeekday: calendar.firstWeekday) }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let f = calendar.firstWeekday - 1
        return Array(symbols[f...] + symbols[..<f])
    }

    private var monthTitle: String {
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.calendar = calendar
        return shown.noon.formatted(style)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(verbatim: monthTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { month = MonthGrid.adding(-1, to: shown) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(shown <= MonthGrid.month(of: first))
                    .accessibilityLabel(Text("Previous month"))
                Button { month = MonthGrid.adding(1, to: shown) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Next month"))
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { dayButton(day) } else { Color.clear.frame(height: 32) }
                }
            }
        }
    }

    private func dayButton(_ day: LocalDay) -> some View {
        let chosen = day == selection
        let allowed = day >= first
        return Button { selection = day } label: {
            Text(verbatim: "\(day.day)")
                .font(.body.monospacedDigit())
                .foregroundStyle(chosen ? Color.white : allowed ? Color.primary : Color.secondary.opacity(0.5))
                .frame(width: 32, height: 32)
                .background(Circle().fill(chosen ? Color.accentColor : Color.clear))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .accessibilityLabel(Text(verbatim: day.noon.formatted(.dateTime.weekday(.wide).month(.wide).day())))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Add's and Edit's "On a day": a switch and a date, from tomorrow on.
struct DayRow: View {
    let model: AppModel
    @Binding var on: Bool
    @Binding var date: Date

    private var tomorrow: Date { (model.currentDay ?? LocalDay(picked: Date())).adding(days: 1).noon }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $on) { Text("On a day") }
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("On a day"))
            if on {
                DatePicker(selection: $date, in: tomorrow..., displayedComponents: .date) { Text("Day") }
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .accessibilityLabel(Text("Day"))
            }
            Spacer(minLength: 0)
        }
        .onAppear { if date < tomorrow { date = tomorrow } }
    }
}
