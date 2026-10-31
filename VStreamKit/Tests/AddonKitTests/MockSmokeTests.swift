import Foundation
import Testing
import TestSupport
@testable import AddonKit

@Suite struct MockSmokeTests {
    @Test func manifestThroughMockHTTP() async throws {
        let http = MockHTTP(MockHTTP.routes([
            "/manifest.json": .json(["id": "org.test", "version": "1.0.0", "name": "Test", "resources": ["stream"], "types": ["movie"], "catalogs": []]),
        ]))
        let client = AddonClient(session: http.session)
        let addon = try await client.fetchManifest(from: "https://addon.example/manifest.json")
        #expect(addon.manifest.name == "Test")
        #expect(http.requests.first?.path == "/manifest.json")
    }
}
