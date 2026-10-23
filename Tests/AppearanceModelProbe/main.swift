import AppKit
import SwiftUI
import AfterSixCore

@MainActor
private final class SchemeObservation {
    var scheme: ColorScheme?
}

private struct SchemeContent: View {
    @Environment(\.colorScheme) private var scheme
    let observation: SchemeObservation
    var body: some View {
        Text("Isolated appearance fixture")
            .onAppear { observation.scheme = scheme }
            .onChange(of: scheme) { observation.scheme = $0 }
    }
}

private struct SchemeFixture: View {
    @ObservedObject var model: AppearanceModel
    let observation: SchemeObservation
    var body: some View {
        SchemeContent(observation: observation)
            .foregroundStyle(model.text).background(model.background)
            .luluWindowColorScheme(model.preferredColorScheme)
    }
}

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
        precondition(model.preferences.palette == .offwhiteLilac, "New profiles must use the approved palette")
        var menuPixels = Set<Data>()
        var headerPixels = Set<Data>()
        let assets: [(LuluDisplayState, String)] = [(.waiting, "waiting"), (.regular, "regular"),
            (.luluDay, "luluDay"), (.morningHalf, "morningHalf"), (.afternoonHalf, "afternoonHalf"),
            (.readyToLeave, "readyToLeave"), (.annualLeave, "annualLeave"), (.dayOff, "dayOff")]
        for (state, filename) in assets {
            let image = LuluBrand.menuBarIcon(for: state)
            precondition(image === LuluBrand.menuBarIcon(for: state), "Timer updates must reuse each cached state")
            precondition(image.isTemplate && image.size == NSSize(width: 26, height: 18))
            let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
            precondition(reps.count == 2, "Menu symbols need cached 1x and 2x pixels")
            // A doubled bitmap CTM crops the Retina face even when every state has unique bytes.
            let bounds = reps.enumerated().map { index, rep -> CGRect in
                let scale = index + 1
                precondition(rep.pixelsWide == 26 * scale && rep.pixelsHigh == 18 * scale)
                var x0 = rep.pixelsWide, y0 = rep.pixelsHigh, x1 = 0, y1 = 0, opaquePixels = 0
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y)!.alphaComponent > 0.2 {
                        opaquePixels += 1
                        x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
                    }
                }
                precondition(opaquePixels > 40 * scale * scale && x1 > x0 && y1 > y0,
                    "Every menu state needs a visible face, not empty or degenerate bounds")
                precondition(x0 > 0 && y0 > 0 && x1 < rep.pixelsWide - 1 && y1 < rep.pixelsHigh - 1,
                    "The complete outline must fit inside every backing scale")
                return CGRect(x: CGFloat(x0) / CGFloat(scale), y: CGFloat(y0) / CGFloat(scale),
                    width: CGFloat(x1 - x0 + 1) / CGFloat(scale), height: CGFloat(y1 - y0 + 1) / CGFloat(scale))
            }
            precondition(abs(bounds[0].minX - bounds[1].minX) <= 1 && abs(bounds[0].minY - bounds[1].minY) <= 1
                && abs(bounds[0].width - bounds[1].width) <= 1 && abs(bounds[0].height - bounds[1].height) <= 1,
                "Retina symbol must preserve the complete 1x face geometry")
            menuPixels.insert(image.tiffRepresentation!)
            let header = LuluBrand.headerIcon(for: state)
            precondition(header === LuluBrand.headerIcon(for: state) && !header.isTemplate)
            precondition(header.size == NSSize(width: 28, height: 28))
            let url = Bundle.main.url(forResource: filename, withExtension: "png", subdirectory: "OwlStates")!
            let asset = NSImage(contentsOf: url)!
            let headerReps = header.representations.compactMap { $0 as? NSBitmapImageRep }
            precondition(headerReps.count == 2, "Headers need cached 1x and 2x color pixels")
            for (index, rep) in headerReps.enumerated() {
                let scale = index + 1
                precondition(rep.pixelsWide == 28 * scale && rep.pixelsHigh == 28 * scale)
                let expected = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28 * scale,
                    pixelsHigh: 28 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                expected.size = header.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: expected)
                NSGraphicsContext.current!.imageInterpolation = .high
                let ratio = min(28 / asset.size.width, 28 / asset.size.height)
                let size = NSSize(width: asset.size.width * ratio, height: asset.size.height * ratio)
                asset.draw(in: NSRect(x: (28 - size.width) / 2, y: (28 - size.height) / 2,
                    width: size.width, height: size.height))
                NSGraphicsContext.restoreGraphicsState()
                precondition(rep.representation(using: .png, properties: [:]) == expected.representation(using: .png, properties: [:]),
                    "Header must use the matching bundled color face: \(filename)")
                var hasColor = false, hasTransparency = false
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        hasTransparency = hasTransparency || color.alphaComponent < 0.1
                        hasColor = hasColor || (color.alphaComponent > 0.5 && abs(color.redComponent - color.blueComponent) > 0.1)
                    }
                }
                precondition(hasColor && hasTransparency, "Headers must preserve the colored transparent face")
            }
            headerPixels.insert(header.tiffRepresentation!)
        }
        precondition(menuPixels.count == 8, "Each state must retain a distinct expression in monochrome")
        precondition(headerPixels.count == 8, "Every state needs its matching color face")
        let mint = model.image(for: .mint)
        precondition(model.image(for: .mint) === mint, "Repeated preview requests must reuse the rendered icon")
        let expected: [(AppearancePalette, String)] = [(.softMint,"#E9EFEB"),(.warmStone,"#EEEAE3"),
            (.blueGray,"#E7EDF1"),(.dustyLavender,"#EEEAF1"),(.charcoal,"#252A2D"),(.offwhiteLilac,"#FAF9FC")]
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
        if AppearanceModel.supportsNativeAppearance {
            let observation = SchemeObservation()
            let host = NSHostingView(rootView: SchemeFixture(model: model, observation: observation))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            let originalAppearance = NSApp.appearance
            defer {
                window.orderOut(nil); window.contentView = nil; window.close()
                NSApp.appearance = originalAppearance
            }
            for (name, expectedScheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
                // This isolated process's appearance only; never change the user's OS preference.
                NSApp.appearance = NSAppearance(named: name)
                for (palette, expected) in [(AppearancePalette.charcoal, ColorScheme.dark),
                    (.nativeGlass, expectedScheme), (.warmStone, .light), (.nativeGlass, expectedScheme)] {
                    model.selectPalette(palette)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                    precondition(observation.scheme == expected,
                        "Open window must follow theme changes without retaining a previous forced scheme: \(palette) / \(name)")
                }
                precondition(model.usesNativeAppearance && model.preferredColorScheme == nil && !model.hasLowContrast)
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    let expectedColors: [(AppearanceColorRole, NSColor)] = [(.background, .windowBackgroundColor),
                        (.sidebar, .underPageBackgroundColor), (.surface, .controlBackgroundColor),
                        (.accent, .controlAccentColor), (.text, .labelColor)]
                    for (role, systemColor) in expectedColors {
                        let actual = NSColor(model.color(role)).usingColorSpace(.sRGB)!
                        let expected = systemColor.usingColorSpace(.sRGB)!
                        precondition(abs(actual.redComponent - expected.redComponent) < 0.001
                            && abs(actual.greenComponent - expected.greenComponent) < 0.001
                            && abs(actual.blueComponent - expected.blueComponent) < 0.001,
                            "Native theme must use semantic system color for \(role) in \(name)")
                    }
                }
            }
            // System appearance changes must propagate without reselecting a theme.
            for (name, expected) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
                NSApp.appearance = NSAppearance(named: name)
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                precondition(observation.scheme == expected && model.preferences.palette == .nativeGlass)
            }
            let savedNative = try store.load()
            precondition(savedNative?.palette == .nativeGlass)
            let reloaded = AppearanceModel(store: store, originalIcon: original)
            precondition(reloaded.usesNativeAppearance && reloaded.preferredColorScheme == nil)
            print("PASS native appearance: five semantic colors in light/dark, live charcoal/native/warm/native transitions, persisted selection")
        }
        model.selectPalette(.offwhiteLilac)
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
        print("PASS appearance model: six live palettes, eight distinct 26x18 template symbols and matching bundled 28pt color headers at1x/2x, HEX rejection/reset, five distinct cached runtime icons, per-model cache isolation, fresh PNG/JPEG replacement, superseded-copy cleanup after persistence, failed validation/save and restart preserve referenced images and original sources, corrupt bytes preserved")
    }
}
