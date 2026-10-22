import AppPluginHost
import SwiftUI
import ServiceManagement
import AfterSixCore

private typealias SettingsState<Value> = SwiftUI.State<Value>

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, work, history, calendar, plugins, plugin, updates

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: L("일반", "General")
        case .appearance: L("외관", "Appearance")
        case .plugin: L("플러그인 설정", "Plugin settings")
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
        case .appearance: "paintpalette"
        case .plugin: "puzzlepiece.extension"
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
        case .appearance: L("눈에 편한 색상과 앱 아이콘을 설정합니다.", "Customize comfortable colors and the app icon.")
        case .plugin: L("설치한 플러그인의 설정입니다.", "Settings for an installed plugin.")
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
    @Published var pluginID: String?
}

struct SettingsView: View {
    @ObservedObject private var appearance = AppearanceModel.shared
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var calendarSync: CalendarSyncModel
    @ObservedObject var plugins: PluginManagerModel
    @ObservedObject var featureCalendar: FeatureCalendarModel
    let pluginPresentations: PluginSettingsPresentationRegistry
    @ObservedObject var navigation: SettingsNavigation
    @SettingsState private var showSyncSettings = false
    private var accent: Color { appearance.accent }
    private var selectedLocale: Locale { _ = language.choice; return displayLocale }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(nsImage: appearance.iconImage).resizable().frame(width: 24, height: 24)
                    Text("HappyLulu").font(.headline)
                }.padding(.horizontal, 16).padding(.top, 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("기본 설정", "Core settings")).font(.caption).foregroundStyle(.secondary).padding(8)
                        ForEach([SettingsSection.general, .appearance, .work, .history, .updates]) { section in
                            sidebarButton(section.title, symbol: section.symbol,
                                          selected: selectedSection == section) { navigation.selection = section }
                        }
                        sidebarButton(L("플러그인 관리", "Manage plugins"), symbol: "puzzlepiece.extension",
                                      selected: selectedSection == .plugins) { navigation.selection = .plugins }
                            .padding(.top, 12)
                        Divider().padding(.vertical, 12)
                        Text(L("설치된 플러그인", "Installed plugins")).font(.caption).foregroundStyle(.secondary).padding(8)
                        ForEach(plugins.installed) { entry in
                            sidebarButton(entry.name, symbol: entry.symbol,
                                          selected: selectedSection == .plugin && navigation.pluginID == entry.id) {
                                navigation.pluginID = entry.id; navigation.selection = .plugin
                            }
                        }
                        if plugins.installed.isEmpty {
                            Text(L("설치된 항목이 없어요", "No plugins installed")).font(.caption).foregroundStyle(.secondary).padding(8)
                        }
                    }.padding(.horizontal, 10)
                }.accessibilityLabel(L("설정 항목", "Settings sections"))
                Button(L("HappyLulu 종료", "Quit HappyLulu")) { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).padding(12)
            }
            .frame(width: 205).background(appearance.sidebar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if selectedSection != .plugin && selectedSection != .calendar {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(selectedSection == .plugins ? L("플러그인 관리", "Manage plugins") : selectedSection.title).font(.title.bold())
                            Text(selectedSection == .plugins ? L("필요한 기능만 추가해 사용하세요.", "Add only the features you need.") : selectedSection.subtitle).foregroundStyle(.secondary)
                        }
                    }
                    switch selectedSection {
                    case .general: generalSection
                    case .work: workSection
                    case .history: historySection
                    case .appearance: AppearanceSettingsView(appearance: appearance)
                    case .calendar:
                        pluginDetail(calendarPluginID)
                    case .plugin:
                        pluginDetail(navigation.pluginID ?? "")
                    case .plugins:
                        PluginSettingsView(model: plugins, presentations: pluginPresentations,
                            onOpenPlugin: { id in navigation.pluginID = id; navigation.selection = .plugin },
                            onInstall: installPlugin, onSetEnabled: setPluginEnabled,
                            needsSetup: { $0 == "leave-detection" && plugins.isEnabled($0) && !model.state.detectHalfDaysFromCalendar })
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
            .id("\(selectedSection.rawValue)|\(navigation.pluginID ?? "")")
            .background(appearance.background)
        }
        .frame(minWidth: 820, minHeight: 620)
        .onAppear { model.refresh() }
        .foregroundStyle(appearance.text)
        .background(appearance.background)
        .preferredColorScheme(appearance.isDark ? .dark : .light)
        .groupBoxStyle(LuluSettingsGroupBoxStyle(surface: appearance.surface))
        .tint(accent)
        .environment(\.locale, selectedLocale)
    }

    private var selectedSection: SettingsSection { navigation.selection ?? .general }

    private func sidebarButton(_ title: String, symbol: String, selected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
                .background(selected ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func installPlugin(_ id: String) {
        plugins.install(id)
        if id == "leave-detection", plugins.isEnabled(id) { model.setCalendarHalfDayDetection(true) }
    }

    private func setPluginEnabled(_ id: String, _ enabled: Bool) {
        plugins.setEnabled(id, enabled)
        if id == "leave-detection", plugins.isEnabled(id) == enabled { model.setCalendarHalfDayDetection(enabled) }
    }

    private var calendarPluginID: String {
        let id = plugins.router.selectedID(for: .calendar)
        return plugins.catalog.contains(where: { $0.id == id }) ? id : "mac-calendar"
    }

    @ViewBuilder private func pluginDetail(_ id: String) -> some View {
        if let entry = plugins.catalog.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 6) {
                Label(entry.name, systemImage: entry.symbol).font(.title.bold())
                Text(L("개발자 · \(entry.author)", "Developer · \(entry.author)")).font(.caption).foregroundStyle(.secondary)
                Text(entry.summary).foregroundStyle(.secondary)
            }
            if plugins.isInstalled(id) {
                Toggle(L("플러그인 사용", "Use plugin"), isOn: Binding(
                    get: { plugins.isEnabled(id) }, set: { setPluginEnabled(id, $0) }))
                    .toggleStyle(.switch).disabled(!plugins.canChangeCatalog)
                if plugins.isEnabled(id) {
                    if id == "mac-calendar" {
                        Picker(L("캘린더 화면", "Calendar view"), selection: $showSyncSettings) {
                            Text(L("일정", "Events")).tag(false)
                            Text(L("동기화 설정", "Sync settings")).tag(true)
                        }.pickerStyle(.segmented)
                        if showSyncSettings {
                            CalendarSyncSettingsView(model: calendarSync)
                                .onAppear { calendarSync.prepareForDisplay() }
                        } else {
                            FeatureCalendarView(model: featureCalendar, plugins: plugins, sync: calendarSync,
                                onOpenSettings: { navigation.selection = .plugins })
                        }
                        FeatureSourceSettingsView(model: plugins, features: [.calendar])
                    } else if id == "leave-detection" {
                        calendarSection
                        FeatureSourceSettingsView(model: plugins, features: [.halfDay])
                    } else {
                        if let settings = pluginPresentations.view(for: id) { settings }
                        else { Text(L("이 플러그인은 별도 설정이 없습니다.", "This plugin has no additional settings.")) }
                        if let registration = plugins.registrations.first(where: { $0.id == id }),
                           !registration.adapter.descriptor.features.isEmpty {
                            FeatureSourceSettingsView(model: plugins,
                                features: [.calendar, .leave].filter { registration.adapter.descriptor.features.contains($0) })
                        }
                    }
                } else {
                    Text(L("사용 안 함 · 연결 설정과 기록은 보존됩니다.", "Off · connection settings and records are preserved."))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(L("설치", "Install")) { installPlugin(id) }
                    .disabled(!entry.available || !plugins.canChangeCatalog)
            }
            if let message = plugins.message {
                Label(visibleMessage(message), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } else {
            Text(L("플러그인 관리에서 기능을 추가해 주세요.", "Add a feature in plugin management."))
            Button(L("플러그인 관리", "Manage plugins")) { navigation.selection = .plugins }
        }
    }

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
                Divider()
                Text(L("표시 옵션", "Display options")).font(.headline)
                Picker(L("퇴근까지 남은 시간 표시", "Countdown display"), selection: Binding(
                    get: { model.countdownDisplay }, set: { model.setCountdownDisplay($0) })) {
                    ForEach(CountdownDisplay.allCases, id: \.self) { choice in
                        Text(choice.displayLabel).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                Text(L("시간은 0.1시간씩, 다른 단위는 선택한 단위로 올림합니다. 밀리초는 0.1초마다 갱신합니다.", "Hours round up in 0.1-hour steps; other units round up to the selected unit. Milliseconds refresh every 0.1 seconds."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("메뉴바에 퇴근 예정 시각 표시", "Show expected departure in menu bar"), isOn: Binding(
                    get: { model.showDepartureInMenuBar }, set: { model.setShowDepartureInMenuBar($0) }))
                    .toggleStyle(.switch)
                Text(L("꺼도 남은 시간과 선택한 표시 단위는 유지됩니다.", "The countdown and selected time format remain when turned off."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("사용량 보기", "Show usage"), isOn: Binding(
                    get: { plugins.showUsage }, set: { plugins.setShowUsage($0) }))
                    .toggleStyle(.switch).disabled(!plugins.canShowUsage)
                if plugins.showUsage, let id = plugins.usagePluginID {
                    Button(L("사용량 설정", "Usage settings")) {
                        navigation.pluginID = id; navigation.selection = .plugin
                    }
                }
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
                Text(plugins.router.selectedID(for: .halfDay) == "mac-calendar"
                     ? L("접근 가능한 Mac 캘린더의 '오전 반차'·'오후 반차' 제목을 읽습니다. 공유 캘린더의 다른 사람 반차도 확인해 주세요. 일정이 모호하면 출근 시각으로 판단해요.", "Reads morning and afternoon off titles from accessible Mac calendars. Check shared calendars for other people’s leave. Ambiguous events fall back to arrival time.")
                     : L("\(plugins.adapterName(plugins.router.selectedID(for: .halfDay))) 일정의 '오전 반차'·'오후 반차' 제목을 읽습니다. 일반 연차에서 반차 유형을 추정하지 않으며, 직접 지정한 근무 유형은 유지합니다.", "Reads explicit morning/afternoon off titles from \(plugins.adapterName(plugins.router.selectedID(for: .halfDay))). Leave amounts do not imply a half-day type. Manual workday choices are preserved."))
                    .foregroundStyle(.secondary)
                if !model.state.detectHalfDaysFromCalendar {
                    Label(L("설정 필요 · 일정 연결과 읽기 권한을 확인한 뒤 자동 인식을 시작하세요.", "Setup required · choose a source and grant read access, then start detection."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button(L("자동 인식 시작", "Start automatic detection")) { model.setCalendarHalfDayDetection(true) }
                }
                Button(L("연결·권한 다시 확인", "Check source and permissions")) { model.setCalendarHalfDayDetection(true) }
                if model.state.detectHalfDaysFromCalendar {
                    Button(L("반차 일정 새로고침", "Refresh half-day events")) { model.checkCalendarHalfDayNow() }
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

private struct LuluSettingsGroupBoxStyle: GroupBoxStyle {
    let surface: Color
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.headline)
            configuration.content
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
