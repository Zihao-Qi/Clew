import AppKit
import ClewCore
import ClewDomain
import SwiftUI

/// A calendar event's page (SPEC 2026-11-19, "Editing an event"): its title, when it
/// starts and ends on today's timeline, Cancel and Save. A repeating event asks, as
/// Calendar does, "This event only" or "All future events" before anything is saved.
struct EventEditView: View {
    let model: AppModel
    let event: CalendarEvent
    let onDone: () -> Void
    /// The snapshot only: opens on the repeat question.
    var startAsking = false

    @State private var title = ""
    @State private var startTime = TimeOfDay(hour: 9, minute: 0)!
    @State private var endTime = TimeOfDay(hour: 10, minute: 0)!
    /// A repeating event's Save asks first.
    @State private var asking = false
    /// False for a double-click's length after opening: the second click of a
    /// double-click on the event lands here and must not hit a button (as in details).
    @State private var takesClicks = false
    @FocusState private var titleFocused: Bool

    private var day: TimelineDay? { model.timeline }

    /// The times as instants on today's timeline: before the rollover hour it is the night
    /// at the end; an end at the rollover hour is the timeline's end. A time not touched
    /// keeps the event's own (seconds and all).
    private var start: Date? {
        guard let day else { return nil }
        if startTime == TimeOfDay(pickerDate: event.start) { return event.start }
        return day.day.instant(at: startTime, in: .current, rolloverHour: model.rolloverHour)
    }
    private var end: Date? {
        guard let day else { return nil }
        if endTime == TimeOfDay(pickerDate: event.end) { return event.end }
        let at = day.day.instant(at: endTime, in: .current, rolloverHour: model.rolloverHour)
        return at <= day.start ? day.end : at
    }
    private var problem: Clew.EventEditProblem? {
        guard let start, let end else { return nil }
        return Clew.eventEditProblem(title: title, start: start, end: end)
    }
    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(EventColor.of(event)).frame(width: 8, height: 8).accessibilityHidden(true)
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit(save)
                    .accessibilityLabel(Text("Event title"))
            }
            if day != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Starts")
                    TimePicker(time: $startTime)
                        .fixedSize()
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
                        .accessibilityLabel(Text("Start time"))
                    Text("Ends").padding(.leading, 8)
                    TimePicker(time: $endTime)
                        .fixedSize()
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
                        .accessibilityLabel(Text("End time"))
                    Spacer()
                }
            }
            if problem == .endsBeforeStart {
                Text("It ends before it starts.").font(.callout).foregroundStyle(.secondary)
            }
            if asking {
                Text("“\(trimmed)” is a repeating event.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack {
                    Button("Cancel") { asking = false }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(Text("Cancel"))
                    Spacer()
                    Button("All future events") { commit(.futureEvents) }
                        .accessibilityLabel(Text("Change this and all future events"))
                    Button("This event only") { commit(.thisEvent) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(Text("Change this event only"))
                }
            } else {
                HStack {
                    Spacer()
                    Button("Cancel", action: onDone)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(Text("Cancel"))
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(problem != nil)
                        .accessibilityLabel(Text("Save the event"))
                }
            }
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .overlay {
            if !takesClicks {
                Color.clear.contentShape(Rectangle()).accessibilityHidden(true)
            }
        }
        .onAppear(perform: setUp)
        .task {
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            takesClicks = true
        }
    }

    private func setUp() {
        title = event.title
        startTime = TimeOfDay(pickerDate: event.start)
        endTime = TimeOfDay(pickerDate: event.end)
        titleFocused = true
        asking = startAsking
    }

    private func save() {
        guard problem == nil, let start, let end else { return }
        guard trimmed != event.title || start != event.start || end != event.end else { return onDone() }
        if event.repeats { asking = true } else { commit(.thisEvent) }
    }

    private func commit(_ span: EventSpan) {
        guard problem == nil, let start, let end else { return }
        let change = AppModel.EventChange(event: event, title: trimmed, start: start, end: end, kind: .changed)
        if model.changeEvent(change, span: span) { onDone() }
    }
}
