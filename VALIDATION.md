# AfterSix 검증 기록

## 2026-10-12 HappyLulu 1.5.11 build27 · 설치와 공개

- [PR #32](https://github.com/young221718/happylulu-app/pull/32)를 독립 검토와 Mac·Windows CI 성공 후 main에 병합했다. 배포 소스는 `cf0d3e03d48599be080cc83719c41f2ce8febebf`다.
- 출근·공유 근무 fixture17건·동기화 코어/서비스·모델·진단·실행·자동 설치와 배포 회귀검사28건을 통과했다. 가상 기록으로 통합 설정의 출근/일정 캘린더를 렌더했다.
- Universal 앱의 고정 자체 인증서, ZIP·DMG·원본 앱 일치, Sparkle archive/appcast/노트 서명과 변조 거부를 확인했다. ZIP SHA-256은 `d981ccd9f906acf0d5581c07c63355d87f65d3b34b1f71741d0559ef594e1997`이다.
- 이 Mac의 기존1.5.10 build22 앱·기록·연결 정보를 비공개 로컬 백업 후1.5.11 build27로 교체·재실행했다. 설치 실행 파일·plist·서명 자원이 후보와 같고, 출근 기록·근무 설정·쉬는 날·캘린더 연결과 fullAccess가 유지됐다.
- 설치된 앱의 캘린더에서 선택한 양쪽 계정의 실제 일정과 동기화 상태를 확인했다. 서버 왕복·부팅/로그아웃·외부 Mac·종전 Site 피드의 자동 이전 시험은 실행하지 않았다.
- [공개 릴리즈](https://github.com/young221718/happylulu-app/releases/tag/macos-v1.5.11-build27)의10개 자산과 고정 `macos-update-feed`를 다시 내려받아 로컬 서명본과 바이트 일치를 확인했다. 고정 feed는 prerelease이며 Latest를 유지하지 않는다. Apple Developer ID·공증은 적용하지 않았다.

## 2026-10-08 HappyLulu 1.5.10 build 21 · 로컬 설치

- 캘린더 서비스52개, 코어28개, 출퇴근31개와 표시·로그인 추가 검사 통과. 반복 회차 복사·이동 예외·재실행 중복 방지·일반 알림 보존·초대 원본 보호·중복 연결의 미확정 저널 보존을 검사했다.
- 권한 변경 후 앱 복귀, 비공개 진단 집계, 미리보기 영수증과 변경 감지, 실행 중 앱 차단과 임시 캘린더 정리 정보 보존 검사 통과. 독립 검토의 발견 사항을 보완한 뒤 최종 조치할 발견 없음.
- Release 빌드, 번들 서명 무결성, plist, diff 검사 통과. AppUpdateChecks는 configuration-only로 실행해 Sparkle 초기화와 격리 설정을 확인했다. 공개 피드 서명·배포는 이번에 검사하거나 수행하지 않았다.
- 설치된 앱은1.5.10 build21이며 실행 파일이 검증한 후보와 일치한다. 출퇴근 파일과 캘린더 동기화 논리 문서의 해시가 교체 전후 동일하다. 기존 build19는 로컬 백업했다.
- 설치 직후 앱 실행 환경의 권한은 notDetermined였고, 사용자 전체 접근 승인 후 fullAccess와 선택 캘린더 두 개의 읽기·쓰기 가능을 확인했다. 실행 중 앱의 두 번째 CLI 미리보기는 appAlreadyRunning으로 거부했다.
- 별도 시험 캘린더 생성은 계정에서 거부됐다(fixtureCreationFailed). 정리 완료·남은 시험 데이터 없음으로 반환됐으며 시험 캘린더 왕복 통과로 표시하지 않는다.
- 실제 선택 캘린더의 새 미리보기는 다우111건·Google56건, 제외·보류·충돌0건이었다. 영수증을 다시 대조해167건의 EventKit 저장을 완료했다. 재조회한 양쪽 일정은 각각169건이고 알림4건·종일3건을 양쪽에서 확인했다. 연결169건 일치, 미완료 journal0건, enabled=true와 다음 실행 예약을 확인했다.
- 실제 선택 캘린더의 두 번째 미리보기는 양방향 추가 작업0건·제외0건·보류0건·충돌0건이었다. 재실행으로 중복 복사가 계획되지 않는 것을 확인했다. 이 검사는 실제 macOS 캘린더 저장·재조회 근거이며 웹 서버 화면 반영과 이후 예약 시각의 자동 실행은 별도 미검증이다. 전체 과정의 출퇴근 파일 해시는 동일했다.
- Developer ID 서명 전환은 사용자 요청에 따라 제외했다. macOS EventKit 저장 성공과 다우오피스·Google 웹 서버 반영은 별도 증거가 필요하다. Figma 이전은 기존 계정 한도 차단 상태를 유지한다.

2026-09-28, 로컬 Mac에서 확인했습니다.

## 완료

- 환경: Apple Silicon, macOS 27.0 (26A428), Swift 6.4 Command Line Tools.
- `swift run --build-system native AfterSixChecks`: 18개 검사 통과.
- `bash scripts/build-app.sh`: Release 앱 생성, ad-hoc 서명 및 서명 검증 통과.
- `bash -n scripts/build-app.sh`, `plutil -lint Resources/Info.plist`, 소스 공백 검사 통과.
- 앱 의존성 확인: 시스템 프레임워크와 Swift 라이브러리만 사용. 빌드 디렉터리의 별도 동적 라이브러리에 의존하지 않음.
- `~/Applications/AfterSix.app`에 설치 및 실행.
- 실제 UI 확인: 출근 대기 화면, 수동 입력된 출근·퇴근 및 카운트다운 화면, 24시간제 표시, 근무 8시간·휴게 1시간, 자동 실행 켜짐.
- 앱 종료·업데이트·재실행 후 기존 수동 출근 기록 유지 확인. 테스트용 출근 시각을 실사용 저장 파일에 주입하지 않음.
- 설치 앱의 `--status`에서 `SMAppService.mainApp.status == 1` (`enabled`) 확인.
- 독립 GPT-6 Sol/xhigh 검토 수행. 지정 `reviewer` 역할의 고정 `biz/gpt-6-sol` 경로가 런타임에서 지원되지 않아, 사용 가능한 동일 Sol/xhigh 기본 역할로 읽기 전용 검토를 수행함. 자동 실행 최초 등록 실패 후 재시도 처리와 24시간 시각 표시를 수정한 뒤 재검토하여 차단 문제 없음 확인.

## 검사 범위

오전 6시 경계, 첫 해제만 기록, 새 날짜 전환, 근무+휴게 합산, 남은 분 올림 및 0 하한, 24시간 표시와 시간대, 수동 수정 보존, 미래·다른 날짜 거부, 수동 조기 출근, 쉬는 날 및 수동 복귀, 다음 날 자동 기록, 로컬 날짜, 일광절약시간의 경과시간 계산, 저장·복원 및 파일 권한, 출근 시각 임의 생성 방지, 손상 파일 원본 보존, 잘못된 근무 설정 거부, 미지원 스키마 거부.

## 미검증

- 실제 사용자의 화면 잠금·해제를 통해 `com.apple.screenIsUnlocked` 알림이 수신되는지.
- 로그아웃·로그인 후 자동 실행과 재부팅 첫 로그인 동작. 등록 상태 확인은 이 검증을 대신하지 않음.
- macOS 13~26 및 Intel 맥. 현재 산출물은 이 맥의 arm64용.
- App Store 배포, Developer ID 공증, 다른 맥 배포.

검증을 위해 사용자 맥을 강제로 잠그거나 재부팅하지 않았습니다. 실제 감지는 README의 잠금/해제 절차로 확인할 수 있습니다.

## 해결한 개발 환경 제약

XCTest가 설치되어 있지 않아 외부 설치 없이 실행하는 독립 검사 실행 파일을 사용했습니다. SDK 27의 `State` 매크로 플러그인 부재는 기존 SwiftUI 프로퍼티 래퍼를 타입 별칭으로 명시하여 해결했습니다. 기존 native 빌드 엔진의 향후 제거 경고는 남아 있으며, 현재 빌드와 실행은 완료했습니다.

## HappyLulu 1.1.0 이름·아이콘 변경

같은 날 사용자가 이름을 HappyLulu로 정하고 회사 동료용 아이콘 제작을 요청했습니다.

- 앱 이름, 실행 파일, 팝업 헤더, 접근성 이름, 앱 아이콘과 메뉴바 심볼을 변경했습니다.
- 근무시간 계산·알림 감지·저장 로직은 변경하지 않았습니다. 저장 경로와 번들 ID를 유지했습니다.
- 내장 이미지 생성 도구로 원본 PNG를 생성하고 RGBA 투명 외곽을 확인했습니다. 원본은 `Resources/HappyLuluIcon.png`에 보관합니다.
- `swift run --build-system native AfterSixChecks`: 18개 검사 통과.
- `bash scripts/build-app.sh`: `dist/HappyLulu.app` 빌드와 ad-hoc 서명 검증 통과.
- `bash -n scripts/build-app.sh`, `plutil -lint Resources/Info.plist` 통과.
- `~/Applications/HappyLulu.app`로 설치했습니다. 기존 설치 앱은 당시 프로젝트의 `.build/branding-before/AfterSix.app`에 보존했습니다.
- 기존 앱의 자동 실행 연결을 해제한 뒤 새 경로의 HappyLulu에서 다시 등록했습니다. 실제 UI와 설치 앱의 `--status`에서 켜짐/`enabled`를 확인했습니다. 실제 재로그인 시험은 수행하지 않았습니다.
- 실제 팝업에서 새 이름·웃는 시계 아이콘·소개 문구와 기존 출근 기록을 확인했습니다.
- 설치된 실행 파일·아이콘·Info.plist가 빌드 산출물과 바이트 단위로 일치합니다.
- 교체 전후 출근 기록 파일의 SHA-256이 일치하여 데이터가 수정되지 않았음을 확인했습니다.
- 새 범위는 외형·이름·패키징 변경이며, 앞선 독립 기능 검토를 새 버전 전체 검토로 표현하지 않습니다. 앞 절의 실제 잠금 해제 등 미검증 항목은 그대로 남아 있습니다.

## happylulu-app 저장소 이관

2026-09-28, Hive의 `dev/services/happylulu-app/develop/`에서 확인했습니다.

- 기존 프로젝트의 소스·검사·아이콘·문서 16개 파일을 복사하고 원본과 바이트 일치를 확인했습니다.
- 앱 동작 코드는 유지하고 개발 안내, 설치 방법, Git 제외 규칙을 정리했습니다.
- 새 위치의 `swift run --build-system native AfterSixChecks`: 18개 검사 통과.
- 새 위치의 `bash scripts/build-app.sh`: Release 빌드, 아이콘 패키징, ad-hoc 서명 검증 통과.
- `bash -n scripts/build-app.sh`, `plutil -lint Resources/Info.plist` 통과.
- Git 추적 대상은 소스·문서·원본 아이콘 17개 파일입니다. 1,125,213바이트의 원본 아이콘을 시각 확인했으며 앱 패키징 입력으로 포함합니다.
- 빌드 결과, 캐시, 이전 앱 백업, 개인 출퇴근 기록은 이관하거나 Git에 포함하지 않았습니다.
- 알려진 토큰·개인키 패턴 검사에서 후보 파일 내 일치 항목이 없었습니다. 이는 포괄적 보안 검토를 뜻하지 않습니다.
- 이관 빌드로 설치 앱을 교체하지 않았으며 실제 잠금·재로그인 등 기존 미검증 항목은 유지합니다.

## HappyLulu 1.2.0 마지막 금요일 조기 퇴근

2026-09-29, 로컬 Mac의 `worktrees/last-friday-early-leave/`에서 확인했습니다.
관련 요구사항은 GitHub 이슈 #1입니다.

- 기록된 출근 시간대의 양력 마지막 금요일에 근무+휴게 합계에서 120분을 빼고 출근 시각을 하한으로 적용합니다. 설정·출근 기록·저장 스키마는 변경하지 않습니다.
- 퇴근 예정, 메뉴바 카운트다운, 진행률이 같은 단축 시각을 사용합니다. 팝업과 설정에 적용 안내를 추가했습니다.
- `swift run --build-system native AfterSixChecks`: 기존 18개와 신규 6개를 포함한 24개 검사 통과.
- 신규 검사: 네 번째/다섯 번째 금요일, 평년/윤년 2월, 12월 말, 다른 요일·일반 금요일, 서울/LA/UTC 날짜 경계, 단축 후 카운트다운·진행률, 사용자 설정과 0시간 하한, 수동 출근 저장·복원.
- `bash scripts/build-app.sh`: Release 앱 빌드와 ad-hoc 서명 검증 통과. 진단 버전을 번들 정보에서 읽도록 변경한 뒤 빌드를 다시 확인했습니다.
- `bash -n scripts/build-app.sh`, `plutil -lint Resources/Info.plist`, `git diff --check` 통과.
- 빌드 앱의 읽기 전용 `--status`에서 `app=HappyLulu version=1.2.0` 확인.
- 기존 독립 Sol/xhigh 검토자가 이번 변경을 읽기 전용으로 검토했으며, 새로운 정확성·회귀 결함은 발견하지 않았습니다. 시간대 변경으로 날짜가 바뀌면 현재 로컬 날짜의 기록으로 전환하는 기존 동작은 README에 명시했습니다.
- 실제 마지막 금요일 UI 표시, 설치 앱 교체, 로그아웃·로그인·잠금 해제 시험은 이번 범위에서 수행하지 않았습니다. 기존 실제 기기 검증 제한은 유지합니다.
- Command Line Tools의 `--build-system native` 향후 제거 경고는 남아 있습니다.

## HappyLulu 1.5.1 기능 통합과 별도 설정 창

2026-10-02, Terra의 `app/mac/happylulu-app/worktrees/updates-1-5-1/`에서 확인했다.
GitHub 이슈 #3은 코드·업데이트 배포, #4는 실제 Mac 시험, #5는 설정 UI를 추적한다.

- 출퇴근 29개, 캘린더 코어 20개, 서비스 35개 검사 통과.
- 메뉴바에는 오늘 상태·출근 수정·반차·쉬는 날과 설정 열기만 두고, 지속 설정과 최근 기록을 별도 창으로 옮겼다.
- Universal arm64·x86_64 앱 빌드와 ad-hoc 서명 검증 통과. ZIP 추출 및 읽기 전용 DMG 안의 앱 파일을 원본과 SHA256으로 대조하고 서명을 재검증했다.
- Intel 링크에서 Swift compatibility packs의 x86_64 부재 경고가 있었다. 빌드는 완료됐지만 Intel 실기기 실행은 사용자 결정으로 후속이다.
- Swift native 빌드 엔진과 hdiutil create 옵션의 향후 제거 경고가 남아 있다.
- plist·패키징 스크립트 문법·diff 공백 확인 통과.
- UI fixture는 별도 임시 StateStore를 사용하며 사용자 출근 기록을 읽지 않고, 자동 실행 등록·캘린더·updater를 시작하지 않는다. 화면 배치 확인과 실제 앱의 창 전환·설정 값 변경은 다른 시험이다.

설치 앱을 강제 교체하거나 잠금·로그아웃·재부팅하지 않았다. 실제 계정 서버 왕복과 이전 앱 업데이트 설치, 권한 흐름은 #4에서 확인한다. 최종 업데이트 서명·Site 게시 및 독립 검토 결과는 완료 증거가 생긴 뒤 아래에 추가한다.

### 1.5.1 최종 검토 보완 (2026-10-02)

- 독립 검토의 충돌 해결 두 경로 수정: 미리보기·일시정지 및 최초 승인 snapshot 우회 쓰기 차단, 화면에 표시한 충돌 이후의 새 변경은 재확인 전 덮어쓰지 않음. 회귀 검사를 포함해 CalendarSyncServiceChecks 36개 통과.
- 캘린더 연결의 공개 서버 주소 선택·복사 버튼과 완료 피드백 추가. 구문 및 Universal 통합 컴파일 확인; 실제 사용자 화면의 복사 클릭은 사용자 시험에 남김.
- SUAllowsAutomaticUpdates=false로 Sparkle의 무동의 설치 opt-in도 차단. 기본 자동 확인은 false.
- 사용자가 키체인 승인·서명 feed 게시·자동 업데이트 활성화를 나중으로 보류함. HappyLuluUpdateServiceEnabled=false이며 업데이트 제어는 비활성. 서명 feed나 업데이트 파일은 게시하지 않음. 현재 수동 교체만 제공.
- AppUpdateChecks의 configuration-only 검사는 Sparkle 구성과 승인 정책을 검사하며 서명·변조 거부 검사를 명시적으로 제외한다. 서명 검사·실제 업데이트 설치 성공과 혼동하지 않는다.
- 최종 배포는 1.5.1 build9 Universal/ad-hoc이며 Developer ID와 Apple 공증, Intel 실기기, 실제 EventKit 서버 왕복·잠금 해제·로그인 시험은 미검증이다.
- 최종 보류 배포본의 ZIP 추출 앱 및 읽기 전용 DMG 앱이 원본 bundle의 모든 정규 파일 SHA256과 일치하고 각각 codesign --verify --deep --strict 통과. source Info.plist와 배포 bundle, source RELEASE-NOTES.md와 배포 노트의 byte 대조 통과.
- AppUpdateChecks --configuration-only 통과: 실제 Sparkle updater를 별도 defaults domain에서 시작하고 자동 확인을 켜도 자동 다운로드 opt-in이 거부됨 확인. 서명 검사는 SKIP으로 출력하며 실행하지 않음.
- 기존 출퇴근 29·Calendar core20 검사는 현재 기능 소스에서 통과했고, 최종 서비스 수정 뒤36검사 통과. Universal 최종 컴파일 통과. macOS의 deprecated native-build/hdiutil 및 Intel compatibility-library 경고는 빌드 실패가 아니며 Intel 실행 검증을 대체하지 않음.

## Mac 1.5.2 영어판 / Windows 1.0.0 (2026-10-02)

- Mac: 영어/한국어/시스템 언어 선택과 동적 날짜·기간·오류 표시 추가. native HappyLulu 빌드, 출퇴근 29검사·캘린더 서비스 36검사·plist lint 통과. 기존 미변경 Calendar core 20검사는 이전 기능 검증을 유지하며 이번 언어 변경으로 재실행하지 않음.
- Mac Universal 1.5.2 build10: arm64/x86_64 빌드 및 ad-hoc 서명 성공. `python3 scripts/verify-release.py dist/releases/1.5.2-build10`은 source plist/노트, ko/en 권한 리소스, SHA-256, ZIP·읽기 전용 DMG의 모든 파일/심볼릭 링크와 세 앱 서명을 대조해 통과. 기존 1.5.1 배포 파일은 보존.
- Mac UI: 별도 preview bundle ID와 임시 StateStore로 실제 SwiftUI 영문 패널 두 상태(364×470) 및 설정(620×700)을 렌더해 확인. 사용자 실제 기록·캘린더·로그인 등록·업데이트 시작은 사용하지 않음. 하단 내용은 스크롤 영역. OS 자체 오류/권한 팝업은 OS 언어를 따를 수 있음.
- Windows: 작업 경로에만 설치한 Microsoft .NET 10 SDK 10.0.401에서 코어 22검사, win-x64 교차 빌드 경고/오류0, self-contained/runtime-required publish 성공. ZIP은 HappyLulu.exe만 포함하며 무결성 검사 통과. 47,089,436바이트 런타임 포함본과 1,203,692바이트 런타임 별도본을 생성.
- Windows 작은 ZIP은 .NET 10 Desktop Runtime x64가 필요하며 Site 다운로드 옆에 명시. 기존 아이콘의 복사본은 원본과 동일한 SHA-256의 1,125,213바이트 소스 이미지로 검토함. 빌드 캐시·bin/obj·ZIP·PDB·개인 데이터는 Git에서 제외.
- 웹: 영어 `/en/` 랜딩과 전 페이지 언어 전환, 한국어/영어 Windows 설치 안내 추가. 8 HTML 경로·앵커·자산 및 신규/기존 배포 파일 해시, JS 구문 통과. 데스크톱·390px·768px 영어 내비 3개/수평 넘침 없음, 모바일 메뉴 선택 후 닫힘·다운로드 앵커 위치와 영어 마지막 금요일 예시 확인.

자동 업데이트 서명/활성화와 Intel 실기기는 사용자 요청대로 보류. 실제 Windows 트레이·언어 전환·잠금 해제·재로그인 자동 실행, Mac 기존 데이터 유지와 실제 잠금 해제/캘린더 서버 왕복은 미검증이며 사용자 시험이 필요하다. 독립 검토·GitHub CI·최종 Site 게시 결과는 실제 종료 결과 확인 후 별도 기록한다.

### 게시 및 독립 검토 결과

- 독립 검토의 영어 공개 안내·복구 문구·기존 FAQ Windows 미지원 문구를 수정하고 재검증. 최종 P1/P2 지적 없음. 영어 README는 Windows 영어 안내로 연결함.
- 기능 GitHub main `489e56f4d478dc5639768c82dd65f05bf509558c` 원격 readback. Windows GitHub Actions [36988588794](https://github.com/young221718/happylulu-app/actions/runs/36988588794)는 실제 Windows runner에서 코어 검사·두 publish·ZIP 패키징·두 artifact 업로드 모두 success, 최종 completed/success 확인. 이것은 사용자 Windows 세션 시험을 대신하지 않음.
- Site source `a0158727d5cabed9a87776b231a7cba40dfcdac8`, version5, deployment `appgdep_6abf7649de1481919889192b29a370fe` succeeded. 공식 https://happylulu.cy-choi-lulu.chatgpt.site 및 영어 `/en/`. Mac 1.5.2 DMG·ZIP과 Windows 런타임 별도 ZIP을 검증한 archive로 게시. 기존 버전 파일 보존.
- Windows 실제 사용자 시험은 [이슈 #7](https://github.com/young221718/happylulu-app/issues/7), Mac 언어 전환·기존 데이터·기존 실제 시험은 [이슈 #4](https://github.com/young221718/happylulu-app/issues/4#issuecomment-5948947107)에서 미완료 유지.

## 2026-10-02 Mac 1.5.3 / Windows 1.1.0 개발 후보

- 요청: GitHub #8 추가 시간·2시간 식대 기준, #9 Windows 카드 디자인. 공개 다운로드는 Mac1.5.2/Windows1.0.0 유지.
- Mac: AfterSixChecks31개와 native HappyLulu debug 빌드 통과. +30분·+120분의 초 경계, 기록 없음·쉬는날·반차·마지막금요일 계산 확인. 화면 시각은 1초 tick, 서비스 조회는 기존 15초 주기. 실제 기준 시각과 잔여 분은 한국어/영어로 표시하며 지급 승인과 구별.
- Windows: .NET10 코어34검사, Mac에서 win-x64 교차 빌드 경고/오류0, runtime-required 및 self-contained publish·ZIP 무결성 통과. 오늘 창의 둥근 카드·큰 시간·출퇴근·식대 카드, 설정 카드와 좁은 창 줄바꿈을 보완.
- 독립 검토: Mac 표시 지연/추가 시간 제목 및 Windows 작은 폭 날짜·경로 잘림 수정 후 최종 diff에 남은 P1/P2/P3 발견 없음. git diff --check 통과.
- 실제 Windows GUI·DPI100/150/200%·창 크기·키보드·언어전환·트레이·잠금 해제·로그인 시험은 미실행. Mac 실제 화면·기존 기록 보존·잠금 해제는 별도 시험. 자동 업데이트/Intel 실기기는 기존 보류.
- Universal Mac 패키지 생성/무결성과 이 후보의 실제 Windows CI는 진행 중이며 완료 증거를 뒤에 추가한다. 설치 앱/실제 출근 기록은 변경하지 않았다.

완료 증거: 기능 소스5827f3eebd457ba0061474db2de27ab771693d2e의 실제 Windows runner [36993469659](https://github.com/young221718/happylulu-app/actions/runs/36993469659)는 completed/success. 코어 검사, 런타임 포함·별도 publish, 두 ZIP 생성과 artifact 업로드 모두 success. Mac1.5.3 build11 Universal 패키지 생성 완료 및 verify-release.py 통과: plist/한영 권한 리소스/두 아키텍처/체크섬/ZIP·읽기 전용 DMG의 모든 파일·심볼릭 링크/서명 확인. x86_64 링크의 CompatibilityPacks 경고가 있었지만 빌드는 성공했으며 Intel 실기기 시험으로 대신하지 않는다. 후보 산출물은 ignored dist에 보존하고 Git에는 넣지 않았다.

## 2026-10-07 · Mac 1.5.6 build14 로그인 출근 누락 수정 (#13)

- 최신 main `f7712de` 위에 구현하여 소수 시간 표시 수정을 보존했습니다.
- `swift run --build-system native --skip-update AfterSixChecks`: 기존 31개 검사와 표시 형식/선택 유지, 로그인 이벤트 판별·출근 경계·캘린더 반차·기존 기록/수동 수정/쉬는 날 보존·새 날짜·출처 저장 왕복 검사 통과.
- `bash scripts/check-login-launch.sh`: 실사용 앱/기록과 분리한 임시 AppKit 앱을 LaunchServices로 열어 will/didFinishLaunching에서 로그인 표시 true, 일반 수동/서비스 시작 false 확인. 생성된 이벤트를 사용한 통합 검사이며 실제 SMAppService 부팅 실행 검증은 아닙니다. 환경의 sandbox extension 경고는 있었으나 세 경우 모두 결과 파일을 읽어 판정을 확인했습니다.
- `bash scripts/build-app.sh`: Apple Silicon Release 앱 빌드, ad-hoc 서명 및 deep/strict 검증 통과. 기존 native 빌드 엔진 폐기 예정 경고 유지.
- 설치된 기존 1.5.4의 read-only `--status`를 샌드박스 밖에서 확인하여 로그인 자동 실행 enabled(1) 확인. 샌드박스 안의 notFound(3)는 실제 등록 상태의 근거로 사용하지 않음.
- 실제 부팅·로그인과 이후 잠금 해제, Intel 기기 검증은 미완료. 사용자 Mac을 로그아웃·잠금·재부팅하지 않았습니다.
- 독립 GPT-6 Sol/xhigh 리뷰에서 차단 결함 없음. 로그인 기록 후 잠금 해제 이력이 없을 때 대기 중으로 보이던 문구를 수정하고 재검토 완료. 구버전은 새 login 출처를 해석하지 못하므로 원본을 보존하고 저장을 중지한다는 복귀 제한을 README에 명시했습니다.
- 로컬 `~/Applications/HappyLulu.app`를 1.5.6 build14로 교체하고 이전 1.5.4 앱을 백업했습니다. 설치 실행 파일은 빌드와 SHA-256 일치, 서명 검증·실행 프로세스·로그인 등록 enabled(1) 확인. 교체 전후 AfterSix/state.json의 SHA-256이 같아 기록 파일 보존 확인. 원격 main/공개 다운로드에는 이번 수정 미반영.

## 2026-10-07 · 자동 업데이트 활성화 1.5.9 build17

사용자가 자동 다운로드·설치와 사이트 배포를 요청해 #3 보류를 재개했습니다. 기존 로그인 수정도 포함합니다.

- Sparkle 자동 확인/설치 기본값 활성화. 기존 저장된 사용자 선택은 보존하며 설정에서 변경 가능.
- 설치 준비 완료부터 설정을 잠시 잠그고, 출근/캘린더 처리 및 앱 창 사용 중에는 재시작을 미룹니다. 설치 중복 호출을 차단하고 실제 종료 취소에만 재시도하며 모든 종료/오류 콜백에서 잠금을 정리합니다. 일반 사용자 종료는 막지 않습니다.
- 독립 Sol/xhigh 리뷰의 설정 변경·실패 복구·중복 설치 지적을 수정하고 최종 focused review에서 차단 문제 없음 확인.
- 실제 AppUpdater.swift를 격리 앱으로 컴파일한 scripts/check-automatic-install.sh 통과: 3개 Objective-C delegate selector, busy/idle, 설정 잠금, 설치 중복 방지, 종료 취소 재시도, abort 및 authorize-later에 해당하는 finished-cycle 정리, opt-out.
- AppUpdateChecks의 실제 Sparkle 시작과 자동 다운로드 opt-in/opt-out 검사 통과. Universal arm64/x86_64 앱 빌드·ad-hoc 서명 검증 완료. 미게시 초기 후보는 rejected-candidates에 보존하고 최종 코드를 다시 빌드했습니다.
- 기존 키체인 sign_update로 시험 파일 서명은 성공. 최종 ZIP 서명은 키체인 단계 대기 중이며 서명 완료·공개 feed 게시·실제 자동 설치는 아직 미검증입니다.
- Developer ID 공증과 Intel 실기기 시험은 별도 미완료입니다.


## 2026-10-08 · 로컬 고정 서명 및 자동 업데이트 후보 1.5.10 build23

- 로그인 키체인에 HappyLulu 전용 고정 자체 서명 인증서를 생성했습니다. 개인 키는 내보낼 수 없도록 가져왔으며 codesign 접근만 허용했습니다. 시스템 인증서 신뢰 설정과 앱 식별자, 기존 Sparkle 공개키·비밀키는 유지했습니다. Developer ID·Apple 공증은 아닙니다.
- `bash scripts/check-code-signing.sh`: 서로 다른 두 빌드의 인증서에 결합된 지정 요구사항 일치, 상호 검증, 변조 거부, 없는 인증서 요청 시 실패·바이너리 보존 통과. 빌드와 패키징에서 공통 서명 도우미를 사용합니다.
- `python3 scripts/check-signed-auto-update.py`: 사용자 데이터가 없는 별도 앱에서 실제 AppUpdater와 Sparkle을 사용했습니다. 서명된 목록·ZIP 다운로드, 구 프로세스 종료, 버전 2 설치와 새 프로세스 재실행, 코드 서명·지정 요구사항 유지 통과. HappyLulu 설치 파일과 출근 기록·캘린더 저장 문서가 시험 전후 같음을 확인했습니다. 루프백 서버 시험이며 공개 서버 다운로드를 대신하지 않습니다.
- `bash scripts/check-automatic-install.sh`: 작업 중 재시작 보류, 설치 준비 중 설정 잠금, 중복 방지, 종료 취소 재시도와 오류 정리 통과. AppUpdateChecks의 ZIP·목록·릴리즈 노트 서명 및 변조 거부 검사 통과.
- Universal arm64/x86_64 build23 패키지 생성 및 `python3 scripts/verify-release.py dist/releases/1.5.10-build23` 통과. Intel 링크의 기존 CompatibilityPacks 경고가 있었고 실제 Intel 기기는 시험하지 않았습니다. 독립 코드 검토에서 남은 조치 항목 없음.
- 실제 설치는 고정 인증서의 build22까지 완료했습니다. 이전 build21을 백업하고 설치 실행 파일, 서명, 단일 실행 프로세스, 출근 기록과 캘린더 설정·동기화 활성화 보존을 확인했습니다. 서명 최초 전환 후 접근 상태는 notDetermined이며 사용자의 전체 접근 승인을 기다립니다. build22→23의 실제 권한 유지 시험은 아직 실행하지 않았습니다.
- 공개 `/updates/appcast.xml`은 HTTP 404였습니다. 기존 공개 사이트 version9 소스에서 build23의 서명된 업데이트 목록·ZIP·노트를 추가한 별도 후보를 준비하고 기존 다운로드 파일을 보존했습니다. 공개 배포는 아직 하지 않았습니다.

## 2026-10-08 · GitHub 통합 후보 1.5.10 build24

- 최신 main의 저장 보호·시간 표시 개선을 선행 PR14와 현재 변경에 통합했습니다. 충돌한 검사 파일의 로그인·기존 설정 시간 검사 모두 유지했고 독립 검토에서 확인했습니다.
- 통합 후 출근32개·Calendar core29개·service52개와 추가 로그인/표시 검사 통과. Mac GitHub Actions는 개인 키 없이 ad-hoc 앱 빌드와 격리 검사를 수행하며 실제 CI 결과는 PR에서 확인합니다.
- `bash scripts/package-release.sh` 및 `python3 scripts/verify-release.py dist/releases/1.5.10-build24` 통과: Universal 두 아키텍처, 메타데이터·한영 권한 리소스·ZIP/DMG 내용·해시·심볼릭 링크·고정 인증서 서명 대조. 이전 x86_64 CompatibilityPacks 링크 경고는 유지합니다.
- `bash scripts/generate-update-feed.sh dist/releases/1.5.10-build24/HappyLulu-1.5.10-universal.zip dist/updates-main-build24`로 새 목록을 생성했고 AppUpdateChecks로 ZIP·목록·노트 서명 및 변조 거부, 격리 Sparkle 설정을 검증했습니다. 미게시 build23 후보와 구분합니다.
- 실제 설치 앱은 build22를 유지합니다. LaunchServices 읽기 전용 진단에서 새 인증서의 캘린더 상태가 아직 notDetermined였고, 예약 실행 후 동기화가 권한 부족으로 일시 중지됐음을 확인했습니다(enabled=false·예약 없음). 이 진단 전후 출근·논리 동기화 문서는 동일합니다. 최초 전체 접근 승인 후 에이전트가 재개·교체·권한 지속을 확인해야 하며, 공개 업데이트 피드는 아직 게시하지 않았습니다.

## 2026-10-08 · GitHub 배포 역할 분리와 라이선스 후보 build25 (#21)

- PR14·19·20을 main에 병합하고 원격 병합 상태를 확인했습니다. GitHub Actions 정의와 로컬 서명·공개 절차를 `DEPLOYMENT.md`에 모았습니다. CI는 비밀키 없는 검사·패키지 artifact만 만들며, 실제 키체인 서명과 공개 승격은 로컬에서 수행합니다.
- 사이트 정본을 `site/`에 포함하고 소개·시연·GitHub 링크 중심으로 축소했습니다. 로컬 9개 경로의 320/1280px 수평 넘침 없음, 시연 47분·마지막 금요일 15:47, 영어 모바일 메뉴 닫힘을 확인했습니다. `python3 site/check-site.py`, `node --check site/dist/app.js`, 문서 내부 링크와 diff 검사는 통과했습니다. 이 기록 시점의 새 Site 공개·GitHub CI 결과는 별도 원격 확인 대상입니다.
- 기존 공개 Mac1.5.5 build13과 Windows1.2.1 파일을 동일 바이트로 GitHub Releases에 옮겼습니다. 원래 소스 `4f13945ef927a88e7326647cb4fce3690fd93078`에 태그를 연결하고 공개 HTTP 다운로드와 세 바이너리·두 체크섬 파일의 SHA-256을 대조해 통과했습니다. 기존 바이너리는 재포장하지 않았으며 새 라이선스가 소급 동봉됐다고 주장하지 않습니다.
- 비상업 이용과 수정·코드 재사용 결과물 전체 소스 공개 조건의 사용자 정의 LICENSE, Sparkle의 실제 배포물 원문 THIRD_PARTY_NOTICES를 추가했습니다. 개인의 공식 무수정 앱 출퇴근 확인은 직장에서도 허용합니다. 이 조건은 OSI 오픈소스 라이선스가 아니며 법적 효력을 검증한 기록이 아닙니다.
- `HAPPY_LULU_SIGNING_IDENTITY=- bash scripts/package-release.sh`와 `python3 scripts/verify-release.py dist/releases/1.5.10-build25` 통과: Universal 두 아키텍처, ZIP·DMG·앱 리소스의 라이선스/고지, 메타데이터·체크섬·서명 검증. 해당 패키지는 미커밋 소스의 ad-hoc 검증본이며 `dist/validation/adhoc-1.5.10-build25`로 분리했습니다. 공개 후보로 사용하지 않습니다.
- `swift run --build-system native AppUpdateChecks dist/validation/adhoc-1.5.10-build25/HappyLulu.app --configuration-only` 통과: GitHub 고정 feed와 격리 Sparkle 설정. 셸·YAML·Python 구문, plist 검증 통과. 배포 회귀 검사와 최종 독립 검토 결과는 아래에 추가합니다.
- 실제 설치는 build22입니다. LaunchServices 읽기 전용 진단은 permission=notDetermined, calendarReadBlocked=true, enabled=false, 예약 없음이며 진단 전후 출근·논리 동기화 문서는 같았습니다. build25 실제 키체인 서명·설치·권한 유지·공개 업데이트 목록 게시와 Windows 사용자 GUI 시험은 미실행입니다.
- `python3 scripts/check-release-delivery.py` 최종 28/28 PASS. 임시 Ed25519 키의 실제 암호 검증과 변조 거부, 소스·태그 불일치 사전 거부, 업로드 실패 시 이전 목록 복구, 누락·미완료 starter 자산의 동일 후보 재개, 증거·백업 변조 시 원격 쓰기 거부를 검사했습니다. GitHub 장애 경로는 mock이며 실제 서버 장애를 발생시키지 않았습니다.
- 독립 검토에서 사이트 정본의 ignore 예외, 기존 태그의 다른 commit 연결, feed 실패 복구·미완료 자산 재개를 보완했습니다. 최종 수리 검토에서 남은 차단사항은 없었습니다. 원격 CI·새 Site 공개 결과는 PR와 작업 TODO의 실제 결과로 추적합니다.


## 2026-10-08 · 집중을 돕는 README·사이트 개편 (#23)

- 승인한 ‘작은 번거로움은 덜고, 내 일에 집중.’ 컨셉을 한·영 README·사이트에 적용했습니다. README의 큰 시각 자료는 웹 제품 데모이며 실제 앱 캡처가 아님을 명시했습니다. main의 실제 3개 workflow 배지를 사용하고 공개 버전·개발 후보·라이선스 조건을 보존했습니다.
- 기존 README 상세 안내는 docs/USER-GUIDE.md와 영어판으로 상대 링크만 교정해 보존했습니다. 문서 링크·이미지·앵커84개, 본문 보존·기존 H2 앵커·배지 목적지 검사 통과.
- 사이트는 다운로드·기능·사용 방법 순서로 정리했습니다. Windows 런타임 링크를 다운로드 카드에 직접 제공하고 릴리즈 노트 복제본2개를 제거했습니다. 기존 릴리즈 경로는 GitHub Releases로 이동하며 자동 이동이 되지 않을 때의 전체 Mac/Windows 변경 기록 링크를 남겼습니다.
- python3 site/check-site.py, node --check site/dist/app.js, git diff --check 통과. 게시 checkout의 check-assets.py에서 9개 경로·기존 다운로드의 고정 해시 통과. 실제 브라우저 7개 페이지×320/1280px 가로 넘침 없음, 영어390px 메뉴→사용방법 이동·메뉴 닫힘, 금요일 데모47분·15:47 확인.
- 앱 코드·키체인·설치본·캘린더 기록·공개 바이너리는 변경하지 않았습니다. 실제 캘린더 권한 유지·새 자동 업데이트 피드 공개·실제 앱 교체는 기존 미완료입니다. 독립 검토·GitHub CI·병합·게시 결과는 이슈와 PR에서 최종 상태로 추적합니다.
