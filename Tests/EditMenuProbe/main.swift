import AppKit
import SwiftUI
import DaouOfficePlugin
import AppPluginCore
import ObjectiveC

private struct FixtureSecrets: PluginSecretStore {
    func load(for key: String) throws -> String? { "fixture-password" }
    func save(_ password: String, for key: String) throws { fatalError("Unexpected credential write") }
    func remove(for key: String) throws { fatalError("Unexpected credential removal") }
}

private struct HeldTransport: DaouOfficeTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
    func cancel() {}
}

// Redirect the accessor only inside this test process, before app startup. Native
// SwiftUI editors and menu validation use the named fixture board; the original
// general-pasteboard getter is never called, read, saved or overwritten.
@MainActor
private final class PasteboardIsolation {
    let pasteboard = NSPasteboard.withUniqueName()
    private let method = class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general))!
    private let original: IMP
    private let replacement: IMP

    init() {
        original = method_getImplementation(method)
        let board = pasteboard
        let getter: @convention(block) (AnyObject) -> NSPasteboard = { _ in board }
        replacement = imp_implementationWithBlock(getter)
        method_setImplementation(method, replacement)
    }

    func restore() {
        method_setImplementation(method, original)
        imp_removeBlock(replacement)
        pasteboard.releaseGlobally()
    }
}

