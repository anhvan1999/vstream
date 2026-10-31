import Foundation
import Testing
@testable import AddonKit

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Suite struct ManifestDecodingTests {
    @Test func minimalManifestDefaults() throws {
        let manifest = try decode(Manifest.self, #"{"id":"org.min"}"#)
        #expect(manifest.name == "org.min")
        #expect(manifest.version == "0.0.0")
        #expect(manifest.description == nil)
        #expect(manifest.types.isEmpty)
        #expect(manifest.resources.isEmpty)
        #expect(manifest.catalogs.isEmpty)
        #expect(manifest.behaviorHints == .init())
        #expect(manifest.raw?["id"] == .string("org.min"))
    }

    @Test func missingIdThrows() {
        #expect(throws: DecodingError.self) { try decode(Manifest.self, #"{"name":"x"}"#) }
    }

    @Test func lenientFields() throws {
        let manifest = try decode(Manifest.self, """
        {"id":"org.l","name":"","version":3,"description":"","logo":" https://a.example/logo.png ",
         "types":"movie, series","idPrefixes":["tt",1,""],
         "resources":["catalog",{"name":"stream","types":["movie"],"idPrefixes":"tt"},{"types":["x"]},7],
         "catalogs":[{"type":"movie","id":"top"},{"id":"no-type"}],
         "behaviorHints":{"adult":1,"p2p":"yes","configurable":"TRUE","configurationRequired":"no"}}
        """)
        #expect(manifest.name == "org.l")
        #expect(manifest.version == "3")
        #expect(manifest.description == nil)
        #expect(manifest.logo?.absoluteString == "https://a.example/logo.png")
        #expect(manifest.types == ["movie", "series"])
        #expect(manifest.idPrefixes == ["tt"])
        #expect(manifest.resources == [
            ManifestResource(name: "catalog"),
            ManifestResource(name: "stream", types: ["movie"], idPrefixes: ["tt"]),
        ])
        #expect(manifest.catalogs.map(\.id) == ["top"])
        #expect(manifest.catalogs.first?.name == "top")
        #expect(manifest.behaviorHints == ManifestBehaviorHints(adult: true, p2p: true, configurable: true, configurationRequired: false))
    }

    @Test func malformedBehaviorHintsFallBackToDefaults() throws {
        let manifest = try decode(Manifest.self, #"{"id":"x","behaviorHints":"nope"}"#)
        #expect(manifest.behaviorHints == .init())
    }

    @Test func encodeWithoutRawUsesFields() throws {
        let original = Manifest(
            id: "org.built",
            version: "1.2.3",
            name: "Built",
            description: "Desc",
            logo: URL(string: "https://a.example/l.png"),
            types: ["movie"],
            idPrefixes: ["tt"],
            resources: [ManifestResource(name: "meta", types: ["series"])],
            catalogs: [ManifestCatalog(type: "movie", id: "top", name: "Top", extra: [ManifestExtra(name: "skip")])],
            behaviorHints: ManifestBehaviorHints(p2p: true)
        )
        #expect(original.raw == nil)
        let decoded = try JSONDecoder().decode(Manifest.self, from: JSONEncoder().encode(original))
        #expect(decoded.id == original.id)
        #expect(decoded.version == original.version)
        #expect(decoded.name == original.name)
        #expect(decoded.description == original.description)
        #expect(decoded.logo == original.logo)
        #expect(decoded.background == nil)
        #expect(decoded.types == original.types)
        #expect(decoded.idPrefixes == original.idPrefixes)
        #expect(decoded.resources == original.resources)
        #expect(decoded.catalogs == original.catalogs)
        #expect(decoded.behaviorHints == original.behaviorHints)
    }

    @Test func encodePreservesUnknownFieldsViaRaw() throws {
        let manifest = try decode(Manifest.self, #"{"id":"x","custom":{"nested":[1,2]},"stremioAddonsConfig":"sig"}"#)
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(manifest))
        #expect(json["custom"]?["nested"] == .array([.number(1), .number(2)]))
        #expect(json["stremioAddonsConfig"] == .string("sig"))
    }
}

@Suite struct ManifestSupportsTests {
    let manifest = Manifest(
        id: "x",
        version: "1",
        name: "X",
        types: ["movie", "series"],
        idPrefixes: ["tt"],
        resources: [
            ManifestResource(name: "catalog"),
            ManifestResource(name: "meta", types: ["anime"], idPrefixes: ["kitsu:"]),
            ManifestResource(name: "stream", idPrefixes: []),
            ManifestResource(name: "subtitles", types: ["movie"]),
        ]
    )

    @Test func inheritsManifestTypesAndPrefixes() {
        #expect(manifest.supports(resource: "catalog", type: "movie"))
        #expect(manifest.supports(resource: "catalog", type: "series", id: "tt123"))
        #expect(!manifest.supports(resource: "catalog", type: "series", id: "kitsu:1"))
        #expect(!manifest.supports(resource: "catalog", type: "channel"))
    }

