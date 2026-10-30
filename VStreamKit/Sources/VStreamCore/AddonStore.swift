import AddonKit
import Foundation
import Observation

@MainActor
@Observable
public final class AddonStore {
    public private(set) var addons: [InstalledAddon] = []
    public private(set) var isRefreshing = false
    /// Called after user-initiated changes so account sync can push the collection.
    @ObservationIgnored public var onChange: (() -> Void)?

    private let client: AddonClient

    public init(client: AddonClient = .shared) {
        self.client = client
        if let saved = JSONStore.load([InstalledAddon].self, from: "addons") {
            addons = saved
        } else {
            Task { await installDefaults() }
        }
    }

    public var enabled: [AddonDescriptor] {
        addons.filter(\.isEnabled).map(\.descriptor)
    }

    public func addons(supporting resource: String, type: String, id: String? = nil) -> [AddonDescriptor] {
        enabled.filter { $0.manifest.supports(resource: resource, type: type, id: id) }
    }

    public func isInstalled(_ url: URL) -> Bool {
        addons.contains { $0.descriptor.transportUrl == url }
    }

    @discardableResult
    public func install(_ input: String) async throws -> AddonDescriptor {
        let descriptor = try await client.fetchManifest(from: input, bypassCache: true)
        if let index = addons.firstIndex(where: { $0.descriptor.transportUrl == descriptor.transportUrl }) {
            addons[index].descriptor = descriptor
        } else {
            addons.append(InstalledAddon(descriptor: descriptor))
        }
        persist(notify: true)
        return descriptor
    }

    public func remove(_ addon: InstalledAddon) {
        guard !addon.descriptor.flags.protected else { return }
        addons.removeAll { $0.id == addon.id }
        persist(notify: true)
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        addons.move(fromOffsets: source, toOffset: destination)
        persist(notify: true)
    }

    public func setEnabled(_ addon: InstalledAddon, _ enabled: Bool) {
        guard let index = addons.firstIndex(where: { $0.id == addon.id }) else { return }
        addons[index].isEnabled = enabled
        persist(notify: false)
    }

    /// Replaces the list with an account's collection, keeping local enabled flags.
    public func replace(with descriptors: [AddonDescriptor]) {
        let disabled = Set(addons.filter { !$0.isEnabled }.map(\.id))
        addons = descriptors.map { InstalledAddon(descriptor: $0, isEnabled: !disabled.contains($0.id)) }
        persist(notify: false)
    }

    /// Re-fetches every manifest so catalogs and resources stay current.
    public func refreshManifests() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let client = self.client
        let refreshed = await withTaskGroup(of: (String, AddonDescriptor?).self) { group in
            for addon in addons {
                let url = addon.descriptor.transportUrl
                group.addTask { (addon.id, try? await client.fetchManifest(from: url.absoluteString)) }
            }
            var result: [String: AddonDescriptor] = [:]
            for await (id, descriptor) in group {
                if let descriptor { result[id] = descriptor }
            }
            return result
        }
        for index in addons.indices {
            if var descriptor = refreshed[addons[index].id] {
                descriptor.flags = addons[index].descriptor.flags
                addons[index].descriptor = descriptor
            }
        }
        persist(notify: false)
    }

    private func installDefaults() async {
        for url in DefaultAddons.all {
            if var descriptor = try? await client.fetchManifest(from: url.absoluteString) {
                descriptor.flags = .init(official: true, protected: url == DefaultAddons.cinemeta)
                addons.append(InstalledAddon(descriptor: descriptor))
            }
        }
        persist(notify: false)
    }

    private func persist(notify: Bool) {
        JSONStore.save(addons, to: "addons")
        if notify { onChange?() }
    }
}
