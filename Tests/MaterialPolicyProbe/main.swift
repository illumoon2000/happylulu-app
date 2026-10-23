import AppKit
import SwiftUI

@MainActor
private final class Observation {
    var result: (enabled: Bool, reduceMotion: Bool, reduceTransparency: Bool, increasedContrast: Bool, nativeReduceMotion: Bool)?
}

@MainActor
private struct PolicyView: View {
    private var glass = LuluGlass()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let observation: Observation

    init(observation: Observation) {
        self.observation = observation
    }

    var body: some View {
        Text("Isolated material policy fixture")
            .frame(width: 260, height: 70)
            .onAppear {
                observation.result = (glass.isEnabled, glass.reduceMotion, reduceTransparency,
                                      contrast == .increased, reduceMotion)
            }
    }
}

@MainActor
private struct ModeFixture: View {
    let mode: LuluMaterialMode?
    let observation: Observation

    var body: some View {
        if let mode {
            PolicyView(observation: observation).environment(\.luluMaterialMode, mode)
        } else {
            PolicyView(observation: observation)
        }
    }
}

@main
struct MaterialPolicyProbe {
    @MainActor static func main() {
        // An explicit truth table checks the production policy without copying its boolean expression.
        let supportedCases: [(LuluMaterialMode, Bool, Bool, Bool)] = [
            (.automatic, false, false, true),
            (.automatic, true, false, false),
            (.automatic, false, true, false),
            (.automatic, true, true, false),
            (.legacy, false, false, false),
            (.legacy, true, false, false),
            (.legacy, false, true, false),
            (.legacy, true, true, false)
        ]
        for (mode, reduced, contrast, expected) in supportedCases {
            precondition(LuluGlass.shouldEnable(isSupported: true, mode: mode,
                reduceTransparency: reduced, increasedContrast: contrast) == expected,
                "Supported material policy failed for \(mode), reduced=\(reduced), contrast=\(contrast)")
            precondition(!LuluGlass.shouldEnable(isSupported: false, mode: mode,
                reduceTransparency: reduced, increasedContrast: contrast),
                "Unsupported systems must always retain the legacy appearance")
        }
        print("PASS material policy: 16 supported/unsupported, automatic/legacy, reduced-transparency and increased-contrast cases")

        _ = NSApplication.shared
        for (label, mode) in [("default", Optional<LuluMaterialMode>.none),
                              ("automatic", .some(.automatic)), ("legacy", .some(.legacy))] {
            let observation = Observation()
            let host = NSHostingView(rootView: ModeFixture(mode: mode, observation: observation))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 260, height: 70),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            host.layoutSubtreeIfNeeded()
            guard let result = observation.result else {
                fatalError("Hosted DynamicProperty did not appear for \(label)")
            }
            let expected = LuluGlass.shouldEnable(isSupported: LuluGlass.isSupported, mode: mode ?? .automatic,
                reduceTransparency: result.reduceTransparency, increasedContrast: result.increasedContrast)
            precondition(result.enabled == expected, "Hosted environment did not reach LuluGlass for \(label)")
            precondition(result.reduceMotion == result.nativeReduceMotion, "Reduce Motion must reach LuluGlass unchanged")
            print("PASS hosted \(label): enabled=\(result.enabled), support=\(LuluGlass.isSupported), reduceTransparency=\(result.reduceTransparency), increasedContrast=\(result.increasedContrast), reduceMotion=\(result.reduceMotion)")
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        print("System accessibility preferences were read, never changed; alternate accessibility rendering and actual unsupported-OS execution remain unverified")
    }
}
