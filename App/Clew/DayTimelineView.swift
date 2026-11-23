import AppKit
import ClewCore
import ClewDomain
import SwiftUI

/// Where the timeline is, in the list's coordinate space, so a dragged row can tell
/// which hour it is over.
struct TimelineGeometry: Equatable {
    /// The visible part (about 6 hours).
    var viewport: CGRect = .zero
    /// The top of the whole day's content (moves as it scrolls).
    var contentTop: CGFloat = 0
    /// The content's left edge (the hours' x = 0).
    var contentLeft: CGFloat = 0
}

enum TimelineMetrics {
    /// 60 points an hour.
    static let pointsPerMinute: CGFloat = 1
    /// About 6 hours show (user, 2026-11-10; was 4).
    static let height: CGFloat = 360
    /// Room before the widest hour label (matching `trailing` on the card's right edge)
    /// and between the labels and hour lines.
    static let labelLeading: CGFloat = trailing
    static let labelGap: CGFloat = 4
    /// Room between the blocks and hour lines and the card's right edge, so the timeline
    /// reads as its own area, apart from the list (user, 2026-11-11).
    static let trailing: CGFloat = 8
    /// The current time sits this far down when the menu opens: 2 of the 6 hours behind
    /// it, 4 ahead (user, 2026-11-11).
    static let quartersBeforeNow = 8

    /// A bottom-edge grip for a block or event of this drawn height: 12 points (user,
    /// 2026-11-11: 6 was hard to hit). Only the part over the block takes clicks, so on a
    /// block under 30 minutes it is a strip of a quarter of the block at its bottom edge,
    /// and the rest moves it (user, 2026-11-22: a 15-minute block only resized).
    static func grip(height: CGFloat) -> (inside: CGFloat, below: CGFloat) {
        height < 29 ? (max(3, height / 4), 0) : (8, 4)
    }
    static let quarter = Clew.blockStepMinutes

    static func y(_ date: Date, in day: TimelineDay) -> CGFloat {
        CGFloat(date.timeIntervalSince(day.start) / 60) * pointsPerMinute
    }

    static func quarters(_ day: TimelineDay) -> Int {
        Int(day.end.timeIntervalSince(day.start) / 60) / quarter
    }

    /// The quarter hour under `y` (content coordinates), kept inside the day.
    static func start(atContentY y: CGFloat, in day: TimelineDay) -> Date {
        Clew.quarterStart(minutesIn: Double(y / pointsPerMinute), day: day)
    }

    /// The minutes left in the day after `start`.
    static func room(after start: Date, in day: TimelineDay) -> Int {
        Int(day.end.timeIntervalSince(start) / 60)
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func hourLabel(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle.dateTime.hour().locale(locale))
    }

    /// Gutter width for `day`'s hour labels in `locale`, so 24-hour ("04"–"23") and
    /// localized labels don't sit behind a blank 12-hour AM/PM margin.
    static func labelWidth(for day: TimelineDay, locale: Locale = .autoupdatingCurrent) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular
        )
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let maxText = stride(from: 0, to: quarters(day), by: 4).reduce(CGFloat(0)) { widest, q in
            let date = day.start.addingTimeInterval(TimeInterval(q * quarter * 60))
            let w = ceil((hourLabel(date, locale: locale) as NSString).size(withAttributes: attrs).width)
            return max(widest, w)
        }
        return maxText + labelLeading + labelGap
    }

    /// "9:00 – 10:00 AM": the shared AM/PM only once (user, 2026-11-13), in the user's
    /// locale (24-hour clocks have none). A range past midnight keeps both in full, since
    /// the interval format would add the dates.
    static func range(_ start: Date, _ end: Date) -> String {
        guard Calendar.current.isDate(start, inSameDayAs: end) else { return "\(time(start)) – \(time(end))" }
        return (start..<end).formatted(Date.IntervalFormatStyle(date: .omitted, time: .shortened))
    }

    /// Timeline text (user, 2026-11-13): titles the size of the list's (body), times and
    /// hour labels a little smaller.
    static let titleFont = Font.body
    static let detailFont = Font.subheadline

    /// Only blocks and events longer than 30 minutes have room for a second line (the
    /// time); shorter ones show just the title (user, 2026-11-13).
    static func hasSecondLine(_ minutes: Double) -> Bool { minutes > 30 }

    /// Where a block's text sits: one line centred in a 15-minute block (14 points, less
    /// than a body line), else at the top.
    static func textAlignment(_ minutes: Int) -> Alignment { minutes <= 15 ? .leading : .topLeading }
    static func textTop(_ minutes: Int) -> CGFloat { minutes <= 15 ? 0 : 2 }
}

/// Today's hours above the list: scrolls, opens at now, holds the task blocks.
struct DayTimelineView: View {
    let model: AppModel
    let day: TimelineDay
    let space: String
    @Binding var geometry: TimelineGeometry
    @Binding var topQuarter: Int?
    /// The block being dragged: the lifted card draws it (TodayListView).
    let liftedBlock: UUID?
    /// The task under the pointer (the Delete key's target).
    @Binding var hovered: UUID?
    /// The double-click's name box, while it is open (SPEC 2026-11-13).
    @Binding var newTask: NewTaskDraft?
    /// A block's drag, reported to the list (nil: cancelled), and its drop.
    let onDrag: (TimelineBlock, DragGesture.Value?) -> Void
    let onDrop: (TimelineBlock) -> Void
    let onMove: (TimelineBlock) -> Void
    let onOpen: (UUID) -> Void
    let onEdit: (Item) -> Void
    /// A click on an event the user may change: its page (SPEC 2026-11-19).
    let onOpenEvent: (CalendarEvent) -> Void
    @Environment(\.locale) private var locale
    /// A drag on empty space (SPEC 2026-11-19): the minute pressed, and the pointer's y in
    /// the list's space (so the block follows the hours as they scroll under it).
    @State private var sweepPress: Double?
    @State private var sweepPointerY: CGFloat?
    @State private var sweepScroll: Timer?
    @State private var sweepStep = 0
    /// This press was decided not to make a task (on a block or the box, or stopped by
    /// the rollover): the rest of the drag does nothing (review).
    @State private var sweepIgnored = false
    @GestureState private var sweeping = false
    /// An event's drag or its bottom edge's (SPEC 2026-11-19): the y pressed, in the
    /// day's content, and the pointer's y in the list's space (so it follows the scroll).
    private struct EventDrag: Equatable {
        let id: String
        let resize: Bool
        let pressY: CGFloat
        var pointerY: CGFloat
    }
    @State private var eventDrag: EventDrag?

