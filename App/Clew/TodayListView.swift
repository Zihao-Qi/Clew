import ClewCore
import ClewDomain
import SwiftUI

struct TodayListView: View {
    let model: AppModel
    @Binding var screen: Screen
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
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
    /// A long list scrolls by itself while a row is dragged near its edge (user,
    /// 2026-11-18): its scroll view, where it shows, the scroll when the drag began, the
    /// pointer's last place and the timer that scrolls.
    @State private var scroller = ListScroller()
    @State private var rowsViewport: CGRect = .zero
    @State private var dragScrollStart: CGFloat = 0
    @State private var lastPointerY: CGFloat = 0
    @State private var listScroll: Timer?
    private var listScrolls: Bool { (rowsHeightAtDrag ?? rowsHeight) > rowsLimit }
    /// How far the list has scrolled since the drag began: the frozen row frames are
    /// measured against the pointer moved by this much.
    private var scrolledSinceDrag: CGFloat { listScrolls ? scroller.offset - dragScrollStart : 0 }
    /// What is being dragged, drawn as one lifted card above the list and the timeline:
    /// a row over the list, a block over the hours (user, 2026-11-10: the same thing,
    /// moving smoothly between the two).
    @State private var lifted: Lifted?
    /// Where the dragged block was grabbed, below its top (points).
    @State private var blockGrab: CGFloat = 0
    /// The task under the pointer (a row or a block): the Delete key deletes it.
    @State private var hoveredItem: UUID?
    /// The step under the pointer, in an unfolded task: the Delete key deletes it.
    @State private var hoveredStep: UUID?
    /// The task whose Add Step… line is open (SPEC 2026-11-21). It lives with the list:
    /// leaving the list closes it.
    @State private var addingStep: UUID?
    /// Add Step…'s line opened by the row's "Suggest steps" VoiceOver action: it asks at once.
    @State private var suggestingStep: UUID?
    /// A click folds or unfolds at once; the double-click's second click puts the fold
    /// back the way it was before the first (SPEC 2026-11-21).
    @State private var foldClicks = FoldClicks()
    /// One task row's height, steps left out: a block coming down from the timeline
    /// becomes one row, whatever the first task holds.
    @State private var rowHeight: CGFloat = 34
    /// Each task's own row height, its steps left out: a dragged task is this tall while
    /// its steps fold (user, 2026-11-22).
    @State private var ownHeights: [UUID: CGFloat] = [:]
    /// The rows' height when a drag began: folding the dragged task's steps never switches
    /// the list between scrolling and not mid-drag, which would cancel the drag (review).
    @State private var rowsHeightAtDrag: CGFloat?
    /// The timeline's name box (SPEC 2026-11-13). It lives with the list: leaving the list
    /// (Add, Later, Settings, details) drops it.
    @State private var newTask: NewTaskDraft?
    /// Cleared by itself when a row drag ends or is cancelled.
    @GestureState private var rowDragLive = false

    private static let listSpace = "todayList"

    private var showsTimeline: Bool { model.timelineShown && model.timeline != nil }

    /// The rows may take what the screen has left after last week's card, the timeline
    /// and the footer.
    #if DEBUG
    /// The debug checks fix the screen's height, so a small CI display never makes the
    /// list scroll rows out of view (2026-11-23).
    static var screenHeightForChecks: CGFloat?
    #endif

    private var rowsLimit: CGFloat {
        var screen = NSScreen.main?.visibleFrame.height ?? 800
        #if DEBUG
        if let fixed = Self.screenHeightForChecks { screen = fixed }
        #endif
        let card = model.showsWeekCard ? weekCardHeight : 0
        // What next?'s panel takes room above the bar while it shows (review).
        let panel = whatNext.isOpen ? nextPanelHeight : 0
        return max(160, screen - card - panel - (showsTimeline ? TimelineMetrics.height : 0) - 170)
    }

    /// Last week's card's height, for `rowsLimit`.
    @State private var weekCardHeight: CGFloat = 0
    /// What next? (SPEC "What next?"): its panel above the bottom bar.
    private var whatNext: WhatNextAsk { model.whatNext }
    @State private var nextPanelHeight: CGFloat = 0
    @AccessibilityFocusState private var voiceOverRow: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Above the list's top, the pointer is over the hours.
    private func isOverTimeline(_ y: CGFloat) -> Bool { showsTimeline && y < timelineGeo.viewport.maxY + 4 }

    /// Where a block at `start` lasting `minutes` sits, in the list's coordinate space.
    private func blockFrame(start: Date, minutes: Int) -> CGRect {
        guard let day = model.timeline else { return .zero }
        let view = timelineGeo.viewport
        let labelWidth = TimelineMetrics.labelWidth(for: day, locale: locale)
        return CGRect(x: view.minX + labelWidth,
                      y: timelineGeo.contentTop + TimelineMetrics.y(start, in: day),
                      width: max(20, view.width - labelWidth - TimelineMetrics.trailing),
                      height: CGFloat(minutes) * TimelineMetrics.pointsPerMinute)
    }

