// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentMeter",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentMeter", targets: ["AgentMeter"]),
        .executable(name: "AgentMeterStatus", targets: ["AgentMeterStatus"]),
        .executable(name: "AgentMeterHook", targets: ["AgentMeterHook"]),
        .executable(name: "AgentMeterRefresh", targets: ["AgentMeterRefresh"])
    ],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "AgentMeter", dependencies: ["UsageCore"], resources: [.process("Resources")]),
        .executableTarget(name: "AgentMeterStatus", dependencies: ["UsageCore"]),
        .executableTarget(name: "AgentMeterHook", dependencies: ["UsageCore"]),
        .executableTarget(name: "AgentMeterRefresh", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ]
)