    /// Where an event shows: as dragged, as waiting for the repeat question, or as it is.
    private func shown(_ event: CalendarEvent) -> (start: Date, end: Date) {
        if let d = eventDrag, d.id == event.id {
            let minutes = Double((d.pointerY - geometry.contentTop - d.pressY) / TimelineMetrics.pointsPerMinute)
            return d.resize ? (event.start, Clew.resizedEnd(event, by: minutes, day: day))
                            : Clew.movedEvent(event, by: minutes, day: day)
        }
        if let p = model.pendingEventChange, p.event.id == event.id { return (p.start, p.end) }
        return (event.start, event.end)
    }

    /// An event's drag (nil: cancelled). A new drag answers a waiting one with Cancel.
    private func eventDragged(_ event: CalendarEvent, resize: Bool, _ value: DragGesture.Value?) {
        guard let value else {
            if eventDrag?.id == event.id { eventDrag = nil; stopEdgeScroll() }
            return
        }
        if eventDrag?.id != event.id || eventDrag?.resize != resize {
            model.answerPendingEventChange(nil)
            eventDrag = EventDrag(id: event.id, resize: resize, pressY: value.startLocation.y - geometry.contentTop,
                                  pointerY: value.location.y)
        }
        eventDrag?.pointerY = value.location.y
        scrollAtEdge(value.location.y)
    }

    /// Let go: saved, or for a repeating event held for the question.
    private func eventDropped(_ event: CalendarEvent, resize: Bool) {
        guard let d = eventDrag, d.id == event.id else { return }
        let at = shown(event)
        eventDrag = nil
        stopEdgeScroll()
        model.proposeEventChange(.init(event: event, title: event.title, start: at.start, end: at.end,
                                       kind: resize ? .changed : .moved))
    }

    /// The block a drag on empty space would make, while it is dragged.
    private var sweepDraft: NewTaskDraft? {
        guard let press = sweepPress, let y = sweepPointerY else { return nil }
        let pointer = Double((y - geometry.contentTop) / TimelineMetrics.pointsPerMinute)
        let s = Clew.sweep(pressMinutes: press, pointerMinutes: pointer, day: day)
        return NewTaskDraft(start: s.start, minutes: s.minutes)
    }

    /// While the name box is open, one layout for blocks, events and the box, so the box
    /// sits in the column its block will get (SPEC 2026-11-13).
    private var draftLayout: (blocks: [UUID: TimelinePlace], events: [String: TimelinePlace], draft: TimelinePlace?)? {
        (sweepDraft ?? newTask).map { Clew.timelineLayout(blocks: day.blocks, timed: model.calendarEvents?.timed ?? [],
                                                         draft: ($0.start, $0.end)) }
    }

    /// Blocks and events together: a block's column comes from the shared layout when
    /// calendar events show.
    private func place(_ block: TimelineBlock, _ layout: (blocks: [UUID: TimelinePlace], events: [String: TimelinePlace], draft: TimelinePlace?)?) -> TimelinePlace {
        layout?.blocks[block.id] ?? model.calendarEvents?.blockPlaces[block.id]
            ?? TimelinePlace(lane: block.lane, lanes: block.lanes)
    }

    /// Where a column starts and how wide it is, in the hours' coordinates.
    private func columns(_ place: TimelinePlace, width: CGFloat, labelWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        (labelWidth + CGFloat(place.lane) * width / CGFloat(place.lanes),
         max(20, width / CGFloat(place.lanes) - 2))
    }

    /// Opens the name box at the quarter hour `y` points into the day, unless the double-
    /// click was on a block (its own click opens details) or inside the open box.
    private func openNewTask(at point: CGPoint, width: CGFloat, labelWidth: CGFloat) {
        guard !isOnBlockOrBox(point, width: width, labelWidth: labelWidth) else { return }
        newTask = NewTaskDraft(minutesIn: Double(point.y / TimelineMetrics.pointsPerMinute), day: day)
    }

    /// `point` (the hours' coordinates) is on a task block, an event the user may change,
    /// or inside the open name box.
    private func isOnBlockOrBox(_ point: CGPoint, width: CGFloat, labelWidth: CGFloat) -> Bool {
        let layout = draftLayout
        func hits(_ start: Date, _ height: CGFloat, _ place: TimelinePlace) -> Bool {
            let col = columns(place, width: width, labelWidth: labelWidth)
            let top = TimelineMetrics.y(start, in: day)
            return point.y >= top && point.y < top + height && point.x >= col.x && point.x < col.x + col.width
        }
        if day.blocks.contains(where: { hits($0.block.start, TimelineMetrics.y($0.block.end, in: day) - TimelineMetrics.y($0.block.start, in: day), place($0, layout)) }) { return true }
        // An event the user may change takes its own clicks and drags (SPEC 2026-11-19).
        for event in model.calendarEvents?.timed ?? [] where event.canEdit {
            let at = shown(event)
            let place = layout?.events[event.id] ?? model.calendarEvents?.eventPlaces[event.id] ?? TimelinePlace(lane: 0, lanes: 1)
            if hits(at.start, TimelineEventView.height(at.start, at.end), place) { return true }
        }
        // The box as drawn: a 15-minute one is taller than its quarter hour (review).
        if let box = newTask, let at = layout?.draft, hits(box.start, NewTaskDraft.boxHeight(box.minutes), at) { return true }
        return false
    }

