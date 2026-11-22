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

    /// True if `text` carries a banned phrase, other than one the person's own text
    /// (`allowing`, e.g. their typed title) carries itself: for the task "Read ADHD paper"
    /// the step "Skim the ADHD paper's abstract" passes, but for "Update the schedule" the
    /// step "You're behind schedule" does not (review).
    public static func trips(_ text: String, allowing own: [String] = []) -> Bool {
        let mine = own.map { words($0).joined(separator: " ") }
        let kept = words(text).joined(separator: " ")
        // Substrings, so stems catch their forms ("diagnos": "diagnosis", "streak": "streaks").
        return phrases.contains { phrase in kept.contains(phrase) && !mine.contains { $0.contains(phrase) } }
    }

    /// Lowercased words: letters and digits, split on anything else.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
