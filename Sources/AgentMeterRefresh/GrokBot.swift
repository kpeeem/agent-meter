import CommonCrypto
import Foundation
import UsageCore

enum GrokBot {
    static let secretsPath = "Library/Application Support/Grok Bot/sand-secrets.json"
    private static let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!

    static func fetch(home: URL) -> GrokUsage? {
        let url = home.appendingPathComponent(secretsPath)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) <= 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let secrets = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let sealed = activeAccount(secrets)?["cursor-access-token"] as? String else {
            return GrokUsage(status: .signedOut)
        }
        guard let password = safeStoragePassword() else { return GrokUsage(status: .keyDenied) }
        guard let token = unseal(sealed, password: password) else { return GrokUsage(status: .unavailable) }
        if let expiry = expiry(of: token), expiry <= .now { return GrokUsage(status: .expired) }
        let machine = (secrets["cursor-machine-id"] as? String).flatMap { unseal($0, password: password) }
        return request(token: token, machine: machine)
    }

    private static func activeAccount(_ secrets: [String: Any]) -> [String: Any]? {
        var value = secrets["cursor-accounts"]
        if let text = value as? String { value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
        guard let accounts = value as? [String: Any], let active = accounts["active"] as? String else { return nil }
        return (accounts["accounts"] as? [String: Any])?[active] as? [String: Any]
    }

    private static func safeStoragePassword() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", "Grok Bot Safe Storage"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        let password = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return password.isEmpty ? nil : password
    }

    private static func unseal(_ sealed: String, password: String) -> String? {
        guard let blob = Data(base64Encoded: sealed), blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let cipher = blob.dropFirst(3)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        guard CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                                   CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count) == kCCSuccess else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var plain = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = cipher.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, input.baseAddress, cipher.count, &plain, plain.count, &moved)
        }
        guard status == kCCSuccess else { return nil }
        let text = String(decoding: plain.prefix(moved), as: UTF8.self)
        return text.isEmpty || text.contains(where: { $0.isNewline || $0 == " " }) ? nil : text
    }

    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func checksum(machine: String, now: Date = .now) -> String {
        let stamp = UInt64(now.timeIntervalSince1970 * 1000) / 1_000_000
        var bytes = (0..<6).map { UInt8(truncatingIfNeeded: stamp >> (40 - 8 * $0)) }
        var previous: UInt8 = 165
        for index in bytes.indices {
            bytes[index] = (bytes[index] ^ previous) &+ UInt8(index % 256)
            previous = bytes[index]
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded + machine
    }

    private static func request(token: String, machine: String?) -> GrokUsage {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let headers = [
            "content-type": "application/json", "connect-protocol-version": "1",
            "authorization": "Bearer " + token, "x-cursor-client-type": "sand", "x-cursor-client-version": "1.0.1",
            "x-cursor-client-os": "CLIENT_OS_MACOS", "x-sand-box-namespace": "prod", "x-ghost-mode": "true",
            "x-request-id": UUID().uuidString.lowercased(),
        ]
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let machine { request.setValue(checksum(machine: machine), forHTTPHeaderField: "x-cursor-checksum") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        var result = GrokUsage(status: .unavailable)
        session.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard let response = response as? HTTPURLResponse else { return }
            switch response.statusCode {
            case 200: result = data.map { GrokUsage.parse($0) } ?? result
            case 401, 403: result = GrokUsage(status: .expired)
            default: break
            }
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return result
    }
}
