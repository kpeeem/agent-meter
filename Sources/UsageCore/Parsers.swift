import Foundation

struct TokenEvent: Sendable {
    let key: String
    let date: Date
    let tokens: Tokens
    let fableCostUSD: Double

    init(key: String, date: Date, tokens: Tokens, fableCostUSD: Double = 0) {
        self.key = key
        self.date = date
        self.tokens = tokens
        self.fableCostUSD = fableCostUSD
    }
}

struct ParsedLog: Sendable {
    let session: UUID
    let project: String
    let events: [TokenEvent]
    let quotas: [Quota]
    var notchActivity: NotchActivity?
    var isService = false
    var entrypoint: String?
    var origin = WorkOrigin.interactive
    var lastActivity: Date?
}

enum Parsers {
    static func claude(_ url: URL, size: Int) throws -> ParsedLog? {
        let decoder = JSONDecoder()
        let assistant = Data("\"assistant\"".utf8)
        var project: String?
        var session: UUID?
        var entrypoint: String?
        var events: [String: TokenEvent] = [:]

        try readLog(url, size: size) { line in
            guard line.range(of: assistant) != nil,
                  let record = try? decoder.decode(ClaudeRecord.self, from: line),
                  record.type == "assistant", let message = record.message,
                  let usage = message.usage, message.model != "<synthetic>",
                  let date = timestamp(record.timestamp) else { return }
            project = project ?? projectPath(record.cwd)
            entrypoint = entrypoint ?? record.entrypoint
            session = session ?? record.sessionID.flatMap(UUID.init(uuidString:))
            let tokens = usage.counts.tokens
            let cost = usage.fableCostUSD(model: message.model)
            guard tokens.total > 0 || cost > 0, let key = message.id ?? record.requestID ?? record.uuid else { return }
            let event = TokenEvent(key: key, date: date, tokens: tokens, fableCostUSD: cost)
            if let previous = events[key], previous.tokens.output > tokens.output { return }
            if let previous = events[key], previous.tokens.output == tokens.output, previous.date > date { return }
            events[key] = event
        }
        guard let session = session ?? UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
        let origin: WorkOrigin = url.pathComponents.contains("subagents") ? .claudeSubagent
            : entrypoint?.hasPrefix("sdk") == true ? .claudeScripted : .interactive
        return ParsedLog(session: session, project: project ?? "", events: Array(events.values), quotas: [],
                         entrypoint: entrypoint, origin: origin, lastActivity: events.values.map(\.date).max())
    }

    static func codex(_ url: URL, size: Int) throws -> ParsedLog? {
        let decoder = JSONDecoder()
        let meta = Data("\"session_meta\"".utf8)
        let token = Data("\"token_count\"".utf8)
        let task = Data("\"task_".utf8)
        let interrupted = Data("\"turn_aborted\"".utf8)
        let prompt = Data("\"user_message\"".utf8)
        var turn: (phase: NotchActivity.Phase, date: Date)?
        var turnStart: Date?
        var turnPrompt: String?
        var turnMessage: String?
        var visible = true
        var origin = WorkOrigin.interactive
        var imported = false
        var lastActivity: Date?
        var project: String?
        var session: UUID?
        var previous: CodexRecord.Usage?
        var events: [TokenEvent] = []
        var quotas: [QuotaWindow: Quota] = [:]

        try readLog(url, size: size) { line in
            guard line.range(of: token) != nil || line.range(of: meta) != nil
                    || line.range(of: task) != nil || line.range(of: interrupted) != nil
                    || line.range(of: prompt) != nil,
                  let record = try? decoder.decode(CodexRecord.self, from: line) else { return }
            if record.type == "session_meta" {
                visible = record.payload.userVisible
                origin = record.payload.origin
                project = project ?? projectPath(record.payload.cwd)
                session = session ?? record.payload.id.flatMap(UUID.init(uuidString:))
                return
            }
            guard record.type == "event_msg", let date = timestamp(record.timestamp) else { return }
            lastActivity = max(lastActivity ?? date, date)
            switch record.payload.type {
            case "task_started" where record.payload.turnID?.hasPrefix("external-import") == true:
                imported = true
            case "task_started":
                turn = (.running, date)
                turnStart = date
                turnMessage = nil
            case "task_complete":
                turn = (.done, date)
                turnMessage = NotchText.clean(record.payload.lastAgentMessage, limit: NotchActivity.messageLimit,
                                              singleLine: false)
            case "turn_aborted": turn = (.interrupted, date)
            case "user_message":
                if let text = NotchText.clean(record.payload.message, limit: NotchActivity.promptLimit,
                                              singleLine: true) { turnPrompt = text }
            case "token_count":
                if let last = turn, last.phase == .running, date > last.date { turn = (.running, date) }
            default: break
            }
            guard record.payload.type == "token_count" else { return }

            if let limits = record.payload.rateLimits, limits.id == nil || limits.id == "codex" {
                for window in [limits.primary, limits.secondary].compactMap({ $0 }) {
                    guard let quota = window.quota(at: date) else { continue }
                    if quotas[quota.window].map({ $0.observedAt > date }) != true {
                        quotas[quota.window] = quota
                    }
                }
            }
            guard let usage = record.payload.info?.total, usage != previous else { return }
            let delta: Tokens
            if let previous, usage.canSubtract(previous) {
                delta = usage.delta(from: previous)
            } else if let last = record.payload.info?.last {
                delta = last.delta(from: .zero)
            } else {
                delta = usage.delta(from: .zero)
            }
            previous = usage
            if delta.total > 0 { events.append(TokenEvent(key: "", date: date, tokens: delta)) }
        }
        let suffix = url.deletingPathExtension().lastPathComponent.suffix(36)
        guard let session = session ?? UUID(uuidString: String(suffix)) else { return nil }
        if imported { origin = .codexImported }
        let activity = turn.flatMap { turn in imported ? nil : turn }.map { turn in
            NotchActivity(provider: .codex, session: session, phase: turn.phase, cwd: project,
                          host: nil, terminalID: nil, updatedAt: turn.date, prompt: turnPrompt,
                          message: turnMessage, startedAt: turnStart, origin: origin)
        }
        return ParsedLog(session: session, project: project ?? "", events: events,
                         quotas: Array(quotas.values), notchActivity: activity, isService: !visible || imported,
                         origin: origin, lastActivity: lastActivity)
    }
}

