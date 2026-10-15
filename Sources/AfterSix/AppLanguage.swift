import Combine
import Foundation
import AfterSixCore

enum LanguageChoice: String, CaseIterable, Identifiable {
    case system, korean, english

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: L("시스템 언어", "System language")
        case .korean: "한국어"
        case .english: "English"
        }
    }
}

@MainActor
final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()
    nonisolated static let key = "HappyLuluLanguage"

    @Published private(set) var choice: LanguageChoice

    private init() {
        choice = LanguageChoice(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "system") ?? .system
    }

    func select(_ choice: LanguageChoice) {
        UserDefaults.standard.set(choice.rawValue, forKey: Self.key)
        self.choice = choice
    }
}

private var selectedLanguage: LanguageChoice {
    LanguageChoice(rawValue: UserDefaults.standard.string(forKey: AppLanguage.key) ?? "system") ?? .system
}

private var usesEnglish: Bool {
    switch selectedLanguage {
    case .english: return true
    case .korean: return false
    case .system: return !(Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("ko")
    }
}

func L(_ korean: String, _ english: String) -> String { usesEnglish ? english : korean }

/// Models keep their existing Korean diagnostics. Translate only at display time
/// so a language change also updates a message produced before the change.
func visibleMessage(_ message: String) -> String {
    guard usesEnglish else { return message }
    let translations: [String: String] = [
        "기능 연결 설정을 읽지 못했습니다. 원본을 보존하고 기본 연결을 사용합니다.": "Could not read feature sources. The original file is preserved; using defaults.",
        "기능 연결을 저장하지 못했습니다. 연결 상태와 설정 파일 접근 권한을 확인해 주세요.": "Could not save the feature source. Check the connection and settings file access.",
        "기능 연결을 저장하지 못했습니다. 이번 실행에서는 기본 연결로 돌아갑니다.": "Could not save the feature source. Using the default for this session.",
        "플러그인을 등록하지 못했습니다. 기본 기능은 계속 사용할 수 있습니다.": "Could not register the plugin. Built-in features remain available.",
        "선택한 달은 연결의 조회 범위 밖입니다. 플러그인 설정에서 조회 가능한 기간을 확인해 주세요.": "This month is outside the source’s fetched range. Check the available dates in Plugins settings.",
        "플러그인의 조회 결과가 없습니다. 플러그인 설정에서 연결 상태를 확인하고 다시 조회해 주세요.": "No plugin data is available. Check its connection and fetch again in Plugins.",
        "선택한 기능 연결을 사용할 수 없습니다. 플러그인 설정을 확인해 주세요.": "This feature source is unavailable. Check Plugins settings.",
        "날짜가 바뀌었습니다. 입력 창을 다시 열어 주세요.": "The date changed. Reopen the editor.",
        "캘린더 접근을 허용해야 반차 일정을 자동 인식할 수 있습니다.": "Allow calendar access to detect half-day events automatically.",
        "캘린더 반차와 기록된 출근 시각이 맞지 않아 출근 시각으로 다시 판단했어요. 필요하면 근무 유형을 직접 지정해 주세요.": "The calendar half-day conflicts with the recorded arrival. The workday type was recalculated from arrival; choose it manually if needed.",
        "명확한 오전·오후 반차 일정이 없어요. 출근 시각으로 판단합니다.": "No clear half-day event found. Using arrival time.",
        "동기화를 시작한 뒤에는 캘린더 쌍을 바꿀 수 없습니다. 기존 중복 방지 기록을 보존하고 있어요.": "Calendar selection cannot change after syncing starts. Existing duplicate-prevention records are preserved.",
        "다우오피스와 Google에 서로 다른 캘린더를 선택해 주세요.": "Select different calendars for Daouoffice and Google.",
        "서로 다른 다우오피스·Google 계정의 캘린더인지 확인해 주세요.": "Confirm the calendars belong to separate Daouoffice and Google accounts.",
        "쓸 수 있는 시스템 캘린더가 없습니다. 인터넷 계정에서 계정을 추가해 주세요.": "No writable system calendars found. Add accounts in Internet Accounts.",
        "첫 일정 저장 결과가 확인되지 않아 다른 일정 반영을 보류했어요.": "The first event save could not be confirmed, so other events were held.",
        "미리보기 완료 · 시스템 캘린더는 변경하지 않았어요.": "Preview complete · system calendars unchanged.",
        "다우오피스 캘린더 내용으로 충돌을 해결했어요.": "Conflict resolved using the Daouoffice calendar.",
        "Google 캘린더 내용으로 충돌을 해결했어요.": "Conflict resolved using the Google calendar.",
        "자동 동기화가 켜져 있어요.": "Automatic sync is on.",
        "자동 동기화가 일시 중지되어 있어요. 새 미리보기를 확인한 뒤 다시 시작해 주세요.": "Automatic sync is paused. Review a new preview, then resume.",
        "동기화할 캘린더를 선택하고 미리보기를 먼저 확인해 주세요.": "Select calendars and review a preview first.",
        "자동 동기화를 일시 중지했어요. 새 미리보기를 확인한 뒤 다시 시작할 수 있어요.": "Automatic sync paused. You can resume after reviewing a new preview.",
        "자동 동기화를 일시 중지했어요.": "Automatic sync paused.",
        "자동 동기화를 다시 시작했어요.": "Automatic sync resumed.",
        "업데이트 설정을 확인하지 못했어요. 제작자에게 알려 주세요.": "Could not check update settings. Please contact the developer.",
        "오늘의 지난 시각을 입력해 주세요. 일반·오후 반차는 08:00~10:00, 오전 반차는 13:00~15:00입니다.": "Enter an earlier time today. Regular and afternoon off arrivals are 08:00–10:00; morning off arrivals are 13:00–15:00.",
        "근무는 1~16시간, 휴게는 0~4시간으로 설정해 주세요.": "Set work to 1–16 hours and break to 0–4 hours.",
        "기록 파일을 읽을 수 없습니다. 원본을 보존했습니다.": "The records file could not be read. The original was preserved.",
        "동기화할 캘린더 두 개를 먼저 선택해 주세요": "Select two calendars to sync first.",
        "처음 동기화할 내용을 먼저 확인해 주세요": "Review the first sync preview before continuing.",
        "캘린더 동기화가 이미 진행 중입니다": "Calendar sync is already running.",
        "미리보기 이후 일정이 바뀌었거나 이전 미리보기의 안전 정보를 확인할 수 없습니다. 새 미리보기를 확인한 뒤 다시 시작해 주세요": "Events changed after the preview, or its safety information is unavailable. Review a new preview and try again.",
        "충돌 확인 이후 일정이 바뀌었습니다. 미리보기를 다시 확인한 뒤 적용할 내용을 선택해 주세요": "Events changed after conflict review. Refresh the preview before choosing a version.",
        "캘린더 목록이 완전히 조회되지 않았습니다": "The calendar list could not be loaded completely.",
        "캘린더 동기화 상태를 읽을 수 없습니다. 원본 파일을 보존했습니다": "Calendar sync state could not be read. The original file was preserved.",
        "선택한 시스템 캘린더를 찾을 수 없습니다": "The selected system calendar could not be found.",
        "선택한 캘린더에 일정을 쓸 수 없습니다": "The selected calendar is read-only.",
        "일정을 확인할 수 없습니다. 캘린더를 새로고침해 주세요.": "The event could not be found. Refresh calendars.",
        "일정이 확인하는 동안 변경됐습니다": "The event changed during verification.",
        "일정 날짜를 읽을 수 없습니다": "The event date could not be read.",
        "날짜 오류로 일정 저장을 시작하지 못했습니다": "The event save could not start because its date is invalid.",
        "이전 일정 저장 결과를 확인할 수 없어 재시도를 보류했어요. 캘린더에서 복사된 일정을 확인해 주세요.": "The previous event save could not be confirmed, so retry was held. Check the calendar for a copied event.",
        "동기화 대상이 일치하지 않습니다": "The sync target does not match.",
        "동기화 일정 ID가 이미 사용 중입니다": "The synced event ID is already in use.",
        "캘린더 서버의 응답을 확인할 수 없습니다": "No response from the calendar server.",
        "다우오피스 HTTPS 주소를 확인해 주세요": "Check the Daouoffice HTTPS address.",
        "다우오피스 계정 연결이 필요합니다": "Connect a Daouoffice account.",
        "다우오피스 CalDAV 응답을 읽을 수 없습니다": "The Daouoffice CalDAV response could not be read.",
        "선택한 캘린더 주소가 계정 범위를 벗어납니다": "The selected calendar address is outside this account.",
        "이 일정 유형은 자동 동기화 대상이 아닙니다": "This event type cannot be synced automatically.",
        "일정 내용을 읽을 수 없습니다": "The event content could not be read.",
        "서버의 일정 버전을 확인할 수 없습니다": "The server event version could not be verified.",
        "저장된 인증 정보를 읽을 수 없습니다": "Saved account credentials could not be read.",
        "Mac 캘린더 접근을 허용해 주세요": "Allow Mac calendar access.",
        "CalDAV 계정을 찾을 수 없습니다": "CalDAV account not found.",
        "CalDAV 캘린더 목록을 찾을 수 없습니다": "CalDAV calendar list not found.",
        "Google 캘린더 응답을 읽을 수 없습니다": "Google Calendar response could not be read.",
        "Google 캘린더 선택을 확인해 주세요": "Check the Google Calendar selection.",
        "Google 데스크톱 OAuth 클라이언트 ID가 필요합니다": "A Google desktop OAuth client ID is required.",
        "Google 로그인 브라우저를 열 수 없습니다": "Could not open the Google sign-in browser.",
        "Google 로그인 응답을 받을 수 없습니다": "Could not receive the Google sign-in response.",
        "Google 로그인이 취소되었습니다": "Google sign-in was cancelled.",
        "Google 로그인 확인 값이 일치하지 않습니다": "Google sign-in verification did not match.",
        "Google 로그인 응답을 읽을 수 없습니다": "Could not read the Google sign-in response.",
        "Google 계정을 다시 연결해 주세요": "Reconnect your Google account.",
        "HTTPS 캘린더 주소가 필요합니다": "An HTTPS calendar address is required.",
        "일반 근무": "Regular workday",
        "오전 반차": "Morning off",
        "오후 반차": "Afternoon off"
    ]
    if let translation = translations[message] { return translation }
    for (prefix, english) in [
        ("시스템 캘린더 ", "System calendars found: "),
        ("동기화 확인 필요 · ", "Sync needs review · "),
        ("동기화 완료 · ", "Sync complete · "),
        ("지난 동기화 오류: ", "Previous sync error: "),
        ("캘린더 동기화 저장소 오류(", "Calendar sync storage error ("),
        ("Mac 키체인 오류(", "Mac Keychain error ("),
        ("캘린더 서버 응답 ", "Calendar server response ")
    ] where message.hasPrefix(prefix) {
        return english + String(message.dropFirst(prefix.count))
            .replacingOccurrences(of: "개를 찾았어요.", with: "")
            .replacingOccurrences(of: "건 반영", with: " applied")
            .replacingOccurrences(of: "건 보류", with: " held")
            .replacingOccurrences(of: "건 충돌", with: " conflicts")
            .replacingOccurrences(of: "건 제외", with: " excluded")
    }
    if message.hasPrefix("캘린더에서 "), message.hasSuffix("를 인식했어요.") {
        let name = message.dropFirst("캘린더에서 ".count).dropLast("를 인식했어요.".count)
        let translated = visibleMessage(String(name))
        return "Detected \(translated) in calendar."
    }
    if message.hasPrefix("저장하지 못했습니다: ") {
        return "Could not save: " + visibleMessage(String(message.dropFirst("저장하지 못했습니다: ".count)))
    }
    if message.hasPrefix("저장된 기록을 불러오지 못했습니다. 원본을 보존했으며 새 기록 저장을 중지했습니다. ") {
        return "Could not load saved records. The original was preserved and saving new records was stopped. " + visibleMessage(String(message.dropFirst("저장된 기록을 불러오지 못했습니다. 원본을 보존했으며 새 기록 저장을 중지했습니다. ".count)))
    }
    if message.hasPrefix("자동 실행 설정: ") {
        return "Launch at login: " + String(message.dropFirst("자동 실행 설정: ".count))
    }
    return message
}

var displayLocale: Locale {
    switch selectedLanguage {
    case .system: .autoupdatingCurrent
    case .korean: Locale(identifier: "ko_KR")
    case .english: Locale(identifier: "en_US")
    }
}

func displayDate(_ date: Date, dateStyle: DateFormatter.Style = .medium,
                 timeStyle: DateFormatter.Style = .short) -> String {
    let formatter = DateFormatter()
    formatter.locale = displayLocale
    formatter.dateStyle = dateStyle
    formatter.timeStyle = timeStyle
    return formatter.string(from: date)
}

func displayClock(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = displayLocale
    formatter.timeZone = timeZone
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

func displayDayKey(_ key: String) -> String {
    let fields = key.split(separator: "-").compactMap { Int($0) }
    guard fields.count == 3 else { return key }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    guard let date = calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2])) else { return key }
    return displayDate(date, timeStyle: .none)
}

extension WorkdayMode {
    var displayLabel: String {
        switch self {
        case .normal: L("일반 근무", "Regular workday")
        case .morningHalf: L("오전 반차", "Morning off")
        case .afternoonHalf: L("오후 반차", "Afternoon off")
        }
    }
}


extension CountdownDisplay {
    var displayLabel: String {
        switch self {
        case .milliseconds: L("밀리초", "Milliseconds")
        case .seconds: L("초", "Seconds")
        case .minutes: L("분", "Minutes")
        case .hours: L("시", "Hours")
        case .hoursMinutes: L("시/분 (기본)", "Hours/minutes (default)")
        }
    }
}
