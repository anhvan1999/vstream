import Foundation

/// An in-process HTTP server for tests: a `URLSession` whose requests are answered by `handler`
/// instead of the network, and which records every request it saw. Each instance is isolated
/// (requests are routed by a per-session header), so tests can run in parallel.
public final class MockHTTP: @unchecked Sendable {
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data

        public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        public static func json(_ object: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return Response(status: status, headers: ["Content-Type": "application/json"], body: data)
        }

        public static func json(string: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: Data(string.utf8))
        }
    }

    /// A request as the server received it, with its body read from the upload stream.
    public struct Request: Sendable {
        public var url: URL
        public var method: String
        public var headers: [String: String]
        public var body: Data

        public var path: String { url.path }
        public var query: [String: String] {
            Dictionary(
                (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                uniquingKeysWith: { first, _ in first }
            )
        }
        public var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        public var bodyString: String { String(decoding: body, as: UTF8.self) }
        /// `application/x-www-form-urlencoded` or multipart fields, by name.
        public var form: [String: String] {
            if headers["Content-Type"]?.hasPrefix("multipart/form-data") == true {
                var fields: [String: String] = [:]
                let pattern = #"name="([^"]+)"\r\n\r\n([\s\S]*?)\r\n--"#
                let regex = try! NSRegularExpression(pattern: pattern)
                let text = bodyString
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let name = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) {
                        fields[String(text[name])] = String(text[value])
                    }
                }
                return fields
            }
            var components = URLComponents()
            components.percentEncodedQuery = bodyString.replacingOccurrences(of: "+", with: "%20")
            return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        }
    }

    public typealias Handler = @Sendable (Request) throws -> Response

    public let session: URLSession
    private let id = UUID().uuidString
    private let lock = NSLock()
    private var recorded: [Request] = []

    public init(_ handler: @escaping Handler) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = [MockURLProtocol.header: id]
        session = URLSession(configuration: configuration)
        MockURLProtocol.register(id: id) { [weak self] request in
            self?.lock.withLock { self?.recorded.append(request) }
            return try handler(request)
        }
    }

    deinit {
        MockURLProtocol.unregister(id: id)
        session.invalidateAndCancel()
    }

    /// Every request received so far, in order.
    public var requests: [Request] { lock.withLock { recorded } }

    /// Routes by path suffix; unknown paths answer 404.
    public static func routes(_ table: [String: Response]) -> Handler {
        { request in
            table.first { request.path.hasSuffix($0.key) }?.value ?? Response(status: 404)
        }
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-Mock-HTTP"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: MockHTTP.Handler] = [:]

    static func register(id: String, handler: @escaping MockHTTP.Handler) {
        lock.withLock { handlers[id] = handler }
    }

    static func unregister(id: String) {
        lock.withLock { handlers[id] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: header) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.header),
              let handler = Self.lock.withLock({ Self.handlers[id] }),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers[Self.header] = nil
        let received = MockHTTP.Request(url: url, method: request.httpMethod ?? "GET", headers: headers, body: Self.body(of: request))
        do {
            let response = try handler(received)
            let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession moves bodies into a stream before protocols see them.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A fresh, empty directory under the system temporary directory.
public func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "VStreamKitTests-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
