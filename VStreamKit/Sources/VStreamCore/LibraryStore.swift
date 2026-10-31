import AddonKit
import Foundation
import Observation
import StremioAPI

public struct ContinueWatchingEntry: Identifiable, Hashable, Sendable {
    public var item: LibraryItem
    /// The video to resume or start next (`nil` for movies).
    public var videoID: String?
    public var isNextUp: Bool

    public var id: String { item.id }
}

/// Local library and watch state, shaped like Stremio's so it syncs both ways.
@MainActor
@Observable
public final class LibraryStore {
    public private(set) var items: [String: LibraryItem] = [:]
    /// Watched video ids per item (episodes, or the meta id for movies).
    public private(set) var watched: [String: Set<String>] = [:]
    @ObservationIgnored public private(set) var dirty: Set<String> = []
    /// Episode order per series, in Stremio's bitfield order; known once a meta has been loaded.
    @ObservationIgnored private var videoOrder: [String: [String]] = [:]

    /// Hooks for sync layers: progress (for scrobbling) and explicit watched/library changes.
    @ObservationIgnored public var onWatched: ((LibraryItem, String) -> Void)?
    @ObservationIgnored public var onLibraryToggle: ((LibraryItem, Bool) -> Void)?

    static let completionThreshold = 0.9
    static let minimumDuration: UInt64 = 121_000

    private struct Snapshot: Codable, Sendable {
        var items: [LibraryItem]
        var watched: [String: Set<String>]
        var dirty: Set<String>
    }

    @ObservationIgnored private let storageName: String