    @Test func resourceOverridesTypesAndPrefixes() {
        #expect(manifest.supports(resource: "meta", type: "anime", id: "kitsu:42"))
        #expect(!manifest.supports(resource: "meta", type: "movie", id: "tt1"))
        #expect(!manifest.supports(resource: "meta", type: "anime", id: "tt1"))
    }

    @Test func emptyResourcePrefixesAcceptAnyId() {
        #expect(manifest.supports(resource: "stream", type: "series", id: "kitsu:1"))
        #expect(manifest.supports(resource: "stream", type: "movie", id: "anything"))
    }

    @Test func resourceTypesWithInheritedPrefixes() {
        #expect(manifest.supports(resource: "subtitles", type: "movie", id: "tt9"))
        #expect(!manifest.supports(resource: "subtitles", type: "series", id: "tt9"))
        #expect(!manifest.supports(resource: "subtitles", type: "movie", id: "yt:9"))
    }

    @Test func unknownResource() {
        #expect(!manifest.supports(resource: "addon_catalog", type: "movie"))
    }

    @Test func noPrefixesAnywhereAcceptsAnyId() {
        let open = Manifest(id: "o", version: "1", name: "O", types: ["movie"], resources: [ManifestResource(name: "stream")])
        #expect(open.supports(resource: "stream", type: "movie", id: "whatever"))
    }

