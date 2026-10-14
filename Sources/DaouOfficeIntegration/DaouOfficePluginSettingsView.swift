import SwiftUI
import AppKit
import AppPluginCore
import AppPluginHost

struct DaouOfficePluginSettingsView: View {
    @ObservedObject var model: DaouOfficePluginModel
    var localize: PluginLocalizer = { korean, _ in korean }
    private func L(_ korean: String, _ english: String) -> String { localize(korean, english) }
    @State private var showingVacations = true
    @FocusState private var captchaFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(L("다우오피스 연결", "Connect Daouoffice"), isOn: Binding(
                        get: { model.enableRequested }, set: { model.setEnableRequested($0) }))
                        .toggleStyle(.switch)
                    Text(L("내 휴가와 캘린더 일정을 백그라운드에서 가져옵니다.", "Fetches your leave and calendar events in the background."))
                        .foregroundStyle(.secondary)
                    if model.enableRequested {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("회사 다우오피스 주소", "Company Daouoffice address"))
                            TextField("https://company.daouoffice.com/", text: $model.address)
                                .disabled(model.isRunning)
                                .accessibilityLabel(L("회사 다우오피스 주소", "Company Daouoffice address"))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("아이디", "ID"))
                            TextField(L("다우오피스 아이디", "Daouoffice ID"), text: $model.loginID)
                                .disabled(model.isRunning)
                                .textContentType(.username)
                                .accessibilityLabel(L("다우오피스 아이디", "Daouoffice ID"))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("비밀번호", "Password"))
                            SecureField(model.canUseSavedPassword ? L("저장된 비밀번호 사용 · 변경할 때만 입력", "Uses saved password · enter to change") : L("다우오피스 비밀번호", "Daouoffice password"), text: $model.password)
                                .disabled(model.isRunning)
                                .textContentType(.password)
                                .accessibilityLabel(L("다우오피스 비밀번호", "Daouoffice password"))
                        }
                        Text(L("비밀번호는 이 Mac의 키체인에 저장합니다. 저장 후 첫 조회를 시작하고, 15분마다 새로 확인합니다.", "The password is saved in this Mac’s Keychain. Saving starts the first fetch, then refreshes every 15 minutes."))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button(L("저장하고 조회", "Save and fetch")) { model.saveAndRefresh() }
                                .buttonStyle(.borderedProminent).disabled(!model.canSave)
                            if model.enabled {
                                Button(L("지금 다시 조회", "Refresh now")) { model.refresh() }
                                    .disabled(!model.canRefresh)
                            }
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }

            if let challenge = model.captchaChallenge {
                GroupBox(L("보안 문자 확인", "CAPTCHA verification")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("다우오피스에서 추가 확인을 요청했습니다. 이미지의 문자를 직접 입력하면 로그인을 이어갑니다.", "Daouoffice requires verification. Enter the characters in the image to continue signing in."))
                            .fixedSize(horizontal: false, vertical: true)
                        if model.captchaLoginRejected {
                            Label(L("로그인이 다시 거절되었습니다. 갱신된 이미지의 문자를 입력해 주세요.", "Sign-in was rejected. Enter the characters in the refreshed image."), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        if let image = NSImage(data: challenge.imageData) {
                            Image(nsImage: image)
                                .resizable().scaledToFit()
                                .frame(width: 260, height: 100)
                                .padding(10).background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                                .id(challenge.id)
                                .accessibilityLabel(L("다우오피스 보안 문자 이미지", "Daouoffice CAPTCHA image"))
                        } else {
                            Text(L("이미지를 표시하지 못했습니다. 새 이미지를 받아 주세요.", "Could not display the image. Request a new image."))
                                .foregroundStyle(.orange)
                        }
                        TextField(L("이미지의 보안 문자", "Characters in the image"), text: $model.captchaAnswer)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .focused($captchaFocused)
                            .disabled(model.isRunning)
                            .accessibilityLabel(L("보안 문자 입력", "Enter CAPTCHA characters"))
                            .onSubmit { model.submitCaptcha() }
                        HStack(spacing: 12) {
                            Button(L("확인하고 조회", "Verify and fetch")) { model.submitCaptcha() }
                                .buttonStyle(.borderedProminent).disabled(!model.canSubmitCaptcha)
                            Button(L("새 이미지", "New image")) { model.reloadCaptcha() }
                                .disabled(!model.canReloadCaptcha)
                            Button(L("취소", "Cancel")) { model.cancelCaptcha() }
                        }
                        Text(L("입력 대기 중에는 자동 조회를 멈춥니다. 보안 문자는 저장하지 않습니다.", "Automatic fetching pauses while waiting. CAPTCHA answers are not saved."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            } else if model.captchaRequired {
                GroupBox(L("보안 문자 확인", "CAPTCHA verification")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("다우오피스에서 보안 문자를 요청했지만 이미지를 받아오지 못했습니다.", "Daouoffice requires a CAPTCHA, but its image could not be loaded."))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button(L("이미지 다시 받기", "Retry image")) { model.refresh() }
                                .disabled(!model.canRefresh)
                            Button(L("취소", "Cancel")) { model.cancelCaptcha() }
                        }
                        Text(L("자동 조회는 입력을 완료할 때까지 멈춥니다.", "Automatic fetching pauses until verification is complete."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }

            if model.enableRequested || model.failure != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if model.isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.captchaChallenge != nil
                                ? L("로그인을 확인하고 있습니다…", "Verifying sign-in…")
                                : L("백그라운드에서 휴가와 일정을 조회하고 있습니다…", "Fetching leave and events in the background…"))
                        }
                    } else if let failure = model.failure, !(failure == .interactionRequired && model.captchaChallenge != nil) {
                        Label(message(failure), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else if model.snapshot == nil {
                        Text(L("연결 정보를 저장하면 조회 결과가 여기에 표시됩니다.", "Save your connection to see the results here."))
                            .foregroundStyle(.secondary)
                    }
                    if let snapshot = model.snapshot {
                        Text(L("마지막 성공", "Last successful fetch") + " · " + snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let next = model.nextRunAt {
                        Text(L("다음 조회", "Next fetch") + " · " + next.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.diagnostic != nil || model.lastLoginDiagnostic != nil {
                        DisclosureGroup(L("연결 진단", "Connection diagnostics")) {
                            VStack(alignment: .leading, spacing: 5) {
                                if let login = model.lastLoginDiagnostic {
                                    Text(L("마지막 로그인 응답", "Last sign-in response")).fontWeight(.semibold)
                                    Text("HTTP \(login.status)" + (login.code.map { " · " + $0 } ?? ""))
                                    if login.captchaRefreshRequired == true {
                                        Text(L("서버에서 새 보안 문자를 요청했습니다.", "The server requested a new CAPTCHA."))
                                    }
                                }
                                if let diagnostic = model.diagnostic, diagnostic != model.lastLoginDiagnostic {
                                    Text(diagnostic.path)
                                    Text("HTTP \(diagnostic.status)" + (diagnostic.code.map { " · " + $0 } ?? ""))
                                    Text(L("응답 필드: ", "Response fields: ") + diagnostic.fields.joined(separator: ", "))
                                }
                            }.font(.caption).textSelection(.enabled).padding(.top, 6)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let snapshot = model.snapshot {
                if let leave = snapshot.leave {
                    GroupBox(L("연차 현황", "Annual leave")) {
                        VStack(spacing: 10) {
                            balanceRow(L("잔여 연차", "Remaining"), leave.remainingDays)
                            balanceRow(L("사용 연차", "Used"), leave.usedDays)
                            balanceRow(L("총 연차", "Total"), leave.totalDays)
                        }.padding(8)
                    }
                }
                Picker(L("조회 결과", "Fetched data"), selection: $showingVacations) {
                    Text(L("휴가 내역", "Leave history")).tag(true)
                    Text(L("캘린더 일정", "Calendar events")).tag(false)
                }.pickerStyle(.segmented)
                Text(showingVacations
                    ? L("올해의 지난 휴가와 예정 휴가입니다. 승인 상태와 원본에 표시된 날짜를 그대로 보여줍니다.", "Past leave this year and upcoming leave, with the source status and dates.")
                    : L("이번 달 내 캘린더의 일정입니다. 출퇴근 기록과 시스템 캘린더는 변경하지 않습니다.", "This month’s events from your calendars. Attendance and system calendars are unchanged."))
                    .font(.caption).foregroundStyle(.secondary)
                if showingVacations {
                    if snapshot.vacations.isEmpty {
                        Text(L("조회 범위에 휴가 내역이 없습니다.", "No leave in the fetched range.")).foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.vacations) { leave in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(leave.kind).font(.headline)
                                Spacer()
                                Text(status(leave.status)).foregroundStyle(.secondary)
                            }
                            Text(leave.periodLabel).textSelection(.enabled)
                            Text(leave.durationLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                } else {
                    if snapshot.events.isEmpty {
                        Text(L("이번 달 일정이 없습니다.", "No events this month.")).foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.events) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.title).font(.headline)
                            Text(event.start.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened))
                                .foregroundStyle(.secondary)
                            if event.isAllDay { Text(L("종일", "All day")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Divider()
                    }
                }
            }
        }
        .onChange(of: model.captchaChallenge?.id) { id in captchaFocused = id != nil }
    }
    private func balanceRow(_ label: String, _ days: Double) -> some View {
        HStack { Text(label); Spacer(); Text(days.formatted(.number.precision(.fractionLength(0...2))) + L("일", " days")).monospacedDigit() }
    }
    private func status(_ value: String) -> String {
        switch value {
        case "APPROVAL": L("완료", "Approved")
        case "INPROGRESS": L("결재 중", "Pending")
        case "CREATE": L("작성", "Created")
        case "TEMPSAVE": L("임시 저장", "Draft")
        case "CANCEL": L("취소", "Cancelled")
        case "RETURN": L("반려", "Rejected")
        default: value
        }
    }
    private func message(_ failure: PluginFailure) -> String {
        switch failure {
        case .invalidAddress: L("회사 웹 주소를 확인해 주세요. https://로 시작하는 기본 주소를 입력합니다.", "Enter the company’s base address starting with https://.")
        case .missingCredentials: L("아이디와 비밀번호를 입력한 뒤 저장해 주세요.", "Enter your ID and password, then save.")
        case .authentication: L("로그인 또는 조회 권한을 확인하지 못했습니다. 연결 정보를 확인하고 다시 저장해 주세요.", "Could not authenticate or access the data. Check the connection and save again.")
        case .interactionRequired: L("추가 인증·비밀번호 변경 또는 기존 세션 확인이 필요합니다. 회사 웹에서 확인한 뒤 다시 조회해 주세요.", "Additional authentication, a password change or a session check is required. Complete it on the company website, then retry.")
        case .credentials: L("키체인 인증 정보를 읽거나 저장하지 못했습니다. 키체인 접근을 확인하고 다시 저장해 주세요.", "Could not read or save the password. Check Keychain access and save again.")
        case .configuration: L("연결 설정을 읽거나 저장하지 못했습니다. 설정 파일 접근 권한을 확인해 주세요.", "Could not read or save the connection. Check settings file access.")
        case .timeout, .network:
            model.nextRunAt != nil
                ? L("다우오피스에 연결하지 못했습니다. 잠시 후 자동으로 다시 조회합니다.", "Could not reach Daouoffice. The app will retry shortly.")
                : L("다우오피스에 연결하지 못했습니다. 연결을 확인한 뒤 직접 다시 시도해 주세요.", "Could not reach Daouoffice. Check the connection and retry.")
        case .unsupportedResponse:
            model.diagnostic?.status == 400
                ? L("다우오피스가 조회 요청을 거절했습니다 (HTTP 400). 연결 진단과 API 로그를 확인해 주세요.", "Daouoffice rejected the fetch request (HTTP 400). Check the connection diagnostic and API log.")
                : L("이 다우오피스 버전의 응답을 해석하지 못했습니다. 자동 조회를 멈췄습니다.", "This Daouoffice response is unsupported. Automatic fetching is paused.")
        default: L("조회하지 못했습니다. 연결 정보를 확인하고 다시 조회해 주세요.", "Could not fetch the data. Check the connection and retry.")
        }
    }
}