    /// Press on empty space (or an event) and drag down or up: a light block shows the
    /// time it covers; letting go opens the name box on it (SPEC 2026-11-19). A block's
    /// own drag comes first.
    private func sweep(width: CGFloat, labelWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
            .updating($sweeping) { _, live, _ in live = true }
            .onChanged { value in
                guard !sweepIgnored else { return }
                if sweepPress == nil {
                    // Pressed on a block or in the open box: not a new task, for the whole drag.
                    let content = CGPoint(x: value.startLocation.x - geometry.contentLeft,
                                          y: value.startLocation.y - geometry.contentTop)
                    guard !isOnBlockOrBox(content, width: width, labelWidth: labelWidth) else {
                        sweepIgnored = true
                        return
                    }
                    sweepPress = Double(content.y / TimelineMetrics.pointsPerMinute)
                }
                sweepPointerY = value.location.y
                scrollAtEdge(value.location.y)
            }
            .onEnded { _ in
                if !sweepIgnored, let draft = sweepDraft { newTask = draft }
                endSweep()
                sweepIgnored = false
            }
    }

    /// Stops the drag's block and its scrolling. `rest`: the drag still held does nothing
    /// more (the rollover); a new drag starts afresh either way.
    private func endSweep(rest ignored: Bool = false) {
        stopEdgeScroll()
        sweepPress = nil
        sweepPointerY = nil
        if ignored { sweepIgnored = true }
    }

    private func stopEdgeScroll() {
        sweepScroll?.invalidate()
        sweepScroll = nil
        sweepStep = 0
    }

