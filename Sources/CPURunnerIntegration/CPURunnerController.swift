import AppKit
import Combine
import AppPluginCore
import AppPluginHost

@MainActor
public protocol RunnerScheduledTask: AnyObject { func cancel() }

@MainActor
public protocol RunnerStatusDisplaying: AnyObject {
    func render(animal: RunnerAnimal, frame: Int, usageText: String, accessibilityLabel: String)
    func remove()
}

public typealias RunnerScheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> any RunnerScheduledTask
public typealias RunnerDisplayFactory = @MainActor (@escaping @MainActor (RunnerAnimal) -> Void) -> any RunnerStatusDisplaying

@MainActor
private final class RunnerTimer: RunnerScheduledTask {
    private let timer: Timer
    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        timer.tolerance = min(0.1, interval * 0.15)
        RunLoop.main.add(timer, forMode: .common)
    }
    func cancel() { timer.invalidate() }
}

@MainActor
private final class RunnerStatusItem: NSObject, RunnerStatusDisplaying {
    private var item: NSStatusItem?
    private let chooseAnimal: @MainActor (RunnerAnimal) -> Void
    private let localize: PluginLocalizer
    private let cpuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var choices: [RunnerAnimal: NSMenuItem] = [:]
    private var selected: RunnerAnimal?
    private var label: String?

    init(localize: @escaping PluginLocalizer, chooseAnimal: @escaping @MainActor (RunnerAnimal) -> Void) {
        self.localize = localize; self.chooseAnimal = chooseAnimal
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        cpuItem.isEnabled = false; menu.addItem(cpuItem); menu.addItem(.separator())
        for (index, animal) in RunnerAnimal.allCases.enumerated() {
            let option = NSMenuItem(title: localize(animal.koreanName, animal.englishName),
                action: #selector(selectAnimal(_:)), keyEquivalent: String(index + 1))
            option.target = self; option.representedObject = animal.rawValue
            option.image = RunnerArtwork.image(for: animal, frame: 0)
            choices[animal] = option; menu.addItem(option)
        }
        item?.menu = menu
    }

    func render(animal: RunnerAnimal, frame: Int, usageText: String, accessibilityLabel: String) {
        guard let item else { return }
        item.button?.image = RunnerArtwork.image(for: animal, frame: frame)
        // Only the sampled value or selected animal changes the menu, not each animation frame.
        if cpuItem.title == usageText, selected == animal, label == accessibilityLabel { return }
        selected = animal; label = accessibilityLabel
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = accessibilityLabel
        item.button?.setAccessibilityLabel(accessibilityLabel)
        cpuItem.title = usageText
        for (candidate, option) in choices {
            option.title = localize(candidate.koreanName, candidate.englishName)
            option.state = candidate == animal ? .on : .off
        }
    }

    @objc private func selectAnimal(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let animal = RunnerAnimal(rawValue: value) else { return }
        chooseAnimal(animal)
    }

    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }
}

@MainActor
public final class CPURunnerController: ObservableObject, PluginController {
    public let descriptor: PluginDescriptor
    @Published public private(set) var enabled = false
    @Published public private(set) var animal: RunnerAnimal
    @Published public private(set) var usage: Double?
    public private(set) var isActive = false
    public var isRunning: Bool { false }
    public var connectionState: PluginConnectionState {
        !enabled || !isActive ? .off : usage == nil ? .connecting : .ready
    }
    public var changes: AnyPublisher<Void, Never> {
        // CPU presentation updates must not invalidate calendar/agenda data in the host.
        $enabled.removeDuplicates()
            .combineLatest($usage.map { $0 != nil }.removeDuplicates())
            .dropFirst().map { _ in () }.eraseToAnyPublisher()
    }
    public var usageText: String {
        guard let usage else { return localize("CPU · 확인 중/사용 불가", "CPU · pending/unavailable") }
        return "CPU \(Int((usage * 100).rounded()))%"
    }
    private let settings: RunnerSettings
    private let sampler: CPUUsageSampler
    private let displayFactory: RunnerDisplayFactory
    private let schedule: RunnerScheduler
    private let reduceMotion: @MainActor () -> Bool
    private let lowPower: @MainActor () -> Bool
    private let observeSystemChanges: Bool
    private let localize: PluginLocalizer
    private var display: (any RunnerStatusDisplaying)?
    private var sampleTimer: (any RunnerScheduledTask)?
    private var frameTimer: (any RunnerScheduledTask)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var asleep = false
    private var frame = 0
    private var generation = 0
    private var animationGeneration = 0
    private var frameInterval: TimeInterval?

