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

    /// What is left: videos to watch, posts to read.
    static func left(_ count: Int, _ source: Source) -> String {
        source == .extensionX ? String(localized: "\(count) to read") : String(localized: "\(count) to watch")
    }

    /// The right-click item that undoes "removed means finished".
    static func notDone(_ source: Source) -> String {
        source == .extensionX ? String(localized: "Not read") : String(localized: "Not finished")
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
                Text(verbatim: CollectionStyle.left(summary.toWatch, summary.source))
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
        // Resting here opens the peek beside the menu (SPEC 2026-11-13); a click opens
        // the page and closes the peek.
        .background(PeekRowAnchor(source: summary.source))
        .onTapGesture {
            PeekController.shared.rowClicked()
            onOpen()
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: "\(CollectionStyle.name(summary.source)), \(CollectionStyle.left(summary.toWatch, summary.source)), \(String(localized: "\(summary.done) done"))"))
        .accessibilityAction(.default, onOpen)
    }
}

/// A collection's page: its heatmap, how many were finished, and the whole list:
/// in progress, not started, and done (folded).
struct CollectionView: View {
    let model: AppModel
    let source: Source
    let onBack: () -> Void

    /// The groups unfolded now; every page opens with all of them folded (user,
    /// 2026-11-13).
    @State private var open: Set<Group> = []
    /// The list's own height, so its scroll area is never taller than what it holds.
    @State private var listHeight: CGFloat = 0
    private static let maxListHeight: CGFloat = 300

    enum Group: Hashable { case inProgress, notStarted, done }

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
                    Text(verbatim: "\(CollectionStyle.left(page.toWatch, source)), \(String(localized: "\(page.done.count) done"))")
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
                // A menu bar window sizes to its content: the list scrolls once it is taller
                // than 300 points, and is never given more room than it fills (a fixed
                // height left a blank area under folded groups; user, 2026-11-13).
                ScrollView {
                    list(page).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 1), Self.maxListHeight))
            } else {
                Text("Nothing here yet.").foregroundStyle(.secondary)
            }
            NoticeView(text: model.notice)
        }
        .padding(12)
    }

    private func list(_ page: CollectionDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !page.inProgress.isEmpty {
                group(.inProgress, Text("In progress (\(page.inProgress.count))"), page.inProgress)
            }
            if !page.notStarted.isEmpty {
                // Posts have no progress: everything left is simply to read.
                group(.notStarted, source == .extensionX ? Text("To read (\(page.notStarted.count))")
                                                         : Text("Not started (\(page.notStarted.count))"),
                      page.notStarted)
            }
            if !page.done.isEmpty {
                group(.done, Text("Done (\(page.done.count))"), page.done)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A folded group: the whole header row, not only its arrow, folds and unfolds it.
    private func group(_ key: Group, _ title: Text, _ list: [CollectionEntry]) -> some View {
        let isOpen = open.contains(key)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if isOpen { open.remove(key) } else { open.insert(key) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    title
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOpen ? Text("Unfolded") : Text("Folded"))
            .accessibilityAddTraits(.isHeader)
            if isOpen { entries(list) }
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
                Button(CollectionStyle.notDone(item.source), role: .destructive) { model.markNotFinished(item.id) }
            }
        }
        .accessibilityAction(named: entry.onList ? Text("Delete") : Text(verbatim: CollectionStyle.notDone(item.source))) {
            entry.onList ? model.delete(item.id) : model.markNotFinished(item.id)
        }
    }
}
