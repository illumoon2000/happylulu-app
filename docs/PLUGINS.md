# 앱 내부 플러그인 · 다우오피스

Mac 1.5.15 build31의 선택 플러그인 안내입니다. 기본 출퇴근 기록·수동 시각·근무 유형 선택은 플러그인 없이 사용할 수 있습니다. Windows 1.5.13에는 이 플러그인 기능이 없습니다.

설정의 **플러그인 관리**에서 앱에 포함된 캘린더·다우오피스·휴가 자동 인식 모듈을 설치하거나 사용 여부를 바꿉니다. 외부 플러그인 파일을 내려받는 마켓은 아닙니다. 설치된 모듈의 설정은 사이드바 가로선 아래에 표시됩니다. 각 목록에 개발자를 표시하며 다우오피스는 **손정열**, 캘린더·휴가 자동 인식은 **HappyLulu contributors**입니다.

## 연결하기

설정 → **플러그인 관리**에서 다우오피스를 설치하고 사용을 켠 뒤 **설정**을 엽니다. **다우오피스 연결**을 켜고 회사의 기본 HTTPS 주소, 아이디, 비밀번호를 입력한 다음 **저장하고 조회**를 누릅니다. 저장 직후 첫 조회를 시작하고 앱이 실행되는 동안 15분마다 갱신합니다. 로그인 정보가 같은 경우 비밀번호 칸을 비워 두면 키체인의 저장된 비밀번호를 사용합니다. 회사 주소나 아이디를 바꾸면 해당 계정의 비밀번호가 필요합니다.

플러그인별 **기능 연결**에서 캘린더 일정·휴가 현황·반차 자동 인식의 출처를 각각 선택합니다. 기존 설정은 최초 업그레이드 때 캘린더 플러그인으로 이관하며, 명시적인 ‘연결 안 함’ 선택은 유지합니다. 로컬 출퇴근 기능은 별도 연결 없이 동작합니다. 다우오피스를 선택하면 같은 캘린더 화면에 회사 일정을 표시하며, 휴가 현황은 메뉴 패널과 캘린더에 잔여 연차를 표시합니다. 반차는 기존 자동 인식 옵션을 켠 상태에서 명시적인 '오전 반차'·'오후 반차' 일정 제목만 사용합니다. 연차 일수나 일반 휴가에서 반차 유형을 추정하지 않습니다. 직접 지정한 근무 유형은 유지합니다.

기능 선택은 `~/Library/Application Support/AfterSix/Plugins/feature-routing.json`에 저장합니다. 플러그인의 사용을 끄면 해당 기능은 실행 중 연결이 해제되지만 저장된 출처 선택은 보존하며, 모듈을 다시 켜면 복원합니다. 내부 등록 해제는 해당 모듈의 저장된 연결도 제거하는 별도 처리입니다. 명시적으로 ‘연결 안 함’을 선택한 기능은 임의로 복원하지 않습니다. 조회 중에 연결을 바꾸면 이전 연결의 늦은 응답은 화면과 출퇴근 처리에 반영하지 않습니다. 기능 라우터는 다른 기능의 연결 변경만으로 진행 중인 데이터 조회를 무효화하지 않습니다. 캘린더 화면의 갱신 작업은 기능 연결 상태가 바뀔 때 다시 실행될 수 있습니다. 회사 일정의 월 범위와 반차 날짜는 어댑터가 제공하는 회사 시간대를 사용합니다.

조회 결과는 잔여·사용·총 연차, **올해의 지난 휴가와 예정 휴가**, **이번 달 내 캘린더 일정**입니다. 마지막 성공과 다음 조회 시각을 표시합니다. 네트워크 오류에는 1분·5분·15분 간격으로 재시도하고, 인증·권한·지원하지 않는 응답에는 자동 재시도를 멈춥니다. 실패한 조회는 마지막 성공 데이터를 유지합니다. 연결을 끄면 요청을 취소하고 내부 API의 결과와 메모리 세션을 비웁니다. 저장된 연결 정보와 키체인 비밀번호는 재연결을 위해 유지합니다.

