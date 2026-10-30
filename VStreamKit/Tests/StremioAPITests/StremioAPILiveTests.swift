import AddonKit
import Foundation
import Testing
@testable import StremioAPI

/// Hits the real api.strem.io. Runs only when `STREMIO_EMAIL` and `STREMIO_PASSWORD` are set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STREMIO_EMAIL"] != nil))
struct StremioAPILiveTests {
    let api = StremioAPIClient()

    @Test func loginAddonsAndLibrary() async throws {
        let env = ProcessInfo.processInfo.environment
        let session = try await api.login(email: env["STREMIO_EMAIL"]!, password: env["STREMIO_PASSWORD"]!)
        #expect(!session.authKey.isEmpty)
        #expect(session.user.email.lowercased() == env["STREMIO_EMAIL"]!.lowercased())

        let collection = try await api.addonCollection(authKey: session.authKey)
        print("addons (\(collection.addons.count)):")
        for addon in collection.addons {
            let resources = Set(addon.manifest.resources.map(\.name)).sorted().joined(separator: ",")
            print("  - \(addon.manifest.name) [\(resources)] \(addon.transportUrl.host ?? "")")
        }
        #expect(!collection.addons.isEmpty)

        // Round-trip: re-encoding descriptors must keep the manifest intact for addonCollectionSet.
        let encoded = try JSONEncoder().encode(collection.addons)
        let decoded = try JSONDecoder().decode([AddonDescriptor].self, from: encoded)
        #expect(decoded.map(\.manifest.id) == collection.addons.map(\.manifest.id))

        let meta = try await api.libraryMeta(authKey: session.authKey)
        let items = try await api.libraryItems(authKey: session.authKey, ids: Array(meta.keys.prefix(200)))
        print("library: \(meta.count) on server, decoded \(items.count) of first \(min(meta.count, 200))")
        print("  in library: \(items.filter(\.isInLibrary).count), with progress: \(items.filter { $0.state.timeOffset > 0 }.count)")
        #expect(items.count == min(meta.count, 200))

        try await api.logout(authKey: session.authKey)
    }
}
