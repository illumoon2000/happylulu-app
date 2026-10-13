# HappyLulu Windows 1.5.13

현재 공개 버전은 **1.5.13**이며 [GitHub Releases](https://github.com/young221718/happylulu-app/releases/tag/windows-v1.5.13)에서 받습니다. 시간 표시를 소수점 한 자리로 올림하고 밝은 카드·추가 경과 시간·식대 시간 기준을 제공합니다. 실제 근무·지급 승인 여부를 판정하지 않습니다.

Windows 알림 영역 앱입니다. 알림 영역 아이콘을 왼쪽 클릭하면 오늘의 출근·퇴근 상태와 직접 입력·쉬는 날 버튼이 열립니다. 오른쪽 클릭 메뉴에서 별도 설정 창과 종료를 선택할 수 있습니다. 설정에서 표시 언어를 시스템·한국어·영어 중 고를 수 있으며 선택은 로컬 기록에 저장됩니다.

앱이 실행 중일 때 Windows의 실제 `SessionUnlock` 이벤트를 받으면 첫 출근 시각을 기록합니다. 일반 근무의 자동 감지는 06:00~10:00(08시 이전 감지는 08시 기록), 오전 반차는 13:00~15:00에 기록하며 오후 반차는 직접 지정할 수 있습니다. 앱을 실행하기 전의 잠금 해제와 PC 켜짐·절전 해제·세션 전환만으로는 출근 시각을 추정하지 않습니다. 오늘 쉬는 날을 선택하면 오늘 기록을 지우고 이후 잠금 해제 자동 기록을 막습니다. 직접 출근 시각을 입력하면 다시 기록합니다.

기록은 `%LOCALAPPDATA%\HappyLulu\state.json`에만 저장됩니다. 파일이 손상되어 읽히지 않으면 원본을 보존하고 새 기록 저장을 중단합니다. 설정 창에서는 근무·휴게 시간, 최근 기록, 선택형 Windows 로그인 자동 실행을 관리합니다. 자동 실행은 사용자가 켤 때만 현재 실행 파일 경로를 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`에 기록합니다. 앱을 옮기면 다시 설정해야 합니다.

Windows 1.5.13에도 캘린더 동기화와 앱 자체 자동 업데이트가 들어 있지 않습니다. 업데이트 배포·서명 정책이 확정되기 전에는 자동 설치를 수행하지 않습니다.

개발 기준은 Mac과 같은 `main`입니다. 플랫폼별 차이와 개발 상태는 [Mac·Windows 기능 현황](../docs/PLATFORM-STATUS.md)에서 확인합니다.

자동 감지는 로컬 시각 **06:00부터** 시작하며 06:00~07:59:59의 일반·오후 반차 출근을 **같은 날 08:00**로 기록합니다. 예: 06:30 감지 → 08:00 기록 → 기본 퇴근 17:00. 06:00 이전은 제외하고 오전 반차는 기존 13:00~15:00을 유지합니다. 아래 표는 수동 입력·기록 시각의 기존 허용 구간이며 수동 입력에는 보정을 적용하지 않습니다.

## 빌드와 검사

Windows에서 .NET 10 SDK로 다음 명령을 실행합니다.

```powershell
dotnet run --project windows/HappyLulu.Checks/HappyLulu.Checks.csproj -c Release
dotnet publish windows/HappyLulu.Tray/HappyLulu.Tray.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:PublishTrimmed=false -p:DebugType=None -p:DebugSymbols=false -o dist/windows/self-contained
dotnet publish windows/HappyLulu.Tray/HappyLulu.Tray.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -p:PublishTrimmed=false -p:DebugType=None -p:DebugSymbols=false -o dist/windows/runtime-required
```

`HappyLulu-1.5.13-windows-x64.zip`은 .NET 런타임을 포함한 포터블 배포본입니다. `HappyLulu-1.5.13-windows-x64-runtime-required.zip`은 **.NET 10 Desktop Runtime x64** 설치가 필요한 작은 포터블 배포본입니다. 두 배포본 모두 압축을 푼 뒤 `HappyLulu.exe`를 실행합니다. CI에서 두 ZIP을 만들고 작은 ZIP의 25 MiB 미만 크기를 확인합니다.

코어 검사와 빌드 성공만으로 실제 Windows 잠금 해제, 알림 영역 표시, 로그인 후 자동 실행, 설치된 런타임의 동작은 확인되지 않습니다. 이 동작은 Windows 세션에서 별도로 검증해야 합니다.

[Windows 릴리즈 노트](RELEASE-NOTES.md)

설정의 **퇴근까지 남은 시간 표시**에서 밀리초, 초, 분, 시간, 시간/분(기본)을 선택할 수 있습니다. 오늘 화면과 트레이 설명에 함께 적용되며 재실행 후에도 유지됩니다. 시간 단위는 0.1시간(6분)씩 올림해 표시합니다(90분→1.5시간, 30분→0.5시간). 정수 시간은 소수점을 생략하며, 남은 시간이 양수면 최소 0.1시간, 0 이하이면 0시간입니다. 다른 단위는 기존처럼 올림하고, 밀리초 표시는 남은 시간이 있을 때 0.1초마다 갱신됩니다. 출퇴근 계산이나 추가 근무 안내 기준은 바뀌지 않습니다.

라이선스: [비상업·코드 재사용 시 전체 소스 공개](../LICENSE). [외부 고지](../THIRD_PARTY_NOTICES.md)와 [배포 절차](../DEPLOYMENT.md)를 확인하세요.
