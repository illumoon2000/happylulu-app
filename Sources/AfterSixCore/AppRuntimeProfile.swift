import Foundation

/// Only the shipped production identity may use production data and services.
public struct AppRuntimeProfile: Sendable {
    public static let productionIdentifier = "local.chanyoung.AfterSix"
    public let isDevelopment: Bool
    public let stateURL: URL
    public let routingURL: URL
    public let catalogURL: URL
    public let syncURL: URL
    public var allowsExternalIntegrations: Bool { !isDevelopment }
    public var allowsLoginItemChanges: Bool { !isDevelopment }
    public var allowsAutomaticActivity: Bool { !isDevelopment }

    public init(bundleIdentifier: String?, applicationSupport: URL) {
        isDevelopment = bundleIdentifier != Self.productionIdentifier
        let root: URL
        if isDevelopment {
            // Preserve the already-installed Dev profile's attendance path.
            if bundleIdentifier == "local.chanyoung.HappyLulu.Dev.manual-leave.20261015" {
                root = applicationSupport.appendingPathComponent("HappyLulu Dev/manual-leave-today")
            } else {
                let key = (bundleIdentifier ?? "command-line").utf8.map { String(format: "%02x", $0) }.joined()
                root = applicationSupport.appendingPathComponent("HappyLulu Dev/Profiles/" + key)
            }
            stateURL = root.appendingPathComponent("state.json")
            routingURL = root.appendingPathComponent("Plugins/feature-routing.json")
            catalogURL = root.appendingPathComponent("Plugins/catalog.json")
            syncURL = root.appendingPathComponent("CalendarSync/sync.sqlite")
        } else {
            root = applicationSupport.appendingPathComponent("AfterSix")
            stateURL = root.appendingPathComponent("state.json")
            routingURL = root.appendingPathComponent("Plugins/feature-routing.json")
            catalogURL = root.appendingPathComponent("Plugins/catalog.json")
            syncURL = applicationSupport.appendingPathComponent("HappyLulu/CalendarSync/sync.sqlite")
        }
    }
}
