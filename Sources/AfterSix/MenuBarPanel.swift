import AppKit

/// Arrowless menu-bar presentation. The content and its editing state stay owned by the app.
@MainActor
final class MenuBarPanel: NSPanel, NSWindowDelegate {
    private let hostedContent: NSViewController
    private var panelSize: NSSize
    private weak var anchorButton: NSStatusBarButton?
    private var anchorRect = NSRect.zero
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var dismissing = false

    init(content: NSViewController, size: NSSize = NSSize(width: 364, height: 350)) {
        hostedContent = content
        panelSize = size
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        title = "happylulu"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(dismiss),
            name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dismiss),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(dismiss),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func frame(anchor: NSRect, visibleFrame: NSRect, size: NSSize) -> NSRect {
        let width = min(size.width, max(1, visibleFrame.width - 16))
        let height = min(size.height, max(1, visibleFrame.height - 14))
        let x = max(visibleFrame.minX + 8,
                    min(anchor.midX - width / 2, visibleFrame.maxX - width - 8))
        let top = min(anchor.minY, visibleFrame.maxY) - 6
        let y = max(visibleFrame.minY + 8, top - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let window = button.window, let screen = window.screen else { return }
        anchorButton = button
        anchorRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        contentViewController = hostedContent
        setFrame(Self.frame(anchor: anchorRect, visibleFrame: screen.visibleFrame, size: panelSize), display: true)
        makeKeyAndOrderFront(nil)
        startMonitoring()
    }

    func updateContentSize(_ size: NSSize) {
        guard size != panelSize else { return }
        panelSize = size
        if isVisible { reposition() }
        else { setContentSize(size) }
    }

    func reposition() {
        guard isVisible, let button = anchorButton, let window = button.window,
              let screen = window.screen else { return }
        anchorRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        setFrame(Self.frame(anchor: anchorRect, visibleFrame: screen.visibleFrame, size: panelSize), display: true)
    }

    @objc func dismiss() {
        guard isVisible, !dismissing else { return }
        dismissing = true
        // Deliver the real field-editor focus loss before removing the host so
        // PanelView's existing deferred save/onDisappear can preserve the draft.
        makeFirstResponder(nil)
        orderOut(nil)
        contentViewController = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        dismissing = false
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }
    func windowDidResignKey(_ notification: Notification) { dismiss() }
    override func close() { dismiss(); super.close() }

    private func startMonitoring() {
        guard localMonitor == nil, globalMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, self.isVisible, event.window !== self else { return event }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            // Status-item actions arrive on mouse-up. Let togglePanel handle this
            // click so mouse-down dismissal cannot immediately reopen the panel.
            if !self.anchorRect.contains(point) { self.dismiss() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.dismiss()
        }
    }
}
