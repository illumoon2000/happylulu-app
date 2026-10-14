import SwiftUI
import AfterSixCore
import AppPluginCore

private typealias FeatureCalendarState<Value> = SwiftUI.State<Value>

struct FeatureCalendarView: View {
    @ObservedObject var model: FeatureCalendarModel
    @ObservedObject var plugins: PluginManagerModel
    @ObservedObject var sync: CalendarSyncModel
    let onOpenSettings: () -> Void
    @FeatureCalendarState private var month = Date()
    @FeatureCalendarState private var selectedDay = Date()
    private var calendar: Calendar { model.calendar }
    private var grid: CalendarMonth { CalendarMonth(containing: month, calendar: calendar) }
    private var source: String { plugins.router.selectedID(for: .calendar) }
    private var readID: String {
        "\(grid.start.timeIntervalSince1970)|\(source)|\(plugins.revision)|\(sync.eventsRevision)|\(model.refreshRevision)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(plugins.adapterName(source), systemImage: source == plugins.router.defaultID ? "desktopcomputer" : "puzzlepiece.extension")
                    .font(.headline)
                Spacer()
                Button(L("일정 새로고침", "Refresh events")) {
                    plugins.refreshSource(for: .calendar); model.refresh()
                }.disabled(model.isLoading || plugins.registrations.first(where: { $0.id == source })?.controller.isRunning == true)
                Button(L("기능 연결 설정", "Feature sources"), action: onOpenSettings)
            }
            if source == plugins.router.defaultID { CalendarSyncStatusView(model: sync) }
            else if let snapshot = plugins.registry.snapshot(for: source) {
                Text(L("일정 시간대: ", "Calendar time zone: ") + calendar.timeZone.identifier)
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("마지막 성공: ", "Last successful fetch: ") + snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                if plugins.registrations.first(where: { $0.id == source })?.controller.connectionState == .attention {
                    Label(L("연결 확인이 필요합니다. 마지막 성공 결과를 표시합니다.", "The connection needs attention. Showing the last successful result."), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            LeaveSummaryView(model: plugins)
            if model.isLoading { ProgressView(L("일정을 불러오는 중", "Loading events")) }
            if let message = model.errorMessage {
                Label(visibleMessage(message), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            MonthCalendarView(month: $month, selectedDay: $selectedDay, calendar: calendar) { day in
                let events = model.events(on: day, calendar: calendar)
                ForEach(Array(events.prefix(2))) { event in
                    Text(event.title).font(.system(size: 10)).lineLimit(1)
                        .foregroundStyle(.tint)
                }
                if events.count > 2 {
                    Text(L("+\(events.count - 2)건", "+\(events.count - 2) events")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text(selectedDay.formatted(Date.FormatStyle(locale: displayLocale, calendar: calendar, timeZone: calendar.timeZone).month().day().weekday())).font(.headline)
            if !model.isLoading && model.errorMessage == nil {
                let selected = model.events(on: selectedDay, calendar: calendar)
                if selected.isEmpty { Text(L("선택한 날짜에 일정이 없습니다.", "No events on this date.")).foregroundStyle(.secondary) }
                ForEach(selected) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.title).font(.headline)
                        Text(event.isAllDay ? L("종일", "All day")
                             : timeLabel(event))
                            .font(.caption).foregroundStyle(.secondary)
                        if source == plugins.router.defaultID,
                           let title = sync.calendars.first(where: { $0.id == event.calendarID })?.title {
                            Text(title).font(.caption).foregroundStyle(.secondary)
                        }
                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
            }
        }
        .task(id: readID) { await model.load(in: DateInterval(start: grid.start, end: grid.end)) }
    }
    private func timeLabel(_ event: FeatureCalendarEvent) -> String {
        let format = Date.FormatStyle(date: .omitted, time: .shortened, locale: displayLocale, timeZone: calendar.timeZone)
        return "\(event.start.formatted(format)) – \(event.end.formatted(format))"
    }
}

struct LeaveSummaryView: View {
    @ObservedObject var model: PluginManagerModel
    var compact = false
    var body: some View {
        if let snapshot = model.leaveSnapshot, let balance = snapshot.leave {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L("잔여 연차", "Leave remaining"), systemImage: "leaf")
                    Spacer()
                    Text(balance.remainingDays.formatted(.number.precision(.fractionLength(0...2))) + L("일", " days"))
                        .monospacedDigit().fontWeight(.semibold)
                }
                if !compact {
                    Text(L("사용 \(balance.usedDays.formatted())일 / 총 \(balance.totalDays.formatted())일", "Used \(balance.usedDays.formatted()) / total \(balance.totalDays.formatted()) days"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.adapterName(snapshot.pluginID) + " · " + snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .font(compact ? .caption : .body)
        }
    }
}