조회 실패 시 **연결 진단**에서 실패한 요청 경로·HTTP 상태·서버 코드·응답 필드 이름을 확인할 수 있습니다. 응답 값·비밀번호·쿠키·헤더 값은 진단에 저장하지 않으며 경로의 숫자 식별자는 가립니다. `open dist/HappyLulu.app --args --plugins`로 플러그인 설정을 바로 열 수 있습니다.

CAPTCHA가 필요한 경우 설정 화면에 서버가 제공한 **보안 문자 이미지**와 입력란이 나타납니다. 사람이 직접 문자를 입력하고 **확인하고 조회**를 누르면 같은 세션으로 로그인을 이어가고 휴가·일정을 조회합니다. **새 이미지**로 문자를 다시 발급하거나 **취소**할 수 있습니다. 취소 후 **지금 다시 조회**를 누르면 저장된 인증정보로 새 세션을 시작하며, 취소 자체로는 자동 로그인을 재시도하지 않습니다. 이미지와 입력값은 메모리에만 보관하며, 입력을 기다리는 동안 자동 조회를 멈춥니다. 이미지 요청에 실패해도 회사 로그인을 반복하지 않고 **이미지 다시 받기**로 같은 세션에서 재요청합니다. 회사 주소·아이디·비밀번호를 바꾸거나 연결을 끄면 이전 보안 문자와 대기 중 요청을 취소합니다.

**연결 진단**은 새 이미지를 받더라도 마지막 로그인 거절의 HTTP 상태·서버 코드·CAPTCHA 갱신 요청 여부를 유지합니다. CAPTCHA 제출에는 최초 로그인에 사용한 인증정보를 같은 세션의 메모리에서 사용하며, 성공·취소·영구 인증 실패에 해당 컨텍스트를 폐기합니다. 사람이 대기하는 사이 다른 저장소 변경으로 제출 비밀번호가 바뀌지 않도록 합니다.

앱은 별도 계정 세션으로 다우오피스 웹이 사용하는 백엔드 API를 호출합니다. 실제 연결은 macOS의 `/usr/bin/curl`로 검증한 요청 방식을 사용합니다. 요청 본문과 쿠키는 프로세스의 표준 입력으로만 전달하며 명령줄 인자·환경 변수·파일에 기록하지 않습니다. 쿠키는 연결 인스턴스의 메모리에만 보관하고 종료·취소 시 비웁니다. 화면 렌더링이나 브라우저 세션 가져오기는 필요하지 않습니다. 비밀번호는 `local.chanyoung.AfterSix.Plugins.DaouOffice` 키체인 서비스에 회사·아이디별로 저장합니다. 비밀번호를 제외한 활성화·주소·아이디 설정은 `~/Library/Application Support/AfterSix/Plugins/daouoffice.json`에 보관합니다. 휴가·일정 결과는 메모리에만 보관합니다.

## CPU 러너 개발 후보

로컬 개발 후보에는 기존 부엉이를 유지하면서 햄스터·토끼·고양이를 별도 메뉴바 항목으로 표시하는 선택형 플러그인을 추가했습니다. 설치·활성화는 기존 플러그인 목록을 사용하며, 일정·휴가·반차 연결에는 참여하지 않습니다. 현재 공개 Mac 1.5.19에는 포함되지 않습니다. [사용과 검증 범위](CPU-RUNNER.md)를 참고하세요.

## 내부 인터페이스

`Sources/AppPluginCore`는 다른 기능과 공유하는 계약입니다.

- `AppPlugin`: 플러그인 식별자, 비동기 `refresh()`, `cancel()`.
- `PluginRegistry`: 등록·활성화·비활성화와 단일 조회. 비활성화되거나 취소된 조회 결과는 게시하지 않습니다.
- `PluginDataProviding`: `snapshot(for:)`, `vacations(for:)`, `calendarEvents(for:startingIn:)`. 인증정보와 세션은 노출하지 않습니다. 일정 필터는 시작 시각 기준이며 끝 경계는 제외합니다.
- `PluginSnapshot`: 조회 완료 시각, 연차 요약, 휴가, 일정, 조회 범위. 휴가의 선택 날짜와 기간 지정은 구분하며 오전·오후 반차를 추정하지 않습니다. 반복 일정의 회차와 64비트 식별자 정밀도를 보존합니다.

