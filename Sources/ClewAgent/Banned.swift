import Foundation

/// Words a suggestion may never carry (docs/AGENT.md §1.4, §5): comparisons with other
/// people, streaks and guilt, medical or diagnostic terms. Phrases, so ordinary work words
/// pass ("Check the failed tests" is fine). Each has its own test.
public enum Banned {
    public static let phrases: [String] = [
        // Comparisons
        "than most", "other people", "average person", "everyone else",
        // Streaks and guilt
        "you missed", "you failed", "you broke", "streak", "behind schedule", "lazy",
        // Medical or diagnostic
        "adhd", "diagnos", "disorder", "symptom", "medication",
    ]

    /// True if `text` carries a banned phrase once the words of the person's own text
    /// (`masking`, e.g. their typed title) are blanked out, so for the task "Read ADHD
    /// paper" the step "Skim the ADHD paper's abstract" passes.
    public static func trips(_ text: String, masking own: [String] = []) -> Bool {
        let mine = Set(own.flatMap(words))
        let kept = words(text).map { mine.contains($0) ? "_" : $0 }.joined(separator: " ")
        // Substrings, so stems catch their forms ("diagnos": "diagnosis", "streak": "streaks").
        return phrases.contains { kept.contains($0) }
    }

    /// Lowercased words: letters and digits, split on anything else.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