private struct ClaudeRecord: Decodable {
    let type: String
    let cwd: String?
    let entrypoint: String?
    let sessionID: String?
    let requestID: String?
    let uuid: String?
    let timestamp: String?
    let message: Message?

    enum CodingKeys: String, CodingKey {
        case type, cwd, uuid, timestamp, message, entrypoint
        case sessionID = "sessionId", requestID = "requestId"
    }

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let counts: Counts
        let speed: String?
        let inferenceGeo: String?
        let iterations: [Iteration]

        enum CodingKeys: String, CodingKey {
            case speed, iterations
            case inferenceGeo = "inference_geo"
        }

        init(from decoder: Decoder) throws {
            counts = try Counts(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            speed = try? values.decode(String.self, forKey: .speed)
            inferenceGeo = try? values.decode(String.self, forKey: .inferenceGeo)
            iterations = (try? values.decode([Iteration].self, forKey: .iterations)) ?? []
        }

        func fableCostUSD(model: String?) -> Double {
            let fallback = iterations.last { $0.type == "fallback_message" }
            let main = counts.fableCostUSD(model: fallback?.model ?? model, speed: speed, inferenceGeo: inferenceGeo)
            return iterations.reduce(main) { cost, iteration in
                guard iteration.type == "advisor_message" ||
                    (fallback != nil && iteration.type == "message" && iteration.counts.tokens.output > 0) else { return cost }
                return cost + iteration.counts.fableCostUSD(model: iteration.model, speed: nil,
                                                            inferenceGeo: inferenceGeo)
            }
        }
    }

    struct Iteration: Decodable {
        let type: String
        let model: String?
        let counts: Counts

        enum CodingKeys: String, CodingKey { case type, model }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            model = try values.decodeIfPresent(String.self, forKey: .model)
            counts = try Counts(from: decoder)
        }
    }

    struct Counts: Decodable {
        let tokens: Tokens
        let hourWrites: Int64

        enum CodingKeys: String, CodingKey {
            case input = "input_tokens", cached = "cache_read_input_tokens"
            case cacheWrite = "cache_creation_input_tokens", output = "output_tokens"
            case cacheCreation = "cache_creation"
        }

        private enum CacheKeys: String, CodingKey { case hour = "ephemeral_1h_input_tokens" }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            func count(_ key: CodingKeys) throws -> Int64 {
                max(0, try values.decodeIfPresent(Int64.self, forKey: key) ?? 0)
            }
            tokens = try Tokens(input: count(.input), cached: count(.cached),
                                cacheWrite: count(.cacheWrite), output: count(.output))
            let cache = try? values.nestedContainer(keyedBy: CacheKeys.self, forKey: .cacheCreation)
            let hour = (try? cache?.decode(Int64.self, forKey: .hour)) ?? 0
            hourWrites = min(tokens.cacheWrite, max(0, hour))
        }

        func fableCostUSD(model: String?, speed: String?, inferenceGeo: String?) -> Double {
            let price: (input: Double, cacheRead: Double)
            switch model {
            case "claude-fable-5": price = (10, 1)
            case "claude-fable-5-1": price = (10, 0.25)
            case "claude-fable-5-2": price = (8, 0.20)
            default: return 0
            }
            let inputEquivalent = Double(tokens.input) + 5 * Double(tokens.output)
                + 1.25 * Double(tokens.cacheWrite - hourWrites) + 2 * Double(hourWrites)
            let fast = model == "claude-fable-5-2" && speed == "fast" ? 2.0 : 1.0
            let geography = inferenceGeo == "us" ? 1.1 : 1.0
            return (price.input * inputEquivalent + price.cacheRead * Double(tokens.cached))
                * fast * geography / 1_000_000
        }
    }
}

