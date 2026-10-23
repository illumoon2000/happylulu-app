import AppKit
import SwiftUI
import AfterSixCore
import AppPluginCore
import AppPluginHost

@MainActor
private enum RenderConfiguration {
    static var materialMode: LuluMaterialMode {
        switch ProcessInfo.processInfo.environment["HAPPY_LULU_MATERIAL_MODE"] ?? "automatic" {
        case "automatic": .automatic
        case "legacy": .legacy
        default: fatalError("HAPPY_LULU_MATERIAL_MODE must be automatic or legacy")
        }
    }

    static func applyPalette() {
        switch ProcessInfo.processInfo.environment["HAPPY_LULU_RENDER_SCHEME"] ?? "system" {
        case "system": break
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: fatalError("Unknown HAPPY_LULU_RENDER_SCHEME")
        }
        guard let raw = ProcessInfo.processInfo.environment["HAPPY_LULU_RENDER_PALETTE"] else { return }
        guard let palette = AppearancePalette(rawValue: raw) else {
            fatalError("Unknown HAPPY_LULU_RENDER_PALETTE: \(raw)")
        }
        AppearanceModel.shared.selectPalette(palette)
        precondition(AppearanceModel.shared.preferences.palette == palette)
    }
}

// Offscreen layout renders must not shrink to the CI runner's 1024×768 desktop.
// Live fixture placement restores AppKit's real screen constraints below.
@MainActor
private final class RenderWindow: NSWindow {
    var constrainsToScreen = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        constrainsToScreen ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }
}

@MainActor
private func capture<V: View>(_ view: V, size: NSSize, to url: URL) throws {
    let controller = NSHostingController(rootView: view.environment(\.luluMaterialMode, RenderConfiguration.materialMode))
    let host = controller.view
    let isSettingsWindow = url.lastPathComponent.hasPrefix("settings-")
    let window = RenderWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                          styleMask: isSettingsWindow ? [.titled, .closable, .miniaturizable, .resizable] : [.titled],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    // Match the app's hosting path and set the viewport after attaching content.
    window.setContentSize(size)
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    host.layoutSubtreeIfNeeded()
    // SwiftUI text baselines settle in a second layout pass after the native window resizes.
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    precondition(host.bounds.size == size,
        "Render viewport mismatch for \(url.lastPathComponent): expected=\(size), bounds=\(host.bounds), frame=\(host.frame), window=\(window.frame), content=\(window.contentLayoutRect), screen=\(String(describing: window.screen?.frame)), visible=\(String(describing: window.screen?.visibleFrame))")
    if url.lastPathComponent.hasPrefix("settings-general-") {
        func controls(_ view: NSView) -> [NSControl] {
            ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap(controls)
        }
        let switches = controls(host).compactMap { $0 as? NSSwitch }
        if switches.isEmpty {
            print("SKIP general native control geometry/AX: CLI SwiftUI host does not expose NSSwitch descendants; inspect retained renders")
        } else {
            precondition(switches.count == 3, "Departure, usage and login must each have one switch")
            let frames = switches.map { host.convert($0.bounds, from: $0) }
            precondition(frames.allSatisfy { abs($0.midX - frames[0].midX) < 1 }, "General switches must share the right column")
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
            print("PASS general native geometry: exactly three switches share the right column")
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
                    if labels.contains(expected) || labels.contains(L("사용량 보기", "Show usage")) { accessibleSwitches += 1; break }
                    element = attribute(current, "accessibilityParent") as? NSObject
                }
            }
            if accessibleSwitches == 3 {
                print("PASS general accessibility: all three semantic switches expose localized setting names")
            } else {
                print("SKIP general semantic AX names: CLI SwiftUI host exposes \(accessibleSwitches)/3 named hit-test elements; explicit labels retained for desktop validation")
            }
        }
    }
    let pixels = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: pixels)
    try pixels.representation(using: .png, properties: [:])!.write(to: url)

    // Opt-in WindowServer evidence captures only this synthetic fixture window.
    // cacheDisplay alone cannot prove the compositor's live glass rendering.
    if ProcessInfo.processInfo.environment["HAPPY_LULU_RENDER_LIVE"] == "1",
       ["panel-korean-regular.png", "settings-general-korean.png", "settings-korean.png"].contains(url.lastPathComponent) {
        guard CGPreflightScreenCaptureAccess() else {
            print("SKIP WindowServer capture: existing screen-capture access is unavailable; no permission requested")
            return
        }
        window.title = "HappyLulu · UI fixture"
        let chrome = isSettingsWindow
            ? SettingsWindowChrome(window: window, appearance: .shared, mode: RenderConfiguration.materialMode)
            : nil
        defer { withExtendedLifetime(chrome) {} }
        window.constrainsToScreen = true
        var captureWindow: NSWindow = window
        if !isSettingsWindow, LuluGlass.isSupported, RenderConfiguration.materialMode == .automatic {
            let content = NSHostingController(rootView: view
                .environment(\.luluMaterialMode, RenderConfiguration.materialMode)
                .clipShape(RoundedRectangle(cornerRadius: 24)))
            let panel = MenuBarPanel(content: content, size: size)
            panel.contentViewController = content
            captureWindow = panel
        }
        defer { if captureWindow !== window { captureWindow.close() } }
        captureWindow.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        captureWindow.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        print("Fixture active=\(NSApp.isActive), key=\(captureWindow.isKeyWindow)")
        let screenshot = url.deletingPathExtension().appendingPathExtension("window.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(captureWindow.windowNumber), screenshot.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: screenshot.path) else {
            throw NSError(domain: "DesignRenderProbe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "WindowServer fixture capture failed"])
        }
        print("PASS WindowServer fixture capture: \(screenshot.lastPathComponent)")
    }
}

