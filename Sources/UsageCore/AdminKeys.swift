import Foundation

public struct AdminKeyInfo: Codable, Sendable, Equatable {
    public let id: String
    public let createdAt: Date?
    public let expiresAt: Date?

    public init(id: String, createdAt: Date?, expiresAt: Date?) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    var lifetime: Int? {
        guard let createdAt, let expiresAt else { return nil }
        return Int(min(31_536_000, max(86_400, expiresAt.timeIntervalSince(createdAt))).rounded())
    }
}

enum OpenAIAdminKeys {
    struct Key: Decodable {
        let id: String
        let name: String?
        let value: String?
        let redactedValue: String?
        let createdAt: Double?
        let expiresAt: Double?
        let deleted: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name, value, deleted, redactedValue = "redacted_value", createdAt = "created_at", expiresAt = "expires_at"
        }

        var info: AdminKeyInfo {
            AdminKeyInfo(id: id, createdAt: createdAt.map(Date.init(timeIntervalSince1970:)),
                         expiresAt: expiresAt.map(Date.init(timeIntervalSince1970:)))
        }
    }

    struct Page: Decodable {
        let data: [Key]
        let hasMore: Bool?
        let lastID: String?

        enum CodingKeys: String, CodingKey { case data, hasMore = "has_more", lastID = "last_id" }
    }

    static func matches(_ redacted: String, key: String) -> Bool {
        guard redacted.count == key.count, let first = redacted.firstIndex(of: "*"),
              let last = redacted.lastIndex(of: "*") else { return false }
        let head = redacted[..<first]
        let tail = redacted[redacted.index(after: last)...]
        return head.count >= 3 && tail.count >= 4 && key.hasPrefix(head) && key.hasSuffix(tail)
    }

    static func validID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
    }

    static func request(_ key: String, id: String? = nil, query: [URLQueryItem]? = nil) throws -> URLRequest {
        var url = URLComponents(string: "https://api.openai.com/v1/organization/admin_api_keys")!
        if let id {
            guard validID(id) else { throw ServiceUsageError.invalidResponse }
            url.path += "/" + id
        }
        url.queryItems = query
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }
}

extension OpenAIAdminKeys {
    typealias Load = @Sendable (URLRequest) async throws -> Data

    static func list(key: String, load: Load) async throws -> [Key] {
        var after: String?
        var keys: [Key] = []
        for _ in 0..<10 {
            let query = [URLQueryItem(name: "limit", value: "100")] + (after.map { [URLQueryItem(name: "after", value: $0)] } ?? [])
            let data = try await load(request(key, query: query))
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw ServiceUsageError.invalidResponse }
            keys += page.data
            guard page.hasMore == true, let next = page.lastID, next != after, validID(next) else { break }
            after = next
        }
        return keys
    }

    static func info(key: String, load: Load) async throws -> AdminKeyInfo? {
        let found = try await list(key: key, load: load).filter { $0.redactedValue.map { matches($0, key: key) } == true }
        return found.count == 1 ? found[0].info : nil
    }

    static func create(key: String, replacing old: AdminKeyInfo, name: String,
                       load: Load) async throws -> (key: String, info: AdminKeyInfo) {
        let title = String(name.prefix(60))
        var body: [String: Any] = ["name": title]
        if let lifetime = old.lifetime { body["expires_in_seconds"] = lifetime }
        var request = try request(key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let data = try await load(request)
            guard let created = try? JSONDecoder().decode(Key.self, from: data),
                  let value = created.value, value.hasPrefix("sk-admin-"), value.utf8.count <= 4096,
                  !value.unicodeScalars.contains(where: { $0.value < 33 || $0.value > 126 }),
                  validID(created.id) else { throw ServiceUsageError.invalidResponse }
            return (value, created.info)
        } catch {
            let orphans = (try? await list(key: key, load: load))?.filter { $0.name == title && $0.id != old.id }
            for orphan in orphans ?? [] { try? await revoke(key: key, id: orphan.id, load: load) }
            throw error
        }
    }

    static func revoke(key: String, id: String, load: Load) async throws {
        var request = try request(key, id: id)
        request.httpMethod = "DELETE"
        let data = try await load(request)
        guard let result = try? JSONDecoder().decode(Key.self, from: data), result.id == id, result.deleted == true else {
            throw ServiceUsageError.invalidResponse
        }
    }
}

extension ServiceUsageClient {
    public func adminKeyInfo(_ account: ServiceAccount, key: String) async throws -> AdminKeyInfo? {
        guard account.rotatesKeys else { return nil }
        return try await OpenAIAdminKeys.info(key: key) { try await self.send($0, billing: true) }
    }

    public func createAdminKey(_ account: ServiceAccount, key: String, replacing old: AdminKeyInfo,
                               name: String) async throws -> (key: String, info: AdminKeyInfo) {
        guard account.rotatesKeys else { throw ServiceUsageError.invalidResponse }
        return try await OpenAIAdminKeys.create(key: key, replacing: old, name: name) { try await self.send($0, billing: true) }
    }

    public func revokeAdminKey(_ account: ServiceAccount, key: String, id: String) async throws {
        guard account.rotatesKeys else { throw ServiceUsageError.invalidResponse }
        try await OpenAIAdminKeys.revoke(key: key, id: id) { try await self.send($0, billing: true) }
    }
}
