import SwiftUI
import AfterSixCore

// The explicit type alias selects the macOS 13-compatible property wrapper,
// avoiding the SDK 27 State macro that requires an Xcode-only compiler plugin.
private typealias LocalState<Value> = SwiftUI.State<Value>

private enum ManualModeChoice: String, CaseIterable {
    case automatic, normal, morningHalf, afternoonHalf

    var label: String {
        switch self {
        case .automatic: L("자동 판단", "Automatic")
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

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var calendarSync: CalendarSyncModel
    @LocalState private var historyVisible = false
    let onOpenHistory: () -> Void
    let onOpenSettings: () -> Void
    @LocalState private var editing = false
    @LocalState private var editTime = Date()
    @LocalState private var editMode = ManualModeChoice.automatic
    @LocalState private var editDay = ""
    @LocalState private var confirmSkip = false
    private let accent = Color(red: 0.16, green: 0.48, blue: 0.42)
    private var selectedLocale: Locale { _ = language.choice; return displayLocale }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    header
                    summary
                    timeCards
                    actions
                    if editing { editor }
                    if let error = model.errorMessage {
                        Label(visibleMessage(error), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup(L("출근 캘린더", "Arrival calendar"), isExpanded: $historyVisible) {
                        AttendanceCalendarView(model: model, compact: true)
                    }
                    CalendarSyncStatusView(model: calendarSync)
                    Button(L("전체 출근 캘린더 열기", "Open arrival calendar"), action: onOpenHistory)
                        .buttonStyle(.borderless)
                    lastUnlockStatus
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button { onOpenSettings() } label: {
                    Label(L("설정", "Settings"), systemImage: "gearshape")
                }
                Spacer()
                Button(L("종료", "Quit")) { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 364, height: 470)
        .tint(accent)
        .environment(\.locale, selectedLocale)
        .onAppear { model.refresh() }
        .confirmationDialog(L("오늘 출근 기록을 지우고 자동 기록을 쉬겠어요?", "Clear today’s arrival and pause automatic recording?"), isPresented: $confirmSkip) {
            Button(L("오늘 쉬는 날로 변경", "Take today off"), role: .destructive) { model.skipToday(); editing = false }
            Button(L("취소", "Cancel"), role: .cancel) {}
        } message: { Text(L("오늘은 다시 잠금을 해제해도 자동으로 기록하지 않습니다. 출근 시각을 직접 입력하면 다시 시작합니다.", "Unlocking again today will not record an arrival. Enter an arrival time to resume.")) }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 36, height: 36)
                .accessibilityLabel(L("HappyLulu 웃는 시계", "HappyLulu smiling clock"))
            VStack(alignment: .leading, spacing: 2) {
                Text("HappyLulu").font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(L("우리의 하루를 더 즐겁게.", "Make every day brighter.")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.now.formatted(.dateTime.locale(displayLocale).month().day().weekday(.abbreviated)))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var extraMinutes: Int? {
        guard model.minutesLeft == 0 else { return nil }
        return model.postDepartureStatus?.extraMinutes
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.minutesLeft == nil ? L("오늘", "TODAY")
                 : extraMinutes == nil ? L("퇴근까지", "TIME TO GO HOME") : L("추가 시간", "EXTRA TIME"))
                .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.8).foregroundStyle(accent)
            if let minutes = model.minutesLeft {
                Text(minutes == 0
                     ? extraMinutes.map(model.extraLabel)
                         ?? L("오늘도 수고했어요", "Great work today")
                     : model.countdownText)
                    .font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(extraMinutes != nil ? L("예정 퇴근 이후 경과 시간", "Elapsed after scheduled departure")
                     : minutes == 0 ? L("오늘의 퇴근 시간이 됐어요.", "It’s time to go home.")
                     : L("퇴근까지 남았어요", "Time until departure"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let extra = model.postDepartureStatus {
                    Text(model.mealStatusLabel(extra))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                    Text(L("예정 퇴근 기준 안내이며 실제 근무나 식대 지급 승인을 뜻하지 않습니다.",
                           "Based on scheduled departure; this does not verify work or approve meal reimbursement."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ProgressView(value: model.progress).padding(.top, 6)
            } else {
                Text(model.isSkipped ? L("오늘은 쉬어가요", "Take today off") : L("출근 기록 대기", "Waiting for arrival"))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(model.isSkipped ? L("오늘 자동 기록을 쉬고 있어요.", "Automatic recording is paused today.") : L("일반·오후 반차 08:00~10:00, 오전 반차 13:00~15:00", "Regular or afternoon off: 08:00–10:00; morning off: 13:00–15:00"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(L("이미 출근했다면 아래에서 시각을 입력해 주세요.", "Already at work? Enter your arrival time below."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let arrival = model.arrival {
                let reason = arrival.modeSource == .manual ? L("직접 지정", "Chosen manually") :
                    (model.detectedModeToday == arrival.mode && arrival.mode != .normal ? L("캘린더 인식", "Detected from calendar") : L("출근 시각 자동 인식", "Detected from arrival time"))
                Label("\(arrival.mode.displayLabel) · \(reason)", systemImage: "calendar.badge.clock")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
            }
            if model.earlyLeaveMinutes > 0 && !model.isSkipped {
                Label(L("마지막 금요일 · 2시간 조기 퇴근", "Last Friday · leave 2 hours early"), systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 16))
    }

    private var timeCards: some View {
        HStack(spacing: 10) {
            timeCard(L("출근", "Arrival"), time: model.arrival.map { model.timeLabel($0.time) } ?? "—",
                     note: model.arrival.map { $0.source == .manual ? L("직접 입력", "Entered manually") : ($0.source == .login ? L("로그인 자동 실행 감지", "Login launch detected") : L("잠금 해제 감지", "Unlock detected")) } ?? L("아직 기록 없음", "No record yet"))
            timeCard(L("퇴근 예정", "Expected departure"), time: model.departure.map { model.timeLabel($0) } ?? "—",
                     note: model.departure.map {
                         if model.arrival?.mode != .normal { return L("반차 · 휴게 없이 4시간", "Half-day · 4 hours without break") }
                         return model.calendar.isDate($0, inSameDayAs: model.now) ? L("휴게시간 포함", "Includes break") : L("다음 날 · 휴게 포함", "Next day · includes break")
                     } ?? L("출근 후 계산", "Calculated after arrival"))
        }
    }

    private func timeCard(_ title: String, time: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(time).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
            Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var actions: some View {
        HStack {
            Button {
                model.refresh()
                editTime = model.arrival?.time ?? model.now
                editMode = model.arrival?.modeSource == .manual
                    ? ManualModeChoice.from(model.arrival!.mode) : .automatic
                editDay = Attendance.dayKey(model.now, calendar: model.calendar)
                editing.toggle()
            } label: { Label(model.arrival == nil ? L("출근 시각 입력", "Enter arrival time") : L("출근 시각 수정", "Edit arrival time"), systemImage: "pencil") }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Spacer()
            Button(L("오늘 쉬는 날", "Take today off")) { confirmSkip = true }
                .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(.secondary)
                .disabled(model.isSkipped)
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
                Button(L("취소", "Cancel")) { editing = false }.controlSize(.small)
                Button(L("저장", "Save")) {
                    model.refresh()
                    guard editDay == Attendance.dayKey(model.now, calendar: model.calendar) else {
                        model.errorMessage = "날짜가 바뀌었습니다. 입력 창을 다시 열어 주세요."
                        editing = false
                        return
                    }
                    let components = model.calendar.dateComponents([.hour, .minute], from: editTime)
                    let start = model.calendar.startOfDay(for: model.now)
                    if let date = model.calendar.date(bySettingHour: components.hour!, minute: components.minute!, second: 0, of: start),
                       model.saveManual(date, selectedMode: editMode.selectedMode) {
                        editing = false
                    }
                }.controlSize(.small).buttonStyle(.borderedProminent)
            }
            Text(L("일반·오후 반차 08:00~10:00, 오전 반차 13:00~15:00. 미래 시각은 저장하지 않아요.", "Regular or afternoon off: 08:00–10:00; morning off: 13:00–15:00. Future times cannot be saved."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var lastUnlockStatus: some View {
        Text(model.state.lastUnlockAt.map { L("최근 잠금 해제 감지 · \(displayDate($0))", "Last unlock detected · \(displayDate($0))") }
             ?? L("아직 잠금 해제 감지 이력 없음 · 일반 08~10시, 오전 반차 13~15시", "No unlock detected yet · regular 08–10, morning off 13–15"))
            .font(.system(size: 10)).foregroundStyle(.tertiary)
    }
}
