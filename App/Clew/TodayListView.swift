import ClewCore
import ClewDomain
import SwiftUI

struct TodayListView: View {
    let model: AppModel
    @Binding var screen: Screen
    @Environment(\.openWindow) private var openWindow
    /// Reordering with a plain drag gesture inside the list (SwiftUI's draggable /
    /// dropDestination never delivered the drop in the menu bar panel). The rows in
    /// between slide aside live; release lands it in the gap. The slot and shift math is
    /// in Core (Clew.dragSlot / dragShift / insertSlot / insertShift), tested.
    @State private var dragging: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragSlot: Int?
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// Row frames frozen when a drag begins, so slots are measured against the list as
    /// it was, not against rows that are sliding.
    @State private var dragFrames: [CGRect] = []
    /// The day timeline above the list (SPEC 2026-11-10): where it is and its scroll
    /// position (a quarter hour at the top).
    @State private var timelineGeo = TimelineGeometry()
    @State private var topQuarter: Int?
    @State private var edgeScroll: Timer?
    /// The rows' full height, so a long list scrolls instead of passing the screen.
    @State private var rowsHeight: CGFloat = 0
    /// What is being dragged, drawn as one lifted card above the list and the timeline:
    /// a row over the list, a block over the hours (user, 2026-11-10: the same thing,
    /// moving smoothly between the two).
    @State private var lifted: Lifted?
    /// Where the dragged block was grabbed, below its top (points).
    @State private var blockGrab: CGFloat = 0
    /// The task under the pointer (a row or a block): the Delete key deletes it.
    @State private var hoveredItem: UUID?
    /// The timeline's name box (SPEC 2026-11-13). It lives with the list: leaving the list
    /// (Add, Later, Settings, details) drops it.
    @State private var newTask: NewTaskDraft?
    /// Cleared by itself when a row drag ends or is cancelled.
    @GestureState private var rowDragLive = false

    private static let listSpace = "todayList"

    private var showsTimeline: Bool { model.timelineShown && model.timeline != nil }

