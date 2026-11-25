import ClewAgent
import ClewAI
import ClewCore
import ClewDomain
import SwiftUI

/// What next? (SPEC "What next?", AI-4): asked ahead when the menu opens, its answer kept
/// in memory for the same open tasks (2 hours at most), and the panel: asking, the
/// answer, or a short failure.
@MainActor @Observable
final class WhatNextAsk {
    enum State: Equatable {
        case idle
        case asking
        /// `picks[0]` is the pick; `first` is the answer's own first pick.
        case shown(picks: [WhatNext.Pick], first: UUID)
        case failed
        case usageLimit
        case signInEnded
    }

    /// An answer kept for later presses: for which open tasks, day and ready period.
    struct Kept {
        let key: String
        let day: LocalDay?
        let generation: Int
        let at: Date
        let picks: [WhatNext.Pick]
    }

    static let keptFor: TimeInterval = 2 * 3600

    private(set) var state: State = .idle
    @ObservationIgnored private(set) var kept: Kept?
    /// A background failure the person sees when they press Next.
    @ObservationIgnored private var keptFailure: State?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private(set) var requestKey: String?
    @ObservationIgnored private var requestGeneration = 0
    @ObservationIgnored private var panelGeneration = 0
    #if DEBUG
    /// The debug render's state.
    static var preset: State?
    init() { state = Self.preset ?? .idle }
    func showForRender(_ shown: State) { state = shown }
    #endif

    var isOpen: Bool { state != .idle }
    var isAsking: Bool { request != nil }

    /// The menu opened: ask in the background unless the kept answer still fits.
    func askAhead(_ model: AppModel, now: Date = Date()) {
        guard model.canAskWhatNext else { return }
        let key = model.whatNextKey()
        if let kept = usable(model, now: now), kept.key == key { return }
        if request != nil, requestKey == key { return }
        start(model, key: key, now: now)
    }

    /// The kept answer, if it is from today, this ready period and less than 2 hours old.
    private func usable(_ model: AppModel, now: Date) -> Kept? {
        guard let kept, kept.day == model.today?.day, kept.generation == model.ai?.generation,
              now.timeIntervalSince(kept.at) < Self.keptFor else { return nil }
        return kept
    }

    private func start(_ model: AppModel, key: String, now: Date) {
        guard let ai = model.ai else { return }
        request?.cancel()
        requestGeneration += 1
        let mine = requestGeneration
        let generation = ai.generation
        let day = model.today?.day
        requestKey = key
        let made = model.whatNextRequest(now: now)
        request = Task {
            let result = await ai.whatNext(made.input, job: WhatNext(ids: made.ids, titles: made.titles))
            guard mine == requestGeneration else { return }
            request = nil
            requestKey = nil
            // This request's own ended sign-in still shows, though it ended ready (SPEC).
            if case .failure(let failure) = result, failure.provider == .signInEnded {
                if state == .asking { landed(model, result) } else { keptFailure = .signInEnded }
                return
            }
            guard generation == ai.generation else { return }   // ready was lost meanwhile
            switch result {
            case .success(let picks):
                kept = Kept(key: key, day: day, generation: generation, at: now, picks: picks)
                keptFailure = nil
            case .failure(let failure) where failure.provider == .usageLimit: keptFailure = .usageLimit
            case .failure(let failure) where failure.provider == .signInEnded: keptFailure = .signInEnded
            case .failure: break   // silent in the background
            }
            if state == .asking { landed(model, result) }
        }
    }

    /// A request finished while the panel waits for it.
    private func landed(_ model: AppModel, _ result: Result<[WhatNext.Pick], JobFailure>) {
        keptFailure = nil
        switch result {
        case .success(let picks):
            // Tasks ticked meanwhile leave; none left closes quietly (not a failure).
            let open = model.whatNextOpenIds
            let left = picks.filter { open.contains($0.itemId) }
            guard let firstPick = picks.first, !left.isEmpty else { return close() }
            state = .shown(picks: left, first: firstPick.itemId)
        case .failure(let failure) where failure.provider == .usageLimit:
            state = .usageLimit
        case .failure(let failure) where failure.provider == .signInEnded:
            state = .signInEnded
            closeLater()
        case .failure:
            state = .failed
            closeLater()
        }
    }

    /// Next: closes what shows (the person chose to), or shows the kept answer at once,
    /// or waits for (or starts) a request.
    func toggle(_ model: AppModel, now: Date = Date()) {
        if isOpen { return closeByPerson(model) }
        guard model.canAskWhatNext else { return }
        panelGeneration += 1
        if let kept = usable(model, now: now) {
            let open = model.whatNextOpenIds
            let left = kept.picks.filter { open.contains($0.itemId) }
            if let firstPick = kept.picks.first, !left.isEmpty {
                state = .shown(picks: left, first: firstPick.itemId)
                return
            }
        }
        if let failure = keptFailure {
            keptFailure = nil
            state = failure
            if failure == .signInEnded { closeLater() }
            return
        }
        if request == nil { start(model, key: model.whatNextKey(), now: now) }
        state = .asking
    }

