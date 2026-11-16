import Foundation
import XCTest
@testable import UsageCore

final class BillingUsageTests: XCTestCase {
    private let month = Date(timeIntervalSince1970: 1_793_491_200)
    private let now = Date(timeIntervalSince1970: 1_794_400_000)

    func testOpenAIPagesAndFiltersUsageAndCostsByKeyID() async throws {
        let query = BillingQuery(account: .openAI, keyID: "key_demo", start: month, end: now)
        let result = try await query.fetch(key: "sk-admin-test-fixture") { request in
            let url = try XCTUnwrap(request.url)
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.host, "api.openai.com")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(parts.queryItems?.first { $0.name == "api_key_ids[]" }?.value, "key_demo")
            XCTAssertEqual(parts.queryItems?.first { $0.name == "group_by[]" }?.value, "api_key_id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-admin-test-fixture")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))

            if parts.path == "/v1/organization/costs" {
                return Data(#"{"data":[{"results":[{"api_key_id":"key_demo","amount":{"value":12.35,"currency":"usd"}}]}],"has_more":false}"#.utf8)
            }
            XCTAssertEqual(parts.path, "/v1/organization/usage/completions")
            if let page = parts.queryItems?.first(where: { $0.name == "page" }) {
                XCTAssertEqual(page.value, "cursor+2")
                XCTAssertTrue(url.absoluteString.contains("page=cursor%2B2"))
                return Data(#"{"data":[{"results":[{"api_key_id":"key_demo","input_tokens":100,"output_tokens":200,"num_model_requests":2}]}],"has_more":false}"#.utf8)
            }
            return Data(#"{"data":[{"results":[{"api_key_id":"key_demo","input_tokens":30,"output_tokens":20,"num_model_requests":1}]}],"has_more":true,"next_page":"cursor+2"}"#.utf8)
        }
        let billing = try XCTUnwrap(result.billing)
        XCTAssertEqual(billing.costUSD, Decimal(string: "12.35"))
        XCTAssertEqual(billing.tokens, 350)
        XCTAssertEqual(billing.requests, 3)
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testAnthropicConvertsFractionalCentsAndPreservesFreshness() async throws {
        let query = BillingQuery(account: .anthropic, keyID: "apikey_demo", start: month, end: now)
        let result = try await query.fetch(key: "sk-ant-admin-test-fixture") { request in
            let url = try XCTUnwrap(request.url)
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.host, "api.anthropic.com")
            XCTAssertEqual(parts.queryItems?.first { $0.name == "api_key_ids[]" }?.value, "apikey_demo")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "analytics-usage-cost-2026-08-24")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-admin-test-fixture")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if parts.path == "/v1/organizations/analytics/cost" {
                return Data(#"{"data":[{"group":{"api_key_id":"apikey_demo"},"cost":{"amount":"41280.150000","currency":"USD"}}],"has_more":false,"data_refreshed_at":"2026-11-11T12:00:00Z"}"#.utf8)
            }
            XCTAssertEqual(parts.path, "/v1/organizations/analytics/usage")
            return Data(#"{"data":[{"group":{"api_key_id":"apikey_demo"},"usage":{"total_tokens":150,"requests":2}}],"has_more":false,"data_refreshed_at":"2026-11-11T11:00:00Z"}"#.utf8)
        }
        let billing = try XCTUnwrap(result.billing)
        XCTAssertEqual(billing.costUSD, Decimal(string: "412.8015"))
        XCTAssertEqual(billing.tokens, 150)
        XCTAssertEqual(billing.dataThrough, timestamp("2026-11-11T11:00:00Z"))
    }

    func testOrdinaryKeyAndUnscopedRowsAreRejected() async throws {
        let query = BillingQuery(account: .openAI, keyID: "key_demo", start: month, end: now)
        XCTAssertThrowsError(try query.request(.usage, key: "sk-proj-example", page: nil)) { error in
            guard case .projectKeyForBilling = error as? ServiceUsageError else {
                return XCTFail("Expected a project key error")
            }
        }
        XCTAssertThrowsError(try ServiceAccount.openAI.reportKeyID("sk-proj-example"))
        do {
            _ = try await query.fetch(key: "sk-admin-test-fixture") { request in
                if request.url?.path == "/v1/organization/costs" {
                    return Data(#"{"data":[],"has_more":false}"#.utf8)
                }
                return Data(#"{"data":[{"results":[{"api_key_id":"key_other","input_tokens":1,"output_tokens":1,"num_model_requests":1}]}],"has_more":false}"#.utf8)
            }
            XCTFail("A scoped request accepted another key's usage.")
        } catch ServiceUsageError.reportRejected {}
    }

    func testAnthropicMissingProviderDataRemainsUnavailable() async throws {
        let query = BillingQuery(account: .anthropic, keyID: nil, start: month, end: now)
        let result = try await query.fetch(key: "sk-ant-admin-test-fixture") { _ in
            Data(#"{"data":[],"has_more":false,"data_refreshed_at":null}"#.utf8)
        }
        XCTAssertNil(result.billing?.tokens)
        XCTAssertNil(result.billing?.costUSD)
    }

    func testAnthropicPersonalKeyGetsSpecificError() {
        let query = BillingQuery(account: .anthropic, keyID: nil, start: month, end: now)
        XCTAssertThrowsError(try query.request(.usage, key: "sk-ant-usr-fixture", page: nil)) { error in
            guard case .personalKeyForBilling = error as? ServiceUsageError else {
                return XCTFail("Expected a personal key error")
            }
        }
    }

    func testOpenAICostsIncludeTodayAndDoNotInventZero() async throws {
        let date = try XCTUnwrap(timestamp("2026-11-11T16:00:00Z"))
        let query = BillingQuery(account: .openAI, keyID: nil, start: BillingUsage.startOfMonth(at: date), end: date)
        let usage = try await query.fetch(key: "sk-admin-test-fixture") { request in
            if request.url?.path == "/v1/organization/costs" {
                let url = try XCTUnwrap(request.url)
                let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let end = try XCTUnwrap(timestamp("2026-11-12T00:00:00Z"))
                XCTAssertEqual(components.queryItems?.first { $0.name == "end_time" }?.value,
                               String(Int(end.timeIntervalSince1970)))
            }
            return Data(#"{"data":[{"results":[]}],"has_more":false}"#.utf8)
        }
        XCTAssertNil(usage.billing?.costUSD)
    }

    func testOpenAICostsAcceptZeroWithHugeExponent() async throws {
        let query = BillingQuery(account: .openAI, keyID: nil, start: month, end: now)
        let usage = try await query.fetch(key: "sk-admin-test-fixture") { request in
            guard request.url?.path == "/v1/organization/costs" else {
                return Data(#"{"data":[],"has_more":false}"#.utf8)
            }
            return Data("""
            {"data":[{"results":[{"amount":{"value":32.45699441830000000000000000,"currency":"usd"}}]},
                     {"results":[{"amount":{"value":0E-6176,"currency":"usd"}}]}],"has_more":false}
            """.utf8)
        }
        XCTAssertEqual(usage.billing?.costUSD, Decimal(string: "32.4569944183"))
    }

    func testXAIReadsTeamSpendCreditsAndLimit() async throws {
        let query = BillingQuery(account: .xai, keyID: nil, start: month, end: now)
        let result = try await query.fetch(key: "xai-mgmt-fixture") { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "management-api.x.ai")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xai-mgmt-fixture")
            switch url.path {
            case "/auth/management-keys/validation":
                return Data(#"{"scope":"SCOPE_TEAM","scopeId":"team-123","teamId":"legacy"}"#.utf8)
            case "/v1/billing/teams/team-123/postpaid/invoice/preview":
                return Data(#"{"coreInvoice":{"amountBeforeVat":"3246","amountAfterVat":"3900"},"billingCycle":{"year":2026,"month":11}}"#.utf8)
            case "/v1/billing/teams/team-123/prepaid/balance":
                return Data(#"{"changes":[],"total":{"val":"18459"}}"#.utf8)
            case "/v1/billing/teams/team-123/postpaid/spending-limits":
                return Data(#"{"spendingLimits":{"effectiveSl":{"val":"10000"},"softSl":{"val":"10000"}}}"#.utf8)
            default:
                XCTFail("Unexpected path \(url.path)")
                return Data()
            }
        }
        let billing = try XCTUnwrap(result.billing)
        XCTAssertEqual(billing.costUSD, Decimal(string: "32.46"))
        XCTAssertEqual(billing.creditUSD, Decimal(string: "184.59"))
        XCTAssertEqual(billing.limitUSD, Decimal(100))
        XCTAssertNil(billing.tokens)
        XCTAssertEqual(billing.monthStart, BillingUsage.startOfMonth(at: Date(timeIntervalSince1970: 1_794_400_000)))
    }

    func testXAIWithoutLimitsOrTeamScope() async throws {
        let query = BillingQuery(account: .xai, keyID: nil, start: month, end: now)
        let partial = try await query.fetch(key: "k") { request in
            switch request.url?.path ?? "" {
            case "/auth/management-keys/validation": return Data(#"{"teamId":"team-9"}"#.utf8)
            case let path where path.hasSuffix("/spending-limits"): throw ServiceUsageError.billingAccessDenied
            case let path where path.hasSuffix("/invoice/preview"): return Data(#"{"coreInvoice":{"amountBeforeVat":"0"}}"#.utf8)
            default: return Data(#"{"total":{"val":"500"}}"#.utf8)
            }
        }
        XCTAssertEqual(partial.billing?.costUSD, 0)
        XCTAssertEqual(partial.billing?.creditUSD, 5)
        XCTAssertNil(partial.billing?.limitUSD)
        do {
            _ = try await query.fetch(key: "k") { _ in Data(#"{"scope":"SCOPE_ORGANIZATION","scopeId":"org-1"}"#.utf8) }
            XCTFail("Organization keys need a team")
        } catch ServiceUsageError.xaiTeamMissing {
        }
        XCTAssertNil(try ServiceAccount.xai.reportKeyID("key_x"))
    }
}
