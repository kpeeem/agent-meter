import Foundation

public final class ServiceUsageClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }

    public func fetch(_ account: ServiceAccount, key: String, region: KimiRegion = .china,
        reportKeyID: String? = nil) async throws -> ServiceUsage {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096, !key.unicodeScalars.contains(where: { $0.value < 33 || $0.value > 126 }) else {
            throw account.isBilling ? ServiceUsageError.invalidAdminKey : ServiceUsageError.invalidKey
        }
        if account.isBilling {
            let now = Date.now
            let query = BillingQuery(account: account, keyID: try account.reportKeyID(reportKeyID),
                                     start: BillingUsage.startOfMonth(at: now), end: now)
            return try await query.fetch(key: key) { try await self.send($0, billing: true) }
        }
        let endpoint: String
        switch account {
        case .zai: endpoint = "https://api.z.ai/api/monitor/usage/quota/limit"
        case .kimi:
            endpoint = region == .china ? "https://api.kimi.com/coding/v1/usages" : "https://api.kimi.ai/coding/v1/usages"
        case .openAI, .anthropic, .xai: throw ServiceUsageError.invalidResponse
        }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        return try ServiceUsageParser.parse(data, account: account)
    }

    func send(_ original: URLRequest, billing: Bool = false) async throws -> Data {
        var request = original
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentMeter/0.7", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ServiceUsageError.unavailable }
        switch response.statusCode {
        case 200: break
        case 400 where billing: throw ServiceUsageError.reportRejected
        case 401, 403: throw billing ? ServiceUsageError.billingAccessDenied : ServiceUsageError.invalidKey
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(secondsFromGMT: 0)
            format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let seconds = Double(header) ?? format.date(from: header)?.timeIntervalSinceNow ?? 900
            throw ServiceUsageError.rateLimited(.now.addingTimeInterval(min(86400, max(300, seconds))))
        default: throw ServiceUsageError.unavailable
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1024 * 1024 else { throw ServiceUsageError.tooLarge }
            data.append(byte)
        }
        return data
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
