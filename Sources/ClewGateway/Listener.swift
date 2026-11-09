#if canImport(Network) && canImport(CryptoKit)
import Foundation
import Network

/// Serves a `Gateway` on `127.0.0.1` only, on the first free port of `Gateway.ports`.
/// One request per connection; a connection that has not sent a full request within
/// 10 seconds is closed.
public final class GatewayListener: @unchecked Sendable {
    public enum Failure: Error, Equatable { case noFreePort }

    private let gateway: Gateway
    private let queue = DispatchQueue(label: "io.github.zihao-qi.clew.gateway")
    private let ports: [UInt16]
    private var listener: NWListener?
    private var activity: (any NSObjectProtocol)?
    static let requestTimeout: TimeInterval = 10

    public init(gateway: Gateway, ports: ClosedRange<UInt16> = Gateway.ports) {
        self.gateway = gateway
        self.ports = Array(ports)
    }

    /// Starts listening and returns the port.
    @discardableResult
    public func start() async throws -> UInt16 {
        for port in ports {
            if let listener = await bind(port) {
                queue.sync {
                    self.listener = listener
                    // The extension can't wake Clew; keep App Nap from delaying replies
                    // while the listener is up (ARCHITECTURE §6).
                    self.activity = ProcessInfo.processInfo.beginActivity(
                        options: .userInitiatedAllowingIdleSystemSleep, reason: "Clew browser connection")
                }
                gateway.listening(on: port)
                return port
            }
        }
        throw Failure.noFreePort
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
    }

    private func bind(_ port: UInt16) async -> NWListener? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = false
        guard let listener = try? NWListener(using: parameters) else { return nil }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return await withCheckedContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: listener) }
                case .failed, .cancelled:
                    listener.cancel()
                    once.run { continuation.resume(returning: nil) }
                case .waiting:
                    // Port in use shows up as waiting on some systems: give up on it.
                    listener.cancel()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                self.respond(connection, self.gateway.handle(request))
            case .invalid(let status):
                self.respond(connection, HTTPResponse(status: status))
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
            }
        }
    }

    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
#endif
