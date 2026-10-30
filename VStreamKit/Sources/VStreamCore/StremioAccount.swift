import AddonKit
import Foundation
import Observation
import StremioAPI

@MainActor
@Observable
public final class StremioAccount {
    public private(set) var session: StremioSession?
    public private(set) var isSyncing = false
    public private(set) var lastSync: Date?
    public private(set) var lastError: String?

    @ObservationIgnored private let api: StremioAPIClient
    @ObservationIgnored private let addons: AddonStore
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var addonPushTask: Task<Void, Never>?
    @ObservationIgnored private var libraryPushTask: Task<Void, Never>?

    public init(api: StremioAPIClient = StremioAPIClient(), addons: AddonStore, library: LibraryStore) {
        self.api = api
        self.addons = addons
        self.library = library
        session = Keychain.value(StremioSession.self, for: "stremio.session")
        addons.onChange = { [weak self] in self?.scheduleAddonPush() }
    }

    public var isSignedIn: Bool { session != nil }

    public func signIn(email: String, password: String) async throws {
        let session = try await api.login(email: email, password: password)
        self.session = session
        Keychain.set(value: session, for: "stremio.session")
        // The account's collection becomes the source of truth on first sign-in.
        let collection = try await api.addonCollection(authKey: session.authKey)
        if !collection.addons.isEmpty { addons.replace(with: collection.addons) }
        await sync()
    }

    public func signOut() async {
        if let session { try? await api.logout(authKey: session.authKey) }
        session = nil
        Keychain.set(nil, for: "stremio.session")
        lastSync = nil
    }

    /// Two-way library sync: push local changes, then pull whatever is newer on the server.
    public func sync() async {
        guard let authKey = session?.authKey, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let pending = library.takeDirty()
            try await api.putLibraryItems(authKey: authKey, pending)
            library.markClean(pending.map(\.id))

            let remote = try await api.libraryMeta(authKey: authKey)
            let stale = remote.filter { id, mtime in
                guard let local = library.items[id] else { return true }
                return mtime.timeIntervalSince(local.mtime) > 0.5
            }.map(\.key)
            for chunk in stale.chunked(into: 200) {
                library.merge(remote: try await api.libraryItems(authKey: authKey, ids: chunk))
            }
            lastSync = Date()
            lastError = nil
        } catch let error as StremioAPIError where error.code == 1 {
            // Session expired.
            lastError = error.message
            session = nil
            Keychain.set(nil, for: "stremio.session")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Debounced push after progress updates.
    public func scheduleLibraryPush() {
        guard session != nil else { return }
        libraryPushTask?.cancel()
        libraryPushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, let authKey = self.session?.authKey else { return }
            let pending = self.library.takeDirty()
            guard !pending.isEmpty else { return }
            do {
                try await self.api.putLibraryItems(authKey: authKey, pending)
                self.library.markClean(pending.map(\.id))
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    private func scheduleAddonPush() {
        guard session != nil else { return }
        addonPushTask?.cancel()
        addonPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, let authKey = self.session?.authKey else { return }
            do {
                try await self.api.setAddonCollection(authKey: authKey, addons: self.addons.addons.map(\.descriptor))
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
