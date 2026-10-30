import Foundation

public struct Manifest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var version: String
    public var name: String
    public var description: String?
    public var logo: URL?
    public var background: URL?
    public var types: [String]
    public var idPrefixes: [String]
    public var resources: [ManifestResource]
    public var catalogs: [ManifestCatalog]
    public var behaviorHints: ManifestBehaviorHints
    /// The original JSON, preserved so descriptors can be pushed back to the Stremio API unchanged.
    public var raw: JSONValue?

    public init(
        id: String,
        version: String,
        name: String,
        description: String? = nil,
        logo: URL? = nil,
        background: URL? = nil,
        types: [String] = [],
        idPrefixes: [String] = [],
        resources: [ManifestResource] = [],
        catalogs: [ManifestCatalog] = [],
        behaviorHints: ManifestBehaviorHints = .init()
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.description = description
        self.logo = logo
        self.background = background
        self.types = types
        self.idPrefixes = idPrefixes
        self.resources = resources
        self.catalogs = catalogs
        self.behaviorHints = behaviorHints
    }

    enum CodingKeys: String, CodingKey {
        case id, version, name, description, logo, background, types, idPrefixes, resources, catalogs, behaviorHints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = container.lossyString(.name) ?? id
        version = container.lossyString(.version) ?? "0.0.0"
        description = container.lossyString(.description)
        logo = container.lossyURL(.logo)
        background = container.lossyURL(.background)
        types = container.lossyStringArray(.types)
        idPrefixes = container.lossyStringArray(.idPrefixes)
        resources = container.lossyArray(.resources)
        catalogs = container.lossyArray(.catalogs)
        behaviorHints = (try? container.decodeIfPresent(ManifestBehaviorHints.self, forKey: .behaviorHints)) ?? .init()
        raw = try? JSONValue(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        if let raw {
            try raw.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(logo, forKey: .logo)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encode(types, forKey: .types)
        try container.encode(idPrefixes, forKey: .idPrefixes)
        try container.encode(resources, forKey: .resources)
        try container.encode(catalogs, forKey: .catalogs)
        try container.encode(behaviorHints, forKey: .behaviorHints)
    }

    /// A resource is supported when it lists the type (or inherits the manifest types) and either
    /// declares no id prefixes or one of them prefixes `id`.
    public func supports(resource name: String, type: String, id: String? = nil) -> Bool {
        resources.contains { resource in
            guard resource.name == name else { return false }
            let types = resource.types ?? self.types
            guard types.contains(type) else { return false }
            guard let id else { return true }
            let prefixes = resource.idPrefixes ?? idPrefixes
            return prefixes.isEmpty || prefixes.contains { id.hasPrefix($0) }
        }
    }
}

public struct ManifestResource: Codable, Sendable, Hashable {
    public var name: String
    /// `nil` means the resource inherits the manifest-level value.
    public var types: [String]?
    public var idPrefixes: [String]?

    public init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
    }

    enum CodingKeys: String, CodingKey { case name, types, idPrefixes }

    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.init(name: name)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            types: container.contains(.types) ? container.lossyStringArray(.types) : nil,
            idPrefixes: container.contains(.idPrefixes) ? container.lossyStringArray(.idPrefixes) : nil
        )
    }
}

public struct ManifestCatalog: Codable, Sendable, Hashable, Identifiable {
    public var type: String
    public var id: String
    public var name: String
    public var extra: [ManifestExtra]

    public init(type: String, id: String, name: String, extra: [ManifestExtra] = []) {
        self.type = type
        self.id = id
        self.name = name
        self.extra = extra
    }

    enum CodingKeys: String, CodingKey { case type, id, name, extra, extraSupported, extraRequired }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        name = container.lossyString(.name) ?? id
        var extra: [ManifestExtra] = container.lossyArray(.extra)
        if extra.isEmpty {
            // Legacy manifests: `extraSupported` / `extraRequired` string arrays.
            let required = Set(container.lossyStringArray(.extraRequired))
            extra = container.lossyStringArray(.extraSupported).map {
                ManifestExtra(name: $0, isRequired: required.contains($0))
            }
        }
        self.extra = extra
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(extra, forKey: .extra)
    }

    public func extra(named name: String) -> ManifestExtra? {
        extra.first { $0.name == name }
    }

    public var requiredExtraNames: Set<String> {
        Set(extra.filter(\.isRequired).map(\.name))
    }

    /// Can be shown as a plain row (Home): nothing is required.
    public var isBrowsable: Bool { requiredExtraNames.isEmpty }

    /// Can answer a search query: supports `search` and requires nothing else.
    public var isSearchable: Bool {
        extra(named: "search") != nil && requiredExtraNames.subtracting(["search"]).isEmpty
    }

    public var supportsPaging: Bool { extra(named: "skip") != nil }

    public var genres: [String] { extra(named: "genre")?.options ?? [] }
}

public struct ManifestExtra: Codable, Sendable, Hashable {
    public var name: String
    public var isRequired: Bool
    public var options: [String]?
    public var optionsLimit: Int?

    public init(name: String, isRequired: Bool = false, options: [String]? = nil, optionsLimit: Int? = nil) {
        self.name = name
        self.isRequired = isRequired
        self.options = options
        self.optionsLimit = optionsLimit
    }

    enum CodingKeys: String, CodingKey { case name, isRequired, options, optionsLimit }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        isRequired = container.lossyBool(.isRequired) ?? false
        options = container.contains(.options) ? container.lossyStringArray(.options) : nil
        optionsLimit = container.lossyInt(.optionsLimit)
    }
}

public struct ManifestBehaviorHints: Codable, Sendable, Hashable {
    public var adult: Bool
    public var p2p: Bool
    public var configurable: Bool
    public var configurationRequired: Bool

    public init(adult: Bool = false, p2p: Bool = false, configurable: Bool = false, configurationRequired: Bool = false) {
        self.adult = adult
        self.p2p = p2p
        self.configurable = configurable
        self.configurationRequired = configurationRequired
    }

    enum CodingKeys: String, CodingKey { case adult, p2p, configurable, configurationRequired }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        adult = container.lossyBool(.adult) ?? false
        p2p = container.lossyBool(.p2p) ?? false
        configurable = container.lossyBool(.configurable) ?? false
        configurationRequired = container.lossyBool(.configurationRequired) ?? false
    }
}
