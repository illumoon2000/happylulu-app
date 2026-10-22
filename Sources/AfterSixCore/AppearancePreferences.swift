import Foundation
import ImageIO

public enum AppearanceColorRole: String, Codable, CaseIterable, Sendable {
    case background, sidebar, surface, accent, text
}

public enum AppearancePalette: String, Codable, CaseIterable, Sendable {
    case softMint, warmStone, blueGray, dustyLavender, charcoal, offwhiteLilac

    public var colors: [AppearanceColorRole: String] {
        let values: [String]
        switch self {
        case .offwhiteLilac: values = ["#FAF9FC", "#EEE8F8", "#FFFFFF", "#7054B3", "#2F2B3D"]
        case .softMint: values = ["#E9EFEB", "#E0E7E2", "#F2F5F3", "#286F5D", "#26382E"]
        case .warmStone: values = ["#EEEAE3", "#E4DED5", "#F6F2ED", "#786347", "#38342E"]
        case .blueGray: values = ["#E7EDF1", "#DDE5EB", "#F0F4F7", "#426780", "#2B3741"]
        case .dustyLavender: values = ["#EEEAF1", "#E4DEEA", "#F5F1F7", "#77608D", "#3A3242"]
        case .charcoal: values = ["#252A2D", "#1E2326", "#303639", "#8CC5B4", "#E0E7E4"]
        }
        return Dictionary(uniqueKeysWithValues: zip(AppearanceColorRole.allCases, values))
    }
}

public enum AppearanceIcon: String, Codable, CaseIterable, Sendable {
    case original, mint, blue, lavender, graphite, custom
}

public enum AppearanceError: LocalizedError {
    case invalidColor, invalidPreferences, invalidImage, readOnly
    public var errorDescription: String? {
        switch self {
        case .invalidColor: return "색상은 #RRGGBB 형식의 6자리 HEX로 입력해 주세요."
        case .invalidPreferences: return "외관 설정의 버전 또는 값이 올바르지 않습니다. 원본은 보존했습니다."
        case .invalidImage: return "PNG/JPEG 이미지(최대 20MB, 각 변 1~8192px)를 선택해 주세요."
        case .readOnly: return "외관 설정을 읽을 수 없어 원본을 보존하는 읽기 전용 상태입니다."
        }
    }
}

public struct AppearancePreferences: Codable, Equatable, Sendable {
    public var version = 1
    public var palette: AppearancePalette = .offwhiteLilac
    public var customColors: [String: String] = [:]
    public var icon: AppearanceIcon = .original
    public var customImageFilename: String?
    public init() {}

    public static func normalizedHex(_ value: String) throws -> String {
        let bytes = Array(value.utf8)
        guard bytes.count == 7, bytes[0] == 35,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { throw AppearanceError.invalidColor }
        return value.uppercased()
    }

    public var colors: [AppearanceColorRole: String] {
        var result = palette.colors
        for role in AppearanceColorRole.allCases {
            if let value = customColors[role.rawValue] { result[role] = value }
        }
        return result
    }

    public mutating func setColor(_ value: String, for role: AppearanceColorRole) throws {
        customColors[role.rawValue] = try Self.normalizedHex(value)
    }

    public mutating func selectPalette(_ value: AppearancePalette) {
        palette = value
        customColors = [:]
    }

    public func validate() throws {
        guard version == 1, customColors.keys.allSatisfy({ AppearanceColorRole(rawValue: $0) != nil })
        else { throw AppearanceError.invalidPreferences }
        for color in customColors.values { _ = try Self.normalizedHex(color) }
        if let filename = customImageFilename { try AppearanceStore.validateFilename(filename) }
        if icon == .custom && customImageFilename == nil { throw AppearanceError.invalidImage }
    }

