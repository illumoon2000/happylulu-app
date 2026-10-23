import AppKit
import Combine
import SwiftUI

/// Allows isolated previews and checks to retain the original appearance.
enum LuluMaterialMode: Sendable {
    case automatic
    case legacy
}

private struct LuluMaterialModeKey: EnvironmentKey {
    static let defaultValue: LuluMaterialMode = .automatic
}

extension EnvironmentValues {
    var luluMaterialMode: LuluMaterialMode {
        get { self[LuluMaterialModeKey.self] }
        set { self[LuluMaterialModeKey.self] = newValue }
    }
}

/// Centralizes native support and current accessibility preferences.
struct LuluGlass: DynamicProperty {
    @Environment(\.luluMaterialMode) private var mode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    static var isSupported: Bool {
        // Xcode 26 introduced these APIs. Keep older Command Line Tools buildable.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    static func shouldEnable(isSupported: Bool, mode: LuluMaterialMode,
                             reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        isSupported && mode == .automatic && !reduceTransparency && !increasedContrast
    }

    var isEnabled: Bool {
        Self.shouldEnable(isSupported: Self.isSupported, mode: mode,
                          reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
    }

    var reduceMotion: Bool { accessibilityReduceMotion }
}

extension View {
    func luluWindowColorScheme(_ scheme: ColorScheme?) -> some View {
        modifier(LuluColorSchemeModifier(scheme: scheme))
    }

    func luluGlassSurface(tint: Color, fallback: Color, cornerRadius: CGFloat,
                          legacyCornerRadius: CGFloat? = nil, interactive: Bool = false,
                          usesSystemAppearance: Bool = false) -> some View {
        modifier(LuluGlassSurfaceModifier(tint: tint, fallback: fallback, cornerRadius: cornerRadius,
                                         legacyCornerRadius: legacyCornerRadius, interactive: interactive,
                                         usesSystemAppearance: usesSystemAppearance))
    }

    func luluGlassButton() -> some View {
        modifier(LuluGlassButtonModifier())
    }

    func luluGlassControls(usesSystemAppearance: Bool = false) -> some View {
        modifier(LuluGlassControlsModifier(usesSystemAppearance: usesSystemAppearance))
    }
}

private struct LuluGlassSurfaceModifier: ViewModifier {
    let tint: Color
    let fallback: Color
    let cornerRadius: CGFloat
    let legacyCornerRadius: CGFloat?
    let interactive: Bool
    let usesSystemAppearance: Bool
    private var glass = LuluGlass()

    init(tint: Color, fallback: Color, cornerRadius: CGFloat,
         legacyCornerRadius: CGFloat?, interactive: Bool, usesSystemAppearance: Bool) {
        self.tint = tint
        self.fallback = fallback
        self.cornerRadius = cornerRadius
        self.legacyCornerRadius = legacyCornerRadius
        self.interactive = interactive
        self.usesSystemAppearance = usesSystemAppearance
    }

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), glass.isEnabled {
            content.glassEffect(
                (usesSystemAppearance ? Glass.regular : Glass.regular.tint(tint.opacity(0.12)))
                    .interactive(interactive && !glass.reduceMotion),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
        } else {
            legacyBody(content)
        }
        #else
        legacyBody(content)
        #endif
    }

    private func legacyBody(_ content: Content) -> some View {
        content.background(fallback, in: RoundedRectangle(cornerRadius: legacyCornerRadius ?? cornerRadius))
    }
}

private struct LuluGlassButtonModifier: ViewModifier {
    private var glass = LuluGlass()

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), glass.isEnabled {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.borderless)
        }
        #else
        content.buttonStyle(.borderless)
        #endif
    }
}

private struct LuluGlassControlsModifier: ViewModifier {
    let usesSystemAppearance: Bool
    private var glass = LuluGlass()

    init(usesSystemAppearance: Bool) { self.usesSystemAppearance = usesSystemAppearance }

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if usesSystemAppearance {
            content.buttonStyle(.automatic)
        } else if #available(macOS 26.0, *), glass.isEnabled {
            content.buttonStyle(.glass)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// SwiftUI can retain a forced scheme after preferredColorScheme becomes nil.
/// Observe the application's system appearance, independently of any window's
/// theme, so the native theme follows live macOS changes through the same public
/// SwiftUI presentation API used by the existing themes.
@MainActor
private final class LuluSystemAppearance: ObservableObject {
    static let shared = LuluSystemAppearance()
    @Published private(set) var scheme: ColorScheme = .light
    private var observation: AnyCancellable?

    private init() {
        let app = NSApplication.shared
        scheme = Self.colorScheme(for: app.effectiveAppearance)
        observation = app.publisher(for: \.effectiveAppearance, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] appearance in
                let next = Self.colorScheme(for: appearance)
                if self?.scheme != next { self?.scheme = next }
            }
    }

    private static func colorScheme(for appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

private struct LuluColorSchemeModifier: ViewModifier {
    let scheme: ColorScheme?
    @ObservedObject private var system = LuluSystemAppearance.shared

    func body(content: Content) -> some View {
        content.preferredColorScheme(scheme ?? system.scheme)
    }
}
