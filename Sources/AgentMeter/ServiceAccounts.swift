import Combine
import Foundation
import Security
import UsageCore

struct ServiceAccountProfile: Codable, Identifiable {
    let id: String
    let provider: ServiceAccount
    var name: String
    var region = KimiRegion.china
    var reportKeyID: String?
    var creditBalance: OpenAICreditSnapshot?
    var usage: ServiceUsage?
    var message: String?
    var nextRefresh: Date = .distantPast
    var adminKey: AdminKeyInfo?
    var adminKeyCheckedAt: Date?

    var title: String { name.isEmpty ? provider.title : name }
    var keyRejected: Bool { nextRefresh == .distantFuture }
    var canRotate: Bool { provider.rotatesKeys && adminKey != nil && !keyRejected }

    func keyExpiry(at now: Date) -> String? {
        guard let expires = adminKey?.expiresAt else { return nil }
        let date = expires.formatted(.dateTime.month(.abbreviated).day())
        guard expires > now else { return String(localized: "Key expired \(date)") }
        let days = Int(ceil(expires.timeIntervalSince(now) / 86_400))
        let expiry = String(localized: "Key expires \(date)")
        return days <= 14 ? expiry + " · " + String(localized: "in \(days) days") : expiry
    }

    func needsKeyAttention(at now: Date) -> Bool {
        keyRejected || (adminKey?.expiresAt).map { $0.timeIntervalSince(now) < 14 * 86_400 } == true
    }
}

struct OpenAICreditSnapshot: Codable {
    let amountUSD: Decimal
    let capturedAt: Date

    static func parseAmount(_ text: String) -> Decimal? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = raw.hasPrefix("$") ? String(raw.dropFirst()).trimmingCharacters(in: .whitespaces) : raw
        guard amount.range(of: #"^[+-]?[0-9]{1,12}([.,][0-9]{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: amount.replacingOccurrences(of: ",", with: "."),
                       locale: Locale(identifier: "en_US_POSIX"))
    }
}

private struct LegacyServiceAccountState: Decodable {
    let connected: Bool
    let region: KimiRegion
    let usage: ServiceUsage?
    let message: String?
    let nextRefresh: Date
}

