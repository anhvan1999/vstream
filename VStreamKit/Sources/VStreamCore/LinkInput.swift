import AddonKit
import Foundation

/// What a pasted or dropped string points at.
public enum LinkInput: Sendable, Hashable {
    case video(URL)
    case magnet(URL)
    case torrentFile(URL)
    case addon(URL)

    public init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        // A bare info hash (40 hex or 32 base32 characters).
        if value.range(of: #"^([0-9a-fA-F]{40}|[A-Za-z2-7]{32})$"#, options: .regularExpression) != nil,
           let url = URL(string: "magnet:?xt=urn:btih:\(value.lowercased())") {
            self = .magnet(url)
            return
        }
        let url: URL? = if value.hasPrefix("/") || value.hasPrefix("~") {
            URL(filePath: (value as NSString).expandingTildeInPath)
        } else {
            URL(string: value) ?? URL(string: value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        }
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        let isTorrent = url.pathExtension.lowercased() == "torrent"
        switch scheme {
        case "magnet" where Magnet.infoHash(from: url) != nil: self = .magnet(url)
        case "stremio": self = .addon(url)
        case "http" where url.host != nil, "https" where url.host != nil: self = isTorrent ? .torrentFile(url) : .video(url)
        case "file": self = isTorrent ? .torrentFile(url) : .video(url)
        default: return nil
        }
    }

    public var raw: String {
        switch self {
        case let .video(url), let .magnet(url), let .torrentFile(url), let .addon(url): url.absoluteString
        }
    }

    public var title: String {
        switch self {
        case let .magnet(url):
            let name = URLComponents(string: "x:" + url.absoluteString.drop { $0 != "?" })?.queryItems?.first { $0.name == "dn" }?.value
            return name ?? "Magnet \(Magnet.infoHash(from: url)?.prefix(8) ?? "")"
        case let .video(url), let .torrentFile(url), let .addon(url):
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            return name.isEmpty || name == "/" ? (url.host ?? url.absoluteString) : name
        }
    }

    public var detail: String {
        switch self {
        case let .magnet(url): Magnet.infoHash(from: url) ?? url.absoluteString
        case let .video(url), let .torrentFile(url), let .addon(url): url.isFileURL ? url.path : url.host ?? url.absoluteString
        }
    }

    public var symbol: String {
        switch self {
        case .magnet: "link.badge.plus"
        case .torrentFile: "doc.zipper"
        case let .video(url): url.isFileURL ? "film" : "globe"
        case .addon: "puzzlepiece.extension"
        }
    }
}
