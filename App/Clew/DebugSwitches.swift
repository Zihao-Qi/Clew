#if DEBUG
import Foundation

/// Every `CLEW_*` switch a Debug build knows. Any other stops it at launch: a build
/// that failed leaves the last app in place, and that older app, given a switch it
/// does not know, would start as the real Clew on this Mac's data (2026-11-24, it
/// did). `scripts/lint.py` checks every switch named in the code and scripts is here.
enum DebugSwitches {
    static let known: Set<String> = [
        "CLEW_AI_CHECK", "CLEW_AI_RENDER", "CLEW_CLICK_TEST", "CLEW_DROP_TEST", "CLEW_EVENT_TEST",
        "CLEW_EVENTKIT_UNDO_SOURCE", "CLEW_EVENTKIT_UNDO_TEST", "CLEW_FETCH_TITLE", "CLEW_GATEWAY_TEST",
        "CLEW_NEWTASK_TEST", "CLEW_NOTES_RENDER", "CLEW_NOTES_TEST", "CLEW_RECONCILE_TEST",
        "CLEW_RENDER_PNG", "CLEW_RESTORE_TEST", "CLEW_SCREEN_HEIGHT", "CLEW_SCROLL_TEST",
        "CLEW_SHORTCUT_SMOKE", "CLEW_STEPS_AI", "CLEW_STEPS_RENDER", "CLEW_STEPS_TEST", "CLEW_TIME_TEST",
    ]

    /// The build and release scripts' own settings, never read by the app: a shell that
    /// exports one still launches it.
    static let buildSettings: Set<String> = [
        "CLEW_CODE_SIGN_IDENTITY", "CLEW_DERIVED_DATA_PATH", "CLEW_INSTALL_DIR", "CLEW_KEYCHAIN",
        "CLEW_SIGNING_P12", "CLEW_SIGNING_P12_PASSWORD", "CLEW_VERSION",
    ]

    /// Exits (code 64) if the environment names a switch this build does not know.
    static func refuseUnknown(_ environment: [String: String] = ProcessInfo.processInfo.environment) {
        let unknown = environment.keys.filter {
            $0.hasPrefix("CLEW_") && !known.contains($0) && !buildSettings.contains($0)
        }.sorted()
        guard !unknown.isEmpty else { return }
        print("FAIL: this build does not know \(unknown.joined(separator: ", ")) (an older build?); not starting")
        fflush(stdout)
        exit(64)
    }
}
#endif
