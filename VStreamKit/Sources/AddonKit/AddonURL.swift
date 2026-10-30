import Foundation

public struct ExtraArgument: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public enum AddonURL {
    /// RFC 3986 unreserved characters; everything else is percent-encoded.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Turns user input (`stremio://host/x`, `host/x`, `https://host/x/manifest.json#frag`) into a manifest URL.
    public static func normalizeManifestURL(_ input: String) -> URL? {
        var string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        if string.lowercased().hasPrefix("stremio://") {
            string = "https://" + string.dropFirst("stremio://".count)
        } else if !string.contains("://") {
            string = "https://" + string
        }
        guard var components = URLComponents(string: string), components.host?.isEmpty == false else { return nil }
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/manifest.json") { path += "/manifest.json" }
        components.percentEncodedPath = path
        return components.url
    }

    /// `{base}/{resource}/{type}/{id}[/{extra}].json?{manifest query}`
    public static func resource(
        transportURL: URL,
        resource: String,
        type: String,
        id: String,
        extra: [ExtraArgument] = []
    ) -> URL? {
        guard var components = URLComponents(url: transportURL, resolvingAgainstBaseURL: false) else { return nil }
        var base = components.percentEncodedPath
        if base.hasSuffix("/manifest.json") { base.removeLast("/manifest.json".count) }
        while base.hasSuffix("/") { base.removeLast() }

        var path = "\(base)/\(encode(resource))/\(encode(type))/\(encode(id))"
        if !extra.isEmpty {
            path += "/" + extra.map { "\(encode($0.name))=\(encode($0.value))" }.joined(separator: "&")
        }
        components.percentEncodedPath = path + ".json"
        return components.url
    }

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
