import Darwin
import Foundation
import UsageCore

enum CodexClient {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func fetch(home: URL) -> CodexLiveUsage? {
        let url = home.appendingPathComponent(".codex/auth.json")
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 64 * 1024,
              let data = try? Data(contentsOf: url),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CodexLiveUsage(status: .unavailable)
        }
        guard let tokens = auth["tokens"] as? [String: Any], let token = tokens["access_token"] as? String,
              !token.isEmpty, token.utf8.count <= 16 * 1024 else { return CodexLiveUsage(status: .signedOut) }
        if let expiry = GrokBot.expiry(of: token), expiry <= .now { return CodexLiveUsage(status: .expired) }
        return request(token: token, account: tokens["account_id"] as? String)
    }

    private static func request(token: String, account: String?) -> CodexLiveUsage {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let account, account.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        var result = CodexLiveUsage(status: .unavailable)
        session.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard let response = response as? HTTPURLResponse else { return }
            switch response.statusCode {
            case 200: result = data.flatMap { $0.count <= 256 * 1024 ? CodexLiveUsage.parse($0) : nil } ?? result
            case 401, 403: result = CodexLiveUsage(status: .expired)
            case 429: result = CodexLiveUsage(status: .throttled)
            default: break
            }
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return result
    }
}
