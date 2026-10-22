import Foundation
import Combine
import AppKit
import SwiftUI
import CPURunnerIntegration

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { print("FAIL \(message)"); exit(1) }
}

@MainActor
func checkCPUUsage() {
    var values: [CPUUsageTicks?] = [
        .init(user: 100, system: 100, nice: 0, idle: 800),
        .init(user: 150, system: 150, nice: 0, idle: 900),
        .init(user: 150, system: 150, nice: 0, idle: 900),
        .init(user: 5, system: 5, nice: 0, idle: 10),
        .init(user: 10, system: 10, nice: 0, idle: 20),
        nil,
        .init(user: 500, system: 500, nice: 0, idle: 1000),
        .init(user: 500, system: 500, nice: 0, idle: 1100)
    ]
    let sampler = CPUUsageSampler(readTicks: { values.removeFirst() })
    require(sampler.sample() == nil, "first CPU sample must establish a baseline")
    require(sampler.sample() == 0.5, "CPU must use elapsed deltas, not lifetime totals")
    require(sampler.sample() == nil, "zero total delta must be unavailable")
    require(sampler.sample() == nil, "counter reset must establish a fresh baseline")
    require(sampler.sample() == 0.5, "counter reset did not recover")
    require(sampler.sample() == nil, "failed reads must be unavailable")
    require(sampler.sample() == nil, "read recovery must not include an unknown time interval")
    require(sampler.sample() == 0, "measured zero usage was lost")
    sampler.reset()
    values = [.init(user: 1, system: 1, nice: 1, idle: 1), .init(user: 1, system: 1, nice: 2, idle: 1)]
    require(sampler.sample() == nil && sampler.sample() == 1, "reset or nice CPU time was lost")
    require(RunnerAnimationPolicy.frameInterval(usage: 0, reduceMotion: false, lowPower: false) == 0.5, "idle rate is not 2 fps")
    require(RunnerAnimationPolicy.frameInterval(usage: 1, reduceMotion: false, lowPower: false) == 0.0625, "busy rate exceeds 16 fps")
    require(RunnerAnimationPolicy.frameInterval(usage: 1, reduceMotion: false, lowPower: true) == 0.25, "low power rate exceeds 4 fps")
    for value in [Double?.none, .some(.nan), .some(.infinity), .some(-0.1), .some(1.1)] {
        require(RunnerAnimationPolicy.frameInterval(usage: value, reduceMotion: false, lowPower: false) == nil, "invalid CPU value animated")
    }
    require(RunnerAnimationPolicy.frameInterval(usage: 0.5, reduceMotion: true, lowPower: false) == nil, "Reduce Motion did not stop animation")
    print("PASS CPU: elapsed deltas, first/zero/reset/failed samples, recovery, nice time and animation bounds")
}

@MainActor
func checkSettings() {
    let name = "happylulu-runner-check-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = RunnerSettings(defaults: defaults)
    require(settings.animal == .hamster, "default animal changed")
    require(defaults.object(forKey: RunnerSettings.animalKey) == nil, "reading defaults wrote a preference")
    defaults.set("future-animal", forKey: RunnerSettings.animalKey)
    require(settings.animal == .hamster, "unknown animal must safely fall back")
    require(defaults.string(forKey: RunnerSettings.animalKey) == "future-animal", "unknown saved preference was overwritten")
    for animal in RunnerAnimal.allCases {
        settings.animal = animal
        require(RunnerSettings(defaults: defaults).animal == animal, "animal selection did not survive a new settings instance")
    }
    print("PASS settings: all three choices persist, absent/unknown settings remain preserved")
}

@MainActor
final class FixtureTimer: RunnerScheduledTask {
    let interval: TimeInterval
    let action: @MainActor () -> Void
    var cancelled = false
    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) { self.interval = interval; self.action = action }
    func cancel() { cancelled = true }
    func fireEvenIfCancelled() { action() }
}

@MainActor
final class FixtureDisplay: RunnerStatusDisplaying {
    var frames: [Int] = []
    var animals: [RunnerAnimal] = []
    var labels: [String] = []
    var removals = 0
    func render(animal: RunnerAnimal, frame: Int, usageText: String, accessibilityLabel: String) {
        frames.append(frame); animals.append(animal); labels.append(accessibilityLabel)
    }
    func remove() { removals += 1 }
}

