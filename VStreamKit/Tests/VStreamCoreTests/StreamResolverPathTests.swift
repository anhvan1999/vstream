import AddonKit
import DebridKit
import Foundation
import Network
import Testing
@testable import VStreamCore

/// A debrid provider whose answers are scripted per test; records what it was asked.
private final class ScriptedDebrid: DebridProvider, @unchecked Sendable {
    let service: DebridService
    private let resolver: @Sendable (DebridRequest) async throws -> DebridLink
    private let downloadError: (any Error)?
    private let lock = NSLock()
    private var _requests: [DebridRequest] = []
    private var _downloads: [String] = []

    init(_ service: DebridService = .realDebrid, downloadError: (any Error)? = nil, resolve: @escaping @Sendable (DebridRequest) async throws -> DebridLink) {
        self.service = service
        self.downloadError = downloadError
        resolver = resolve
    }

    var requests: [DebridRequest] { lock.withLock { _requests } }
    var downloads: [String] { lock.withLock { _downloads } }

    func validate() async throws -> Bool { true }
    func cachedHashes(_ hashes: [String]) async throws -> Set<String>? { nil }
    func resolve(_ request: DebridRequest) async throws -> DebridLink {
        lock.withLock { _requests.append(request) }
        return try await resolver(request)
    }
    func startDownload(_ request: DebridRequest) async throws {
        lock.withLock { _downloads.append(request.infoHash) }
        if let downloadError { throw downloadError }
    }
}

private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _phases: [ResolvePhase] = []
    var phases: [ResolvePhase] { lock.withLock { _phases } }
    var callback: @Sendable (ResolvePhase) -> Void { { [self] phase in lock.withLock { _phases.append(phase) } } }
}

