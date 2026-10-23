# macOS 리퀴드 글래스 UI

이 문서는 `codex/liquid-glass`의 개발 변경을 설명합니다. 공개 배포 버전은 변경하지 않습니다.

## 적용 범위

- 외관 → 테마에 **순정 리퀴드 글래스**를 추가합니다(macOS 26 이상). 색조를 덧입히지 않은 Apple 기본 `.regular` 글래스, 시스템 색상·강조색, 기본 사이드바·설정 컨트롤을 사용합니다. 라이트·다크 모드는 시스템 설정을 따르며, 이 테마에서는 세부 색상 편집을 제공하지 않습니다. 기존 기본 테마와 저장된 선택은 유지합니다.
- macOS 26 이상에서 메뉴 패널과 설정 사이드바에 Apple의 네이티브 Liquid Glass를 적용합니다.
- 메뉴 패널의 삼각형 화살표를 없앴습니다. 메뉴바 항목 아래에 맞춰 열고, 해당 모니터의 사용 가능 영역 안으로 위치를 보정합니다. 바깥 클릭·다른 창 활성화·Space/화면 변경 시 닫히며, 숫자 편집 중 Escape는 먼저 편집 취소를 처리합니다.
- 설정 창은 중복된 상단 제목을 숨기고 제목 표시줄 배경을 현재 테마에 연결합니다. 기본 창 버튼과 창 이동 기능은 유지합니다.
- 설정은 떠 있는 탐색 영역과 분리된 콘텐츠 영역으로 구성합니다. 설정과 플러그인 호스트의 기본 버튼, 달력 이동 버튼은 네이티브 glass 스타일을 사용합니다.
- 출근 기록, 달력 날짜, 설정 입력 내용은 읽기 쉬운 콘텐츠 표면에 유지합니다. 저장된 테마·색상·아이콘을 그대로 사용합니다.
- macOS 13~15에서는 기존 레이아웃·색상·컨트롤 외관을 유지합니다. 최소 지원 버전은 macOS 13입니다.
- ‘투명도 줄이기’나 ‘대비 증가’가 켜지면 불투명한 기존 UI로 돌아갑니다. ‘동작 줄이기’는 근무 유형 전환의 추가 애니메이션을 끕니다.

## 구현 경계

`Sources/AfterSix/LuluMaterials.swift`가 OS 가용성, 접근성 설정, 재질과 버튼 스타일을 처리합니다. 새 API 참조는 런타임 가용성 검사와 컴파일러 조건으로 격리합니다. 구형 Apple Command Line Tools로 빌드한 앱은 기존 외관을 사용합니다. 컴파일러 조건은 SDK 버전 검사가 아니므로 표준 Xcode/Command Line Tools 조합을 전제로 합니다.

순정 테마는 `NSApplication.effectiveAppearance`의 변경을 주 스레드에서 관찰해 SwiftUI에 전달합니다. 기존 사용자 테마의 밝기 지정은 유지하면서 순정 테마에서 macOS 모드 변경을 바로 반영합니다.

플러그인은 UI 재질을 결정하거나 macOS 가용성을 검사하지 않습니다. 설정 호스트가 공통 GroupBox·Button 스타일을 주입합니다. 출퇴근 계산, 저장 경로, 번들 식별자, 플러그인 데이터 처리에는 변경이 없습니다.

## 검증

```sh
bash scripts/check-material-policy.sh
HAPPY_LULU_MATERIAL_MODE=legacy bash scripts/check-settings-navigation.sh
HAPPY_LULU_MATERIAL_MODE=automatic bash scripts/check-settings-navigation.sh
HAPPY_LULU_MATERIAL_MODE=legacy bash scripts/check-design-render.sh
HAPPY_LULU_MATERIAL_MODE=automatic bash scripts/check-design-render.sh
HAPPY_LULU_MATERIAL_MODE=automatic HAPPY_LULU_RENDER_PALETTE=charcoal bash scripts/check-design-render.sh
HAPPY_LULU_RENDER_PALETTE=nativeGlass HAPPY_LULU_RENDER_SCHEME=light bash scripts/check-design-render.sh
HAPPY_LULU_RENDER_PALETTE=nativeGlass HAPPY_LULU_RENDER_SCHEME=dark bash scripts/check-design-render.sh
bash scripts/check-appearance-model.sh
bash scripts/check-panel-focus.sh
```

