# Mac·Windows 검증과 남은 작업

2026-10-12, 공통 `main` d6a59f256109d9788f1c92139a60a84e6ad2fadf의 앱 코드를 검사했습니다. 플랫폼별 기능 상태는 [기능 현황](PLATFORM-STATUS.md)을 따릅니다.

## 자동 검사 결과

| 범위 | 실행 | 결과 |
| --- | --- | --- |
| Mac 근무 규칙·표시·로그인 처리 | `swift run --build-system native AfterSixChecks` | 코어32개와 추가 표시·로그인 검사 통과 |
| Windows 근무 규칙·저장 | `dotnet run --project windows/HappyLulu.Checks/HappyLulu.Checks.csproj -c Release` | 63개 통과, .NET10.0.401 사용 |
| 캘린더 코어·서비스 | `swift run --build-system native CalendarSyncChecks`, `CalendarSyncServiceChecks` | 각각29개·52개 통과 |
| 캘린더 통합 | `bash scripts/check-calendar-model.sh`, `check-calendar-diagnostics.sh`, `check-calendar-runtime.sh` | 격리 모델·진단·예약/중단 가드 통과 |
| 로그인 실행 구분 | `bash scripts/check-login-launch.sh` | 임시 앱에서 일반 실행·로그인 이벤트·서비스 실행 구분 통과 |
| 배포 검증기 | `python3 scripts/check-release-delivery.py` | 28개 통과 |
| 코드 서명·설치 제어 | `bash scripts/check-code-signing.sh`, `check-automatic-install.sh` | 동일 requirement·변조 거부·설치 허용/중단 검사 통과 |
| 서명된 자동 업데이트 | `python3 scripts/check-signed-auto-update.py` | 데이터 없는 격리 앱의 다운로드·교체·재실행 통과, 설치 앱과 개인 상태 보존 |
| 사이트 | `python3 site/check-site.py` | 9개 경로 검사 통과 |

각 shell 검사에는 `scripts/` 접두어가 필요합니다. 서명 검사는 기존 로컬 키를 쓰며 키를 내보내거나 공개하지 않습니다. 격리 시험 통과는 실제 사용 앱의 업데이트·권한 유지나 실제 부팅 성공을 대신하지 않습니다.

## 같은 입력으로 확인한 계산 규칙

임시 Swift/C# 실행기를 각 플랫폼의 실제 Core에 연결해 아래16개 입력과 명시한 기대값을 비교했습니다. 모든 결과가 양쪽에서 일치했습니다. 이번 비교는 일회성 검증이며 공통 fixture를 CI에 연결하는 작업은 남아 있습니다. 서울 시간대를 사용했습니다.

| 입력 | 기대값 | 사례 수 |
| --- | --- | --- |
| 일반 금요일 09시 정상 근무 / 마지막 금요일 09시 정상 근무 | 근무+휴게540분 / 420분 | 2 |
| 오전 반차13시 / 오후 반차09시, 일반·마지막 금요일 | 모두240분, 단축 중복 없음 | 4 |
| 마지막 금요일 근무60분·휴게0분 | 0분 하한 | 1 |
| 일반 근무360분·휴게60분 | 420분 | 1 |
| 정상 근무07:59:59 / 08:00:00 / 10:00:59 / 10:01:00 | 기록 불가 / 가능 / 가능 / 불가 | 4 |
| 오전 반차12:59:59 / 13:00:00 / 15:00:59 / 15:01:00 | 기록 불가 / 가능 / 가능 / 불가 | 4 |

## 남은 검증과 기능 차이

- [Mac 실기기 #4](https://github.com/young221718/happylulu-app/issues/4), [통합 검증 #17](https://github.com/young221718/happylulu-app/issues/17): 설치 앱은1.5.10 build22, 저장 상태 정상. 현재 캘린더 권한은 `writeOnly`로 읽기가 차단되어 있습니다. 전체 접근 승인 후 선택 캘린더·실제 서버 왕복과 예약 동기화를 확인해야 합니다. 진단에서 일정 제목·계정·원문은 수집하지 않았습니다.
- [Mac 업데이트 #3](https://github.com/young221718/happylulu-app/issues/3): 실제 설치 앱 교체·재실행·기록/연결/권한 유지와 공개 피드가 남았습니다. 로컬 서명 후보나 fixture 통과만으로 공개 완료로 처리하지 않습니다.
- [로그인 출근 #13](https://github.com/young221718/happylulu-app/issues/13): 실제 부팅·로그인에서 첫 기록과 이후 잠금 해제의 중복 방지를 확인해야 합니다.
- [Windows 실기기 #7](https://github.com/young221718/happylulu-app/issues/7): Windows 사용자 세션의 트레이·화면 잠금/해제·자동 실행을 확인해야 합니다. Mac에서 실행한63개 Core 검사는 이를 대신하지 않습니다.
- [기능 동등성 #27](https://github.com/young221718/happylulu-app/issues/27): Windows의 로그인 직후 출근, 일정 기반 반차, 캘린더 동기화, 앱 자체 업데이트는 현재 착수 계획이 없습니다. 공통 계산 fixture의 지속 검사도 후속입니다.

공개 배포본은 Mac1.5.5 build13·Windows1.2.1입니다. 개발 후보·현재 설치 앱·공개 버전은 각각 구분해서 확인합니다. 이번 검증에서 개인 일정 변경이나 설치 앱 교체, 강제 잠금·재부팅은 수행하지 않았습니다.
