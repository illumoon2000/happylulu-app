import AppKit
import AfterSixCore

@MainActor
enum LuluBrand {
    static let headerIcon: NSImage = {
        guard let url = Bundle.main.url(forResource: "HappyLuluBrand", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage(named: NSImage.applicationIconName)! }
        image.accessibilityDescription = "happylulu"
        return image
    }()

    // Rasterize both backing scales once. The countdown may request an image every 0.1 seconds.
    private static let menuImages = Dictionary(uniqueKeysWithValues: LuluDisplayState.allCases.map { state in
        (state, makeImage(size: NSSize(width: 26, height: 18), template: true) { drawFace(state) })
    })
    // Decode only the visible state; loading all eight PNGs delays the first panel opening.
    private static var headerImages: [LuluDisplayState: NSImage] = [:]
    private static var vacationHeaderImages: [LuluDisplayState: NSImage] = [:]

    private static func makeHeaderImage(for state: LuluDisplayState) -> NSImage {
        guard let url = Bundle.main.url(forResource: state.rawValue, withExtension: "png", subdirectory: "OwlStates"),
              let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else {
            return headerIcon
        }
        return makeImage(size: NSSize(width: 28, height: 28), template: false) {
            NSGraphicsContext.current?.imageInterpolation = .high
            let ratio = min(28 / source.size.width, 28 / source.size.height)
            let size = NSSize(width: source.size.width * ratio, height: source.size.height * ratio)
            source.draw(in: NSRect(x: (28 - size.width) / 2, y: (28 - size.height) / 2,
                                   width: size.width, height: size.height))
        }
    }

    private static let vacationMenuImages = menuImages.mapValues { dressedImage($0, template: true) }

    static func menuBarIcon(for state: LuluDisplayState = .waiting, vacationEve: Bool = false) -> NSImage {
        vacationEve ? vacationMenuImages[state]! : menuImages[state]!
    }
    static func headerIcon(for state: LuluDisplayState, vacationEve: Bool = false) -> NSImage {
        if vacationEve, let image = vacationHeaderImages[state] { return image }
        let normal: NSImage
        if let cached = headerImages[state] {
            normal = cached
        } else {
            normal = makeHeaderImage(for: state)
            headerImages[state] = normal
        }
        guard vacationEve else { return normal }
        let image = dressedImage(normal, template: false)
        vacationHeaderImages[state] = image
        return image
    }

