import AddonKit
import Foundation

public struct CatalogRow: Identifiable, Hashable, Sendable {
    public var addon: AddonDescriptor
    public var catalog: ManifestCatalog

    /// `{manifestId}:{type}:{catalogId}`, stable across launches.
    public var id: String { "\(addon.manifest.id):\(catalog.type):\(catalog.id)" }

    public var title: String {
        let type = catalog.type.capitalized
        return catalog.name.localizedCaseInsensitiveContains(type) ? catalog.name : "\(catalog.name) · \(type)"
    }
}

public struct StreamGroup: Identifiable, Hashable, Sendable {
    public var addon: AddonDescriptor
    public var streams: [AddonStream]
    public var error: String?

    public var id: String { addon.id }
}

public struct SearchResultGroup: Identifiable, Hashable, Sendable {
    public var row: CatalogRow
    public var metas: [MetaPreview]

    public var id: String { row.id }
}

/// Addon-protocol queries that span all installed addons.
public struct ContentService: Sendable {
    public let client: AddonClient

    public init(client: AddonClient = .shared) {
        self.client = client
    }

    public static func homeRows(_ addons: [AddonDescriptor], includeAdult: Bool) -> [CatalogRow] {
        addons
            .filter { includeAdult || !$0.manifest.behaviorHints.adult }
            .flatMap { addon in addon.manifest.catalogs.filter(\.isBrowsable).map { CatalogRow(addon: addon, catalog: $0) } }
    }

    public static func discoverRows(_ addons: [AddonDescriptor]) -> [CatalogRow] {
        addons.flatMap { addon in
            addon.manifest.catalogs
                .filter { $0.requiredExtraNames.subtracting(["genre"]).isEmpty }
                .map { CatalogRow(addon: addon, catalog: $0) }
        }
    }

    public func page(_ row: CatalogRow, skip: Int = 0, genre: String? = nil, search: String? = nil) async throws -> CatalogPage {
        var extra: [ExtraArgument] = []
        if let search { extra.append(ExtraArgument("search", search)) }
        if let genre { extra.append(ExtraArgument("genre", genre)) }
        if skip > 0 { extra.append(ExtraArgument("skip", String(skip))) }
        return try await client.catalog(row.addon, type: row.catalog.type, id: row.catalog.id, extra: extra)
    }

    public func search(_ query: String, addons: [AddonDescriptor]) async -> [SearchResultGroup] {
        let rows = addons.flatMap { addon in
            addon.manifest.catalogs.filter(\.isSearchable).map { CatalogRow(addon: addon, catalog: $0) }
        }
        return await withTaskGroup(of: (Int, SearchResultGroup?).self) { group in
            for (index, row) in rows.enumerated() {
                group.addTask {
                    let page = try? await page(row, search: query)
                    return (index, page.flatMap { $0.metas.isEmpty ? nil : SearchResultGroup(row: row, metas: $0.metas) })
                }
            }
            var results: [(Int, SearchResultGroup)] = []
            for await (index, result) in group {
                if let result { results.append((index, result)) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// First addon (in install order) that answers wins; each gets 5 seconds.
    public func meta(type: String, id: String, addons: [AddonDescriptor]) async throws -> MetaDetail {
        let candidates = addons.filter { $0.manifest.supports(resource: "meta", type: type, id: id) }
        var lastError: Error = AddonError.unsupported(resource: "meta", addon: "installed addons")
        for addon in candidates {
            do {
                let client = self.client
                return try await withTimeout(5) { try await client.meta(addon, type: type, id: id) }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Streams from every capable addon, in parallel, yielded per addon as they arrive.
    public func streams(type: String, id: String, addons: [AddonDescriptor]) -> AsyncStream<StreamGroup> {
        let candidates = addons.filter { $0.manifest.supports(resource: "stream", type: type, id: id) }
        let client = self.client
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: StreamGroup.self) { group in
                    for addon in candidates {
                        group.addTask {
                            do {
                                let streams = try await withTimeout(30) { try await client.streams(addon, type: type, id: id) }
                                return StreamGroup(addon: addon, streams: streams)
                            } catch {
                                return StreamGroup(addon: addon, streams: [], error: error.localizedDescription)
                            }
                        }
                    }
                    for await result in group { continuation.yield(result) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func subtitles(type: String, id: String, stream: AddonStream?, addons: [AddonDescriptor]) async -> [Subtitle] {
        let candidates = addons.filter {
            $0.manifest.supports(resource: "subtitles", type: type, id: id)
        }
        var extra: [ExtraArgument] = []
        if let hash = stream?.behaviorHints.videoHash { extra.append(ExtraArgument("videoHash", hash)) }
        if let size = stream?.behaviorHints.videoSize { extra.append(ExtraArgument("videoSize", String(size))) }
        if let name = stream?.behaviorHints.filename { extra.append(ExtraArgument("filename", name)) }
        let client = self.client
        let arguments = extra
        let fetched = await withTaskGroup(of: [Subtitle].self) { group in
            for addon in candidates {
                group.addTask {
                    (try? await withTimeout(10) { try await client.subtitles(addon, type: type, id: id, extra: arguments) }) ?? []
                }
            }
            var all: [Subtitle] = []
            for await subtitles in group { all += subtitles }
            return all
        }
        var seen = Set<URL>()
        return ((stream?.subtitles ?? []) + fetched).filter { seen.insert($0.url).inserted }
    }
}
