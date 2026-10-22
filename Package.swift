// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasDaouoffice = ProcessInfo.processInfo.environment["HAPPY_LULU_DISABLE_DAOUOFFICE"] != "1" &&
    FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/DaouOfficePlugin").path) &&
    FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/DaouOfficeIntegration").path)
let optionalTargets: [Target] = hasDaouoffice ? [
    .target(name: "DaouOfficePlugin", dependencies: ["AppPluginCore", "CalendarSyncServices"]),
    .target(name: "DaouOfficeIntegration", dependencies: ["DaouOfficePlugin", "AppPluginCore", "AppPluginHost"]),
    .executableTarget(name: "AppPluginChecks", dependencies: ["AppPluginCore", "DaouOfficePlugin"], path: "Tests/AppPluginChecks")
] : []
let optionalDependencies: [Target.Dependency] = hasDaouoffice ? [.byName(name: "DaouOfficeIntegration")] : []

let package = Package(
    name: "HappyLulu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "HappyLulu", targets: ["AfterSix"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "AfterSixCore"),
        .target(name: "MacLaunchSupport"),
        .target(name: "CalendarSyncCore"),
        .target(name: "CalendarSyncServices", dependencies: ["CalendarSyncCore"]),
        .target(name: "AppPluginCore"),
        .target(name: "AppPluginHost", dependencies: ["AppPluginCore"]),
        .target(name: "CPURunnerIntegration", dependencies: ["AppPluginCore", "AppPluginHost"]),
        .executableTarget(name: "CPURunnerChecks", dependencies: ["CPURunnerIntegration", "AppPluginCore", "AppPluginHost"], path: "Tests/CPURunnerChecks"),
        .executableTarget(name: "AfterSix", dependencies: ["AfterSixCore", "MacLaunchSupport", "CalendarSyncCore", "CalendarSyncServices", "AppPluginCore", "AppPluginHost", "CPURunnerIntegration",
            .product(name: "Sparkle", package: "Sparkle")] + optionalDependencies,
            swiftSettings: hasDaouoffice ? [.define("HAPPY_LULU_DAOUOFFICE_ENABLED")] : [],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "AfterSixChecks", dependencies: ["AfterSixCore", "MacLaunchSupport"], path: "Tests/AfterSixCoreTests"),
        .executableTarget(name: "AfterSixParityChecks", dependencies: ["AfterSixCore"], path: "Tests/AfterSixParityChecks"),
        .executableTarget(name: "CalendarSyncChecks", dependencies: ["CalendarSyncCore"], path: "Tests/CalendarSyncCoreTests"),
        .executableTarget(name: "CalendarSyncServiceChecks", dependencies: ["CalendarSyncCore", "CalendarSyncServices"], path: "Tests/CalendarSyncServicesTests"),
        .executableTarget(name: "AppUpdateChecks", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Tests/AppUpdateChecks")
    ] + optionalTargets
)
