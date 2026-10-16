import AppKit
import SwiftUI
import AfterSixCore

@main
struct AppearanceModelProbe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = URL(fileURLWithPath: CommandLine.arguments[2])
        let originalBytes = try Data(contentsOf: source)
        let original = NSImage(contentsOf: source)!
        let store = AppearanceStore(rootDirectory: root, bundleIdentifier: "test.happylulu.appearance-model")
        let model = AppearanceModel(store: store, originalIcon: original)
        let expected: [(AppearancePalette, String)] = [(.softMint,"#E9EFEB"),(.warmStone,"#EEEAE3"),
            (.blueGray,"#E7EDF1"),(.dustyLavender,"#EEEAF1"),(.charcoal,"#252A2D")]
        for (palette, background) in expected {
            model.selectPalette(palette)
            precondition(model.errorMessage == nil && model.hex(.background) == background)
            let persisted = try store.load()
            precondition(persisted == model.preferences)
            let rgb = NSColor(model.background).usingColorSpace(.sRGB)!
            let actual = String(format:"#%02X%02X%02X",Int((rgb.redComponent*255).rounded()),
                                Int((rgb.greenComponent*255).rounded()),Int((rgb.blueComponent*255).rounded()))
            precondition(actual == background)
        }
        model.setColor("#112233", for: .background)
        let valid = model.preferences
        model.setColor("oops", for: .background)
        precondition(model.preferences == valid && model.errorMessage != nil)
        model.resetColors()
        precondition(model.errorMessage == nil && model.preferences.customColors.isEmpty)
        var images = Set<Data>()
        for icon in [AppearanceIcon.original,.mint,.blue,.lavender,.graphite] {
            model.selectIcon(icon)
            precondition(model.errorMessage == nil && model.preferences.icon == icon)
            guard let data = model.iconImage.tiffRepresentation else { preconditionFailure("Missing icon pixels") }
            images.insert(data)
            precondition(NSApplication.shared.applicationIconImage.size == model.iconImage.size)
        }
        precondition(images.count == 5, "Icon variants must produce five distinct images")
        model.importIcon(from: source)
        precondition(model.errorMessage == nil && model.preferences.icon == .custom)
        let sourceAfter = try Data(contentsOf: source)
        precondition(sourceAfter == originalBytes)
        let custom = model.preferences
        let restarted = AppearanceModel(store: AppearanceStore(rootDirectory: root,
            bundleIdentifier:"test.happylulu.appearance-model"), originalIcon: original)
        precondition(restarted.preferences == custom && restarted.errorMessage == nil)
        let jpegURL = root.appendingPathComponent("fixture.jpg")
        let bitmap = NSBitmapImageRep(data: original.tiffRepresentation!)!
        try bitmap.representation(using: .jpeg, properties: [.compressionFactor:0.8])!.write(to: jpegURL)
        model.importIcon(from: jpegURL)
        precondition(model.errorMessage == nil && model.preferences.icon == .custom)
        let beforeInvalid = model.preferences
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        model.importIcon(from: invalid)
        precondition(model.preferences == beforeInvalid && model.errorMessage != nil)
        let corrupt = Data("broken preferences".utf8)
        try corrupt.write(to: store.preferencesURL)
        let protectedModel = AppearanceModel(store: AppearanceStore(rootDirectory: root,
            bundleIdentifier:"test.happylulu.appearance-model"), originalIcon: original)
        precondition(protectedModel.isReadOnly && protectedModel.errorMessage != nil)
        protectedModel.selectPalette(.warmStone)
        let preserved = try Data(contentsOf:store.preferencesURL)
        precondition(preserved == corrupt)
        print("PASS appearance model: five live palettes, HEX rejection/reset, five distinct runtime icons, PNG/JPEG import, restart and corrupt bytes preserved")
    }
}