    public static func luminance(_ hex: String) -> Double {
        guard let rgb = UInt32(hex.dropFirst(), radix: 16) else { return 0 }
        let components = [Double((rgb >> 16) & 255), Double((rgb >> 8) & 255), Double(rgb & 255)].map {
            let value = $0 / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
    }

    public var contrastRatio: Double {
        let foreground = Self.luminance(colors[.text]!)
        return [AppearanceColorRole.background, .sidebar, .surface].map {
            let background = Self.luminance(colors[$0]!)
            return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
        }.min()!
    }
}

public final class AppearanceStore {
    public let directory: URL
    public var preferencesURL: URL { directory.appendingPathComponent("appearance.json") }
    public private(set) var isReadOnly = false
    public static let maximumImageBytes = 20 * 1024 * 1024
    private let fileManager = FileManager.default
    private var importedImageFilenames = Set<String>()

    public init(rootDirectory: URL, bundleIdentifier: String) {
        // Bundle identifiers are application metadata; encode them as one path component.
        let component = bundleIdentifier.utf8.map { String(format: "%02x", $0) }.joined()
        directory = rootDirectory.appendingPathComponent(component, isDirectory: true).appendingPathComponent("Appearance", isDirectory: true)
    }

    public func load() throws -> AppearancePreferences? {
        guard fileManager.fileExists(atPath: preferencesURL.path) else { return nil }
        do {
            let value = try JSONDecoder().decode(AppearancePreferences.self, from: Data(contentsOf: preferencesURL))
            try validate(value)
            return value
        } catch {
            isReadOnly = true
            throw error
        }
    }

    private func validate(_ value: AppearancePreferences) throws {
        try value.validate()
        if let filename = value.customImageFilename {
            _ = try Self.imageExtension(Data(contentsOf: imageURL(filename)))
        }
    }

    public func save(_ value: AppearancePreferences) throws {
        guard !isReadOnly else { throw AppearanceError.readOnly }
        try validate(value)
        let bytes = try JSONEncoder().encode(value)
        let previous = (try? Data(contentsOf: preferencesURL)).flatMap {
            try? JSONDecoder().decode(AppearancePreferences.self, from: $0)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: preferencesURL, options: .atomic)
        var superseded = importedImageFilenames
        if let filename = previous?.customImageFilename { superseded.insert(filename) }
        for filename in superseded where filename != value.customImageFilename {
            removeSupersededImage(filename)
        }
    }

    private func removeSupersededImage(_ filename: String) {
        // Only known references with the importer's UUID name are eligible; never sweep the directory.
        let name = (filename as NSString).deletingPathExtension
        guard let uuid = UUID(uuidString: name), uuid.uuidString == name,
              ["png", "jpg"].contains((filename as NSString).pathExtension),
              let url = try? imageURL(filename),
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isSymbolicLink != true, values.isRegularFile == true,
              let folder = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]), folder.isSymbolicLink != true,
              let parent = try? directory.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]),
              parent.isSymbolicLink != true else { return }
        if (try? fileManager.removeItem(at: url)) != nil { importedImageFilenames.remove(filename) }
    }

    public static func validateFilename(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !name.isEmpty, name.utf8.count <= 128, !name.hasPrefix("."),
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              ["png", "jpg", "jpeg"].contains((name as NSString).pathExtension.lowercased())
        else { throw AppearanceError.invalidImage }
    }

    public func imageURL(_ filename: String) throws -> URL {
        try Self.validateFilename(filename)
        let url = directory.appendingPathComponent(filename)
        // Refuse a replaced symlink so references cannot leave the isolated image directory.
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  let size = values.fileSize, size <= Self.maximumImageBytes else { throw AppearanceError.invalidImage }
        }
        return url
    }

    private static func imageExtension(_ data: Data) throws -> String {
        guard data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { throw AppearanceError.invalidImage }
        return type == "public.png" ? "png" : "jpg"
    }

    public func importImage(_ bytes: Data) throws -> String {
        guard !isReadOnly else { throw AppearanceError.readOnly }
        let ext = try Self.imageExtension(bytes)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = UUID().uuidString + "." + ext
        try bytes.write(to: imageURL(filename), options: .atomic)
        importedImageFilenames.insert(filename)
        return filename
    }
}
