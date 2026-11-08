import ClewDomain
import SwiftUI

struct TodayListView: View {
    let model: AppModel
    @Binding var screen: Screen

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

            NoticeView(text: model.notice)

            Divider()

            HStack(spacing: 12) {
                Button { screen = .add } label: { Label("Add", systemImage: "plus") }
                    .keyboardShortcut("n")
                    .accessibilityLabel(Text("Add an item"))
                Spacer()
                Button { screen = .pick } label: { Text("Later (\(model.laterCount))") }
                    .keyboardShortcut("l")
                    .accessibilityLabel(Text("Later pile, \(model.laterCount) items. Pick some for today."))
                Menu {
                    Button("Quit Clew") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("More"))
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
        HStack(spacing: 8) {
            Button { model.tap(row) } label: {
                Image(systemName: row.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(row.isDone ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(tapLabel)

            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(row.isDone ? .secondary : .primary)
                .accessibilityAddTraits(row.isDone ? .isSelected : [])
                .frame(maxWidth: .infinity, alignment: .leading)

            if let target = item.progress.target {
                ProgressView(value: Double(min(row.lifetimeAmount, target)), total: Double(target))
                    .progressViewStyle(.linear)
                    .frame(width: 64)
                    .accessibilityHidden(true)
                Text(verbatim: "\(row.lifetimeAmount)/\(target)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("\(row.lifetimeAmount) of \(target)"))
            }

            if let url = item.url {
                Button { model.open(url) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Open link for \(item.title)"))
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
            if (item.kind == .once || item.kind == .link), row.lifetimeAmount == 0 {
                Button("Move to Later") { model.moveToLater(row) }
            }
            Divider()
            Button("Archive") { model.archive(row) }
        }
    }

    private var tapLabel: Text {
        if item.kind == .goal { return Text("Add one to \(item.title)") }
        return row.isDone ? Text("Undo \(item.title)") : Text("Mark \(item.title) done")
    }
}

struct NoticeView: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
    }
}
