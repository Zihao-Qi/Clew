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
        VStack(spacing: 14) {   // user, 2026-11-18: the month sat too close to the weekdays
            HStack(spacing: 0) {
                // A step below the task's name, so the two do not compete (design review).
                Text(verbatim: monthTitle)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // 28 pt click areas; the last arrow's glyph ends in line with Save.
                Button { month = MonthGrid.adding(-1, to: shown) } label: { arrow("chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(shown <= MonthGrid.month(of: first))
                    .accessibilityLabel(Text("Previous month"))
                Button { month = MonthGrid.adding(1, to: shown) } label: { arrow("chevron.right") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Next month"))
                    .padding(.trailing, -9)
            }
            // The outer days' circles line up with the title and Save (design review).
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
            .padding(.horizontal, -7)
        }
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
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
                // Today, which cannot be chosen, keeps a thin ring as a landmark.
                .overlay(Circle().strokeBorder(Color.secondary.opacity(day == first.adding(days: -1) ? 0.6 : 0), lineWidth: 1))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .accessibilityLabel(Text(verbatim: day.noon.formatted(.dateTime.weekday(.wide).month(.wide).day())))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Add's and Edit's "On a day": a switch, then the day as a button that opens the
/// same calendar as "Pick a day…" right below it (user, 2026-11-18: the system date
/// field's calendar was small and looked foreign). Picking a day closes it.
struct DayRow: View {
    let model: AppModel
    @Binding var on: Bool
    @Binding var date: Date
    /// The calendar is open below the row.
    @Binding var open: Bool

    private var tomorrow: LocalDay { (model.currentDay ?? LocalDay(picked: Date())).adding(days: 1) }
    private var day: LocalDay { max(LocalDay(picked: date), tomorrow) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle(isOn: $on) { Text("On a day") }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(Text("On a day"))
                if on {
                    Button { withAnimation(.snappy(duration: 0.25)) { open.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: day.noon.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            Image(systemName: open ? "chevron.up" : "chevron.down")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(Text("Day"))
                    .accessibilityValue(Text(verbatim: day.noon.formatted(.dateTime.weekday(.wide).month(.wide).day())))
                }
                Spacer(minLength: 0)
            }
            if on, open {
                MonthCalendar(selection: Binding(get: { day }, set: { picked in
                    date = picked.noon
                    withAnimation(.snappy(duration: 0.25)) { open = false }
                }), first: tomorrow)
                .transition(.opacity)
            }
        }
        .onAppear { if LocalDay(picked: date) < tomorrow { date = tomorrow.noon } }
        // Switching it on opens the calendar; off closes it.
        .onChange(of: on) { withAnimation(.snappy(duration: 0.25)) { open = on } }
    }
}
