# 플러그인 설정·외관 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. 현재 사용자의 설계 승인과 실행 요청에 따라 독립 작업을 분담하고 동일 변경에서 최종 검토한다.

**Goal:** 기본 출퇴근 기능과 선택 플러그인을 분리하고 5개 테마·아이콘 및 세부 외관 편집을 제공한 개발 앱을 설치한다.
**Architecture:** 기존 PluginHost/FeatureAdapter 경계를 재사용하며 설치·활성 상태와 외관은 출근 데이터와 분리한다. 외관·플러그인 런타임은 독립 작성, 설정 UI와 통합·검증·Dev 갱신은 주 에이전트가 담당한다.
**Tech Stack:** Swift 6, SwiftUI/AppKit, 기존 Swift Package와 assert 검사. 새 의존성 없음.
**Spec:** ../specs/2026-10-16-plugin-settings-appearance-design.md

## Global Constraints

- 기존 정식 앱·개인 데이터·Dev 기록·기존 미커밋 숫자 편집 보존. 새 커밋·푸시·릴리즈 없음.
- 다우오피스 개발자 손정열. 개인 저작자를 추정하지 않음.
- 로컬 포함 모듈 설치, 원격 코드 다운로드 없음. 비활성화는 데이터 삭제가 아님.
- Dev 외부 계정·캘린더 권한·자동 업데이트·로그인 항목 변경 차단 유지.

## Review Focus

- 최초 실행/이전 설정/손상 상태에서 선택 모듈의 원치 않는 시작과 데이터 손실을 막는다.
- 플러그인 끄기 후 대기 중 비동기 결과가 기본 기록을 바꾸지 않는다.
- 잘못된 HEX·이미지·쓰기 오류는 원본을 보존한다.
- 테마/아이콘 설정과 이미지 경로가 Dev/정식 앱 사이에 공유되지 않는다.
- 숫자 편집 위치·직접 입력·자동 저장과 기존 half-day/동기화 동작을 회귀 검사한다.

### Task 1: 외관 모델·설정 화면 (외관 작성자)
- [x] 코어 외관 Codable/HEX/대비/5팔레트/아이콘 참조의 실패 검사를 먼저 작성하고 RED 확인.
- [x] AppearanceModel.swift, AppearanceSettingsView.swift와 코어 타입·검사를 구현한다. API: AppearanceModel.shared, background/sidebar/surface/accent/text Color, isDark Bool, iconImage NSImage; AppearanceSettingsView(appearance:).
- [x] 별도 저장소의 오류 원자성·개발 분리·잘못된 이미지/취소·재시작을 검사하고 GREEN 확인. 앱 리소스 수정 금지.

### Task 2: 선택 플러그인 상태·생명주기 (플러그인 작성자)
- [x] PluginManagerModel·DefaultFeatureAdapter·CalendarSyncModel·AppModel·main과 Probe 검사 소유. 신규 모듈 상태/이관/실패 보존 검사 RED.
- [x] 출퇴근 전용 fallback, 캘린더/휴가 인식 모듈 게이트, 기존 다우오피스 게이트와 개발자 메타데이터를 구현한다.
- [x] UI API: catalog entries(id,name,author,summary,symbol), isInstalled/isEnabled/install/setEnabled 및 설치된 메뉴 상태. 개별 플러그인ID는 mac-calendar, daouoffice, leave-detection. 기존 테스트용 초기화 호환.
- [x] 새 사용자는 기본만, 기존 동기화/계정/자동 인식은 원본 유지 이관. 이벤트·타이머/요청 중지·stale 결과 거부·선택 경로 검증 GREEN.

### Task 3: 설정·메인 UI 통합 (주 작성자)
- [x] SettingsView 사이드바: 기본/외관/관리/가로선/설치 플러그인. 개별 상세와 설치/사용/개발자 UI.
- [x] 캘린더·휴가 인식 설정을 해당 상세로 이동, 기존 접근 경로와 오류/연결 선택 보존.
- [x] AppearanceModel을 설정·PanelView·근무 캡슐에 연결하며 숫자 배치 유지. 설치 모듈 없음 안내.

### Task 4: 검증·개발 앱 (주 작성자)
- [x] 각 작성자 결과·diff를 모아 독립 검토하고 발견 사항을 원 작성자에게 돌려 조치한다.
- [x] AfterSixChecks, AppPluginChecks, 공유20fixture, PluginArchitectureProbe, 캘린더 checks, debug/release 패키징·문법·plist·diff 검증.
- [ ] 격리 QA: 새 사이드바·3개 모듈·손정열·5테마/아이콘·세부 편집·저장/재시작·숫자 위치. 실제 외부 호출 금지.
- [x] 기존 Dev 번들과 기록 백업, 동일 ID/분리 저장소로 Dev만 교체. SHA-256 보존·실행 readback. 설치는 현재 sandbox 권한 경계에 따라 승인된 쓰기 경로로 실행한다.
- [x] TODO와 명세에 실제 결과·미검증을 분리 기록한다.

## 2026-10-16 실행 결과

로컬 구현·Dev 백업/교체·실행 완료. 사용자에게 격리 QA 실행과 Dev 교체의 명시적 승인을 받았다. 기존 Dev 번들 및 전체 개발 프로필은 artifacts/happylulu-dev-plugin-appearance-20261016/before-update에 보존했다. 동일 개발 bundle ID와 서명을 검증했고 출퇴근 state.json SHA256은 교체 전후 동일하다. 정식 앱은 변경하지 않았다.

코어·플러그인·공유 fixture20건·캘린더 코어29건/서비스54건·런타임10그룹·다우오피스 모델 검사와 debug/release 패키징 통과. 독립 검토 후 손상 플러그인 설정의 기존 기록 변경과 권한 재시도 경로를 수정했다. 실제 AppearanceModel의 5개 팔레트·서로 다른 5개 아이콘·PNG/JPEG·재시작·손상 원본 보존 검사 통과. CoreImage 생성이 제한되는 실행 sandbox 밖 일반 앱 환경에서 아이콘 검사를 확인했다. 재현: bash scripts/check-appearance-model.sh.

격리 QA에서 사이드바·3개 모듈·손정열 표기·설치 후 메뉴 추가·개별 설정을 화면으로, 사용 상태 저장을 파일로 확인했다. 외관 페이지 클릭 시 UI 도구의 native pipe closed 때문에 테마 클릭·키보드·최소 창 크기 전체 시각 검증은 미완료다. 실제 외부 계정/캘린더 연결은 실행하지 않았다. 검증 로그와 installation.json은 위 artifact의 validation에 보존한다. 새 커밋·푸시·CI·공개 릴리즈 없음.