기능 화면은 플러그인별 모델에 직접 연결하지 않고 `FeatureAdapterRouter`를 통해 데이터를 받습니다. 기존 출퇴근 처리는 `DefaultAttendanceAdapter`, Mac 캘린더와 반차 읽기는 `DefaultFeatureAdapter`가 담당합니다. 플러그인의 원본 스냅샷이 필요한 내부 소비자는 공유 `PluginManagerModel.registry`의 읽기 인터페이스를 사용합니다.

```swift
let provider: any PluginDataProviding = plugins.registry
let current = provider.snapshot(for: "daouoffice")
let leave = provider.vacations(for: "daouoffice")
let events = provider.calendarEvents(for: "daouoffice", startingIn: selectedMonth)
```

플러그인의 서버 API는 읽기 전용입니다. 기능 연결을 선택하면 표시와 기존 반차 자동 인식에 사용하며, EventKit 일정 등록·기존 양방향 동기화에는 쓰지 않습니다. 과거 출퇴근 기록을 생성하지 않습니다.

## 새 플러그인 등록과 처리 경계

- `AppPluginCore`: Foundation 기반 데이터·어댑터 계약. 앱 화면과 개별 플러그인에 의존하지 않습니다.
- `AppPluginHost`: 공통 컨트롤러·모듈 등록 계약과 ID별 설정 화면 등록. 개별 플러그인의 타입을 참조하지 않습니다.
- `AppPlugin`: 인증과 원본 조회. `PluginRegistry`는 여러 ID의 데이터를 독립적으로 보관합니다.
- `PluginController`: 설정 모델·시작·종료·조회 상태. `PluginManagerModel`에 여러 컨트롤러를 등록합니다.
- `FeatureAdapter`: 공통 일정·휴가·반차 계약과 지원 기능. 표준 스냅샷을 제공하면 `SnapshotFeatureAdapter`를 사용할 수 있고, 별도 형식이면 직접 구현합니다. 일정 종료는 끝 시각 제외 방식으로 정규화하며, 포함형 종일 종료를 사용하는 다우오피스에는 `inclusiveAllDayEnd: true`를 지정합니다.
- `FeatureAdapterRouter`: 기능별 선택, 기본 연결 복귀, 조회 중 연결 변경 차단. 인증정보와 뷰는 포함하지 않습니다.
- `PluginSettingsPresentationRegistry`: ID별 SwiftUI 설정 화면 등록. 처리 코드에는 SwiftUI나 설정 뷰를 넣지 않습니다.
- `FeatureCalendarModel`과 `AppModel`: 화면 상태와 사용자 명령을 관리하며, 읽기와 출퇴근 계산은 어댑터에 위임합니다.

각 플러그인의 `PluginModule`이 동일한 ID의 컨트롤러·어댑터·설정 화면을 등록합니다. 앱의 `BundledPlugins`는 포함할 모듈 목록만 조립합니다. 새 플러그인을 추가할 때 공통 플러그인 탭이나 캘린더 뷰에 종류별 분기문을 추가하지 않습니다. 모듈 등록 중 오류가 발생하면 해당 모듈의 컨트롤러·데이터·설정 화면을 제거하고 기본 연결을 유지합니다. 이 롤백은 저장된 기능 연결을 수정하지 않아 뒤에 등록되는 다른 플러그인의 선택도 복원합니다. 이미 등록된 동일 ID는 보존하며 중복 등록을 거절합니다.

```swift
enum MyPluginModule: PluginModule {
    static let id = "my-plugin"
    @MainActor static func register(in context: PluginHostContext) throws {
        let controller = MyPluginController(registry: context.registry)
        let adapter = MyFeatureAdapter(controller: controller)
        try context.register(PluginRegistration(
            controller: controller, adapter: adapter,
            symbol: "calendar", summary: "일정 연결", englishSummary: "Calendar connection"))
        try context.presentations.register(id) { MyPluginSettingsView(model: controller) }
    }
}
```