@MainActor
final class PasteProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var failures = [String]()

    private func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures.append(message) }
    }

    private func pump(_ host: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["HAPPY_LULU_EDIT_MENU_EVIDENCE"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func addressField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.isEditable && (field.accessibilityLabel() == "Company Daouoffice address"
                || field.stringValue == "https://fixture.daouoffice.com/") { return field }
        return view.subviews.lazy.compactMap { self.addressField(in: $0) }.first
    }

    private func secureField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        return view.subviews.lazy.compactMap { self.secureField(in: $0) }.first
    }

    private func commandItem(action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.action == action { return item }
            if let nested = commandItem(action: action, in: item.submenu) { return nested }
        }
        return nil
    }

    private func commandV() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9)!
        NSApp.sendEvent(event)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        perform(#selector(execute), with: nil, afterDelay: 0.1)
    }

    @objc private func execute() {
        do { try run() }
        catch { check(false, "fixture setup: \(error)") }
        window?.orderOut(nil)
        pasteboardIsolation.restore()
        print("LIMIT native editor uses a process-local named pasteboard substitute; original general clipboard and user credentials untouched; no physical keyboard")
        exit(failures.isEmpty ? 0 : 1)
    }

    private func run() throws {
        precondition(Bundle.main.bundleIdentifier!.hasPrefix("local.happylulu.edit-menu-probe."))
        defer { UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!) }
        let originalLanguage = AppLanguage.shared.choice
        for (language, title, paste) in [(LanguageChoice.korean, "편집", "붙여넣기"), (.english, "Edit", "Paste")] {
            AppLanguage.shared.select(language)
            let menu = makeApplicationMenu()
            check(menu.items.last?.submenu?.title == title
                && commandItem(action: #selector(NSText.paste(_:)), in: menu)?.title == paste,
                "standard menu localizes for \(language.rawValue)")
        }
        AppLanguage.shared.select(originalLanguage)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = DaouOfficeConfigurationStore(url: folder.appendingPathComponent("daouoffice.json"))
        let savedAddress = "https://fixture.daouoffice.com/"
        try store.save(DaouOfficeConfiguration(enabled: true, address: savedAddress, loginID: "fixture"))
        let original = try Data(contentsOf: store.url)
        let model = DaouOfficePluginModel(store: store, secrets: FixtureSecrets(),
            localize: { _, english in english },
            makeClient: { DaouOfficeAPIClient(configuration: $0, secrets: $1,
                transport: HeldTransport(), log: nil) })
        defer { model.stop() }
        let host = NSHostingView(rootView: DaouOfficePluginSettingsView(model: model, localize: { _, english in english })
            .padding().background(Color(nsColor: .windowBackgroundColor)))
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.setActivationPolicy(.regular)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
        pump(host)
        window.makeKey()
        // This contract still runs on CI hosts that cannot activate a foreground app.
        for (action, key, modifiers) in [
            ("undo:", "z", NSEvent.ModifierFlags.command),
            ("redo:", "z", NSEvent.ModifierFlags.command.union(.shift)),
            ("cut:", "x", .command), ("copy:", "c", .command),
            ("paste:", "v", .command), ("selectAll:", "a", .command)
        ] {
            let item = commandItem(action: NSSelectorFromString(action), in: NSApp.mainMenu)
            check(item?.keyEquivalent == key && item?.keyEquivalentModifierMask == modifiers && item?.target == nil,
                "production bootstrap registers \(action) with its standard shortcut and responder-chain target")
        }
        let deadline = Date().addingTimeInterval(2)
        while addressField(in: host) == nil && Date() < deadline { pump(host) }
        guard let field = addressField(in: host) else {
            check(false, "production company address TextField exists")
            try capture(host, name: "missing-address")
            return
        }
        check(field.isEnabled && field.isEditable, "idle address input is enabled and editable")
        window.makeFirstResponder(field)
        field.selectText(nil)
        pump(host)
        guard let editor = field.currentEditor() as? NSTextView else {
            check(false, "production TextField has a native field editor")
            return
        }
        let hasKeyWindow = window.isKeyWindow && NSApp.keyWindow === window && window.firstResponder === editor
        print("INFO fixture key window: local=\(window.isKeyWindow), application=\(NSApp.keyWindow === window), editor=\(window.firstResponder === editor)")
        if !hasKeyWindow {
            print("SKIP end-to-end Cmd+V and context-menu dispatch: this host cannot establish an active key window")
        }
        editor.selectAll(nil)
        editor.insertText("https://typed.example/", replacementRange: editor.selectedRange())
        pump(host)
        check(model.address == "https://typed.example/", "ordinary typing updates the production model")

        let pasted = "https://pasted.example/"
        pasteboardIsolation.pasteboard.setString(pasted, forType: .string)
        editor.selectAll(nil)
        if hasKeyWindow {
            commandV()
            pump(host)
            check(model.address == pasted, "Cmd+V reaches the focused editor and updates the company address")
        }
        // Characterize the native field independently; this does not prove keyboard routing.
        editor.selectAll(nil)
        editor.paste(nil)
        pump(host)
        check(model.address == pasted, "native paste updates the production company address binding")

        editor.selectAll(nil)
        editor.insertText("https://before-context.example/", replacementRange: editor.selectedRange())
        editor.selectAll(nil)
        let rightClick = NSEvent.mouseEvent(with: .rightMouseDown,
            location: editor.convert(NSPoint(x: 4, y: 4), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let contextMenu = editor.menu(for: rightClick)
        contextMenu?.update()
        if let item = commandItem(action: #selector(NSText.paste(_:)), in: contextMenu), let action = item.action {
            check(editor.validateUserInterfaceItem(item), "native context-menu Paste is valid for the editable address")
            if hasKeyWindow {
                let dispatched = NSApp.sendAction(action, to: item.target, from: item)
                pump(host)
                check(item.isEnabled && dispatched && model.address == pasted,
                    "enabled context-menu Paste reaches the editor independently of Cmd+V")
            } else {
                // Invoke the native editor action as a characterization, without changing the menu target.
                editor.paste(item)
                pump(host)
                check(model.address == pasted, "native context Paste action updates the binding (dispatch unverified)")
            }
        } else {
            check(false, "native field editor exposes a context-menu Paste command")
        }
        try capture(host, name: "company-address-paste")
        if let secure = secureField(in: host) {
            window.makeFirstResponder(secure)
            secure.selectText(nil)
            pump(host)
            if let secureEditor = secure.currentEditor() as? NSTextView {
                let secret = "fixture-secret-only"
                pasteboardIsolation.pasteboard.setString(secret, forType: .string)
                secureEditor.selectAll(nil)
                secureEditor.paste(nil)
                pump(host)
                check(model.password == secret && model.address == pasted,
                    "native secure-field paste updates only its production password binding")
                secureEditor.selectAll(nil)
                let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
                let cut = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
                check(!secureEditor.validateUserInterfaceItem(copy) && !secureEditor.validateUserInterfaceItem(cut),
                    "native secure editor disables Copy and Cut")
                if hasKeyWindow {
                    pasteboardIsolation.pasteboard.setString("fixture-key-paste", forType: .string)
                    commandV()
                    pump(host)
                    check(model.password == "fixture-key-paste" && model.address == pasted,
                        "Cmd+V targets the focused secure field only")
                }
            } else { check(false, "production SecureField has a native editor") }
        } else { check(false, "production password SecureField exists") }

        window.makeFirstResponder(nil)
        pump(host)
        let beforeUnfocused = model.address
        if hasKeyWindow {
            commandV()
            pump(host)
            check(model.address == beforeUnfocused, "Cmd+V without an active input leaves the address unchanged")
        }

        model.address = savedAddress
        // The secure-field probe leaves an unsaved password draft; refresh requires
        // the original saved connection, exactly as the production settings do.
        model.password = ""
        check(model.canRefresh, "restored saved fixture connection is eligible for refresh")
        model.refresh()
        pump(host)
        check(model.isRunning && !field.isEnabled, "address input is disabled during a fetch")
        if hasKeyWindow {
            window.makeFirstResponder(field)
            commandV()
            pump(host)
            check(model.address == savedAddress, "Cmd+V cannot edit the disabled address")
        }
        try capture(host, name: "company-address-disabled")
        check(try Data(contentsOf: store.url) == original, "editing does not save the connection")
    }
}

private let pasteboardIsolation = PasteboardIsolation()
