import ClewCore
import ClewDomain
import SwiftUI

struct TodayListView: View {
    let model: AppModel
    @Binding var screen: Screen
    @Environment(\.openWindow) private var openWindow
    /// Reordering with a plain drag gesture inside the list (SwiftUI's draggable /
    /// dropDestination never delivered the drop in the menu bar panel). The dragged row
    /// follows the pointer; the rows in between slide aside live; release lands it in
    /// the gap. The slot and shift math is in Core (Clew.dragSlot / dragShift), tested.
    @State private var dragging: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragSlot: Int?
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// Row frames frozen when a drag begins, so slots are measured against the list as
    /// it was, not against rows that are sliding.
    @State private var dragFrames: [CGRect] = []

    private static let listSpace = "todayList"

    private func offset(for row: TodayRow, at index: Int, in rows: [TodayRow]) -> CGFloat {
        guard let dragging, let from = rows.firstIndex(where: { $0.id == dragging }) else { return 0 }
        if row.id == dragging { return dragTranslation }
        let height = Double(dragFrames.indices.contains(from) ? dragFrames[from].height : 0)
        return CGFloat(Clew.dragShift(index: index, from: from, to: dragSlot ?? from, draggedHeight: height))
    }

    private func drag(_ row: TodayRow, in rows: [TodayRow]) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if dragging == nil {
                    dragFrames = rows.map { rowFrames[$0.id] ?? .zero }
                    dragging = row.id
                }
                // Kept inside the rows: never over the footer (Add, Later, Settings).
                let from = rows.firstIndex(where: { $0.id == row.id }) ?? 0
                if let first = dragFrames.first, let last = dragFrames.last, dragFrames.indices.contains(from) {
                    let own = dragFrames[from]
                    dragTranslation = CGFloat(Clew.clampDrag(
                        translation: Double(value.translation.height),
                        row: (minY: Double(own.minY), maxY: Double(own.maxY)),
                        list: (minY: Double(first.minY), maxY: Double(last.maxY))))
                } else {
                    dragTranslation = value.translation.height
                }
                let spans = dragFrames.map { (minY: Double($0.minY), maxY: Double($0.maxY)) }
                let slot = Clew.dragSlot(pointerY: Double(value.location.y), spans: spans)
                if slot != dragSlot {
                    withAnimation(.easeOut(duration: 0.15)) { dragSlot = slot }
                }
            }
            .onEnded { _ in
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    if let from = rows.firstIndex(where: { $0.id == row.id }), let to = dragSlot, to != from {
                        model.drop(row.id, onto: rows[to])
                    }
                    dragging = nil
                    dragTranslation = 0
                    dragSlot = nil
                }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rows = model.today?.rows, !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        RowView(row: row, model: model, onEdit: { screen = .edit(row.item, back: .list) },
                                onOpen: { screen = .detail(row.id) },
                                canMoveUp: index > 0, canMoveDown: index < rows.count - 1,
                                isDragged: dragging == row.id)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: RowFrames.self,
                                                       value: [row.id: g.frame(in: .named(Self.listSpace))])
                            })
                            .offset(y: offset(for: row, at: index, in: rows))
                            .zIndex(dragging == row.id ? 1 : 0)
                            .shadow(color: .black.opacity(dragging == row.id ? 0.18 : 0), radius: 6, y: 2)
                            .gesture(drag(row, in: rows))
                    }
                }
                .coordinateSpace(name: Self.listSpace)
                .onPreferenceChange(RowFrames.self) { rowFrames = $0 }
                .padding(.vertical, 6)
            } else {
                Text("Nothing for today.")
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
    var canMoveUp = false
    var canMoveDown = false
    /// This row is being dragged: it gets a solid background so rows sliding under it
    /// don't show through.
    var isDragged = false

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

    /// How far along the row is, drawn in the chosen style: a goal's count this round,
    /// or how much of a video was watched. Nil: nothing to draw.
    private var fraction: Double? {
        if let target = item.progress.target, target > 0 {
            return Double(min(row.progressAmount, target)) / Double(target)
        }
        if let watched = model.watched[row.id], watched > 0 { return watched }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            mainLine
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
                        .fill(Color.primary.opacity(hovering ? 0.06 : 0))
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
        .onHover { hovering = $0 }
        .accessibilityAction(named: Text("Move Up")) { if canMoveUp { model.move(row, by: -1) } }
        .accessibilityAction(named: Text("Move Down")) { if canMoveDown { model.move(row, by: 1) } }
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

    private var mainLine: some View {
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

            titleView
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
