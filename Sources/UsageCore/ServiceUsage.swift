import CoreFoundation
import Foundation

public enum ServiceAccount: String, CaseIterable, Codable, Sendable, Identifiable {
    case zai, kimi, openAI, anthropic, xai

    public var id: Self { self }
    public var isBilling: Bool { self == .openAI || self == .anthropic || self == .xai }
    public var filtersByKeyID: Bool { self == .openAI || self == .anthropic }
    public var rotatesKeys: Bool { self == .openAI }

    public var title: String {
        switch self {
        case .zai: "Z.ai"
        case .kimi: "Kimi Code"
        case .openAI: "OpenAI API"
        case .anthropic: "Anthropic API"
        case .xai: "Grok API"
        }
    }

    public var symbol: String {
        switch self {
        case .zai: "z.square"
        case .kimi: "k.square"
        case .openAI: "o.square"
        case .anthropic: "a.square"
        case .xai: "x.square"
        }
    }

    public func reportKeyID(_ value: String?) throws -> String? {
        guard filtersByKeyID, let id = value?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        let prefix = self == .openAI ? "key_" : "apikey_"
        guard id.hasPrefix(prefix), id.count > prefix.count, id.utf8.count <= 200,
              id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ServiceUsageError.invalidReportKeyID(prefix)
        }
        return id
    }
}

public enum KimiRegion: String, CaseIterable, Codable, Sendable {
    case china, international

    public var title: String { self == .china ? "Kimi.com" : "Kimi.ai" }
}

public struct ServiceWindow: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let resetsAt: Date?
}

public struct ServiceUsage: Codable, Sendable {
    public let observedAt: Date
    public let windows: [ServiceWindow]
    public let billing: BillingUsage?

    init(observedAt: Date, windows: [ServiceWindow], billing: BillingUsage? = nil) {
        self.observedAt = observedAt
        self.windows = windows
        self.billing = billing
    }

    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(observedAt) >= 3600
    }
}

public enum ServiceUsageError: LocalizedError, Sendable {
    case invalidKey, invalidAdminKey, projectKeyForBilling, personalKeyForBilling, billingAccessDenied, invalidReportKeyID(String)
    case xaiTeamMissing
    case unavailable, invalidResponse, reportRejected, tooLarge, rateLimited(Date)

    public var message: String {
        switch self {
        case .invalidKey: "Check the API key and subscription."
        case .invalidAdminKey: "Paste the full organization Admin API key shown when you create it."
        case .projectKeyForBilling: "This is an OpenAI project key (sk-proj-…). For Usage and Costs, create a key on the organization’s Admin keys page and copy the full secret."
        case .personalKeyForBilling: "This is a Claude Console personal key (sk-ant-usr-…). Use Create admin key on the Admin keys page and paste the full sk-ant-admin01-… secret."
        case .billingAccessDenied: "The provider rejected this key. Check that it is active and can read usage and billing."
        case .xaiTeamMissing: "This xAI management key is not scoped to a team. Create a team management key in the xAI Console."
        case .invalidReportKeyID(let prefix): "Enter a key ID beginning with \(prefix), or leave it blank for the organization."
        case .reportRejected: "The provider rejected the report request. Check the API key ID and organization."
        case .unavailable: "Service temporarily unavailable."
        case .invalidResponse: "The service returned an unsupported quota response."
        case .tooLarge: "The quota response exceeded the size limit."
        case .rateLimited: "Rate limited. Automatic refresh will retry later."
        }
    }
    public var errorDescription: String? { message }
}

