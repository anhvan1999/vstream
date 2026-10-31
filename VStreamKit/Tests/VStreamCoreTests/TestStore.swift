import Foundation
import Testing
import TestSupport
@testable import VStreamCore

/// Points `JSONStore` at a per-process temporary directory before anything reads it.
///
/// `JSONStore.directory` is resolved once, lazily, from `VSTREAM_STORE_DIR`. Every suite that
/// creates a `LibraryStore`, `LastStreamStore` or `AddonStore` calls `TestStore.prepare()` in its
/// `init`, so the override is in place before the first store touches the disk and tests never
/// write to `~/Library/Application Support/VStream`.
enum TestStore {
    static let directory: URL = {
        let url = temporaryDirectory()
        setenv("VSTREAM_STORE_DIR", url.path, 1)
        let resolved = JSONStore.directory
        precondition(
            resolved.standardizedFileURL.path == url.standardizedFileURL.path,
            "JSONStore resolved \(resolved.path) instead of the test directory; refusing to touch real data"
        )
        return url
    }()

    static func prepare() { _ = directory }

    /// A storage name no other test uses.
    static func uniqueName(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.prefix(8))" }

    static func fileURL(_ name: String) -> URL { directory.appending(path: "\(name).json") }
}

/// Polls `condition` (JSONStore writes are asynchronous) until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite struct StoreDirectoryTests {
    init() { TestStore.prepare() }

    @Test func storeDirectoryIsTheTemporaryOverride() {
        #expect(JSONStore.directory.standardizedFileURL.path == TestStore.directory.standardizedFileURL.path)
        #expect(ProcessInfo.processInfo.environment["VSTREAM_STORE_DIR"] == TestStore.directory.path)
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "VStream")
        #expect(!JSONStore.directory.path.hasPrefix(real.path))
    }

    @Test func saveThenLoadRoundTrips() async {
        let name = TestStore.uniqueName("jsonstore")
        #expect(JSONStore.load([String: Int].self, from: name) == nil)
        JSONStore.save(["a": 1, "b": 2], to: name)
        let loaded = await eventually { JSONStore.load([String: Int].self, from: name) == ["a": 1, "b": 2] }
        #expect(loaded)
        #expect(FileManager.default.fileExists(atPath: TestStore.fileURL(name).path))
    }

    @Test func loadOfUndecodableFileIsNil() throws {
        let name = TestStore.uniqueName("garbage")
        try Data("not json".utf8).write(to: TestStore.fileURL(name))
        #expect(JSONStore.load([String: Int].self, from: name) == nil)
    }
}

@Suite struct TimeoutTests {
    @Test func returnsTheOperationResult() async throws {
        let value = try await withTimeout(5) { 42 }
        #expect(value == 42)
    }

    @Test func throwsWhenTheOperationIsTooSlow() async {
        let start = ContinuousClock.now
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(0.05) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func propagatesTheOperationError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withTimeout(5) { () async throws -> Int in throw Boom() }
        }
    }
}