    public convenience init(defaults: UserDefaults = .standard,
                            localize: @escaping PluginLocalizer = { korean, _ in korean }) {
        self.init(settings: RunnerSettings(defaults: defaults), sampler: CPUUsageSampler(),
            displayFactory: { RunnerStatusItem(localize: localize, chooseAnimal: $0) },
            schedule: { RunnerTimer(interval: $0, action: $1) },
            reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
            lowPower: { ProcessInfo.processInfo.isLowPowerModeEnabled }, localize: localize)
    }

    public init(settings: RunnerSettings, sampler: CPUUsageSampler,
                displayFactory: @escaping RunnerDisplayFactory, schedule: @escaping RunnerScheduler,
                reduceMotion: @escaping @MainActor () -> Bool, lowPower: @escaping @MainActor () -> Bool,
                observeSystemChanges: Bool = true,
                localize: @escaping PluginLocalizer = { korean, _ in korean }) {
        self.settings = settings; self.sampler = sampler; self.displayFactory = displayFactory
        self.schedule = schedule; self.reduceMotion = reduceMotion; self.lowPower = lowPower
        self.observeSystemChanges = observeSystemChanges; self.localize = localize
        animal = settings.animal
        descriptor = PluginDescriptor(id: CPURunnerModule.id, name: localize("CPU 러너", "CPU Runner"))
    }

    public func setModuleEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if !value { stop() }
    }

    public func selectAnimal(_ value: RunnerAnimal) {
        guard animal != value else { return }
        settings.animal = value; animal = value; frame = 0; render()
    }

    public func start() {
        guard enabled, !isActive else { return }
        isActive = true; asleep = false; generation += 1
        if observeSystemChanges { installObservers() }
        resumeMonitoring()
    }

    public func stop() {
        generation += 1; isActive = false; asleep = false
        cancelTimers(); sampler.reset(); usage = nil; frame = 0
        display?.remove(); display = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    public func refreshData() {
        guard enabled, isActive, !asleep else { return }
        sampleCPU()
    }

    public func suspendForSleep() {
        guard isActive, !asleep else { return }
        asleep = true; generation += 1
        cancelTimers(); sampler.reset(); usage = nil; frame = 0; render()
    }

    public func resumeAfterSleep() {
        guard enabled, isActive, asleep else { return }
        asleep = false; generation += 1; resumeMonitoring()
    }

    public func refreshDisplayPreferences() {
        guard enabled, isActive, !asleep else { return }
        updateAnimation(); render()
    }

    private func resumeMonitoring() {
        sampler.reset()
        if display == nil { display = displayFactory { [weak self] in self?.selectAnimal($0) } }
        sampleCPU()
        let current = generation
        sampleTimer = schedule(1) { [weak self] in
            guard let self, self.generation == current, self.isActive, !self.asleep else { return }
            self.sampleCPU()
        }
    }

    private func sampleCPU() {
        usage = sampler.sample()
        updateAnimation(); render()
    }

    private func updateAnimation() {
        let next = RunnerAnimationPolicy.frameInterval(usage: usage, reduceMotion: reduceMotion(), lowPower: lowPower())
        guard frameInterval != next else { return }
        frameTimer?.cancel(); frameTimer = nil; animationGeneration += 1; frameInterval = next
        guard let next else { frame = 0; return }
        let current = generation, animation = animationGeneration
        frameTimer = schedule(next) { [weak self] in
            guard let self, self.generation == current, self.animationGeneration == animation,
                  self.isActive, !self.asleep else { return }
            self.frame = (self.frame + 1) % RunnerArtwork.frameCount
            self.render()
        }
    }

    private func cancelTimers() {
        sampleTimer?.cancel(); sampleTimer = nil
        frameTimer?.cancel(); frameTimer = nil
        animationGeneration += 1; frameInterval = nil
    }

    private func render() {
        let name = localize(animal.koreanName, animal.englishName)
        display?.render(animal: animal, frame: frame, usageText: usageText,
            accessibilityLabel: localize("happylulu 러너, \(name), \(usageText)", "happylulu runner, \(name), \(usageText)"))
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspendForSleep() }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterSleep() }
        }))
        for name in [NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            let center = name == NSWorkspace.accessibilityDisplayOptionsDidChangeNotification ? workspace : NotificationCenter.default
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDisplayPreferences() }
            }))
        }
    }
}
