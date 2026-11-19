import AppKit
import UsageCore

@MainActor
final class MenuBarUsageStrip {
    private struct Window {
        let label: String
        let used: Double

        var percent: String { (used / 100).formatted(.percent.precision(.fractionLength(0))) }
    }

    private struct Reading {
        let title: String
        let icon: NSImage?
        let label: String
        let window: Window?
        var billing = false
        var saved = false
        var cost: Decimal?

        var value: String {
            if billing {
                return cost.map { "$" + $0.formatted(.number.notation(.compactName).precision(.fractionLength(0...2))) } ?? "—"
            }
            return window?.percent ?? "—"
        }
    }

    private let icons = Dictionary(uniqueKeysWithValues: Provider.allCases.compactMap { provider in
        Bundle.main.url(forResource: provider.rawValue, withExtension: "svg", subdirectory: "ProviderIcons")
            .flatMap { NSImage(contentsOf: $0) }.map { (provider, $0) }
    })

    func render(result: ScanResult, services: [ServiceAccountProfile], hidden: Set<String>,
                tick: Int, dark: Bool, now: Date = .now) -> (image: NSImage?, description: String) {
        var readings: [Reading] = []
        for provider in Provider.allCases where !hidden.contains(provider.rawValue) {
            let windows = result.quotas(for: provider)
                .filter { !$0.isStale(at: now) }
                .sorted { $0.window.rawValue < $1.window.rawValue }
                .map { Window(label: $0.window.title, used: $0.used) }
            let fallback = provider == .claude ? "sun.max" : "chevron.left.forwardslash.chevron.right"
            readings.append(Reading(title: provider.title,
                                    icon: icons[provider] ?? symbol(fallback),
                                    label: provider == .claude ? "CC" : "CX", window: selected(windows, tick: tick)))
        }
        if !hidden.contains("grok"), let quota = result.grok?.quota, !quota.isStale(at: now) {
            readings.append(Reading(title: "Grok", icon: symbol(ServiceAccount.xai.symbol), label: "GK",
                                    window: Window(label: quota.window.title, used: quota.used)))
        }
        let labels = ["5-hour rolling": QuotaWindow.fiveHours.title, "7-day rolling": QuotaWindow.sevenDays.title,
                      "Monthly total": String(localized: "1M"), "MCP": "MCP"]
        for service in services where !hidden.contains(service.id) {
            if service.provider.isBilling {
                let icon = service.provider == .xai ? symbol(service.provider.symbol)
                    : icons[service.provider == .openAI ? .codex : .claude] ?? symbol(service.provider.symbol)
                let bill = service.usage.flatMap { usage in
                    usage.isStale(at: now) || usage.billing?.monthStart != BillingUsage.startOfMonth(at: now)
                        ? nil : usage.billing
                }
                let credit = service.provider == .openAI && service.reportKeyID == nil ? service.creditBalance : nil
                readings.append(Reading(title: service.title, icon: icon,
                                        label: credit == nil ? String(localized: "MTD") : String(localized: "SAVED"),
                                        window: nil, billing: true, saved: credit != nil, cost: credit?.amountUSD ?? bill?.costUSD))
                continue
            }
            let windows = service.usage.flatMap { usage in
                usage.isStale(at: now) ? nil : usage.windows.filter { $0.resetsAt.map { $0 > now } != false }
            } ?? []
            let values = windows.map { Window(label: labels[$0.title] ?? "API", used: $0.usedPercent) }
            readings.append(Reading(title: service.title, icon: symbol(service.provider.symbol),
                                    label: "API", window: selected(values, tick: tick)))
        }
        if readings.isEmpty { return (symbol("chart.bar.xaxis"), "Agent Meter") }
        let details = readings.map { reading in
            if reading.billing {
                return reading.cost.map {
                    let amount = $0.formatted(.currency(code: "USD"))
                    return reading.saved ? String(localized: "\(reading.title) saved API credit balance \(amount)")
                        : String(localized: "\(reading.title) \(amount) this month")
                } ?? String(localized: "\(reading.title) monthly API cost unavailable")
            }
            return reading.window.map { String(localized: "\(reading.title) \($0.label) \($0.percent) used") }
                ?? String(localized: "\(reading.title) quota unavailable")
        }
        let description = (["Agent Meter"] + details).joined(separator: ", ")
        return (image(readings, dark: dark), description)
    }

    private func selected(_ windows: [Window], tick: Int) -> Window? {
        windows.isEmpty ? nil : windows[Int(UInt(bitPattern: tick) % UInt(windows.count))]
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func image(_ readings: [Reading], dark: Bool) -> NSImage {
        let neutral: NSColor = dark ? .white : .black
        let amber = NSColor(srgbRed: dark ? 1 : 0.68, green: dark ? 0.63 : 0.32, blue: 0.10, alpha: 1)
        let red = NSColor(srgbRed: dark ? 1 : 0.75, green: dark ? 0.35 : 0.10, blue: 0.18, alpha: 1)
        let labelFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
        let percentFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        let values = readings.map(\.value)
        let widths = values.map { max(47, 25 + ceil($0.size(withAttributes: [.font: percentFont]).width)) }
        let marks = readings.map { reading -> NSImage? in
            guard let icon = reading.icon else { return nil }
            return NSImage(size: NSSize(width: 15, height: 15), flipped: false) { rect in
                icon.draw(in: rect)
                neutral.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
        }
        return NSImage(size: NSSize(width: widths.reduce(2, +), height: 22), flipped: false) { _ in
            var x: CGFloat = 2
            for (index, reading) in readings.enumerated() {
                defer { x += widths[index] }
                marks[index]?.draw(in: NSRect(x: x, y: 3.5, width: 15, height: 15))
                let used = reading.window?.used ?? 0
                let color = used >= 80 ? red : used >= 50 ? amber : neutral
                (reading.window?.label ?? reading.label).draw(at: NSPoint(x: x + 20, y: 12),
                    withAttributes: [.font: labelFont, .foregroundColor: color])
                values[index].draw(at: NSPoint(x: x + 20, y: 3),
                    withAttributes: [.font: percentFont, .foregroundColor: color])
                if reading.billing { continue }
                let track = NSRect(x: x + 20, y: 1, width: 23, height: 2)
                neutral.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
                if used > 0 {
                    color.setFill()
                    let fill = NSRect(x: track.minX, y: track.minY, width: track.width * used / 100, height: track.height)
                    NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
                }
            }
            return true
        }
    }
}
