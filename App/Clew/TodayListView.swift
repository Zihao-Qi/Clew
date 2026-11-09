import ClewDomain
import SwiftUI

struct TodayListView: View {
    let model: AppModel
    @Binding var screen: Screen
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rows = model.today?.rows, !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        RowView(row: row, model: model) { screen = .edit(row.item) }
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
        .contentShape(Rectangle())
        .contextMenu {
            if row.todayAmount > 0 {
                if item.kind == .goal {
                    Button("Undo +1") { model.undo(row) }
                } else {
                    Button("Undo") { model.undo(row) }
                }
            }
            Button("Edit…", action: onEdit)
            if (item.kind == .once || item.kind == .link), row.progressAmount == 0 {
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
                ProgressView(value: Double(min(row.progressAmount, target)), total: Double(target))
                    .progressViewStyle(.linear)
                    .frame(width: 64)
                    .accessibilityHidden(true)
                Text(verbatim: "\(row.progressAmount)/\(target)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("\(row.progressAmount) of \(target)"))
                // Undo is one click away (SPEC §4), and kept apart from the circle so
                // rapid +1s cannot hit it by mistake.
                Button { model.undo(row) } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .opacity(row.todayAmount > 0 ? 1 : 0)
                    .disabled(row.todayAmount == 0)
                    .accessibilityHidden(row.todayAmount == 0)
                    .accessibilityLabel(Text("Remove one from \(item.title)"))
            }
        }
    }

    /// A linked title opens its link; a small link mark says so (SPEC §3).
    @ViewBuilder private var titleView: some View {
        let text = Text(item.title)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(row.isDone ? .secondary : .primary)
        if let url = item.url {
            Button { model.open(url) } label: {
                HStack(spacing: 4) {
                    text
                    Image(systemName: "link")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .modifier(LinkPointer())
            .help(url.absoluteString)
            .accessibilityLabel(Text("Open \(item.title)"))
        } else {
            text.accessibilityAddTraits(row.isDone ? .isSelected : [])
        }
    }

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
