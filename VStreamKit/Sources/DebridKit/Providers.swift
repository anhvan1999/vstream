import Foundation

// MARK: - Real-Debrid

/// Real-Debrid removed its instant-availability endpoint, so caching is discovered by adding the
/// magnet and checking whether it is immediately `downloaded`.
public struct RealDebridProvider: DebridProvider {
    public let service = DebridService.realDebrid
    private let http: DebridHTTP
    private let base = URL(string: "https://api.real-debrid.com/rest/1.0")!

    public init(apiKey: String, session: URLSession = .shared) {
        http = DebridHTTP(apiKey: apiKey, session: session)
    }

    public func validate() async throws -> Bool {
        let user = try await http.jsonObject(base.appending(path: "user"))
        return user["id"] != nil
    }

    public func cachedHashes(_ hashes: [String]) async throws -> Set<String>? { nil }

    public func resolve(_ request: DebridRequest) async throws -> DebridLink {
        let added = try await http.jsonObject(base.appending(path: "torrents/addMagnet"), method: "POST", form: [("magnet", request.magnet)])
        guard let id = added["id"] as? String else { throw DebridError.api("Real-Debrid did not accept the magnet") }

        var info = try await waitForFiles(id)
        let files = (info["files"] as? [[String: Any]] ?? []).compactMap { file -> DebridFile? in
            guard let fileID = file.int("id"), let path = file["path"] as? String else { return nil }
            return DebridFile(id: String(fileID), path: path, size: file.int64("bytes") ?? 0)
        }
        guard let selected = DebridFileSelector.select(files, request: request) else {
            try? await delete(id)
            throw DebridError.noPlayableFile
        }

        if info["status"] as? String == "waiting_files_selection" {
            _ = try await http.request(base.appending(path: "torrents/selectFiles/\(id)"), method: "POST", form: [("files", selected.id)])
        }

        // Cached torrents flip to "downloaded" almost immediately.
        for _ in 0..<10 {
            info = try await http.jsonObject(base.appending(path: "torrents/info/\(id)"))
            let status = info["status"] as? String
            if status == "downloaded" { break }
            if ["downloading", "queued", "magnet_error", "error", "virus", "dead"].contains(status) {
                try? await delete(id)
                throw DebridError.notCached
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard info["status"] as? String == "downloaded" else {
            try? await delete(id)
            throw DebridError.notCached
        }

        // `links` lists one entry per *selected* file, in file order.
        let selectedFiles = (info["files"] as? [[String: Any]] ?? []).filter { ($0["selected"] as? Int) == 1 }
        let linkIndex = selectedFiles.firstIndex { $0.int("id").map(String.init) == selected.id } ?? 0
        let links = info["links"] as? [String] ?? []
        guard links.indices.contains(linkIndex) else { throw DebridError.noPlayableFile }

        let unrestricted = try await http.jsonObject(base.appending(path: "unrestrict/link"), method: "POST", form: [("link", links[linkIndex])])
        guard let download = (unrestricted["download"] as? String).flatMap(URL.init(string:)) else {
            throw DebridError.api("Real-Debrid did not return a download link")
        }
        return DebridLink(url: download, filename: unrestricted["filename"] as? String, size: unrestricted.int64("filesize"))
    }

    private func waitForFiles(_ id: String) async throws -> [String: Any] {
        for _ in 0..<20 {
            let info = try await http.jsonObject(base.appending(path: "torrents/info/\(id)"))
            if !(info["files"] as? [Any] ?? []).isEmpty { return info }
            if info["status"] as? String == "magnet_error" { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        try? await delete(id)
        throw DebridError.notCached
    }

    private func delete(_ id: String) async throws {
        _ = try await http.request(base.appending(path: "torrents/delete/\(id)"), method: "DELETE")
    }
}

// MARK: - TorBox

public struct TorboxProvider: DebridProvider {
    public let service = DebridService.torbox
    private let http: DebridHTTP
    private let apiKey: String
    private let base = URL(string: "https://api.torbox.app/v1/api")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        http = DebridHTTP(apiKey: apiKey, session: session)
    }

    public func validate() async throws -> Bool {
        let response = try await http.jsonObject(base.appending(path: "user/me"))
        return response["success"] as? Bool == true
    }

    public func cachedHashes(_ hashes: [String]) async throws -> Set<String>? {
        guard !hashes.isEmpty else { return [] }
        var url = URLComponents(url: base.appending(path: "torrents/checkcached"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "format", value: "object")]
        let response = try await http.jsonObject(url.url!, method: "POST", json: ["hashes": hashes.map { $0.lowercased() }])
        let data = response["data"] as? [String: Any] ?? [:]
        return Set(data.keys.map { $0.lowercased() })
    }

    public func resolve(_ request: DebridRequest) async throws -> DebridLink {
        // With `add_only_if_cached`, an uncached torrent fails with DOWNLOAD_NOT_CACHED (as an
        // HTTP error or a `success: false` body); report it as `.notCached` so automatic mode
        // falls back to P2P.
        let created: [String: Any]
        do {
            created = try await http.jsonObject(
                base.appending(path: "torrents/createtorrent"),
                method: "POST",
                multipart: [("magnet", request.magnet), ("add_only_if_cached", "true"), ("allow_zip", "false")]
            )
        } catch let DebridError.api(message) where Self.isNotCached(message) {
            throw DebridError.notCached
        }
        guard created["success"] as? Bool != false else {
            let message = created["error"] as? String ?? created["detail"] as? String
            if let message, Self.isNotCached(message) { throw DebridError.notCached }
            throw DebridError.api(created["detail"] as? String ?? "TorBox rejected the torrent")
        }
        let data = created["data"] as? [String: Any] ?? [:]
        guard let torrentID = data.int("torrent_id") ?? data.int("id") else { throw DebridError.notCached }

        var list = URLComponents(url: base.appending(path: "torrents/mylist"), resolvingAgainstBaseURL: false)!
        list.queryItems = [URLQueryItem(name: "id", value: String(torrentID)), URLQueryItem(name: "bypass_cache", value: "true")]
        let torrent = try await http.jsonObject(list.url!)["data"] as? [String: Any] ?? [:]
        let files = (torrent["files"] as? [[String: Any]] ?? []).compactMap { file -> DebridFile? in
            guard let id = file.int("id") else { return nil }
            let path = file["name"] as? String ?? file["short_name"] as? String ?? file["absolute_path"] as? String ?? ""
            return DebridFile(id: String(id), path: path, size: file.int64("size") ?? 0)
        }
        guard let selected = DebridFileSelector.select(files, request: request) else { throw DebridError.noPlayableFile }

        var download = URLComponents(url: base.appending(path: "torrents/requestdl"), resolvingAgainstBaseURL: false)!
        download.queryItems = [
            URLQueryItem(name: "token", value: apiKey),
            URLQueryItem(name: "torrent_id", value: String(torrentID)),
            URLQueryItem(name: "file_id", value: selected.id),
            URLQueryItem(name: "zip_link", value: "false"),
            URLQueryItem(name: "redirect", value: "false"),
        ]
        let link = try await http.jsonObject(download.url!)
        guard let url = (link["data"] as? String).flatMap(URL.init(string:)) else {
            throw DebridError.api(link["detail"] as? String ?? "TorBox did not return a link")
        }
        return DebridLink(url: url, filename: selected.basename, size: selected.size)
    }

    private static func isNotCached(_ message: String) -> Bool {
        message == "DOWNLOAD_NOT_CACHED" || message.range(of: "not cached", options: .caseInsensitive) != nil
    }
}

// MARK: - Premiumize

public struct PremiumizeProvider: DebridProvider {
    public let service = DebridService.premiumize
    private let http: DebridHTTP
    private let base = URL(string: "https://www.premiumize.me/api")!

    public init(apiKey: String, session: URLSession = .shared) {
        http = DebridHTTP(apiKey: apiKey, session: session)
    }

    public func validate() async throws -> Bool {
        try await http.jsonObject(base.appending(path: "account/info"))["status"] as? String == "success"
    }

    public func cachedHashes(_ hashes: [String]) async throws -> Set<String>? {
        guard !hashes.isEmpty else { return [] }
        let response = try await http.jsonObject(base.appending(path: "cache/check"), method: "POST", form: hashes.map { ("items[]", $0) })
        let flags = response["response"] as? [Bool] ?? []
        return Set(zip(hashes, flags).filter(\.1).map { $0.0.lowercased() })
    }

    public func resolve(_ request: DebridRequest) async throws -> DebridLink {
        let response = try await http.jsonObject(base.appending(path: "transfer/directdl"), method: "POST", form: [("src", request.magnet)])
        guard response["status"] as? String == "success" else {
            throw DebridError.api(response["message"] as? String ?? "Premiumize could not resolve this torrent")
        }
        let content = response["content"] as? [[String: Any]] ?? []
        let files = content.enumerated().compactMap { index, file -> DebridFile? in
            guard let path = file["path"] as? String else { return nil }
            return DebridFile(id: String(index), path: path, size: file.int64("size") ?? 0)
        }
        guard let selected = DebridFileSelector.select(files, request: request), let index = Int(selected.id),
              let url = (content[index]["link"] as? String).flatMap(URL.init(string:)) else {
            throw DebridError.noPlayableFile
        }
        return DebridLink(url: url, filename: selected.basename, size: selected.size)
    }
}
