import AddonKit
import Foundation
import StremioAPI
import Testing
@testable import VStreamCore

@MainActor
@Suite struct LibraryStoreTests {
    let movie = MetaPreview(id: "tt0816692", type: "movie", name: "Interstellar", poster: URL(string: "https://img.example/interstellar.jpg"))
    let series = MetaPreview(id: "tt0903747", type: "series", name: "Breaking Bad")

    init() { TestStore.prepare() }

    private func makeStore() -> (LibraryStore, String) {
        let name = TestStore.uniqueName("library")
        return (LibraryStore(storageName: name), name)
    }

    private func episode(_ season: Int, _ number: Int, released: Date? = Date(timeIntervalSince1970: 1_200_000_000)) -> Video {
        Video(id: "\(series.id):\(season):\(number)", title: "S\(season)E\(number)", released: released, season: season, episode: number)
    }

    private func seriesDetail() -> MetaDetail {
        MetaDetail(preview: series, videos: [episode(1, 1), episode(1, 2), episode(1, 3)])
    }

    // MARK: recordProgress

    @Test func clipsShorterThanMinimumDurationAreIgnored() {
        let (library, _) = makeStore()
        library.recordProgress(meta: movie, videoID: movie.id, position: 60, duration: 120, nextVideoID: nil)
        #expect(library.items.isEmpty)
        #expect(library.dirty.isEmpty)
        library.recordProgress(meta: movie, videoID: movie.id, position: 60, duration: 120.9, nextVideoID: nil)
        #expect(library.items.isEmpty)
    }

    @Test func positionsUnderOneSecondAreIgnored() {
        let (library, _) = makeStore()
        library.recordProgress(meta: movie, videoID: movie.id, position: 0.5, duration: 121, nextVideoID: nil)
        library.recordProgress(meta: movie, videoID: movie.id, position: -10, duration: 5_000, nextVideoID: nil)
        #expect(library.items.isEmpty)
    }

    @Test func minimumDurationIsRecorded() throws {
        let (library, _) = makeStore()
        library.recordProgress(meta: movie, videoID: movie.id, position: 10, duration: 121, nextVideoID: nil)
        let item = try #require(library.items[movie.id])
        #expect(item.state.timeOffset == 10_000)
        #expect(item.state.duration == 121_000)
        #expect(item.state.videoId == nil, "movies store no video id")
        #expect(item.temp && item.removed, "watching alone does not add to the library")
        #expect(!library.isInLibrary(movie.id))
        #expect(item.name == "Interstellar")
        #expect(item.poster == movie.poster)
        #expect(item.state.lastWatched != nil)
        #expect(library.dirty == [movie.id])
        #expect(library.resumePosition(itemID: movie.id, videoID: movie.id) == 10)
    }

    @Test func eightyNinePercentIsNotWatched() {
        let (library, _) = makeStore()
        library.recordProgress(meta: movie, videoID: movie.id, position: 899, duration: 1_000, nextVideoID: nil)
        #expect(!library.isWatched(itemID: movie.id, videoID: movie.id))
        #expect(library.continueWatching.map(\.id) == [movie.id])
    }

    @Test func ninetyPercentMarksMovieWatchedOnce() throws {
        let (library, _) = makeStore()
        var events: [String] = []
        library.onWatched = { _, videoID in events.append(videoID) }
        library.recordProgress(meta: movie, videoID: movie.id, position: 900, duration: 1_000, nextVideoID: nil)
        var item = try #require(library.items[movie.id])
        #expect(library.isWatched(itemID: movie.id, videoID: movie.id))
        #expect(item.state.flaggedWatched == 1)
        #expect(item.state.timesWatched == 1)
        #expect(item.state.timeOffset == 0)
        #expect(item.state.videoId == nil)
        #expect(library.continueWatching.isEmpty)
        #expect(library.resumePosition(itemID: movie.id, videoID: movie.id) == nil)

        library.recordProgress(meta: movie, videoID: movie.id, position: 990, duration: 1_000, nextVideoID: nil)
        item = try #require(library.items[movie.id])
        #expect(item.state.timesWatched == 1, "already watched: not counted again")
        #expect(events == [movie.id])
    }