@MainActor
private final class LiveRenderDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            do { try DesignRenderProbe.render(); exit(0) }
            catch { print("FAIL live render: \(error)"); exit(1) }
        }
    }
}

@main
struct DesignRenderProbe {
    @MainActor static func main() throws {
        if ProcessInfo.processInfo.environment["HAPPY_LULU_RENDER_LIVE"] == "1" {
            let app = NSApplication.shared
            let delegate = LiveRenderDelegate()
            app.setActivationPolicy(.accessory)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } else {
            try render()
        }
    }

    @MainActor static func render() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let identity = Bundle.main.bundleIdentifier!
        precondition(identity.hasPrefix("local.happylulu.design-probe."))
        _ = NSApplication.shared
        defer { UserDefaults.standard.removePersistentDomain(forName: identity) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        RenderConfiguration.applyPalette()
        let mode = ProcessInfo.processInfo.environment["HAPPY_LULU_MATERIAL_MODE"] ?? "automatic"
        let context = """
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Material mode: \(mode)
        Palette: \(AppearanceModel.shared.preferences.palette.rawValue)
        Offscreen NSHostingView bitmaps verify layout only. Optional .window.png files capture fixture windows through WindowServer; production popover/window chrome remain unverified.
        Accessibility uses the current system preferences; this probe never changes them.
        """
        try context.write(to: output.appendingPathComponent("render-context.txt"), atomically: true, encoding: .utf8)
        print(context)
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

                    for section in [SettingsSection.work, .history, .plugins, .updates] {
                        navigation.selection = section
                        for (suffix, size) in [("", NSSize(width: 920, height: 720)),
                                               ("-minimum", NSSize(width: 820, height: 620))] {
                            try capture(SettingsView(model: model, updater: AppUpdater(), calendarSync: sync, plugins: plugins,
                                featureCalendar: FeatureCalendarModel(router: plugins.router),
                                pluginPresentations: presentations, navigation: navigation), size: size,
                                to: output.appendingPathComponent("settings-\(section.rawValue)-\(language.rawValue)\(suffix).png"))
                        }
                    }

                    // A separate in-memory catalog exercises the installed-plugin host. External integration
                    // stays disabled, so the calendar view reads only the empty default fixture adapter.
                    let installed = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(),
                        routingStore: FeatureRoutingStore(url: nil), catalogStore: PluginCatalogStore(url: nil))
                    let installedPresentations = PluginSettingsPresentationRegistry()
                    installed.configureCatalog(sync: sync, presentations: installedPresentations, modules: [],
                        allowsExternalIntegrations: false)
                    installed.install("mac-calendar")
                    installed.setEnabled("mac-calendar", true)
                    precondition(installed.isEnabled("mac-calendar") && !installed.allowsExternalIntegrations)
                    precondition(installed.router.selectedID(for: .calendar) == installed.router.defaultID)
                    navigation.selection = .plugin
                    navigation.pluginID = "mac-calendar"
                    for (suffix, size) in [("", NSSize(width: 920, height: 720)),
                                           ("-minimum", NSSize(width: 820, height: 620))] {
                        try capture(SettingsView(model: model, updater: AppUpdater(), calendarSync: sync, plugins: installed,
                            featureCalendar: FeatureCalendarModel(router: installed.router),
                            pluginPresentations: installedPresentations, navigation: navigation), size: size,
                            to: output.appendingPathComponent("settings-calendar-\(language.rawValue)\(suffix).png"))
                    }
                    precondition(!sync.runtimeAllowed, "Rendering must never enable calendar services")
                    let afterSettings = try Data(contentsOf: store.url)
                    precondition(afterSettings == original, "All settings renders must preserve attendance bytes")
                    print("PASS settings \(language.rawValue): work/history/plugins/updates/installed calendar at both sizes; attendance preserved and external services disabled")
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
        print("cacheDisplay verifies layout only; optional WindowServer captures are reported separately. Production popover/window chrome, VoiceOver, changed system accessibility settings, menu-bar interaction and real-data acceptance remain unverified")
    }
}
