import Foundation
import Combine
import AppPluginCore
import AfterSixCore

@MainActor
final class FeatureCalendarModel: ObservableObject {
    @Published private(set) var events: [FeatureCalendarEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var refreshRevision = 0
    private let router: FeatureAdapterRouter
    private var generation = 0
    private var loadedSource: String?
    init(router: FeatureAdapterRouter) { self.router = router }
    var calendar: Calendar {
        guard let timeZone = router.timeZone(for: .calendar) else { return .current }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar
    }
    func refresh() { refreshRevision += 1 }
    func load(in interval: DateInterval) async {
        generation += 1; let current = generation
        events = []; loadedSource = nil; errorMessage = nil; isLoading = true
        defer { if generation == current { isLoading = false } }
        do {
            let values = try await router.calendarEvents(in: interval)
            guard generation == current, !Task.isCancelled else { return }
            events = values.sorted { $0.start < $1.start }
            loadedSource = router.selectedID(for: .calendar)
        } catch is CancellationError {
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            if let failure = error as? FeatureAdapterFailure {
                switch failure {
                case .outsideCoverage:
                    errorMessage = "선택한 달은 연결의 조회 범위 밖입니다. 플러그인 설정에서 조회 가능한 기간을 확인해 주세요."
                case .missingSnapshot:
                    errorMessage = "플러그인의 조회 결과가 없습니다. 플러그인 설정에서 연결 상태를 확인하고 다시 조회해 주세요."
                default: errorMessage = "선택한 기능 연결을 사용할 수 없습니다. 플러그인 설정을 확인해 주세요."
                }
            } else { errorMessage = error.localizedDescription }
        }
    }
    func events(on day: Date, calendar: Calendar) -> [FeatureCalendarEvent] {
        guard loadedSource == router.selectedID(for: .calendar) else { return [] }
        let grid = CalendarMonth(containing: day, calendar: calendar)
        return events.filter { grid.overlaps(day: day, start: $0.start, end: $0.end) }
    }
}
