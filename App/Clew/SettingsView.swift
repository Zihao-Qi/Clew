import AppKit
import ClewCore
import SwiftUI
import UniformTypeIdentifiers

/// The small Settings window (SPEC §9): launch at login, active days ("done means
/// used", shown only here), and one-click export.
struct SettingsView: View {
    static let windowID = "settings"
    let model: AppModel

    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginMessage: String?
    @State private var activeDays: ActiveDays?
    @State private var exportMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                if let loginMessage {
                    HStack {
                        Text(loginMessage).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                    }
                }
            }

            Section {
                LabeledContent {
                    if let days = activeDays {
                        Text("\(days.last7) of the last 7 · \(days.last14) of the last 14")
                            .monospacedDigit()
                    }
                } label: {
                    Text("Active days")
                }
            } footer: {
                Text("A day with at least one tick.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Export…", action: export)
                    if let exportMessage {
                        Text(exportMessage).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Everything Clew stores, as one JSON file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
    }

    private func reload() {
        openAtLogin = LoginItem.isEnabled
        if LoginItem.needsApproval {
            loginMessage = String(localized: "Allow Clew in System Settings › General › Login Items.")
        }
        activeDays = model.activeDays()
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginMessage = LoginItem.setEnabled(on)
        openAtLogin = LoginItem.isEnabled
    }

    private func export() {
        guard let data = model.exportData() else {
            exportMessage = String(localized: "Export failed. Try again.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Clew \(model.today?.day.description ?? "export").json"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            exportMessage = String(localized: "Saved.")
        } catch {
            exportMessage = String(localized: "Export failed. Try again.")
        }
    }
}
