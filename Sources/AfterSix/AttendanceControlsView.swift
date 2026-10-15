import SwiftUI
import AfterSixCore

private typealias EditorState<Value> = SwiftUI.State<Value>

private enum ManualModeChoice: String, CaseIterable {
    case automatic, normal, morningHalf, afternoonHalf

    var label: String {
        switch self {
        case .automatic: L("오늘 선택 또는 자동", "Today’s choice or automatic")
        case .normal: L("일반 근무", "Regular workday")
        case .morningHalf: L("오전 반차", "Morning off")
        case .afternoonHalf: L("오후 반차", "Afternoon off")
        }
    }

    var selectedMode: WorkdayMode? {
        switch self {
        case .automatic: nil
        case .normal: .normal
        case .morningHalf: .morningHalf
        case .afternoonHalf: .afternoonHalf
        }
    }

    static func from(_ mode: WorkdayMode) -> Self {
        switch mode {
        case .normal: .normal
        case .morningHalf: .morningHalf
        case .afternoonHalf: .afternoonHalf
        }
    }
}

struct ManualArrivalEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @EditorState private var editTime = Date()
    @EditorState private var editMode = ManualModeChoice.automatic
    @EditorState private var editDay = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("출근 시각 수정", "Edit arrival time")).font(.headline)
            editor
            if let error = model.errorMessage {
                Text(visibleMessage(error)).font(.caption).foregroundStyle(.orange)
            }
        }.padding(20).frame(width: 350)
        .environment(\.locale, displayLocale)
        .onAppear {
            model.refresh()
            let record = model.state.arrivals[model.dayKey(model.now)]
            editTime = record?.time ?? model.now
            editMode = model.todayDayType != nil ? .automatic
                : record.map { $0.modeSource == .manual ? ManualModeChoice.from($0.mode) : .automatic } ?? .automatic
            editDay = model.dayKey(model.now)
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("근무 유형", "Workday type"), selection: $editMode) {
                ForEach(ManualModeChoice.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }.pickerStyle(.menu)
            HStack {
                DatePicker(L("오늘 출근", "Today’s arrival"), selection: $editTime, displayedComponents: [.hourAndMinute])
                    .datePickerStyle(.field).labelsHidden()
                Spacer()
                Button(L("취소", "Cancel")) { dismiss() }.controlSize(.small)
                Button(L("저장", "Save")) {
                    if model.saveManualClock(editTime, forDay: editDay, selectedMode: editMode.selectedMode) {
                        dismiss()
                    }
                }.controlSize(.small).buttonStyle(.borderedProminent)
            }
            Text(L("일반·오후 반차 08:00~10:00, 오전 반차 13:00~15:00. 미래 시각은 저장하지 않아요.", "Regular or afternoon off: 08:00–10:00; morning off: 13:00–15:00. Future times cannot be saved."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

}

struct AttendanceControlsView: View {
    @ObservedObject var model: AppModel
    @EditorState private var editing = false
    @EditorState private var confirmSkip = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(L("출근 시각 수정", "Edit arrival time")) { editing = true }
                Button(L("오늘 쉬는 날", "Take today off")) { confirmSkip = true }
                    .disabled(model.isSkipped)
            }
            if let departure = model.departure, departure > model.now {
                Text(L("퇴근까지 \(model.countdownText)", "Time to leave: \(model.countdownText)"))
            }
            if let status = model.postDepartureStatus {
                if let minutes = status.extraMinutes { Text(model.extraLabel(minutes)) }
                Text(model.mealStatusLabel(status))
                Text(L("예정 퇴근 기준 안내이며 실제 근무나 식대 지급 승인을 뜻하지 않습니다.",
                       "Based on scheduled departure; this does not verify work or approve meal reimbursement."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(model.state.lastUnlockAt.map { L("최근 잠금 해제 감지 · \(displayDate($0))", "Last unlock detected · \(displayDate($0))") }
                 ?? L("잠금 해제 감지 이력 없음", "No unlock detected yet"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $editing) { ManualArrivalEditor(model: model) }
        .confirmationDialog(L("오늘 출근 기록을 지우고 자동 기록을 쉬겠어요?", "Clear today’s arrival and pause automatic recording?"), isPresented: $confirmSkip) {
            Button(L("오늘 쉬는 날로 변경", "Take today off"), role: .destructive) { model.skipToday() }
            Button(L("취소", "Cancel"), role: .cancel) {}
        } message: { Text(L("출근을 직접 입력하면 다시 시작합니다.", "Enter an arrival time to resume.")) }
    }
}
