import Foundation

/// The Stremio `Descriptor`: an addon manifest plus the URL it was installed from.
public struct AddonDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var manifest: Manifest
    public var transportUrl: URL
    public var flags: Flags

    public var id: String { transportUrl.absoluteString }

    public struct Flags: Codable, Sendable, Hashable {
        public var official: Bool
        public var `protected`: Bool

        public init(official: Bool = false, protected: Bool = false) {
            self.official = official
            self.protected = `protected`
        }

        enum CodingKeys: String, CodingKey { case official, `protected` }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            official = container.lossyBool(.official) ?? false
            `protected` = container.lossyBool(.protected) ?? false
        }
    }

    public init(manifest: Manifest, transportUrl: URL, flags: Flags = .init()) {
        self.manifest = manifest
        self.transportUrl = transportUrl
        self.flags = flags
    }

    enum CodingKeys: String, CodingKey { case manifest, transportUrl, flags }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try container.decode(Manifest.self, forKey: .manifest)
        transportUrl = try container.decode(URL.self, forKey: .transportUrl)
        flags = (try? container.decodeIfPresent(Flags.self, forKey: .flags)) ?? .init()
    }
}

/// A locally installed addon: the descriptor plus local-only presentation state.
public struct InstalledAddon: Codable, Sendable, Hashable, Identifiable {
    public var descriptor: AddonDescriptor
    public var isEnabled: Bool

    public var id: String { descriptor.id }
    public var manifest: Manifest { descriptor.manifest }

    public init(descriptor: AddonDescriptor, isEnabled: Bool = true) {
        self.descriptor = descriptor
        self.isEnabled = isEnabled
    }
}

public enum DefaultAddons {
    public static let cinemeta = URL(string: "https://v3-cinemeta.strem.io/manifest.json")!
    public static let openSubtitles = URL(string: "https://opensubtitles-v3.strem.io/manifest.json")!
    public static let all = [cinemeta, openSubtitles]
}
