import ClewCore
import ClewDomain
import SwiftUI

/// An unfolded task's steps, under its row (SPEC "Steps in a task", 2026-11-21): done
/// steps first, in the order they were done, then the open ones in your order; each with
/// its own circle. Open steps reorder by dragging within their task, or go onto an hour
/// of the timeline when dragged up there (the list draws that card). A step on the
/// timeline is not listed. A click on a step does nothing; a double-click opens its task's
/// details.
struct StepsList: View {
    let model: AppModel
    let row: TodayRow
    let steps: TaskSteps
    /// Add Step…'s line is open after the steps.
    let adding: Bool
    /// The line opened from the row's "Suggest steps" VoiceOver action: it asks at once.
    var suggestOnOpen = false
    let onAddClose: () -> Void
    let onOpen: () -> Void
    /// The step under the pointer: the Delete key deletes it.
    @Binding var hoveredStep: UUID?
    /// The list's coordinate space, where the timeline is too.
    var listSpace: String? = nil
    /// A step dragged in the list's space (nil: the drag ended or was cancelled); true
    /// while it is over the hours, where the list draws it as a block.
    var onTimelineDrag: (TaskSteps.Entry, CGPoint?) -> Bool = { _, _ in false }
    /// Dropped: true if it went onto the timeline.
    var onTimelineDrop: (TaskSteps.Entry) -> Bool = { _ in false }

    /// A step ticked out of order keeps its place until the pointer leaves it, so no other
    /// step slides under the pointer (SPEC, *user* 2026-11-21).
    @State private var held: (order: [UUID], step: UUID)?
    @State private var dragging: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragSlot: Int?
    @State private var frames: [UUID: CGRect] = [:]
    @State private var dragFrames: [CGRect] = []
    /// Cleared by itself when a step drag ends or is cancelled (the menu closing, Esc).
    @GestureState private var dragLive = false
    @State private var draggedEntry: TaskSteps.Entry?
    @State private var overTimeline = false
    /// Where this list starts in the list's space: drags are measured there.
    @State private var origin: CGFloat = 0

    private var space: String { "steps-\(row.id.uuidString)" }

    /// The steps as drawn: the held order while a ticked step is under the pointer.
    private var shown: [TaskSteps.Entry] {
        // Placed steps stay listed, with their time (SPEC 2026-11-22).
        let entries = steps.entries
        guard let held else { return entries }
        let rank = Dictionary(uniqueKeysWithValues: held.order.enumerated().map { ($1, $0) })
        return entries.enumerated().sorted { a, b in
            (rank[a.element.id] ?? held.order.count + a.offset) < (rank[b.element.id] ?? held.order.count + b.offset)
        }.map(\.element)
    }

