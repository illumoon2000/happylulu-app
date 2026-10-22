import AppKit
import AfterSixCore
import CryptoKit

@MainActor
private func bitmap(_ image: NSImage, scale: Int) -> NSBitmapImageRep {
    guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep })
        .first(where: { $0.pixelsWide == Int(image.size.width) * scale && $0.pixelsHigh == Int(image.size.height) * scale }) else {
        fatalError("Missing cached \(scale)x representation")
    }
    return rep
}

private func pixels(_ rep: NSBitmapImageRep) -> Data {
    Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
}

private func digest(_ rep: NSBitmapImageRep) -> String {
    SHA256.hash(data: pixels(rep)).map { String(format: "%02x", $0) }.joined()
}

@MainActor
private func tinted(_ image: NSImage, scale: Int, dark: Bool) -> NSImage {
    let source = bitmap(image, scale: scale)
    let result = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide,
        pixelsHigh: source.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<source.pixelsHigh {
        for x in 0..<source.pixelsWide {
            let level: CGFloat = dark ? 1 : 0
            result.setColor(NSColor(deviceRed: level, green: level, blue: level,
                alpha: source.colorAt(x: x, y: y)!.alphaComponent), atX: x, y: y)
        }
    }
    return NSImage(cgImage: result.cgImage!, size: image.size)
}

@MainActor
private func contactSheet(output: URL, scale: Int, dark: Bool) throws {
    let size = NSSize(width: 1000, height: 690)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }
    (dark ? NSColor(deviceWhite: 0.12, alpha: 1) : .white).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    let textColor: NSColor = dark ? .white : .black
    let label: (String, CGFloat, CGFloat, CGFloat) -> Void = { text, x, y, fontSize in
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: textColor])
    }
    label("Vacation eve • \(dark ? "dark" : "light") • \(scale)x • fixture only", 24, 653, 18)
    label("State", 24, 623, 12)
    label("Normal / holiday • native size", 200, 623, 12)
    label("Menu • enlarged 3x", 440, 623, 12)
    label("Header • enlarged 2x", 720, 623, 12)
    for (row, state) in LuluDisplayState.allCases.enumerated() {
        let y = CGFloat(565 - row * 76)
        label(state.rawValue, 24, y + 20, 14)
        for (column, holiday) in [false, true].enumerated() {
            let menu = tinted(LuluBrand.menuBarIcon(for: state, vacationEve: holiday), scale: scale, dark: dark)
            let sourceHeader = LuluBrand.headerIcon(for: state, vacationEve: holiday)
            let header = NSImage(cgImage: bitmap(sourceHeader, scale: scale).cgImage!, size: sourceHeader.size)
            let x = CGFloat(200 + column * 105)
            menu.draw(in: NSRect(x: x, y: y + 20, width: 26, height: 18))
            header.draw(in: NSRect(x: x + 34, y: y + 15, width: 28, height: 28))
            NSGraphicsContext.current!.imageInterpolation = .none
            menu.draw(in: NSRect(x: 440 + CGFloat(column * 120), y: y + 1, width: 78, height: 54))
            header.draw(in: NSRect(x: 720 + CGFloat(column * 100), y: y, width: 56, height: 56))
            NSGraphicsContext.current!.imageInterpolation = .high
        }
    }
    try rep.representation(using: .png, properties: [:])!.write(to:
        output.appendingPathComponent("vacation-\(dark ? "dark" : "light")-\(scale)x.png"))
}