/// A tiny HTTP/1.1 server on 127.0.0.1 for `AddonDebridLink.probe`, which uses its own session.
private final class LoopbackHTTPServer: @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = ""
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "vstream.tests.loopback")
    private let lock = NSLock()
    private var _seen: [(path: String, headers: [String: String])] = []
    private let handler: @Sendable (String, URL) -> Reply
    private(set) var baseURL = URL(string: "http://127.0.0.1")!

    var seen: [(path: String, headers: [String: String])] { lock.withLock { _seen } }

    init(_ handler: @escaping @Sendable (_ path: String, _ base: URL) -> Reply) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }
        let resumed = NSLock()
        nonisolated(unsafe) var done = false
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                resumed.withLock {
                    guard !done else { return }
                    switch state {
                    case .ready:
                        done = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case let .failed(error):
                        done = true
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
        }
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil { connection.cancel() } else { receive(connection, buffer: buffer) }
                return
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            lock.withLock { _seen.append((path, headers)) }
            let reply = handler(path, baseURL)
            var head = "HTTP/1.1 \(reply.status) Test\r\nContent-Length: \(reply.body.utf8.count)\r\nConnection: close\r\n"
            for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
            connection.send(content: Data((head + "\r\n" + reply.body).utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Suite struct StreamResolverPathTests {
    let hash = "abcdef0123456789abcdef0123456789abcdef01"
    var torrent: AddonStream {
        AddonStream(infoHash: hash, fileIdx: 4, sources: ["tracker:udp://tracker.example:80"], behaviorHints: .init(filename: "Show.S01E02.mkv"))
    }

    // MARK: Direct and external

    @Test func directURLPassesFilenameHint() async throws {
        let stream = AddonStream(url: URL(string: "https://cdn.example/v.mkv")!, behaviorHints: .init(filename: "v.mkv"))
        guard case let .play(playback) = try await StreamResolver(debrid: nil, mode: .debridOnly).resolve(stream, context: .init()) else {
            Issue.record("expected play"); return
        }
        #expect(playback == ResolvedPlayback(url: URL(string: "https://cdn.example/v.mkv")!, headers: [:], source: .direct, filename: "v.mkv"))
    }

    @Test func externalURLOpensExternally() async throws {
        let url = URL(string: "https://www.netflix.com/title/80057281")!
        guard case let .openExternally(opened) = try await StreamResolver(debrid: nil, mode: .automatic).resolve(AddonStream(externalUrl: url), context: .init()) else {
            Issue.record("expected external"); return
        }
        #expect(opened == url)
    }

    @Test func youtubeWinsOverExternalURL() async throws {
        let stream = AddonStream(ytId: "abc123", externalUrl: URL(string: "https://example.com")!)
        guard case let .openExternally(opened) = try await StreamResolver(debrid: nil, mode: .automatic).resolve(stream, context: .init()) else {
            Issue.record("expected external"); return
        }
        #expect(opened == URL(string: "https://www.youtube.com/watch?v=abc123"))
    }

    @Test func emptyStreamIsUnplayable() async {
        let error = await #expect(throws: ResolveError.self) {
            try await StreamResolver(debrid: nil, mode: .automatic).resolve(AddonStream(name: "nothing"), context: .init())
        }
        guard case .unplayable? = error else { Issue.record("expected unplayable"); return }
    }

    // MARK: Debrid for torrents

    @Test func debridRequestCarriesStreamAndEpisode() async throws {
        let link = DebridLink(url: URL(string: "https://rd.example/dl/Show.S01E02.mkv")!, filename: "Show.S01E02.mkv", size: 10)
        let debrid = ScriptedDebrid { _ in link }
        let log = PhaseLog()
        let outcome = try await StreamResolver(debrid: debrid, mode: .debridOnly)
            .resolve(torrent, context: EpisodeContext(videoID: "tt1:1:2"), onPhase: log.callback)
        guard case let .play(playback) = outcome else { Issue.record("expected play"); return }
        #expect(playback == ResolvedPlayback(url: link.url, headers: [:], source: .debrid(.realDebrid), filename: "Show.S01E02.mkv"))
        #expect(log.phases == [.resolvingDebrid(.realDebrid)])

        let request = try #require(debrid.requests.first)
        #expect(request.infoHash == hash)
        #expect(request.fileIndex == 4)
        #expect(request.filename == "Show.S01E02.mkv")
        #expect(request.season == 1)
        #expect(request.episode == 2)
        #expect(request.magnet == torrent.magnetURI)
        #expect(request.magnet.contains("tracker.example"))
    }

    @Test func debridOnlySurfacesProviderErrors() async {
        let debrid = ScriptedDebrid { _ in throw DebridError.api("account suspended") }
        let log = PhaseLog()
        let error = await #expect(throws: DebridError.self) {
            try await StreamResolver(debrid: debrid, mode: .debridOnly, addsUncachedToDebrid: true).resolve(torrent, context: .init(), onPhase: log.callback)
        }
        guard case let .api(message)? = error else { Issue.record("expected api error"); return }
        #expect(message == "account suspended")
        #expect(debrid.downloads.isEmpty, "only uncached torrents are queued")
        #expect(log.phases == [.resolvingDebrid(.realDebrid)])
    }

    @Test func debridOnlyQueuesUncachedAndReportsIt() async {
        let debrid = ScriptedDebrid(.premiumize) { _ in throw DebridError.notCached }
        let error = await #expect(throws: ResolveError.self) {
            try await StreamResolver(debrid: debrid, mode: .debridOnly, addsUncachedToDebrid: true).resolve(torrent, context: .init())
        }
        guard case let .queuedOnDebrid(service)? = error else { Issue.record("expected queuedOnDebrid"); return }
        #expect(service == .premiumize)
        #expect(debrid.downloads == [hash])
    }

    @Test func debridOnlyQueueFailureIsReported() async {
        let debrid = ScriptedDebrid(downloadError: DebridError.http(503)) { _ in throw DebridError.notCached }
        let error = await #expect(throws: DebridError.self) {
            try await StreamResolver(debrid: debrid, mode: .debridOnly, addsUncachedToDebrid: true).resolve(torrent, context: .init())
        }
        guard case let .http(status)? = error else { Issue.record("expected http error"); return }
        #expect(status == 503)
    }

    @Test func automaticModeDoesNotSwallowCancellation() async {
        let debrid = ScriptedDebrid { _ in throw CancellationError() }
        let log = PhaseLog()
        await #expect(throws: CancellationError.self) {
            try await StreamResolver(debrid: debrid, mode: .automatic).resolve(torrent, context: .init(), onPhase: log.callback)
        }
        #expect(log.phases == [.resolvingDebrid(.realDebrid)], "no fallback to peer-to-peer once cancelled")
    }

    @Test func errorDescriptions() {
        #expect(ResolveError.unplayable.errorDescription == "This stream has nothing playable")
        #expect(ResolveError.debridRequired.errorDescription?.contains("debrid") == true)
        #expect(ResolveError.queuedOnDebrid(.torbox).errorDescription?.contains("TorBox") == true)
        #expect(ResolveError.addonDebridFailed(.realDebrid).errorDescription?.contains("Real-Debrid") == true)
    }

    // MARK: Addon debrid links

    @Test(arguments: [
        ("torbox", DebridService.torbox),
        ("TorBox", .torbox),
        ("realdebrid", .realDebrid),
        ("real-debrid", .realDebrid),
        ("premiumize", .premiumize),
    ])
    func addonDebridLinkServices(name: String, service: DebridService) throws {
        let url = URL(string: "https://torrentio.strem.fun/resolve/\(name)/KEY/\(hash.uppercased())/Show/2/Show.S01E02.mkv")!
        let link = try #require(AddonDebridLink(url))
        #expect(link.service == service)
        #expect(link.url == url)
        #expect(link.infoHash == hash)
        #expect(link.fileIndex == 2)
        #expect(link.filename == "Show.S01E02.mkv")
    }

    @Test func addonDebridLinkOptionalParts() throws {
        let short = try #require(AddonDebridLink(URL(string: "https://addon.example/resolve/torbox/KEY/\(hash)")!))
        #expect(short.fileIndex == nil)
        #expect(short.filename == nil)
        let noFile = try #require(AddonDebridLink(URL(string: "https://addon.example/prefix/config/resolve/torbox/KEY/\(hash)/name/x")!))
        #expect(noFile.fileIndex == nil, "non-numeric index")
        #expect(noFile.filename == nil)
    }

    @Test(arguments: [
        "https://addon.example/resolve/alldebrid/KEY/abcdef0123456789abcdef0123456789abcdef01/n/1/f.mkv",
        "https://addon.example/resolve/torbox/KEY/abcdef0123456789abcdef0123456789abcdef0/n/1/f.mkv",
        "https://addon.example/resolve/torbox/KEY/zzzzzz0123456789abcdef0123456789abcdef01/n/1/f.mkv",
        "https://addon.example/resolve/torbox/KEY",
        "https://addon.example/stream/torbox/KEY/abcdef0123456789abcdef0123456789abcdef01",
    ])
    func notAddonDebridLinks(text: String) {
        #expect(AddonDebridLink(URL(string: text)!) == nil)
    }

    @Test func probeFollowsRedirectsAndRejectsPlaceholders() async throws {
        let server = try LoopbackHTTPServer { path, base in
            switch path {
            case let path where path.hasPrefix("/resolve/torbox/"): .init(status: 302, headers: ["Location": base.appending(path: "cdn/Show.S01E02.mkv").absoluteString])
            case "/cdn/Show.S01E02.mkv": .init(status: 206, body: "ab")
            case let path where path.hasPrefix("/resolve/realdebrid/"): .init(status: 302, headers: ["Location": base.appending(path: "videos/failed_infringement_v2.mp4").absoluteString])
            case let path where path.hasPrefix("/resolve/premiumize/"): .init(status: 302, headers: ["Location": base.appending(path: "videos/downloading_v2.mp4").absoluteString])
            case "/videos/failed_infringement_v2.mp4", "/videos/downloading_v2.mp4": .init(status: 200, body: "placeholder")
            default: .init(status: 500)
            }
        }
        try await server.start()
        defer { server.stop() }
        func link(_ service: String) throws -> AddonDebridLink {
            try #require(AddonDebridLink(server.baseURL.appending(path: "resolve/\(service)/KEY/\(hash)/Show/2/Show.S01E02.mkv")))
        }

        guard case let .playable(final) = await (try link("torbox")).probe(headers: ["X-Token": "secret"], timeout: 5) else {
            Issue.record("expected playable"); return
        }
        #expect(final.path == "/cdn/Show.S01E02.mkv")
        let first = try #require(server.seen.first)
        #expect(first.headers["range"] == "bytes=0-1")
        #expect(first.headers["x-token"] == "secret")

        guard case .failed = await (try link("realdebrid")).probe(headers: [:], timeout: 5) else { Issue.record("failed_ placeholder should fail"); return }
        guard case .failed = await (try link("premiumize")).probe(headers: [:], timeout: 5) else { Issue.record("downloading placeholder should fail"); return }
        let broken = try #require(AddonDebridLink(server.baseURL.appending(path: "x/resolve/torbox/KEY/\(hash)")))
        guard case .failed = await broken.probe(headers: [:], timeout: 5) else { Issue.record("HTTP 500 should fail"); return }
    }

    @Test func probeOfUnreachableHostFails() async throws {
        let link = try #require(AddonDebridLink(URL(string: "http://127.0.0.1:9/resolve/torbox/KEY/\(hash)/n/1/f.mkv")!))
        guard case .failed = await link.probe(headers: [:], timeout: 3) else { Issue.record("expected failed"); return }
    }

    @Test func addonDebridLinkPlaysThroughResolver() async throws {
        let server = try LoopbackHTTPServer { path, base in
            path.hasPrefix("/resolve/") ? .init(status: 302, headers: ["Location": base.appending(path: "cdn/file.mkv").absoluteString]) : .init(status: 200, body: "ok")
        }
        try await server.start()
        defer { server.stop() }
        let url = server.baseURL.appending(path: "resolve/torbox/KEY/\(hash)/Show/2/Show.S01E02.mkv")
        let stream = AddonStream(url: url, behaviorHints: .init(requestHeaders: ["User-Agent": "VStream"]))
        let log = PhaseLog()
        for mode in [TorrentMode.automatic, .debridOnly] {
            guard case let .play(playback) = try await StreamResolver(debrid: nil, mode: mode).resolve(stream, context: .init(), onPhase: log.callback) else {
                Issue.record("expected play"); return
            }
            #expect(playback.source == .debrid(.torbox))
            #expect(playback.url.path == "/cdn/file.mkv")
            #expect(playback.headers == ["User-Agent": "VStream"])
            #expect(playback.filename == "Show.S01E02.mkv", "falls back to the link's filename")
        }
        #expect(log.phases == [.resolvingDebrid(.torbox), .resolvingDebrid(.torbox)])
        #expect(server.seen.first?.headers["user-agent"] == "VStream")
    }

    @Test func failedAddonDebridLinkInDebridOnlyMode() async throws {
        let stream = AddonStream(
            url: URL(string: "http://127.0.0.1:9/resolve/realdebrid/KEY/\(hash)/n/1/f.mkv")!,
            behaviorHints: .init(filename: "hint.mkv")
        )
        let error = await #expect(throws: ResolveError.self) {
            try await StreamResolver(debrid: nil, mode: .debridOnly).resolve(stream, context: .init())
        }
        guard case let .addonDebridFailed(service)? = error else { Issue.record("expected addonDebridFailed"); return }
        #expect(service == .realDebrid)
    }
}
