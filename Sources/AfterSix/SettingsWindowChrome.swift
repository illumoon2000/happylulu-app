import AppKit
import Combine

/// Keeps native window controls above the content while sharing its theme background.
@MainActor
final class SettingsWindowChrome {
    private var appearanceObservation: AnyCancellable?

    init(window: NSWindow, appearance: AppearanceModel, mode: LuluMaterialMode = .automatic) {
        guard LuluGlass.isSupported, mode == .automatic else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        // Keep window.title for accessibility and the Window menu. AppKit owns the
        // traffic lights, titlebar dragging and the content layout safe area.
        appearanceObservation = appearance.$preferences.sink { [weak window] preferences in
            window?.backgroundColor = preferences.palette == .nativeGlass
                ? .windowBackgroundColor : AppearanceModel.nsColor(preferences.colors[.background]!)
        }
    }
}