    /// The rows may take what the screen has left after the timeline and the footer.
    private var rowsLimit: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(160, screen - (showsTimeline ? TimelineMetrics.height : 0) - 170)
    }

    /// Above the list's top, the pointer is over the hours.
    private func isOverTimeline(_ y: CGFloat) -> Bool { showsTimeline && y < timelineGeo.viewport.maxY + 4 }

    /// Where a block at `start` lasting `minutes` sits, in the list's coordinate space.
    private func blockFrame(start: Date, minutes: Int) -> CGRect {
        guard let day = model.timeline else { return .zero }
        let view = timelineGeo.viewport
        return CGRect(x: view.minX + TimelineMetrics.labelWidth,
                      y: timelineGeo.contentTop + TimelineMetrics.y(start, in: day),
                      width: max(20, view.width - TimelineMetrics.labelWidth - TimelineMetrics.trailing),
                      height: CGFloat(minutes) * TimelineMetrics.pointsPerMinute)
    }

    /// A row's place and size for a card over the list: like the first row, at `y`.
    private func rowFrame(centeredAt y: CGFloat) -> CGRect {
        let sample = dragFrames.first ?? rowFrames.values.first ?? CGRect(x: 0, y: 0, width: 340, height: 34)
        return CGRect(x: sample.minX, y: y - sample.height / 2, width: sample.width, height: sample.height)
    }

    /// Near the timeline's top or bottom edge while dragging, it scrolls by itself.
    private func scrollAtEdge(_ y: CGFloat?) {
        let view = timelineGeo.viewport
        var step = 0
        if let y, y < view.maxY {
            if y < view.minY + 18 { step = -1 } else if y > view.maxY - 18 { step = 1 }
        }
        guard step != 0 else {
            edgeScroll?.invalidate()
            edgeScroll = nil
            return
        }
        guard edgeScroll == nil else { return }
        let direction = step
        let timer = Timer(timeInterval: 0.12, repeats: true) { _ in
            Task { @MainActor in
                guard let day = model.timeline else { return }
                let visible = Int(TimelineMetrics.height) / TimelineMetrics.quarter
                let top = (topQuarter ?? 0) + direction
                topQuarter = min(max(top, 0), TimelineMetrics.quarters(day) - visible)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeScroll = timer
    }

    private func offset(for row: TodayRow, at index: Int, in rows: [TodayRow]) -> CGFloat {
        // A block coming down from the timeline opens a gap where it would land.
        if let lifted, lifted.blockId != nil, let slot = lifted.slot {
            let height = Double(dragFrames.first?.height ?? 34)
            return CGFloat(Clew.insertShift(index: index, slot: slot, height: height))
        }
        guard let dragging, let from = rows.firstIndex(where: { $0.id == dragging }) else { return 0 }
        if row.id == dragging { return dragTranslation }
        let height = Double(dragFrames.indices.contains(from) ? dragFrames[from].height : 0)
        return CGFloat(Clew.dragShift(index: index, from: from, to: dragSlot ?? from, draggedHeight: height))
    }

    private func endDrag() {
        scrollAtEdge(nil)
        lifted = nil
        dragging = nil
        dragTranslation = 0
        dragSlot = nil
    }

    // MARK: Dragging a row

    private func drag(_ row: TodayRow, in rows: [TodayRow]) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.listSpace))
            .updating($rowDragLive) { _, live, _ in live = true }
            .onChanged { value in
                if dragging == nil {
                    dragFrames = rows.map { rowFrames[$0.id] ?? .zero }
                    dragging = row.id
                }
                let from = rows.firstIndex(where: { $0.id == row.id }) ?? 0
                let own = dragFrames.indices.contains(from) ? dragFrames[from] : rowFrame(centeredAt: value.location.y)
                // Up over the hours: the card becomes the block it would be, at the
                // quarter hour under the pointer; the other rows stay where they are.
                if isOverTimeline(value.location.y), let day = model.timeline {
                    let start = TimelineMetrics.start(atContentY: value.location.y - timelineGeo.contentTop, in: day)
                    let open = day.blocks.first { $0.block.itemId == row.id && $0.block.end > Date() }?.block.minutes
                    let minutes = min(open ?? Clew.blockDefaultMinutes, TimelineMetrics.room(after: start, in: day))
                    lifted = Lifted(itemId: row.id, blockId: nil, title: row.item.title, overTimeline: true,
                                    frame: blockFrame(start: start, minutes: minutes), start: start, minutes: minutes)
                    dragTranslation = value.translation.height
                    if dragSlot != nil { withAnimation(.easeOut(duration: 0.15)) { dragSlot = nil } }
                    scrollAtEdge(value.location.y)
                    return
                }
                scrollAtEdge(nil)
                // Kept inside the rows: never over the footer (Add, Later, Settings).
                if let first = dragFrames.first, let last = dragFrames.last {
                    dragTranslation = CGFloat(Clew.clampDrag(
                        translation: Double(value.translation.height),
                        row: (minY: Double(own.minY), maxY: Double(own.maxY)),
                        list: (minY: Double(first.minY), maxY: Double(last.maxY))))
                } else {
                    dragTranslation = value.translation.height
                }
                lifted = Lifted(itemId: row.id, blockId: nil, title: row.item.title, overTimeline: false,
                                frame: own.offsetBy(dx: 0, dy: dragTranslation))
                let spans = dragFrames.map { (minY: Double($0.minY), maxY: Double($0.maxY)) }
                let slot = Clew.dragSlot(pointerY: Double(value.location.y), spans: spans)
                if slot != dragSlot {
                    withAnimation(.easeOut(duration: 0.15)) { dragSlot = slot }
                }
            }
            .onEnded { _ in
                let landing = lifted
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    if let landing, landing.overTimeline, let start = landing.start {
                        model.place(landing.itemId, at: start, minutes: landing.minutes)
                    } else if let from = rows.firstIndex(where: { $0.id == row.id }), let to = dragSlot, to != from {
                        model.drop(row.id, onto: rows[to])
                    }
                    endDrag()
                }
            }
    }

    // MARK: Dragging a block

    /// A block's move gesture reports here, so the card can leave the timeline.
    private func blockDrag(_ block: TimelineBlock, _ value: DragGesture.Value?) {
        guard let value else { return endDrag() }      // cancelled
        let b = block.block
        if lifted == nil {
            dragFrames = model.listRows.map { rowFrames[$0.id] ?? .zero }
            blockGrab = value.startLocation.y - blockFrame(start: b.start, minutes: b.minutes).minY
        }
        if isOverTimeline(value.location.y), let day = model.timeline {
            // Measured on the hours under the pointer, so the block stays under it while
            // the timeline scrolls at its edges (user, 2026-11-10).
            let top = value.location.y - blockGrab - timelineGeo.contentTop
            let start = block.canChange
                ? Clew.blockStart(minutesIn: Double(top / TimelineMetrics.pointsPerMinute), minutes: b.minutes, day: day)
                : b.start
            lifted = Lifted(itemId: b.itemId, blockId: b.id, title: block.title, overTimeline: true,
                            frame: blockFrame(start: start, minutes: b.minutes), start: start, minutes: b.minutes)
            scrollAtEdge(value.location.y)
        } else {
            // Down over the list: a row, with the rows opening the gap it would take.
            let spans = dragFrames.map { (minY: Double($0.minY), maxY: Double($0.maxY)) }
            let slot = Clew.insertSlot(pointerY: Double(value.location.y), spans: spans)
            if lifted?.slot != slot {
                withAnimation(.easeOut(duration: 0.15)) {
                    lifted = Lifted(itemId: b.itemId, blockId: b.id, title: block.title, overTimeline: false,
                                    frame: rowFrame(centeredAt: value.location.y), slot: slot)
                }
            } else {
                lifted?.overTimeline = false
                lifted?.frame = rowFrame(centeredAt: value.location.y)
            }
            scrollAtEdge(nil)
        }
    }

    private func blockDropped(_ block: TimelineBlock) {
        let landing = lifted
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if let landing, !landing.overTimeline {
                model.putBack(block.block.id, itemId: block.block.itemId, at: landing.slot ?? 0)
            } else if let landing, let start = landing.start, start != block.block.start {
                model.moveBlock(block.block.id, to: start)
            }
            endDrag()
        }
    }

    /// The lifted card: the dragged row's own look over the list, a block over the hours,
    /// one tint for both. Its frame moves smoothly from one shape to the other.
    @ViewBuilder
    private var liftedCard: some View {
        if let lifted, let row = model.row(lifted.itemId) {
            ZStack(alignment: .topLeading) {
                RowView(row: row, model: model, onEdit: {}, onOpen: {}, isDragged: true)
                    .frame(width: lifted.frame.width, alignment: .leading)
                    .opacity(lifted.overTimeline ? 0 : 1)
                LiftedBlockCard(title: lifted.title, start: lifted.start, minutes: lifted.minutes)
                    .opacity(lifted.overTimeline ? 1 : 0)
            }
            .frame(width: lifted.frame.width, height: lifted.frame.height, alignment: .topLeading)
            .clipped()
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .position(x: lifted.frame.midX, y: lifted.frame.midY)
            .animation(.spring(response: 0.22, dampingFraction: 0.9), value: lifted.overTimeline)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func rowsStack(_ rows: [TodayRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                RowView(row: row, model: model, onEdit: { screen = .edit(row.item, back: .list) },
                        onOpen: { screen = .detail(row.id) },
                        onPlace: showsTimeline ? { screen = .place(row.id, block: nil) } : nil,
                        canMoveUp: index > 0, canMoveDown: index < rows.count - 1,
                        isDragged: dragging == row.id,
                        dragActive: dragging != nil || lifted != nil,
                        onHoverChange: { inside in
                            if inside { hoveredItem = row.id } else if hoveredItem == row.id { hoveredItem = nil }
                        })
                    .background(GeometryReader { g in
                        Color.clear.preference(key: RowFrames.self,
                                               value: [row.id: g.frame(in: .named(Self.listSpace))])
                    })
                    .offset(y: offset(for: row, at: index, in: rows))
                    // The lifted card draws the dragged row, here or over the hours.
                    .opacity(dragging == row.id ? 0 : 1)
                    .gesture(drag(row, in: rows))
            }
        }
        .padding(.vertical, 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
        // A block coming down from the timeline: the list grows by one row, so the rows
        // sliding down to open its gap push what is below (the YouTube row, the footer)
        // instead of covering it (user, 2026-11-10).
        .padding(.bottom, incomingGap)
    }

    /// The extra room a block held over the list takes: one row while it is there.
    private var incomingGap: CGFloat {
        guard let lifted, lifted.blockId != nil, !lifted.overTimeline, lifted.slot != nil else { return 0 }
        return dragFrames.first?.height ?? 34
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTimeline, let day = model.timeline {
                DayTimelineView(model: model, day: day, space: Self.listSpace,
                                geometry: $timelineGeo, topQuarter: $topQuarter,
                                liftedBlock: lifted?.blockId, hovered: $hoveredItem, newTask: $newTask,
                                onDrag: blockDrag, onDrop: blockDropped,
                                onMove: { block in screen = .place(block.block.itemId, block: block.id) },
                                onOpen: { screen = .detail($0) },
                                onEdit: { item in screen = .edit(item, back: .list) })
            }
            ForEach(model.lateTicks) { late in
                LateTickLine(late: late, today: model.today?.day, model: model)
            }
            if case let rows = model.listRows, !rows.isEmpty {
                Group {
                    if rowsHeight > rowsLimit {
                        // A long list scrolls rather than pushing the menu past the screen.
                        ScrollView(.vertical) { rowsStack(rows) }
                            .frame(height: rowsLimit)
                    } else {
                        rowsStack(rows)
                    }
                }
                .onPreferenceChange(RowFrames.self) { rowFrames = $0 }
            } else {
                Group {
                    if model.today?.rows.isEmpty == false {
                        // Everything is placed; drag a block here to bring it back.
                        Text("Everything is on the timeline.")
                    } else {
                        Text("Nothing for today.")
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            }

            // Imported lists, below the tasks with no heading (SPEC 2026-11-09).
            if !model.collections.isEmpty {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach(model.collections) { summary in
                        CollectionRowView(summary: summary, model: model) { screen = .collection(summary.source) }
                    }
                }
                .padding(.vertical, 6)
            }

            NoticeView(text: model.notice ?? model.confirmation)
                .animation(.easeOut(duration: 0.4), value: model.notice ?? model.confirmation)
            if let deleted = model.lastDeleted {
                // A delete is for good, so it can be taken back for a few seconds.
                HStack(spacing: 8) {
                    Text("Deleted “\(deleted.title)”").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Undo") { model.undoDelete() }
                        .accessibilityLabel(Text("Undo deleting \(deleted.title)"))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            if model.browser?.youTube?.needsUpdate == true || model.browser?.x?.needsUpdate == true {
                // Health report, not silence (ARCHITECTURE §6). Quiet, never red.
                Label(model.browser?.youTube?.needsUpdate == true ? "YouTube import needs an update" : "X import needs an update",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .accessibilityLabel(Text("YouTube import needs an update. Nothing was removed."))
            }

            Divider()

            HStack(spacing: 12) {
                Button { screen = .add } label: { Label("Add", systemImage: "plus") }
                    .keyboardShortcut("n")
                    .accessibilityLabel(Text("Add an item"))
                Spacer()
                Button { screen = .pick } label: { Text("Later (\(model.laterCount))") }
                    .keyboardShortcut("l")
                    .accessibilityLabel(Text("Later pile, \(model.laterCount) items. Pick some for today."))
                // One click straight to Settings; Quit lives there.
                Button {
                    openWindow(id: SettingsView.windowID)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                }
                .keyboardShortcut(",")
                .help(Text("Settings"))
                .accessibilityLabel(Text("Settings"))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Above both the list and the timeline, so nothing clips it.
        .overlay(alignment: .topLeading) { liftedCard }
        .onChange(of: rowDragLive) { _, live in
            // A row drag that was cancelled leaves nothing behind.
            if !live, dragging != nil, lifted?.blockId == nil { endDrag() }
        }
        .background {
            // Delete deletes the task under the pointer, in the list or on the timeline,
            // like the menu's Delete (user, 2026-11-10); Undo shows for a few seconds.
            Button("Delete") {
                // The deleted task's view goes without an "exit" hover, so forget it here.
                if let id = hoveredItem { hoveredItem = nil; model.delete(id) }
            }
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                // While the name box is open, the keyboard edits the name.
                .disabled(hoveredItem == nil || dragging != nil || lifted != nil || newTask != nil)
                .accessibilityHidden(true)
        }
        // One space for the timeline and the rows, so a row can be dragged onto an hour.
        .coordinateSpace(name: Self.listSpace)
        // The peek beside a collection row (SPEC 2026-11-13): the list reports the
        // pointer, drags and leaving; the rows report hover and clicks.
        .background(PeekWindowReader(model: model))
        .onContinuousHover { phase in
            switch phase {
            case .active: PeekController.shared.pointerMoved()
            case .ended: PeekController.shared.pointerLeftList()
            }
        }
        .onChange(of: dragging != nil || lifted != nil) { _, active in PeekController.shared.dragChanged(active) }
        .onChange(of: model.collections) { _, lists in PeekController.shared.collectionsChanged(lists) }
        .onDisappear { PeekController.shared.listLeft() }
    }
}

/// What is being dragged (a row from the list, or a block from the timeline) and the
/// card drawing it: its frame in the list's space, and where it lands.
struct Lifted: Equatable {
    var itemId: UUID
    /// The block being dragged; nil for a row from the list.
    var blockId: UUID?
    var title: String
    var overTimeline: Bool
    var frame: CGRect
    /// Over the hours: the block it would be.
    var start: Date? = nil
    var minutes: Int = Clew.blockDefaultMinutes
    /// A block over the list: the gap it would take.
    var slot: Int? = nil
}

/// The lifted card's block shape: the same tint as a dragged row, the block's title and
/// time.
struct LiftedBlockCard: View {
    let title: String
    let start: Date?
    let minutes: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
            .overlay {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(TimelineMetrics.titleFont).lineLimit(1)
                    if let start, TimelineMetrics.hasSecondLine(Double(minutes)) {
                        Text(verbatim: TimelineMetrics.range(start, start.addingTimeInterval(TimeInterval(minutes * 60))))
                            .font(TimelineMetrics.detailFont.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, TimelineMetrics.textTop(minutes))
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                       alignment: TimelineMetrics.textAlignment(minutes))
            }
    }
}

/// "Ticked for yesterday: Write intro · Not finished": a block that ended while the
/// Mac slept ticked its task for that day (SPEC 2026-11-10). One line per task.
struct LateTickLine: View {
    let late: LateTick
    let today: LocalDay?
    let model: AppModel

    private var text: Text {
        if let today, late.day == today.adding(days: -1) {
            return Text("Ticked for yesterday: \(late.title)")
        }
        let weekday = Calendar.current.weekdaySymbols[(late.day.weekday.rawValue % 7)]
        return Text("Ticked for \(weekday): \(late.title)")
    }

    var body: some View {
        HStack(spacing: 8) {
            text
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if late.canUndo {
                Button("Not finished") { model.undoLateTicks(late.itemId) }
                    .accessibilityLabel(Text("\(late.title) was not finished"))
            }
            Button { model.dismissLateTicks(late.itemId) } label: { Image(systemName: "xmark").imageScale(.small) }
                .accessibilityLabel(Text("Close"))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

/// Shared column widths, so a collection's name lines up with the task titles.
enum TaskColumns {
    /// The tick circle (`circle` at `.title3`, measured 19 pt on a 2x render).
    static let circleWidth: CGFloat = 19
}

struct RowView: View {
    let row: TodayRow
    let model: AppModel
    let onEdit: () -> Void
    let onOpen: () -> Void
    /// "Put on timeline…", when the timeline is shown.
    var onPlace: (() -> Void)? = nil
    var canMoveUp = false
    var canMoveDown = false
    /// This row is being dragged: it gets a solid background so rows sliding under it
    /// don't show through.
    var isDragged = false
    /// Something is being dragged: rows under the pointer do not light up (user,
    /// 2026-11-10: it looked as if they were selected).
    var dragActive = false
    /// Tells the list which task is under the pointer (the Delete key's target).
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var hovering = false
    @State private var hoveringDots = false
    /// Where the title text starts in the row, so the under-title bar lines up with it.
    @State private var titleInset: CGFloat = 26
    private static let rowSpace = "row"

    /// Rating dots are on and there is a live tick today to rate.
    private var canRate: Bool { model.ratingsOn && row.lastTickToday != nil }
    /// Shown for a few seconds after a tick (a hint), and whenever the dots' place is
    /// hovered, so a rating can be given or changed later.
    private var showsDots: Bool { canRate && (model.ratingPrompt?.itemId == row.id || hoveringDots) }

    private var dots: some View {
        RatingDots(rating: model.ratingPrompt?.itemId == row.id ? model.ratingPrompt?.rating ?? row.lastTickToday?.rating
                                                                  : row.lastTickToday?.rating) { model.rate(row, $0) }
            .transition(.opacity)
    }

    private var item: Item { row.item }

    /// This row's focus timer or break, if it has the running one.
    private var timer: FocusTimer? { model.focus?.itemId == row.id ? model.focus : nil }

    /// How far along the row is, drawn in the chosen style: while a timer runs, the
    /// time (SPEC 2026-11-10); else a goal's count this round, or how much of a video
    /// was watched. Nil: nothing to draw.
    private func fraction(now: Date) -> Double? {
        if let timer { return timer.fraction(at: now) }
        if let target = item.progress.target, target > 0 {
            return Double(min(row.progressAmount, target)) / Double(target)
        }
        if let watched = model.watched[row.id], watched > 0 { return watched }
        return nil
    }

    var body: some View {
        // Only the row with the running timer reads the model's tick, so only it
        // redraws every second.
        if timer != nil {
            content(now: model.clockTick)
        } else {
            content(now: Date())
        }
    }

    private func content(now: Date) -> some View {
        let fraction = fraction(now: now)
        return VStack(alignment: .leading, spacing: 4) {
            mainLine(now: now)
                .background {
                    // Fills the title line only, out to the row's rounded edges, so a
                    // "goal reached" block below it stays plain.
                    if model.barStyle == .behindTitle, let fraction {
                        ProgressFill(fraction: fraction)
                            .padding(.horizontal, -6)
                            .padding(.vertical, -5)
                    }
                }
            if model.barStyle == .underTitle, let fraction {
                // Starts where the title's text starts and sits just under it, so it
                // reads as this row's bar, not the next one's.
                ProgressLine(fraction: fraction)
                    .padding(.leading, titleInset)
                    .padding(.top, -2)
            }
            if let timer, timer.phase == .focus, timer.isOver(at: now) {
                timeUp
            }
            if row.isGoalReached, !model.dismissedCelebrations.contains(row.id) {
                celebration
            }
        }
        .coordinateSpace(.named(Self.rowSpace))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background {
            ZStack {
                if isDragged {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(hovering && !dragActive ? 0.06 : 0))
                }
            }
            .padding(.horizontal, 6)
        }
        // A little clear space between rows, so two filled rows don't run together.
        .padding(.vertical, 2)
        // The whole row, margins included, opens the details; the circle, link mark,
        // − and celebration buttons are buttons and keep their own clicks.
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0; onHoverChange?($0) }
        .accessibilityAction(named: Text("Move Up")) { if canMoveUp { model.move(row, by: -1) } }
        .accessibilityAction(named: Text("Move Down")) { if canMoveDown { model.move(row, by: 1) } }
        .accessibilityActions {
            if let onPlace { Button("Put on timeline…", action: onPlace) }
        }
        .contextMenu {
            if row.todayAmount > 0 {
                if item.kind == .goal {
                    Button("Undo +1") { model.undo(row) }
                } else {
                    Button("Undo") { model.undo(row) }
                }
            }
            Button("Details", action: onOpen)
            Button("Edit…", action: onEdit)
            if let onPlace {
                Button("Put on timeline…", action: onPlace)
            }
            if timer == nil, model.focus?.phase != .focus, !row.isGoalReached {
                Menu("Focus") {
                    ForEach(Clew.focusMinutes, id: \.self) { m in
                        Button("\(m) min") { model.startFocus(row, minutes: m) }
                    }
                }
            }
            if (item.kind == .once || item.kind == .link), row.progressAmount == 0 {
                Button("Move to Later") { model.moveToLater(row) }
            }
            Divider()
            // The keyboard and VoiceOver way to reorder (dragging needs a pointer).
            Button("Move Up") { model.move(row, by: -1) }.disabled(!canMoveUp)
            Button("Move Down") { model.move(row, by: 1) }.disabled(!canMoveDown)
            Divider()
            Button("Delete", role: .destructive) { model.delete(row.id) }
        }
    }

    /// SPEC: reaching the count means the goal is reached. Congratulate, then offer
    /// a next round or a higher bar. (The Daruma's second eye comes in v1.3.)
    private var celebration: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("🎉 Goal reached. Well done!")
                .font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Button("Next round") { model.nextRound(row) }
                    .accessibilityLabel(Text("Start a next round of \(item.title)"))
                Button("Raise target…", action: onEdit)
                    .accessibilityLabel(Text("Raise the target of \(item.title)"))
                Button("Done") { model.dismissCelebration(row) }
                    .accessibilityLabel(Text("Close"))
            }
            .controlSize(.small)
        }
        .padding(.leading, 28)
    }

    /// Time is up (SPEC 2026-11-10): the row asks, it never ticks by itself.
    private var timeUp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Time's up.")
                .font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Button(item.kind == .goal ? "+1" : "Done") { model.finishFocus(row) }
                    .accessibilityLabel(item.kind == .goal ? Text("Add one to \(item.title) and stop") : Text("Mark \(item.title) done and stop"))
                Button("5 more min") { model.extendFocus() }
                    .accessibilityLabel(Text("Five more minutes on \(item.title)"))
                if model.focusOffersBreak {
                    Button("Break") { model.startBreak() }
                        .accessibilityLabel(Text("Take a five-minute break"))
                }
                Button("Stop") { model.stopFocus() }
                    .accessibilityLabel(Text("Stop the timer"))
            }
            .controlSize(.small)
        }
        .padding(.leading, 28)
    }

    /// The running timer's controls, right after the title: time left (☕ in a break),
    /// pause or resume, stop. A timer is started from right-click → Focus only, so
    /// nothing appears or moves on hover (user, 2026-11-10: a ▶ before the count sat
    /// in a different place on goal rows).
    @ViewBuilder
    private func timerControls(now: Date) -> some View {
        if let timer {
            HStack(spacing: 6) {
                Text(verbatim: (timer.phase == .rest ? "☕ " : "") + Self.clock(timer.remaining(at: now)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(timer.phase == .rest
                        ? Text("Break, \(Self.clock(timer.remaining(at: now))) left")
                        : Text("\(Self.clock(timer.remaining(at: now))) left on \(item.title)"))
                if timer.phase == .focus, !timer.isOver(at: now) {
                    Button { timer.isPaused ? model.resumeFocus() : model.pauseFocus() } label: {
                        Image(systemName: timer.isPaused ? "play.fill" : "pause.fill").imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(timer.isPaused ? Text("Resume the timer") : Text("Pause the timer"))
                }
                Button { model.stopFocus() } label: { Image(systemName: "stop.fill").imageScale(.small) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(timer.phase == .rest ? Text("End the break") : Text("Stop the timer"))
            }
        }
    }

    /// "12:34", or "1:02:03" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func mainLine(now: Date) -> some View {
        HStack(spacing: 8) {
            Button { model.tap(row) } label: {
                Image(systemName: row.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .frame(width: TaskColumns.circleWidth)
                    .foregroundStyle(row.isDone ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .disabled(row.isGoalReached)
            .accessibilityLabel(tapLabel)

            HStack(spacing: 8) {
                titleView
                // Kept whole; a long title truncates instead.
                timerControls(now: now)
                    .fixedSize()
                    .layoutPriority(1)

            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let target = item.progress.target {
                // Fixed widths, so every goal's bar starts in the same column.
                HStack(spacing: 4) {
                    // Hovering the bar and count shows the rating dots in their place;
                    // "−" stays put (SPEC §4: undo is always one click away).
                    // The bar itself is drawn in the chosen style (behind or under the
                    // title); this column keeps the count, with room for the dots.
                    ZStack(alignment: .trailing) {
                        Text(verbatim: "\(row.progressAmount)/\(target)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: Self.countWidth, alignment: .trailing)
                            .accessibilityLabel(Text("\(row.progressAmount) of \(target)"))
                            .opacity(showsDots ? 0 : 1)
                        if showsDots { dots }
                    }
                    .frame(minWidth: RatingDots.width, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onHover { hoveringDots = $0 }
                    // Undo is one click away (SPEC §4), and kept apart from the circle so
                    // rapid +1s cannot hit it by mistake. Its slot is kept so columns align.
                    Button { model.undo(row) } label: { Image(systemName: "minus").imageScale(.small) }
                        .buttonStyle(.borderless)
                        .frame(width: Self.undoWidth)
                        .opacity(row.todayAmount > 0 ? 1 : 0)
                        .disabled(row.todayAmount == 0)
                        .accessibilityHidden(row.todayAmount == 0)
                        .accessibilityLabel(Text("Remove one from \(item.title)"))
                }
            } else if canRate {
                // The right end of a ticked row: hover to rate or change the rating.
                ZStack(alignment: .trailing) {
                    Color.clear.frame(width: RatingDots.width, height: 14)
                    if showsDots { dots }
                }
                .contentShape(Rectangle())
                .onHover { hoveringDots = $0 }
            }
        }
    }

    /// Clicking the title (or anywhere in the row's free space) opens the details; the
    /// link mark is the button that opens the link (SPEC §3).
    private var titleView: some View {
        HStack(spacing: 4) {
            Text(item.title)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.rowSpace)).minX } action: { titleInset = $0 }
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(row.isDone ? .secondary : .primary)
                .accessibilityAddTraits(row.isDone ? .isSelected : [])
                .accessibilityValue(watchedValue)
                .accessibilityAction(named: Text("Details"), onOpen)
            if let url = item.url {
                Button { model.open(url) } label: {
                    Image(systemName: "link").imageScale(.small).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .modifier(LinkPointer())
                .help(url.absoluteString)
                .accessibilityLabel(Text("Open link for \(item.title)"))
            }
        }
    }

    /// "999/999" measures 41.7 pt in the caption font; larger counts widen only their
    /// own row.
    static let countWidth: CGFloat = 44
    static let undoWidth: CGFloat = 12

    /// "40 percent watched" for a started video, read with the title.
    private var watchedValue: Text {
        guard item.progress.target == nil, let watched = model.watched[row.id], watched > 0 else { return Text(verbatim: "") }
        return Text("\(Int((watched * 100).rounded())) percent watched")
    }

    private var tapLabel: Text {
        if row.isGoalReached { return Text("\(item.title), goal reached") }
        if item.kind == .goal { return Text("Add one to \(item.title)") }
        return row.isDone ? Text("Undo \(item.title)") : Text("Mark \(item.title) done")
    }
}

/// Progress drawn behind a row's title: the row's rounded background fills from the
/// left (Settings › General › Progress bars). `fraction` is 0–1; a timer can drive it
/// by changing it over time.
struct ProgressFill: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: geo.size.width * min(max(fraction, 0), 1))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityHidden(true)
    }
}

/// Progress drawn as a long bar under a row's title, almost to the row's end
/// (Settings › General › Progress bars), and as the bar on a video's details.
struct ProgressLine: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityHidden(true)
    }
}

/// The pointing-hand cursor over a link (macOS 15+; older systems keep the tooltip).
struct LinkPointer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content
        }
    }
}

struct NoticeView: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .transition(.opacity)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
    }
}

/// Each row's frame in the list, for working out where a dragged row is.
private struct RowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Five small dots: how a tick felt, 1 rough … 5 great. Optional; shown after a tick
/// and on hover. Only when Settings › Rating dots is on.
struct RatingDots: View {
    let rating: Int?
    let rate: (Int) -> Void

    static let dot: CGFloat = 9
    static let gap: CGFloat = 4
    /// Five dots with their click padding.
    static var width: CGFloat { 5 * (dot + 4) }

    static func word(_ n: Int) -> String {
        switch n {
        case 1: String(localized: "rough")
        case 2: String(localized: "meh")
        case 3: String(localized: "okay")
        case 4: String(localized: "good")
        default: String(localized: "great")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { n in
                Button { rate(n) } label: {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                        .background(Circle().fill(n <= (rating ?? 0) ? Color.accentColor : .clear))
                        .frame(width: Self.dot, height: Self.dot)
                        .padding(2) // the click target is a little larger than the dot
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: Self.word(n)))
                .accessibilityLabel(Text("Felt \(Self.word(n))"))
            }
        }
    }
}