    @Test func watchTimeAccumulatesInBoundedSteps() throws {
        let (library, _) = makeStore()
        library.recordProgress(meta: movie, videoID: movie.id, position: 10, duration: 5_000, nextVideoID: nil)
        library.recordProgress(meta: movie, videoID: movie.id, position: 100, duration: 5_000, nextVideoID: nil)
        var state = try #require(library.items[movie.id]).state
        #expect(state.overallTimeWatched == 25_000, "10 s, then a jump capped at 15 s")
        #expect(state.timeWatched == 25_000)
        
        library.recordProgress(meta: movie, videoID: movie.id, position: 50, duration: 5_000, nextVideoID: nil)
        state = try #require(library.items[movie.id]).state
        #expect(state.overallTimeWatched == 25_000, "seeking back adds nothing")
        #expect(state.timeOffset == 50_000)

        // Episodes keep their video id, so their current watch time does accumulate.
        let videoID = "\(series.id):1:1"
        library.recordProgress(meta: series, videoID: videoID, position: 10, duration: 3_000, nextVideoID: nil)
        library.recordProgress(meta: series, videoID: videoID, position: 100, duration: 3_000, nextVideoID: nil)
        #expect(try #require(library.items[series.id]).state.timeWatched == 25_000)
    }

    @Test func switchingEpisodesResetsCurrentWatchTime() throws {
        let (library, _) = makeStore()
        library.recordProgress(meta: series, videoID: "\(series.id):1:1", position: 100, duration: 3_000, nextVideoID: nil)
        library.recordProgress(meta: series, videoID: "\(series.id):1:2", position: 10, duration: 3_000, nextVideoID: nil)
        let state = try #require(library.items[series.id]).state
        #expect(state.videoId == "\(series.id):1:2")
        #expect(state.timeWatched == 0)
        #expect(state.overallTimeWatched == 15_000)
        #expect(library.resumePosition(itemID: series.id, videoID: "\(series.id):1:2") == 10)
        #expect(library.resumePosition(itemID: series.id, videoID: "\(series.id):1:1") == nil)
        #expect(library.resumePosition(itemID: "unknown", videoID: "x") == nil)
    }

    @Test func libraryItemStaysInLibraryWhileWatching() throws {
        let (library, _) = makeStore()
        library.toggleLibrary(movie)
        library.recordProgress(meta: movie, videoID: movie.id, position: 600, duration: 6_000, nextVideoID: nil)
        let item = try #require(library.items[movie.id])
        #expect(!item.temp && !item.removed)
        #expect(library.isInLibrary(movie.id))
    }

    // MARK: Continue watching

    @Test func continueWatchingIsNewestFirst() {
        let (library, _) = makeStore()
        library.recordProgress(meta: movie, videoID: movie.id, position: 600, duration: 6_000, nextVideoID: nil)
        library.recordProgress(meta: series, videoID: "\(series.id):1:1", position: 300, duration: 3_000, nextVideoID: nil)
        #expect(library.continueWatching.map(\.id) == [series.id, movie.id])
        #expect(library.continueWatching.first?.videoID == "\(series.id):1:1")
        #expect(library.continueWatching.allSatisfy { !$0.isNextUp })

        library.recordProgress(meta: movie, videoID: movie.id, position: 700, duration: 6_000, nextVideoID: nil)
        #expect(library.continueWatching.map(\.id) == [movie.id, series.id])
        #expect(library.continueWatching.first?.videoID == nil)
    }

    @Test func finishedEpisodeQueuesNextUpUntilItIsWatched() throws {
        let (library, _) = makeStore()
        library.recordProgress(meta: series, videoID: "\(series.id):1:1", position: 2_950, duration: 3_000, nextVideoID: "\(series.id):1:2")
        let entry = try #require(library.continueWatching.first)
        #expect(entry.isNextUp)
        #expect(entry.videoID == "\(series.id):1:2")
        let state = try #require(library.items[series.id]).state
        #expect(state.duration == 0)
        #expect(state.timeWatched == 0)
        #expect(state.timesWatched == 1)

        library.importWatched([series.id: ["\(series.id):1:2"]])
        #expect(library.continueWatching.isEmpty, "next episode already watched")
    }

