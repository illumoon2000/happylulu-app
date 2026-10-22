import AppKit

/// Original silhouettes share one small canvas; only the cached frame changes while running.
@MainActor
public enum RunnerArtwork {
    public static let frameCount = 8
    public static let size = NSSize(width: 26, height: 18)
    private static let frames = Dictionary(uniqueKeysWithValues: RunnerAnimal.allCases.map { animal in
        (animal, (0..<frameCount).map { makeImage(for: animal, frame: $0) })
    })

    public static func image(for animal: RunnerAnimal, frame: Int) -> NSImage {
        frames[animal]![(frame % frameCount + frameCount) % frameCount]
    }

    private static func makeImage(for animal: RunnerAnimal, frame: Int) -> NSImage {
        let image = NSImage(size: size)
        for scale in [1, 2] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.shouldAntialias = true
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            draw(animal, frame: frame)
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(animal.englishName) CPU runner"
        return image
    }

    // Source: runner-candidates-v1.png in the shared design library. The approved
    // silhouette is traced into a body and limbs, so articulation cannot reshape
    // the cheeks, belly or ears. Hidden feet are occluded by the body, not collapsed.
    private static func draw(_ animal: RunnerAnimal, frame: Int) {
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        NSColor.black.setFill()
        switch animal {
        case .hamster:
            context.translateBy(x: 3.2, y: 16.3)
            context.scaleBy(x: 0.097, y: -0.097)
            context.translateBy(x: 0, y: [CGFloat](arrayLiteral: 0, 2, 0, -3, -5, -4, -2, 0)[frame])
            limb(hamsterHind, pivot: (27, 123), angle: [0, -25, -60, -90, -100, -70, -35, -10][frame])
            limb(hamsterFront, pivot: (145, 123), angle: [0, 30, 65, 95, 65, 15, -25, -20][frame])
            smoothPath(hamsterBody).fill()
            clear(hamsterEye)
        case .rabbit:
            context.translateBy(x: 4.1, y: 16.85)
            context.scaleBy(x: 0.088, y: -0.088)
            context.translateBy(x: 0, y: [CGFloat](arrayLiteral: 0, -3, -6, -5, -3, -1, 1, 2)[frame])
            limb(rabbitHind, pivot: (36, 143), angle: [0, 20, 25, -10, -60, -85, -60, -25][frame],
                 rise: [0, 0, 0, -3, -6, -6, -8, -6][frame])
            limb(rabbitFront, pivot: (137, 141), angle: [0, 35, 75, 110, 100, 50, 0, -20][frame],
                 rise: [0, -6, -6, 0, 0, -8, 0, 0][frame])
            let body = rabbitBody.map { point -> NSPoint in
                let weight = (1 - ramp(45, 76, point.y)) * (1 - ramp(110, 145, point.x))
                return NSPoint(x: point.x + weight * [CGFloat](arrayLiteral: 0, -1, -3, -2, 1, 4, 4, 2)[frame],
                               y: point.y + weight * [CGFloat](arrayLiteral: 0, 2, 3, 1, -1, -2, -2, -1)[frame])
            }
            smoothPath(body).fill()
            clear(rabbitEye)
        case .cat:
            context.translateBy(x: 1.4, y: 16.65)
            context.scaleBy(x: 0.085, y: -0.085)
            context.translateBy(x: 0, y: [CGFloat](arrayLiteral: 0, -2, -5, -7, -5, -2, 1, 2)[frame])
            limb(catFar, pivot: (103, 139), angle: [0, -15, -40, -70, -20, 35, 60, 30][frame])
            limb(catHind, pivot: (71, 132), angle: [0, 20, 10, -35, -85, -120, -80, -30][frame], sock: catHindSock)
            limb(catFront, pivot: (181, 130), angle: [0, 30, 65, 110, 125, 75, 10, -20][frame],
                 rise: [0, -3, -6, -3, 0, 0, 0, 0][frame], sock: catFrontSock)
            let body = catBody.map { point -> NSPoint in
                let weight = (1 - ramp(85, 113, point.y)) * (1 - ramp(65, 81, point.x))
                return NSPoint(x: point.x + weight * [CGFloat](arrayLiteral: 0, -1, -2, -1, 1, 3, 3, 1)[frame],
                               y: point.y + weight * [CGFloat](arrayLiteral: 0, 1, 2, 1, -1, -2, -2, -1)[frame])
            }
            smoothPath(body).fill()
            clear(catEye)
        }
        context.restoreGState()
    }

