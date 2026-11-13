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
}

enum TimelineMetrics {
    /// 60 points an hour.
    static let pointsPerMinute: CGFloat = 1
    /// About 6 hours show (user, 2026-11-10; was 4).
    static let height: CGFloat = 360
    static let labelWidth: CGFloat = 40
    /// Room between the blocks and hour lines and the card's right edge, so the timeline
    /// reads as its own area, apart from the list (user, 2026-11-11).
    static let trailing: CGFloat = 8
    /// The current time sits this far down when the menu opens: 2 of the 6 hours behind
    /// it, 4 ahead (user, 2026-11-11).
    static let quartersBeforeNow = 8
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

    /// While the name box is open, one layout for blocks, events and the box, so the box
    /// sits in the column its block will get (SPEC 2026-11-13).
    private var draftLayout: (blocks: [UUID: TimelinePlace], events: [String: TimelinePlace], draft: TimelinePlace?)? {
        newTask.map { Clew.timelineLayout(blocks: day.blocks, timed: model.calendarEvents?.timed ?? [],
                                          draft: ($0.start, $0.end)) }
    }

    /// Blocks and events together: a block's column comes from the shared layout when
    /// calendar events show.
    private func place(_ block: TimelineBlock, _ layout: (blocks: [UUID: TimelinePlace], events: [String: TimelinePlace], draft: TimelinePlace?)?) -> TimelinePlace {
        layout?.blocks[block.id] ?? model.calendarEvents?.blockPlaces[block.id]
            ?? TimelinePlace(lane: block.lane, lanes: block.lanes)
    }

    /// Where a column starts and how wide it is, in the hours' coordinates.
    private func columns(_ place: TimelinePlace, width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        (TimelineMetrics.labelWidth + CGFloat(place.lane) * width / CGFloat(place.lanes),
         max(20, width / CGFloat(place.lanes) - 2))
    }

