import Foundation
import ImageIO
import AfterSixCore

func checkAppearancePreferences() throws {
    expectEqual(AppearancePalette.allCases.count, 6)
    expectEqual(AppearanceIcon.allCases.count, 6) // Five bundled choices plus imported image.
    expectEqual(AppearancePalette.softMint.colors[.background], "#E9EFEB")
    expectEqual(AppearancePalette.charcoal.colors[.text], "#E0E7E4")
    let paletteSpec: [(AppearancePalette, [String])] = [
        (.softMint, ["#E9EFEB", "#E0E7E2", "#286F5D", "#26382E"]),
        (.warmStone, ["#EEEAE3", "#E4DED5", "#786347", "#38342E"]),
        (.blueGray, ["#E7EDF1", "#DDE5EB", "#426780", "#2B3741"]),
        (.dustyLavender, ["#EEEAF1", "#E4DEEA", "#77608D", "#3A3242"]),
        (.charcoal, ["#252A2D", "#1E2326", "#8CC5B4", "#E0E7E4"])
    ]
    for (palette, expected) in paletteSpec {
        expectEqual([AppearanceColorRole.background, .sidebar, .accent, .text].map { palette.colors[$0]! }, expected)
        expectEqual(palette.colors.count, 5)
    }
    try expectEqual(try AppearancePreferences.normalizedHex("#abcdef"), "#ABCDEF")
    for invalid in ["FFF", "#FFFF", "#12345678", "#GG0000", "123456", "#１２３４５６"] {
        expectThrows(try AppearancePreferences.normalizedHex(invalid))
    }
    // Existing raw values, custom colors and icon selections must survive the new default.
    for raw in ["softMint", "warmStone", "blueGray", "dustyLavender", "charcoal"] {
        let data = Data(("{\"version\":1,\"palette\":\"" + raw + "\",\"customColors\":{\"accent\":\"#123456\"},\"icon\":\"blue\"}").utf8)
        let saved = try JSONDecoder().decode(AppearancePreferences.self, from: data)
        expectEqual(saved.palette.rawValue, raw)
        expectEqual(saved.colors[.accent], "#123456")
        expectEqual(saved.icon, .blue)
        try expectEqual(try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(saved)), saved)
    }
    var preferences = AppearancePreferences()
    expectEqual(preferences.palette.rawValue, "offwhiteLilac")
    expectEqual(preferences.colors[.background], "#FAF9FC")
    expectEqual(preferences.colors[.sidebar], "#EEE8F8")
    expectEqual(preferences.colors[.surface], "#FFFFFF")
    expectEqual(preferences.colors[.accent], "#7054B3")
    expectEqual(preferences.colors[.text], "#2F2B3D")
    expectTrue(preferences.contrastRatio > 4.5)
    try preferences.setColor("#FAF9FC", for: .text)
    expectTrue(preferences.contrastRatio < 1.01)
    let beforeInvalid = preferences
    expectThrows(try preferences.setColor("red", for: .text))
    expectEqual(preferences, beforeInvalid)
    preferences.selectPalette(.charcoal)
    expectEqual(preferences.colors, AppearancePalette.charcoal.colors)
    expectTrue(preferences.customColors.isEmpty)
    preferences.icon = .blue
    preferences.selectPalette(.warmStone)
    expectEqual(preferences.icon, .blue)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-check-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let production = AppearanceStore(rootDirectory: root, bundleIdentifier: "test.happylulu")
    let development = AppearanceStore(rootDirectory: root, bundleIdentifier: "test.happylulu.dev")
    expectTrue(production.directory != development.directory)
    try expectEqual(try production.load(), nil)
    expectFalse(FileManager.default.fileExists(atPath: production.directory.path))
    try production.save(preferences)
    try expectEqual(try AppearanceStore(rootDirectory: root, bundleIdentifier: "test.happylulu").load(), preferences)
    try expectEqual(try development.load(), nil)
    let bytes = try Data(contentsOf: production.preferencesURL)
    for invalidName in ["../other.png", "/tmp/icon.png", ".hidden.png", "icon.gif", "nested/icon.jpg"] {
        var invalid = preferences
        invalid.icon = .custom
        invalid.customImageFilename = invalidName
        expectThrows(try production.save(invalid))
        try expectEqual(try Data(contentsOf: production.preferencesURL), bytes)
    }
    expectThrows(try production.importImage(Data("not an image".utf8)))
    // A real one-pixel PNG exercises decode, copying, safe reference and restart.
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    let source = CGImageSourceCreateWithData(png as CFData, nil)!
    let jpeg = NSMutableData()
    let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImageFromSource(destination, source, 0, nil)
    expectTrue(CGImageDestinationFinalize(destination))
    let jpegFilename = try production.importImage(jpeg as Data)
    expectTrue(jpegFilename.hasSuffix(".jpg"))
    let directoryReference = production.directory.appendingPathComponent("directory.png")
    try FileManager.default.createDirectory(at: directoryReference, withIntermediateDirectories: true)
    expectThrows(try production.imageURL("directory.png"))
    let symlinkReference = production.directory.appendingPathComponent("symlink.png")
    try FileManager.default.createSymbolicLink(at: symlinkReference, withDestinationURL: directoryReference)
    expectThrows(try production.imageURL("symlink.png"))
    let externalPNG = root.appendingPathComponent("external-source.png")
    try png.write(to: externalPNG)
    let externalReference = production.directory.appendingPathComponent("external-reference.png")
    try FileManager.default.createSymbolicLink(at: externalReference, withDestinationURL: externalPNG)
    expectThrows(try production.imageURL("external-reference.png"))
    var symlinkPreferences = preferences
    symlinkPreferences.icon = .custom
    symlinkPreferences.customImageFilename = "external-reference.png"
    expectThrows(try production.save(symlinkPreferences))
    try expectEqual(try Data(contentsOf: externalPNG), png)
    try expectEqual(try Data(contentsOf: production.preferencesURL), bytes)
    let filename = try production.importImage(png)
    preferences.icon = .custom
    preferences.customImageFilename = filename
    try production.save(preferences)
    try expectEqual(try Data(contentsOf: production.imageURL(filename)), png)
    try expectEqual(try AppearanceStore(rootDirectory: root, bundleIdentifier: "test.happylulu").load(), preferences)
    let importedBytes = try Data(contentsOf: production.preferencesURL)
    try Data("broken-image".utf8).write(to: production.imageURL(filename))
    let invalidImageStore = AppearanceStore(rootDirectory: root, bundleIdentifier: "test.happylulu")
    expectThrows(try invalidImageStore.load())
    expectTrue(invalidImageStore.isReadOnly)
    expectThrows(try invalidImageStore.save(AppearancePreferences()))
    try expectEqual(try Data(contentsOf: production.preferencesURL), importedBytes)

    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: production.preferencesURL)
    let damaged = AppearanceStore(rootDirectory: root, bundleIdentifier: "test.happylulu")
    expectThrows(try damaged.load())
    expectTrue(damaged.isReadOnly)
    expectThrows(try damaged.save(AppearancePreferences()))
    try expectEqual(try Data(contentsOf: production.preferencesURL), corrupt)

    for corruptValue in ["{\"version\":99,\"palette\":\"softMint\",\"customColors\":{},\"icon\":\"original\"}",
                         "{\"version\":1,\"palette\":\"softMint\",\"customColors\":{\"text\":\"red\"},\"icon\":\"original\"}",
                         "{\"version\":1,\"palette\":\"softMint\",\"customColors\":{},\"icon\":\"custom\",\"customImageFilename\":\"../escape.png\"}"] {
        let payload = Data(corruptValue.utf8)
        try payload.write(to: production.preferencesURL)
        let invalidStore = AppearanceStore(rootDirectory: root, bundleIdentifier: "test.happylulu")
        expectThrows(try invalidStore.load())
        expectTrue(invalidStore.isReadOnly)
        expectThrows(try invalidStore.save(AppearancePreferences()))
        try expectEqual(try Data(contentsOf: production.preferencesURL), payload)
    }
    var unsupported = AppearancePreferences()
    unsupported.version = 99
    expectThrows(try development.save(unsupported))
    let blockedRoot = root.appendingPathComponent("file-is-not-directory")
    try Data().write(to: blockedRoot)
    let unwritable = AppearanceStore(rootDirectory: blockedRoot, bundleIdentifier: "test")
    expectThrows(try unwritable.save(AppearancePreferences()))
    expectTrue(FileManager.default.fileExists(atPath: blockedRoot.path))
    print("PASS appearance: six palettes, legacy persistence, HEX/contrast, independent icons, atomic isolated persistence, corrupt/read-only, validated image references and write failures")
}
