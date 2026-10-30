import Foundation
import NuvioEngine

public struct TorrentSettings: Codable, Sendable, Hashable {
    public enum Profile: String, Codable, Sendable, CaseIterable { case soft, balanced, fast }

    public var profile: Profile
    public var diskCacheGB: Int
    public var uploadEnabled: Bool

    public init(profile: Profile = .balanced, diskCacheGB: Int = 5, uploadEnabled: Bool = true) {
        self.profile = profile
        self.diskCacheGB = diskCacheGB
        self.uploadEnabled = uploadEnabled
    }
}

public struct TorrentPlayback: Sendable, Hashable {
    public var url: URL
    public var streamID: String
    public var torrentID: String
    public var fileName: String
    public var fileSize: UInt64
}

public enum TorrentPhase: Sendable, Hashable {
    case startingEngine
    case fetchingMetadata
    case preparingFile(String)
    case buffering(Double)
}

public struct TorrentStats: Sendable, Hashable {
    public var downloadRate: UInt64
    public var uploadRate: UInt64
    public var peers: UInt32
    public var seeds: UInt32
    /// Contiguous bytes ready from the start of the file, 0...1.
    public var bufferProgress: Double
    public var fileProgress: Double

    public static let zero = TorrentStats(downloadRate: 0, uploadRate: 0, peers: 0, seeds: 0, bufferProgress: 0, fileProgress: 0)
}

public enum TorrentError: Error, LocalizedError, Sendable {
    case noFiles

    public var errorDescription: String? {
        switch self {
        case .noFiles: "The torrent has no playable files"
        }
    }
}

/// Where a torrent comes from: a magnet link or the bytes of a `.torrent` file.
public enum TorrentSource: Sendable, Hashable {
    case magnet(String)
    case file(Data)
}

public struct TorrentFileEntry: Sendable, Hashable, Identifiable {
    /// libtorrent's file index, as used by `fileIdx`.
    public var index: Int
    public var path: String
    public var size: UInt64

    public var id: Int { index }
    public var name: String { (path as NSString).lastPathComponent }

    public init(index: Int, path: String, size: UInt64) {
        self.index = index
        self.path = path
        self.size = size
    }

    public var isVideo: Bool {
        ["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg", "ogv"]
            .contains((path as NSString).pathExtension.lowercased())
    }
}

public struct TorrentContents: Sendable, Hashable {
    public var infoHash: String
    public var name: String?
    public var trackers: [String]
    public var files: [TorrentFileEntry]

    public init(infoHash: String, name: String?, trackers: [String], files: [TorrentFileEntry]) {
        self.infoHash = infoHash
        self.name = name
        self.trackers = trackers
        self.files = files
    }
}