    @Test func finishedLastEpisodeLeavesContinueWatching() {
        let (library, _) = makeStore()
        library.recordProgress(meta: series, videoID: "\(series.id):1:3", position: 2_950, duration: 3_000, nextVideoID: nil)
        #expect(library.isWatched(itemID: series.id, videoID: "\(series.id):1:3"))
        #expect(library.continueWatching.isEmpty)
    }

    @Test func continueWatchingFiltersStaleAndHiddenItems() {
        let (library, _) = makeStore()
        func item(_ id: String, type: String = "series", removed: Bool = false, temp: Bool = false, offset: UInt64 = 0, videoID: String? = nil, daysAgo: Double) -> LibraryItem {
            var item = LibraryItem(meta: MetaPreview(id: id, type: type, name: id), now: Date(timeIntervalSince1970: 1_000))
            item.removed = removed
            item.temp = temp
            item.state.timeOffset = offset
            item.state.videoId = videoID
            item.state.lastWatched = Date().addingTimeInterval(-daysAgo * 86_400)
            return item
        }
        library.merge(remote: [
            item("stale-next-up", videoID: "stale-next-up:1:2", daysAgo: 61),
            item("recent-next-up", videoID: "recent-next-up:1:2", daysAgo: 1),
            item("other", type: "other", offset: 5_000, daysAgo: 0.5),
            item("removed", removed: true, offset: 5_000, daysAgo: 0.4),
            item("removed-temp", removed: true, temp: true, offset: 5_000, daysAgo: 0.3),
            item("movie-no-progress", type: "movie", daysAgo: 0.2),
        ])
        let entries = library.continueWatching
        #expect(entries.map(\.id) == ["removed-temp", "recent-next-up"])
        #expect(entries.map(\.isNextUp) == [false, true])
    }

    @Test func continueWatchingIsCappedAtThirty() {
        let (library, _) = makeStore()
        for index in 0..<35 {
            let meta = MetaPreview(id: "tt\(index)", type: "movie", name: "Movie \(index)")
            library.recordProgress(meta: meta, videoID: meta.id, position: 600, duration: 6_000, nextVideoID: nil)
        }
        let entries = library.continueWatching
        #expect(entries.count == 30)
        #expect(entries.first?.id == "tt34")
        #expect(!entries.contains { $0.id == "tt0" })
    }

    @Test func removeFromContinueWatching() throws {
        let (library, _) = makeStore()
        library.recordProgress(meta: movie, videoID: movie.id, position: 600, duration: 6_000, nextVideoID: nil)
        library.toggleLibrary(series)
        library.recordProgress(meta: series, videoID: "\(series.id):1:1", position: 300, duration: 3_000, nextVideoID: nil)
        #expect(library.continueWatching.count == 2)

        library.removeFromContinueWatching(movie.id)
        let removed = try #require(library.items[movie.id])
        #expect(removed.state.timeOffset == 0)
        #expect(removed.state.videoId == nil)
        #expect(removed.removed, "temp items are dropped")

        library.removeFromContinueWatching(series.id)
        #expect(library.isInLibrary(series.id), "library items stay in the library")
        #expect(library.continueWatching.isEmpty)

        let before = library.items
        library.removeFromContinueWatching("missing")
        #expect(library.items == before)
    }

    // MARK: Library

    @Test func toggleLibraryAddsAndRemoves() throws {
        let (library, _) = makeStore()
        var toggles: [(String, Bool)] = []
        library.onLibraryToggle = { item, added in toggles.append((item.id, added)) }

        library.toggleLibrary(movie)
        #expect(library.isInLibrary(movie.id))
        library.toggleLibrary(series)
        #expect(library.library.map(\.id) == [series.id, movie.id], "newest first")

        let renamed = MetaPreview(id: movie.id, type: "movie", name: "Interstellar (2014)", poster: URL(string: "https://img.example/new.jpg"), posterShape: .landscape)
        library.toggleLibrary(renamed)
        #expect(!library.isInLibrary(movie.id))
        let item = try #require(library.items[movie.id])
        #expect(item.removed && !item.temp)
        #expect(item.name == "Interstellar (2014)")
        #expect(item.poster == URL(string: "https://img.example/new.jpg"))
        #expect(item.posterShape == .landscape)
        #expect(library.library.map(\.id) == [series.id])

        #expect(toggles.map(\.0) == [movie.id, series.id, movie.id])
        #expect(toggles.map(\.1) == [true, true, false])
    }

