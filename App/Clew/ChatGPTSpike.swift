#if DEBUG
import AppKit
import CryptoKit
import Foundation
import Network

/// `CLEW_CHATGPT_SPIKE=1` (2026-11-22, user): can Clew, sandboxed, use the person's ChatGPT
/// plan through OpenAI's "Sign in with ChatGPT" for open-source, locally run apps
/// (developers.openai.com/siwc/token-sharing-open-source)? Signs in through the browser
/// (PKCE, a loopback callback on 127.0.0.1:1455), checks the plan permission was granted,
/// lists the models, and asks one question as a stream. Tokens stay in memory and are never
/// printed; only the issued client id and this Mac's host id are kept (not secrets).
/// A spike: no ID-token signature check yet, no refresh, no Keychain.
enum ChatGPTSpike {
    static let authorize = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let token = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let api = "https://api.openai.com/v1"
    static let redirect = "http://127.0.0.1:1455/auth/callback"
    @MainActor static let defaults = UserDefaults(suiteName: "clew-chatgpt-spike")!
    /// No cache, no cookies (review).
    static let session = URLSession(configuration: .ephemeral)

    static func start() {
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                print("FAIL:", error)
                exit(1)
            }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func random(_ n: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return base64url(Data(bytes))
    }

    @MainActor
    static func run() async throws {
        // This Mac's host id, chosen once and kept (not a credential).
        let hostId = defaults.string(forKey: "hostId") ?? "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(hostId, forKey: "hostId")
        let savedClient = defaults.string(forKey: "clientId")

        let verifier = random(), state = random(16), nonce = random(16)
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var q = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: savedClient ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: hostId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            URLQueryItem(name: "resource", value: api),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        if savedClient == nil { items.append(URLQueryItem(name: "agent_name_hint", value: "Clew")) }
        q.queryItems = items

        let callback = try await waitForCallback {
            print("Opening the browser to sign in with ChatGPT…"); fflush(stdout)
            NSWorkspace.shared.open(q.url!)
        }
        guard callback["error"] == nil else { throw Failure("sign-in refused: \(callback["error"]!)") }
        guard callback["state"] == state else { throw Failure("state does not match") }
        guard let code = callback["code"] else { throw Failure("no code in the callback") }
        if let issued = callback["client_id"] {
            if let savedClient, savedClient != issued { throw Failure("issued client id differs from the saved one") }
            defaults.set(issued, forKey: "clientId")
        }
        guard let clientId = defaults.string(forKey: "clientId") else { throw Failure("no issued client id") }
        print("PASS signed in; client id issued to Clew:", clientId.prefix(10) + "…")

        // Code for tokens (form-encoded; no client secret).
        var exchange = URLRequest(url: token)
        exchange.httpMethod = "POST"
        exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        exchange.httpBody = form(["grant_type": "authorization_code", "client_id": clientId, "code": code,
                                  "code_verifier": verifier, "redirect_uri": redirect, "resource": api])
        let (tokenData, tokenResponse) = try await session.data(for: exchange)
        guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200,
              let tokens = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let access = tokens["access_token"] as? String else {
            // Only the status: the body may hold tokens (review).
            throw Failure("token exchange: HTTP \((tokenResponse as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let scopes = (tokens["scope"] as? String ?? "").split(separator: " ").map(String.init)
        print(scopes.contains("chatgpt.tokens.use.direct") ? "PASS" : "FAIL", "plan permission granted; scopes:",
              scopes.sorted().joined(separator: " "), "| access token lasts", tokens["expires_in"] ?? "?", "s")
        guard scopes.contains("chatgpt.tokens.use.direct") else { throw Failure("no plan permission") }

        // The models this plan can use.
        var models = URLRequest(url: URL(string: api + "/models")!)
        models.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (modelData, modelResponse) = try await session.data(for: models)
        let listed = ((try? JSONSerialization.jsonObject(with: modelData) as? [String: Any])?["models"] as? [[String: Any]] ?? [])
            .filter { $0["visibility"] as? String == "list" }
        let slugs = listed.compactMap { $0["slug"] as? String }
        print(slugs.isEmpty ? "FAIL" : "PASS", "models (HTTP \((modelResponse as? HTTPURLResponse)?.statusCode ?? 0)):",
              slugs.joined(separator: ", "))
        guard let model = ProcessInfo.processInfo.environment["CLEW_CHATGPT_MODEL"] ?? slugs.first else {
            throw Failure("no model: " + (String(data: modelData, encoding: .utf8)?.prefix(300).description ?? ""))
        }

        // One question, streamed.
        var ask = URLRequest(url: URL(string: api + "/responses")!)
        ask.httpMethod = "POST"
        ask.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        ask.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ask.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": "You help someone with ADHD start a task. Reply with a JSON array of 3 to 5 short steps "
                + "(each under 60 characters). The first step takes about 2 minutes. No other text.",
            "input": [["role": "user", "content": "Task: Prepare the talk"]],
            "store": false,
            "stream": true,
        ])
        let started = Date()
        let (bytes, askResponse) = try await session.bytes(for: ask)
        let status = (askResponse as? HTTPURLResponse)?.statusCode ?? 0
        var text = "", outcome = "ended without completion", raw = ""
        for try await line in bytes.lines {
            if status != 200 { raw += line; continue }
            guard line.hasPrefix("data: "), let data = line.dropFirst(6).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta": text += event["delta"] as? String ?? ""
            case "response.completed": outcome = "completed"
            case "response.failed":
                let error = ((event["response"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
                outcome = "failed: \(error ?? "no code")"
            case "response.incomplete": outcome = "incomplete"
            default: break
            }
        }
        guard status == 200 else { throw Failure("responses: HTTP \(status) \(raw.prefix(300))") }
        print(outcome == "completed" ? "PASS" : "FAIL", "model \(model), \(outcome) in",
              String(format: "%.1f s", Date().timeIntervalSince(started)))
        print("REPLY:", text)
        let steps = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String]
        print(steps.map { (3...5).contains($0.count) } == true ? "PASS" : "FAIL", "the reply is 3–5 steps as JSON")
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    /// Resumes the wait once, whichever comes first: the callback, a failure or the timeout.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let listener: NWListener
        private let continuation: CheckedContinuation<[String: String], Error>
        init(listener: NWListener, continuation: CheckedContinuation<[String: String], Error>) {
            self.listener = listener
            self.continuation = continuation
        }
        func finish(_ result: Result<[String: String], Error>) {
            let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
            guard first else { return }
            listener.cancel()
            continuation.resume(with: result)
        }
    }

    /// Listens on 127.0.0.1:1455 for the browser's callback, then answers it.
    @MainActor
    static func waitForCallback(_ open: @escaping @Sendable @MainActor () -> Void) async throws -> [String: String] {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 1455)
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(listener: listener, continuation: continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: Task { @MainActor in open() }
                case .failed(let error): once.finish(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    guard target.hasPrefix("/auth/callback"), let parts = URLComponents(string: "http://x" + target) else {
                        connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    let body = "<html><body style='font-family:-apple-system'><h3>Clew is signed in. You can close this tab.</h3></body></html>"
                    connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8),
                                    completion: .contentProcessed { _ in connection.cancel() })
                    var values: [String: String] = [:]
                    for item in parts.queryItems ?? [] { values[item.name] = item.value ?? "" }
                    once.finish(.success(values))
                }
            }
            listener.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { once.finish(.failure(Failure("no sign-in within 5 minutes"))) }
        }
    }
}
#endif
