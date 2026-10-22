import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// swiftc -parse-as-library Sources/CPURunnerIntegration/{RunnerAnimal,RunnerArtwork}.swift scripts/check-runner-artwork.swift -o .build/check-runner-artwork
@main
struct RunnerArtworkChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/runner-artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            guard condition() else { throw Failure(description: message) }
        }
        var animalSignatures = Set<String>()
        for animal in RunnerAnimal.allCases {
            var frameSignatures = Set<String>()
            for frame in 0..<RunnerArtwork.frameCount {
                let image = RunnerArtwork.image(for: animal, frame: frame)
                try expect(image.size == NSSize(width: 26, height: 18), "Wrong logical canvas")
                try expect(image.isTemplate, "Runner must remain a template image")
                try expect(image.representations.count == 2, "Missing 1×/2× representations")
                try expect(image === RunnerArtwork.image(for: animal, frame: frame), "Frame cache was not reused")
                for scale in [1, 2] {
                    guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep })
                        .first(where: { $0.pixelsWide == 26 * scale && $0.pixelsHigh == 18 * scale }),
                        let bytes = rep.bitmapData,
                        let png = rep.representation(using: .png, properties: [:]) else {
                        throw Failure(description: "Missing bitmap for \(animal) \(frame) \(scale)×")
                    }
                    var opaque = 0
                    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
                    for y in 0..<rep.pixelsHigh {
                        for x in 0..<rep.pixelsWide where bytes[y * rep.bytesPerRow + x * 4 + 3] > 8 {
                            opaque += 1
                            minX = min(minX, x); minY = min(minY, y)
                            maxX = max(maxX, x); maxY = max(maxY, y)
                        }
                    }
                    try expect(opaque > 70 * scale * scale, "Blank or too-small animal")
                    try expect(minX > 0 && minY > 0 && maxX < rep.pixelsWide - 1 && maxY < rep.pixelsHigh - 1,
                               "Clipped animal: \(animal) frame\(frame) \(scale)× [\(minX),\(minY),\(maxX),\(maxY)]")
                    try expect(maxX - minX > 15 * scale && maxY - minY > 9 * scale,
                               "Backing image did not fill the logical canvas")
                    try png.write(to: output.appendingPathComponent("\(animal.rawValue)-\(frame)-\(scale)x.png"))
                    if scale == 2 {
                        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
                        frameSignatures.insert(digest)
                        if frame == 0 { animalSignatures.insert(digest) }
                    }
                }
            }
            try expect(frameSignatures.count == RunnerArtwork.frameCount, "Animation needs distinct poses for \(animal)")
            try expect(RunnerArtwork.image(for: animal, frame: -1) === RunnerArtwork.image(for: animal, frame: 7), "Negative frame wrapping")
            try expect(RunnerArtwork.image(for: animal, frame: Int.min) === RunnerArtwork.image(for: animal, frame: 0), "Minimum frame wrapping")
        }
        try expect(animalSignatures.count == 3, "Animal silhouettes must be distinct")
        for dark in [false, true] {
            let board = try makeBoard(dark: dark)
            try png(board).write(to: output.appendingPathComponent(dark ? "runner-frames-dark.png" : "runner-frames-light.png"))
        }
        try makeGIF(output.appendingPathComponent("runner-preview.gif"))
        print("PASS \(checks) artwork assertions; 3 animals × 8 poses × 2 scales")
        print("Rendered: \(output.path)")
    }

    @MainActor
    static func bitmap(width: Int, height: Int, draw: () -> Void) throws -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep) else { throw Failure(description: "Bitmap allocation") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @MainActor
    static func drawRunner(_ animal: RunnerAnimal, frame: Int, in rect: NSRect, dark: Bool) {
        let image = RunnerArtwork.image(for: animal, frame: frame)
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first { $0.pixelsWide == 52 }!
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.interpolationQuality = .none
        context.clip(to: rect, mask: rep.cgImage!)
        context.setFillColor((dark ? NSColor.white : NSColor.black).cgColor)
        context.fill(rect)
        context.restoreGState()
    }

    @MainActor
    static func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, dark: Bool, bold: Bool = false) {
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: dark ? NSColor.white : NSColor.black
        ])
    }

    @MainActor
    static func makeBoard(dark: Bool) throws -> NSBitmapImageRep {
        try bitmap(width: 1120, height: 470) {
            (dark ? NSColor(calibratedWhite: 0.09, alpha: 1) : .white).setFill()
            NSRect(x: 0, y: 0, width: 1120, height: 470).fill()
            label("CPU 러너 · 실제 벡터 프레임", x: 28, y: 425, size: 24, dark: dark, bold: true)
            label("각 동물 8프레임 · 확대와 실제 26×18 pt · 앱 적용 전 렌더 검사", x: 28, y: 399, size: 14, dark: dark)
            for (row, animal) in RunnerAnimal.allCases.enumerated() {
                let y = CGFloat(285 - row * 112)
                label(animal.koreanName, x: 28, y: y + 35, size: 19, dark: dark, bold: true)
                for frame in 0..<8 {
                    drawRunner(animal, frame: frame, in: NSRect(x: 160 + frame * 115, y: Int(y), width: 104, height: 72), dark: dark)
                    drawRunner(animal, frame: frame, in: NSRect(x: 198 + frame * 115, y: Int(y) - 28, width: 26, height: 18), dark: dark)
                }
            }
        }
    }

    @MainActor
    static func makeGIF(_ url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 8, nil) else {
            throw Failure(description: "GIF allocation")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<8 {
            let rep = try bitmap(width: 780, height: 240) {
                NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 780, height: 240).fill()
                label("happylulu CPU 러너 · 실제 프레임 미리보기", x: 28, y: 202, size: 20, dark: false, bold: true)
                for (column, animal) in RunnerAnimal.allCases.enumerated() {
                    let x = CGFloat(60 + column * 250)
                    drawRunner(animal, frame: frame, in: NSRect(x: x, y: 82, width: 156, height: 108), dark: false)
                    label(animal.koreanName, x: x + 47, y: 49, size: 17, dark: false, bold: true)
                    drawRunner(animal, frame: frame, in: NSRect(x: x + 65, y: 22, width: 26, height: 18), dark: false)
                }
            }
            CGImageDestinationAddImage(destination, rep.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "GIF encoding") }
    }

    static func png(_ rep: NSBitmapImageRep) throws -> Data {
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "PNG encoding") }
        return data
    }
}
