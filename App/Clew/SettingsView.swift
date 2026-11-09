import AppKit
import ClewCore
import ClewDomain
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
    @State private var summaries = SummarySettings.defaults

    var body: some View {
        Form {
            Section {
                // An explicit closure, not `set: setOpenAtLogin`: Swift 6.3 crashes generating the
                // isolated thunk for the method reference.
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
                if let loginMessage {
                    HStack {
                        Text(loginMessage).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                    }
                }
            }

            Section {
                summaryRow(Text("Morning"), enabled: \.morningEnabled, time: \.morningTime)
                summaryRow(Text("Evening"), enabled: \.eveningEnabled, time: \.eveningTime)
                if model.notificationsDenied {
                    NotificationsOffNotice()
                }
            } header: {
                Text("Summaries")
            } footer: {
                Text("Morning: how many are on today's list. Evening: how many are done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        // A menu bar app shows no window at launch, so macOS must not restore this one
        // if it was open when Clew quit.
        .background(NonRestorableWindow())
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
    }

    private func summaryRow(_ label: Text, enabled: WritableKeyPath<SummarySettings, Bool>,
                            time: WritableKeyPath<SummarySettings, TimeOfDay>) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { summaries[keyPath: enabled] }, set: { on in
                summaries[keyPath: enabled] = on
                model.setSummaries(summaries)
            })) { label }
            Spacer()
            DatePicker(selection: Binding(get: { summaries[keyPath: time].pickerDate }, set: { date in
                summaries[keyPath: time] = TimeOfDay(pickerDate: date)
                model.setSummaries(summaries)
            }), displayedComponents: .hourAndMinute) { label }
                .labelsHidden()
                .fixedSize()
                .disabled(!summaries[keyPath: enabled])
                .accessibilityLabel(Text("Time"))
        }
    }

    private func reload() {
        summaries = model.summaries()
        model.checkNotificationPermission()
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

/// Marks its hosting window as not restorable (works on macOS 14, unlike the macOS 15
/// `restorationBehavior` scene modifier).
private struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isRestorable = false
        }
    }
}