/// Owns the single libtorrent engine for the app and the one active stream.
public actor TorrentStreamer {
    public static let shared = TorrentStreamer()

    private var engine: NuvioEngine?
    private var settings = TorrentSettings()
    private var current: TorrentPlayback?
    /// A torrent added only to list its files (magnet inspection), removed unless it is played.
    private var inspected: String?

    public init() {}

    public func apply(_ settings: TorrentSettings) async {
        guard settings != self.settings else { return }
        self.settings = settings
        // The engine reads its configuration at creation; restart it lazily on next use.
        if current == nil, let engine {
            await engine.shutdown()
            self.engine = nil
        }
    }

    /// Adds the magnet, waits for metadata, picks a file and returns a loopback HTTP URL for mpv.
    public func prepare(
        magnet: String,
        fileIndex: Int?,
        filenameHint: String?,
        onPhase: @Sendable (TorrentPhase) -> Void = { _ in }
    ) async throws -> TorrentPlayback {
        try await prepare(source: .magnet(magnet), fileIndex: fileIndex, filenameHint: filenameHint, onPhase: onPhase)
    }

    public func prepare(
        source: TorrentSource,
        fileIndex: Int?,
        filenameHint: String?,
        onPhase: @Sendable (TorrentPhase) -> Void = { _ in }
    ) async throws -> TorrentPlayback {
        await stop()
        onPhase(.startingEngine)
        let engine = try await engineInstance()
        onPhase(.fetchingMetadata)
        let torrentID = try await add(source, to: engine)
        if inspected == torrentID { inspected = nil }
        await removeInspected()
        do {
            let files = try await engine.files(for: torrentID)
            guard !files.isEmpty else { throw TorrentError.noFiles }
            let index = fileIndex.flatMap { index in files.contains { $0.index == UInt32(index) } ? UInt32(index) : nil }
            let name = index.flatMap { index in files.first { $0.index == index }?.path } ?? filenameHint ?? ""
            onPhase(.preparingFile((name as NSString).lastPathComponent))
            let stream = try await engine.prepareStream(
                torrentID: torrentID,
                fileIndex: index,
                filenameHint: index == nil ? filenameHint : nil
            )
            let resolvedName = files.first { $0.index == stream.fileIndex }?.path ?? name
            let playback = TorrentPlayback(
                url: stream.url,
                streamID: stream.id,
                torrentID: torrentID,
                fileName: (resolvedName as NSString).lastPathComponent,
                fileSize: stream.fileSize
            )
            current = playback
            onPhase(.buffering(0))
            return playback
        } catch {
            try? await engine.removeTorrent(torrentID)
            throw error
        }
    }

    /// Fetches a magnet's metadata to list its files. The torrent stays added (re-adding the same
    /// hash is instant) until another one is inspected or played.
    public func inspect(magnet: String) async throws -> TorrentContents {
        let engine = try await engineInstance()
        let torrentID = try await engine.addMagnet(magnet)
        if inspected != torrentID {
            await removeInspected()
            if current?.torrentID != torrentID { inspected = torrentID }
        }
        let files = try await engine.files(for: torrentID)
        let url = URL(string: magnet)
        let name = url.flatMap { URLComponents(string: "x:" + $0.absoluteString.drop { $0 != "?" })?.queryItems?.first { $0.name == "dn" }?.value }
        return TorrentContents(
            infoHash: torrentID,
            name: name,
            trackers: [],
            files: files.map { TorrentFileEntry(index: Int($0.index), path: $0.path, size: $0.size) }
        )
    }

    private func add(_ source: TorrentSource, to engine: NuvioEngine) async throws -> String {
        switch source {
        case let .magnet(magnet): try await engine.addMagnet(magnet)
        case let .file(data): try await engine.addTorrent(data)
        }
    }

    private func removeInspected() async {
        guard let inspected, let engine else { return }
        self.inspected = nil
        try? await engine.removeTorrent(inspected)
    }

    public func stop() async {
        guard let current, let engine else { return }
        self.current = nil
        try? await engine.stopStream(current.streamID)
        try? await engine.removeTorrent(current.torrentID)
    }

    public func stats() async -> TorrentStats {
        guard let engine else { return .zero }
        let engineStats = (try? await engine.currentStats()) ?? NuvioEngineStats()
        var stats = TorrentStats(
            downloadRate: engineStats.downloadRateBytesPerSecond,
            uploadRate: engineStats.uploadRateBytesPerSecond,
            peers: engineStats.connectedPeers,
            seeds: engineStats.connectedSeeds,
            bufferProgress: 0,
            fileProgress: 0
        )
        if let current, let streamStats = try? await engine.currentStreamStats(current.streamID) {
            stats.bufferProgress = streamStats.bufferProgress
            stats.fileProgress = streamStats.fileProgress
        }
        return stats
    }

    public func clearCache() async throws {
        let engine = try await engineInstance()
        try await engine.reclaimDiskCache(targetBytes: 0)
    }

    public static var version: String { NuvioEngine.version }

    private func engineInstance() async throws -> NuvioEngine {
        if let engine { return engine }
        let fileManager = FileManager.default
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "VStream/Torrent", directoryHint: .isDirectory)
        let cache = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "VStream/Torrent", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)

        let profile: NuvioTorrentProfile = switch settings.profile {
        case .soft: .soft
        case .balanced: .balanced
        case .fast: .fast
        }
        let configuration = NuvioEngineConfiguration(
            dataDirectory: support,
            cacheDirectory: cache,
            memoryCacheCapacityBytes: 128 << 20,
            diskCacheCapacityBytes: UInt64(max(settings.diskCacheGB, 1)) << 30,
            torrentProfile: profile,
            uploadMode: settings.uploadEnabled ? .unlimited : .disabled
        )
        let engine = try await NuvioEngine.create(configuration: configuration)
        self.engine = engine
        return engine
    }
}
