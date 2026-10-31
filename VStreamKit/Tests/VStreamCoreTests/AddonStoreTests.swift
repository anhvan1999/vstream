import AddonKit
import Foundation
import Testing
import TestSupport
@testable import VStreamCore

/// Serves manifests for the default addons and a custom one; `version` changes what refreshes see.
private final class ManifestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _version = "1.0.0"
    var version: String {
        get { lock.withLock { _version } }
        set { lock.withLock { _version = newValue } }
    }

    lazy var http = MockHTTP { [unowned self] request in
        guard request.path.hasSuffix("/manifest.json") else { return .init(status: 404) }
        let version = self.version
        switch request.url.host {
        case "v3-cinemeta.strem.io":
            return .json(["id": "com.linvo.cinemeta", "version": version, "name": "Cinemeta", "types": ["movie", "series"], "resources": ["catalog", "meta"], "catalogs": []])
        case "opensubtitles-v3.strem.io":
            return .json(["id": "org.stremio.opensubtitlesv3", "version": version, "name": "OpenSubtitles v3", "types": ["movie", "series"], "resources": ["subtitles"], "catalogs": []])
        case "custom.example":
            return .json(["id": "org.custom", "version": version, "name": "Custom", "types": ["movie"], "resources": ["stream"], "catalogs": []])
        default:
            return .init(status: 404)
        }
    }
}

/// `AddonStore` always persists to `addons.json`, so the whole lifecycle runs in one test to keep
/// the shared file free of races.
@MainActor
@Suite struct AddonStoreTests {
    init() { TestStore.prepare() }

    @Test func lifecycle() async throws {
        let server = ManifestServer()
        let client = AddonClient(session: server.http.session)
        let store = AddonStore(client: client)

        // First launch: no saved list, so the defaults are installed.
        #expect(await eventually { store.addons.count == 2 })
        #expect(store.addons.map(\.descriptor.transportUrl) == DefaultAddons.all)
        #expect(store.addons.allSatisfy { $0.descriptor.flags.official })
        let protectedFlags = store.addons.map { $0.descriptor.flags.protected }
        #expect(protectedFlags == [true, false], "only Cinemeta is protected")
        #expect(store.enabled.count == 2)
        #expect(store.addons(supporting: "subtitles", type: "movie").map(\.manifest.name) == ["OpenSubtitles v3"])
        #expect(store.addons(supporting: "meta", type: "series", id: "tt1").map(\.manifest.name) == ["Cinemeta"])

        var changes = 0
        store.onChange = { changes += 1 }

        // Install (normalised URL), then reinstall updates in place.
        let custom = try await store.install("custom.example")
        #expect(custom.transportUrl == URL(string: "https://custom.example/manifest.json"))
        #expect(store.isInstalled(custom.transportUrl))
        #expect(store.addons.count == 3)
        #expect(changes == 1)
        server.version = "1.1.0"
        try await store.install("stremio://custom.example/manifest.json")
        #expect(store.addons.count == 3)
        #expect(store.addons.last?.manifest.version == "1.1.0")
        #expect(changes == 2)

        // Invalid input never reaches the list.
        await #expect(throws: AddonError.self) { try await store.install("   ") }
        await #expect(throws: AddonError.self) { try await store.install("missing.example") }
        #expect(store.addons.count == 3)
        #expect(changes == 2)

        // Protected addons can't be removed.
        let cinemeta = try #require(store.addons.first)
        store.remove(cinemeta)
        #expect(store.addons.count == 3)
        #expect(changes == 2)

        // Disabling is local: no change notification.
        let installed = try #require(store.addons.last)
        store.setEnabled(installed, false)
        #expect(store.enabled.map(\.id) == DefaultAddons.all.map(\.absoluteString))
        #expect(store.addons(supporting: "stream", type: "movie").isEmpty)
        #expect(changes == 2)
        store.setEnabled(InstalledAddon(descriptor: addonDescriptor("ghost.example")), true)
        #expect(store.addons.count == 3)

        // Reorder.
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.addons.first?.id == installed.id)
        #expect(changes == 3)

        // Replacing with an account's collection keeps local disabled flags.
        store.replace(with: [installed.descriptor, cinemeta.descriptor])
        #expect(store.addons.map(\.id) == [installed.id, cinemeta.id])
        #expect(store.addons.map(\.isEnabled) == [false, true])
        #expect(changes == 3)

        // Refresh picks up new manifests but keeps flags.
        server.version = "2.0.0"
        await store.refreshManifests()
        #expect(!store.isRefreshing)
        #expect(store.addons.allSatisfy { $0.manifest.version == "2.0.0" })
        #expect(store.addons.last?.descriptor.flags == .init(official: true, protected: true))
        #expect(store.addons.map(\.isEnabled) == [false, true])

        store.remove(try #require(store.addons.first))
        #expect(store.addons.map(\.id) == [cinemeta.id])
        #expect(!store.isInstalled(custom.transportUrl))
        #expect(changes == 4)

        // A second store loads the saved list instead of installing defaults.
        let expected = store.addons
        let loaded = await eventually { JSONStore.load([InstalledAddon].self, from: "addons") == expected }
        #expect(loaded)
        let requestsBefore = server.http.requests.count
        let reloaded = await eventually { AddonStore(client: client).addons == expected }
        #expect(reloaded)
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.http.requests.count == requestsBefore, "saved list: no default install")
    }

    private func addonDescriptor(_ host: String) -> AddonDescriptor {
        AddonDescriptor(manifest: Manifest(id: host, version: "1", name: host), transportUrl: URL(string: "https://\(host)/manifest.json")!)
    }
}
