import ClewDomain
import SwiftUI

struct TodayListView: View {
    let model: AppModel
    @Binding var screen: Screen
    @Environment(\.openWindow) private var openWindow
    @State private var dropTarget: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rows = model.today?.rows, !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        RowView(row: row, model: model, onEdit: { screen = .edit(row.item, back: .list) },
                                onOpen: { screen = .detail(row.id) },
                                canMoveUp: index > 0, canMoveDown: index < rows.count - 1,
                                isDropTarget: dropTarget == row.id)
                            .draggable(row.id.uuidString)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let dragged = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
                                return model.drop(dragged, onto: row)
                            } isTargeted: { over in
                                if over { dropTarget = row.id } else if dropTarget == row.id { dropTarget = nil }
                            }
                    }
                }
                .padding(.vertical, 6)
            } else {
                Text("Nothing for today.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }

            NoticeView(text: model.notice ?? model.confirmation)
                .animation(.easeOut(duration: 0.4), value: model.notice ?? model.confirmation)

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

struct RowView: View {
    let row: TodayRow
    let model: AppModel
    let onEdit: () -> Void
    let onOpen: () -> Void
    var canMoveUp = false
    var canMoveDown = false
    /// A dragged row is hovering over this one.
    var isDropTarget = false

    @State private var hovering = false

    private var item: Item { row.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            mainLine
            if row.isGoalReached, !model.dismissedCelebrations.contains(row.id) {
                celebration
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background {
            // A dropped row takes this row's place, above or below depending on where it
            // came from, so the whole row lights up rather than a line on one side.
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hovering ? 0.06 : 0))
                .padding(.horizontal, 6)
        }
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
                    ProgressView(value: Double(min(row.progressAmount, target)), total: Double(target))
                        .progressViewStyle(.linear)
                        .frame(width: 64)
                        .accessibilityHidden(true)
                    Text(verbatim: "\(row.progressAmount)/\(target)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: Self.countWidth, alignment: .trailing)
                        .accessibilityLabel(Text("\(row.progressAmount) of \(target)"))
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
            }
        }
    }

    /// Clicking the title (or anywhere in the row's free space) opens the details; the
    /// link mark is the button that opens the link (SPEC §3).
    private var titleView: some View {
        HStack(spacing: 4) {
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(row.isDone ? .secondary : .primary)
                .accessibilityAddTraits(row.isDone ? .isSelected : [])
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

    private var tapLabel: Text {
        if row.isGoalReached { return Text("\(item.title), goal reached") }
        if item.kind == .goal { return Text("Add one to \(item.title)") }
        return row.isDone ? Text("Undo \(item.title)") : Text("Mark \(item.title) done")
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