    @Test func toggleLibraryPromotesWatchHistory() throws {
        let (library, _) = makeStore()
        library.recordProgress(meta: movie, videoID: movie.id, position: 600, duration: 6_000, nextVideoID: nil)
        #expect(library.items[movie.id]?.temp == true)
        library.toggleLibrary(MetaPreview(id: movie.id, type: "movie", name: ""))
        let item = try #require(library.items[movie.id])
        #expect(item.isInLibrary)
        #expect(item.name == "Interstellar", "an empty name doesn't overwrite")
        #expect(item.state.timeOffset == 600_000, "progress is kept")
    }

    // MARK: Watched

    @Test func setWatchedForMovies() throws {
        let (library, _) = makeStore()
        var events = 0
        library.onWatched = { _, _ in events += 1 }
        library.setWatched(meta: movie, videoID: movie.id, true)
        #expect(library.isWatched(itemID: movie.id, videoID: movie.id))
        #expect(library.items[movie.id]?.state.flaggedWatched == 1)
        #expect(library.items[movie.id]?.temp == true)
        library.setWatched(meta: movie, videoID: movie.id, false)
        #expect(!library.isWatched(itemID: movie.id, videoID: movie.id))
        #expect(library.items[movie.id]?.state.flaggedWatched == 0)
        #expect(events == 1)
    }

    @Test func setWatchedForEpisodesQueuesNext() throws {
        let (library, _) = makeStore()
        library.setWatched(meta: series, videoID: "\(series.id):1:1", true, nextVideoID: "\(series.id):1:2")
        #expect(library.continueWatching.first?.videoID == "\(series.id):1:2")
        #expect(library.continueWatching.first?.isNextUp == true)
        library.setWatched(meta: series, videoID: "\(series.id):1:1", false)
        #expect(!library.isWatched(itemID: series.id, videoID: "\(series.id):1:1"))
    }

    @Test func importWatchedDoesNotCallHooks() {
        let (library, _) = makeStore()
        var events = 0
        library.onWatched = { _, _ in events += 1 }
        library.importWatched([series.id: ["a", "b"], movie.id: [movie.id]])
        library.importWatched([series.id: ["c"]])
        #expect(library.watched[series.id] == ["a", "b", "c"])
        #expect(library.isWatched(itemID: movie.id, videoID: movie.id))
        #expect(events == 0)
        #expect(library.items.isEmpty)
        #expect(library.dirty.isEmpty)
    }

    // MARK: Stremio watched bitfield

    @Test func registerVideosImportsStremioBitfield() throws {
        let (library, _) = makeStore()
        let detail = seriesDetail()
        let order = WatchedBitfield.orderedVideoIDs(detail.videos)
        let encoded = try #require(WatchedBitfield.encode(watched: [order[0], order[1]], videoIDs: order))
        var remote = LibraryItem(meta: series, now: Date())
        remote.removed = false
        remote.temp = false
        remote.state.watched = encoded
        library.merge(remote: [remote])
        #expect(!library.isWatched(itemID: series.id, videoID: order[0]), "order unknown until the meta is loaded")

        library.registerVideos(of: detail)
        #expect(library.watched[series.id] == [order[0], order[1]])
        #expect(!library.isWatched(itemID: series.id, videoID: order[2]))

        // Merging again once the order is known decodes immediately.
        var newer = remote
        newer.mtime = Date().addingTimeInterval(60)
        newer.state.watched = try #require(WatchedBitfield.encode(watched: Set(order), videoIDs: order))
        library.merge(remote: [newer])
        #expect(library.watched[series.id] == Set(order))
    }

