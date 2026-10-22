import Foundation

public enum RunnerAnimal: String, CaseIterable, Codable, Identifiable, Sendable {
    case hamster, rabbit, cat

    public var id: String { rawValue }
    public var koreanName: String {
        switch self {
        case .hamster: "햄스터"
        case .rabbit: "토끼"
        case .cat: "고양이"
        }
    }
    public var englishName: String {
        switch self {
        case .hamster: "Hamster"
        case .rabbit: "Rabbit"
        case .cat: "Cat"
        }
    }
}
