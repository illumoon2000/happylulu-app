import AppKit
import SwiftUI
import CoreImage
import AfterSixCore

@MainActor
final class AppearanceModel: ObservableObject {
    static let shared = AppearanceModel()
    @Published private(set) var preferences = AppearancePreferences()
    @Published private(set) var iconImage: NSImage
    @Published private(set) var errorMessage: String?
    private let store: AppearanceStore
    private let originalIcon: NSImage
    // SwiftUI requests previews again on navigation and refresh; render each built-in once.
    private var builtInIcons: [AppearanceIcon: NSImage] = [:]
    private lazy var iconContext = CIContext()
    var isReadOnly: Bool { store.isReadOnly }
    var background: Color { color(.background) }
    var sidebar: Color { color(.sidebar) }
    var surface: Color { color(.surface) }
    var accent: Color { color(.accent) }
    var text: Color { color(.text) }
    var isDark: Bool { AppearancePreferences.luminance(hex(.background)) < 0.179 }
    var hasLowContrast: Bool { preferences.contrastRatio < 4.5 }

    init(store: AppearanceStore? = nil, originalIcon: NSImage? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.store = store ?? AppearanceStore(rootDirectory: root, bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.happylulu.command-line")
        let base = originalIcon ?? NSImage(named: NSImage.applicationIconName) ?? NSApplication.shared.applicationIconImage!
        self.originalIcon = (base.copy() as? NSImage) ?? base
        self.iconImage = self.originalIcon
        do { preferences = try self.store.load() ?? AppearancePreferences() }
        catch { errorMessage = L("외관 설정을 읽지 못했습니다. 원본을 보존하며 읽기 전용 기본값을 표시합니다. ", "Appearance settings could not be read. The original is preserved; defaults are read-only. ") + error.localizedDescription }
        applyIcon()
    }

    func hex(_ role: AppearanceColorRole) -> String { preferences.colors[role]! }
    func color(_ role: AppearanceColorRole) -> Color { Color(nsColor: Self.nsColor(hex(role))) }

    static func nsColor(_ hex: String) -> NSColor {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
    }

    func setColor(_ value: String, for role: AppearanceColorRole) {
        change { try $0.setColor(value, for: role) }
    }

    func setColor(_ value: Color, for role: AppearanceColorRole) {
        guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
        let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        setColor(hex, for: role)
    }

    func selectPalette(_ palette: AppearancePalette) { change { $0.selectPalette(palette) } }
    func resetColors() { selectPalette(preferences.palette) }
    func selectIcon(_ icon: AppearanceIcon) { change { $0.icon = icon } }

    private func change(_ update: (inout AppearancePreferences) throws -> Void) {
        guard !isReadOnly else { return }
        var next = preferences
        do {
            try update(&next)
            try next.validate()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        preferences = next
        applyIcon()
        do { try store.save(next); errorMessage = nil }
        catch { errorMessage = L("현재 외관은 적용했지만 저장하지 못했습니다. 재시작하면 이전 설정으로 돌아갑니다. ", "Applied for this session, but saving failed. Restarting will restore the previous settings. ") + error.localizedDescription }
    }

    func importIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("아이콘 가져오기", "Import icon")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importIcon(from: url)
    }

    func importIcon(from url: URL) {
        guard !isReadOnly else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= AppearanceStore.maximumImageBytes,
                  ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { throw AppearanceError.invalidImage }
            let filename = try store.importImage(Data(contentsOf: url, options: .mappedIfSafe))
            change { $0.customImageFilename = filename; $0.icon = .custom }
        } catch { errorMessage = error.localizedDescription }
    }

    func image(for icon: AppearanceIcon) -> NSImage {
        if icon == .original { return originalIcon }
        if icon == .custom {
            guard let filename = preferences.customImageFilename,
                  let url = try? store.imageURL(filename), let image = NSImage(contentsOf: url) else { return originalIcon }
            return image
        }
        if let image = builtInIcons[icon] { return image }
        let tint: String
        switch icon {
        case .mint: tint = "#52AC91"
        case .blue: tint = "#588DB4"
        case .lavender: tint = "#A18ABD"
        case .graphite: tint = "#69767E"
        default: return originalIcon
        }
        guard let bytes = originalIcon.tiffRepresentation, let source = CIImage(data: bytes),
              let filter = CIFilter(name: "CIColorMonochrome") else { return originalIcon }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(CIColor(color: Self.nsColor(tint)), forKey: kCIInputColorKey)
        filter.setValue(1.0, forKey: kCIInputIntensityKey)
        guard let output = filter.outputImage,
              let cgImage = iconContext.createCGImage(output, from: source.extent) else { return originalIcon }
        let image = NSImage(cgImage: cgImage, size: originalIcon.size)
        builtInIcons[icon] = image
        return image
    }

    private func applyIcon() {
        iconImage = image(for: preferences.icon)
        NSApplication.shared.applicationIconImage = iconImage
    }
}
