import Foundation
import Network

public enum LoopbackError: Error, LocalizedError, Sendable {
    case portUnavailable(UInt16)
    case timedOut
    case denied(String)

    public var errorDescription: String? {
        switch self {
        case let .portUnavailable(port): "Port \(port) is in use, so the browser sign-in can't receive Trakt's reply. Use the device code instead."
        case .timedOut: "Trakt sign-in timed out"
        case let .denied(reason): "Trakt sign-in failed: \(reason)"
        }
    }
}

/// One-shot HTTP server on the loopback interface that captures an OAuth redirect.
/// Only loopback connections are accepted, so nothing is exposed to the local network.
final class LoopbackRedirectServer: @unchecked Sendable {
    private let port: UInt16
    private let path: String
    private let queue = DispatchQueue(label: "vstream.trakt.loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?

    init(port: UInt16, path: String) {
        self.port = port
        self.path = path
    }

    /// Starts listening; throws if the port can't be bound.
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: port) else { throw LoopbackError.portUnavailable(self.port) }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw LoopbackError.portUnavailable(self.port)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { return ready.resume(throwing: CancellationError()) }
                self.readyContinuation = ready
                listener.stateUpdateHandler = { [weak self] state in
                    // Runs on `queue`.
                    guard let self, let ready = self.readyContinuation else { return }
                    switch state {
                    case .ready:
                        self.readyContinuation = nil
                        ready.resume()
                    case .failed, .waiting:
                        self.readyContinuation = nil
                        listener.cancel()
                        ready.resume(throwing: LoopbackError.portUnavailable(self.port))
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
    }

    /// Waits for the redirect and returns its query parameters.
    func waitForCallback(timeout: Duration = .seconds(300)) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.queue.async { self.continuation = continuation }
                    }
                } onCancel: {
                    self.finish(.failure(CancellationError()))
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LoopbackError.timedOut
            }
            defer {
                group.cancelAll()
                stop()
            }
            return try await group.next()!
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        queue.async {
            guard let continuation = self.continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://localhost\(target)")
            guard components?.path == self.path else {
                self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            let succeeded = query["code"] != nil
            self.respond(
                connection,
                status: "200 OK",
                body: succeeded
                    ? "<h2>VStream is connected to Trakt.</h2><p>You can close this tab and return to the app.</p>"
                    : "<h2>Trakt sign-in was not completed.</h2><p>You can close this tab.</p>"
            )
            self.finish(.success(query))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><title>VStream</title><body style=\"font:16px -apple-system;text-align:center;padding-top:15vh\">\(body)</body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
