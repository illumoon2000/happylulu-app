import Foundation
import CryptoKit
import AppPluginCore
import CalendarSyncServices

public struct DaouOfficeConfiguration: Codable, Sendable, Equatable {
    public var enabled: Bool
    public let baseURL: URL
    public let loginID: String
    public let version: Int

    public init(enabled: Bool, address: String, loginID: String) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/", "/login"].contains(parts.path), parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw PluginFailure.invalidAddress
        }
        let id = loginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw PluginFailure.missingCredentials }
        parts.scheme = "https"; parts.host = host.lowercased(); parts.path = "/"
        if parts.port == 443 { parts.port = nil }
        guard let url = parts.url else { throw PluginFailure.invalidAddress }
        self.enabled = enabled; self.baseURL = url; self.loginID = id; self.version = 1
    }

    public func allows(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil &&
        url.host?.lowercased() == baseURL.host?.lowercased() && (url.port ?? 443) == (baseURL.port ?? 443)
    }
    public var credentialKey: String {
        let data = try! JSONEncoder().encode([baseURL.absoluteString, loginID])
        return "daouoffice." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct DaouOfficeConfigurationStore: Sendable {
    public let url: URL
    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AfterSix/Plugins/daouoffice.json")
    }
    public func load() throws -> DaouOfficeConfiguration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let value = try JSONDecoder().decode(DaouOfficeConfiguration.self, from: Data(contentsOf: url))
            guard value.version == 1,
                  try DaouOfficeConfiguration(enabled: value.enabled, address: value.baseURL.absoluteString, loginID: value.loginID) == value else {
                throw PluginFailure.configuration
            }
            return value
        } catch { throw PluginFailure.configuration }
    }
    public func save(_ config: DaouOfficeConfiguration) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(config).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw PluginFailure.configuration }
    }
}

public protocol PluginSecretStore: Sendable {
    func load(for key: String) throws -> String?
    func save(_ password: String, for key: String) throws
    func remove(for key: String) throws
}

public struct DaouOfficeSecretStore: PluginSecretStore {
    private let keychain = CredentialStore(service: "local.chanyoung.AfterSix.Plugins.DaouOffice")
    public init() {}
    public func load(for key: String) throws -> String? {
        do { return try keychain.load(for: key) } catch { throw PluginFailure.credentials }
    }
    public func save(_ password: String, for key: String) throws {
        do { try keychain.save(password, for: key) } catch { throw PluginFailure.credentials }
    }
    public func remove(for key: String) throws {
        do { try keychain.remove(for: key) } catch { throw PluginFailure.credentials }
    }
}
