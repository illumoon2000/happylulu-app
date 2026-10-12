import SwiftUI
import AfterSixCore
import CalendarSyncServices

private typealias WorkspaceState<Value> = SwiftUI.State<Value>

struct CalendarSyncStatusView: View {
    @ObservedObject var model: CalendarSyncModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(model.enabled ? L("캘린더 자동 동기화 켜짐", "Calendar auto-sync on") : (model.pairLocked ? L("캘린더 자동 동기화 일시 중지", "Calendar auto-sync paused") : L("캘린더 동기화 시작 전", "Calendar sync not started")),
                  systemImage: model.enabled ? "arrow.triangle.2.circlepath" : "calendar")
            if model.isRunning { Label(L("캘린더 작업 중", "Calendar task in progress"), systemImage: "clock") }
            if let last = model.lastSuccessAt {
                Text(L("마지막 동기화: \(last.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: displayLocale)))", "Last sync: \(last.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: displayLocale)))"))
            }
            if model.enabled, let next = model.nextRunAt {
                Text(L("다음 실행: \(next.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: displayLocale)))", "Next run: \(next.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: displayLocale)))"))
            }
            if !model.conflicts.isEmpty {
                Text(L("확인이 필요한 충돌 \(model.conflicts.count)건", "\(model.conflicts.count) conflicts to review")).foregroundStyle(.orange)
            }
            if let message = model.message {
                Text(visibleMessage(message)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
    }
}

struct SyncedEventsCalendarView: View {
    @ObservedObject var model: CalendarSyncModel
    let onOpenSettings: () -> Void
    @WorkspaceState private var month = Date()
    @WorkspaceState private var selectedDay = Date()
    private var calendar: Calendar { .current }
    private var grid: CalendarMonth { CalendarMonth(containing: month, calendar: calendar) }
    // Month and pair form the read identity; completed syncs/explicit refreshes trigger a new read.
    private var readID: String {
        "\(grid.start.timeIntervalSince1970)|\(model.selectedDaouCalendar)|\(model.selectedGoogleCalendar)|\(model.eventsRevision)"
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 16) {
                CalendarSyncStatusView(model: model)
                HStack {
                    calendarLabel(model.selectedDaouCalendar, side: L("다우오피스", "Daou Office"), color: .blue)
                    calendarLabel(model.selectedGoogleCalendar, side: "Google", color: .green)
                    Spacer()
                    Button(L("일정 새로고침", "Refresh events")) { model.refreshDisplayedEvents() }
                        .disabled(model.isLoadingEvents)
                    Button(L("동기화 설정", "Sync settings"), action: onOpenSettings)
                }
                .font(.caption)
                Text(L("선택한 Mac 캘린더의 현재 일정입니다. 양쪽의 복사본은 계정별로 표시하며, 반복·초대 일정도 조회할 수 있습니다.", "Current events from the selected Mac calendars. Copies appear per account, including recurring and invited events."))
                    .font(.caption).foregroundStyle(.secondary)
                if model.selectedDaouCalendar.isEmpty && model.selectedGoogleCalendar.isEmpty {
                    Text(L("동기화 설정에서 표시할 캘린더를 선택해 주세요.", "Select calendars in Sync settings.")).foregroundStyle(.secondary)
                } else if model.isLoadingEvents {
                    ProgressView(L("일정을 불러오는 중", "Loading events"))
                } else if let error = model.eventReadError {
                    Label(visibleMessage(error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button(L("캘린더 연결 확인", "Check calendar connection"), action: onOpenSettings)
                }
                MonthCalendarView(month: $month, selectedDay: $selectedDay, calendar: calendar) { day in
                    let events = events(on: day)
                    ForEach(Array(events.prefix(2))) { event in
                        Text(event.title).font(.system(size: 10)).lineLimit(1)
                            .foregroundStyle(color(event))
                    }
                    if events.count > 2 {
                        Text(L("+\(events.count - 2)건", "+\(events.count - 2) events")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text(selectedDay.formatted(.dateTime.locale(displayLocale).month().day().weekday()))
                    .font(.headline)
                if model.eventReadError == nil && !model.isLoadingEvents {
                    let selected = events(on: selectedDay)
                    if selected.isEmpty {
                        Text(L("선택한 날짜에 조회된 일정이 없어요.", "No events found for this date.")).foregroundStyle(.secondary)
                    }
                    ForEach(selected) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.headline)
                            Text("\(side(event)) · \(timeLabel(event))").foregroundStyle(color(event))
                            if let location = event.location, !location.isEmpty {
                                Label(location, systemImage: "mappin.and.ellipse").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(color(event).opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(2)
        }
        .task(id: readID) { await model.loadDisplayedEvents(start: grid.start, end: grid.end) }
    }

    private func events(on day: Date) -> [SystemCalendarDisplayEvent] {
        model.displayedEvents.filter { grid.overlaps(day: day, start: $0.start, end: $0.end) }
    }

    private func calendarLabel(_ id: String, side: String, color: Color) -> some View {
        let title = model.calendars.first { $0.id == id }?.title ?? (id.isEmpty ? L("선택 전", "Not selected") : L("연결 확인 필요", "Check connection"))
        return Label("\(side) · \(title)", systemImage: "circle.fill").foregroundStyle(color)
    }

    private func side(_ event: SystemCalendarDisplayEvent) -> String {
        event.calendarID == model.selectedDaouCalendar ? L("다우오피스", "Daou Office") : "Google"
    }

    private func color(_ event: SystemCalendarDisplayEvent) -> Color {
        event.calendarID == model.selectedDaouCalendar ? .blue : .green
    }

    private func timeLabel(_ event: SystemCalendarDisplayEvent) -> String {
        if event.isAllDay { return L("종일", "All day") }
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: displayLocale)
        return "\(event.start.formatted(format)) ~ \(event.end.formatted(format))"
    }
}