    private func closeLater() {
        let mine = panelGeneration
        Task {
            try? await Task.sleep(for: .seconds(5))
            if mine == panelGeneration, state == .failed || state == .signInEnded { close() }
        }
    }

    /// Cancel, Not now, Esc, Next: an answer still showing counts as dismissed.
    func closeByPerson(_ model: AppModel) {
        if case .shown = state { model.ai?.recordNextDismissed() }
        close()
    }

    /// Closings the person did not choose: nothing is recorded. A request under way
    /// finishes into the kept answer.
    func close() {
        panelGeneration += 1
        state = .idle
    }

    /// Losing ready, the rollover, Forget everything: the kept answer and any request go.
    func drop() {
        requestGeneration += 1
        request?.cancel()
        request = nil
        requestKey = nil
        kept = nil
        keptFailure = nil
        close()
    }

    /// Another task becomes the pick; the old pick takes its place under "Or:".
    func choose(_ itemId: UUID) {
        guard case .shown(var picks, let first) = state, let i = picks.firstIndex(where: { $0.itemId == itemId }),
              i > 0 else { return }
        picks.swapAt(0, i)
        state = .shown(picks: picks, first: first)
    }

    /// ▶ Focus 25 min on the pick.
    func focus(_ model: AppModel) {
        guard case .shown(let picks, let first) = state, let pick = picks.first,
              let row = model.row(pick.itemId) else { return }
        model.ai?.recordNext(task: row.item.title, typed: row.item.titleOrigin == .typed, focus: true,
                             other: pick.itemId != first)
        close()
        model.startFocus(row, minutes: 25)
    }

    /// The pick's title: the panel closes and the list goes to the task.
    func goTo(_ model: AppModel) {
        guard case .shown(let picks, let first) = state, let pick = picks.first,
              let row = model.row(pick.itemId) else { return }
        model.ai?.recordNext(task: row.item.title, typed: row.item.titleOrigin == .typed, focus: false,
                             other: pick.itemId != first)
        close()
        model.requestReveal(pick.itemId)
    }

    /// Keeps the panel in step with the list (SPEC "What next?": Pressing Next, While it shows).
    func update(_ model: AppModel) {
        let ready = model.ai?.canSuggestSteps == true
        // A request that ended the sign-in is let land, so its message shows (SPEC).
        let landing = model.ai?.ended == true && request != nil
        if !ready, !landing, state != .signInEnded, kept != nil || request != nil { drop() }
        switch state {
        case .idle:
            break
        case .asking:
            if !model.canAskWhatNext, !landing { close() }
        case .failed, .usageLimit:
            if !ready || model.focus != nil { close() }
        case .signInEnded:
            if model.focus != nil { close() }
        case .shown(var picks, let first):
            guard ready, model.focus == nil else { return close() }
            let open = model.whatNextOpenIds
            picks.removeAll { !open.contains($0.itemId) }
            if picks.isEmpty { close() } else if picks != currentPicks { state = .shown(picks: picks, first: first) }
        }
    }

    private var currentPicks: [WhatNext.Pick] {
        if case .shown(let picks, _) = state { return picks }
        return []
    }
}

extension AppModel {
    /// Today's open tasks (SPEC "What next?", as Notes): not done today; a goal not yet
    /// reached. In Today's order, wherever a task is placed.
    var whatNextOpenRows: [TodayRow] {
        (today?.rows ?? []).filter { $0.item.progress.target != nil ? !$0.isGoalReached : !$0.isDone }
    }

    var whatNextOpenIds: Set<UUID> { Set(whatNextOpenRows.map(\.id)) }

    /// ✨ shows: AI ready with a model, no focus timer at all, at least 2 open tasks.
    var canAskWhatNext: Bool {
        ai?.canSuggestSteps == true && focus == nil && whatNextOpenRows.count >= 2
    }

    /// What is sent (SPEC "What next?": What is sent).
    func whatNextRequest(now: Date = Date())
        -> (input: WhatNext.Input, ids: [String: UUID], titles: [String: String]) {
        let blocks = timelineShown ? (timeline?.blocks ?? []) : []
        let candidates = whatNextOpenRows.map { row -> WhatNext.Candidate in
            let steps = allSteps(of: row.id)
            let next = blocks.filter { $0.block.itemId == row.id && Self.end($0) > now }.map(\.block.start).min()
            let kind: WhatNext.Task.Kind = switch row.item.kind {
            case .once: .once
            case .link: .link
            case .habit: .habit
            case .goal: .goal
            }
            return WhatNext.Candidate(itemId: row.id, title: row.item.title, typed: row.item.titleOrigin == .typed,
                                      kind: kind, progress: row.item.progress.target.map { (row.progressAmount, $0) },
                                      priority: row.item.priority,
                                      steps: steps.isEmpty ? nil : (steps.filter(\.isDone).count, steps.count),
                                      block: next)
        }
        var free: Int?
        if timelineShown, timeline != nil {
            let busy = blocks.map { (start: $0.block.start, end: Self.end($0)) }
                + (calendarEvents?.timed ?? []).map { (start: $0.start, end: $0.end) }
            free = WhatNext.freeMinutes(now: now, busy: busy)
        }
        return WhatNext.input(candidates, at: now, calendar: .current, freeMinutes: free)
    }

