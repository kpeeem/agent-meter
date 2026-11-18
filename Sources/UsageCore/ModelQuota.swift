import Foundation

public struct ModelQuota: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let quota: Quota
    public var id: String { name.lowercased() }

    public init?(name: String, quota: Quota?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quota, !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        self.name = trimmed
        self.quota = quota
    }

    func matches(_ other: ModelQuota) -> Bool {
        id == other.id || id.contains(other.id) || other.id.contains(id)
    }

    public static func newest(_ groups: [ModelQuota]...) -> [ModelQuota] {
        var result: [ModelQuota] = []
        for model in groups.joined() {
            if let index = result.firstIndex(where: { $0.matches(model) }) {
                if model.quota.observedAt > result[index].quota.observedAt { result[index] = model }
            } else {
                result.append(model)
            }
        }
        let order = ["opus", "sonnet"]
        func rank(_ model: ModelQuota) -> Int { order.firstIndex { model.id.contains($0) } ?? order.count }
        return result.sorted { (rank($0), $0.id) < (rank($1), $1.id) }
    }
}
