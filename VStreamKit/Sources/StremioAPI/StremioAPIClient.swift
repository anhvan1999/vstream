import AddonKit
import Foundation

public struct StremioUser: Codable, Sendable, Hashable {
    public var id: String
    public var email: String
    public var fullname: String?
    public var avatar: URL?

    enum CodingKeys: String, CodingKey { case id = "_id", email, fullname, avatar }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        email = (try? container.decode(String.self, forKey: .email)) ?? ""
        fullname = try? container.decodeIfPresent(String.self, forKey: .fullname)
        avatar = (try? container.decodeIfPresent(String.self, forKey: .avatar)).flatMap { $0.flatMap(URL.init(string:)) }
    }
}

public struct StremioSession: Codable, Sendable, Hashable {
    public var authKey: String
    public var user: StremioUser
}

public struct StremioAPIError: Error, LocalizedError, Sendable {
    public var message: String
    public var code: Int

    public var errorDescription: String? { message }
}

public struct AddonCollection: Sendable {
    public var addons: [AddonDescriptor]
    public var lastModified: Date?
}

/// Client for `https://api.strem.io/api/{method}`. All calls are JSON POSTs that answer
/// `{"result": ...}` or `{"error": {"message", "code"}}`.
public struct StremioAPIClient: Sendable {
    public var baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "https://api.strem.io")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func login(email: String, password: String) async throws -> StremioSession {
        try await call("login", [
            "type": .string("Login"),
            "email": .string(email),
            "password": .string(password),
            "facebook": .bool(false),
        ])
    }

    public func logout(authKey: String) async throws {
        let _: JSONValue = try await call("logout", ["type": .string("Logout"), "authKey": .string(authKey)])
    }

    public func user(authKey: String) async throws -> StremioUser {
        try await call("getUser", ["type": .string("GetUser"), "authKey": .string(authKey)])
    }

    public func addonCollection(authKey: String) async throws -> AddonCollection {
        let response: CollectionResponse = try await call("addonCollectionGet", [
            "type": .string("AddonCollectionGet"),
            "authKey": .string(authKey),
            "update": .bool(true),
        ])
        return AddonCollection(
            addons: response.addons.compactMap(\.value),
            lastModified: StremioAPIDate.parse(response.lastModified)
        )
    }

    public func setAddonCollection(authKey: String, addons: [AddonDescriptor]) async throws {
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(addons))
        let _: JSONValue = try await call("addonCollectionSet", [
            "type": .string("AddonCollectionSet"),
            "authKey": .string(authKey),
            "addons": encoded,
        ])
    }

    /// Returns `[id: mtime]` for every library item on the server.
    public func libraryMeta(authKey: String) async throws -> [String: Date] {
        let pairs: [[JSONValue]] = try await call("datastoreMeta", [
            "authKey": .string(authKey),
            "collection": .string("libraryItem"),
        ])
        var result: [String: Date] = [:]
        for pair in pairs where pair.count == 2 {
            guard let id = pair[0].stringValue, case let .number(milliseconds) = pair[1] else { continue }
            result[id] = Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return result
    }

    public func libraryItems(authKey: String, ids: [String] = [], all: Bool = false) async throws -> [LibraryItem] {
        let items: [LossyItem<LibraryItem>] = try await call("datastoreGet", [
            "authKey": .string(authKey),
            "collection": .string("libraryItem"),
            "ids": .array(ids.map(JSONValue.string)),
            "all": .bool(all),
        ])
        return items.compactMap(\.value)
    }

    public func putLibraryItems(authKey: String, _ changes: [LibraryItem]) async throws {
        guard !changes.isEmpty else { return }
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(changes))
        let _: JSONValue = try await call("datastorePut", [
            "authKey": .string(authKey),
            "collection": .string("libraryItem"),
            "changes": encoded,
        ])
    }

    // MARK: Transport

    private func call<T: Decodable>(_ method: String, _ body: [String: JSONValue]) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: "api/\(method)"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await session.data(for: request)
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let error = envelope.error {
            throw StremioAPIError(message: error.message, code: error.code)
        }
        guard let result = envelope.result else {
            throw StremioAPIError(message: "Empty response from Stremio API", code: -1)
        }
        return result
    }
}

private struct Envelope<T: Decodable>: Decodable {
    struct APIError: Decodable {
        var message: String
        var code: Int
    }

    var result: T?
    var error: APIError?
}

private struct CollectionResponse: Decodable {
    var addons: [LossyItem<AddonDescriptor>]
    var lastModified: String?
}

struct LossyItem<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