public enum ServiceUsageParser {
    public static func parse(_ data: Data, account: ServiceAccount, now: Date = .now) throws -> ServiceUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceUsageError.invalidResponse
        }
        guard !account.isBilling else { throw ServiceUsageError.invalidResponse }
        let windows = account == .zai ? try zai(root, now: now) : kimi(root)
        guard !windows.isEmpty else { throw ServiceUsageError.invalidResponse }
        return ServiceUsage(observedAt: now, windows: windows)
    }

    private static func zai(_ root: [String: Any], now: Date) throws -> [ServiceWindow] {
        guard root["success"] as? Bool != false, [nil, 0, 200].contains(number(root["code"])),
              let data = root["data"] as? [String: Any], let limits = data["limits"] as? [[String: Any]] else {
            throw ServiceUsageError.invalidResponse
        }
        return limits.enumerated().compactMap { index, limit in
            guard let type = limit["type"] as? String,
                  ["TOKENS_LIMIT", "CREDIT_LIMIT", "TIME_LIMIT"].contains(type),
                  let supplied = number(limit["percentage"]), supplied >= 0 else { return nil }
            var percent = supplied
            if let maximum = number(limit["usage"]), maximum > 0 {
                if let used = number(limit["currentValue"]), used >= 0 {
                    percent = used / maximum * 100
                } else if let remaining = number(limit["remaining"]), remaining >= 0 {
                    percent = (maximum - remaining) / maximum * 100
                }
            }
            guard percent.isFinite else { return nil }
            let minutesPerUnit: [Double: Double] = [1: 1440, 3: 60, 5: 1, 6: 10080]
            let minutes = number(limit["unit"]).flatMap { minutesPerUnit[$0] }
                .flatMap { multiplier in number(limit["number"]).map { $0 * multiplier } }
            let title = type == "TIME_LIMIT" ? "MCP" : windowTitle(minutes)
            var reset = number(limit["nextResetTime"]).flatMap { validDate($0 / 1000) }
            if type != "TIME_LIMIT", minutes == 300, let date = reset, date.timeIntervalSince(now) > 18060 {
                reset = nil
            }
            return ServiceWindow(id: "zai-\(index)", title: title, usedPercent: min(100, max(0, percent)), resetsAt: reset)
        }
    }

    private static func kimi(_ root: [String: Any]) -> [ServiceWindow] {
        let pools = root["usages"] as? [String: Any] ?? [:]
        var windows: [ServiceWindow] = []
        for (id, minutes) in [("limit_5h", 300.0), ("limit_7d", 10080), ("limit_month_total", 43200)] {
            guard let pool = pools[id] as? [String: Any], let ratio = number(pool["used_ratio"]), ratio >= 0 else { continue }
            windows.append(ServiceWindow(id: id, title: windowTitle(minutes), usedPercent: min(1, ratio) * 100,
                                         resetsAt: timestamp(pool["reset_time"] as? String)))
        }
        let hasMonthlyPool = windows.contains { $0.id == "limit_month_total" }
        if let usage = root["usage"] as? [String: Any],
           let weekly = countWindow(usage, id: "limit_7d", minutes: 10080) {
            mergeKimiCount(weekly, into: &windows, allowZeroFallback: !hasMonthlyPool)
        }
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let window = limit["window"] as? [String: Any],
                      let duration = number(window["duration"]), duration > 0,
                      let unit = window["timeUnit"] as? String,
                      let multiplier = ["TIME_UNIT_MINUTE": 1.0, "TIME_UNIT_HOUR": 60, "TIME_UNIT_DAY": 1440][unit],
                      duration * multiplier == 300,
                      let detail = limit["detail"] as? [String: Any],
                      let usage = countWindow(detail, id: "limit_5h", minutes: 300) else { continue }
                mergeKimiCount(usage, into: &windows, allowZeroFallback: !hasMonthlyPool)
                break
            }
        }
        return windows
    }

    private static func mergeKimiCount(_ count: ServiceWindow, into windows: inout [ServiceWindow],
                                       allowZeroFallback: Bool) {
        guard let index = windows.firstIndex(where: { $0.id == count.id }) else {
            if count.id == "limit_5h" { windows.insert(count, at: 0) }
            else { windows.append(count) }
            return
        }
        let ratio = windows[index]
        if allowZeroFallback, ratio.usedPercent == 0, count.usedPercent > 0,
           let first = ratio.resetsAt, let second = count.resetsAt, abs(first.timeIntervalSince(second)) <= 2 {
            windows[index] = count
        }
    }
    private static func countWindow(_ value: [String: Any], id: String, minutes: Double) -> ServiceWindow? {
        guard let limit = number(value["limit"]), limit > 0 else { return nil }
        let used = number(value["used"]) ?? number(value["remaining"]).map { limit - $0 }
        guard let used, used >= 0 else { return nil }
        let reset = ["resetTime", "resetAt", "reset_time", "reset_at"].compactMap { value[$0] as? String }.first
        return ServiceWindow(id: id, title: windowTitle(minutes), usedPercent: min(100, used / limit * 100),
                             resetsAt: timestamp(reset))
    }

    private static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            parsed = n.doubleValue
        } else if let text = value as? String {
            parsed = Double(text)
        } else {
            parsed = nil
        }
        return parsed.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func validDate(_ epoch: Double) -> Date? {
        epoch > 0 && epoch < 32_503_680_000 ? Date(timeIntervalSince1970: epoch) : nil
    }

    private static func windowTitle(_ minutes: Double?) -> String {
        switch minutes {
        case 300: "5-hour rolling"
        case 10080: "7-day rolling"
        case 43200: "Monthly total"
        case .some(let value) where value > 0: "\(Int(min(value, 525600))) min"
        default: "Coding Plan"
        }
    }
}