@MainActor
final class FixtureMotionPreferences {
    var reduceMotion = false
    var lowPower = false
}

@MainActor
func checkLifecycle() {
    let name = "happylulu-runner-lifecycle-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    var ticks = CPUUsageTicks(user: 100, system: 100, nice: 0, idle: 800)
    var readFails = false, reads = 0
    let motion = FixtureMotionPreferences()
    var timers: [FixtureTimer] = [], displays: [FixtureDisplay] = []
    let controller = CPURunnerController(settings: RunnerSettings(defaults: defaults),
        sampler: CPUUsageSampler(readTicks: { reads += 1; return readFails ? nil : ticks }),
        displayFactory: { _ in let value = FixtureDisplay(); displays.append(value); return value },
        schedule: { interval, action in
            let timer = FixtureTimer(interval: interval, action: action); timers.append(timer); return timer
        }, reduceMotion: { motion.reduceMotion }, lowPower: { motion.lowPower }, observeSystemChanges: false)
    controller.start()
    require(displays.isEmpty && timers.isEmpty && reads == 0, "disabled plugin created runtime resources")
    controller.setModuleEnabled(true); controller.start(); controller.start()
    require(displays.count == 1 && timers.count == 1 && reads == 1, "start is not idempotent")
    require(controller.isActive && !controller.isRunning, "ongoing monitoring must not block app updates")
    let sample = timers[0]
    ticks = .init(user: 150, system: 150, nice: 0, idle: 900); sample.fireEvenIfCancelled()
    require(controller.usage == 0.5 && timers.count == 2, "sample did not start CPU animation")
    let animation = timers[1], display = displays[0]
    var changes = 0
    let subscription = controller.changes.sink { changes += 1 }
    for _ in 0..<RunnerArtwork.frameCount { animation.fireEvenIfCancelled() }
    require(Set(display.frames.suffix(RunnerArtwork.frameCount)).count == RunnerArtwork.frameCount, "animation did not cycle all frames")
    require(changes == 0, "animation frames published whole-app settings changes")
    for animal in RunnerAnimal.allCases {
        controller.selectAnimal(animal)
        require(controller.animal == animal && display.animals.last == animal, "selection did not update live display")
        require(RunnerSettings(defaults: defaults).animal == animal, "live selection was not persisted")
    }
    require(display.labels.last?.contains("CPU 50%") == true, "accessible label lost measured CPU value")
    for (next, expected) in [
        (CPUUsageTicks(user: 175, system: 150, nice: 0, idle: 975), 0.25),
        (CPUUsageTicks(user: 250, system: 150, nice: 0, idle: 1000), 0.75),
        (CPUUsageTicks(user: 300, system: 150, nice: 0, idle: 1050), 0.5)
    ] {
        ticks = next; sample.fireEvenIfCancelled()
        require(controller.usage == expected, "normal CPU values stopped updating presentation")
    }
    require(changes == 0, "normal CPU samples must not invalidate host calendar/agenda data")
    let beforeSleep = reads
    controller.suspendForSleep()
    require(changes == 1, "CPU becoming unavailable must notify host connection state once")
    require(sample.cancelled && animation.cancelled && controller.usage == nil, "sleep did not stop both timers")
    let sleepFrames = display.frames.count
    sample.fireEvenIfCancelled(); animation.fireEvenIfCancelled()
    require(reads == beforeSleep && display.frames.count == sleepFrames, "cancelled callbacks ran during sleep")
    ticks = .init(user: 1000, system: 1000, nice: 0, idle: 2000)
    controller.resumeAfterSleep(); controller.resumeAfterSleep()
    require(controller.usage == nil && displays.count == 1, "wake did not rebaseline or duplicated status item")
    let wakeSample = timers.last!
    ticks = .init(user: 1050, system: 1050, nice: 0, idle: 2100); wakeSample.fireEvenIfCancelled()
    require(controller.usage == 0.5, "wake sample used CPU time from before sleep")
    require(changes == 2, "CPU recovery must notify host connection state once")
    let wakeAnimation = timers.last!
    motion.reduceMotion = true; controller.refreshDisplayPreferences()
    require(wakeAnimation.cancelled && !wakeSample.cancelled, "Reduce Motion must keep CPU sampling active")
    let reducedFrames = display.frames.count
    wakeAnimation.fireEvenIfCancelled()
    require(display.frames.count == reducedFrames, "cancelled animation callback escaped Reduce Motion")
    motion.reduceMotion = false; motion.lowPower = true; controller.refreshDisplayPreferences()
    require(timers.last!.interval >= 0.25, "low power mode exceeded frame cap")
    readFails = true; wakeSample.fireEvenIfCancelled()
    require(controller.usage == nil && !controller.usageText.contains("0%"), "failed sampling fabricated zero usage")
    require(changes == 3, "CPU failure must notify host connection state once")
    readFails = false; wakeSample.fireEvenIfCancelled()
    require(controller.usage == nil, "CPU read recovery failed to rebaseline")
    require(changes == 3, "pending recovery repeated a host notification")
    ticks = .init(user: 1100, system: 1100, nice: 0, idle: 2200); wakeSample.fireEvenIfCancelled()
    require(controller.usage == 0.5, "CPU sampling did not recover")
    require(changes == 4, "successful recovery did not notify host")
    controller.setModuleEnabled(false)
    require(changes == 6, "disable and availability transitions did not reach host")
    let stoppedReads = reads, stoppedFrames = display.frames.count
    for timer in timers { timer.fireEvenIfCancelled() }
    require(!controller.isActive && timers.allSatisfy(\.cancelled) && display.removals == 1, "disable leaked timers or status item")
    require(reads == stoppedReads && display.frames.count == stoppedFrames, "callbacks published after stop")
    controller.setModuleEnabled(true); controller.start(); controller.stop(); controller.stop()
    require(displays.count == 2 && displays[1].removals == 1 && timers.allSatisfy(\.cancelled), "restart/stop leaked a status item or timer")
    require(RunnerSettings(defaults: defaults).animal == .cat, "disable cleared saved animal")
    withExtendedLifetime(subscription) {}
    print("PASS lifecycle: opt-in, idempotence, 8 frames, live choices, AX CPU, bounded host notifications, sleep/wake, power/motion, failure recovery and cleanup")
}

