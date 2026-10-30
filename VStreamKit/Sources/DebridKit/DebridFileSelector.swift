import Foundation

public struct DebridFile: Sendable, Hashable {
    public var id: String
    public var path: String
    public var size: Int64

    public init(id: String, path: String, size: Int64) {
        self.id = id
        self.path = path
        self.size = size
    }

    var normalizedPath: String {
        var path = path.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    var basename: String { normalizedPath.split(separator: "/").last.map(String.init) ?? normalizedPath }

    public var isVideo: Bool {
        let lower = path.lowercased()
        return DebridFileSelector.videoExtensions.contains { lower.hasSuffix($0) }
    }
}

/// Picks the file to play inside a multi-file torrent. Port of Nuvio's `selectDebridFile`:
/// exact filename → episode pattern → declared `fileIdx` → largest video.
public enum DebridFileSelector {
    static let videoExtensions = [".mp4", ".mkv", ".webm", ".avi", ".mov", ".m4v", ".ts", ".m2ts", ".wmv", ".flv"]

    public static func select(_ files: [DebridFile], request: DebridRequest) -> DebridFile? {
        let playable = files.filter(\.isVideo)
        guard !playable.isEmpty else { return nil }

        if let name = request.filename.map(normalize), !name.isEmpty {
            let matches = matching(playable, name: name)
            if !matches.isEmpty { return matches.count == 1 ? matches[0] : matches.max { $0.size < $1.size } }
        }

        if let pattern = episodePattern(season: request.season, episode: request.episode) {
            let matches = playable.filter { file in
                file.basename.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
            if !matches.isEmpty { return matches.max { $0.size < $1.size } }
        }

        if let index = request.fileIndex, files.indices.contains(index), files[index].isVideo {
            return files[index]
        }

        return playable.max { $0.size < $1.size }
    }

    public static func episodePattern(season: Int?, episode: Int?) -> String? {
        guard let season, let episode else { return nil }
        return "(?<![a-z0-9])(?:s0*\(season)[ ._-]?e0*\(episode)|0*\(season)x0*\(episode))(?![0-9])"
    }

    private static func normalize(_ name: String) -> String {
        DebridFile(id: "", path: name, size: 0).normalizedPath
    }

    private static func matching(_ files: [DebridFile], name: String) -> [DebridFile] {
        let basename = name.split(separator: "/").last.map(String.init) ?? name
        for compare in [{ (a: String, b: String) in a == b }, { $0.caseInsensitiveCompare($1) == .orderedSame }] {
            let byPath = files.filter { compare($0.normalizedPath, name) || (name.contains("/") && $0.normalizedPath.lowercased().hasSuffix("/" + name.lowercased())) }
            if !byPath.isEmpty { return byPath }
            let byName = files.filter { compare($0.basename, basename) }
            if !byName.isEmpty { return byName }
        }
        return []
    }
}