@main
struct VacationAppearanceProbe {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Usage: VacationAppearanceProbe OUTPUT_DIRECTORY") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        precondition(Bundle.main.bundleIdentifier?.hasPrefix("local.happylulu.vacation-probe.") == true)
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures: [String] = []
        var normalHashes: [String] = []
        for state in LuluDisplayState.allCases {
            // Default calls must keep the approved normal image even after the costume cache is used.
            let normalMenu = LuluBrand.menuBarIcon(for: state)
            let normalHeader = LuluBrand.headerIcon(for: state)
            for (kind, normal, size) in [("menu", normalMenu, NSSize(width: 26, height: 18)),
                                         ("header", normalHeader, NSSize(width: 28, height: 28))] {
                precondition(normal.size == size && size.width.isFinite && size.height.isFinite)
                let before = [1, 2].map { pixels(bitmap(normal, scale: $0)) }
                let dressed = kind == "menu" ? LuluBrand.menuBarIcon(for: state, vacationEve: true)
                    : LuluBrand.headerIcon(for: state, vacationEve: true)
                let repeated = kind == "menu" ? LuluBrand.menuBarIcon(for: state, vacationEve: true)
                    : LuluBrand.headerIcon(for: state, vacationEve: true)
                let explicitNormal = kind == "menu" ? LuluBrand.menuBarIcon(for: state, vacationEve: false)
                    : LuluBrand.headerIcon(for: state, vacationEve: false)
                precondition(normal === explicitNormal && dressed === repeated, "Images must be cached independently")
                precondition(dressed.size == size && normal.isTemplate == (kind == "menu") && dressed.isTemplate == normal.isTemplate)
                var changedBounds: [NSRect] = []
                for scale in [1, 2] {
                    let original = bitmap(normal, scale: scale)
                    let costume = bitmap(dressed, scale: scale)
                    precondition(before[scale - 1] == pixels(original), "Costume mutated normal owl")
                    normalHashes.append("\(digest(original))  \(kind)-\(state.rawValue)-\(scale)x")
                    if pixels(original) == pixels(costume) { failures.append("\(kind) \(state.rawValue) \(scale)x costume must change visible pixels") }
                    var visible = 0
                    var changedInside = 0
                    var bounds = NSRect.null
                    for y in 0..<costume.pixelsHigh {
                        for x in 0..<costume.pixelsWide {
                            let a = original.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                            let b = costume.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                            precondition([b.redComponent, b.greenComponent, b.blueComponent, b.alphaComponent].allSatisfy { $0.isFinite })
                            if b.alphaComponent > 0.1 { visible += 1 }
                            if kind == "menu", b.alphaComponent > 0.01 {
                                precondition(b.redComponent < 0.01 && b.greenComponent < 0.01 && b.blueComponent < 0.01,
                                             "Menu must remain a monochrome template")
                            }
                            if a != b {
                                let edge = x == 0 || y == 0 || x == costume.pixelsWide - 1 || y == costume.pixelsHigh - 1
                                precondition(!edge, "Accessory clipped at \(kind) \(state) \(scale)x edge \(x),\(y)")
                                changedInside += 1
                                bounds = bounds.union(NSRect(x: CGFloat(x) / CGFloat(scale), y: CGFloat(y) / CGFloat(scale),
                                                             width: 1 / CGFloat(scale), height: 1 / CGFloat(scale)))
                            }
                        }
                    }
                    precondition(visible > 30 * scale * scale, "Blank owl")
                    if changedInside < 5 * scale * scale { failures.append("Too little visible costume: \(kind) \(state) \(scale)x") }
                    changedBounds.append(bounds)
                }
                let a = changedBounds[0], b = changedBounds[1]
                if !zip([a.minX, a.minY, a.maxX, a.maxY], [b.minX, b.minY, b.maxX, b.maxY])
                    .allSatisfy({ abs($0 - $1) <= 1 }) {
                    failures.append("\(kind) \(state) accessory bounds must match at 1x/2x: \(a), \(b)")
                }
            }
        }
        try (normalHashes.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("normal-pixel-sha256.txt"), atomically: true, encoding: .utf8)
        for scale in [1, 2] {
            for dark in [false, true] { try contactSheet(output: output, scale: scale, dark: dark) }
        }
        if !failures.isEmpty {
            for failure in failures { print("FAIL \(failure)") }
            exit(1)
        }
        print("PASS vacation appearance: 8 unchanged normal states, distinct cached costumes; 26x18 menu / 28x28 header, 1x/2x, finite pixels, monochrome templates, no accessory clipping")
        print("PASS 4 light/dark native-size contact sheets: \(output.path)")
    }
}
