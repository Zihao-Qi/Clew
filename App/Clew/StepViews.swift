import ClewCore
import ClewDomain
import SwiftUI

/// An unfolded task's steps, under its row (SPEC "Steps in a task", 2026-11-21): done
/// steps first, in the order they were done, then the open ones in your order; each with
/// its own circle. Open steps reorder by dragging within their task. A click on a step
/// does nothing; a double-click opens its task's details.
struct StepsList: View {
    let model: AppModel
    let row: TodayRow
    let steps: TaskSteps
    /// Add Step…'s line is open after the steps.
    let adding: Bool
    let onAddClose: () -> Void
    let onOpen: () -> Void
    /// The step under the pointer: the Delete key deletes it.
    @Binding var hoveredStep: UUID?

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

    private var space: String { "steps-\(row.id.uuidString)" }

    /// The steps as drawn: the held order while a ticked step is under the pointer.
    private var shown: [TaskSteps.Entry] {
        guard let held else { return steps.entries }
        let rank = Dictionary(uniqueKeysWithValues: held.order.enumerated().map { ($1, $0) })
        return steps.entries.enumerated().sorted { a, b in
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
                NewStepLine(model: model, taskId: row.id, taskTitle: row.item.title, close: onAddClose)
            }
        }
        .coordinateSpace(name: space)
        .onPreferenceChange(StepFrames.self) { frames = $0 }
        .onChange(of: dragLive) { _, live in
            // A cancelled drag leaves nothing behind (review).
            if !live, dragging != nil { dragging = nil; dragTranslation = 0; dragSlot = nil }
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

    private func reorder(_ entry: TaskSteps.Entry) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { value in
                // Done steps stay where they are; the drag still belongs to the step, never
                // to its task's row.
                guard !entry.isDone else { return }
                if dragging == nil {
                    dragFrames = openIds.map { frames[$0] ?? .zero }
                    dragging = entry.id
                }
                let from = openIds.firstIndex(of: entry.id) ?? 0
                let own = dragFrames.indices.contains(from) ? dragFrames[from] : .zero
                if let first = dragFrames.first, let last = dragFrames.last {
                    dragTranslation = CGFloat(Clew.clampDrag(
                        translation: Double(value.translation.height),
                        row: (minY: Double(own.minY), maxY: Double(own.maxY)),
                        list: (minY: Double(first.minY), maxY: Double(last.maxY))))
                }
                let spans = dragFrames.map { (minY: Double($0.minY), maxY: Double($0.maxY)) }
                let slot = Clew.dragSlot(pointerY: Double(value.location.y), spans: spans)
                if slot != dragSlot { withAnimation(.easeOut(duration: 0.15)) { dragSlot = slot } }
            }
            .onEnded { _ in
                if let dragging, let from = openIds.firstIndex(of: dragging), let to = dragSlot, to != from {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { model.moveStep(dragging, toOpenIndex: to) }
                }
                dragging = nil
                dragTranslation = 0
                dragSlot = nil
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
            Text(entry.step.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(entry.isDone ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("\(entry.step.title), step of \(row.item.title)"))
                .accessibilityAddTraits(entry.isDone ? .isSelected : [])
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
        .debugFrame("step:\(entry.id)")
        .zIndex(dragging == entry.id ? 1 : 0)
        .onTapGesture(count: 2, perform: onOpen)
        .gesture(reorder(entry))
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
            Button("Delete") { model.deleteStep(entry.step) }
        }
    }
}

enum StepMetrics {
    /// A step's circle sits under its task's title: the row's margin, the task's circle
    /// and the gap after it.
    static let leading: CGFloat = 12 + TaskColumns.circleWidth + 8
}

/// Add Step…'s line (SPEC 2026-11-21): Return adds the step and opens the next line;
/// Esc, Return on an empty line, a click elsewhere and the menu closing close it.
struct NewStepLine: View {
    let model: AppModel
    let taskId: UUID
    let taskTitle: String
    let close: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField(text: $text) { Text("New step") }
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(save)
                .onExitCommand(perform: close)
                .accessibilityLabel(Text("New step of \(taskTitle)"))
        }
        .padding(.leading, StepMetrics.leading)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .background(OutsideClickWatcher(onOutside: close))
        .debugFrame("newStep:\(taskId)")
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return close() }
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
