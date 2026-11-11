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
    /// A block's drag, reported to the list (nil: cancelled), and its drop.
    let onDrag: (TimelineBlock, DragGesture.Value?) -> Void
    let onDrop: (TimelineBlock) -> Void
    let onMove: (TimelineBlock) -> Void
    let onOpen: (UUID) -> Void
    let onEdit: (Item) -> Void

    var body: some View {
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                grid
                GeometryReader { g in
                    let width = g.size.width - TimelineMetrics.labelWidth - TimelineMetrics.trailing
                    ForEach(day.blocks) { block in
                        TimelineBlockView(model: model, block: block, day: day, space: space,
                                          isLifted: liftedBlock == block.id, hovered: $hovered,
                                          onDrag: { onDrag(block, $0) }, onDrop: { onDrop(block) },
                                          onMove: { onMove(block) }, onOpen: { onOpen(block.block.itemId) },
                                          onEdit: onEdit)
                            .frame(width: max(20, width / CGFloat(block.lanes) - 2))
                            .offset(x: TimelineMetrics.labelWidth + CGFloat(block.lane) * width / CGFloat(block.lanes),
                                    y: TimelineMetrics.y(block.block.start, in: day))
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
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(space)).minY } action: { geometry.contentTop = $0 }
        }
        .scrollPosition(id: $topQuarter, anchor: .top)
        .frame(height: TimelineMetrics.height)
        // Its own card: a faint tint and rounded corners, inset like the list's rows.
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { geometry.viewport = $0 }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        // Every time the menu opens, now is a third of the way down.
        .onAppear(perform: centreOnNow)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in centreOnNow() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Today's timeline"))
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
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .offset(y: -6)
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
            .overlay(alignment: .bottom) { if block.canChange { resizeHandle } }
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
            .accessibilityLabel(Text("\(block.title), \(range)"))
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
        "\(TimelineMetrics.time(b.start))–\(TimelineMetrics.time(b.start.addingTimeInterval(TimeInterval(minutes * 60))))"
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
        HStack(alignment: .top, spacing: 3) {
            if looksDone {
                Image(systemName: "checkmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(block.title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(looksDone ? .secondary : .primary)
                if block.state == .asking {
                    // A slot block never ticks by itself: it asks (SPEC 2026-11-10).
                    Text("Done?")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                } else if let timer {
                    // Its focus timer counts down here, since the task is not in the list.
                    Text(verbatim: (timer.phase == .rest ? "☕ " : "⏱ ") + RowView.clock(timer.remaining(at: model.clockTick)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if height >= 30 {
                    Text(verbatim: range)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, minutes <= 15 ? 0 : 2)
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
            .offset(y: 4)
            .onHover { onEdge = $0 }
            .modifier(ResizePointer())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(space))
                    .onChanged { value in
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

/// The up-down resize cursor over a block's bottom edge (macOS 15+).
struct ResizePointer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.frameResize(position: .bottom))
        } else {
            content
        }
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
