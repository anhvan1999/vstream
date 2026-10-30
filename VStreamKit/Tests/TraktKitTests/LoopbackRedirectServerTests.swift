import Foundation
import Testing
@testable import TraktKit

@Suite struct LoopbackRedirectServerTests {
    @Test func capturesRedirectQuery() async throws {
        let server = LoopbackRedirectServer(port: 18765, path: "/trakt")
        try await server.start()
        async let callback = server.waitForCallback(timeout: .seconds(10))

        // A stray request (browsers ask for favicons) must not complete the flow.
        _ = try? await URLSession.shared.data(from: URL(string: "http://localhost:18765/favicon.ico")!)
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:18765/trakt?code=abc123&state=xyz")!)

        let query = try await callback
        #expect(query["code"] == "abc123")
        #expect(query["state"] == "xyz")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("connected to Trakt"))
    }

    @Test func busyPortIsReported() async throws {
        let first = LoopbackRedirectServer(port: 18766, path: "/trakt")
        try await first.start()
        defer { first.stop() }
        let second = LoopbackRedirectServer(port: 18766, path: "/trakt")
        await #expect(throws: LoopbackError.self) { try await second.start() }
    }

    @Test func redirectURIMatchesRegisteredApp() {
        #expect(TraktClient.redirectURI == "http://localhost:8765/trakt")
    }
}

@Suite struct PKCETests {
    @Test func matchesRFC7636Example() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomVerifierIsURLSafe() {
        let verifier = PKCE().verifier
        #expect(verifier.count == 43)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func publicClientSendsNoSecret() {
        #expect(TraktCredentials(clientID: "id").signed(["a": 1])["client_secret"] == nil)
        #expect(TraktCredentials(clientID: "id", clientSecret: "s").signed([:])["client_secret"] as? String == "s")
    }
}
