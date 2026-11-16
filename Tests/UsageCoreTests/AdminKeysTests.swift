import Foundation
import XCTest
@testable import UsageCore

final class AdminKeysTests: XCTestCase {
    let key = "sk-admin-" + String(repeating: "a", count: 120) + "Zq9x"

    func redacted(_ value: String) -> String {
        String(value.prefix(8)) + String(repeating: "*", count: value.count - 12) + String(value.suffix(4))
    }

    func testFindsTheSavedKeyAcrossPagesByItsRedactedValue() async throws {
        let other = "sk-admin-" + String(repeating: "b", count: 120) + "Zq9y"
        let info = try await OpenAIAdminKeys.info(key: key) { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.key)
            if query.contains(where: { $0.name == "after" }) {
                return Data("""
                {"data":[{"id":"key_ours","redacted_value":"\(self.redacted(self.key))","created_at":1794000000,"expires_at":1796592000}],
                 "has_more":false,"last_id":"key_ours"}
                """.utf8)
            }
            return Data("""
            {"data":[{"id":"key_other","redacted_value":"\(self.redacted(other))","created_at":1,"expires_at":null}],
             "has_more":true,"last_id":"key_other"}
            """.utf8)
        }
        XCTAssertEqual(info, AdminKeyInfo(id: "key_ours", createdAt: Date(timeIntervalSince1970: 1_794_000_000),
                                          expiresAt: Date(timeIntervalSince1970: 1_796_592_000)))
        XCTAssertEqual(info?.lifetime, 2_592_000)
    }

    func testAmbiguousOrShortRedactionsDoNotMatch() {
        XCTAssertFalse(OpenAIAdminKeys.matches("sk-admin****", key: key))
        XCTAssertFalse(OpenAIAdminKeys.matches(redacted(key) + "x", key: key))
        XCTAssertTrue(OpenAIAdminKeys.matches(redacted(key), key: key))
    }

    func testRotationKeepsTheLifetimeAndRevokesByID() async throws {
        let old = AdminKeyInfo(id: "key_old", createdAt: Date(timeIntervalSince1970: 0),
                               expiresAt: Date(timeIntervalSince1970: 2_592_000))
        let created = try await OpenAIAdminKeys.create(key: key, replacing: old, name: "Agent Meter 2026-11-13") { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["expires_in_seconds"] as? Int, 2_592_000)
            XCTAssertEqual(body["name"] as? String, "Agent Meter 2026-11-13")
            return Data(#"{"id":"key_new","value":"sk-admin-new-secret","created_at":10,"expires_at":2592010}"#.utf8)
        }
        XCTAssertEqual(created.key, "sk-admin-new-secret")
        XCTAssertEqual(created.info.id, "key_new")

        try await OpenAIAdminKeys.revoke(key: created.key, id: "key_old") { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/organization/admin_api_keys/key_old")
            return Data(#"{"id":"key_old","object":"organization.admin_api_key.deleted","deleted":true}"#.utf8)
        }
        do {
            try await OpenAIAdminKeys.revoke(key: key, id: "../projects") { _ in Data() }
            XCTFail("Expected an invalid key ID to be rejected")
        } catch {}
    }

    func testFailedCreationRevokesTheKeyItLeftBehind() async {
        let old = AdminKeyInfo(id: "key_old", createdAt: nil, expiresAt: nil)
        let revoked = Revoked()
        do {
            _ = try await OpenAIAdminKeys.create(key: key, replacing: old, name: "Agent Meter 2026-11-13 A1B2C3") { request in
                switch request.httpMethod {
                case "POST": return Data(#"{"id":"key_new","value":null}"#.utf8)
                case "DELETE":
                    let id = request.url?.lastPathComponent ?? ""
                    await revoked.add(id)
                    return Data(#"{"id":"\#(id)","deleted":true}"#.utf8)
                default:
                    return Data("""
                    {"data":[{"id":"key_old","name":"Agent Meter 2026-11-13 A1B2C3"},
                             {"id":"key_new","name":"Agent Meter 2026-11-13 A1B2C3"},
                             {"id":"key_mine","name":"Agent Meter 2026-11-13"}],"has_more":false}
                    """.utf8)
                }
            }
            XCTFail("Expected the bad response to fail")
        } catch {}
        let ids = await revoked.ids
        XCTAssertEqual(ids, ["key_new"])
    }

    func testNetworkErrorsAreNotReportedAsBadResponses() async {
        do {
            _ = try await OpenAIAdminKeys.info(key: key) { _ in throw ServiceUsageError.billingAccessDenied }
            XCTFail("Expected the access error")
        } catch ServiceUsageError.billingAccessDenied {
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }
}

private actor Revoked {
    var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}