원본 조회에 `PluginRegistry`를 사용하는 컨트롤러에는 `plugins.registry`를 주입합니다. 중복 ID는 거절하며 컨트롤러의 설정·인증·조회 상태를 공유하지 않습니다. 등록 해제 시 `plugins.unregister(id)`로 작업과 데이터를 정리하고 `presentations.unregister(id)`로 설정 화면 등록도 제거합니다. 지원하지 않는 기능은 선택할 수 없고, 아직 조회되지 않았거나 조회 범위 밖인 일정은 빈 성공 결과로 처리하지 않습니다. 이번 달만 제공하는 다우오피스의 다른 월은 범위 안내를 표시합니다.

다우오피스의 인증·HTTP·파싱은 `Sources/DaouOfficePlugin`, 설정 모델·전용 화면·모듈 조립은 `Sources/DaouOfficeIntegration`에 격리합니다. 두 모듈은 공통 계약을 참조하며 `AfterSix` 앱 타깃에 의존하지 않습니다. 공통 앱의 `main.swift`, 기능 관리자와 기능 화면에는 다우오피스 타입이 없습니다. 기존 기본 캘린더 동기화 서비스는 기본 어댑터에 유지합니다.

`HAPPY_LULU_DISABLE_DAOUOFFICE=1 swift build --product HappyLulu`로 다우오피스 타깃을 제외할 수 있습니다. 두 소스 폴더가 없을 때도 `Package.swift`가 선택 의존성을 제외하고 기본 앱을 빌드합니다. 제거된 플러그인의 저장된 기능 연결이 있어도 실행 중에는 기본 어댑터를 사용합니다. `scripts/check-plugin-isolation.sh`는 실제로 두 폴더를 제외한 임시 프로젝트에서 기본 앱 빌드·모듈 구성 진단 실행·출퇴근과 공통 호스트 검사를 수행합니다. 이 검사는 사용자 데이터나 계정에 접근하지 않습니다.

## 다우오피스 4 API 어댑터

2026-10-13 회사 웹의 로그인·휴가·캘린더 화면과 공개 서비스 JavaScript에서 요청 형식을 확인하고, curl로 사람의 CAPTCHA 입력 후 로그인·휴가·캘린더 API의 HTTP 200 응답을 확인했습니다. 실제 연차 숫자 필드의 문자열 형식도 처리합니다. 다음 비공개 웹 API를 사용하므로 다우오피스 버전·회사 구성에 따라 달라질 수 있습니다. CAPTCHA는 사람이 입력하며 여러 회사 선택, SSO 전용 계정, 2차 인증·비밀번호 변경·중복 세션 해제는 자동 처리하지 않습니다.

| 요청 | 용도 |
| --- | --- |
| `GET /api/portal/public/auth/company` | 회사 식별자 조회 |
| `POST /api/portal/public/auth/login` | 회사 ID·로그인 ID·비밀번호로 정상 로그인 |
| `PUT /api/portal/public/auth/captcha` | 보안 문자 이미지 발급·갱신 |
| `POST /api/portal/public/auth/refresh/login` | 401 응답 시 쿠키 갱신 한 번 |
| `GET /api/leave/normal/my/annual/summary` | 연차 요약 |
| `GET /api/leave/normal/my/upcoming` | 예정 휴가 |
| `GET /api/leave/normal/my/past/{year}` | 올해의 지난 휴가 |
| `GET /gw/api/user/session` | 계정의 캘린더 조회용 식별자 |
| `GET /gw/api/calendar/user/{id}/calendar` | 내 캘린더 목록 |
| `GET /gw/api/calendar/event` | 날짜 범위·캘린더 ID로 일정 조회 |

URL은 HTTPS의 동일 출처로 제한하며 HTTP 리다이렉트는 따라가지 않습니다. 인증정보를 URL에 넣거나 로그로 출력하지 않습니다. 휴가 신청·일정 등록·수정·삭제 API는 호출하지 않습니다. 추가 인증이나 응답 필드 변경을 빈 결과로 처리하지 않고 오류로 표시합니다. 한국 회사의 연도·월 조회 경계는 `Asia/Seoul`을 사용합니다.

일정 응답에는 조회 월과 무관한 음력 공휴일 기준 데이터가 포함될 수 있습니다. 2026년 10월의 실제 응답에서 1970년 설날·추석과 2027년 설날 기준 날짜를 확인했습니다. 플러그인은 요청한 월과 겹치는 실제 날짜만 제공하며, 월 경계를 걸치는 일정과 시작·종료가 같은 종일 공휴일은 보존합니다. 기준 데이터의 연도를 임의로 바꾸거나 음력 날짜를 추정하지 않습니다.

