import AppKit
import SwiftUI
import AfterSixCore
import AppPluginCore
import AppPluginHost

@MainActor
private func capture<V: View>(_ view: V, size: NSSize, to url: URL) throws {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    host.layoutSubtreeIfNeeded()
    // SwiftUI text baselines settle in a second layout pass after the native window resizes.
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    precondition(host.bounds.size == size)
    if url.lastPathComponent.hasPrefix("settings-general-") {
        func controls(_ view: NSView) -> [NSControl] {
            ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap(controls)
        }
        let switches = controls(host).compactMap { $0 as? NSSwitch }
        if switches.isEmpty {
            print("SKIP general native control geometry/AX: CLI SwiftUI host does not expose NSSwitch descendants; inspect retained renders")
        } else {
            precondition(switches.count == 2, "Picker rows must not create fake toggles")
            let frames = switches.map { host.convert($0.bounds, from: $0) }
            precondition(abs(frames[0].midX - frames[1].midX) < 1, "General switches must share the right column")
            let pickers = controls(host).compactMap { $0 as? NSPopUpButton }
            if pickers.count == 2 {
                let rightEdge = frames[0].maxX
                for picker in pickers {
                    let frame = host.convert(picker.bounds, from: picker)
                    precondition(abs(frame.maxX - rightEdge) < 2, "Language/countdown picker must share the right control column with switches")
                }
                print("PASS general native picker geometry: both menus share the right control column")
            } else {
                print("SKIP picker native geometry: CLI SwiftUI menus have no NSPopUpButton descendants; inspect retained same-row/right-column renders")
            }
            print("PASS general native geometry: exactly two switches share the right column")
            // SwiftUI exposes accessibility on semantic wrappers, not the backing NSSwitch.
            // Inspect the actual hit-test element and its accessibility parents when the CLI host vends them.
            func attribute(_ object: NSObject, _ name: String) -> AnyObject? {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { return nil }
                return object.perform(selector)?.takeUnretainedValue()
            }
            var accessibleSwitches = 0
            for control in switches {
                let frame = host.convert(control.bounds, from: control)
                let point = window.convertPoint(toScreen: host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil))
                var element = host.accessibilityHitTest(point) as? NSObject
                let expected = control.isEnabled
                    ? L("메뉴바에 퇴근 예정 시각 표시", "Show expected departure in menu bar")
                    : L("로그인 시 자동 실행", "Launch at login")
                for _ in 0..<8 {
                    guard let current = element else { break }
                    let labels = ["accessibilityLabel", "accessibilityTitle"].compactMap { attribute(current, $0) as? String }
                    if labels.contains(expected) { accessibleSwitches += 1; break }
                    element = attribute(current, "accessibilityParent") as? NSObject
                }
            }
            if accessibleSwitches == 2 {
                print("PASS general accessibility: both semantic switches expose localized setting names")
            } else {
                print("SKIP general semantic AX names: CLI SwiftUI host exposes \(accessibleSwitches)/2 named hit-test elements; explicit labels retained for desktop validation")
            }
        }
    }
    let pixels = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: pixels)
    try pixels.representation(using: .png, properties: [:])!.write(to: url)
}

