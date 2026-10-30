import AddonKit
import Foundation
import Observation

/// The stream last played for each title, so Continue Watching resumes it directly instead of
/// asking for a stream again. Kept locally (Stremio's LibraryItem has no field for it).
public struct LastStream: Codable, Sendable, Hashable {
    public var videoID: String
    public var stream: AddonStream
    public var playedAt: Date
}

@MainActor
@Observable
public final class LastStreamStore {
    private var entries: [String: LastStream]
    @ObservationIgnored private let storageName: String
    /// Plenty for Continue Watching; older titles fall back to picking a stream.
    private static let limit = 200

    public init(storageName: String = "last-streams") {
        self.storageName = storageName
        entries = JSONStore.load([String: LastStream].self, from: storageName) ?? [:]
    }

    public func stream(for itemID: String) -> LastStream? { entries[itemID] }

    public func remember(itemID: String, videoID: String, stream: AddonStream) {
        entries[itemID] = LastStream(videoID: videoID, stream: stream, playedAt: Date())
        if entries.count > Self.limit {
            let oldest = entries.sorted { $0.value.playedAt < $1.value.playedAt }.prefix(entries.count - Self.limit)
            for (id, _) in oldest { entries[id] = nil }
        }
        JSONStore.save(entries, to: storageName)
    }

    public func forget(itemID: String) {
        guard entries.removeValue(forKey: itemID) != nil else { return }
        JSONStore.save(entries, to: storageName)
    }
}
