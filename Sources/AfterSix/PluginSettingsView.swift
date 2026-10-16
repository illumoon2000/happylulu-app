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

struct PluginSettingsView: View {
    @ObservedObject var model: PluginManagerModel
    let presentations: PluginSettingsPresentationRegistry
    let onOpenPlugin: (String) -> Void
    let onInstall: (String) -> Void
    let onSetEnabled: (String, Bool) -> Void
    let needsSetup: (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.catalog) { entry in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 13) {
                        Image(systemName: entry.symbol).font(.title3).frame(width: 36, height: 36)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name).font(.headline)
                            Text(L("개발자 · \(entry.author)", "Developer · \(entry.author)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if model.isInstalled(entry.id) {
                            Button(L("설정", "Settings")) { onOpenPlugin(entry.id) }
                            Toggle(L("\(entry.name) 사용", "Use \(entry.name)"), isOn: Binding(
                                get: { model.isEnabled(entry.id) }, set: { onSetEnabled(entry.id, $0) }))
                                .labelsHidden().toggleStyle(.switch).disabled(!model.canChangeCatalog)
                                .accessibilityLabel(L("\(entry.name) 사용", "Use \(entry.name)"))
                        } else {
                            Button(L("설치", "Install")) { onInstall(entry.id) }
                                .disabled(!entry.available || !model.canChangeCatalog)
                                .accessibilityLabel(L("\(entry.name) 설치", "Install \(entry.name)"))
                        }
                    }
                    Text(entry.summary).font(.callout).foregroundStyle(.secondary)
                    if needsSetup(entry.id) {
                        Label(L("설정 필요 · 연결과 권한을 확인해 주세요.", "Setup required · check the source and permissions."), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !entry.available {
                        Text(L("이 빌드에서는 제공되지 않습니다.", "Not available in this build."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 19)
                Divider()
            }
            if let message = model.message {
                Label(visibleMessage(message), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).padding(.top, 16)
            }
        }
    }
}

struct FeatureSourceSettingsView: View {
    @ObservedObject var model: PluginManagerModel
    let features: [AppFeature]
    var body: some View {
        GroupBox(L("기능 연결", "Feature sources")) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(features, id: \.self) { feature in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(feature.title)
                            Text(feature.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker(feature.title, selection: Binding(
                            get: { model.router.selectedID(for: feature) },
                            set: { model.select($0, for: feature) })) {
                            Text(L("연결 안 함", "Not connected")).tag(model.router.defaultID)
                            ForEach(model.router.descriptors.filter {
                                $0.id != model.router.defaultID && $0.features.contains(feature) && model.router.isEnabled($0.id)
                            }) { descriptor in
                                Text(model.adapterName(descriptor.id)).tag(descriptor.id)
                            }
                        }.labelsHidden().frame(width: 180).disabled(!model.canChangeRoutes)
                            .accessibilityLabel(feature.title)
                    }
                }
            }.padding(8)
        }
    }
}