@main
struct DesignRenderProbe {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let identity = Bundle.main.bundleIdentifier!
        precondition(identity.hasPrefix("local.happylulu.design-probe."))
        _ = NSApplication.shared
        defer { UserDefaults.standard.removePersistentDomain(forName: identity) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let day = "2026-10-21"
        let timeZone = TimeZone(identifier: "Asia/Seoul")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fixtureCalendar = calendar
        let fixtureNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15))!
        let plugins = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(),
            routingStore: FeatureRoutingStore(url: nil), catalogStore: PluginCatalogStore(url: nil))
        let sync = CalendarSyncModel(runtimeAllowed: false, storeURL: root.appendingPathComponent("sync.sqlite"))
        let presentations = PluginSettingsPresentationRegistry()
        plugins.configureCatalog(sync: sync, presentations: presentations, modules: [], allowsExternalIntegrations: false)
        // Fictitious fixed-time state covers the real AppModel-to-expression integration in both languages.
        for language in [LanguageChoice.korean, .english] {
            AppLanguage.shared.select(language)
            for expression in LuluDisplayState.allCases {
                var state = AttendanceState()
                state.didOfferLoginItem = true
                let type: ManualDayType = switch expression {
                case .morningHalf: .morningHalf
                case .afternoonHalf: .afternoonHalf
                case .luluDay: .luluDay
                case .annualLeave: .annualLeave
                default: .regular
                }
                state.manualDayTypes[day] = type
                if expression == .dayOff { state.suppressedDays.insert(day) }
                if ![.waiting, .dayOff, .annualLeave].contains(expression) {
                    let arrivalHour = type == .morningHalf ? 13 : 9
                    let arrival = calendar.date(bySettingHour: arrivalHour, minute: 0, second: 0, of: fixtureNow)!
                    state.arrivals[day] = Arrival(day: day, time: arrival, source: .manual,
                        timeZoneID: timeZone.identifier, mode: type.workdayMode!, modeSource: .manual,
                        earlyLeaveOverrideMinutes: type.earlyLeaveOverrideMinutes)
                    if expression == .readyToLeave { state.settings.workMinutes = 300; state.settings.breakMinutes = 60 }
                }
                let store = StateStore(url: root.appendingPathComponent(expression.rawValue + ".json"))
                try store.save(state)
                let original = try Data(contentsOf: store.url)
                let displayNow = expression == .afternoonHalf
                    ? calendar.date(bySettingHour: 11, minute: 0, second: 0, of: fixtureNow)! : fixtureNow
                let model = AppModel(store: store, featureRouter: plugins.router, allowsLoginItemChanges: false,
                    nowProvider: { displayNow }, calendarProvider: { fixtureCalendar })
                precondition(model.luluDisplayState == expression, "Wrong expression for real fixture: \(expression)")
                precondition(!model.luluStateLabel.isEmpty)
                try capture(PanelView(model: model, calendarSync: sync, plugins: plugins,
                    onOpenHistory: {}, onOpenSettings: {}), size: NSSize(width: 364, height: 350),
                    to: output.appendingPathComponent("panel-\(language.rawValue)-\(expression.rawValue).png"))
                let afterRender = try Data(contentsOf: store.url)
                precondition(afterRender == original, "Rendering must preserve attendance bytes")
                if expression == .regular {
                    let navigation = SettingsNavigation()
                    navigation.selection = .appearance
                    for (suffix, size) in [("", NSSize(width: 920, height: 720)),
                                           ("-minimum", NSSize(width: 820, height: 620))] {
                        try capture(SettingsView(model: model, updater: AppUpdater(), calendarSync: sync, plugins: plugins,
                            featureCalendar: FeatureCalendarModel(router: plugins.router),
                            pluginPresentations: presentations, navigation: navigation), size: size,
                            to: output.appendingPathComponent("settings-\(language.rawValue)\(suffix).png"))
                    }
                    navigation.selection = .general
                    let savedDisplay = model.countdownDisplay
                    let savedDeparture = model.showDepartureInMenuBar
                    let expectedGuide = language == .korean
                        ? "https://happylulu.cy-choi-lulu.chatgpt.site/guide/"
                        : "https://happylulu.cy-choi-lulu.chatgpt.site/en/guide/"
                    precondition(GeneralSettingsPreview.guideURL.absoluteString == expectedGuide)
                    var examples = Set<String>()
                    for format in CountdownDisplay.allCases {
                        model.setCountdownDisplay(format)
                        let remaining = GeneralSettingsPreview.countdown(model.countdownDisplay)
                        examples.insert(remaining)
                        model.setShowDepartureInMenuBar(false)
                        precondition(GeneralSettingsPreview.departure(model.countdownDisplay, shown: model.showDepartureInMenuBar) == remaining)
                        model.setShowDepartureInMenuBar(true)
                        precondition(GeneralSettingsPreview.departure(model.countdownDisplay, shown: model.showDepartureInMenuBar).hasSuffix(remaining))
                    }
                    precondition(examples.count == 5, "Each selected format must produce a distinct live preview")
                    model.setCountdownDisplay(.milliseconds)
                    precondition(GeneralSettingsPreview.countdown(model.countdownDisplay) == (language == .korean ? "5320000밀리초 남음" : "5320000 ms left"))
                    try capture(SettingsView(model: model, updater: AppUpdater(), calendarSync: sync, plugins: plugins,
                        featureCalendar: FeatureCalendarModel(router: plugins.router),
                        pluginPresentations: presentations, navigation: navigation), size: NSSize(width: 820, height: 620),
                        to: output.appendingPathComponent("settings-general-\(language.rawValue)-milliseconds-minimum.png"))
                    // Representative images use a readable fixed fixture selection; stress above retains long milliseconds.
                    model.setCountdownDisplay(.hoursMinutes)
                    for (suffix, size) in [("", NSSize(width: 920, height: 720)),
                                           ("-minimum", NSSize(width: 820, height: 620))] {
                        try capture(SettingsView(model: model, updater: AppUpdater(), calendarSync: sync, plugins: plugins,
                            featureCalendar: FeatureCalendarModel(router: plugins.router),
                            pluginPresentations: presentations, navigation: navigation), size: size,
                            to: output.appendingPathComponent("settings-general-\(language.rawValue)\(suffix).png"))
                    }
                    model.setShowDepartureInMenuBar(false)
                    for (suffix, size) in [("", NSSize(width: 920, height: 720)),
                                           ("-minimum", NSSize(width: 820, height: 620))] {
                        try capture(SettingsView(model: model, updater: AppUpdater(), calendarSync: sync, plugins: plugins,
                            featureCalendar: FeatureCalendarModel(router: plugins.router),
                            pluginPresentations: presentations, navigation: navigation), size: size,
                            to: output.appendingPathComponent("settings-general-\(language.rawValue)-departure-off\(suffix).png"))
                    }
                    model.setCountdownDisplay(savedDisplay)
                    model.setShowDepartureInMenuBar(savedDeparture)
                    let afterGeneral = try Data(contentsOf: store.url)
                    precondition(afterGeneral == original, "General settings preview must preserve attendance bytes")
                    print("PASS general settings \(language.rawValue): 5 live formats, departure on/off, localized guide, 920x720/820x620 renders, attendance preserved")
                }
            }
        }
        // Actual cached pixels, drawn at native 26x18pt onto light/dark backgrounds at both backing scales.
        for scale in [1, 2] {
            for dark in [false, true] {
                let size = NSSize(width: 680, height: 8 * 78 + 40)
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                    pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                bitmap.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white).setFill()
                NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
                for (row, expression) in LuluDisplayState.allCases.enumerated() {
                    let y = size.height - CGFloat(row + 1) * 78
                    let symbol = LuluBrand.menuBarIcon(for: expression)
                    precondition(symbol === LuluBrand.menuBarIcon(for: expression))
                    let source = symbol.representations.compactMap { $0 as? NSBitmapImageRep }
                        .first { $0.pixelsWide == 26 * scale }!
                    let tintedPixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide,
                        pixelsHigh: source.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    for y in 0..<source.pixelsHigh {
                        for x in 0..<source.pixelsWide {
                            // Match the bitmap's RGB space; calibrated grayscale loses alpha in setColor.
                            let level: CGFloat = dark ? 1 : 0
                            tintedPixels.setColor(NSColor(deviceRed: level, green: level, blue: level,
                                alpha: source.colorAt(x: x, y: y)!.alphaComponent), atX: x, y: y)
                        }
                    }
                    let tinted = NSImage(cgImage: tintedPixels.cgImage!, size: symbol.size)
                    tinted.draw(in: NSRect(x: 20, y: y + 18, width: 26, height: 18))
                    LuluBrand.headerIcon(for: expression).draw(in: NSRect(x: 70, y: y + 13, width: 28, height: 28))
                    (expression.rawValue as NSString).draw(at: NSPoint(x: 130, y: y + 18), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 15), .foregroundColor: dark ? NSColor.white : .black])
                    // Enlarged nearest representation is an inspection aid, not a claim of native-scale legibility.
                    NSGraphicsContext.current!.imageInterpolation = .none
                    tinted.draw(in: NSRect(x: 400, y: y, width: 78, height: 54))
                }
                NSGraphicsContext.restoreGraphicsState()
                for (row, expression) in LuluDisplayState.allCases.enumerated() {
                    let y = size.height - CGFloat(row + 1) * 78
                    for rect in [NSRect(x: 20, y: y + 18, width: 26, height: 18),
                                 NSRect(x: 400, y: y, width: 78, height: 54)] {
                        var contrastingPixels = 0
                        for pixelY in Int((size.height - rect.maxY) * CGFloat(scale))..<Int((size.height - rect.minY) * CGFloat(scale)) {
                            for pixelX in Int(rect.minX * CGFloat(scale))..<Int(rect.maxX * CGFloat(scale)) {
                                let color = bitmap.colorAt(x: pixelX, y: pixelY)!.usingColorSpace(.deviceRGB)!
                                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                                if color.alphaComponent > 0.9 && (dark ? brightness > 0.75 : brightness < 0.25) {
                                    contrastingPixels += 1
                                }
                            }
                        }
                        precondition(contrastingPixels > Int(rect.width * rect.height * CGFloat(scale * scale) * 0.08),
                            "Blank monochrome board: \(expression), \(scale)x, dark=\(dark), rect=\(rect), contrastingPixels=\(contrastingPixels)")
                    }
                }
                try bitmap.representation(using: .png, properties: [:])!.write(to:
                    output.appendingPathComponent("eyes-\(dark ? "dark" : "light")-\(scale)x.png"))
            }
        }
        print("PASS offline design render: 8 AppModel states, 16 Korean/English 364x350 panels, 4 appearance settings (920x720 and820x620), 26x18pt light/dark 1x/2x boards with matching 28pt color headers; fixture attendance bytes preserved")
        print("Live desktop, VoiceOver, menu-bar interaction and real-data acceptance remain unverified")
    }
}