    /// A row's place and size for a card over the list: like the first row, at `y`.
    private func rowFrame(centeredAt y: CGFloat) -> CGRect {
        let sample = dragFrames.first ?? rowFrames.values.first ?? CGRect(x: 0, y: 0, width: 340, height: 34)
        // A task's own row: an unfolded first task's frame holds its steps too (review).
        return CGRect(x: sample.minX, y: y - rowHeight / 2, width: sample.width, height: rowHeight)
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

    private func offset(for id: UUID, at index: Int, in ids: [UUID]) -> CGFloat {
        // A block coming down from the timeline opens a gap where it would land.
        if let lifted, lifted.blockId != nil, let slot = lifted.slot {
            let height = Double(rowHeight)
            return CGFloat(Clew.insertShift(index: index, slot: slot, height: height))
        }
        guard let dragging, let from = ids.firstIndex(of: dragging) else { return 0 }
        if id == dragging { return dragTranslation }
        let height = Double(dragFrames.indices.contains(from) ? dragFrames[from].height : 0)
        return CGFloat(Clew.dragShift(index: index, from: from, to: dragSlot ?? from, draggedHeight: height))
    }

    /// Near the long list's top or bottom edge while dragging, it scrolls by itself.
    private func listEdgeScroll(_ y: CGFloat?) {
        lastPointerY = y ?? lastPointerY
        let step = y.map { ListAutoScroll.step(pointerY: Double($0), viewport: (Double(rowsViewport.minY), Double(rowsViewport.maxY))) } ?? 0
        guard listScrolls, step != 0 else {
            listScroll?.invalidate()
            listScroll = nil
            return
        }
        guard listScroll == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            Task { @MainActor in autoScrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        listScroll = timer
    }

    private func autoScrollTick() {
        let step = ListAutoScroll.step(pointerY: Double(lastPointerY),
                                       viewport: (Double(rowsViewport.minY), Double(rowsViewport.maxY)))
        // Only over the list (a tick already queued when the pointer went up onto the
        // timeline does nothing; review).
        let overList = lifted?.overTimeline != true
        let draggingRow = dragging != nil && overList
        let draggingBlock = lifted?.blockId != nil && overList
        guard listScroll != nil, listScrolls, step != 0, draggingRow || draggingBlock else { return listEdgeScroll(nil) }
        let next = CGFloat(ListAutoScroll.clamp(Double(scroller.offset) + step, maxOffset: Double(scroller.maxOffset)))
        // At the list's end it stops (review: it kept ticking); moving the pointer starts it again.
        guard next != scroller.offset else { return listEdgeScroll(nil) }
        scroller.offset = next
        // The rows moved under a pointer that did not: the gap follows.
        let spans = dragFrames.map { (minY: Double($0.minY), maxY: Double($0.maxY)) }
        let y = Double(lastPointerY + scrolledSinceDrag)
        if draggingRow {
            let slot = Clew.dragSlot(pointerY: y, spans: spans)
            if slot != dragSlot { withAnimation(.easeOut(duration: 0.15)) { dragSlot = slot } }
        } else if let lifted {
            let slot = Clew.insertSlot(pointerY: y, spans: spans)
            if lifted.slot != slot { withAnimation(.easeOut(duration: 0.15)) { self.lifted?.slot = slot } }
        }
    }

    private func endDrag() {
        let draggedId = dragging
        listEdgeScroll(nil)
        scrollAtEdge(nil)
        lifted = nil
        dragging = nil
        dragTranslation = 0
        dragSlot = nil
        // The folded steps come back: the rows are as tall as before the drag, so the list
        // never flips out of scrolling for a frame (review). An Add Step line that closed
        // stays closed, and the next measure corrects the height.
        if let id = draggedId, let saved = rowsHeightAtDrag, sequence.contains(id), model.steps(of: id) != nil, model.isUnfolded(id) {
            rowsHeight = saved
        }
        rowsHeightAtDrag = nil
    }

    // MARK: Dragging a row

    /// Today's visible rows, the "Goals & Later" label and its rows, as one sequence a
    /// row is dragged through (SPEC 2026-11-15).
    private func drag(_ row: TodayRow, in ids: [UUID]) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.listSpace))
            .updating($rowDragLive) { _, live, _ in live = true }
            .onChanged { value in
                if dragging == nil {
                    var frames = ids.map { rowFrames[$0] ?? .zero }
                    // A dragged task's steps (and an open Add Step line) fold while it moves
                    // (user, 2026-11-22): it is as tall as its own row, the rows below close up.
                    let showsSteps = (model.steps(of: row.id) != nil && model.isUnfolded(row.id)) || addingStep == row.id
                    if showsSteps, let from = ids.firstIndex(of: row.id), let own = ownHeights[row.id],
                       frames[from].height > own + 1 {
                        let cut = frames[from].height - own
                        frames[from].size.height = own
                        for k in frames.indices where k > from { frames[k].origin.y -= cut }
                    }
                    if addingStep == row.id { addingStep = nil; suggestingStep = nil }
                    rowsHeightAtDrag = rowsHeight
                    dragFrames = frames
                    dragScrollStart = scroller.offset
                    dragging = row.id
                }
                let from = ids.firstIndex(of: row.id) ?? 0
                let own = dragFrames.indices.contains(from) ? dragFrames[from] : rowFrame(centeredAt: value.location.y)
                // Up over the hours: the card becomes the block it would be, at the
                // quarter hour under the pointer; the other rows stay where they are.
                if isOverTimeline(value.location.y), let day = model.timeline {
                    let start = TimelineMetrics.start(atContentY: value.location.y - timelineGeo.contentTop, in: day)
                    let open = day.blocks.first { $0.block.itemId == row.id && $0.block.stepId == nil
                                                  && $0.block.end > Date() }?.block.minutes
                    let minutes = min(open ?? Clew.blockDefaultMinutes, TimelineMetrics.room(after: start, in: day))
                    lifted = Lifted(itemId: row.id, blockId: nil, title: row.item.title, overTimeline: true,
                                    frame: blockFrame(start: start, minutes: minutes), start: start, minutes: minutes)
                    dragTranslation = value.translation.height
                    if dragSlot != nil { withAnimation(.easeOut(duration: 0.15)) { dragSlot = nil } }
                    scrollAtEdge(value.location.y)
                    listEdgeScroll(nil)
                    return
                }
                scrollAtEdge(nil)
                listEdgeScroll(value.location.y)
                let scrolled = scrolledSinceDrag
                // Kept inside the rows: never over the footer (Add, Later, Settings), and
                // in a long list inside the part that shows.
                if let first = dragFrames.first, let last = dragFrames.last {
                    var top = Double(first.minY - scrolled), bottom = Double(last.maxY - scrolled)
                    if listScrolls { top = max(top, Double(rowsViewport.minY)); bottom = min(bottom, Double(rowsViewport.maxY)) }
                    dragTranslation = CGFloat(Clew.clampDrag(
                        translation: Double(value.translation.height),
                        row: (minY: Double(own.minY), maxY: Double(own.maxY)),
                        list: (minY: top, maxY: bottom)))
                } else {
                    dragTranslation = value.translation.height
                }
                lifted = Lifted(itemId: row.id, blockId: nil, title: row.item.title, overTimeline: false,
                                frame: own.offsetBy(dx: 0, dy: dragTranslation))
                let spans = dragFrames.map { (minY: Double($0.minY), maxY: Double($0.maxY)) }
                let slot = Clew.dragSlot(pointerY: Double(value.location.y + scrolled), spans: spans)
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
                    } else if let from = ids.firstIndex(of: row.id), let to = dragSlot, to != from {
                        model.drop(row.id, in: ids.map { $0 == Self.labelID ? nil : $0 }, from: from, to: to)
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
            dragFrames = sequence.map { rowFrames[$0] ?? .zero }
            dragScrollStart = scroller.offset
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
                            frame: blockFrame(start: start, minutes: b.minutes), start: start, minutes: b.minutes,
                            stepId: b.stepId)
            scrollAtEdge(value.location.y)
            listEdgeScroll(nil)
        } else if b.stepId != nil {
            // A step's block over the list goes back to its task wherever it is dropped:
            // no gap opens (SPEC 2026-11-21).
            lifted = Lifted(itemId: b.itemId, blockId: b.id, title: block.title, overTimeline: false,
                            frame: rowFrame(centeredAt: value.location.y), minutes: b.minutes, stepId: b.stepId)
            scrollAtEdge(nil)
            listEdgeScroll(nil)
        } else {
            // Down over the list: a row, with the rows opening the gap it would take.
            listEdgeScroll(value.location.y)
            let spans = dragFrames.map { (minY: Double($0.minY), maxY: Double($0.maxY)) }
            let slot = Clew.insertSlot(pointerY: Double(value.location.y + scrolledSinceDrag), spans: spans)
            // The card stays over the part of a long list that shows (review: it could
            // be drawn over the footer).
            var cardY = value.location.y
            if listScrolls { cardY = min(max(cardY, rowsViewport.minY + 17), rowsViewport.maxY - 17) }
            if lifted?.slot != slot {
                withAnimation(.easeOut(duration: 0.15)) {
                    lifted = Lifted(itemId: b.itemId, blockId: b.id, title: block.title, overTimeline: false,
                                    frame: rowFrame(centeredAt: cardY), slot: slot)
                }
            } else {
                lifted?.overTimeline = false
                lifted?.frame = rowFrame(centeredAt: cardY)
            }
            scrollAtEdge(nil)
        }
    }

    private func blockDropped(_ block: TimelineBlock) {
        let landing = lifted
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if let landing, !landing.overTimeline, block.block.stepId != nil {
                model.removeBlock(block.block.id)              // back under its task
            } else if let landing, !landing.overTimeline {
                let slot = landing.slot ?? 0
                if let label = sequence.firstIndex(of: Self.labelID), slot > label {
                    // Dropped in Goals & Later (SPEC 2026-11-15).
                    model.putBackBelow(block.block.id, itemId: block.block.itemId, at: slot - label - 1)
                } else {
                    model.putBack(block.block.id, itemId: block.block.itemId, at: slot)
                }
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
        if let lifted, lifted.stepId != nil {
            LiftedBlockCard(title: lifted.title, start: lifted.overTimeline ? lifted.start : nil, minutes: lifted.minutes)
                .frame(width: lifted.frame.width, height: lifted.frame.height)
                .clipped()
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .position(x: lifted.frame.midX, y: lifted.frame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else if let lifted, let row = model.row(lifted.itemId) {
            ZStack(alignment: .topLeading) {
                // Only the task's own row: its steps go with it, but are not drawn on the
                // card (user, 2026-11-22).
                RowView(row: row, model: model, onEdit: {}, onOpen: {}, isDragged: true,
                        steps: model.steps(of: row.id), unfolded: false)
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

    /// A click on a row: a task with steps unfolds or folds, at once (SPEC 2026-11-21).
    private func clicked(_ row: TodayRow) {
        guard model.steps(of: row.id) != nil else { return }
        let next = foldClicks.click(row.id, unfolded: model.isUnfolded(row.id), at: Date(),
                                    interval: NSEvent.doubleClickInterval)
        withAnimation(.easeOut(duration: 0.15)) { model.setUnfolded(row.id, next) }
    }

    /// A double-click opens the details and leaves the task folded or unfolded as it was.
    private func doubleClicked(_ row: TodayRow) {
        if let back = foldClicks.doubleClick(row.id, at: Date(), interval: NSEvent.doubleClickInterval) {
            model.setUnfolded(row.id, back)
        }
        screen = .detail(row.id)
    }

    /// A step dragged in the list (SPEC 2026-11-21): over the hours the card is the block it
    /// would be, at the quarter hour under the pointer. Nil: the drag is over.
    private func stepDragged(_ entry: TaskSteps.Entry, of row: TodayRow, at point: CGPoint?) -> Bool {
        guard let point else {
            if lifted?.stepId == entry.id { lifted = nil }
            scrollAtEdge(nil)
            return false
        }
        guard isOverTimeline(point.y), let day = model.timeline else {
            if lifted?.stepId == entry.id { lifted = nil }
            scrollAtEdge(nil)
            return false
        }
        let start = TimelineMetrics.start(atContentY: point.y - timelineGeo.contentTop, in: day)
        let open = day.blocks.first { $0.block.stepId == entry.id && $0.block.end > Date() }?.block.minutes
        let minutes = min(open ?? Clew.blockDefaultMinutes, TimelineMetrics.room(after: start, in: day))
        lifted = Lifted(itemId: row.id, blockId: nil, title: "\(row.item.title) - \(entry.step.title)",
                        overTimeline: true, frame: blockFrame(start: start, minutes: minutes), start: start,
                        minutes: minutes, stepId: entry.id)
        scrollAtEdge(point.y)
        return true
    }

    /// Dropped over the hours: the step goes there.
    private func stepDropped(_ entry: TaskSteps.Entry) -> Bool {
        guard let landing = lifted, landing.stepId == entry.id, landing.blockId == nil, landing.overTimeline,
              let start = landing.start else { return false }
        lifted = nil
        scrollAtEdge(nil)
        return model.placeStep(entry.id, at: start, minutes: landing.minutes)
    }

    /// Add Step…: unfold the task with an empty step line after its steps.
    private func startAddingStep(_ row: TodayRow) {
        startAddingStep(row.id)
    }

    private func startAddingStep(_ id: UUID, suggest: Bool = false) {
        guard let row = model.row(id) else { return }
        model.setUnfolded(row.id, true)
        suggestingStep = suggest ? row.id : nil
        // Already open: reopen it, so the new line asks.
        if suggest, addingStep == row.id { addingStep = nil; DispatchQueue.main.async { addingStep = row.id } } else {
            addingStep = row.id
        }
    }

    /// One row of either list; Move Up / Move Down stop at its own list's ends. An
    /// unfolded task's steps are listed under it, inside its row, so they move with it.
    private func listRow(_ row: TodayRow, index: Int, count: Int, ids: [UUID]) -> some View {
        let steps = model.steps(of: row.id)
        let adding = addingStep == row.id
        return VStack(alignment: .leading, spacing: 0) {
            RowView(row: row, model: model, onEdit: { screen = .edit(row.item, back: .list) },
                    onOpen: { screen = .detail(row.id) },
                    canMoveUp: index > 0 && model.canMove(row, by: -1), canMoveDown: index < count - 1 && model.canMove(row, by: 1),
                    isDragged: dragging == row.id,
                    dragActive: dragging != nil || lifted != nil,
                    onHoverChange: { inside in
                        if inside { hoveredItem = row.id } else if hoveredItem == row.id { hoveredItem = nil }
                    },
                    steps: steps,
                    unfolded: model.isUnfolded(row.id),
                    onClick: { clicked(row) },
                    onDoubleClick: { doubleClicked(row) },
                    onAddStep: { startAddingStep(row) })
                .accessibilityActions {
                    if model.canSuggestSteps(row.id) {
                        Button("Suggest steps") { startAddingStep(row.id, suggest: true) }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    if steps == nil { rowHeight = $0 }
                    ownHeights[row.id] = $0
                }
                // What next?'s pick, shown for about a second (SPEC "What next?").
                .background(model.highlightedRow == row.id ? Color.accentColor.opacity(0.18) : .clear)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: model.highlightedRow == row.id)
                .accessibilityFocused($voiceOverRow, equals: row.id)
            if ((steps != nil && model.isUnfolded(row.id)) || adding) && dragging != row.id {
                StepsList(model: model, row: row, steps: steps ?? TaskSteps(taskId: row.id, entries: []),
                          adding: adding, suggestOnOpen: suggestingStep == row.id,
                          onAddClose: { if addingStep == row.id { addingStep = nil; suggestingStep = nil } },
                          onOpen: { screen = .detail(row.id) }, hoveredStep: $hoveredStep,
                          listSpace: Self.listSpace,
                          onTimelineDrag: { entry, point in stepDragged(entry, of: row, at: point) },
                          onTimelineDrop: { entry in stepDropped(entry) })
                    .padding(.bottom, 2)
            }
        }
            .background(GeometryReader { g in
                Color.clear.preference(key: RowFrames.self,
                                       value: [row.id: g.frame(in: .named(Self.listSpace))])
            })
            .offset(y: offset(for: row.id, at: ids.firstIndex(of: row.id) ?? 0, in: ids))
            // The lifted card draws the dragged row, here or over the hours.
            .opacity(dragging == row.id ? 0 : 1)
            // While a step is renamed in place, its edit line keeps the pointer (review).
            .gesture(drag(row, in: ids), including: model.renamingStep == nil ? .all : .subviews)
    }

    /// Where a row's circle starts: the "Goals & Later" label lines up with it.
    static let circleLeading: CGFloat = 14

    /// The id standing for the "Goals & Later" label in the dragged sequence.
    static let labelID = UUID(uuidString: "60A15A4D-1A7E-4000-8000-000000000000")!

    /// Today's visible rows, then (when it has any) the label and Goals & Later's rows.
    private var sequence: [UUID] {
        let below = model.goalsAndLater
        return model.listRows.map(\.id) + (below.isEmpty ? [] : [Self.labelID] + below.map(\.id))
    }

    /// One entry of the rows: a row of either list, or the "Goals & Later" label.
    private enum ListEntry: Identifiable {
        case row(TodayRow, index: Int, count: Int)
        case label
        var id: UUID {
            switch self {
            case .row(let row, _, _): row.id
            case .label: TodayListView.labelID
            }
        }
    }

    /// A divider, then a quiet section label lined up with the circles (SPEC 2026-11-15;
    /// *changed* after use: a line above it, label at the left).
    private func goalsAndLaterLabel(todayIsEmpty: Bool, at index: Int, ids: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !todayIsEmpty {
                Divider().padding(.horizontal, 12).padding(.top, 6).accessibilityHidden(true)
            }
            Text("Goals & Later")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, Self.circleLeading)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear.preference(key: RowFrames.self,
                                   value: [Self.labelID: g.frame(in: .named(Self.listSpace))])
        })
        .offset(y: offset(for: Self.labelID, at: index, in: ids))
    }

    /// What next?'s pick: scroll its row into view (or, with no row, its block on the
    /// timeline) and move VoiceOver there (SPEC "What next?").
    private func reveal() {
        guard let itemId = model.revealing else { return }
        if model.listRows.contains(where: { $0.id == itemId }) {
            if listScrolls, let frame = rowFrames[itemId],
               frame.minY < rowsViewport.minY || frame.maxY > rowsViewport.maxY {
                let target = scroller.offset + frame.minY - rowsViewport.minY - 8
                scroller.offset = min(max(target, 0), scroller.maxOffset)
            }
            voiceOverRow = itemId
        } else if let day = model.timeline, let id = model.revealedBlock,
                  let block = day.blocks.first(where: { $0.id == id }) {
            let visible = Int(TimelineMetrics.height) / TimelineMetrics.quarter
            let quarter = Int(block.block.start.timeIntervalSince(day.start) / 60) / TimelineMetrics.quarter
            topQuarter = min(max(quarter - 1, 0), max(TimelineMetrics.quarters(day) - visible, 0))
        }
    }

    @ViewBuilder
    private func rowsStack() -> some View {
        let today = model.listRows
        let below = model.goalsAndLater
        let ids = sequence
        // One ForEach for both lists and the label, so a row moving between them slides
        // to its new place (user, 2026-11-18) instead of vanishing and reappearing.
        let entries: [ListEntry] = today.enumerated().map { .row($1, index: $0, count: today.count) }
            + (below.isEmpty ? [] : [.label]
               + below.enumerated().map { .row($1, index: $0, count: below.count) })
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                switch entry {
                case .row(let row, let index, let count):
                    listRow(row, index: index, count: count, ids: ids)
                case .label:
                    goalsAndLaterLabel(todayIsEmpty: today.isEmpty, at: today.count, ids: ids)
                }
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
        return rowHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Last week's card (SPEC 2026-11-15): the very top, above the timeline.
            if model.showsWeekCard {
                WeekCardView(recap: model.weekCard, noticed: model.noticedShown,
                             answer: { model.answerNoticed($0, true: $1) }) { model.dropWeekCard() }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { weekCardHeight = $0 }
            }
            if showsTimeline, let day = model.timeline {
                DayTimelineView(model: model, day: day, space: Self.listSpace,
                                geometry: $timelineGeo, topQuarter: $topQuarter,
                                liftedBlock: lifted?.blockId, hovered: $hoveredItem, newTask: $newTask,
                                onDrag: blockDrag, onDrop: blockDropped,
                                onMove: { block in screen = .place(block.block.itemId, block: block.id) },
                                onOpen: { screen = .detail($0) },
                                onEdit: { item in screen = .edit(item, back: .list) },
                                onOpenEvent: { screen = .event($0) })
            }
            ForEach(model.lateTicks) { late in
                LateTickLine(late: late, today: model.today?.day, model: model)
            }
            // "All done for today" only when everything counted is done; otherwise the
            // empty states as before (SPEC 2026-11-15).
            if model.today?.allDone == true {
                Text("All done for today")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
                    .padding(.bottom, model.listRows.isEmpty ? 4 : 0)
            } else if model.listRows.isEmpty {
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
                .padding(.vertical, model.goalsAndLater.isEmpty ? 20 : 10)
            }
            if !sequence.isEmpty {
                Group {
                    if listScrolls {
                        // Long lists scroll together rather than pushing the menu past the
                        // screen (SPEC 2026-11-15: Today and Goals & Later).
                        ScrollView(.vertical) {
                            rowsStack().background(ScrollViewFinder(scroller: scroller))
                        }
                        .frame(height: rowsLimit)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.listSpace)) } action: {
                            rowsViewport = $0
                        }
                    } else {
                        rowsStack()
                    }
                }
                .onPreferenceChange(RowFrames.self) { rowFrames = $0 }
            }

            // Imported lists, below the tasks with no heading (SPEC 2026-11-09), then the
            // Notes row in their style (SPEC "Notes", 2026-11-23).
            if !model.collections.isEmpty || !model.openNotes.isEmpty {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach(model.collections) { summary in
                        CollectionRowView(summary: summary) { screen = .collection(summary.source) }
                    }
                    if !model.openNotes.isEmpty {
                        NotesRowView(count: model.openNotes.count) { screen = .notes }
                    }
                }
                .padding(.vertical, 6)
            }

            NoticeView(text: model.notice)
                .animation(.easeOut(duration: 0.4), value: model.notice)
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
            if let last = model.lastEventChange {
                // An event changed in Calendar can be put back for a few seconds (SPEC 2026-11-19).
                let title = last.change.event.title
                HStack(spacing: 8) {
                    Group {
                        if last.change.kind == .moved { Text("Moved “\(title)”") } else { Text("Changed “\(title)”") }
                    }
                    .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Undo") { model.undoEventChange() }
                        .accessibilityLabel(Text("Undo the change to \(title)"))
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

            // What next?'s panel, just above the bottom bar: the menu grows to fit it, so it
            // covers nothing and no row moves (SPEC "What next?").
            if whatNext.isOpen {
                WhatNextPanel(ask: whatNext, model: model)
                    .padding(.bottom, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nextPanelHeight = $0 }
            }

            Divider()

            // Each icon close to its word, the two buttons further apart (user, 2026-11-23).
            HStack(spacing: 22) {
                Button { screen = .add } label: { BarLabel(title: Text("Add"), icon: "plus") }
                    .keyboardShortcut("n")
                    .accessibilityLabel(Text("Add an item"))
                // Writes a note (SPEC "Notes"): the menu closes first, then the note box.
                Button {
                    MenuBarExtraToggle.closeMenu()
                    DispatchQueue.main.async { NoteBox.shared.open() }
                } label: { BarLabel(title: Text("Note"), icon: "square.and.pencil") }
                    .help(Text("Write a note"))
                    .accessibilityLabel(Text("Write a note"))
                    .debugFrame("noteButton")
                // What next? (SPEC "What next?"): last in the group, so it moves nothing.
                // While its panel shows it stays to close it, but not once AI is gone.
                if model.canAskWhatNext || (whatNext.isOpen && model.ai?.isReady == true) {
                    Button { whatNext.toggle(model) } label: { BarLabel(title: Text("Next"), icon: "signpost.right") }
                        .help(Text("What next?"))
                        .accessibilityLabel(Text("What next?"))
                        .debugFrame("whatNextButton")
                }
                Spacer()
                // No "Later (N)" button or ⌘L: Later items are in Goals & Later (SPEC
                // 2026-11-15).
                // One click straight to Settings; Quit lives there. The menu closes first,
                // like any menu item that opens a window; with a newer version known, the
                // dot shows and Settings opens at About (SPEC 2026-11-13).
                Button {
                    if model.updates.showsDot { model.updates.paneRequest = .about }
                    MenuBarExtraToggle.closeMenu()
                    openWindow(id: SettingsView.windowID)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                        .overlay(alignment: .topTrailing) {
                            if model.updates.showsDot {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 3, y: -2)
                            }
                        }
                }
                .keyboardShortcut(",")
                .help(Text("Settings"))
                .accessibilityLabel(model.updates.showsDot ? Text("Settings, update available") : Text("Settings"))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background { WhatNextHooks(ask: whatNext, model: model, screen: screen, reveal: reveal) }
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
                if let id = hoveredStep, let entry = model.steps.values.lazy.flatMap(\.entries).first(where: { $0.id == id }) {
                    hoveredStep = nil
                    model.deleteStep(entry.step)
                } else if let id = hoveredItem, let entry = model.stepEntry(id) {
                    hoveredItem = nil                          // a step's block
                    model.deleteStep(entry.step)
                } else if let id = hoveredItem {
                    hoveredItem = nil
                    model.delete(id)
                }
            }
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                // While the name box is open, the keyboard edits the name.
                .disabled((hoveredItem == nil && hoveredStep == nil) || dragging != nil || lifted != nil || newTask != nil
                          || addingStep != nil || model.renamingStep != nil)
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
        .onChange(of: model.openNotes.count) { _, count in PeekController.shared.notesChanged(count) }
        .onChange(of: model.notesPageRequest) { screen = .notes }
        .onAppear {
            #if DEBUG
            DebugFrames.addStep = { startAddingStep($0) }
            DebugFrames.hoverStep = { hoveredStep = $0 }
            #endif
        }
        // The rollover closes Add Step…'s line (SPEC 2026-11-21).
        .onChange(of: model.today?.day) { addingStep = nil; model.renamingStep = nil }
        .onDisappear {
            // Leaving the list mid-drag (⌘N, ⌘,) ends the drag and its timers (review).
            endDrag()
            PeekController.shared.listLeft()
            // Leaving the list ends last week's card for this week.
            model.dropWeekCard()
            model.renamingStep = nil
        }
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
    /// A step dragged from the list, or a step's block (SPEC 2026-11-21): drawn as a block
    /// card everywhere, and it opens no gap in the list.
    var stepId: UUID? = nil
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
    /// Move Up / Move Down (VoiceOver actions) stop at the row's own list's ends.
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
    /// The task's steps (SPEC 2026-11-21), nil when it has none.
    var steps: TaskSteps? = nil
    var unfolded = false
    /// A click (a task with steps folds or unfolds) and a double-click (the details).
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onAddStep: () -> Void = {}

    /// A task with steps that is not done shows them as a goal shows its count.
    private var openSteps: TaskSteps? { row.isDone ? nil : steps }

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
        if let openSteps { return openSteps.fraction }
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
                        // Only on rows a click does something to (SPEC 2026-11-21).
                        .fill(Color.primary.opacity(hovering && !dragActive && steps != nil ? 0.06 : 0))
                }
            }
            .padding(.horizontal, 6)
        }
        // A little clear space between rows, so two filled rows don't run together.
        .padding(.vertical, 2)
        // The whole row, margins included: a click folds or unfolds a task with steps and a
        // double-click opens the details (SPEC 2026-11-21); the circle, link mark, − and
        // celebration buttons are buttons and keep their own clicks. The click is not held
        // back to wait for a second one.
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onDoubleClick)
        .simultaneousGesture(TapGesture().onEnded(onClick))
        .onHover { hovering = $0; onHoverChange?($0) }
        .accessibilityActions {
            // Offered only where they move the row (review: no silent no-ops at an end).
            if canMoveUp { Button("Move Up") { model.move(row, by: -1) } }
            if canMoveDown { Button("Move Down") { model.move(row, by: 1) } }
        }
        .accessibilityActions {
            // Nothing needs a drag (SPEC 2026-11-15); a day and a time are set in Edit.
            if model.isBelow(row) {
                if !row.isGoalReached { Button("Move to Today") { model.moveToToday(row) } }
            } else if model.isMoved(row) {
                Button("Move to Goals & Later") { model.moveBack(row) }
            } else if (item.kind == .once || item.kind == .link), row.progressAmount == 0 {
                Button("Move to Later") { model.moveToLater(row) }
            }
        }
        .accessibilityActions {
            if steps != nil {
                if unfolded { Button("Fold", action: onClick) } else { Button("Unfold", action: onClick) }
            }
            if model.canAddStep(row) { Button("Add Step…", action: onAddStep) }
        }
        // Kept short (user, 2026-11-18): a time on the timeline and a day for Later are
        // set in Edit; Move Up / Move Down stay for VoiceOver above.
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
            if model.canAddStep(row) { Button("Add Step…", action: onAddStep) }
            // Rows on Today only (SPEC 2026-11-19).
            if !model.isBelow(row) {
                Toggle("Priority", isOn: Binding(get: { item.priority }, set: { model.setPriority(row, $0) }))
            }
            if timer == nil, model.focus?.phase != .focus, !row.isGoalReached {
                Menu("Focus") {
                    ForEach(Clew.focusMinutes, id: \.self) { m in
                        Button("\(m) min") { model.startFocus(row, minutes: m) }
                    }
                }
            }
            // Between the two lists (SPEC 2026-11-15).
            if model.isBelow(row) {
                if !row.isGoalReached { Button("Move to Today") { model.moveToToday(row) } }
            } else if model.isMoved(row) {
                Button("Move to Goals & Later") { model.moveBack(row) }
            } else if (item.kind == .once || item.kind == .link), row.progressAmount == 0 {
                Button("Move to Later") { model.moveToLater(row) }
            }
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
                    // A priority's circle and ✓ are gold (SPEC 2026-11-19).
                    .foregroundStyle(model.showsPriority(row) ? PriorityGold.color
                                     : row.isDone ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .disabled(row.isGoalReached)
            .accessibilityLabel(tapLabel)
            .debugFrame("circle:\(row.id)")

            HStack(spacing: 8) {
                titleView
                // Kept whole; a long title truncates instead.
                timerControls(now: now)
                    .fixedSize()
                    .layoutPriority(1)

            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // At the row's end, lined up with the goals' counts (user, 2026-11-18).
            if let waitingText {
                Text(verbatim: waitingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    // Lined up with goals' counts; beside a task's own count, just a gap (review).
                    .padding(.trailing, openSteps == nil ? Self.undoWidth + 4 : 0)
                    .accessibilityLabel(Text("Comes to Today \(waitingText)"))
            }

            if let openSteps {
                // "1/3" where a goal's count is (SPEC 2026-11-21), the same columns.
                HStack(spacing: 4) {
                    Text(verbatim: "\(openSteps.done)/\(openSteps.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: Self.countWidth, alignment: .trailing)
                        .frame(minWidth: RatingDots.width, alignment: .trailing)
                        .accessibilityHidden(true)
                    Color.clear.frame(width: Self.undoWidth, height: 1)
                }
            } else if let target = item.progress.target {
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
                    Button { model.undo(row) } label: {
                        Image(systemName: "minus").imageScale(.small)
                            .frame(width: Self.undoWidth)
                            // Its click area reaches the row's end and the row's height
                            // (user, 2026-11-19: a near miss opened the details instead);
                            // the layout keeps the small mark's width.
                            .padding(.leading, Self.undoReach.leading)
                            .padding(.trailing, Self.undoReach.trailing)
                            .padding(.vertical, Self.undoReach.vertical)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.borderless)
                        .padding(.leading, -Self.undoReach.leading)
                        .padding(.trailing, -Self.undoReach.trailing)
                        .padding(.vertical, -Self.undoReach.vertical)
                        .opacity(row.todayAmount > 0 ? 1 : 0)
                        .disabled(row.todayAmount == 0)
                        // Hidden: clicks there open the details, as anywhere in the row.
                        .allowsHitTesting(row.todayAmount > 0)
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
                .accessibilityValue(rowValue)
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
            if steps != nil {
                // A task with steps: pointing right when folded, down when unfolded.
                Image(systemName: unfolded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                    .accessibilityHidden(true)
            }
            // A saved link's site in Goals & Later, as Pick showed it (SPEC 2026-11-15).
            if model.isBelow(row), let text = item.siteLabel {
                Text(verbatim: text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
    }

    /// The day a waiting Goals & Later row comes to Today (SPEC 2026-11-17).
    private var waitingText: String? {
        guard model.isBelow(row) else { return nil }
        return model.waitingDay(row).flatMap { d in model.currentDay.map { dayLabel(d, today: $0) } }
    }

    /// "999/999" measures 41.7 pt in the caption font; larger counts widen only their
    /// own row.
    static let countWidth: CGFloat = 44
    static let undoWidth: CGFloat = 12
    /// How far −'s click area reaches past the mark: to the dots' column on the left
    /// (4 pt), the row's end on the right (its 12 pt margin), and up and down to within
    /// about 2 pt of a one-line row's edges.
    static let undoReach = (leading: CGFloat(4), trailing: CGFloat(12), vertical: CGFloat(12))

    /// "Priority" (SPEC 2026-11-19) and how much was watched, read with the title.
    private var rowValue: Text {
        if let steps {
            let fold = unfolded ? Text("unfolded") : Text("folded")
            let count = Text("\(steps.done) of \(steps.total) steps")
            let base = model.showsPriority(row) ? Text("Priority") + Text(verbatim: ", ") + count : count
            return base + Text(verbatim: ", ") + fold
        }
        let watched = item.progress.target == nil && (model.watched[row.id] ?? 0) > 0
        switch (model.showsPriority(row), watched) {
        case (true, true): return Text("Priority") + Text(verbatim: ", ") + watchedValue
        case (true, false): return Text("Priority")
        default: return watchedValue
        }
    }

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

/// What next?'s close paths and the reveal (SPEC "What next?"): the list changing, the
/// menu closing, the rollover, leaving the list.
private struct WhatNextHooks: View {
    let ask: WhatNextAsk
    let model: AppModel
    let screen: Screen
    let reveal: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: WhatNextWatch(model)) { ask.update(model) }
            .onChange(of: model.menuCloses) { ask.close() }
            .onChange(of: model.today?.day) { ask.drop() }   // the rollover drops the kept answer
            .onChange(of: screen) { if screen != .list { ask.close() } }
            .onDisappear { ask.close() }
            .onChange(of: model.revealRequests) { reveal() }
            .accessibilityHidden(true)
    }
}

/// What, when it changes, may close or shorten What next?'s panel.
private struct WhatNextWatch: Equatable {
    let ready: Bool
    let focus: Bool
    let open: Set<UUID>

    @MainActor init(_ model: AppModel) {
        ready = model.ai?.canSuggestSteps == true
        focus = model.focus != nil
        open = model.whatNextOpenIds
    }
}