    private var openIds: [UUID] { shown.filter { !$0.isDone }.map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { entry in
                stepRow(entry)
            }
            if adding {
                NewStepLine(model: model, taskId: row.id, taskTitle: row.item.title, suggestOnOpen: suggestOnOpen,
                            close: onAddClose)
            }
        }
        .coordinateSpace(name: space)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(listSpace ?? space)).minY } action: { origin = $0 }
        .onPreferenceChange(StepFrames.self) { frames = $0 }
        .onChange(of: dragLive) { _, live in
            // A cancelled drag leaves nothing behind (review).
            if !live, dragging != nil { endDrag() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            // The menu closing: no step stays held or hovered (review).
            held = nil
            if let h = hoveredStep, steps.entries.contains(where: { $0.id == h }) { hoveredStep = nil }
        }
        .onDisappear {
            // Folded without the pointer leaving (VoiceOver's Fold): the Delete key must
            // not reach a step that is no longer shown (review).
            if let h = hoveredStep, steps.entries.contains(where: { $0.id == h }) { hoveredStep = nil }
            // Gone mid-drag: the list's card goes too (review).
            if dragging != nil { endDrag() }
        }
        .onChange(of: steps) { _, now in
            // A step that is gone (deleted elsewhere) is no longer held.
            if let held, !now.entries.contains(where: { $0.id == held.step }) { self.held = nil }
        }
    }

    private func tap(_ entry: TaskSteps.Entry) {
        // Held only under the pointer: ticked another way (VoiceOver), it moves at once.
        // The order as drawn now, so a second tick under the pointer keeps it too (review).
        if hoveredStep == entry.id { held = (shown.map(\.id), entry.id) }
        model.tapStep(entry)
    }

    private func offset(_ id: UUID) -> CGFloat {
        guard let dragging, let from = openIds.firstIndex(of: dragging), let index = openIds.firstIndex(of: id) else { return 0 }
        if id == dragging { return dragTranslation }
        let height = Double(dragFrames.indices.contains(from) ? dragFrames[from].height : 0)
        return CGFloat(Clew.dragShift(index: index, from: from, to: dragSlot ?? from, draggedHeight: height))
    }

    private func endDrag() {
        if let draggedEntry { _ = onTimelineDrag(draggedEntry, nil) }
        draggedEntry = nil
        overTimeline = false
        dragging = nil
        dragTranslation = 0
        dragSlot = nil
    }

    private func reorder(_ entry: TaskSteps.Entry) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(listSpace ?? space))
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { value in
                // Done steps stay where they are; the drag still belongs to the step, never
                // to its task's row.
                guard !entry.isDone else { return }
                if dragging == nil {
                    dragFrames = openIds.map { frames[$0] ?? .zero }
                    dragging = entry.id
                    draggedEntry = entry
                }
                // Up over the hours: the list draws it as the block it would be, and the
                // steps stay where they are (SPEC 2026-11-21).
                let over = onTimelineDrag(entry, value.location)
                if over != overTimeline { overTimeline = over }
                if over {
                    if dragSlot != nil { withAnimation(.easeOut(duration: 0.15)) { dragSlot = nil } }
                    return
                }
                let localY = value.location.y - (listSpace == nil ? 0 : origin)
                let from = openIds.firstIndex(of: entry.id) ?? 0
                let own = dragFrames.indices.contains(from) ? dragFrames[from] : .zero
                if let first = dragFrames.first, let last = dragFrames.last {
                    dragTranslation = CGFloat(Clew.clampDrag(
                        translation: Double(value.translation.height),
                        row: (minY: Double(own.minY), maxY: Double(own.maxY)),
                        list: (minY: Double(first.minY), maxY: Double(last.maxY))))
                }
                let spans = dragFrames.map { (minY: Double($0.minY), maxY: Double($0.maxY)) }
                let slot = Clew.dragSlot(pointerY: Double(localY), spans: spans)
                if slot != dragSlot { withAnimation(.easeOut(duration: 0.15)) { dragSlot = slot } }
            }
            .onEnded { _ in
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    if overTimeline, let draggedEntry, onTimelineDrop(draggedEntry) {
                        // Placed: it leaves the list.
                    } else if let dragging, let from = openIds.firstIndex(of: dragging), let to = dragSlot, to != from {
                        model.moveStep(dragging, toOpenIndex: to)
                    }
                    endDrag()
                }
            }
    }

    private func stepRow(_ entry: TaskSteps.Entry) -> some View {
        let open = openIds
        let index = open.firstIndex(of: entry.id)
        return HStack(spacing: 6) {
            Button { tap(entry) } label: {
                Image(systemName: entry.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(entry.isDone ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(entry.isDone ? Text("Undo \(entry.step.title)") : Text("Mark \(entry.step.title) done"))
            .debugFrame("circle:\(entry.id)")
            if model.renamingStep == entry.id {
                // Only its own rename ends: a late save never clears another step's (review).
                StepRenameLine(model: model, step: entry.step) {
                    if model.renamingStep == entry.id { model.renamingStep = nil }
                }
            } else {
                Text(entry.step.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(entry.isDone ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("\(entry.step.title), step of \(row.item.title)"))
                    .accessibilityAddTraits(entry.isDone ? .isSelected : [])
                if model.timelineShown, let start = model.timeline?.nextStart(ofStep: entry.id, now: Date()) {
                    // Its block's start, until the block ends (SPEC 2026-11-22).
                    Text(start, format: .dateTime.hour().minute())
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        // Lined up with the task's count above it.
                        .padding(.trailing, RowView.undoWidth + 4)
                        .debugFrame("stepTime:\(entry.id)")
                        .accessibilityLabel(Text("on the timeline at \(start.formatted(date: .omitted, time: .shortened))"))
                }
            }
        }
        .padding(.leading, StepMetrics.leading)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .background {
            if dragging == entry.id {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
                    .padding(.leading, StepMetrics.leading - 6)
                    .padding(.trailing, 6)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            }
        }
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Color.clear.preference(key: StepFrames.self, value: [entry.id: g.frame(in: .named(space))])
        })
        .offset(y: offset(entry.id))
        // Over the hours, the list's card stands in for it.
        .opacity(dragging == entry.id && overTimeline ? 0 : 1)
        .debugFrame("step:\(entry.id)")
        .zIndex(dragging == entry.id ? 1 : 0)
        // While renaming, clicks and drags belong to the edit line.
        .gesture(TapGesture(count: 2).onEnded(onOpen), including: model.renamingStep == entry.id ? .subviews : .all)
        .gesture(reorder(entry), including: model.renamingStep == entry.id ? .subviews : .all)
        .onHover { inside in
            if inside {
                hoveredStep = entry.id
            } else {
                if hoveredStep == entry.id { hoveredStep = nil }
                // The pointer left the ticked step: it moves to its place now.
                if held?.step == entry.id { withAnimation(.easeOut(duration: 0.2)) { held = nil } }
            }
        }
        .contextMenu {
            Button("Rename") { model.renamingStep = entry.id }
            Button("Delete", role: .destructive) { model.deleteStep(entry.step) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if let index, index > 0 {
                Button("Move Up") { model.moveStep(entry.id, toOpenIndex: index - 1) }
            }
            if let index, index < open.count - 1 {
                Button("Move Down") { model.moveStep(entry.id, toOpenIndex: index + 1) }
            }
            Button("Rename") { model.renamingStep = entry.id }
            Button("Delete") { model.deleteStep(entry.step) }
            // Nothing needs a drag (SPEC 2026-11-21): the next quarter hour, 30 minutes.
            if !entry.isDone, model.timelineShown, model.timeline != nil {
                Button("Put on timeline") { model.placeStepAtNextQuarter(entry.id) }
            }
        }
    }
}

/// A step's title as an edit line, in place (SPEC 2026-11-22): Return or a click
/// elsewhere saves, Esc keeps the old title; an empty title is not saved.
struct StepRenameLine: View {
    let model: AppModel
    let step: Step
    let done: () -> Void

    @State private var text = ""
    @State private var ended = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(text: $text, prompt: Text(verbatim: step.title)) { EmptyView() }
            .textFieldStyle(.plain)
            .focused($focused)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text("Rename \(step.title)"))
            .debugFrame("rename:\(step.id)")
            .background(OutsideClickWatcher(onOutside: save))
            // The step left the list (deleted, folded, put on the timeline): the rename ends.
            .onDisappear { if model.renamingStep == step.id { model.renamingStep = nil } }
            .onAppear {
                text = step.title
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit(save)
            .onExitCommand {
                ended = true
                done()
            }
            .onChange(of: focused) { _, now in if !now { save() } }
    }

    private func save() {
        guard !ended else { return }
        ended = true
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != step.title { model.renameStep(step.id, trimmed) }
        done()
    }
}

enum StepMetrics {
    /// A step's circle sits under its task's title: the row's margin, the task's circle
    /// and the gap after it.
    static let leading: CGFloat = 12 + TaskColumns.circleWidth + 8
}

/// Add Step…'s line (SPEC 2026-11-21): Return adds the step and opens the next line;
/// Esc, Return on an empty line, a click elsewhere and the menu closing close it. With
/// AI on, ✨ at its right end suggests steps under it (SPEC "Suggest steps"); they are part
/// of the line, so clicking them never closes it.
struct NewStepLine: View {
    let model: AppModel
    let taskId: UUID
    let taskTitle: String
    var suggestOnOpen = false
    let close: () -> Void

    @State private var text = ""
    @State private var ask = SuggestionAsk()
    @FocusState private var focused: Bool

    private var canAdd: Bool { model.row(taskId).map(model.canAddStep) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                TextField(text: $text) { Text("New step") }
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityLabel(Text("New step of \(taskTitle)"))
                if model.canSuggestSteps(taskId) || ask.isThinking {
                    SuggestButton(ask: ask, title: false, start: suggest)
                }
            }
            .padding(.leading, StepMetrics.leading)
            .padding(.trailing, 12)
            .padding(.vertical, 3)
            SuggestionList(ask: ask, leading: StepMetrics.leading) { model.addSuggestedStep(to: taskId, title: $0) }
        }
        // Esc anywhere in the line, the suggestions' buttons too (review).
        .onExitCommand { ask.cancel(); close() }
        .background(OutsideClickWatcher(onOutside: close))
        .debugFrame("newStep:\(taskId)")
        .onAppear {
            DispatchQueue.main.async { focused = true }
            if suggestOnOpen { suggest() }
        }
        .onDisappear { ask.cancel() }
        // The task became done or was deleted: nothing appears later.
        .onChange(of: canAdd) { _, now in if !now { ask.cancel() } }
        .onChange(of: model.row(taskId)?.isDone) { _, done in if done == true { ask.cancel() } }
    }

    private func suggest() {
        guard let ai = model.ai, model.canSuggestSteps(taskId), let input = model.suggestInput(taskId) else { return }
        ask.ask(ai, input)
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { ask.cancel(); return close() }
        // Refused (too long): the line keeps its text, and the notice says why.
        if model.addStep(to: taskId, title: text) {
            text = ""
            DispatchQueue.main.async { focused = true }
        }
    }
}

private struct StepFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Debug harnesses find views by key: their frames in the window's content, top-left
/// origin. Nothing in a release build.
@MainActor enum DebugFrames {
    #if DEBUG
    static var frames: [String: CGRect] = [:]
    /// Add Step… on a task, as its menu item does (the harness cannot open a menu).
    static var addStep: ((UUID) -> Void)?
    /// The pointer over a step, as hovering does (posted events do not move it).
    static var hoverStep: ((UUID?) -> Void)?
    #endif
}

extension View {
    func debugFrame(_ key: @autoclosure () -> String) -> some View {
        #if DEBUG
        let key = key()
        return background(GeometryReader { g in
            Color.clear
                .onAppear { DebugFrames.frames[key] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, now in DebugFrames.frames[key] = now }
                .onDisappear { DebugFrames.frames[key] = nil }
        })
        #else
        return self
        #endif
    }
}