    @Test func registerVideosIgnoresMoviesAndItemsWithoutBitfield() {
        let (library, _) = makeStore()
        library.registerVideos(of: MetaDetail(preview: movie))
        library.registerVideos(of: seriesDetail())
        #expect(library.watched.isEmpty)
    }

    @Test func localMarksAreExportedToTheBitfield() throws {
        let (library, _) = makeStore()
        let detail = seriesDetail()
        let order = WatchedBitfield.orderedVideoIDs(detail.videos)
        library.registerVideos(of: detail)
        library.recordProgress(meta: series, videoID: order[0], position: 2_950, duration: 3_000, nextVideoID: order[1])
        let serialized = try #require(library.items[series.id]?.state.watched)
        #expect(serialized == WatchedBitfield.encode(watched: [order[0]], videoIDs: order))
        #expect(WatchedBitfield.decode(serialized, videoIDs: order) == [order[0]])

        library.setWatched(meta: series, videoID: order[0], false)
        let cleared = try #require(library.items[series.id]?.state.watched)
        #expect(WatchedBitfield.decode(cleared, videoIDs: order).isEmpty)
    }

    // MARK: Merge & dirty tracking

    @Test func mergeAppliesNewerRemoteItems() throws {
        let (library, _) = makeStore()
        library.toggleLibrary(movie)
        #expect(library.dirty == [movie.id])

        var older = LibraryItem(meta: movie, now: Date(timeIntervalSince1970: 0))
        older.name = "Old"
        library.merge(remote: [older])
        #expect(library.items[movie.id]?.name == "Interstellar")
        #expect(library.dirty == [movie.id], "ignored remote items stay dirty")

        var newer = older
        newer.mtime = Date().addingTimeInterval(60)
        newer.state.timesWatched = 1
        library.merge(remote: [newer])
        #expect(library.items[movie.id]?.name == "Old")
        #expect(library.isWatched(itemID: movie.id, videoID: movie.id), "watched movies come from timesWatched")
        #expect(library.dirty.isEmpty)
    }

    @Test func dirtyTrackingAndSyncFilter() throws {
        let (library, _) = makeStore()
        library.toggleLibrary(movie)
        library.recordProgress(meta: series, videoID: "\(series.id):1:1", position: 300, duration: 3_000, nextVideoID: nil)

        var ancient = LibraryItem(meta: MetaPreview(id: "tt-old", type: "movie", name: "Old"), now: Date(timeIntervalSince1970: 0))
        ancient.state.lastWatched = Date().addingTimeInterval(-400 * 86_400)
        ancient.state.timeOffset = 10
        library.merge(remote: [ancient])
        library.removeFromContinueWatching("tt-old")
        #expect(library.dirty == [movie.id, series.id, "tt-old"])

        let pending = library.takeDirty()
        #expect(Set(pending.map(\.id)) == [movie.id, series.id], "items not in the library or watched within a year aren't synced")

        library.markClean([movie.id])
        #expect(library.dirty == [series.id, "tt-old"])
        library.markClean(library.dirty)
        #expect(library.takeDirty().isEmpty)
    }

    @Test func resetClearsEverything() {
        let (library, _) = makeStore()
        library.toggleLibrary(movie)
        library.importWatched([movie.id: [movie.id]])
        library.reset()
        #expect(library.items.isEmpty)
        #expect(library.watched.isEmpty)
        #expect(library.dirty.isEmpty)
    }

    // MARK: Persistence

    @Test func snapshotRoundTripsThroughASecondInstance() async throws {
        let (library, name) = makeStore()
        library.toggleLibrary(movie)
        library.recordProgress(meta: series, videoID: "\(series.id):1:2", position: 300, duration: 3_000, nextVideoID: nil)
        library.importWatched([series.id: ["\(series.id):1:1"]])
        library.markClean([movie.id])

        var reloaded = LibraryStore(storageName: name)
        let persisted = await eventually {
            reloaded = LibraryStore(storageName: name)
            return reloaded.items.count == 2 && reloaded.watched == library.watched && reloaded.dirty == library.dirty
        }
        #expect(persisted)
        #expect(reloaded.isInLibrary(movie.id))
        #expect(reloaded.dirty == [series.id])
        #expect(reloaded.resumePosition(itemID: series.id, videoID: "\(series.id):1:2") == 300)
        #expect(reloaded.isWatched(itemID: series.id, videoID: "\(series.id):1:1"))
        #expect(reloaded.items[series.id]?.name == "Breaking Bad")
        #expect(reloaded.continueWatching.map(\.id) == [series.id])
    }