    private static func limb(_ outline: [NSPoint], pivot: (CGFloat, CGFloat), angle: CGFloat,
                             rise: CGFloat = 0, sock: [NSPoint] = []) {
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.translateBy(x: pivot.0, y: pivot.1 + rise)
        context.rotate(by: angle * .pi / 180)
        context.translateBy(x: -pivot.0, y: -pivot.1)
        smoothPath(outline).fill()
        if !sock.isEmpty { clear(sock) }
        context.restoreGState()
    }

    private static func clear(_ contour: [NSPoint]) {
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.setBlendMode(.clear)
        smoothPath(contour).fill()
        context.restoreGState()
    }

    private static func ramp(_ lower: CGFloat, _ upper: CGFloat, _ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, (value - lower) / (upper - lower)))
        return t * t * (3 - 2 * t)
    }

    private static func smoothPath(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: points[0])
        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let start = points[index]
            let end = points[(index + 1) % points.count]
            let next = points[(index + 2) % points.count]
            path.curve(to: end,
                controlPoint1: NSPoint(x: start.x + (end.x - previous.x) / 6,
                                      y: start.y + (end.y - previous.y) / 6),
                controlPoint2: NSPoint(x: end.x - (next.x - start.x) / 6,
                                      y: end.y - (next.y - start.y) / 6))
        }
        path.close()
        return path
    }

    private static let hamsterBody: [NSPoint] = [
        NSPoint(x: 9, y: 82), NSPoint(x: 8, y: 77), NSPoint(x: 14, y: 67), NSPoint(x: 25, y: 64), NSPoint(x: 30, y: 67),
        NSPoint(x: 30, y: 71), NSPoint(x: 38, y: 60), NSPoint(x: 55, y: 49), NSPoint(x: 65, y: 46), NSPoint(x: 81, y: 46),
        NSPoint(x: 75, y: 36), NSPoint(x: 75, y: 26), NSPoint(x: 77, y: 20), NSPoint(x: 84, y: 12), NSPoint(x: 91, y: 9),
        NSPoint(x: 104, y: 9), NSPoint(x: 111, y: 12), NSPoint(x: 120, y: 23), NSPoint(x: 123, y: 23), NSPoint(x: 125, y: 22),
        NSPoint(x: 123, y: 19), NSPoint(x: 124, y: 9), NSPoint(x: 132, y: 3), NSPoint(x: 141, y: 4), NSPoint(x: 151, y: 12),
        NSPoint(x: 154, y: 18), NSPoint(x: 154, y: 27), NSPoint(x: 161, y: 29), NSPoint(x: 174, y: 39), NSPoint(x: 183, y: 53),
        NSPoint(x: 185, y: 64), NSPoint(x: 193, y: 69), NSPoint(x: 196, y: 76), NSPoint(x: 195, y: 89), NSPoint(x: 182, y: 105),
        NSPoint(x: 165, y: 113), NSPoint(x: 157, y: 113), NSPoint(x: 129, y: 134), NSPoint(x: 117, y: 139), NSPoint(x: 104, y: 141),
        NSPoint(x: 83, y: 140), NSPoint(x: 69, y: 135), NSPoint(x: 57, y: 140), NSPoint(x: 44, y: 141), NSPoint(x: 30, y: 137),
        NSPoint(x: 24, y: 132), NSPoint(x: 16, y: 117), NSPoint(x: 15, y: 99), NSPoint(x: 18, y: 90), NSPoint(x: 12, y: 89),
    ]

    private static let hamsterFront: [NSPoint] = [
        NSPoint(x: 157, y: 113), NSPoint(x: 157, y: 115), NSPoint(x: 161, y: 116), NSPoint(x: 159, y: 120), NSPoint(x: 165, y: 117),
        NSPoint(x: 173, y: 120), NSPoint(x: 176, y: 124), NSPoint(x: 176, y: 133), NSPoint(x: 169, y: 139), NSPoint(x: 156, y: 140),
        NSPoint(x: 129, y: 134),
    ]

    private static let hamsterHind: [NSPoint] = [
        NSPoint(x: 24, y: 132), NSPoint(x: 25, y: 139), NSPoint(x: 15, y: 146), NSPoint(x: 7, y: 146), NSPoint(x: 3, y: 141),
        NSPoint(x: 9, y: 122), NSPoint(x: 16, y: 117),
    ]

    private static let hamsterEye: [NSPoint] = [
        NSPoint(x: 159, y: 76), NSPoint(x: 162, y: 76), NSPoint(x: 166, y: 69), NSPoint(x: 165, y: 61), NSPoint(x: 160, y: 56),
        NSPoint(x: 156, y: 57), NSPoint(x: 153, y: 62), NSPoint(x: 153, y: 71), NSPoint(x: 155, y: 75),
    ]

    private static let rabbitBody: [NSPoint] = [
        NSPoint(x: 124, y: 60), NSPoint(x: 129, y: 59), NSPoint(x: 129, y: 57), NSPoint(x: 122, y: 52), NSPoint(x: 85, y: 39),
        NSPoint(x: 70, y: 31), NSPoint(x: 62, y: 23), NSPoint(x: 61, y: 13), NSPoint(x: 68, y: 8), NSPoint(x: 87, y: 7),
        NSPoint(x: 99, y: 10), NSPoint(x: 122, y: 23), NSPoint(x: 138, y: 41), NSPoint(x: 146, y: 57), NSPoint(x: 156, y: 58),
        NSPoint(x: 171, y: 64), NSPoint(x: 185, y: 76), NSPoint(x: 190, y: 85), NSPoint(x: 193, y: 100), NSPoint(x: 199, y: 106),
        NSPoint(x: 199, y: 116), NSPoint(x: 196, y: 122), NSPoint(x: 181, y: 134), NSPoint(x: 158, y: 139), NSPoint(x: 123, y: 158),
        NSPoint(x: 106, y: 159), NSPoint(x: 88, y: 156), NSPoint(x: 68, y: 166), NSPoint(x: 54, y: 166), NSPoint(x: 38, y: 160),
        NSPoint(x: 31, y: 137), NSPoint(x: 32, y: 130), NSPoint(x: 22, y: 131), NSPoint(x: 17, y: 128), NSPoint(x: 17, y: 124),
        NSPoint(x: 14, y: 122), NSPoint(x: 13, y: 114), NSPoint(x: 17, y: 107), NSPoint(x: 22, y: 106), NSPoint(x: 25, y: 100),
        NSPoint(x: 38, y: 100), NSPoint(x: 44, y: 105), NSPoint(x: 44, y: 108), NSPoint(x: 39, y: 113), NSPoint(x: 40, y: 115),
        NSPoint(x: 46, y: 109), NSPoint(x: 61, y: 101), NSPoint(x: 76, y: 98), NSPoint(x: 92, y: 99), NSPoint(x: 97, y: 85),
        NSPoint(x: 106, y: 76), NSPoint(x: 106, y: 74), NSPoint(x: 100, y: 74), NSPoint(x: 63, y: 77), NSPoint(x: 39, y: 72),
        NSPoint(x: 22, y: 62), NSPoint(x: 19, y: 52), NSPoint(x: 23, y: 45), NSPoint(x: 44, y: 38), NSPoint(x: 69, y: 39),
        NSPoint(x: 97, y: 47),
    ]

    private static let rabbitFront: [NSPoint] = [
        NSPoint(x: 158, y: 139), NSPoint(x: 169, y: 144), NSPoint(x: 175, y: 151), NSPoint(x: 176, y: 162), NSPoint(x: 173, y: 166),
        NSPoint(x: 167, y: 168), NSPoint(x: 158, y: 167), NSPoint(x: 160, y: 171), NSPoint(x: 157, y: 176), NSPoint(x: 145, y: 177),
        NSPoint(x: 136, y: 172), NSPoint(x: 123, y: 158),
    ]

    private static let rabbitHind: [NSPoint] = [
        NSPoint(x: 38, y: 160), NSPoint(x: 18, y: 174), NSPoint(x: 8, y: 174), NSPoint(x: 5, y: 172), NSPoint(x: 3, y: 163),
        NSPoint(x: 9, y: 149), NSPoint(x: 22, y: 135), NSPoint(x: 27, y: 134), NSPoint(x: 31, y: 137),
    ]

    private static let rabbitEye: [NSPoint] = [
        NSPoint(x: 178, y: 99), NSPoint(x: 176, y: 92), NSPoint(x: 170, y: 92), NSPoint(x: 167, y: 99), NSPoint(x: 169, y: 107),
        NSPoint(x: 175, y: 109), NSPoint(x: 178, y: 105),
    ]

    private static let catBody: [NSPoint] = [
        NSPoint(x: 26, y: 41), NSPoint(x: 41, y: 36), NSPoint(x: 51, y: 37), NSPoint(x: 60, y: 41), NSPoint(x: 71, y: 55),
        NSPoint(x: 73, y: 64), NSPoint(x: 72, y: 83), NSPoint(x: 75, y: 91), NSPoint(x: 78, y: 93), NSPoint(x: 87, y: 84),
        NSPoint(x: 103, y: 78), NSPoint(x: 119, y: 78), NSPoint(x: 128, y: 81), NSPoint(x: 131, y: 66), NSPoint(x: 136, y: 57),
        NSPoint(x: 141, y: 53), NSPoint(x: 146, y: 31), NSPoint(x: 160, y: 7), NSPoint(x: 166, y: 6), NSPoint(x: 173, y: 10),
        NSPoint(x: 183, y: 20), NSPoint(x: 192, y: 35), NSPoint(x: 196, y: 33), NSPoint(x: 207, y: 16), NSPoint(x: 215, y: 12),
        NSPoint(x: 227, y: 30), NSPoint(x: 230, y: 45), NSPoint(x: 237, y: 49), NSPoint(x: 247, y: 61), NSPoint(x: 251, y: 69),
        NSPoint(x: 255, y: 92), NSPoint(x: 268, y: 93), NSPoint(x: 267, y: 95), NSPoint(x: 256, y: 95), NSPoint(x: 255, y: 97),
        NSPoint(x: 255, y: 102), NSPoint(x: 263, y: 105), NSPoint(x: 266, y: 111), NSPoint(x: 253, y: 104), NSPoint(x: 248, y: 113),
        NSPoint(x: 235, y: 123), NSPoint(x: 223, y: 128), NSPoint(x: 199, y: 132), NSPoint(x: 163, y: 146), NSPoint(x: 142, y: 145),
        NSPoint(x: 115, y: 135), NSPoint(x: 104, y: 143), NSPoint(x: 91, y: 149), NSPoint(x: 81, y: 150), NSPoint(x: 76, y: 148),
        NSPoint(x: 73, y: 148), NSPoint(x: 64, y: 121), NSPoint(x: 66, y: 112), NSPoint(x: 56, y: 104), NSPoint(x: 53, y: 98),
        NSPoint(x: 51, y: 90), NSPoint(x: 52, y: 73), NSPoint(x: 47, y: 64), NSPoint(x: 40, y: 63), NSPoint(x: 37, y: 65),
        NSPoint(x: 34, y: 75), NSPoint(x: 29, y: 79), NSPoint(x: 19, y: 79), NSPoint(x: 14, y: 75), NSPoint(x: 12, y: 70),
        NSPoint(x: 13, y: 56), NSPoint(x: 17, y: 49),
    ]

    private static let catFront: [NSPoint] = [
        NSPoint(x: 199, y: 132), NSPoint(x: 210, y: 142), NSPoint(x: 222, y: 144), NSPoint(x: 228, y: 151), NSPoint(x: 226, y: 163),
        NSPoint(x: 214, y: 170), NSPoint(x: 201, y: 170), NSPoint(x: 189, y: 166), NSPoint(x: 170, y: 154), NSPoint(x: 163, y: 146),
    ]

    private static let catHind: [NSPoint] = [
        NSPoint(x: 73, y: 148), NSPoint(x: 60, y: 161), NSPoint(x: 48, y: 162), NSPoint(x: 41, y: 155), NSPoint(x: 42, y: 141),
        NSPoint(x: 48, y: 130), NSPoint(x: 55, y: 123), NSPoint(x: 64, y: 121),
    ]

    private static let catFar: [NSPoint] = [
        NSPoint(x: 104, y: 143), NSPoint(x: 109, y: 142), NSPoint(x: 126, y: 150), NSPoint(x: 113, y: 163), NSPoint(x: 106, y: 164),
        NSPoint(x: 100, y: 162), NSPoint(x: 94, y: 156), NSPoint(x: 91, y: 149),
    ]

    private static let catHindSock: [NSPoint] = [
        NSPoint(x: 45, y: 145), NSPoint(x: 45, y: 155), NSPoint(x: 50, y: 159), NSPoint(x: 58, y: 158), NSPoint(x: 67, y: 151),
        NSPoint(x: 60, y: 132), NSPoint(x: 61, y: 124), NSPoint(x: 51, y: 132),
    ]

    private static let catFrontSock: [NSPoint] = [
        NSPoint(x: 194, y: 163), NSPoint(x: 204, y: 167), NSPoint(x: 215, y: 166), NSPoint(x: 224, y: 159), NSPoint(x: 224, y: 151),
        NSPoint(x: 219, y: 147), NSPoint(x: 210, y: 145),
    ]

    private static let catEye: [NSPoint] = [
        NSPoint(x: 223, y: 89), NSPoint(x: 226, y: 95), NSPoint(x: 233, y: 93), NSPoint(x: 235, y: 89), NSPoint(x: 233, y: 76),
        NSPoint(x: 226, y: 75), NSPoint(x: 224, y: 77),
    ]

}
