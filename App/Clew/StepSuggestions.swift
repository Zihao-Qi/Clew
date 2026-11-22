import ClewAgent
import ClewAI
import ClewDomain
import SwiftUI

/// One open line's suggestions (SPEC "Suggest steps"): thinking, shown, or a short
/// failure. Never kept; anything that closes the line drops them.
@MainActor @Observable
final class SuggestionAsk {
    enum State: Equatable {
        case idle
        case thinking
        case shown([String])
        case failed
        case usageLimit
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    #if DEBUG
    /// The debug render's state for every new line.
    static var preset: State?
    init() { state = Self.preset ?? .idle }
    #endif
    @ObservationIgnored private var generation = 0

    var isThinking: Bool { state == .thinking }

    /// Asks again; a new set replaces the old one.
    func ask(_ ai: AIModel, _ input: SuggestSteps.Input) {
        cancel()
        generation += 1
        let mine = generation
        state = .thinking
        task = Task {
            let result = await ai.suggestSteps(input)
            guard mine == generation, !Task.isCancelled else { return }
            switch result {
            case .success(let steps): state = .shown(steps)
            case .failure(let failure) where failure.provider == .usageLimit: state = .usageLimit
            case .failure:
                state = .failed
                try? await Task.sleep(for: .seconds(5))
                if mine == generation, state == .failed { state = .idle }
            }
        }
    }

    /// Cancel, Esc, the line closing: nothing appears later.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        state = .idle
    }

    func take(_ step: String) {
        guard case .shown(var steps) = state else { return }
        steps.removeAll { $0 == step }
        state = steps.isEmpty ? .idle : .shown(steps)
    }
}

extension AppModel {
    /// What Suggest steps sends for a task: its title (marked untrusted if fetched), its
    /// note and its steps. Nothing else (SPEC "Suggest steps").
    func suggestInput(_ taskId: UUID) -> SuggestSteps.Input? {
        guard let row = row(taskId) else { return nil }
        return SuggestSteps.Input(title: row.item.title, untrusted: row.item.titleOrigin == .fetched,
                                  note: row.item.note,
                                  steps: allSteps(of: taskId).map { .init(name: $0.step.title, done: $0.isDone) })
    }

    /// ✨ shows only while signed in, the switch on, and a step can be added.
    func canSuggestSteps(_ taskId: UUID) -> Bool {
        guard let ai, ai.canSuggestSteps, let row = row(taskId) else { return false }
        return canAddStep(row)
    }
}

/// The ✨ button, or while thinking a small spinner with Cancel.
struct SuggestButton: View {
    let ask: SuggestionAsk
    let title: Bool
    let start: () -> Void

    var body: some View {
        if ask.isThinking {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Button("Cancel") { ask.cancel() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel(Text("Cancel suggestions"))
            }
        } else if title {
            Button(action: start) { Label("Suggest Steps", systemImage: "sparkles") }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Suggest steps"))
        } else {
            Button(action: start) { Image(systemName: "sparkles") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(Text("Suggest steps"))
                .accessibilityLabel(Text("Suggest steps"))
        }
    }
}

/// The suggestions under the line: quiet rows with +, then Add all and Dismiss.
struct SuggestionList: View {
    let ask: SuggestionAsk
    let leading: CGFloat
    /// The details already pad their content; the list's rows do not.
    var trailing: CGFloat = 12
    /// Adds one step as typing it would; false if it was refused.
    let add: (String) -> Bool

    var body: some View {
        switch ask.state {
        case .idle, .thinking: EmptyView()
        case .shown(let steps):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(steps, id: \.self) { step in
                    HStack(spacing: 6) {
                        Image(systemName: "circle.dotted")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(step)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { if add(step) { ask.take(step) } } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help(Text("Add \(step)"))
                            .accessibilityLabel(Text("Add \(step)"))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: Text("Add \(step)")) { if add(step) { ask.take(step) } }
                }
                HStack(spacing: 12) {
                    Button("Add all") {
                        for step in steps {
                            guard add(step) else { break }
                            ask.take(step)
                        }
                        ask.cancel()
                    }
                    .accessibilityLabel(Text("Add all suggested steps"))
                    Button("Dismiss") { ask.cancel() }
                        .accessibilityLabel(Text("Dismiss suggestions"))
                    Spacer()
                    Text("Using ChatGPT plan").font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.top, 3)
            }
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .padding(.vertical, 2)
        case .failed:
            Text("Couldn't suggest steps. Try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, leading)
                .padding(.vertical, 2)
        case .usageLimit:
            HStack(spacing: 4) {
                Group {
                    Text("ChatGPT usage limit reached")
                    Text(verbatim: "·")
                }
                .foregroundStyle(.secondary)
                Link("Manage usage", destination: ChatGPT.usageURL)
                    .accessibilityLabel(Text("Manage ChatGPT usage"))
                Spacer()
                Button { ask.cancel() } label: { Image(systemName: "xmark").imageScale(.small) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Dismiss"))
            }
            .font(.caption)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .padding(.vertical, 2)
        }
    }
}
