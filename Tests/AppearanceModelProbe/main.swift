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
        let mint = model.image(for: .mint)
        precondition(model.image(for: .mint) === mint, "Repeated preview requests must reuse the rendered icon")
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
        precondition(model.image(for: .mint) === mint, "Palette and color edits must retain built-in previews")
        var images = Set<Data>()
        for icon in [AppearanceIcon.original,.mint,.blue,.lavender,.graphite] {
            model.selectIcon(icon)
            precondition(model.errorMessage == nil && model.preferences.icon == icon)
            precondition(model.iconImage === model.image(for: icon), "Selection must reuse the preview image")
            guard let data = model.iconImage.tiffRepresentation else { preconditionFailure("Missing icon pixels") }
            images.insert(data)
            precondition(NSApplication.shared.applicationIconImage.size == model.iconImage.size)
        }
        precondition(images.count == 5, "Icon variants must produce five distinct images")
        let otherOriginal = NSImage(cgImage: NSBitmapImageRep(data: originalBytes)!.cgImage!,
            size: NSSize(width: 32, height: 32))
        let other = AppearanceModel(store: AppearanceStore(rootDirectory: root,
            bundleIdentifier: "test.happylulu.other-icon"), originalIcon: otherOriginal)
        precondition(other.image(for: .mint) !== mint, "Built-in previews belong to each model's original icon")
        precondition(other.image(for: .mint).size == otherOriginal.size)
        model.importIcon(from: source)
        precondition(model.errorMessage == nil && model.preferences.icon == .custom)
        let sourceAfter = try Data(contentsOf: source)
        precondition(sourceAfter == originalBytes)
        let custom = model.preferences
        let customPixels = model.iconImage.tiffRepresentation
        let restarted = AppearanceModel(store: AppearanceStore(rootDirectory: root,
            bundleIdentifier:"test.happylulu.appearance-model"), originalIcon: original)
        precondition(restarted.preferences == custom && restarted.errorMessage == nil)
        let jpegURL = root.appendingPathComponent("fixture.jpg")
        let bitmap = NSBitmapImageRep(data: original.tiffRepresentation!)!
        try bitmap.representation(using: .jpeg, properties: [.compressionFactor:0.8])!.write(to: jpegURL)
        model.importIcon(from: jpegURL)
        precondition(model.errorMessage == nil && model.preferences.icon == .custom)
        precondition(model.iconImage.tiffRepresentation == NSImage(contentsOf: jpegURL)!.tiffRepresentation,
            "Custom replacement must show the latest imported image")
        precondition(model.iconImage.tiffRepresentation != customPixels)
        let firstCopy = try store.imageURL(custom.customImageFilename!)
        precondition(!FileManager.default.fileExists(atPath: firstCopy.path), "Successful replacement must remove the superseded generated copy")
        let jpegBytes = try Data(contentsOf: jpegURL)
        let sourceAfterReplacement = try Data(contentsOf: source)
        precondition(sourceAfterReplacement == originalBytes)
        let replacement = model.preferences
        let replacementCopy = try store.imageURL(replacement.customImageFilename!)
        let replacementRestart = AppearanceModel(store: AppearanceStore(rootDirectory: root,
            bundleIdentifier:"test.happylulu.appearance-model"), originalIcon: original)
        precondition(replacementRestart.preferences == replacement && replacementRestart.errorMessage == nil)
        let beforeInvalid = model.preferences
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        model.importIcon(from: invalid)
        precondition(model.preferences == beforeInvalid && model.errorMessage != nil)
        precondition(FileManager.default.fileExists(atPath: replacementCopy.path))
        let persistedBytes = try Data(contentsOf: store.preferencesURL)
        let backup = root.appendingPathComponent("saved-appearance.json")
        try FileManager.default.moveItem(at: store.preferencesURL, to: backup)
        try FileManager.default.createDirectory(at: store.preferencesURL, withIntermediateDirectories: false)
        model.importIcon(from: source)
        precondition(model.errorMessage != nil, "Replacing preferences with a directory must fail persistence")
        precondition(FileManager.default.fileExists(atPath: replacementCopy.path), "Failed persistence must retain the previously saved image")
        let unsavedCopy = try store.imageURL(model.preferences.customImageFilename!)
        precondition(FileManager.default.fileExists(atPath: unsavedCopy.path), "Session-applied image must remain readable after failed persistence")
        try FileManager.default.removeItem(at: store.preferencesURL)
        try FileManager.default.moveItem(at: backup, to: store.preferencesURL)
        let failedRestart = AppearanceModel(store: AppearanceStore(rootDirectory: root,
            bundleIdentifier:"test.happylulu.appearance-model"), originalIcon: original)
        precondition(failedRestart.preferences == replacement && failedRestart.errorMessage == nil)
        let persistedAfterFailure = try Data(contentsOf: store.preferencesURL)
        precondition(persistedAfterFailure == persistedBytes)
        model.importIcon(from: jpegURL)
        precondition(model.errorMessage == nil)
        precondition(!FileManager.default.fileExists(atPath: replacementCopy.path))
        precondition(!FileManager.default.fileExists(atPath: unsavedCopy.path), "A later successful save must remove superseded session copies")
        let finalSourceBytes = try Data(contentsOf: source)
        let finalJPEGBytes = try Data(contentsOf: jpegURL)
        precondition(finalSourceBytes == originalBytes)
        precondition(finalJPEGBytes == jpegBytes)
        // Files without the app-generated UUID name and replaced symlinks are never cleanup targets.
        let safetyStore = AppearanceStore(rootDirectory: root, bundleIdentifier: "test.happylulu.cleanup-safety")
        try FileManager.default.createDirectory(at: safetyStore.directory, withIntermediateDirectories: true)
        let userCopy = safetyStore.directory.appendingPathComponent("user-selected.png")
        try originalBytes.write(to: userCopy)
        var userPreferences = AppearancePreferences()
        userPreferences.icon = .custom
        userPreferences.customImageFilename = "user-selected.png"
        try safetyStore.save(userPreferences)
        let safetyModel = AppearanceModel(store: safetyStore, originalIcon: original)
        safetyModel.importIcon(from: source)
        precondition(safetyModel.errorMessage == nil && FileManager.default.fileExists(atPath: userCopy.path))
        let symlinkCopy = try safetyStore.imageURL(safetyModel.preferences.customImageFilename!)
        try FileManager.default.removeItem(at: symlinkCopy)
        try FileManager.default.createSymbolicLink(at: symlinkCopy, withDestinationURL: source)
        safetyModel.importIcon(from: jpegURL)
        precondition(safetyModel.errorMessage == nil)
        let symlinkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkCopy.path)
        precondition(symlinkDestination == source.path, "Cleanup must leave replaced symlinks untouched")
        let protectedSourceBytes = try Data(contentsOf: source)
        let protectedUserBytes = try Data(contentsOf: userCopy)
        precondition(protectedSourceBytes == originalBytes && protectedUserBytes == originalBytes)
        let corrupt = Data("broken preferences".utf8)
        try corrupt.write(to: store.preferencesURL)
        let protectedModel = AppearanceModel(store: AppearanceStore(rootDirectory: root,
            bundleIdentifier:"test.happylulu.appearance-model"), originalIcon: original)
        precondition(protectedModel.isReadOnly && protectedModel.errorMessage != nil)
        protectedModel.selectPalette(.warmStone)
        let preserved = try Data(contentsOf:store.preferencesURL)
        precondition(preserved == corrupt)
        print("PASS appearance model: five live palettes, HEX rejection/reset, five distinct cached runtime icons, per-model cache isolation, fresh PNG/JPEG replacement, superseded-copy cleanup after persistence, failed validation/save and restart preserve referenced images and original sources, corrupt bytes preserved")
    }
}
