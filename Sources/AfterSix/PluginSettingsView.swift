import SwiftUI
import AppPluginCore
import AppPluginHost

extension AppFeature {
    var title: String {
        switch self {
        case .calendar: L("캘린더 일정", "Calendar events")
        case .leave: L("휴가 현황", "Leave summary")
        case .halfDay: L("반차 자동 인식", "Half-day detection")
        }
    }
    var detail: String {
        switch self {
        case .calendar: L("캘린더 탭에 표시할 일정", "Events shown in the Calendar tab")
        case .leave: L("메뉴 패널과 캘린더의 연차 현황", "Leave shown in the menu panel and Calendar")
        case .halfDay: L("자동 인식을 켰을 때 읽을 반차 일정", "Half-day events read when detection is enabled")
        }
    }
}

private typealias PluginViewState<Value> = SwiftUI.State<Value>

struct PluginSettingsView: View {
    @ObservedObject var model: PluginManagerModel
    let presentations: PluginSettingsPresentationRegistry
    let onOpenCalendarSettings: () -> Void
    @PluginViewState private var selectedID: String? = "builtin"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox(L("앱 기능 연결", "Feature sources")) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("기능별로 사용할 연결을 선택합니다. 플러그인을 끄면 기본 연결로 돌아갑니다.",
                           "Choose a source for each feature. Disabling a plugin restores the default."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(AppFeature.allCases, id: \.self) { feature in
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(feature.title)
                                Text(feature.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Picker(feature.title, selection: Binding(
                                get: { model.router.selectedID(for: feature) },
                                set: { model.select($0, for: feature) })) {
                                ForEach(model.router.descriptors.filter {
                                    $0.features.contains(feature) && model.router.isEnabled($0.id)
                                }) { descriptor in
                                    Text(model.adapterName(descriptor.id)).tag(descriptor.id)
                                }
                            }.labelsHidden().frame(width: 180)
                            .disabled(!model.canChangeRoutes)
                            .accessibilityLabel(feature.title)
                        }
                    }
                    if let message = model.message {
                        Label(visibleMessage(message), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("등록된 플러그인", "Registered plugins")).font(.headline)
                    Spacer()
                    Text(L("\(model.registrations.count)개", "\(model.registrations.count) registered"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                List(selection: $selectedID) {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("HappyLulu 기본", "HappyLulu default"))
                            Text(L("출퇴근 기록 · Mac 캘린더", "Attendance · Mac calendars"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(L("기본", "Default")).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 7).tag(model.router.defaultID)
                    ForEach(model.registrations) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: entry.symbol).frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.controller.descriptor.name)
                                Text(L(entry.summaryKorean, entry.summaryEnglish)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.controller.isRunning { ProgressView().controlSize(.small) }
                            Text(status(entry.controller.connectionState)).font(.caption)
                                .foregroundStyle(entry.controller.connectionState == .attention ? .orange : .secondary)
                        }.padding(.vertical, 7).tag(entry.id)
                    }
                }
                .listStyle(.inset).frame(height: min(300, CGFloat(model.registrations.count + 1) * 64 + 12))
                .accessibilityLabel(L("등록된 연결 목록", "Registered connections"))
            }

            if let entry = model.registrations.first(where: { $0.id == selectedID }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.controller.descriptor.name).font(.title2.bold())
                    Text(entry.adapter.descriptor.features.sorted { $0.rawValue < $1.rawValue }
                        .map(\.title).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if let settings = presentations.view(for: entry.id) { settings }
                    else { Text(L("이 플러그인은 별도 설정이 없습니다.", "This plugin has no additional settings.")) }
                }.id(entry.id)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("HappyLulu 기본", "HappyLulu default")).font(.title2.bold())
                    Text(L("이 Mac의 출퇴근 기록과 연결된 캘린더를 사용합니다. 근무 시간과 수동 출근은 기존 근무 설정을 따릅니다.",
                           "Uses attendance on this Mac and its connected calendars, with your existing work settings."))
                        .foregroundStyle(.secondary)
                    Button(L("Mac 캘린더 설정 열기", "Open Mac calendar settings"), action: onOpenCalendarSettings)
                        .buttonStyle(.bordered).tint(.primary).foregroundStyle(.primary)
                    Text(L("연차 현황을 보려면 휴가 정보를 제공하는 플러그인을 연결해 주세요.",
                           "Connect a plugin that provides leave data to see an annual leave summary."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: model.registrations.map(\.id)) { ids in
            if let selectedID, selectedID != model.router.defaultID, !ids.contains(selectedID) {
                self.selectedID = model.router.defaultID
            }
        }
    }
    private func status(_ state: PluginConnectionState) -> String {
        switch state {
        case .off: L("사용 안 함", "Off")
        case .setup: L("설정 필요", "Needs setup")
        case .connecting: L("연결 중", "Connecting")
        case .ready: L("연결됨", "Connected")
        case .attention: L("확인 필요", "Needs attention")
        }
    }
}
