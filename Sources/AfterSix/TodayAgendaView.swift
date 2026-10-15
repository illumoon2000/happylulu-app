import SwiftUI
import AppPluginCore
import AfterSixCore

struct TodayAgendaView: View {
    @ObservedObject var model: FeatureCalendarModel
    @ObservedObject var plugins: PluginManagerModel
    @ObservedObject var sync: CalendarSyncModel
    let now: Date
    let onOpenCalendar: () -> Void
    private var calendar: Calendar { model.calendar }
    private var start: Date { calendar.startOfDay(for: now) }
    private var end: Date { calendar.date(byAdding: .day, value: 1, to: start) ?? start }
    private var readID: String {
        "\(start.timeIntervalSince1970)|\(plugins.router.selectedID(for: .calendar))|\(plugins.revision)|\(sync.eventsRevision)|\(model.refreshRevision)"
    }
    var body: some View {
        let agenda = DailyAgenda(events: model.events(on: now, calendar: calendar), on: now, calendar: calendar)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L("오늘 일정", "Today's agenda")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(agenda.remainingCount > 0 ? L("+\(agenda.remainingCount)건", "+\(agenda.remainingCount) more") : L("전체 보기", "View all"),
                       action: onOpenCalendar)
                    .buttonStyle(.borderless).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if model.isLoading {
                Text(L("일정을 불러오는 중…", "Loading events…")).font(.caption).foregroundStyle(.secondary)
            } else if let error = model.errorMessage {
                Button(L("일정 연결 확인이 필요해요", "Check the calendar connection"), action: onOpenCalendar)
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.orange).help(visibleMessage(error))
            } else if agenda.items.isEmpty {
                Text(L("조회된 일정이 없어요", "No events found")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(agenda.items) { event in
                    HStack(spacing: 9) {
                        Circle().fill(Color.accentColor.opacity(0.65)).frame(width: 5, height: 5)
                        Text(event.isAllDay ? L("종일", "All day") : Attendance.clockLabel(event.start, timeZone: calendar.timeZone))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 43, alignment: .leading)
                        Text(event.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }.help(event.title)
                }
            }
        }.frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .topLeading)
        .task(id: readID) { await model.load(in: DateInterval(start: start, end: end)) }
    }
}
