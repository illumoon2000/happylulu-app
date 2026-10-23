import SwiftUI
import AfterSixCore

private typealias DayTypeState<Value> = SwiftUI.State<Value>

struct TodayDayTypeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var appearance = AppearanceModel.shared
    @ObservedObject var model: AppModel
    var onSelect: ((ManualDayType) -> Bool)? = nil
    @DayTypeState private var expanded = false
    private var accent: Color { appearance.accent }
    private var selectedForeground: Color {
        AppearancePreferences.luminance(appearance.hex(.accent)) > 0.179 ? .black : .white
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(expanded ? model.effectiveDayType.selectionOrder : [model.effectiveDayType], id: \.self) { type in
                dayTypeButton(type)
                .accessibilityLabel(type.displayLabel)
                .accessibilityAddTraits(type == model.effectiveDayType ? .isSelected : [])
                .help(expanded ? type.displayLabel : L("눌러서 오늘 근무 유형 변경", "Choose today's workday type"))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("오늘 근무 유형", "Today's workday type"))
        .onExitCommand { expanded = false }
    }

    @ViewBuilder private func dayTypeButton(_ type: ManualDayType) -> some View {
        if appearance.usesNativeAppearance {
            if type == model.effectiveDayType {
                Button(title(type)) { select(type) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button(title(type)) { select(type) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        } else {
            Button { select(type) } label: {
                Text(title(type))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .padding(.horizontal, 7).frame(height: 27)
                    .foregroundStyle(type == model.effectiveDayType ? selectedForeground : appearance.text)
                    .background(type == model.effectiveDayType ? accent : Color.primary.opacity(0.045), in: Capsule())
            }.buttonStyle(.plain)
        }
    }

    private func select(_ type: ManualDayType) {
        if !expanded { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded = true } }
        else if (onSelect?(type) ?? model.setDayType(type)) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded = false }
        }
    }

    private func title(_ type: ManualDayType) -> String {
        switch type {
        case .regular: L("일반근무", "Regular")
        case .morningHalf: L("오전반차", "AM off")
        case .afternoonHalf: L("오후반차", "PM off")
        case .luluDay: L("룰루데이", "Lulu")
        case .annualLeave: L("연차/공가", "Leave")
        }
    }
}
