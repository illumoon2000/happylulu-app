# 오늘 반차와 연차 직접 입력 명세

기준: main e3daf06, 2026-10-15. 이슈 #36. 사용자가 승인한 범위는 Mac의 오늘 입력이다. 로컬 작업이며 GitHub 이슈 변경·커밋·PR·공개·설치 앱 교체는 하지 않는다.

## 동작

- 메뉴바 패널에 캘린더 연결이 필요 없는 ‘오늘 근무·휴가’ 선택을 제공한다. 일반 근무·오전 반차·오후 반차·연차를 고를 수 있다. 선택 자체는 출근 시각을 만들지 않는다.
- 오늘 선택은 날짜별 `manualDayTypes`에 저장한다. 반차 선택은 출근 감지와 수동 출근 입력에서 캘린더보다 우선하며 감지 후에도 manual 근무 유형으로 유지한다. 기존 출근 허용 시간과 06~08시 보정을 유지한다.
- 기존 출근 기록에 유형을 적용할 때 기록된 시간대의 허용 시간을 검사한다. 맞지 않으면 상태를 변경하지 않고 출근 시각 수정이 필요하다고 알린다. 시각·출처·시간대·과거 기록은 임의로 바꾸지 않는다.
- 연차는 기존 쉬는 날과 구분해 저장한다. 연차 선택은 오늘 자동 감지·카운트다운·추가 시간 표시를 중지하지만 기존 출근 기록은 삭제하지 않는다. 월별 기록에서는 연차를 우선 표시하고 남아 있는 출근 기록은 보존 기록이라고 명시한다.
- 일반·반차로 다시 선택하면 유효한 기존 출근 기록을 재사용한다. 출근 시각을 직접 저장하면 연차/쉬는 날을 해제한다. 명시한 근무 유형은 오늘 선택에도 반영한다. 기존 ‘오늘 쉬는 날’은 기존 확인·삭제 규칙을 유지하며 연차와 구분된다.
- 다음 날에는 전날 선택을 적용하지 않는다. 휴가 이력은 날짜별로 남는다. 기존 데이터에는 새 선택 필드가 없어도 빈 값으로 읽는다. 기존 bundle ID·저장 경로·스키마 버전·캘린더 권한은 유지한다. 이전 앱으로 내려가면 새 필드를 유지하지 못할 수 있으므로 다운그레이드 호환은 보장하지 않는다.
- 과거·미래 날짜 지정, 회사 근태 등록, 휴가 잔여일수 계산, Windows UI는 제외한다.

## 요구사항별 검사

| 검사 | 확인할 내용 |
| --- | --- |
| 선택 후 감지 | 기록 없는 오전/오후 반차 선택, 출근 미생성, 각 허용 구간, 수동 우선·캘린더 refresh 차단 |
| 기존 기록 | 오후 반차 적용 시 시각·출처·시간대 보존; 오전 반차와 09시 기록 충돌 시 원자적 거부 |
| 연차 | 기존 arrival 바이트 의미 보존, unlock/login 거부, today·추가시간 미표시, 정상 근무 복귀와 수동 입력 재개 |
| 날짜·저장 | 다음 날 독립성, 날짜별 휴가 유지, JSON/StateStore roundtrip, legacy 필드 누락, 잘못된 enum 파일 보존 |
| UI·통합 | 캘린더 없이 선택 가능한 컨트롤, 연차와 보존 기록 표시, AppModel 임시 저장소 테스트와 앱 빌드 |
| 기존 계산 | AfterSixChecks 전체와 공유 parity fixture; 캘린더·플러그인 아키텍처 검사 |

## 열린 이슈 대조

- #31: `AttendanceCalendarView`·`CalendarWorkspaceView`와 월 그리드·DST·출근 이력 검사가 구현되어 있다. 1.5.11 설치 기록은 UPDATES.md에 있으나 이번 로컬 작업이 실기기 검증을 새로 수행한 것은 아니다. 원격 이슈는 변경하지 않는다.
- #37: SPEC.md와 계산 상수·30/120분 경계 검사가 존재한다. 설치 앱에서 일반/반차/마지막 금요일과 기록 없음·쉬는 날의 실제 표시 확인은 남아 있다. 로컬 검사로 이 조건을 완료 처리하지 않는다.

## 2026-10-15 로컬 검증 결과

- 새 API가 없는 상태에서 `AfterSixChecks`가 `AttendanceCommand.dayType` 미정의로 실패하는 것을 먼저 확인했다.
- 구현 후 `swift run --build-system native AfterSixChecks` 통과: 새 오늘 근무·휴가 회귀 검사와 기존 33개 검사, countdown·login·settings 검사.
- `swift run --build-system native AfterSixParityChecks Tests/Shared/attendance.json` 통과: 공유 출근 fixture 20건.
- `bash scripts/check-plugin-architecture.sh` 통과: 캘린더 연결 없는 AppModel 저장·재시작·연차→반차 복귀와 기존 출처 변경·격리 검사. 임시 저장소만 사용했다.
- `swift build --build-system native --product HappyLulu`, `bash scripts/build-app.sh` 통과. 로컬 `dist/HappyLulu.app` 생성·고정 인증서 서명 완료. 설치 앱은 교체하거나 실행하지 않았다.
- `bash -n scripts/build-app.sh`, `plutil -lint Resources/Info.plist`, `git diff --check` 통과.
- 기존 Swift native build-system 및 SwiftUI onChange API의 사용 중단 경고가 있다. 실제 UI 클릭·사용자 출근 기록·캘린더 권한·잠금/재부팅 검증은 수행하지 않았다. CI·공개·Apple 공증도 수행하지 않았다.
- 독립 검토에서 확정 결함 없음. 추가 권고된 연차→유효하지 않은 반차 복귀의 전체 상태 보존과 pending 반차의 `selectedMode: nil` 수동 입력 우선순위를 명시적인 회귀 검사로 보강했다.
