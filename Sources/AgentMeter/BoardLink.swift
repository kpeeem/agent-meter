import Combine
import CoreBluetooth
import UsageCore

struct BoardConfig: Codable, Equatable {
    var v: Int
    var board: String?
    var fw: String?
    var ip: String?
    var source: Int
    var theme: Int
    var every: Int
    var tz: String
    var cards: Cards

    struct Cards: Codable, Equatable {
        var opus: Bool
        var fable: Bool
        var codex: Bool
        var codexWeek: Bool
        var detail: Bool
        var indoor: Bool
        var battery: Bool
    }

    static let themes = ["Paper", "Ink", "Mono"]
    static let intervals = [5, 10, 20, 30, 60, 120]
    var pushesQuota: Bool { source == 0 }
}

final class BoardLink: NSObject, ObservableObject {
    enum Status: Equatable {
        case off, starting, unauthorized, bluetoothOff, searching, connected

        var text: String {
            switch self {
            case .off: "Off. Turn the link on to push numbers to the board."
            case .starting: "Starting Bluetooth…"
            case .unauthorized: "macOS denied Bluetooth access. Allow Agent Meter in System Settings → Privacy & Security → Bluetooth."
            case .bluetoothOff: "Bluetooth is off. Turn it on to reach the board."
            case .searching: "Looking for the board…"
            case .connected: "Connected"
            }
        }
    }

    static let enabledKey = "board.enabled"
    private static let service = CBUUID(string: "ae4c9350-5442-48a2-8f62-288e8b34fc7c")
    private static let quotaID = CBUUID(string: "ae4c9351-5442-48a2-8f62-288e8b34fc7c")
    private static let configID = CBUUID(string: "ae4c9352-5442-48a2-8f62-288e8b34fc7c")
    private static let heartbeat: TimeInterval = 120