    /// Opens the name box at the quarter hour `y` points into the day, unless the double-
    /// click was on a block (its own click opens details) or inside the open box.
    private func openNewTask(at point: CGPoint, width: CGFloat) {
        let layout = draftLayout
        func hits(_ start: Date, _ end: Date, _ place: TimelinePlace) -> Bool {
            let col = columns(place, width: width)
            return point.y >= TimelineMetrics.y(start, in: day) && point.y < TimelineMetrics.y(end, in: day)
                && point.x >= col.x && point.x < col.x + col.width
        }
        if day.blocks.contains(where: { hits($0.block.start, $0.block.end, place($0, layout)) }) { return }
        if let box = newTask, let at = layout?.draft, hits(box.start, box.end, at) { return }
        newTask = NewTaskDraft(minutesIn: Double(point.y / TimelineMetrics.pointsPerMinute), day: day)
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
        }
        // Its own card: a shallower fill than the list, slightly translucent, with rounded corners, inset like the list's rows.
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        // Every time the menu opens, now is a third of the way down.
        // While the name box is open, the timeline stays where it is.
        .onAppear { if newTask == nil { centreOnNow() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if newTask == nil { centreOnNow() }
        }
        // The rollover closes the box; nothing is made.
        .onChange(of: day.day) { newTask = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Today's timeline"))
        .accessibilityAction(named: Text("New task on the timeline"), openNewTaskAtNextQuarter)
    }

    /// Above the hours: "Show your calendar" until it is on (or closed), a note when macOS
    /// does not allow it, and today's all-day events as one thin line.
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
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                grid
                GeometryReader { g in
                    let width = g.size.width - TimelineMetrics.labelWidth - TimelineMetrics.trailing
                    let layout = draftLayout
                    ZStack(alignment: .topLeading) {
                    // Calendar events first, so task blocks draw over them.
                    ForEach(model.calendarEvents?.timed ?? []) { event in
                        let col = columns(layout?.events[event.id] ?? model.calendarEvents?.eventPlaces[event.id]
                                          ?? TimelinePlace(lane: 0, lanes: 1), width: width)
                        TimelineEventView(event: event)
                            .frame(width: col.width,
                                   height: max(CGFloat(event.end.timeIntervalSince(event.start) / 60) * TimelineMetrics.pointsPerMinute - 1, 6))
                            .offset(x: col.x, y: TimelineMetrics.y(event.start, in: day))
                    }
                    ForEach(day.blocks) { block in
                        let col = columns(place(block, layout), width: width)
                        TimelineBlockView(model: model, block: block, day: day, space: space,
                                          isLifted: liftedBlock == block.id, hovered: $hovered,
                                          onDrag: { onDrag(block, $0) }, onDrop: { onDrop(block) },
                                          onMove: { onMove(block) }, onOpen: { onOpen(block.block.itemId) },
                                          onEdit: onEdit)
                            .frame(width: col.width)
                            .offset(x: col.x, y: TimelineMetrics.y(block.block.start, in: day))
                    }
                    if let draft = newTask, let at = layout?.draft {
                        let col = columns(at, width: width)
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
                                .frame(width: g.size.width - TimelineMetrics.labelWidth + 4 - TimelineMetrics.trailing, height: 1)
                                .offset(x: TimelineMetrics.labelWidth - 4, y: TimelineMetrics.y(context.date, in: day))
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
                        openNewTask(at: value.location, width: width)
                    })
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(space)).minY } action: { geometry.contentTop = $0 }
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
    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(0..<TimelineMetrics.quarters(day), id: \.self) { q in
                HStack(alignment: .top, spacing: 4) {
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
                    .frame(width: TimelineMetrics.labelWidth - 4, alignment: .trailing)
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
        return date.formatted(.dateTime.hour())
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
    /// Ticked, covered by a hand tick, or the task is done anyway.
    private var looksDone: Bool {
        block.state == .ticked || block.state == .covered || (block.state == .skipped && row?.isDone == true)
    }
    private var minutes: Int { b.minutes + resizeBy }
    /// Running now: it stands out a little (user, 2026-11-11). Redrawn at each block's start
    /// and end, when the app refreshes.
    private var isNow: Bool { block.state == .pending && b.start <= Date() && Date() < b.end }
    private var height: CGFloat { CGFloat(minutes) * TimelineMetrics.pointsPerMinute }

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(looksDone ? Color.secondary.opacity(0.14)
                  : isNow ? Color.accentColor.opacity(0.32)
                  : block.state == .pending || block.state == .asking ? Color.accentColor.opacity(0.22)
                  : Color.secondary.opacity(0.08))
            .overlay(alignment: .leading) {
                if isNow {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .topLeading) { label }
            // The grip reaches 4 points below the block, placed by layout (not a visual
            // offset), so the hover, the cursor and the drag all use the same strip.
            .overlay(alignment: .bottom) {
                if block.canChange { resizeHandle.alignmentGuide(.bottom) { $0[.bottom] - 4 } }
            }
            .frame(height: max(height - 1, 6))
            // While dragged, the lifted card draws it, over the hours or over the list.
            .opacity(isLifted ? 0 : 1)
            .contentShape(Rectangle())
            // The same as a row: click opens the details, right-click the menu.
            .onTapGesture(perform: onOpen)
            .gesture(moveGesture)
            .onHover { inside in
                if inside { hovered = b.itemId } else if hovered == b.itemId { hovered = nil }
            }
            .contextMenu { menu }
            .onChange(of: dragging) { _, live in
                // Ended or cancelled: nothing of the drag stays on screen.
                if !live, isLifted { onDrag(nil) }
            }
            .onDisappear {
                if isLifted { onDrag(nil) }
                if hovered == b.itemId { hovered = nil }
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

    private var range: String {
        TimelineMetrics.range(b.start, b.start.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    private var stateText: Text {
        switch block.state {
        case .pending: Text("Not ended yet")
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

    /// The goal's progress in its current round, as its row counts it.
    private var count: (done: Int, target: Int)? {
        guard let row, let target = row.item.progress.target else { return nil }
        return (row.progressAmount, target)
    }

    private var title: Text {
        Text(block.title)
            .font(TimelineMetrics.titleFont)
            .foregroundStyle(looksDone ? .secondary : .primary)
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

    /// The bottom edge's grip: 12 points tall, reaching 4 below the block, so it is easy
    /// to catch (user, 2026-11-11: 6 points was hard to hit).
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 12)
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
    private static var resizeCursor: NSCursor {
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

    /// The running focus timer, if it is this task's.
    private var timer: FocusTimer? { model.focus?.itemId == b.itemId ? model.focus : nil }

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

/// A calendar event: a stripe in its calendar's colour, a light fill, the title in
/// secondary text. Read only: nothing to drag or tick (SPEC "Calendar events").
struct TimelineEventView: View {
    let event: CalendarEvent

    private var range: String { TimelineMetrics.range(event.start, event.end) }
    private var minutes: Double { event.end.timeIntervalSince(event.start) / 60 }

    var body: some View {
        let color = EventColor.of(event)
        RoundedRectangle(cornerRadius: 4)
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
struct PlaceView: View {
    let model: AppModel
    let itemId: UUID
    /// Moving this block; nil places the task (moving its open block, or adding one).
    let blockId: UUID?
    let onDone: () -> Void

    @State private var hour = 0          // hours after the day's start
    @State private var quarter = 0
    @State private var minutes = Clew.blockDefaultMinutes

    private var day: TimelineDay? { model.timeline }
    private var title: String { model.today?.rows.first { $0.id == itemId }?.item.title ?? "" }
    private var start: Date? {
        day.map { $0.start.addingTimeInterval(TimeInterval((hour * 60 + quarter * 15) * 60)) }
    }
    private var room: Int { day.flatMap { d in start.map { TimelineMetrics.room(after: $0, in: d) } } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).lineLimit(1)
            if let day {
                HStack {
                    Picker(selection: $hour) {
                        ForEach(0..<(TimelineMetrics.quarters(day) / 4), id: \.self) { h in
                            Text(verbatim: day.start.addingTimeInterval(TimeInterval(h * 3600)).formatted(.dateTime.hour())).tag(h)
                        }
                    } label: { Text("Start") }
                    .accessibilityLabel(Text("Start hour"))
                    Picker(selection: $quarter) {
                        ForEach(0..<4, id: \.self) { q in Text(verbatim: String(format: ":%02d", q * 15)).tag(q) }
                    } label: { EmptyView() }
                    .labelsHidden()
                    .frame(width: 70)
                    .accessibilityLabel(Text("Start minutes"))
                }
                Picker(selection: $minutes) {
                    ForEach(Clew.blockLengths.filter { $0 <= max(room, Clew.blockStepMinutes) }, id: \.self) { m in
                        Text("\(m) min").tag(m)
                    }
                } label: { Text("Length") }
                .accessibilityLabel(Text("Length"))
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
        let from = block?.start ?? Date()
        let q = min(Int(ceil(from.timeIntervalSince(day.start) / 60 / 15)), TimelineMetrics.quarters(day) - 1)
        hour = max(0, q) / 4
        quarter = max(0, q) % 4
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