@MainActor
final class ServiceAccounts: ObservableObject {
    @Published private(set) var states: [ServiceAccountProfile] = []
    @Published private(set) var loading: Set<String> = []
    private let client = ServiceUsageClient()
    private let vault = AccountVault()
    private var keys: [String: String] = [:]
    private let defaults: UserDefaults
    private var tasks: [String: Task<Void, Never>] = [:]
    private var requests: [String: UUID] = [:]
    private let defaultsKey = "service-accounts.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: defaultsKey) {
            states = (try? decoder.decode([ServiceAccountProfile].self, from: data)) ?? []
        } else if let data = defaults.data(forKey: "service-accounts.v1"),
                  let legacy = try? decoder.decode([ServiceAccount: LegacyServiceAccountState].self, from: data) {
            states = ServiceAccount.allCases.compactMap { provider in
                guard let previous = legacy[provider], previous.connected else { return nil }
                return ServiceAccountProfile(id: provider.rawValue, provider: provider, name: "",
                                             region: previous.region, usage: previous.usage,
                                             message: previous.message, nextRefresh: previous.nextRefresh)
            }
            save()
        }
        for index in states.indices {
            if let usage = states[index].usage,
               usage.windows.count > 8 || usage.observedAt > .now.addingTimeInterval(60)
               || !usage.windows.allSatisfy({ (0...100).contains($0.usedPercent) }) {
                states[index].usage = nil
            }
        }
    }

    func refresh(force: Bool = false) {
        for state in states {
            let id = state.id
            guard !loading.contains(id), force || state.nextRefresh <= .now else { continue }
            let request = begin(id)
            tasks[id] = Task {
                defer { finish(id, request: request) }
                var updated = state
                do {
                    let key = try keys[id] ?? vault.read(id, provider: state.provider)
                    keys[id] = key
                    updated.usage = try await client.fetch(state.provider, key: key, region: state.region,
                                                           reportKeyID: state.reportKeyID)
                    updated.message = nil
                    updated.nextRefresh = .now.addingTimeInterval(300)
                    if state.provider.rotatesKeys,
                       (state.adminKeyCheckedAt ?? .distantPast) < .now.addingTimeInterval(-12 * 3600) {
                        do {
                            updated.adminKey = try await client.adminKeyInfo(state.provider, key: key)
                            updated.adminKeyCheckedAt = .now
                        } catch {}
                    }
                } catch {
                    updated.message = (error as? ServiceUsageError)?.message
                        ?? (error as? AccountVault.VaultError)?.errorDescription
                        ?? String(localized: "Connection failed. Will retry automatically.")
                    updated.nextRefresh = .now.addingTimeInterval(300)
                    if case .rateLimited(let until) = error as? ServiceUsageError { updated.nextRefresh = until }
                    switch error as? ServiceUsageError {
                    case .invalidKey, .invalidAdminKey, .billingAccessDenied: updated.nextRefresh = .distantFuture
                    default: break
                    }
                }
                guard requests[id] == request, !Task.isCancelled,
                      let index = states.firstIndex(where: { $0.id == id }) else { return }
                updated.name = states[index].name
                updated.creditBalance = states[index].creditBalance
                states[index] = updated
                save()
            }
        }
    }

    func connect(_ provider: ServiceAccount, replacing profile: ServiceAccountProfile? = nil,
                 name: String, key: String, region: KimiRegion, reportKeyID: String? = nil) async throws {
        let id = profile?.id ?? UUID().uuidString
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportKeyID = try provider.reportKeyID(reportKeyID)
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if let profile {
            guard let index = states.firstIndex(where: { $0.id == id && $0.provider == provider }) else { return }
            if key.isEmpty && reportKeyID == states[index].reportKeyID {
                guard region == states[index].region else { throw ServiceUsageError.invalidKey }
                states[index].name = name.isEmpty ? profile.title : name
                save()
                return
            }
        }
        let request = begin(id)
        defer { finish(id, request: request) }
        let credential = key.isEmpty && profile != nil ? try keys[id] ?? vault.read(id, provider: provider) : key
        let usage = try await client.fetch(provider, key: credential, region: region, reportKeyID: reportKeyID)
        guard requests[id] == request, !Task.isCancelled else { return }
        if !key.isEmpty { try vault.save(key, for: id, provider: provider) }
        keys[id] = credential

        var updated = ServiceAccountProfile(id: id, provider: provider,
                                            name: name.isEmpty ? (profile?.title ?? suggestedName(for: provider)) : name,
                                            region: region, reportKeyID: reportKeyID, usage: usage,
                                            nextRefresh: .now.addingTimeInterval(300))
        if let index = states.firstIndex(where: { $0.id == id }) {
            if name.isEmpty { updated.name = states[index].name }
            if key.isEmpty {
                updated.creditBalance = states[index].creditBalance
                updated.adminKey = states[index].adminKey
                updated.adminKeyCheckedAt = states[index].adminKeyCheckedAt
            }
            states[index] = updated
        } else {
            states.append(updated)
        }
        save()
    }

    func rotateKey(_ id: String) async throws -> Bool {
        guard let profile = states.first(where: { $0.id == id }), profile.canRotate, let old = profile.adminKey else {
            throw ServiceUsageError.invalidKey
        }
        let request = begin(id)
        defer {
            finish(id, request: request)
            refresh(force: true)
        }
        let current = try keys[id] ?? vault.read(id, provider: profile.provider)
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        let created = try await client.createAdminKey(profile.provider, key: current, replacing: old,
                                                      name: "Agent Meter \(stamp) \(UUID().uuidString.prefix(6))")
        do {
            try vault.save(created.key, for: id, provider: profile.provider)
        } catch {
            try? await client.revokeAdminKey(profile.provider, key: current, id: created.info.id)
            throw error
        }
        keys[id] = created.key
        let removed = (try? await client.revokeAdminKey(profile.provider, key: created.key, id: old.id)) != nil
        if let index = states.firstIndex(where: { $0.id == id }) {
            states[index].adminKey = created.info
            states[index].adminKeyCheckedAt = .now
            states[index].nextRefresh = .distantPast
            save()
        }
        return removed
    }

    func setOpenAICreditBalance(_ amount: Decimal?, for id: String) {
        guard let index = states.firstIndex(where: {
            $0.id == id && $0.provider == .openAI && $0.reportKeyID == nil
        }) else { return }
        states[index].creditBalance = amount.map { OpenAICreditSnapshot(amountUSD: $0, capturedAt: .now) }
        save()
    }

    func suggestedName(for provider: ServiceAccount) -> String {
        let names = Set(states.filter { $0.provider == provider }.map(\.title))
        if !names.contains(provider.title) { return provider.title }
        var number = 2
        while names.contains("\(provider.title) \(number)") { number += 1 }
        return "\(provider.title) \(number)"
    }

    func disconnect(_ id: String) throws {
        guard let profile = states.first(where: { $0.id == id }) else { return }
        try vault.remove(id, provider: profile.provider)
        keys[profile.id] = nil
        if let request = requests[id] {
            tasks[id]?.cancel()
            finish(id, request: request)
        }
        states.removeAll { $0.id == id }
        save()
    }

    private func begin(_ id: String) -> UUID {
        tasks[id]?.cancel()
        let request = UUID()
        requests[id] = request
        loading.insert(id)
        return request
    }

    private func finish(_ id: String, request: UUID) {
        guard requests[id] == request else { return }
        requests.removeValue(forKey: id)
        tasks.removeValue(forKey: id)
        loading.remove(id)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

private struct AccountVault {
    private static let service = "local.agentmeter.service-keys"

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Agent Meter", isDirectory: true)
            .appendingPathComponent("service-keys.json")
    }

    private func account(_ id: String, provider: ServiceAccount) -> String {
        id == provider.rawValue ? id : "\(provider.rawValue).\(id)"
    }

    private func query(_ id: String, provider: ServiceAccount) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account(id, provider: provider)]
    }

    func read(_ id: String, provider: ServiceAccount) throws -> String {
        if let key = try stored()[account(id, provider: provider)] { return key }
        var query = query(id, provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw ServiceUsageError.invalidKey }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw VaultError.read }
        try? save(key, for: id, provider: provider)
        return key
    }

    func save(_ key: String, for id: String, provider: ServiceAccount) throws {
        var keys = try stored()
        keys[account(id, provider: provider)] = key
        try write(keys)
    }

    func remove(_ id: String, provider: ServiceAccount) throws {
        var keys = try stored()
        if keys.removeValue(forKey: account(id, provider: provider)) != nil { try write(keys) }
        SecItemDelete(query(id, provider: provider) as CFDictionary)
    }

    private func stored() throws -> [String: String] {
        guard let url = Self.fileURL else { throw VaultError.read }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return [:] }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 256 * 1024,
              let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String: String].self, from: data) else { throw VaultError.read }
        return keys
    }

    private func write(_ keys: [String: String]) throws {
        guard let url = Self.fileURL else { throw VaultError.save }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(keys)
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".service-keys-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else { throw VaultError.save }
            guard rename(temporary.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw VaultError.save
            }
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.save
        }
    }

    enum VaultError: LocalizedError {
        case read, save, remove
        var errorDescription: String? {
            switch self {
            case .read: String(localized: "Agent Meter could not read the saved API key.")
            case .save: String(localized: "Agent Meter could not save the API key.")
            case .remove: String(localized: "Agent Meter could not remove the API key.")
            }
        }
    }
}
