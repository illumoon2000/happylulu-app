import SwiftUI
import AIUsagePlugin

public struct AIUsageSettingsView: View {
    @ObservedObject private var model: AIUsageModel
    public init(model: AIUsageModel) { self.model = model }
    private func t(_ ko: String, _ en: String) -> String { model.text(ko, en) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox(t("Codex 사용량", "Codex usage")) {
                VStack(alignment: .leading, spacing: 12) {
                    row(t("주간 잔여량", "Weekly remaining"), value: model.snapshot.map { "\($0.weekly.remainingPercent)%" } ?? "—")
                    HStack {
                        Text(t("초기화", "Resets")); Spacer()
                        if let reset = model.snapshot?.weekly.resetDate {
                            Text(reset, format: .dateTime.month().day().hour().minute()).monospacedDigit()
                        } else { Text("—") }
                    }
                    row(t("시간당 소모율", "Hourly consumption"), value: model.analysis.hour.map {
                        String(format: "%.3f", $0.perHour) + t(" %p/시간", " pp/hour")
                    } ?? "—")
                    if let rate = model.analysis.hour {
                        Text(t("최근 \(Int(rate.observedMinutes))분 관측 기준", "Based on the last \(Int(rate.observedMinutes)) observed minutes"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let snapshot = model.snapshot {
                        HStack {
                            Text(t("마지막 조회", "Last updated")); Spacer()
                            Text(snapshot.fetchedAt, format: .dateTime.hour().minute()).monospacedDigit()
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    if model.isStale, model.snapshot != nil {
                        Text(t("이전 조회 값입니다.", "Showing the previous reading.")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = model.message {
                        Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button(t("지금 새로고침", "Refresh now")) { model.refreshData() }
                            .disabled(model.isRunning)
                        if model.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel(t("사용량 조회 중", "Reading usage")) }
                    }
                }.padding(8)
            }
            GroupBox(t("표시 및 갱신", "Display and refresh")) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(t("메뉴바 표시", "Menu bar label"), selection: Binding(
                        get: { model.preferences.labelFormat }, set: { value in model.updatePreferences { $0.labelFormat = value } })) {
                        Text("Codex + %").tag(LabelFormat.named)
                        Text(t("%만", "% only")).tag(LabelFormat.percentage)
                    }
                    Picker(t("갱신 주기", "Refresh interval"), selection: Binding(
                        get: { model.preferences.refreshMinutes }, set: { value in model.updatePreferences { $0.refreshMinutes = value } })) {
                        ForEach([1, 5, 10, 15, 30], id: \.self) { minutes in Text(t("\(minutes)분", "\(minutes) min")).tag(minutes) }
                    }
                    Toggle(t("잔여량 부족 알림", "Low allowance notification"), isOn: Binding(
                        get: { model.preferences.notificationsEnabled }, set: { model.setNotifications($0) })).toggleStyle(.switch)
                    if model.preferences.notificationsEnabled {
                        Picker(t("알림 기준", "Notify below"), selection: Binding(
                            get: { model.preferences.notificationThreshold }, set: { value in model.updatePreferences { $0.notificationThreshold = value } })) {
                            ForEach([10, 20, 30], id: \.self) { value in Text("\(value)%").tag(value) }
                        }
                    }
                }.padding(8)
            }
            DisclosureGroup(t("Codex 연결", "Codex connection")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.executablePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(t("실행 파일 선택", "Choose executable")) { model.chooseExecutable() }
                        if !model.preferences.cliPath.isEmpty {
                            Button(t("자동 찾기", "Find automatically")) { model.updatePreferences { $0.cliPath = "" } }
                        }
                    }.disabled(model.isLoggingIn)
                    if model.isLoggingIn {
                        Button(t("로그인 취소", "Cancel sign-in")) { model.cancelLogin() }
                    } else {
                        Button(model.snapshot == nil ? t("ChatGPT로 로그인", "Sign in with ChatGPT") : t("다른 계정으로 로그인", "Sign in with another account")) { model.login() }
                            .disabled(model.isRunning)
                    }
                    Text(t("기존 Codex 로그인을 사용합니다. 다른 계정으로 로그인하면 Codex CLI 계정도 변경됩니다.",
                           "Uses your existing Codex sign-in. Signing in with another account also changes the Codex CLI account."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 10)
            }
        }
    }
    private func row(_ title: String, value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit() }
    }
}
