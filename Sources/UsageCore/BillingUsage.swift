import Foundation

public struct BillingUsage: Codable, Sendable {
    public let monthStart: Date
    public let tokens: Int64?
    public let requests: Int64?
    public let costUSD: Decimal?
    public let dataThrough: Date?
    public var creditUSD: Decimal? = nil
    public var limitUSD: Decimal? = nil

    public static func startOfMonth(at date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateInterval(of: .month, for: date)?.start ?? date
    }
}

struct BillingQuery: Sendable {
    enum Metric { case usage, cost }

    let account: ServiceAccount
    let keyID: String?
    let start: Date
    let end: Date

    func request(_ metric: Metric, key: String, page: String?) throws -> URLRequest {
        var url = URLComponents()
        url.scheme = "https"
        var query: [URLQueryItem]
        switch account {
        case .openAI:
            if key.hasPrefix("sk-proj-") { throw ServiceUsageError.projectKeyForBilling }
            guard key.hasPrefix("sk-admin-") else { throw ServiceUsageError.invalidAdminKey }
            url.host = "api.openai.com"
            url.path = metric == .usage ? "/v1/organization/usage/completions" : "/v1/organization/costs"
            let startTime = Int(start.timeIntervalSince1970)
            let endTime = Int(end.timeIntervalSince1970)
            let exclusiveEnd = metric == .cost ? (endTime / 86400 + 1) * 86400 : max(startTime + 1, endTime)
            query = [
                .init(name: "start_time", value: String(startTime)),
                .init(name: "end_time", value: String(exclusiveEnd)),
                .init(name: "bucket_width", value: "1d"),
                .init(name: "limit", value: "31"),
            ]
        case .anthropic:
            if key.hasPrefix("sk-ant-usr-") { throw ServiceUsageError.personalKeyForBilling }
            guard key.hasPrefix("sk-ant-admin") else { throw ServiceUsageError.invalidAdminKey }
            url.host = "api.anthropic.com"
            url.path = "/v1/organizations/analytics/" + (metric == .usage ? "usage" : "cost")
            let format = ISO8601DateFormatter()
            query = [.init(name: "starting_at", value: format.string(from: start)),
                     .init(name: "ending_at", value: format.string(from: end))]
        case .zai, .kimi, .xai:
            throw ServiceUsageError.invalidResponse
        }
        if let keyID {
            query += [.init(name: "api_key_ids[]", value: keyID), .init(name: "group_by[]", value: "api_key_id")]
        }
        if let page { query.append(.init(name: "page", value: page)) }
        url.queryItems = query
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let endpoint = url.url else { throw ServiceUsageError.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        if account == .openAI {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            request.setValue("analytics-usage-cost-2026-08-24", forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }
}

struct BillingPage<Row: Decodable>: Decodable {
    let data: [Row]
    let hasMore: Bool
    let nextPage: String?
    let dataRefreshedAt: String?

    enum CodingKeys: String, CodingKey {
        case data, hasMore = "has_more", nextPage = "next_page", dataRefreshedAt = "data_refreshed_at"
    }
}

struct OpenAIBucket<Result: Decodable & Sendable>: Decodable, Sendable {
    let results: [Result]
}

struct OpenAIModelUsage: Decodable, Sendable {
    let inputTokens: Int64
    let outputTokens: Int64
    let requests: Int64
    let keyID: String?

    enum CodingKeys: String, CodingKey {
        case keyID = "api_key_id"
        case inputTokens = "input_tokens", outputTokens = "output_tokens", requests = "num_model_requests"
    }
}

struct OpenAICost: Decodable, Sendable {
    struct Amount: Decodable, Sendable {
        let value: Decimal
        let currency: String

        enum CodingKeys: String, CodingKey { case value, currency }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            currency = try values.decode(String.self, forKey: .currency)
            if let exact = try? values.decode(Decimal.self, forKey: .value) {
                value = exact
            } else {
                value = Decimal(try values.decode(Double.self, forKey: .value))
            }
        }
    }

    let amount: Amount
    let keyID: String?

    enum CodingKeys: String, CodingKey { case amount, keyID = "api_key_id" }
}

struct AnthropicReportGroup: Decodable, Sendable {
    let keyID: String?

    enum CodingKeys: String, CodingKey { case keyID = "api_key_id" }
}

struct AnthropicModelUsage: Decodable, Sendable {
    struct Usage: Decodable, Sendable {
        let totalTokens: Int64
        let requests: Int64

        enum CodingKeys: String, CodingKey { case totalTokens = "total_tokens", requests }
    }

    let usage: Usage
    let group: AnthropicReportGroup?
}

struct AnthropicCost: Decodable, Sendable {
    struct Cost: Decodable, Sendable {
        let amount: String
        let currency: String
    }

    let cost: Cost
    let group: AnthropicReportGroup?
}

enum BillingTotals {
    static func count(_ values: [Int64]) throws -> Int64 {
        try values.reduce(0) { total, value in
            let (next, overflow) = total.addingReportingOverflow(value)
            guard value >= 0, !overflow else { throw ServiceUsageError.invalidResponse }
            return next
        }
    }

    static func openAICost(_ rows: [OpenAICost]) throws -> Decimal {
        try rows.reduce(Decimal.zero) { total, row in
            let value = total + row.amount.value
            guard row.amount.currency.uppercased() == "USD", value.isFinite else {
                throw ServiceUsageError.invalidResponse
            }
            return value
        }
    }

    static func anthropicCost(_ rows: [AnthropicCost]) throws -> Decimal {
        let cents = try rows.reduce(Decimal.zero) { total, row in
            guard row.cost.currency == "USD",
                  row.cost.amount.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let amount = Decimal(string: row.cost.amount, locale: Locale(identifier: "en_US_POSIX")),
                  (total + amount).isFinite else { throw ServiceUsageError.invalidResponse }
            return total + amount
        }
        return cents / 100
    }
}

extension BillingQuery {
    func fetch(key: String, load: @escaping @Sendable (URLRequest) async throws -> Data) async throws -> ServiceUsage {
        let report: BillingUsage
        switch account {
        case .openAI:
            async let usage = fetchReport(OpenAIBucket<OpenAIModelUsage>.self, metric: .usage, key: key, load: load)
            async let costs = fetchReport(OpenAIBucket<OpenAICost>.self, metric: .cost, key: key, load: load)
            let (used, billed) = try await (usage, costs)
            let rows = used.rows.flatMap(\.results)
            let costRows = billed.rows.flatMap(\.results)
            try checkScope(rows.map(\.keyID))
            try checkScope(costRows.map(\.keyID))
            report = BillingUsage(monthStart: start, tokens: try BillingTotals.count(rows.flatMap { [$0.inputTokens, $0.outputTokens] }),
                                  requests: try BillingTotals.count(rows.map(\.requests)),
                                  costUSD: costRows.isEmpty ? nil : try BillingTotals.openAICost(costRows), dataThrough: nil)
        case .anthropic:
            async let usage = fetchReport(AnthropicModelUsage.self, metric: .usage, key: key, load: load)
            async let costs = fetchReport(AnthropicCost.self, metric: .cost, key: key, load: load)
            let (used, billed) = try await (usage, costs)
            try checkScope(used.rows.map { $0.group?.keyID })
            try checkScope(billed.rows.map { $0.group?.keyID })
            guard (used.rows.isEmpty || used.through != nil), (billed.rows.isEmpty || billed.through != nil) else {
                throw ServiceUsageError.invalidResponse
            }
            report = BillingUsage(monthStart: start,
                                  tokens: try used.through.map { _ in try BillingTotals.count(used.rows.map(\.usage.totalTokens)) },
                                  requests: try used.through.map { _ in try BillingTotals.count(used.rows.map(\.usage.requests)) },
                                  costUSD: try billed.through.map { _ in try BillingTotals.anthropicCost(billed.rows) },
                                  dataThrough: [used.through, billed.through].compactMap { $0 }.min())
        case .xai:
            return try await XAIBilling.fetch(key: key, now: end, load: load)
        case .zai, .kimi:
            throw ServiceUsageError.invalidResponse
        }
        return ServiceUsage(observedAt: end, windows: [], billing: report)
    }

    private func checkScope(_ reportedIDs: [String?]) throws {
        if let keyID, !reportedIDs.allSatisfy({ $0 == keyID }) { throw ServiceUsageError.reportRejected }
    }

    private func fetchReport<Row: Decodable & Sendable>(_ row: Row.Type, metric: Metric, key: String,
                                                       load: @Sendable (URLRequest) async throws -> Data) async throws
        -> (rows: [Row], through: Date?) {
        var rows: [Row] = []
        var through: Date?
        var cursor: String?
        var cursors = Set<String>()
        for _ in 0..<16 {
            let request = try request(metric, key: key, page: cursor)
            let data = try await load(request)
            guard let page = try? JSONDecoder().decode(BillingPage<Row>.self, from: data) else {
                throw ServiceUsageError.invalidResponse
            }
            rows.append(contentsOf: page.data)
            if let refreshed = page.dataRefreshedAt.flatMap(timestamp) { through = refreshed }
            if !page.hasMore { return (rows, through) }
            guard let next = page.nextPage, !next.isEmpty, next.utf8.count <= 4096, cursors.insert(next).inserted else {
                throw ServiceUsageError.invalidResponse
            }
            cursor = next
        }
        throw ServiceUsageError.tooLarge
    }
}

enum XAIBilling {
    static func fetch(key: String, now: Date,
                      load: @escaping @Sendable (URLRequest) async throws -> Data) async throws -> ServiceUsage {
        guard let validation = object(try await load(request("/auth/management-keys/validation", key: key))) else {
            throw ServiceUsageError.invalidResponse
        }
        let scoped = validation["scope"] as? String == "SCOPE_TEAM" ? validation["scopeId"] as? String : nil
        guard let team = scoped ?? validation["teamId"] as? String,
              team.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else {
            throw ServiceUsageError.xaiTeamMissing
        }
        let base = "/v1/billing/teams/" + team
        async let invoiceData = load(request(base + "/postpaid/invoice/preview", key: key))
        async let balanceData = load(request(base + "/prepaid/balance", key: key))
        async let limitData = try? load(request(base + "/postpaid/spending-limits", key: key))
        guard let invoice = object(try await invoiceData), let balance = object(try await balanceData) else {
            throw ServiceUsageError.invalidResponse
        }
        let limits = (await limitData).flatMap(object)
        let core = invoice["coreInvoice"] as? [String: Any] ?? [:]
        let cost = cents(core["amountBeforeVat"]) ?? cents(core["amountBeforeVatLimitedAndUnlimited"])
        var cycleStart = BillingUsage.startOfMonth(at: now)
        if let cycle = invoice["billingCycle"] as? [String: Any], let year = cycle["year"] as? Int,
           let month = cycle["month"] as? Int, (1...12).contains(month) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            cycleStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? cycleStart
        }
        let spending = (limits?["spendingLimits"] as? [String: Any])?["effectiveSl"]
        var report = BillingUsage(monthStart: cycleStart, tokens: nil, requests: nil,
                                  costUSD: cost.map { $0 / 100 }, dataThrough: nil)
        report.creditUSD = cents(balance["total"]).map { $0 / 100 }
        report.limitUSD = cents(spending).map { $0 / 100 }
        return ServiceUsage(observedAt: now, windows: [], billing: report)
    }

    static func request(_ path: String, key: String) throws -> URLRequest {
        guard let url = URL(string: "https://management-api.x.ai" + path) else { throw ServiceUsageError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func cents(_ value: Any?) -> Decimal? {
        let raw: String?
        if let wrapped = value as? [String: Any] { raw = wrapped["val"] as? String ?? (wrapped["val"] as? NSNumber)?.stringValue }
        else { raw = value as? String ?? (value as? NSNumber)?.stringValue }
        guard let raw, raw.range(of: #"^-?[0-9]{1,15}(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
    }
}
