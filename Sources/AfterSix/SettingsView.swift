import AppPluginHost
import SwiftUI
import ServiceManagement
import AfterSixCore

private typealias SettingsState<Value> = SwiftUI.State<Value>

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, work, history, calendar, plugins, updates

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: L("일반", "General")
        case .work: L("근무", "Work")
        case .history: L("출근 기록", "Arrival history")
        case .calendar: L("캘린더", "Calendar")
        case .plugins: L("플러그인", "Plugins")
        case .updates: L("업데이트", "Updates")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .work: "clock"
        case .history: "calendar"
        case .calendar: "calendar"
        case .plugins: "puzzlepiece.extension"
        case .updates: "arrow.down.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .general: L("언어와 앱 실행 방식을 관리합니다.", "Manage language and app launch behavior.")
        case .work: L("근무 시간과 휴게 시간을 설정합니다.", "Set your work and break hours.")
        case .history: L("저장된 출근 기록을 월별로 확인합니다.", "Browse saved arrivals by month.")
        case .calendar: L("반차 인식과 캘린더 동기화를 관리합니다.", "Manage half-day detection and calendar sync.")
        case .plugins: L("플러그인과 앱 기능의 연결을 관리합니다.", "Manage plugins and their connections to app features.")
        case .updates: L("앱 버전과 자동 업데이트를 관리합니다.", "Manage the app version and automatic updates.")
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsSection? = .general
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var calendarSync: CalendarSyncModel
    @ObservedObject var plugins: PluginManagerModel
    @ObservedObject var featureCalendar: FeatureCalendarModel
    let pluginPresentations: PluginSettingsPresentationRegistry
    @ObservedObject var navigation: SettingsNavigation
    @SettingsState private var showSyncSettings = false
    private let accent = Color(red: 0.16, green: 0.48, blue: 0.42)
    private var selectedLocale: Locale { _ = language.choice; return displayLocale }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("HappyLulu", systemImage: "clock")
                    .font(.headline).padding(.horizontal, 16).padding(.top, 20)
                List(SettingsSection.allCases, selection: $navigation.selection) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                        .padding(.vertical, 4)
                }
                .listStyle(.sidebar)
                .accessibilityLabel(L("설정 항목", "Settings sections"))
                Button(L("HappyLulu 종료", "Quit HappyLulu")) { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).padding(12)
            }
            .frame(width: 190)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selectedSection.title).font(.title.bold())
                        Text(selectedSection.subtitle).foregroundStyle(.secondary)
                    }
                    switch selectedSection {
                    case .general: generalSection
                    case .work: workSection
                    case .history: historySection
                    case .calendar:
                        Picker(L("캘린더 화면", "Calendar view"), selection: $showSyncSettings) {
                            Text(L("일정", "Events")).tag(false)
                            Text(L("동기화 설정", "Sync settings")).tag(true)
                        }.pickerStyle(.segmented)
                        if showSyncSettings {
                            calendarSection
                            CalendarSyncSettingsView(model: calendarSync)
                        } else {
                            FeatureCalendarView(model: featureCalendar, plugins: plugins, sync: calendarSync,
                                onOpenSettings: { navigation.selection = .plugins })
                        }
                    case .plugins: PluginSettingsView(model: plugins, presentations: pluginPresentations,
                        onOpenCalendarSettings: { showSyncSettings = true; navigation.selection = .calendar })
                    case .updates: updatesSection
                    }
                    if let error = model.errorMessage {
                        Label(visibleMessage(error), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            .id(selectedSection)
        }
        .frame(minWidth: 820, minHeight: 620)
        .onAppear { model.refresh(); calendarSync.prepareForDisplay() }
        .tint(accent)
        .environment(\.locale, selectedLocale)
    }

    private var selectedSection: SettingsSection { navigation.selection ?? .general }

    private var generalSection: some View {
        GroupBox(L("일반", "General")) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(L("언어", "Language"), selection: Binding(
                    get: { language.choice }, set: { language.select($0) })) {
                    ForEach(LanguageChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                Picker(L("퇴근까지 남은 시간 표시", "Countdown display"), selection: Binding(
                    get: { model.countdownDisplay }, set: { model.setCountdownDisplay($0) })) {
                    ForEach(CountdownDisplay.allCases, id: \.self) { choice in
                        Text(choice.displayLabel).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                Text(L("시간은 0.1시간씩, 다른 단위는 선택한 단위로 올림합니다. 밀리초는 0.1초마다 갱신합니다.", "Hours round up in 0.1-hour steps; other units round up to the selected unit. Milliseconds refresh every 0.1 seconds."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("로그인 시 자동 실행", "Launch at login"), isOn: Binding(
                    get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                    .toggleStyle(.switch).disabled(!model.allowsLoginItemChanges)
                Text(model.loginDescription).foregroundStyle(.secondary)
                if model.loginStatus == .requiresApproval {
                    Button(L("시스템 설정에서 허용", "Allow in System Settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AttendanceCalendarView(model: model)
            Button(L("기록 폴더 열기", "Open records folder")) { model.showData() }
        }
    }

    private var workSection: some View {
        GroupBox(L("근무", "Work")) {
            VStack(alignment: .leading, spacing: 12) {
                TodayDayTypeView(model: model)
                AttendanceControlsView(model: model)
                Divider()
                Stepper(L("근무  \(model.duration(model.state.settings.workMinutes))", "Work  \(model.duration(model.state.settings.workMinutes))"), value: Binding(
                    get: { model.state.settings.workMinutes },
                    set: { model.updateSettings(work: $0, rest: model.state.settings.breakMinutes) }
                ), in: 60...960, step: 30)
                Stepper(L("휴게  \(model.duration(model.state.settings.breakMinutes))", "Break  \(model.duration(model.state.settings.breakMinutes))"), value: Binding(
                    get: { model.state.settings.breakMinutes },
                    set: { model.updateSettings(work: model.state.settings.workMinutes, rest: $0) }
                ), in: 0...240, step: 15)
                Text(L("오늘 퇴근 예정에도 바로 반영됩니다. 잠금·절전 중에도 시간이 흘러갑니다.", "Changes affect today’s departure immediately. Time continues while the Mac is locked or asleep."))
                    .foregroundStyle(.secondary)
                Text(L("매달 마지막 금요일에는 퇴근 예정이 2시간 빨라집니다. 반차는 휴게 없이 출근 4시간 뒤 퇴근하며, 마지막 금요일 단축과 중복 적용하지 않아요.", "On the last Friday of each month, departure is 2 hours earlier. A half-day ends 4 hours after arrival with no break or additional Friday reduction."))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var calendarSection: some View {
        GroupBox(L("캘린더", "Calendar")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L("캘린더 반차 자동 인식", "Detect half-days from calendar"), isOn: Binding(
                    get: { model.state.detectHalfDaysFromCalendar },
                    set: { model.setCalendarHalfDayDetection($0) }))
                    .toggleStyle(.switch)
                Text(plugins.router.selectedID(for: .halfDay) == plugins.router.defaultID
                     ? L("접근 가능한 Mac 캘린더의 '오전 반차'·'오후 반차' 제목을 읽습니다. 공유 캘린더의 다른 사람 반차도 확인해 주세요. 일정이 모호하면 출근 시각으로 판단해요.", "Reads morning and afternoon off titles from accessible Mac calendars. Check shared calendars for other people’s leave. Ambiguous events fall back to arrival time.")
                     : L("\(plugins.adapterName(plugins.router.selectedID(for: .halfDay))) 일정의 '오전 반차'·'오후 반차' 제목을 읽습니다. 일반 연차에서 반차 유형을 추정하지 않으며, 직접 지정한 근무 유형은 유지합니다.", "Reads explicit morning/afternoon off titles from \(plugins.adapterName(plugins.router.selectedID(for: .halfDay))). Leave amounts do not imply a half-day type. Manual workday choices are preserved."))
                    .foregroundStyle(.secondary)
                if model.state.detectHalfDaysFromCalendar {
                    Button(L("반차 일정 다시 확인", "Check half-day events again")) { model.checkCalendarHalfDayNow() }
                }
                if let message = model.calendarHalfDayMessage {
                    Text(visibleMessage(message)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var updatesSection: some View {
        GroupBox(L("업데이트 · \(updater.version)", "Updates · \(updater.version)")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("서명된 새 버전을 앱에서 받아 설치합니다. 출근 기록과 설정은 유지됩니다.", "Downloads and installs signed updates in the app, preserving your records and settings."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("새 버전 자동 확인", "Automatically check for updates"), isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.setAutomaticallyChecks($0) }))
                    .disabled(!updater.canCheckForUpdates)
                Toggle(L("자동 다운로드 및 설치", "Automatically download and install"), isOn: Binding(
                    get: { updater.automaticallyInstalls },
                    set: { updater.setAutomaticallyInstalls($0) }))
                    .disabled(!updater.canCheckForUpdates || updater.isPreparingInstallation || !updater.automaticallyChecks)
                Text(L("자동 확인을 켜면 1시간마다 새 버전을 찾습니다. 자동 설치를 켜면 창을 닫고 출근 처리·캘린더 동기화가 끝난 뒤 앱이 자동으로 재시작됩니다. 끄면 설치 전에 확인합니다. 설치 준비가 끝나면 재시작까지 설정을 잠시 바꿀 수 없습니다.", "When enabled, checks for updates hourly. With automatic installation on, the app restarts after its windows are closed and attendance/calendar work has finished. Otherwise, installation asks for confirmation. Once installation is prepared, settings are locked until restart."))
                    .foregroundStyle(.secondary)
                Button(L("지금 업데이트 확인", "Check for updates now")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                if let error = updater.startupError {
                    Text(visibleMessage(error)).foregroundStyle(.orange)
                }
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }
}