    /// Near the timeline's top or bottom edge while sweeping or dragging an event, the
    /// hours scroll by themselves (as when a block is dragged there).
    private func scrollAtEdge(_ y: CGFloat) {
        let view = geometry.viewport
        let step = y < view.minY + 18 ? -1 : y > view.maxY - 18 ? 1 : 0
        // Already scrolling this way; a new direction (or none) stops the old timer.
        guard step != sweepStep || sweepScroll == nil else { return }
        sweepScroll?.invalidate()
        sweepScroll = nil
        sweepStep = step
        guard step != 0 else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { _ in
            Task { @MainActor in
                guard sweepScroll != nil, sweepStep == step else { return }
                let visible = Int(TimelineMetrics.height) / TimelineMetrics.quarter
                let top = (topQuarter ?? 0) + step
                topQuarter = min(max(top, 0), TimelineMetrics.quarters(day) - visible)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sweepScroll = timer
    }

    /// VoiceOver's "New task on the timeline": the box at the next quarter hour (the
    /// day's last one if none is left), with now in view.
    private func openNewTaskAtNextQuarter() {
        centreOnNow()
        let minutes = Date().timeIntervalSince(day.start) / 60
        let next = (minutes / Double(TimelineMetrics.quarter)).rounded(.down) + 1
        newTask = NewTaskDraft(minutesIn: next * Double(TimelineMetrics.quarter), day: day)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hours
            // Below the hours, so nothing in them moves when it shows.
            repeatQuestion
        }
        // Its own card, floating just above the menu (SPEC 2026-11-19, user): the
        // foreground of what to do now and next.
        .modifier(FloatingCard())
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        // Every time the menu opens, now is a third of the way down.
        // While the name box is open, the timeline stays where it is.
        .onAppear { if newTask == nil { centreOnNow() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if newTask == nil { centreOnNow() }
        }
        // The rollover closes the box; nothing is made. A waiting event goes back.
        .onChange(of: day.day) {
            newTask = nil
            endSweep(rest: true)
            eventDrag = nil
            model.answerPendingEventChange(nil)
        }
        // The menu closing puts a waiting event back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            model.answerPendingEventChange(nil)
        }
        // A drag the system cancelled (the menu closed): nothing is made.
        .onChange(of: sweeping) {
            if !sweeping {
                endSweep()
                sweepIgnored = false
            }
        }
        // Leaving the list (Add, Settings) mid-drag: no timer is left running, and a
        // waiting event goes back.
        .onDisappear {
            endSweep()
            eventDrag = nil
            model.answerPendingEventChange(nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Today's timeline"))
        .accessibilityAction(named: Text("New task on the timeline"), openNewTaskAtNextQuarter)
    }

    /// Above the hours: "Show your calendar" until it is on (or closed), a note when macOS
    /// does not allow it, and today's all-day events as one thin line.
    /// A repeating event dragged: Calendar's question, before anything is saved.
    @ViewBuilder
    private var repeatQuestion: some View {
        if let pending = model.pendingEventChange {
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(pending.event.title)” is a repeating event.").lineLimit(1).truncationMode(.middle)
                HStack(spacing: 12) {
                    // The answers in the accent colour, so they read as buttons.
                    Group {
                        Button("This event only") { model.answerPendingEventChange(.thisEvent) }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityLabel(Text("Change this event only"))
                        Button("All future events") { model.answerPendingEventChange(.futureEvents) }
                            .accessibilityLabel(Text("Change this and all future events"))
                    }
                    .foregroundStyle(Color.accentColor)
                    Spacer()
                    Button("Cancel") { model.answerPendingEventChange(nil) }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(Text("Cancel the change"))
                }
            }
            .font(TimelineMetrics.detailFont)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var header: some View {
        if !model.calendarShown, !model.calendarPromptClosed {
            HStack(spacing: 6) {
                Button { model.showCalendar() } label: { Label("Show your calendar", systemImage: "calendar") }
                    .accessibilityLabel(Text("Show your calendar events on the timeline"))
                Spacer()
                Button { model.closeCalendarPrompt() } label: { Image(systemName: "xmark").imageScale(.small) }
                    .accessibilityLabel(Text("Not now"))
            }
            .font(TimelineMetrics.detailFont)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        } else if model.calendarShown, model.calendarAccess == .denied {
            HStack(spacing: 6) {
                Text("Clew can't read your calendar.")
                Spacer()
                Button("Allow…") { EventKitCalendar.openPrivacySettings() }
                    .accessibilityLabel(Text("Open calendar privacy settings"))
            }
            .font(TimelineMetrics.detailFont)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        } else if let allDay = model.calendarEvents?.allDay, !allDay.isEmpty {
            HStack(spacing: 8) {
                ForEach(allDay) { event in
                    HStack(spacing: 4) {
                        Circle().fill(EventColor.of(event)).frame(width: 6, height: 6)
                        Text(event.title).lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("All day: \(event.title)"))
                }
                Spacer(minLength: 0)
            }
            .font(TimelineMetrics.detailFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    private var hours: some View {
        let labelWidth = TimelineMetrics.labelWidth(for: day, locale: locale)
        return ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                grid(labelWidth: labelWidth)
                GeometryReader { g in
                    let width = g.size.width - labelWidth - TimelineMetrics.trailing
                    let layout = draftLayout
                    ZStack(alignment: .topLeading) {
                    // Calendar events first, so task blocks draw over them.
                    ForEach(model.calendarEvents?.timed ?? []) { event in
                        let col = columns(layout?.events[event.id] ?? model.calendarEvents?.eventPlaces[event.id]
                                          ?? TimelinePlace(lane: 0, lanes: 1), width: width, labelWidth: labelWidth)
                        let at = shown(event)
                        TimelineEventView(event: event, start: at.start, end: at.end, space: space,
                                          // One waiting for the question takes nothing more.
                                          editable: event.canEdit && model.pendingEventChange?.event.id != event.id,
                                          onOpen: { onOpenEvent(event) },
                                          onDrag: { eventDragged(event, resize: $0, $1) },
                                          onDrop: { eventDropped(event, resize: $0) })
                            .frame(width: col.width, height: TimelineEventView.height(at.start, at.end))
                            .offset(x: col.x, y: TimelineMetrics.y(at.start, in: day))
                    }
                    ForEach(day.blocks) { block in
                        let col = columns(place(block, layout), width: width, labelWidth: labelWidth)
                        TimelineBlockView(model: model, block: block, day: day, space: space,
                                          isLifted: liftedBlock == block.id, hovered: $hovered,
                                          onDrag: { onDrag(block, $0) }, onDrop: { onDrop(block) },
                                          onMove: { onMove(block) }, onOpen: { onOpen(block.block.itemId) },
                                          onEdit: onEdit)
                            .frame(width: col.width)
                            .offset(x: col.x, y: TimelineMetrics.y(block.block.start, in: day))
                    }
                    if let draft = sweepDraft, let at = layout?.draft {
                        let col = columns(at, width: width, labelWidth: labelWidth)
                        SweepBlock(draft: draft)
                            .frame(width: col.width)
                            .offset(x: col.x, y: TimelineMetrics.y(draft.start, in: day))
                    } else if let draft = newTask, let at = layout?.draft {
                        let col = columns(at, width: width, labelWidth: labelWidth)
                        NewTaskBox(model: model, draft: draft) {
                            // Only this box: a late close never takes a newer one.
                            if newTask?.id == draft.id { newTask = nil }
                        }
                        .id(draft.id)
                        .frame(width: col.width)
                        .offset(x: col.x, y: TimelineMetrics.y(draft.start, in: day))
                    }
                    // The current time, redrawn each minute (popover content: a TimelineView
                    // is fine here, unlike in the menu bar label).
                    TimelineView(.everyMinute) { context in
                        if context.date >= day.start, context.date < day.end {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: g.size.width - labelWidth + TimelineMetrics.labelGap - TimelineMetrics.trailing, height: 1)
                                .offset(x: labelWidth - TimelineMetrics.labelGap, y: TimelineMetrics.y(context.date, in: day))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                    // Double-click an empty spot, or an event: a new task there (SPEC
                    // 2026-11-13). A block's own click comes first, and a click inside the
                    // open box is the box's.
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2).onEnded { value in
                        openNewTask(at: value.location, width: width, labelWidth: labelWidth)
                    })
                    // After a block's own drag: a press on a block moves the block.
                    .gesture(sweep(width: width, labelWidth: labelWidth))
                }
            }
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(space)).origin } action: {
                geometry.contentTop = $0.y
                geometry.contentLeft = $0.x
            }
        }
        .scrollPosition(id: $topQuarter, anchor: .top)
        .frame(height: TimelineMetrics.height)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { geometry.viewport = $0 }
    }

    private func centreOnNow() {
        let minutes = Int(Date().timeIntervalSince(day.start) / 60)
        let visible = Int(TimelineMetrics.height) / TimelineMetrics.quarter
        topQuarter = max(0, min(minutes / TimelineMetrics.quarter - TimelineMetrics.quartersBeforeNow,
                                TimelineMetrics.quarters(day) - visible))
    }

    /// One 15-point row per quarter hour (the scroll anchors), with the hour labels.
    private func grid(labelWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<TimelineMetrics.quarters(day), id: \.self) { q in
                HStack(alignment: .top, spacing: TimelineMetrics.labelGap) {
                    Group {
                        if q % 4 == 0 {
                            Text(verbatim: hourLabel(q))
                                .font(TimelineMetrics.detailFont.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .offset(y: -7)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: labelWidth - TimelineMetrics.labelGap, alignment: .trailing)
                    Rectangle()
                        .fill(Color.primary.opacity(q % 4 == 0 ? 0.12 : 0))
                        .frame(height: 1)
                        .padding(.trailing, TimelineMetrics.trailing)
                }
                .frame(height: CGFloat(TimelineMetrics.quarter) * TimelineMetrics.pointsPerMinute, alignment: .top)
                .id(q)
                .accessibilityHidden(true)
            }
        }
        .scrollTargetLayout()
        .padding(.top, 6)
        .padding(.top, -6)
    }

    private func hourLabel(_ q: Int) -> String {
        let date = day.start.addingTimeInterval(TimeInterval(q * TimelineMetrics.quarter * 60))
        return TimelineMetrics.hourLabel(date, locale: locale)
    }
}

/// One task's block: drag to move, drag the bottom edge to resize, drag it onto the list
/// to remove; right-click for the same without dragging.
struct TimelineBlockView: View {
    let model: AppModel
    let block: TimelineBlock
    let day: TimelineDay
    let space: String
    /// Being dragged: the lifted card stands in for it.
    let isLifted: Bool
    @Binding var hovered: UUID?
    let onDrag: (DragGesture.Value?) -> Void
    let onDrop: () -> Void
    let onMove: () -> Void
    let onOpen: () -> Void
    let onEdit: (Item) -> Void

    /// True while a drag of the block is live; it resets by itself when the drag ends
    /// or is cancelled, which clears what the drag showed (Gemini review).
    @GestureState private var dragging = false
    @State private var resizeBy = 0
    /// True while the grip is dragged; it resets by itself when the drag ends or is
    /// cancelled, so a cancelled resize never leaves its cursor or size behind.
    @GestureState private var resizing = false
    /// The pointer is on the bottom edge: a grab bar shows that it resizes.
    @State private var onEdge = false

    private var b: TimeBlock { block.block }
    private var row: TodayRow? { model.today?.rows.first { $0.id == b.itemId } }
    /// A step's block (SPEC 2026-11-21): its step, while it exists.
    private var step: TaskSteps.Entry? { b.stepId.flatMap { model.stepEntry($0) } }
    /// Ticked, covered by a hand tick, or the task (a step's block: the step) is done anyway.
    /// A block still to come for something already done (a done step or task put on the
    /// timeline to show when, user 2026-11-22) looks done too, not running.
    private var looksDone: Bool {
        let waitingForDone = block.state == .pending || block.state == .skipped
        if b.stepId != nil { return block.state == .ticked || (waitingForDone && step?.isDone == true) }
        return block.state == .ticked || block.state == .covered
            || (waitingForDone && row?.isDone == true && row?.item.kind != .goal)
            || (block.state == .skipped && row?.isDone == true)
    }
    /// What the Delete key deletes under the pointer: the step of a step's block.
    private var hoverId: UUID { b.stepId ?? b.itemId }
    private var minutes: Int { b.minutes + resizeBy }
    /// Running now: it stands out a little (user, 2026-11-11). Redrawn at each block's start
    /// and end, when the app refreshes.
    private var isNow: Bool { block.state == .pending && !looksDone && b.start <= Date() && Date() < b.end }
    private var height: CGFloat { CGFloat(minutes) * TimelineMetrics.pointsPerMinute }

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isNow ? Color.accentColor.opacity(0.32)
                  : looksDone || block.state == .pending || block.state == .asking ? Color.accentColor.opacity(0.22)
                  : Color.secondary.opacity(0.08))
            .overlay(alignment: .leading) {
                if isNow {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .topLeading) { label }
            // The grip is placed by layout (not a visual offset), so the hover, the cursor
            // and the drag all use the same strip (TimelineMetrics.grip).
            .overlay(alignment: .bottom) {
                if block.canChange { resizeHandle.alignmentGuide(.bottom) { $0[.bottom] - gripBelow } }
            }
            .frame(height: max(height - 1, 6))
            // While dragged, the lifted card draws it, over the hours or over the list.
            .opacity(isLifted ? 0 : 1)
            .contentShape(Rectangle())
            // The same as a row: click opens the details, right-click the menu.
            .onTapGesture(perform: onOpen)
            .gesture(moveGesture)
            .onHover { inside in
                if inside { hovered = hoverId } else if hovered == hoverId { hovered = nil }
            }
            .contextMenu { if b.stepId != nil { stepMenu } else { menu } }
            .debugFrame("block:\(b.id)")
            .onChange(of: dragging) { _, live in
                // Ended or cancelled: nothing of the drag stays on screen.
                if !live, isLifted { onDrag(nil) }
            }
            .onDisappear {
                if isLifted { onDrag(nil) }
                if hovered == hoverId { hovered = nil }
            }
            .help(Text(verbatim: "\(block.title) · \(range)"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(count.map { Text("\(block.title), \($0.done) of \($0.target), \(range)") }
                                ?? Text("\(block.title), \(range)"))
            .accessibilityValue(stateText)
            .accessibilityAction(named: Text("Details"), onOpen)
            .accessibilityAction(named: Text("Move to…"), onMove)
            .accessibilityAction(named: Text("Remove block")) { model.removeBlock(b.id) }
            .accessibilityActions {
                if let step {
                    Button(step.isDone ? "Undo" : "Done") { model.tapStep(step) }
                    Button("Delete") { model.deleteStep(step.step) }
                } else {
                    if let row, !row.isGoalReached, row.item.kind == .goal || !row.isDone {
                        Button(row.item.kind == .goal ? "+1" : "Done") { model.tap(row) }
                    }
                    if let row, row.todayAmount > 0 {
                        Button(row.item.kind == .goal ? "Undo +1" : "Undo") { model.undo(row) }
                    }
                    if timer != nil {
                        Button("Stop the timer") { model.stopFocus() }
                    }
                }
            }
    }

    private var range: String {
        TimelineMetrics.range(b.start, b.start.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    private var stateText: Text {
        switch block.state {
        case .pending: looksDone ? Text("Done") : Text("Not ended yet")
        case .asking: Text("Ended. Done?")
        case .ticked, .covered: Text("Done")
        case .undone: Text("Not finished")
        case .skipped: looksDone ? Text("Done") : Text("Ended")
        }
    }

    private var label: some View {
        let twoLines = TimelineMetrics.hasSecondLine(Double(minutes))
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            if looksDone {
                Image(systemName: "checkmark").font(TimelineMetrics.detailFont.weight(.semibold)).foregroundStyle(.secondary)
            }
            if twoLines {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        title
                        countView
                    }
                    status ?? Text(verbatim: range).font(TimelineMetrics.detailFont.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                // 30 minutes or less: one line. "Done?" or a running timer follows the title
                // and keeps its width; the title truncates instead.
                title
                if let status { status.fixedSize() }
                countView
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 4)
        .padding(.top, TimelineMetrics.textTop(minutes))
        // minHeight 0: in a 15-minute block the frame is the block, not the taller line,
        // so the line really centres (Gemini review). Clipped, so a very narrow column
        // never spills "Done?" or a timer onto its neighbour.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
               alignment: TimelineMetrics.textAlignment(minutes))
        .clipped()
    }

    /// A counted goal's "10/30" at the right end of the title line, where the list shows
    /// it (user, 2026-11-13); kept whole, the title truncates instead.
    @ViewBuilder
    private var countView: some View {
        if let count {
            Spacer(minLength: 4)
            Text(verbatim: "\(count.done)/\(count.target)")
                .font(TimelineMetrics.detailFont.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    /// The goal's progress in its current round, as its row counts it; a task's own block
    /// shows its steps done, as its row does (SPEC 2026-11-21).
    private var count: (done: Int, target: Int)? {
        guard let row else { return nil }
        if let target = row.item.progress.target { return (row.progressAmount, target) }
        if b.stepId == nil, !row.isDone, let steps = model.steps(of: row.id) { return (steps.done, steps.total) }
        return nil
    }

    /// A step's block keeps the step's name: the task's part truncates first (review).
    @ViewBuilder
    private var title: some View {
        if let step, let task = row?.item.title {
            HStack(spacing: 0) {
                Text(task)
                Text(verbatim: " - ").fixedSize()
                Text(step.step.title).layoutPriority(1)
            }
            .font(TimelineMetrics.titleFont)
            .foregroundStyle(.primary)
        } else {
            Text(block.title)
                .font(TimelineMetrics.titleFont)
                .foregroundStyle(.primary)
        }
    }

    /// What a block says besides its title: a slot block's question, or its focus timer.
    private var status: Text? {
        if block.state == .asking {
            // A slot block never ticks by itself: it asks (SPEC 2026-11-10).
            return Text("Done?")
                .font(TimelineMetrics.detailFont.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        if let timer {
            // Its focus timer counts down here, since the task is not in the list.
            return Text(verbatim: (timer.phase == .rest ? "☕ " : "⏱ ") + RowView.clock(timer.remaining(at: model.clockTick)))
                .font(TimelineMetrics.detailFont.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        return nil
    }

    var gripInside: CGFloat { TimelineMetrics.grip(height: max(height - 1, 6)).inside }
    var gripBelow: CGFloat { TimelineMetrics.grip(height: max(height - 1, 6)).below }

    /// The bottom edge's grip: 12 points tall on a block of 30 minutes or more.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: gripInside + gripBelow)
            .overlay {
                if onEdge || resizeBy != 0 {
                    Capsule().fill(Color.accentColor.opacity(0.8)).frame(width: 24, height: 3)
                }
            }
            .contentShape(Rectangle())
            // The cursor is set on every move over the grip and through the resize, so a
            // tooltip or a redraw cannot put the arrow back (user, 2026-11-13: SwiftUI's
            // pointer style showed the resize cursor only in a narrow part of the grip).
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    onEdge = true
                    Self.resizeCursor.set()
                case .ended:
                    onEdge = false
                    if !resizing { NSCursor.arrow.set() }
                }
            }
            .onChange(of: resizing) { _, live in
                // Ended or cancelled: nothing of the resize stays, and the arrow comes
                // back unless the pointer is still on the grip.
                guard !live else { return }
                resizeBy = 0
                if !onEdge { NSCursor.arrow.set() }
            }
            // The grip going away under the pointer (the block deleted or no longer
            // changeable) or the menu closing never sends "hover ended".
            .onDisappear { resetCursor() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                resetCursor()
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(space))
                    .updating($resizing) { _, live, _ in live = true }
                    .onChanged { value in
                        Self.resizeCursor.set()
                        let room = TimelineMetrics.room(after: b.start, in: day)
                        let wanted = b.minutes + Self.snap(value.translation.height)
                        resizeBy = min(max(wanted, Clew.blockStepMinutes), room) - b.minutes
                    }
                    .onEnded { value in
                        let room = TimelineMetrics.room(after: b.start, in: day)
                        let change = min(max(b.minutes + Self.snap(value.translation.height), Clew.blockStepMinutes), room) - b.minutes
                        resizeBy = 0
                        if change != 0 { model.resizeBlock(b.id, minutes: b.minutes + change) }
                    }
            )
    }

    /// The bottom-edge resize cursor, as a window's bottom edge shows it (the one SwiftUI's
    /// pointer style gave before; `resizeUpDown` has a bar between the arrows).
    static var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) { NSCursor.frameResize(position: .bottom, directions: .all) } else { .resizeUpDown }
    }

    /// Back to the arrow if this grip set the resize cursor.
    private func resetCursor() {
        guard onEdge || resizing || resizeBy != 0 else { return }
        onEdge = false
        NSCursor.arrow.set()
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
            .updating($dragging) { _, live, _ in live = true }
            // The list draws and drops it: over the hours it moves, over the list it goes
            // back there (SPEC 2026-11-10).
            .onChanged { onDrag($0) }
            .onEnded { value in
                onDrag(value)          // from the final position, whatever state a cancel reset
                onDrop()
            }
    }

    /// A drag in points as whole quarter hours of minutes.
    static func snap(_ points: CGFloat) -> Int {
        Clew.snapMinutes(Double(points / TimelineMetrics.pointsPerMinute))
    }

    /// The running focus timer, if it is this task's (never on a step's block: Focus is the
    /// task's).
    private var timer: FocusTimer? { model.focus?.itemId == b.itemId && b.stepId == nil ? model.focus : nil }

    /// A step's block (SPEC 2026-11-21): Done / Undo for the step, then the block's own; no
    /// Focus (it is the task's); Delete deletes the step.
    @ViewBuilder
    private var stepMenu: some View {
        if let step {
            Button(step.isDone ? "Undo" : "Done") { model.tapStep(step) }
            Divider()
        }
        if block.state == .ticked {
            Button("Not finished") { model.blockNotFinished(b.id) }
        }
        Button("Move to…", action: onMove)
        Menu("Length") {
            ForEach(Clew.blockLengths.filter { $0 <= TimelineMetrics.room(after: b.start, in: day) }, id: \.self) { m in
                Button("\(m) min") { model.resizeBlock(b.id, minutes: m) }
                    .disabled(m == b.minutes)
            }
        }
        if model.canAddBlock(after: b), row != nil {
            Button("Add another block") { model.addBlock(after: b.id) }
        }
        Divider()
        Button("Remove block") { model.removeBlock(b.id) }
        if let step {
            Button("Delete", role: .destructive) { model.deleteStep(step.step) }
        }
    }

    /// The row's menu first (user, 2026-11-10: the same operations in the list and on the
    /// timeline), then the block's own.
    @ViewBuilder
    private var menu: some View {
        if let row {
            if row.item.kind == .goal, !row.isGoalReached {
                Button("+1") { model.tap(row) }
            } else if !row.isDone {
                Button("Done") { model.tap(row) }
            }
            if row.todayAmount > 0 {
                Button(row.item.kind == .goal ? "Undo +1" : "Undo") { model.undo(row) }
            }
            Button("Details", action: onOpen)
            Button("Edit…") { onEdit(row.item) }
            if let timer {
                if timer.phase == .focus, timer.isOver(at: Date()) {
                    if !row.isGoalReached {
                        Button(row.item.kind == .goal ? "+1 and stop" : "Done and stop") { model.finishFocus(row) }
                    }
                    Button("5 more min") { model.extendFocus() }
                    if model.focusOffersBreak {
                        Button("Break") { model.startBreak() }
                    }
                } else if timer.phase == .focus {
                    Button(timer.isPaused ? "Resume the timer" : "Pause the timer") {
                        timer.isPaused ? model.resumeFocus() : model.pauseFocus()
                    }
                }
                Button("Stop the timer") { model.stopFocus() }
            } else if model.focus?.phase != .focus, !row.isGoalReached {
                Menu("Focus") {
                    ForEach(Clew.focusMinutes, id: \.self) { m in
                        Button("\(m) min") { model.startFocus(row, minutes: m) }
                    }
                }
            }
            if (row.item.kind == .once || row.item.kind == .link), row.progressAmount == 0 {
                Button("Move to Later") { model.moveToLater(row) }
            }
            Divider()
        }
        if block.state == .ticked, block.canChange {
            Button("Not finished") { model.blockNotFinished(b.id) }
        }
        if block.canChange {
            Button("Move to…", action: onMove)
            Menu("Length") {
                ForEach(Clew.blockLengths.filter { $0 <= TimelineMetrics.room(after: b.start, in: day) }, id: \.self) { m in
                    Button("\(m) min") { model.resizeBlock(b.id, minutes: m) }
                        .disabled(m == b.minutes)
                }
            }
        }
        if model.canAddBlock(after: b), row != nil {
            Button("Add another block") { model.addBlock(after: b.id) }
        }
        Divider()
        Button("Remove block") { model.removeBlock(b.id) }
        if row != nil {
            Button("Delete", role: .destructive) { model.delete(b.itemId) }
        }
    }
}

/// The block a drag on the timeline is making (SPEC 2026-11-19): light, with its time.
struct SweepBlock: View {
    let draft: NewTaskDraft

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        shape.fill(Color.accentColor.opacity(0.16))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text(verbatim: TimelineMetrics.range(draft.start, draft.end))
                    .font(TimelineMetrics.detailFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 7)
                    .padding(.top, TimelineMetrics.textTop(draft.minutes))
            }
            // The box's own height, so nothing jumps when it opens (review).
            .frame(height: NewTaskDraft.boxHeight(draft.minutes))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A calendar event: a stripe in its calendar's colour, a light fill, the title in
/// secondary text (SPEC "Calendar events"). Never ticked. One the user may change
/// (SPEC 2026-11-19): click for its page, drag to move, drag the bottom edge for its end.
struct TimelineEventView: View {
    let event: CalendarEvent
    /// Where it shows now (moved while dragged, or waiting for the repeat question).
    let start: Date
    let end: Date
    let space: String
    let editable: Bool
    let onOpen: () -> Void
    /// A drag (true: the bottom edge's), nil when cancelled; and its letting go.
    let onDrag: (Bool, DragGesture.Value?) -> Void
    let onDrop: (Bool) -> Void

    @GestureState private var moving = false
    @GestureState private var resizing = false
    @State private var onEdge = false

    static func height(_ start: Date, _ end: Date) -> CGFloat {
        max(CGFloat(end.timeIntervalSince(start) / 60) * TimelineMetrics.pointsPerMinute - 1, 6)
    }

    private var range: String { TimelineMetrics.range(start, end) }
    private var minutes: Double { end.timeIntervalSince(start) / 60 }

    var body: some View {
        if editable {
            card
                .overlay(alignment: .bottom) {
                    grip.alignmentGuide(.bottom) { $0[.bottom] - TimelineMetrics.grip(height: Self.height(start, end)).below }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .gesture(drag(resize: false, $moving))
                .onChange(of: moving) { _, live in if !live { onDrag(false, nil) } }
                // Gone mid-drag (changed elsewhere): nothing of the drag stays (review).
                .onDisappear { if moving || resizing { onDrag(resizing, nil) } }
                .accessibilityAction(named: Text("Edit event"), onOpen)
        } else {
            card
        }
    }

    /// The bottom edge's grip, as a block's (TimelineMetrics.grip).
    private var grip: some View {
        Color.clear
            .frame(height: { let g = TimelineMetrics.grip(height: Self.height(start, end)); return g.inside + g.below }())
            .overlay {
                if onEdge || resizing {
                    Capsule().fill(EventColor.of(event).opacity(0.8)).frame(width: 24, height: 3)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    onEdge = true
                    TimelineBlockView.resizeCursor.set()
                case .ended:
                    onEdge = false
                    if !resizing { NSCursor.arrow.set() }
                }
            }
            .onChange(of: resizing) { _, live in
                guard !live else { return }
                onDrag(true, nil)
                if !onEdge { NSCursor.arrow.set() }
            }
            .onDisappear { if onEdge || resizing { onEdge = false; NSCursor.arrow.set() } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                if onEdge { onEdge = false; NSCursor.arrow.set() }
            }
            .gesture(drag(resize: true, $resizing))
    }

    private func drag(resize: Bool, _ state: GestureState<Bool>) -> some Gesture {
        DragGesture(minimumDistance: resize ? 2 : 3, coordinateSpace: .named(space))
            .updating(state) { _, live, _ in live = true }
            .onChanged { value in
                if resize { TimelineBlockView.resizeCursor.set() }
                onDrag(resize, value)
            }
            .onEnded { value in
                onDrag(resize, value)
                onDrop(resize)
            }
    }

    private var card: some View {
        let color = EventColor.of(event)
        return RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(0.12))
            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
            .overlay {
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title).font(TimelineMetrics.titleFont).lineLimit(1)
                    if TimelineMetrics.hasSecondLine(minutes) {
                        Text(verbatim: range).font(TimelineMetrics.detailFont.monospacedDigit()).lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 7)
                .padding(.top, TimelineMetrics.textTop(Int(minutes)))
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                       alignment: TimelineMetrics.textAlignment(Int(minutes)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .help(Text(verbatim: "\(event.title) · \(range)"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Calendar: \(event.title), \(range)"))
    }
}

enum EventColor {
    static func of(_ event: CalendarEvent) -> Color {
        let c = event.color + [0.5, 0.5, 0.5]
        return Color(.sRGB, red: c[0], green: c[1], blue: c[2])
    }
}

/// "Put on timeline…" and a block's "Move to…": a start time and a length, without
/// dragging (SPEC 2026-11-10; also the VoiceOver way).
extension TimelineDay {
    /// A wall-clock time on this timeline, by the Clew day's own rule (so a daylight-saving
    /// day is right too): before the rollover hour it is the night at the end. Kept
    /// inside the timeline, a quarter hour before its end at the latest.
    func start(at time: TimeOfDay, rolloverHour: Int) -> Date {
        let at = day.instant(at: time, in: .current, rolloverHour: rolloverHour)
        return min(max(at, start), end.addingTimeInterval(-TimeInterval(Clew.blockStepMinutes * 60)))
    }

    /// The next quarter hour from `now` on this timeline, as a time (its last if none is left).
    func nextQuarter(after now: Date) -> TimeOfDay {
        let q = min(max(0, Int(ceil(now.timeIntervalSince(start) / 60 / 15))), TimelineMetrics.quarters(self) - 1)
        return QuarterTime.nearest(TimeOfDay(pickerDate: start.addingTimeInterval(TimeInterval(q * 15 * 60))))
    }
}

struct PlaceView: View {
    let model: AppModel
    let itemId: UUID
    /// Moving this block; nil places the task (moving its open block, or adding one).
    let blockId: UUID?
    let onDone: () -> Void

    /// The start's wall-clock time, on a quarter hour (user, 2026-11-18: one time field,
    /// the hour or the minutes selected and changed with the arrow keys).
    @State private var time = TimeOfDay(hour: 9, minute: 0)!
    @State private var minutes = Clew.blockDefaultMinutes

    private var day: TimelineDay? { model.timeline }
    /// A step's block is named as on the timeline: "Prepare the talk - Speech notes" (review).
    private var title: String {
        blockId.flatMap { id in day?.blocks.first { $0.id == id }?.title }
            ?? model.today?.rows.first { $0.id == itemId }?.item.title ?? ""
    }
    /// The time on today's timeline: before the rollover hour it is the night after
    /// midnight, at the timeline's end.
    private var start: Date? {
        day?.start(at: time, rolloverHour: model.rolloverHour)
    }
    private var room: Int { day.flatMap { d in start.map { TimelineMetrics.room(after: $0, in: d) } } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).lineLimit(1)
            if day != nil {
                // "at [10:15] for [30 min]", as a habit's slot reads.
                AtForLine(time: $time, minutes: $minutes,
                          lengths: Clew.blockLengths.filter { $0 <= max(room, Clew.blockStepMinutes) })
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Text("Cancel"))
                Button(blockId == nil ? "Put on timeline" : "Move") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(minutes > room)
                    .accessibilityLabel(blockId == nil ? Text("Put \(title) on the timeline") : Text("Move the block"))
            }
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .onAppear(perform: setUp)
    }

    private func setUp() {
        guard let day else { return }
        let block = day.blocks.first { $0.id == blockId }?.block
        // A new block starts at the next quarter hour; a moved one where it is.
        time = day.nextQuarter(after: block?.start ?? Date())
        minutes = block?.minutes ?? Clew.blockDefaultMinutes
    }

    private func save() {
        guard let start else { return }
        let ok = if let blockId {
            model.moveBlock(blockId, to: start, minutes: minutes)
        } else {
            model.place(itemId, at: start, minutes: minutes)
        }
        if ok { onDone() }
    }
}

/// The timeline's card, floating just above the menu (SPEC 2026-11-19).
private struct FloatingCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        let dark = scheme == .dark
        // Light: a nearly opaque sheet, so the shadow shows only outside it. Dark: a
        // slightly lighter surface than the glass, as macOS shows height in dark mode.
        let fill: Color = dark ? .white.opacity(0.08) : Color(nsColor: .textBackgroundColor).opacity(0.95)
        // A faint edge; in dark a light one, a little brighter along the top.
        let edge = LinearGradient(colors: dark ? [.white.opacity(0.16), .white.opacity(0.05)]
                                               : [.black.opacity(0.05), .black.opacity(0.05)],
                                  startPoint: .top, endPoint: .bottom)
        content
            .background(shape.fill(fill))
            .clipShape(shape)
            .overlay(shape.strokeBorder(edge, lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true))
            // A tight shadow, lower than a dragged row's (0.18, radius 6, y 2) so a drag
            // still rises highest. Drawn from a solid shape with its inside cut away, so
            // it shows only outside the card, whatever the card's own opacity.
            .background {
                // Inset a little, so the caster's soft edge stays inside the cut-out (review:
                // the corners showed it); dark below a dragged row's 0.18 too, the lighter
                // surface does the lifting there.
                shape.inset(by: 0.75).fill(Color.black)
                    .shadow(color: .black.opacity(dark ? 0.16 : 0.10), radius: 2.5, y: 1)
                    .mask {
                        Rectangle().padding(-16)
                            .overlay(shape.blendMode(.destinationOut))
                            .compositingGroup()
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