    @Test func differentStorageNamesAreIndependent() async {
        let (library, name) = makeStore()
        library.toggleLibrary(movie)
        _ = await eventually { LibraryStore(storageName: name).isInLibrary(movie.id) }
        #expect(LibraryStore(storageName: TestStore.uniqueName("library")).items.isEmpty)
    }

    @Test func corruptSnapshotLoadsEmpty() throws {
        let name = TestStore.uniqueName("library")
        try Data("{\"items\": 3}".utf8).write(to: TestStore.fileURL(name))
        let library = LibraryStore(storageName: name)
        #expect(library.items.isEmpty)
        #expect(library.watched.isEmpty)
    }
}

@Suite struct NextEpisodeTests {
    let past = Date(timeIntervalSince1970: 1_200_000_000)
    let future = Date().addingTimeInterval(30 * 86_400)

    func meta(_ videos: [Video]) -> MetaDetail {
        MetaDetail(preview: MetaPreview(id: "tt1", type: "series", name: "Show"), videos: videos)
    }

    var videos: [Video] {
        [
            Video(id: "tt1:0:1", title: "Special", released: past, season: 0, episode: 1),
            Video(id: "tt1:1:1", title: "One", released: past, season: 1, episode: 1),
            Video(id: "tt1:1:2", title: "Two", released: nil, season: 1, episode: 2),
            Video(id: "tt1:1:3", title: "Three", released: future, season: 1, episode: 3),
        ]
    }

    @Test func afterReturnsFollowingReleasedEpisode() {
        let detail = meta(videos)
        #expect(NextEpisode.after("tt1:1:1", in: detail)?.id == "tt1:1:2", "no release date counts as released")
        #expect(NextEpisode.after("tt1:1:2", in: detail) == nil, "next one isn't out yet")
        #expect(NextEpisode.after("tt1:1:3", in: detail) == nil, "last episode")
        #expect(NextEpisode.after("tt1:0:1", in: detail) == nil, "specials are skipped")
        #expect(NextEpisode.after("missing", in: detail) == nil)
    }

    @Test func videosWithoutSeasonCountAsRegularEpisodes() {
        let detail = meta([
            Video(id: "a", title: "A", released: past),
            Video(id: "b", title: "B", released: past),
        ])
        #expect(NextEpisode.after("a", in: detail)?.id == "b")
        #expect(NextEpisode.firstUnwatched(in: detail, watched: [])?.id == "a")
    }

    @Test func firstUnwatchedSkipsSpecialsWatchedAndUnreleased() {
        let detail = meta(videos)
        #expect(NextEpisode.firstUnwatched(in: detail, watched: [])?.id == "tt1:1:1")
        #expect(NextEpisode.firstUnwatched(in: detail, watched: ["tt1:1:1"])?.id == "tt1:1:2")
        #expect(NextEpisode.firstUnwatched(in: detail, watched: ["tt1:1:1", "tt1:1:2"]) == nil)
        #expect(NextEpisode.firstUnwatched(in: meta([]), watched: []) == nil)
    }
}

@Suite struct EpisodeContextTests {
    @Test(arguments: [
        ("tt0903747:2:5", 2, 5),
        ("kitsu:1:3:4", 3, 4),
        ("tt1:0:12", 0, 12),
    ])
    func parsesSeasonAndEpisode(videoID: String, season: Int, episode: Int) {
        #expect(EpisodeContext(videoID: videoID) == EpisodeContext(season: season, episode: episode))
    }

    @Test(arguments: ["tt0816692", "tt1:2", "tt1:a:b", "tt1:1:x", "", "::"])
    func otherIDsHaveNoEpisode(videoID: String) {
        let context = EpisodeContext(videoID: videoID)
        #expect(context.season == nil)
        #expect(context.episode == nil)
    }
}
