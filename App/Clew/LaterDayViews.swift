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

    @State private var date = Date()

    private var title: String { model.row(itemId)?.item.title ?? "" }
    private var tomorrow: Date { (model.currentDay ?? LocalDay(picked: Date())).adding(days: 1).noon }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).lineLimit(1)
            DatePicker(selection: $date, in: tomorrow..., displayedComponents: .date) {
                Text("Later until")
            }
            .datePickerStyle(.graphical)
            .labelsHidden()
            .accessibilityLabel(Text("Later until"))
            NoticeView(text: model.notice)
            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if model.setLaterDay(itemId, LocalDay(picked: date)) { onDone() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(Text("Save the day for \(title)"))
            }
        }
        .padding(12)
        .onAppear { date = model.laterDay(itemId)?.noon ?? tomorrow }
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