    private static func dressedImage(_ original: NSImage, template: Bool) -> NSImage {
        let image = NSImage(size: original.size)
        for source in original.representations.compactMap({ $0 as? NSBitmapImageRep }) {
            guard let pixels = source.bitmapData,
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide,
                    pixelsHigh: source.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: source.bytesPerRow, bitsPerPixel: 0),
                  let destination = rep.bitmapData else { continue }
            // Copy the approved pixels exactly before drawing accessories; never mutate the normal cache.
            destination.update(from: pixels, count: source.bytesPerRow * source.pixelsHigh)
            rep.size = original.size
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.shouldAntialias = true
            drawVacationAccessories(template: template)
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return original }
        image.isTemplate = template
        image.accessibilityDescription = "happylulu"
        return image
    }

    private static func drawVacationAccessories(template: Bool) {
        let straw = template ? NSColor.black : NSColor(deviceRed: 0.91, green: 0.76, blue: 0.43, alpha: 1)
        let outline = template ? NSColor.black : NSColor(deviceRed: 0.48, green: 0.32, blue: 0.14, alpha: 1)
        let crown = NSBezierPath()
        let brim: NSBezierPath
        if template {
            crown.move(to: NSPoint(x: 8, y: 14.1))
            crown.line(to: NSPoint(x: 9.5, y: 16.4))
            crown.curve(to: NSPoint(x: 16.5, y: 16.4),
                        controlPoint1: NSPoint(x: 11, y: 16.9), controlPoint2: NSPoint(x: 15, y: 16.9))
            crown.line(to: NSPoint(x: 18, y: 14.1))
            brim = NSBezierPath(ovalIn: NSRect(x: 5, y: 13.5, width: 16, height: 1.8))
        } else {
            crown.move(to: NSPoint(x: 7.5, y: 21.7))
            crown.line(to: NSPoint(x: 9, y: 25.3))
            crown.curve(to: NSPoint(x: 19, y: 25.3),
                        controlPoint1: NSPoint(x: 11, y: 26.2), controlPoint2: NSPoint(x: 17, y: 26.2))
            crown.line(to: NSPoint(x: 20.5, y: 21.7))
            brim = NSBezierPath(ovalIn: NSRect(x: 3.5, y: 20.4, width: 21, height: 2.8))
        }
        crown.close()
        straw.setFill()
        outline.setStroke()
        brim.fill()
        brim.lineWidth = template ? 0 : 0.4
        if !template { brim.stroke() }
        crown.fill()
        crown.lineWidth = template ? 0 : 0.4
        if !template { crown.stroke() }

        NSGraphicsContext.saveGraphicsState()
        if template {
            NSGraphicsContext.current!.cgContext.setBlendMode(.clear)
        } else {
            NSColor(deviceRed: 0.12, green: 0.44, blue: 0.42, alpha: 1).setFill()
        }
        NSBezierPath(roundedRect: template ? NSRect(x: 8.6, y: 14.8, width: 8.8, height: 0.55)
            : NSRect(x: 7.9, y: 22.1, width: 12.2, height: 1.1), xRadius: 0.25, yRadius: 0.25).fill()
        NSGraphicsContext.restoreGraphicsState()

        let lenses = template
            ? [NSRect(x: 4.4, y: 7.3, width: 6.7, height: 4.4), NSRect(x: 14.9, y: 7.3, width: 6.7, height: 4.4)]
            : [NSRect(x: 5.1, y: 8.3, width: 8.1, height: 5.2), NSRect(x: 15.3, y: 7.5, width: 8.1, height: 5.2)]
        for rect in lenses {
            let lens = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            (template ? NSColor.black.withAlphaComponent(0.32)
                : NSColor(deviceRed: 0.07, green: 0.13, blue: 0.22, alpha: 0.72)).setFill()
            lens.fill()
            (template ? NSColor.black : NSColor(deviceRed: 0.10, green: 0.16, blue: 0.24, alpha: 1)).setStroke()
            lens.lineWidth = template ? 0.8 : 0.7
            lens.stroke()
            NSGraphicsContext.saveGraphicsState()
            if template { NSGraphicsContext.current!.cgContext.setBlendMode(.clear) }
            else { NSColor(deviceRed: 0.70, green: 0.91, blue: 0.96, alpha: 0.8).setFill() }
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 1.2, y: rect.maxY - 1.4, width: 2.1, height: 0.5),
                         xRadius: 0.25, yRadius: 0.25).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let frame = NSBezierPath()
        frame.move(to: NSPoint(x: lenses[0].maxX, y: lenses[0].midY + 0.6))
        frame.curve(to: NSPoint(x: lenses[1].minX, y: lenses[1].midY + 0.6),
                    controlPoint1: NSPoint(x: 12.5, y: lenses[0].midY + 1.7),
                    controlPoint2: NSPoint(x: 14, y: lenses[1].midY + 1.7))
        for rect in lenses {
            let left = rect == lenses[0]
            let x = left ? rect.minX : rect.maxX
            frame.move(to: NSPoint(x: x, y: rect.maxY - 1))
            frame.line(to: NSPoint(x: x + (left ? -1.2 : 1.2), y: rect.maxY - 0.2))
        }
        frame.lineWidth = 0.8
        frame.lineCapStyle = .round
        frame.stroke()
    }

    private static func makeImage(size: NSSize, template: Bool, draw: () -> Void) -> NSImage {
        let image = NSImage(size: size)
        for scale in [1, 2] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = size
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.shouldAntialias = true
            draw()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return headerIcon }
        image.isTemplate = template
        image.accessibilityDescription = "happylulu"
        return image
    }

    private static func drawFace(_ state: LuluDisplayState) {
        // NSGraphicsContext maps logical points to backing pixels; normalize only once.
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: 0, y: 18)
        context.scaleBy(x: 26 / 144, y: -18 / 100)
        NSColor.black.setFill()
        NSColor.black.setStroke()

        // The two broad lobes join above the beak and taper inward below the eyes.
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: 45, y: 84))
        outline.curve(to: NSPoint(x: 10, y: 50), controlPoint1: NSPoint(x: 21, y: 87), controlPoint2: NSPoint(x: 9, y: 72))
        outline.curve(to: NSPoint(x: 39, y: 13), controlPoint1: NSPoint(x: 10, y: 28), controlPoint2: NSPoint(x: 20, y: 13))
        outline.curve(to: NSPoint(x: 72, y: 31), controlPoint1: NSPoint(x: 52, y: 12), controlPoint2: NSPoint(x: 63, y: 22))
        outline.curve(to: NSPoint(x: 105, y: 13), controlPoint1: NSPoint(x: 81, y: 22), controlPoint2: NSPoint(x: 92, y: 12))
        outline.curve(to: NSPoint(x: 134, y: 50), controlPoint1: NSPoint(x: 124, y: 13), controlPoint2: NSPoint(x: 134, y: 28))
        outline.curve(to: NSPoint(x: 99, y: 84), controlPoint1: NSPoint(x: 135, y: 72), controlPoint2: NSPoint(x: 123, y: 87))
        outline.lineWidth = 10
        outline.lineCapStyle = .round
        outline.lineJoinStyle = .round
        outline.stroke()

        for (index, center) in [CGFloat(42), CGFloat(102)].enumerated() {
            let winking = (state == .morningHalf && index == 0) || (state == .afternoonHalf && index == 1)
            if [.luluDay, .readyToLeave, .annualLeave].contains(state) || winking {
                closedEye(center: center)
            } else {
                openEye(center: center, state: state)
            }
        }
        drawBeak(state)
    }

    private static func closedEye(center: CGFloat) {
        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: center - 15, y: 59))
        eye.curve(to: NSPoint(x: center + 15, y: 59),
                  controlPoint1: NSPoint(x: center - 8, y: 39), controlPoint2: NSPoint(x: center + 8, y: 39))
        eye.lineWidth = 7
        eye.lineCapStyle = .round
        eye.stroke()
    }

    private static func openEye(center: CGFloat, state: LuluDisplayState) {
        NSGraphicsContext.saveGraphicsState()
        if state == .dayOff {
            NSBezierPath(rect: NSRect(x: center - 18, y: 54, width: 36, height: 24)).addClip()
        }
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: center, y: 53.5)
        context.rotate(by: 0.16)
        NSBezierPath(ovalIn: NSRect(x: -14, y: -18.5, width: 28, height: 37)).fill()
        // Template images use alpha holes so highlights follow either menu-bar background.
        context.setBlendMode(.clear)
        NSBezierPath(ovalIn: NSRect(x: 3, y: -12.5 + (state == .dayOff ? 15 : 0), width: 6, height: 7)).fill()
        NSGraphicsContext.restoreGraphicsState()
        if state == .dayOff {
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: center - 17, y: 54))
            lid.line(to: NSPoint(x: center + 17, y: 54))
            lid.lineWidth = 3.5
            lid.lineCapStyle = .round
            lid.stroke()
        } else if state == .regular {
            let brow = NSBezierPath()
            let left = center < 72
            brow.move(to: NSPoint(x: center - 16, y: left ? 29 : 34))
            brow.curve(to: NSPoint(x: center + 16, y: left ? 34 : 29),
                       controlPoint1: NSPoint(x: center - 5, y: 29), controlPoint2: NSPoint(x: center + 5, y: 30))
            brow.lineWidth = 3
            brow.lineCapStyle = .round
            brow.stroke()
        }
    }

    private static func drawBeak(_ state: LuluDisplayState) {
        let beak = NSBezierPath()
        if state == .annualLeave {
            beak.move(to: NSPoint(x: 72, y: 88))
            beak.curve(to: NSPoint(x: 62, y: 75), controlPoint1: NSPoint(x: 68, y: 86), controlPoint2: NSPoint(x: 58, y: 78))
            beak.curve(to: NSPoint(x: 72, y: 77), controlPoint1: NSPoint(x: 65, y: 69), controlPoint2: NSPoint(x: 70, y: 72))
            beak.curve(to: NSPoint(x: 82, y: 75), controlPoint1: NSPoint(x: 74, y: 72), controlPoint2: NSPoint(x: 79, y: 69))
            beak.curve(to: NSPoint(x: 72, y: 88), controlPoint1: NSPoint(x: 86, y: 78), controlPoint2: NSPoint(x: 76, y: 86))
            beak.close()
            beak.fill()
        } else {
            let bottom: CGFloat = state == .luluDay ? 91 : 86
            beak.move(to: NSPoint(x: 64, y: 74))
            beak.curve(to: NSPoint(x: 80, y: 74), controlPoint1: NSPoint(x: 68, y: 69), controlPoint2: NSPoint(x: 76, y: 69))
            beak.curve(to: NSPoint(x: 72, y: bottom), controlPoint1: NSPoint(x: 79, y: 79), controlPoint2: NSPoint(x: 75, y: bottom - 3))
            beak.curve(to: NSPoint(x: 64, y: 74), controlPoint1: NSPoint(x: 69, y: bottom - 3), controlPoint2: NSPoint(x: 65, y: 79))
            beak.close()
            beak.lineWidth = state == .luluDay ? 4.5 : 3.5
            beak.lineJoinStyle = .round
            beak.stroke()
        }
    }
}