    public init(storageName: String = "library") {
        self.storageName = storageName
        if let snapshot = JSONStore.load(Snapshot.self, from: storageName) {
            items = Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in lhs.mtime > rhs.mtime ? lhs : rhs })
            watched = snapshot.watched
            dirty = snapshot.dirty
        }
    }

    // MARK: Queries

    public var library: [LibraryItem] {
        items.values.filter(\.isInLibrary).sorted { $0.mtime > $1.mtime }
    }

    public func isInLibrary(_ id: String) -> Bool {
        items[id]?.isInLibrary ?? false
    }

    public func isWatched(itemID: String, videoID: String) -> Bool {
        watched[itemID]?.contains(videoID) ?? false
    }

    public func resumePosition(itemID: String, videoID: String) -> Double? {
        guard let item = items[itemID], item.state.videoId == videoID || (item.type == "movie" && item.state.videoId == nil),
              item.state.timeOffset > 0 else { return nil }
        return Double(item.state.timeOffset) / 1000
    }

    /// Partially watched items, plus series whose next episode is queued, newest first.
    public var continueWatching: [ContinueWatchingEntry] {
        let recent = Date().addingTimeInterval(-60 * 86_400)
        return items.values.compactMap { item -> ContinueWatchingEntry? in
            guard item.type != "other", !item.removed || item.temp else { return nil }
            if item.state.timeOffset > 0 {
                return ContinueWatchingEntry(item: item, videoID: item.state.videoId, isNextUp: false)
            }
            if item.type != "movie", let videoID = item.state.videoId, !isWatched(itemID: item.id, videoID: videoID),
               (item.state.lastWatched ?? .distantPast) > recent {
                return ContinueWatchingEntry(item: item, videoID: videoID, isNextUp: true)
            }
            return nil
        }
        .sorted { ($0.item.state.lastWatched ?? $0.item.mtime) > ($1.item.state.lastWatched ?? $1.item.mtime) }
        .prefix(30)
        .map { $0 }
    }

    // MARK: Stremio watched bitfield

    /// Learns a series' episode list, then reads Stremio's per-episode watched marks for it.
    public func registerVideos(of meta: MetaDetail) {
        guard meta.isSeriesLike else { return }
        let order = WatchedBitfield.orderedVideoIDs(meta.videos)
        videoOrder[meta.id] = order
        importStremioWatched(itemID: meta.id)
    }

    private func importStremioWatched(itemID: String) {
        guard let serialized = items[itemID]?.state.watched, let order = videoOrder[itemID] else { return }
        let remote = WatchedBitfield.decode(serialized, videoIDs: order)
        guard !remote.isSubset(of: watched[itemID] ?? []) else { return }
        watched[itemID, default: []].formUnion(remote)
        persist()
    }

    /// Writes local marks back into the item so Stremio sees them after the next sync.
    private func exportStremioWatched(_ item: inout LibraryItem) {
        guard let order = videoOrder[item.id], let encoded = WatchedBitfield.encode(watched: watched[item.id] ?? [], videoIDs: order) else { return }
        item.state.watched = encoded
    }

    // MARK: Mutations

    public func toggleLibrary(_ meta: MetaPreview) {
        var item = items[meta.id] ?? LibraryItem(meta: meta)
        let adding = !item.isInLibrary
        item.removed = !adding
        item.temp = false
        refreshPresentation(&item, from: meta)
        commit(item)
        onLibraryToggle?(item, adding)
    }

    public func removeFromContinueWatching(_ id: String) {
        guard var item = items[id] else { return }
        item.state.timeOffset = 0
        item.state.videoId = nil
        if item.temp { item.removed = true }
        commit(item)
    }

    /// Records playback progress. Call periodically (≈10 s) and on pause/stop.
    public func recordProgress(meta: MetaPreview, videoID: String, position: Double, duration: Double, nextVideoID: String?) {
        let positionMS = UInt64(max(position, 0) * 1000)
        let durationMS = UInt64(max(duration, 0) * 1000)
        guard durationMS >= Self.minimumDuration, positionMS >= 1000 else { return }

        var item = items[meta.id] ?? LibraryItem(meta: meta)
        refreshPresentation(&item, from: meta)
        let now = Date()
        // Movies keep `videoId` nil, so compare against what this call would store.
        let storedVideoID = meta.type == "movie" ? nil : videoID
        if item.state.videoId != storedVideoID {
            item.state.timeWatched = 0
        }
        let delta = positionMS > item.state.timeOffset ? min(positionMS - item.state.timeOffset, 15_000) : 0
        item.state.timeWatched += delta
        item.state.overallTimeWatched += delta
        item.state.videoId = storedVideoID
        item.state.timeOffset = positionMS
        item.state.duration = durationMS
        item.state.lastWatched = now
        if item.removed { item.temp = true }

        if Double(positionMS) / Double(durationMS) >= Self.completionThreshold {
            markCompleted(&item, videoID: videoID, nextVideoID: nextVideoID)
        }
        commit(item)
    }

    public func setWatched(meta: MetaPreview, videoID: String, _ isWatched: Bool, nextVideoID: String? = nil) {
        var item = items[meta.id] ?? LibraryItem(meta: meta)
        refreshPresentation(&item, from: meta)
        if isWatched {
            markCompleted(&item, videoID: videoID, nextVideoID: nextVideoID)
            if item.removed { item.temp = true }
        } else {
            watched[item.id]?.remove(videoID)
            if meta.type == "movie" { item.state.flaggedWatched = 0 }
            exportStremioWatched(&item)
        }
        commit(item)
    }

    /// Bulk import (e.g. from Trakt) without triggering outbound sync hooks.
    public func importWatched(_ entries: [String: Set<String>]) {
        for (id, videos) in entries {
            watched[id, default: []].formUnion(videos)
        }
        persist()
    }

    /// Merges server items: newer `mtime` wins. Returns ids that should be pushed back.
    public func merge(remote: [LibraryItem]) {
        for item in remote {
            if let local = items[item.id], local.mtime >= item.mtime { continue }
            items[item.id] = item
            dirty.remove(item.id)
            if item.state.flaggedWatched > 0 || item.state.timesWatched > 0, item.type == "movie" {
                watched[item.id, default: []].insert(item.id)
            }
            if let serialized = item.state.watched, let order = videoOrder[item.id] {
                watched[item.id, default: []].formUnion(WatchedBitfield.decode(serialized, videoIDs: order))
            }
        }
        persist()
    }

    public func takeDirty() -> [LibraryItem] {
        dirty.compactMap { items[$0] }.filter(\.shouldSync)
    }

    public func markClean(_ ids: some Sequence<String>) {
        dirty.subtract(ids)
        persist()
    }

    public func reset() {
        items = [:]
        watched = [:]
        dirty = []
        persist()
    }

    // MARK: Private

    private func markCompleted(_ item: inout LibraryItem, videoID: String, nextVideoID: String?) {
        let alreadyWatched = isWatched(itemID: item.id, videoID: videoID)
        watched[item.id, default: []].insert(videoID)
        item.state.timesWatched += alreadyWatched ? 0 : 1
        item.state.timeOffset = 0
        item.state.lastWatched = Date()
        if item.type == "movie" {
            item.state.flaggedWatched = 1
            item.state.videoId = nil
        } else {
            item.state.videoId = nextVideoID
            item.state.duration = 0
            item.state.timeWatched = 0
        }
        exportStremioWatched(&item)
        if !alreadyWatched { onWatched?(item, videoID) }
    }

    private func refreshPresentation(_ item: inout LibraryItem, from meta: MetaPreview) {
        if !meta.name.isEmpty { item.name = meta.name }
        if let poster = meta.poster { item.poster = poster }
        item.posterShape = meta.posterShape
    }

    private func commit(_ item: LibraryItem) {
        var item = item
        item.mtime = Date()
        items[item.id] = item
        dirty.insert(item.id)
        persist()
    }

    private func persist() {
        JSONStore.save(Snapshot(items: Array(items.values), watched: watched, dirty: dirty), to: storageName)
    }
}

public enum NextEpisode {
    /// The released episode following `videoID`, skipping specials.
    public static func after(_ videoID: String, in meta: MetaDetail) -> Video? {
        let episodes = meta.videos.filter { ($0.season ?? 1) != 0 }
        guard let index = episodes.firstIndex(where: { $0.id == videoID }), index + 1 < episodes.count else { return nil }
        let next = episodes[index + 1]
        return next.isReleased ? next : nil
    }

    /// First unwatched released episode, for "Play" on a series page.
    public static func firstUnwatched(in meta: MetaDetail, watched: Set<String>) -> Video? {
        meta.videos.filter { ($0.season ?? 1) != 0 && $0.isReleased }.first { !watched.contains($0.id) }
    }
}
