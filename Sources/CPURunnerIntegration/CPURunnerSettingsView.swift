import SwiftUI
import AppPluginHost

public struct CPURunnerSettingsView: View {
    @ObservedObject private var model: CPURunnerController
    private let localize: PluginLocalizer

    public init(model: CPURunnerController, localize: @escaping PluginLocalizer) {
        self.model = model; self.localize = localize
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(localize("캐릭터", "Character")).font(.headline)
                        Text(localize("달릴 친구를 골라 주세요.", "Choose your little runner."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 112, alignment: .leading)
                    HStack(spacing: 14) {
                        ForEach(RunnerAnimal.allCases) { animal in
                            VStack(spacing: 5) {
                                Image(nsImage: RunnerArtwork.image(for: animal, frame: 0))
                                    .renderingMode(.template).resizable().scaledToFit()
                                    .frame(width: 39, height: 27)
                                Text(localize(animal.koreanName, animal.englishName)).font(.caption)
                            }
                            .foregroundStyle(model.animal == animal ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                        }
                    }.frame(maxWidth: .infinity)
                    Picker(localize("캐릭터", "Character"), selection: Binding(
                        get: { model.animal }, set: { model.selectAnimal($0) })) {
                        ForEach(RunnerAnimal.allCases) { animal in
                            Text(localize(animal.koreanName, animal.englishName)).tag(animal)
                        }
                    }.labelsHidden().frame(width: 132)
                        .accessibilityLabel(localize("러너 캐릭터", "Runner character"))
                }
                Divider()
                HStack(spacing: 12) {
                    Text(localize("CPU 사용량", "CPU usage")).frame(width: 112, alignment: .leading)
                    Text(model.usageText).monospacedDigit().frame(maxWidth: .infinity)
                    Text(localize("1초마다 갱신", "Updates every second"))
                        .font(.caption).foregroundStyle(.secondary).frame(width: 132, alignment: .trailing)
                }
                Text(localize("CPU가 바쁠수록 빠르게 달려요. 동작 줄이기를 사용하면 가만히 있어요.",
                    "Your runner speeds up as CPU usage rises. Reduce Motion keeps it still."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(12)
        }
    }
}
