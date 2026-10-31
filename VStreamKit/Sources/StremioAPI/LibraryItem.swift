import AddonKit
import Foundation

/// Mirrors `stremio-core/src/types/library/library_item.rs` so items round-trip with the Stremio API.
public struct LibraryItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var type: String
    public var poster: URL?
    public var posterShape: PosterShape
    public var removed: Bool
    /// Temporary items are created by just watching something; they are not shown in the library.
    public var temp: Bool
    public var ctime: Date?
    public var mtime: Date
    public var state: LibraryItemState
    public var behaviorHints: JSONValue?

    public init(meta: MetaPreview, now: Date = Date()) {
        id = meta.id
        name = meta.name
        type = meta.type
        poster = meta.poster
        posterShape = meta.posterShape
        removed = true
        temp = true
        ctime = now
        mtime = now
        state = LibraryItemState()
    }

    enum CodingKeys: String, CodingKey {
        case id = "_id", name, type, poster, posterShape, removed, temp, ctime = "_ctime", mtime = "_mtime", state, behaviorHints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        type = try container.decode(String.self, forKey: .type)
        poster = (try? container.decodeIfPresent(String.self, forKey: .poster)).flatMap { $0.flatMap(URL.init(string:)) }
        posterShape = (try? container.decodeIfPresent(PosterShape.self, forKey: .posterShape)) ?? .poster
        removed = (try? container.decode(Bool.self, forKey: .removed)) ?? false
        temp = (try? container.decode(Bool.self, forKey: .temp)) ?? false
        ctime = StremioAPIDate.parse(try? container.decodeIfPresent(String.self, forKey: .ctime))
        mtime = StremioAPIDate.parse(try? container.decodeIfPresent(String.self, forKey: .mtime)) ?? .distantPast
        state = (try? container.decode(LibraryItemState.self, forKey: .state)) ?? LibraryItemState()
        behaviorHints = try? container.decodeIfPresent(JSONValue.self, forKey: .behaviorHints)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(poster?.absoluteString ?? "", forKey: .poster)
        try container.encode(posterShape, forKey: .posterShape)
        try container.encode(removed, forKey: .removed)
        try container.encode(temp, forKey: .temp)
        try container.encodeIfPresent(ctime.map(StremioAPIDate.format), forKey: .ctime)
        try container.encode(StremioAPIDate.format(mtime), forKey: .mtime)
        try container.encode(state, forKey: .state)
        try container.encode(behaviorHints ?? .object([:]), forKey: .behaviorHints)
    }

    /// In the user's visible library (not just watch history).
    public var isInLibrary: Bool { !removed && !temp }

    public var progress: Double {
        guard state.duration > 0 else { return 0 }
        return min(Double(state.timeOffset) / Double(state.duration), 1)
    }

    /// Same rule as stremio-core: synced items must be in the library or watched within the last year.
    public var shouldSync: Bool {
        isInLibrary || (state.lastWatched ?? .distantPast) > Date().addingTimeInterval(-365 * 86_400)
    }
}

public struct LibraryItemState: Codable, Sendable, Hashable {
    public var lastWatched: Date?
    /// Milliseconds watched in the current video.
    public var timeWatched: UInt64
    /// Playback position in milliseconds.
    public var timeOffset: UInt64
    public var overallTimeWatched: UInt64
    public var timesWatched: UInt32
    public var flaggedWatched: UInt32
    /// Duration of the current video in milliseconds.
    public var duration: UInt64
    public var videoId: String?
    /// Stremio's compressed watched bitfield; preserved opaquely.
    public var watched: String?
    public var noNotif: Bool

    public init() {
        timeWatched = 0
        timeOffset = 0
        overallTimeWatched = 0
        timesWatched = 0
        flaggedWatched = 0
        duration = 0
        noNotif = false
    }

    enum CodingKeys: String, CodingKey {
        case lastWatched, timeWatched, timeOffset, overallTimeWatched, timesWatched, flaggedWatched, duration
        case videoId = "video_id", watched, noNotif
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func number<T: FixedWidthInteger & Decodable>(_ key: CodingKeys) -> T {
            if let value = try? container.decode(T.self, forKey: key) { return value }
            // Clamp before converting: Int64(_:) traps on doubles past its range (e.g. 1e20).
            if let value = try? container.decode(Double.self, forKey: key), value >= 0 {
                return value >= Double(Int64.max) ? T.max : T(clamping: Int64(value))
            }
            return 0
        }
        lastWatched = StremioAPIDate.parse(try? container.decodeIfPresent(String.self, forKey: .lastWatched))
        timeWatched = number(.timeWatched)
        timeOffset = number(.timeOffset)
        overallTimeWatched = number(.overallTimeWatched)
        timesWatched = number(.timesWatched)
        flaggedWatched = number(.flaggedWatched)
        duration = number(.duration)
        videoId = (try? container.decodeIfPresent(String.self, forKey: .videoId)).flatMap { $0?.isEmpty == false ? $0 : nil }
        watched = (try? container.decodeIfPresent(String.self, forKey: .watched)).flatMap { $0?.isEmpty == false ? $0 : nil }
        noNotif = (try? container.decode(Bool.self, forKey: .noNotif)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(lastWatched.map(StremioAPIDate.format), forKey: .lastWatched)
        try container.encode(timeWatched, forKey: .timeWatched)
        try container.encode(timeOffset, forKey: .timeOffset)
        try container.encode(overallTimeWatched, forKey: .overallTimeWatched)
        try container.encode(timesWatched, forKey: .timesWatched)
        try container.encode(flaggedWatched, forKey: .flaggedWatched)
        try container.encode(duration, forKey: .duration)
        try container.encode(videoId ?? "", forKey: .videoId)
        try container.encode(watched ?? "", forKey: .watched)
        try container.encode(noNotif, forKey: .noNotif)
    }
}

enum StremioAPIDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    private static let lock = NSLock()

    static func parse(_ string: String??) -> Date? {
        guard let string = string ?? nil, !string.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: string) ?? plain.date(from: string)
    }

    static func format(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractional.string(from: date)
    }
}
