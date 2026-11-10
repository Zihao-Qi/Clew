import ClewCore
import ClewGateway
import SwiftUI

/// Settings › Browser: pair the Chrome extension, see paired browsers and the last
/// Watch Later import.
struct BrowserSettings: View {
    let connection: BrowserConnection

    var body: some View {
        Section {
            if let problem = connection.problem {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(connection.clients) { client in
                LabeledContent {
                    Button("Remove") { connection.remove(client) }
                        .accessibilityLabel(Text("Remove \(client.name)"))
                } label: {
                    Text(verbatim: client.name)
                    Text("Paired \(client.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                }
            }
            if let pairing = connection.pairing {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: pairing.code.prefix(3) + " " + pairing.code.suffix(3))
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel(Text("Pairing code \(pairing.code.map(String.init).joined(separator: " "))"))
                    Text("Type this code in the Clew extension's window. It works until \(pairing.expiresAt.formatted(date: .omitted, time: .shortened)).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { connection.cancelPairing() }
                }
            } else {
                Button(connection.clients.isEmpty ? "Pair Chrome…" : "Pair another browser…") {
                    connection.startPairing()
                }
            }
        } header: {
            Text("Chrome extension")
        } footer: {
            Text("The extension copies your YouTube Watch Later and X bookmarks into Clew, each as one list below your tasks. It talks only to Clew on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !connection.clients.isEmpty {
            Section {
                report(connection.youTube, site: "YouTube", open: Text("Open your Watch Later page in Chrome to import it."))
            } header: {
                Text("YouTube Watch Later")
            } footer: {
                Text("A video you remove from Watch Later counts as finished. If you didn't finish it, right-click it in the list and choose Not finished.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                report(connection.x, site: "X", open: Text("Open your Bookmarks on x.com in Chrome to import them. Bookmarking a post in Chrome adds it right away."))
            } header: {
                Text("X bookmarks")
            } footer: {
                Text("A post you unbookmark counts as read: in Chrome right away, from your phone the next time you open Bookmarks in Chrome and scroll past where it was. If you didn't read it, right-click it in the list and choose Not read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func report(_ report: ImportReport?, site: String, open: Text) -> some View {
        if let report {
            LabeledContent {
                Text(report.at, style: .relative)
            } label: {
                Text("Last import")
                Text(Self.summary(report))
            }
            if report.needsUpdate {
                Text("\(site) changed its page, so Clew couldn't read it all. Nothing was removed; the extension needs an update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            open
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// "12 on the list · 2 new · 1 let go"
    static func summary(_ r: ImportReport) -> String {
        var parts = [String(localized: "\(r.scan.parsed) read")]
        if r.result.added > 0 { parts.append(String(localized: "\(r.result.added) new")) }
        if r.result.restored > 0 { parts.append(String(localized: "\(r.result.restored) back")) }
        if r.result.letGo > 0 { parts.append(String(localized: "\(r.result.letGo) removed")) }
        return parts.joined(separator: " · ")
    }
}
