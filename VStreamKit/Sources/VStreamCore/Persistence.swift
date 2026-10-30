import Foundation
import Security

/// Small JSON documents in Application Support. Writes are atomic and happen off the main thread.
public enum JSONStore {
    static let directory: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let url = base.appending(path: "VStream", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let queue = DispatchQueue(label: "vstream.jsonstore", qos: .utility)

    public static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appending(path: "\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public static func save<T: Encodable & Sendable>(_ value: T, to name: String) {
        let url = directory.appending(path: "\(name).json")
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Generic-password Keychain items for secrets (auth keys, API tokens).
public enum Keychain {
    /// Items are owned by the signing identity that created them. Builds signed ad-hoc used
    /// "com.vstream.app"; a fresh service name keeps a stably signed app from inheriting
    /// those items, whose access lists would prompt on every read.
    private static let service = "com.vstream.app.secrets"

    public static func string(_ account: String) -> String? {
        data(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func set(_ value: String?, for account: String) {
        set(value.map { Data($0.utf8) }, for: account)
    }

    public static func value<T: Decodable>(_ type: T.Type, for account: String) -> T? {
        data(account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    public static func set<T: Encodable>(value: T?, for account: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, for: account)
    }

    private static func data(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func set(_ data: Data?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
