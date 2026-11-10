import ClewCore
import ClewDomain
import SwiftUI

/// Names and icons of the imported lists (SPEC decision 2026-11-09).
enum CollectionStyle {
    static func name(_ source: Source) -> String {
        switch source {
        case .extensionYouTube: String(localized: "YouTube Watch Later")
        case .extensionX: String(localized: "X bookmarks")
        default: String(localized: "Imported")
        }
    }

    static func icon(_ source: Source) -> String {
        source == .extensionX ? "bookmark" : "play.rectangle"
    }
}

/// One imported list below the tasks: no circle, not counted toward today. Clicking it
/// opens its page.
struct CollectionRowView: View {
    let summary: CollectionSummary
    let model: AppModel
    let onOpen: () -> Void

    @State private var hovering = false
    @State private var titleInset: CGFloat = 26
    private static let rowSpace = "collectionRow"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // In the circle's place, so names line up with the tasks above.
                Image(systemName: CollectionStyle.icon(summary.source))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: TaskColumns.circleWidth)
                Text(verbatim: CollectionStyle.name(summary.source))
                    .lineLimit(1)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.rowSpace)).minX } action: { titleInset = $0 }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(summary.toWatch) to watch")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .background {
                if model.barStyle == .behindTitle {
                    ProgressFill(fraction: summary.fraction)
                        .padding(.horizontal, -6)
                        .padding(.vertical, -5)
                }
            }
            if model.barStyle == .underTitle {
                ProgressLine(fraction: summary.fraction)
                    .padding(.leading, titleInset)
                    .padding(.top, -2)
            }
        }
        .coordinateSpace(.named(Self.rowSpace))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                .padding(.horizontal, 6)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("\(CollectionStyle.name(summary.source)), \(summary.toWatch) to watch, \(summary.done) done"))
        .accessibilityAction(.default, onOpen)
    }
}

/// A collection's page: its heatmap, how many were finished, and the whole list:
/// in progress, not started, and done (folded).
struct CollectionView: View {
    let model: AppModel
    let source: Source
    let onBack: () -> Void

    @State private var showDone = false

    var body: some View {
        // Reading `collections` re-renders the page after every change.
        let _ = model.collections
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onBack) { Label("Today", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("Back to today's list"))

            if let page = model.collection(source), page.total > 0 || page.finishedAllTime > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: CollectionStyle.name(source))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(page.toWatch) to watch, \(page.done.count) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Deeper for more videos finished in a day, like a goal's +1s.
                Heatmap(today: page.today, amountByDay: page.finishedByDay, graded: true)
                HStack(alignment: .top, spacing: 8) {
                    StatTile(value: "\(page.finishedThisWeek)", label: Text("This week"))
                    StatTile(value: "\(page.finishedLast30)", label: Text("Last 30 days"))
                    StatTile(value: "\(page.finishedAllTime)", label: Text("All time"))
                }
                // A menu bar window sizes to its content, so a long list scrolls in a
                // fixed height instead of growing past the screen.
                if page.total > 8 {
                    ScrollView { list(page) }.frame(height: 300)
                } else {
                    list(page)
                }
            } else {
                Text("Nothing here yet.").foregroundStyle(.secondary)
            }
            NoticeView(text: model.notice)
        }
        .padding(12)
    }

    private func list(_ page: CollectionDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !page.inProgress.isEmpty {
                group(Text("In progress"), page.inProgress)
            }
            if !page.notStarted.isEmpty {
                group(Text("Not started"), page.notStarted)
            }
            if !page.done.isEmpty {
                DisclosureGroup(isExpanded: $showDone) {
                    entries(page.done)
                } label: {
                    Text("Done (\(page.done.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group(_ title: Text, _ list: [CollectionEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            title.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            entries(list)
        }
    }

    private func entries(_ list: [CollectionEntry]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(list) { CollectionEntryRow(entry: $0, model: model) }
        }
    }
}

/// One video on a collection's page: a circle to tick it (or undo today's tick) and a
/// title that opens it; its watch progress in the chosen bar style. One that left the
/// list counts as finished; "Not finished" takes it out (SPEC decision 2026-11-10).
struct CollectionEntryRow: View {
    let entry: CollectionEntry
    let model: AppModel

    private var item: Item { entry.item }
    private var isDone: Bool { entry.doneAt != nil }
    /// Watch progress, only while it is not ticked.
    private var watched: Double? { isDone ? nil : entry.watched.flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button { model.toggleFinished(entry) } label: {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isDone ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                // A tick from an earlier day stays: undo is for today (SPEC §4). One that
                // left the list is undone with "Not finished" instead.
                .disabled(isDone && (!entry.doneToday || !entry.onList))
                .accessibilityLabel(isDone ? Text("Undo \(item.title)") : Text("Mark \(item.title) done"))

                Button {
                    if let url = item.url { model.open(url) }
                } label: {
                    Text(item.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isDone ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .modifier(LinkPointer())
                .help(item.url?.absoluteString ?? "")
                .accessibilityLabel(Text("Open \(item.title)"))
                .accessibilityValue(watched.map { Text("\(Int(($0 * 100).rounded())) percent watched") } ?? Text(verbatim: ""))
            }
            .background {
                if model.barStyle == .behindTitle, let watched {
                    ProgressFill(fraction: watched).padding(.horizontal, -4).padding(.vertical, -3)
                }
            }
            if model.barStyle == .underTitle, let watched {
                ProgressLine(fraction: watched).padding(.leading, 22)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contextMenu {
            if let url = item.url { Button("Open") { model.open(url) } }
            if entry.onList {
                Button("Delete", role: .destructive) { model.delete(item.id) }
            } else {
                Button("Not finished", role: .destructive) { model.markNotFinished(item.id) }
            }
        }
        .accessibilityAction(named: entry.onList ? Text("Delete") : Text("Not finished")) {
            entry.onList ? model.delete(item.id) : model.markNotFinished(item.id)
        }
    }
}
