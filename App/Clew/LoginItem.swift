import AppKit
import ServiceManagement

/// Launch at login (SPEC §9). Adapted from Tact's LoginItem, without its one-time
/// default: Clew starts with it off and only the user turns it on.
/// `SMAppService` is the source of truth; nothing is stored.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns nil on success, or one sentence saying what to do instead.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
                if needsApproval {
                    return String(localized: "Allow Clew in System Settings › General › Login Items.")
                }
            } else {
                guard SMAppService.mainApp.status != .notRegistered else { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return enabled
                ? String(localized: "Clew couldn't add itself. Add it in System Settings › General › Login Items.")
                : String(localized: "Clew couldn't remove itself. Remove it in System Settings › General › Login Items.")
        }
    }

    static func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
