import SwiftUI
import AfterSixCore

private typealias CalendarState<Value> = SwiftUI.State<Value>

struct MonthCalendarView<DayContent: View>: View {
    @Binding var month: Date
    @Binding var selectedDay: Date
    let calendar: Calendar
    var compact = false
    @ViewBuilder let dayContent: (Date) -> DayContent
    private let accent = Color(red: 0.16, green: 0.48, blue: 0.42)

    var body: some View {
        let grid = CalendarMonth(containing: month, calendar: calendar)
        VStack(spacing: 8) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(L("이전 달", "Previous month"))
                Text(month.formatted(Date.FormatStyle(locale: displayLocale, calendar: calendar, timeZone: calendar.timeZone).year().month()))
                    .font(.system(size: compact ? 12 : 18, weight: .semibold))
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel(L("다음 달", "Next month"))
                Spacer()
                Button(L("오늘", "Today")) { month = Date(); selectedDay = Date() }
            }
            .buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    let weekday = (calendar.firstWeekday - 1 + index) % 7
                    Text(weekdayLabel(weekday))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(grid.days.indices, id: \.self) { index in
                    if let day = grid.days[index] {
                        Button { selectedDay = day } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(calendar.component(.day, from: day))")
                                    .font(.system(size: compact ? 10 : 13, weight: calendar.isDateInToday(day) ? .bold : .medium))
                                    .foregroundStyle(calendar.isDateInToday(day) ? accent : .primary)
                                dayContent(day)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: compact ? 42 : 78, maxHeight: compact ? 42 : 78, alignment: .topLeading)
                            .padding(compact ? 4 : 8)
                            .background(calendar.isDate(day, inSameDayAs: selectedDay) ? accent.opacity(0.16) : Color.primary.opacity(0.035),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(calendar.isDate(day, inSameDayAs: selectedDay) ? accent : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                        .accessibilityAddTraits(calendar.isDate(day, inSameDayAs: selectedDay) ? .isSelected : [])
                    } else {
                        Color.clear.frame(height: compact ? 50 : 94).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func move(_ months: Int) {
        let next = CalendarMonth(containing: month, calendar: calendar).shifted(by: months)
        month = next.start
        selectedDay = next.start
    }

    private func weekdayLabel(_ index: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        formatter.calendar = calendar
        return formatter.shortWeekdaySymbols[index]
    }
}

struct AttendanceCalendarView: View {
    @ObservedObject var model: AppModel
    var compact = false
    @CalendarState private var month = Date()
    @CalendarState private var selectedDay = Date()
    private let accent = Color(red: 0.16, green: 0.48, blue: 0.42)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = model.calendar.timeZone
        calendar.firstWeekday = model.calendar.firstWeekday
        return calendar
    }

    var body: some View {
        let history = model.arrivalHistory
        VStack(alignment: .leading, spacing: 12) {
            MonthCalendarView(month: $month, selectedDay: $selectedDay, calendar: calendar, compact: compact) { day in
                let key = model.dayKey(day, calendar: calendar)
                if let records = history[key], let record = records.first {
                    Text(Attendance.clockLabel(record.time, timeZone: TimeZone(identifier: record.timeZoneID) ?? .current))
                        .font(.system(size: compact ? 9 : 12, weight: .medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Text(records.count > 1 ? L("\(records.count)건", "\(records.count) records") : (record.mode == .normal ? L("출근", "Arrived") : record.mode.displayLabel))
                        .font(.system(size: compact ? 8 : 10)).foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.75)
                } else if isSuppressed(day) {
                    Text(L("쉬는 날", "Day off")).font(.system(size: compact ? 8 : 11)).foregroundStyle(.secondary)
                }
            }
            let key = model.dayKey(selectedDay, calendar: calendar)
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedDay.formatted(Date.FormatStyle(locale: displayLocale, calendar: calendar, timeZone: calendar.timeZone).month().day().weekday()))
                    .font(.system(size: compact ? 11 : 15, weight: .semibold))
                if let records = history[key] {
                    ForEach(records, id: \.day) { record in
                        Text(L("출근 \(clock(record)) · \(record.mode.displayLabel)", "Arrived \(clock(record)) · \(record.mode.displayLabel)"))
                        Label(record.source == .manual ? L("직접 입력", "Manual entry") : (record.source == .login ? L("로그인 감지", "Login detected") : L("잠금 해제 감지", "Unlock detected")),
                              systemImage: record.source == .manual ? "pencil" : (record.source == .login ? "power" : "lock.open"))
                            .foregroundStyle(.secondary)
                        Text(L("기록 시간대: \(record.timeZoneID)", "Recorded time zone: \(record.timeZoneID)")).foregroundStyle(.secondary)
                        if record.day != key {
                            Text(L("기록 당시 날짜: \(record.day)", "Original date: \(record.day)")).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(isSuppressed(selectedDay) ? L("자동 기록을 쉬는 날이에요.", "Automatic recording is paused for this day.") : L("저장된 출근 기록이 없어요.", "No arrival saved for this day."))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: compact ? 10 : 13))
            Text(L("양력 달력 · 출근 날짜와 시각은 기록 당시 시간대로 표시합니다.", "Gregorian calendar · arrivals use their recorded time zone."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func clock(_ record: Arrival) -> String {
        displayClock(record.time, timeZone: TimeZone(identifier: record.timeZoneID) ?? .current)
    }

    private func isSuppressed(_ day: Date) -> Bool {
        model.isSuppressed(day, calendar: calendar)
    }
}