private struct CodexRecord: Decodable {
    let type: String
    let timestamp: String?
    let payload: Payload

    struct Payload: Decodable {
        let type: String?
        let id: String?
        let cwd: String?
        let info: Info?
        let rateLimits: Limits?
        let message: String?
        let lastAgentMessage: String?
        let turnID: String?
        let userVisible: Bool
        let origin: WorkOrigin

        enum CodingKeys: String, CodingKey {
            case type, id, cwd, info, message, source
            case rateLimits = "rate_limits", lastAgentMessage = "last_agent_message", threadSource = "thread_source"
            case turnID = "turn_id"
        }

        struct Source: Decodable {
            let subagent: Subagent?
            struct Subagent: Decodable {
                let other: String?
                enum CodingKeys: String, CodingKey { case other }
                init(from decoder: Decoder) throws {
                    other = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .other)
                }
            }
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decodeIfPresent(String.self, forKey: .type)
            id = try values.decodeIfPresent(String.self, forKey: .id)
            cwd = try values.decodeIfPresent(String.self, forKey: .cwd)
            info = try values.decodeIfPresent(Info.self, forKey: .info)
            rateLimits = try values.decodeIfPresent(Limits.self, forKey: .rateLimits)
            message = try? values.decodeIfPresent(String.self, forKey: .message)
            lastAgentMessage = try? values.decodeIfPresent(String.self, forKey: .lastAgentMessage)
            turnID = try? values.decodeIfPresent(String.self, forKey: .turnID)
            let name = try? values.decode(String.self, forKey: .source)
            let source: Any? = values.contains(.source) ? (name as Any?) ?? [String: Any]() : nil
            let thread = (try? values.decodeIfPresent(String.self, forKey: .threadSource))?.lowercased()
            userVisible = CodexThread.isUserVisible(source: source, threadSource: thread)
            let subagent = (try? values.decodeIfPresent(Source.self, forKey: .source))?.subagent
            if thread == "guardian_review" || subagent?.other?.lowercased() == "guardian" {
                origin = .codexGuardian
            } else if thread == "subagent" || subagent != nil {
                origin = .codexSubagent
            } else if name?.lowercased() == "exec" {
                origin = .codexScripted
            } else {
                origin = userVisible ? .interactive : .codexService
            }
        }
    }

    struct Info: Decodable {
        let total: Usage?
        let last: Usage?

        enum CodingKeys: String, CodingKey {
            case total = "total_token_usage", last = "last_token_usage"
        }
    }

    struct Usage: Decodable, Equatable {
        let input: Int64?
        let cached: Int64?
        let cacheWrite: Int64?
        let output: Int64?

        static let zero = Usage(input: 0, cached: 0, cacheWrite: 0, output: 0)

        enum CodingKeys: String, CodingKey {
            case input = "input_tokens", cached = "cached_input_tokens"
            case cacheWrite = "cache_write_input_tokens", output = "output_tokens"
        }

        func canSubtract(_ old: Self) -> Bool {
            (input ?? 0) >= (old.input ?? 0) && (output ?? 0) >= (old.output ?? 0)
        }

        func delta(from old: Self) -> Tokens {
            func delta(_ a: Int64?, _ b: Int64?) -> Int64 { max(0, max(0, a ?? 0) - max(0, b ?? 0)) }
            let input = delta(input, old.input)
            let cached = min(input, delta(cached, old.cached))
            let written = min(input - cached, delta(cacheWrite, old.cacheWrite))
            return Tokens(input: input - cached - written, cached: cached, cacheWrite: written,
                          output: delta(output, old.output))
        }
    }

    struct Limits: Decodable {
        let id: String?
        let primary: Window?
        let secondary: Window?

        enum CodingKeys: String, CodingKey { case id = "limit_id", primary, secondary }
    }

    struct Window: Decodable {
        let used: Double?
        let minutes: Int?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case used = "used_percent", minutes = "window_minutes", resetsAt = "resets_at"
        }

        func quota(at date: Date) -> Quota? {
            guard let used, let minutes, let window = QuotaWindow(rawValue: minutes) else { return nil }
            return Quota(window: window, used: used, observedAt: date, resetEpoch: resetsAt)
        }
    }
}