    /// What the kept answer is for: the open tasks as sent, without the time.
    func whatNextKey() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let tasks = whatNextRequest().input.tasks
        return String(decoding: (try? encoder.encode(tasks)) ?? Data(), as: UTF8.self)
    }

    static func end(_ block: TimelineBlock) -> Date {
        block.block.start.addingTimeInterval(TimeInterval(block.block.minutes * 60))
    }

    /// ▶ Focus only where the timer can show: the task's row in the list, or its own
    /// block on the timeline (not a task off the list only through its steps' blocks).
    func whatNextCanFocus(_ itemId: UUID) -> Bool {
        if listRows.contains(where: { $0.id == itemId }) { return true }
        return timelineShown && (timeline?.blocks ?? []).contains { $0.block.itemId == itemId && $0.block.stepId == nil }
    }

    /// The block to show for a task with no row: its next one that has not ended (its own
    /// or a step's), else its latest today.
    func whatNextBlock(_ itemId: UUID, now: Date = Date()) -> TimelineBlock? {
        let mine = (timeline?.blocks ?? []).filter { $0.block.itemId == itemId }
        return mine.filter { Self.end($0) > now }.min { $0.block.start < $1.block.start }
            ?? mine.max { $0.block.start < $1.block.start }
    }
}

/// The panel above the bottom bar.
struct WhatNextPanel: View {
    let ask: WhatNextAsk
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch ask.state {
            case .idle:
                EmptyView()
            case .asking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Choosing…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { ask.closeByPerson(model) }
                        .accessibilityLabel(Text("Cancel What next?"))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Choosing what's next"))
            case .shown(let picks, _):
                answer(picks)
            case .failed:
                failure(Text("Couldn't choose. Try again."))
            case .usageLimit:
                // As Suggest steps says it: the text, then the link in the accent colour.
                failure(Text("ChatGPT usage limit reached")) {
                    Link("Manage usage", destination: ChatGPT.usageURL)
                        .buttonStyle(.link)
                        .simultaneousGesture(TapGesture().onEnded { ask.close() })
                        .accessibilityLabel(Text("Manage ChatGPT usage"))
                }
            case .signInEnded:
                // The ended sign-in's message stays its 5 seconds, though ready is gone.
                failure(Text("OpenAI ended Clew's sign-in. Sign in again in Settings › AI."))
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8)
        .background {
            // Esc closes it (SPEC "What next?").
            Button { ask.closeByPerson(model) } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .debugFrame("whatNextPanel")
    }

    /// A failure's line (it may wrap), anything to act on, then Not now on its own line,
    /// as the answer's.
    private func failure(_ text: Text, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            text.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                action()
                Spacer()
                notNow
            }
        }
    }

    private var notNow: some View {
        Button("Not now") { ask.closeByPerson(model) }
            .accessibilityLabel(Text("Not now"))
    }

    private func answer(_ picks: [WhatNext.Pick]) -> some View {
        let pick = picks[0]
        let title = model.row(pick.itemId)?.item.title ?? ""
        let others = picks.dropFirst().compactMap { p in model.row(p.itemId).map { (p.itemId, $0.item.title) } }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ClickableText(text: title, bold: true) { ask.goTo(model) }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(Text("Go to \(title)"))
                    .accessibilitySortPriority(1)
                    .debugFrame("whatNextTitle")
                Spacer(minLength: 8)
                if model.whatNextCanFocus(pick.itemId) {
                    Button { ask.focus(model) } label: { Label("Focus 25 min", systemImage: "play.fill") }
                        .fixedSize()
                        .accessibilityLabel(Text("Focus 25 minutes on \(title)"))
                        .accessibilitySortPriority(2)
                        .debugFrame("whatNextFocus")
                }
            }
            Text(verbatim: pick.reason)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text("Suggested: \(title). \(pick.reason)"))
                .accessibilitySortPriority(3)   // read first, then Focus, Go to, the others, Not now
            if !others.isEmpty {
                HStack(spacing: 4) {
                    Text("Or:").foregroundStyle(.secondary).fixedSize()
                    ForEach(Array(others.enumerated()), id: \.element.0) { i, other in
                        if i > 0 { Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true) }
                        ClickableText(text: other.1, bold: false) { ask.choose(other.0) }
                            .lineLimit(1)
                            .accessibilityLabel(Text("Choose \(other.1)"))
                    }
                }
            }
            HStack {
                Spacer()
                notNow
            }
        }
        // Its order stays inside the panel, never above the list's rows (review).
        .accessibilityElement(children: .contain)
    }
}

/// Plain text that shows it can be clicked on hover: underlined, a pointing hand.
private struct ClickableText: View {
    let text: String
    let bold: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: text)
                .fontWeight(bold ? .semibold : .regular)
                .underline(hovering)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .modifier(LinkPointer())   // the hand comes and goes with the view (review: a push leaked)
    }
}