    @Test func resourceObjectWithoutListsInherits() throws {
        let resource = try decode(ManifestResource.self, #"{"name":"meta"}"#)
        #expect(resource.types == nil)
        #expect(resource.idPrefixes == nil)
        let explicitEmpty = try decode(ManifestResource.self, #"{"name":"meta","types":[],"idPrefixes":null}"#)
        #expect(explicitEmpty.types == [])
        #expect(explicitEmpty.idPrefixes == [])
    }

    @Test func resourceWithoutNameThrows() {
        #expect(throws: DecodingError.self) { try decode(ManifestResource.self, #"{"types":["movie"]}"#) }
    }
}

@Suite struct ManifestCatalogTests {
    @Test func extrasAndDerivedFlags() throws {
        let catalog = try decode(ManifestCatalog.self, """
        {"type":"movie","id":"top","name":"Popular","extra":[
          {"name":"genre","options":["Action","Drama"],"optionsLimit":"1"},
          {"name":"skip"},
          {"name":"search","isRequired":"false"},
          {"options":["missing name"]}
        ]}
        """)
        #expect(catalog.name == "Popular")
        #expect(catalog.extra.map(\.name) == ["genre", "skip", "search"])
        #expect(catalog.genres == ["Action", "Drama"])
        #expect(catalog.extra(named: "genre")?.optionsLimit == 1)
        #expect(catalog.extra(named: "skip")?.options == nil)
        #expect(catalog.extra(named: "nope") == nil)
        #expect(catalog.requiredExtraNames.isEmpty)
        #expect(catalog.isBrowsable)
        #expect(catalog.isSearchable)
        #expect(catalog.supportsPaging)
    }

    @Test func requiredGenreIsNeitherBrowsableNorSearchable() throws {
        let catalog = ManifestCatalog(type: "movie", id: "g", name: "G", extra: [
            ManifestExtra(name: "genre", isRequired: true, options: ["A"]),
            ManifestExtra(name: "search"),
        ])
        #expect(catalog.requiredExtraNames == ["genre"])
        #expect(!catalog.isBrowsable)
        #expect(!catalog.isSearchable)
        #expect(!catalog.supportsPaging)
    }

    @Test func searchOnlyCatalog() {
        let catalog = ManifestCatalog(type: "series", id: "s", name: "S", extra: [ManifestExtra(name: "search", isRequired: true)])
        #expect(catalog.isSearchable)
        #expect(!catalog.isBrowsable)
        #expect(catalog.genres.isEmpty)
    }

    @Test func legacyExtrasOnlyWhenNoExtraObjects() throws {
        let legacy = try decode(ManifestCatalog.self, #"{"type":"movie","id":"x","extraSupported":"genre, skip","extraRequired":["genre"]}"#)
        #expect(legacy.extra == [ManifestExtra(name: "genre", isRequired: true), ManifestExtra(name: "skip")])
        let both = try decode(ManifestCatalog.self, #"{"type":"movie","id":"x","extra":[{"name":"search"}],"extraSupported":["genre"]}"#)
        #expect(both.extra.map(\.name) == ["search"])
    }

    @Test func encodesModernExtraShape() throws {
        let legacy = try decode(ManifestCatalog.self, #"{"type":"movie","id":"x","name":"X","extraSupported":["skip"]}"#)
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(legacy))
        #expect(json["extraSupported"] == nil)
        #expect(json["extra"] == .array([.object(["name": .string("skip"), "isRequired": .bool(false)])]))
        #expect(try JSONDecoder().decode(ManifestCatalog.self, from: JSONEncoder().encode(legacy)) == legacy)
    }

    @Test func extraOptionsAsString() throws {
        let extra = try decode(ManifestExtra.self, #"{"name":"genre","options":"A, B","isRequired":1}"#)
        #expect(extra.options == ["A", "B"])
        #expect(extra.isRequired)
        #expect(extra.optionsLimit == nil)
    }
}

@Suite struct AddonDescriptorTests {
    let manifest = Manifest(id: "org.d", version: "1", name: "D")

    @Test func identityAndDefaults() {
        let descriptor = AddonDescriptor(manifest: manifest, transportUrl: URL(string: "https://d.example/manifest.json")!)
        #expect(descriptor.id == "https://d.example/manifest.json")
        #expect(!descriptor.flags.official)
        #expect(!descriptor.flags.protected)
    }

    @Test func decodesLenientFlags() throws {
        let descriptor = try decode(AddonDescriptor.self, """
        {"manifest":{"id":"org.d"},"transportUrl":"https://d.example/manifest.json","flags":{"official":"true","protected":1}}
        """)
        #expect(descriptor.flags == .init(official: true, protected: true))
        #expect(descriptor.manifest.name == "org.d")
    }

    @Test func missingOrBadFlagsDefault() throws {
        let missing = try decode(AddonDescriptor.self, #"{"manifest":{"id":"a"},"transportUrl":"https://a.example/manifest.json"}"#)
        #expect(missing.flags == .init())
        let bad = try decode(AddonDescriptor.self, #"{"manifest":{"id":"a"},"transportUrl":"https://a.example/manifest.json","flags":[1]}"#)
        #expect(bad.flags == .init())
    }

    @Test func missingManifestThrows() {
        #expect(throws: DecodingError.self) { try decode(AddonDescriptor.self, #"{"transportUrl":"https://a.example"}"#) }
    }

    @Test func roundTrips() throws {
        let descriptor = try decode(AddonDescriptor.self, #"{"manifest":{"id":"a","name":"A"},"transportUrl":"https://a.example/manifest.json","flags":{"official":true}}"#)
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(descriptor))
        #expect(json["transportUrl"] == .string("https://a.example/manifest.json"))
        #expect(json["flags"] == .object(["official": .bool(true), "protected": .bool(false)]))
        #expect(json["manifest"] == .object(["id": .string("a"), "name": .string("A")]))
        #expect(try JSONDecoder().decode(AddonDescriptor.self, from: JSONEncoder().encode(descriptor)) == descriptor)
    }

    @Test func installedAddon() throws {
        let descriptor = AddonDescriptor(manifest: manifest, transportUrl: URL(string: "https://d.example/manifest.json")!)
        let installed = InstalledAddon(descriptor: descriptor)
        #expect(installed.isEnabled)
        #expect(installed.id == descriptor.id)
        #expect(installed.manifest == manifest)
        var disabled = installed
        disabled.isEnabled = false
        #expect(try JSONDecoder().decode(InstalledAddon.self, from: JSONEncoder().encode(disabled)).isEnabled == false)
    }

    @Test func defaultAddons() {
        #expect(DefaultAddons.all == [DefaultAddons.cinemeta, DefaultAddons.openSubtitles])
        #expect(DefaultAddons.all.allSatisfy { $0.lastPathComponent == "manifest.json" && $0.scheme == "https" })
    }
}

@Suite struct AddonURLTests {
    @Test(arguments: [
        ("STREMIO://a.example/x", "https://a.example/x/manifest.json"),
        ("http://a.example/x///", "http://a.example/x/manifest.json"),
        ("https://a.example", "https://a.example/manifest.json"),
        ("https://a.example/manifest.json/", "https://a.example/manifest.json"),
        ("a.example:8080/x\n", "https://a.example:8080/x/manifest.json"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(AddonURL.normalizeManifestURL(input)?.absoluteString == expected)
    }

    @Test func rejectsHostless() {
        #expect(AddonURL.normalizeManifestURL("") == nil)
        #expect(AddonURL.normalizeManifestURL("stremio://") == nil)
        #expect(AddonURL.normalizeManifestURL("file:///tmp/manifest.json") == nil)
    }

    @Test func resourceFromNonManifestTransport() {
        let url = AddonURL.resource(transportURL: URL(string: "https://a.example/base/")!, resource: "meta", type: "movie", id: "tt1")
        #expect(url?.absoluteString == "https://a.example/base/meta/movie/tt1.json")
    }

    @Test func resourceEncodesEverySegment() {
        let url = AddonURL.resource(
            transportURL: URL(string: "https://a.example/manifest.json")!,
            resource: "catalog",
            type: "my type",
            id: "a/b",
            extra: [ExtraArgument("q=x", "ü+1")]
        )
        #expect(url?.absoluteString == "https://a.example/catalog/my%20type/a%2Fb/q%3Dx=%C3%BC%2B1.json")
    }

    @Test func encodeKeepsUnreserved() {
        #expect(AddonURL.encode("aZ0-._~") == "aZ0-._~")
        #expect(AddonURL.encode("a:b") == "a%3Ab")
    }

    @Test func extraArgument() {
        let extra = ExtraArgument("skip", "20")
        #expect(extra.name == "skip")
        #expect(extra.value == "20")
        #expect(extra == ExtraArgument("skip", "20"))
    }
}