    @Published private(set) var status = Status.off
    @Published private(set) var config: BoardConfig?
    @Published private(set) var pushedAt: Date?
    @Published var enabled = UserDefaults.standard.bool(forKey: BoardLink.enabledKey) {
        didSet {
            guard oldValue != enabled else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }

    private var central: CBCentralManager?
    private var board: CBPeripheral?
    private var quotaChar: CBCharacteristic?
    private var configChar: CBCharacteristic?
    private var lastPush: Data?
    private var latest: ScanResult?

    func startIfEnabled() {
        if enabled { start() }
    }

    func push(_ result: ScanResult, now: Date = .now) {
        latest = result
        guard let board, let quotaChar, config?.pushesQuota != false, let payload = encode(result, now: now) else { return }
        let fresh = Date.now.timeIntervalSince(pushedAt ?? .distantPast) >= Self.heartbeat
        guard payload != lastPush || fresh else { return }
        board.writeValue(payload, for: quotaChar, type: .withResponse)
        lastPush = payload
        pushedAt = now
    }

    func apply(_ update: BoardConfig) {
        guard let board, let configChar, let payload = try? JSONEncoder().encode(update) else { return }
        config = update
        board.writeValue(payload, for: configChar, type: .withResponse)
    }

    private func start() {
        guard central == nil else {
            connect()
            return
        }
        status = .starting
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func stop() {
        if let board { central?.cancelPeripheralConnection(board) }
        central?.stopScan()
        central = nil
        board = nil
        quotaChar = nil
        configChar = nil
        lastPush = nil
        config = nil
        pushedAt = nil
        status = .off
    }

    private func connect() {
        guard let central, enabled, board == nil else { return }
        switch central.state {
        case .poweredOn:
            status = .searching
            central.scanForPeripherals(withServices: [Self.service])
        case .unauthorized:
            status = .unauthorized
        case .poweredOff:
            status = .bluetoothOff
        default:
            status = .starting
        }
    }

    private func encode(_ result: ScanResult, now: Date) -> Data? {
        let claude = Payload.Side(
            state: claudeState(result, now: now),
            plan: nil,
            session: window(result.claudeQuotas.first { $0.window == .fiveHours }, now: now),
            week: window(result.claudeQuotas.first { $0.window == .sevenDays }, now: now),
            opus: window(model(result, named: "opus"), now: now),
            sonnet: window(model(result, named: "sonnet"), now: now),
            fable: window(result.claudeFableQuota, now: now))
        let codex = Payload.Side(
            state: codexState(result, now: now),
            plan: result.codexLive?.plan,
            session: window(result.codexQuotas.first { $0.window == .fiveHours }, now: now),
            week: window(result.codexQuotas.first { $0.window == .sevenDays }, now: now))
        return try? JSONEncoder().encode(Payload(at: Int(now.timeIntervalSince1970), claude: claude, codex: codex,
                                                 agent: agent(result, now: now)))
    }

    private func agent(_ result: ScanResult, now: Date) -> Payload.Agent? {
        let live = result.notchActivities.filter { now.timeIntervalSince($0.updatedAt) < 4 * 3600 }
        let newest = { (group: [NotchActivity]) in group.max { $0.updatedAt < $1.updatedAt } }
        let name = { (activity: NotchActivity) in String(activity.project.prefix(22)) }

        let attention = live.filter { $0.phase.needsAttention }
        if let one = newest(attention) {
            return Payload.Agent(state: "waiting", project: name(one), count: attention.count)
        }
        let working = live.filter { $0.phase == .running || $0.phase == .ready }
        if let one = newest(working) {
            return Payload.Agent(state: "working", project: name(one), count: working.count)
        }
        if let one = newest(live.filter({ $0.phase.isFinished })) {
            return Payload.Agent(state: one.phase == .failed ? "failed" : "done", project: name(one), count: 1)
        }
        return nil
    }

    private func model(_ result: ScanResult, named: String) -> Quota? {
        result.claudeModelQuotas.first { $0.name.localizedCaseInsensitiveContains(named) }?.quota
    }

    private func window(_ quota: Quota?, now: Date) -> [Double]? {
        guard let quota else { return nil }
        let used = (quota.used * 10).rounded() / 10
        let reset = quota.resetsAt?.timeIntervalSince1970.rounded() ?? 0
        let age = max(0, now.timeIntervalSince(quota.observedAt)).rounded()
        if age >= 60 { return [used, reset, age] }
        return reset > 0 ? [used, reset] : [used]
    }

    private func claudeState(_ result: ScanResult, now: Date) -> String {
        let quotas = result.claudeQuotas + [result.claudeFableQuota].compactMap { $0 }
        if result.automaticClaude?.status == .needsLogin { return "expired" }
        guard !quotas.isEmpty else {
            switch result.automaticClaude?.status {
            case .throttled: return "limit"
            case .timedOut, .unavailable: return "err"
            default: return "none"
            }
        }
        return quotas.contains { $0.isStale(at: now) } ? "stale" : "ok"
    }

    private func codexState(_ result: ScanResult, now: Date) -> String {
        let quotas = result.codexQuotas
        if result.codexLive?.status == .signedOut { return "none" }
        if result.codexLive?.status == .expired { return "expired" }
        guard !quotas.isEmpty else {
            switch result.codexLive?.status {
            case .throttled: return "limit"
            case .unavailable: return "err"
            default: return "none"
            }
        }
        return quotas.contains { $0.isStale(at: now) } ? "stale" : "ok"
    }

    private struct Payload: Encodable {
        let v = 1
        let at: Int
        let claude: Side
        let codex: Side
        let agent: Agent?

        struct Agent: Encodable {
            let state: String
            let project: String
            let count: Int
        }

        struct Side: Encodable {
            let state: String
            let plan: String?
            var session: [Double]?
            var week: [Double]?
            var opus: [Double]?
            var sonnet: [Double]?
            var fable: [Double]?
        }
    }
}

extension BoardLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        connect()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard board == nil else { return }
        board = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dropped()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dropped()
    }

    private func dropped() {
        board = nil
        quotaChar = nil
        configChar = nil
        lastPush = nil
        config = nil
        pushedAt = nil
        connect()
    }
}

extension BoardLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics([Self.quotaID, Self.configID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.quotaID { quotaChar = characteristic }
            if characteristic.uuid == Self.configID {
                configChar = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            }
        }
        guard quotaChar != nil, configChar != nil else { return }
        status = .connected
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.configID, let data = characteristic.value, data.count <= 1024,
              let decoded = try? JSONDecoder().decode(BoardConfig.self, from: data) else { return }
        config = decoded
        if let latest { push(latest) }
    }
}
