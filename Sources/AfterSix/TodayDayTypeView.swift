import SwiftUI
import AfterSixCore

private typealias DayTypeState<Value> = SwiftUI.State<Value>

struct TodayDayTypeView: View {
    @ObservedObject var model: AppModel
    var onSelect: ((ManualDayType) -> Bool)? = nil
    @DayTypeState private var expanded = false
    private let accent = Color(red: 0.16, green: 0.48, blue: 0.42)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(expanded ? model.effectiveDayType.selectionOrder : [model.effectiveDayType], id: \.self) { type in
                Button {
                    if !expanded { withAnimation(.easeInOut(duration: 0.15)) { expanded = true } }
                    else if (onSelect?(type) ?? model.setDayType(type)) { withAnimation(.easeInOut(duration: 0.15)) { expanded = false } }
                } label: {
                    Text(title(type))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .padding(.horizontal, 7).frame(height: 27)
                        .foregroundStyle(type == model.effectiveDayType ? Color.white : Color.primary)
                        .background(type == model.effectiveDayType ? accent : Color.primary.opacity(0.045), in: Capsule())
                }
                .buttonStyle(.plain)
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
