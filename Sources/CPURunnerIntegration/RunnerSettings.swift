import Foundation

@MainActor
public struct RunnerSettings {
    public static let animalKey = "HappyLuluRunnerAnimal"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var animal: RunnerAnimal {
        get { defaults.string(forKey: Self.animalKey).flatMap(RunnerAnimal.init(rawValue:)) ?? .hamster }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.animalKey) }
    }
}
