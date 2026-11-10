import ClewCore
import ClewDomain
import ClewGateway
import Foundation
import Observation
import Security

/// Paired clients in the login Keychain (ARCHITECTURE §6), one item holding them all,
/// so they never reach the database, its backups or an export.
struct KeychainCredentials: CredentialStore {
    static let service = "io.github.zihao-qi.clew.gateway"
    /// The debug check uses its own account and removes it afterwards.
    var account = "paired-clients"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func remove() { SecItemDelete(query as CFDictionary) }

    func load() throws -> [PairedClient] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode([PairedClient].self, from: data)
    }

    func save(_ clients: [PairedClient]) throws {
        let data = try JSONEncoder().encode(clients)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Clew browser connection"
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    struct KeychainError: Error { let status: OSStatus }
}

/// The Chrome extension's connection, for Settings › Browser: pairing, paired
/// browsers, and the last Watch Later import. The listener runs only while a browser
/// is paired or a pairing code is shown.
@MainActor @Observable
final class BrowserConnection {
    /// The extension's fixed ID (its manifest `key`), the only Origin allowed.
    nonisolated static let extensionOrigin = "chrome-extension://jonldjbmjcdehoffcnkeobpapjkoebga"

    private(set) var clients: [PairedClient] = []
    private(set) var pairing: (code: String, expiresAt: Date)?
    private(set) var youTube: ImportReport?
    private(set) var x: ImportReport?
    private(set) var port: UInt16?
    /// Set when Clew could not listen (all ports taken) or read the Keychain.
    private(set) var problem: String?

    @ObservationIgnored private var gateway: Gateway?
    @ObservationIgnored private var listener: GatewayListener?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    init(clew: Clew) {
        do {
            gateway = try Gateway(clew: clew, credentials: KeychainCredentials(),
                                  allowedOrigins: [Self.extensionOrigin],
                                  onChange: { [weak self] in Task { @MainActor in self?.sync() } })
        } catch {
            problem = String(localized: "Clew couldn't read its browser pairing from the Keychain.")
        }
        sync()
    }

    /// Around a restore: the Gateway answers "busy" while the database is closed.
    func use(_ clew: Clew?) { gateway?.use(clew) }

    func startPairing() {
        guard let gateway else { return }
        gateway.startPairing()
        sync()
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Gateway.pairingLifetime + 1))
            self?.sync()
        }
    }

    func cancelPairing() {
        gateway?.cancelPairing()
        sync()
    }

    func remove(_ client: PairedClient) {
        do { try gateway?.revoke(client.id) } catch {
            problem = String(localized: "Clew couldn't update the Keychain.")
        }
        sync()
    }

    /// Reads the Gateway's state and starts or stops the listener to match.
    private func sync() {
        guard let gateway else { return }
        clients = gateway.clients
        pairing = gateway.pendingPairing
        youTube = gateway.lastImport(from: .extensionYouTube)
        x = gateway.lastImport(from: .extensionX)
        let wanted = !clients.isEmpty || pairing != nil
        if wanted, listener == nil {
            let listener = GatewayListener(gateway: gateway)
            self.listener = listener
            Task { [weak self] in
                do {
                    let port = try await listener.start()
                    self?.port = port
                    self?.problem = nil
                } catch {
                    self?.listener = nil
                    self?.problem = String(localized: "Clew couldn't open its browser connection: ports 39271–39275 are in use.")
                }
            }
        } else if !wanted, let listener {
            listener.stop()
            self.listener = nil
            port = nil
        }
    }
}