@MainActor
func renderSettings(to folder: URL) throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = "happylulu-runner-render-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    for language in ["ko", "en"] {
        var reads = 0
        let controller = CPURunnerController(settings: RunnerSettings(defaults: defaults),
            sampler: CPUUsageSampler(readTicks: {
                reads += 1
                return reads == 1 ? .init(user: 0, system: 0, nice: 0, idle: 0)
                    : .init(user: 35, system: 0, nice: 0, idle: 65)
            }), displayFactory: { _ in FixtureDisplay() },
            schedule: { FixtureTimer(interval: $0, action: $1) }, reduceMotion: { false }, lowPower: { false },
            observeSystemChanges: false, localize: { korean, english in language == "ko" ? korean : english })
        controller.setModuleEnabled(true); controller.start(); controller.refreshData()
        require(controller.usage == 0.35, "settings render lost synthetic CPU fixture")
        for dark in [false, true] {
            for animal in RunnerAnimal.allCases {
                controller.selectAnimal(animal)
                let view = CPURunnerSettingsView(model: controller, localize: { korean, english in language == "ko" ? korean : english })
                    .padding(16).frame(width: 500, height: 260, alignment: .topLeading)
                    .background(dark ? Color(NSColor.windowBackgroundColor) : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 500, height: 260),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 260)
                hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    throw NSError(domain: "RunnerRender", code: 1)
                }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "RunnerRender", code: 2)
                }
                let filename = "runner-settings-\(language)-\(dark ? "dark" : "light")-\(animal.rawValue).png"
                try png.write(to: folder.appendingPathComponent(filename))
                window.close()
            }
        }
        controller.stop()
    }
    print("PASS settings render: 12 files, 500pt content width, all animals, Korean/English, light/dark, synthetic CPU 35%")
}

await MainActor.run {
    checkCPUUsage()
    checkSettings()
    checkLifecycle()
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-dir" {
    try await MainActor.run { try renderSettings(to: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)) }
}