## 검증

실제 회사 데이터는 앱을 실행하기 전에 curl로 먼저 확인합니다. 아래 명령은 터미널에서 비밀번호를 숨겨 입력하고, 서버가 요구할 때 새 CAPTCHA 이미지를 열어 사람이 직접 입력하게 합니다.

```sh
python3 scripts/check-daouoffice-api.py --prompt-password --login-then-captcha
```

웹과 같은 순서로 회사 조회·로그인을 진행하고, CAPTCHA가 필요한 경우 같은 쿠키 세션에서 이미지를 발급합니다. 두 번째 로그인은 사람이 CAPTCHA를 입력한 뒤 한 번만 실행합니다. 실패하면 추가 요청을 중단합니다. 성공한 경우 연차 요약·휴가·캘린더 목록·이번 달 일정을 조회하고 `PASS curl`을 표시합니다. 비밀번호는 curl 표준 입력으로 전달하며, 쿠키와 CAPTCHA 이미지는 임시 폴더에서 실행 종료 시 삭제합니다. `.build/daouoffice-curl-report.json`에는 응답 필드의 자료형·건수·HTTP 및 서버 코드·쿠키 개수·CAPTCHA 상태만 저장합니다. 로그인 오류 문구는 비밀번호·아이디·CAPTCHA 답·쿠키 값을 가려 터미널에만 표시합니다.

2026-10-13 실제 curl 확인은 `PASS curl`로 완료했습니다. 공개 JavaScript와 모의 응답 검사 통과만으로 실제 연결 성공을 판단하지 않습니다.

플러그인 API 호출은 표준 출력과 `~/Library/Application Support/AfterSix/Plugins/Logs/daouoffice-api.log`에 JSONL로 기록합니다. 요청 메서드·실제 URL·HTTP 상태·응답 크기·소요 시간과 한국 시각을 남깁니다. 조회 오류의 JSON 응답은 64KB 이내에서 원문을 기록하며, 민감 필드는 가립니다. 로그인·보안 문자·인증 갱신 응답의 본문, 요청 헤더·본문, 비밀번호·쿠키·토큰·보안 문자 답은 기록하지 않습니다. 정상 응답은 자료형과 건수만 기록합니다. 로그 폴더는 700, 파일은 600 권한이며 1MB가 되면 이전 파일 한 개만 보관합니다.

개발 앱을 `dist/HappyLulu.app/Contents/MacOS/HappyLulu --plugins --plugin-diagnostics`로 실행하면 위 API 로그에 더해 표준 출력에 CAPTCHA 상태·작업 결과 건수를 기록합니다. 재조회는 기존 로그인 세션을 재사용합니다. 캘린더 조회의 `+09:00` 시간대는 `%2B09:00`으로 인코딩하여 서버에서 공백으로 해석되지 않게 합니다.

```sh
swift run --build-system native AppPluginChecks
bash scripts/check-daouoffice-model.sh
bash scripts/check-plugin-architecture.sh
bash scripts/check-plugin-isolation.sh
swift run --build-system native AfterSixChecks
HAPPY_LULU_SIGNING_IDENTITY=- bash scripts/build-app.sh
```

검사는 계정·실제 키체인·실제 회사 데이터가 없는 fixture와 임시 폴더를 사용합니다. 내부 계약, API 요청·응답 파싱, 세션 재사용·갱신, 추가 인증 중단, 선택 활성화, 저장 실패의 비밀번호 복구, 재시작, 조회 중 비활성화와 기존 출퇴근 회귀를 확인합니다. `bash scripts/check-daouoffice-model.sh --show-ui`는 격리된 설정 화면을 표시합니다.

**curl로 실제 계정의 휴가·일정 응답을 확인한 뒤 앱 연결과 실제 키체인 저장/복원을 검증해야 합니다.** 웹에서 사용자가 로그인해 화면을 확인한 것은 앱의 별도 세션 로그인 검증을 대신하지 않습니다.