재질 모드·팔레트·화면 모드 환경 변수는 테스트 앱에서만 읽습니다. 화면 모드는 격리된 테스트 앱의 외관만 바꾸며 macOS 전역 설정을 바꾸지 않습니다. 사용자의 앱 설정에는 개발용 전환 옵션을 추가하지 않습니다. 테스트 앱은 임시 번들 식별자와 합성 데이터를 사용하며 출근 데이터 불변성을 검사합니다. 실제 캘린더·플러그인 계정·로그인 항목·업데이트를 실행하지 않습니다.

`HAPPY_LULU_RENDER_OUTPUT`으로 결과 디렉터리를 정할 수 있습니다. `HAPPY_LULU_RENDER_LIVE=1`을 함께 지정하면 기존 화면 캡처 권한이 있을 때만 격리된 테스트 창(패널·일반 설정·외관 설정)을 WindowServer로 캡처합니다. 데스크톱 전체나 다른 앱은 캡처하지 않으며, 권한을 새로 요청하지 않습니다. 일반 `cacheDisplay` PNG는 레이아웃 확인용이고 실제 배경 굴절을 증명하지 않습니다.

실제 미지원 macOS 실행, VoiceOver 사용, 시스템 접근성 설정을 변경한 뒤의 육안 확인은 별도 검증 대상입니다. 기존 UI 강제 분기 검사와 구 SDK 컴파일은 이 실기기 검증을 대신하지 않습니다.

### 이번 변경의 로컬 확인 결과

- macOS 26.6.2에서 순정 테마의 밝은·어두운 화면, 설정 최소 크기, 근무 유형 5개를 펼친 패널을 확인했습니다. 활성 창의 패널·외관·일반 설정은 WindowServer 캡처로도 확인했습니다.
- 시스템 색상 5개, 저장 후 복원, 열린 창에서 차콜 → 순정 → 웜 스톤 → 순정 전환, 테마를 다시 선택하지 않은 상태의 시스템 라이트·다크 변경을 검사했습니다.
- 기존 사이드바 클릭 28개와 순정 사이드바의 행 구성·클릭·키보드 이동 11개를 통과했습니다. 테스트는 실제 앱 이벤트 루프에서 실행하며 출근 데이터와 외부 서비스는 격리합니다.
- 기존 패널과 화살표 없는 패널의 시간 편집·붙여넣기·포커스·닫기·저장을 3개 시간대에서 검사했습니다. 재질 정책 16개 조합과 실제 SwiftUI 환경 전달도 확인했습니다.
- 재질 헬퍼는 Swift 6.4/SDK 27과 Swift 6.1.2/SDK 15.5에서 macOS 13을 대상으로 타입 검사했습니다. 구 SDK 검사는 앱 전체 빌드나 구형 OS 실기기 실행을 뜻하지 않습니다.
- 화면 밖의 `cacheDisplay` 비교만으로 표시 정상을 판정하지 않습니다. 실제 활성 창에서 기존 테마의 기본 메뉴 컨트롤까지 확인했습니다.
- 독립 코드·시각 리뷰에서 수정이 필요한 P1/P2 문제는 발견되지 않았습니다. UI 구독은 주 스레드로 전달하도록 리뷰 의견을 반영했습니다.

### 최신 main 통합

- 기준 커밋: `f111c37`(PR #63 통합). 최신 설정·종료 메뉴와 사용량 플러그인 이동 경로를 유지했습니다.
- 사용량 행에 맞춰 글래스 패널 크기를 갱신하고 메뉴바 앵커를 유지합니다. 350/390/430pt 전환을 기존 편집·닫기·저장 회귀 검사와 함께 확인했습니다.
- 일반 설정의 사용량 보기 추가를 반영해 세 토글의 열 정렬을 검사합니다. 코덱스 사용량의 기존/순정 라이트·다크 설정과 패널, 메뉴 이동 및 플러그인 격리 검사도 통과했습니다.
