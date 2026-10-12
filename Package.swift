// swift-tools-version: 6.0
import PackageDescription

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
        .executableTarget(name: "AfterSix", dependencies: ["AfterSixCore", "MacLaunchSupport", "CalendarSyncCore", "CalendarSyncServices",
            .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "AfterSixChecks", dependencies: ["AfterSixCore", "MacLaunchSupport"], path: "Tests/AfterSixCoreTests"),
        .executableTarget(name: "AfterSixParityChecks", dependencies: ["AfterSixCore"], path: "Tests/AfterSixParityChecks"),
        .executableTarget(name: "CalendarSyncChecks", dependencies: ["CalendarSyncCore"], path: "Tests/CalendarSyncCoreTests"),
        .executableTarget(name: "CalendarSyncServiceChecks", dependencies: ["CalendarSyncCore", "CalendarSyncServices"], path: "Tests/CalendarSyncServicesTests"),
        .executableTarget(name: "AppUpdateChecks", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Tests/AppUpdateChecks")
    ]
)
