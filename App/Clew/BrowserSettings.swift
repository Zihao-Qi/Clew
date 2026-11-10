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
            Text("The extension adds the videos in your YouTube Watch Later to the Later pile. It talks only to Clew on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !connection.clients.isEmpty {
            Section {
                if let report = connection.youTube {
                    LabeledContent {
                        Text(report.at, style: .relative)
                    } label: {
                        Text("Last import")
                        Text(Self.summary(report))
                    }
                    if report.needsUpdate {
                        Text("YouTube changed its page, so Clew couldn't read it all. Nothing was removed; the extension needs an update.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Open your Watch Later page in Chrome to import it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("YouTube Watch Later")
            } footer: {
                Text("Videos you remove from Watch Later leave the Later pile too, unless you picked or finished them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
