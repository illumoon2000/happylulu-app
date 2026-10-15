# GitHub 배포 절차

소스·검증과 실제 공개를 분리합니다. GitHub Actions는 앱 검증과 패키지 artifact만 만들며 Release를 쓰지 않습니다. Mac의 고정 코드 서명과 Sparkle Ed25519 서명은 제작자 Mac의 보호된 키체인을 사용합니다. 비밀키 내보내기, CI Secret 등록, 사용자 앱 교체는 이 스크립트가 수행하지 않습니다.

## Mac 로컬 준비

`Resources/Info.plist`의 버전·증가한 build, RELEASE-NOTES.md, LICENSE, THIRD_PARTY_NOTICES.md를 검토·커밋한 깨끗한 checkout에서 실행합니다. 현재 후보는 1.5.14 build30입니다.

```sh
bash scripts/prepare-release.sh
python3 scripts/release_delivery.py check dist/releases/1.5.14-build30
```

준비 단계는 고정 코드 서명 검사, arm64/x86_64 Universal 빌드, ZIP·DMG 생성, 로컬 Sparkle feed 서명, 번들·ZIP·DMG 일치 검사와 Ed25519 서명 검사를 수행합니다. 키체인 승인창은 운영자가 직접 승인합니다. ad-hoc 서명은 배포 준비 검사에서 거부합니다. Developer ID·공증과 외부 Mac 설치 시험은 별도입니다.

실제 feed 생성 회귀검사는 패키지 ZIP과 기존 로컬 Sparkle 키가 있는 Mac에서 실행합니다. 임시 폴더에 feed를 생성해 노트 원문 보존과 서명 유효성을 확인하고, 두 노트 사본을 함께 변조해도 서명 검사가 거부하는지 확인합니다. 개인 키가 없는 공개 CI에서는 기존 오프라인 배포 검사만 실행합니다.

```sh
python3 scripts/check-update-feed-generation.py \
  dist/releases/1.5.14-build30/HappyLulu-1.5.14-universal.zip
```

`generate_appcast --disable-signing-warning`은 노트에 붙이는 안내 주석만 억제합니다. archive·노트·feed 서명은 유지하며, 서명 후 노트를 원문으로 되돌리지 않습니다.

`dist/releases/<version>-build<build>/`에 앱, ZIP, DMG, 노트, 라이선스, `updates/appcast.xml`, 서명된 노트, `build-source.json`, `release.json`, `SHA256SUMS.txt`를 보관합니다. 빌드 시작 때 기록한 소스 commit과 clean 상태가 현재 checkout과 일치해야 배포 준비를 통과합니다. manifest는 버전, build, feed, 공개키와 코드 서명 requirement도 연결합니다. 체크섬은 업로드할 모든 파일을 열거합니다. 경로 이탈·symlink·중복/누락 체크섬·변조·다른 URL/버전의 feed는 거부합니다. 서명 후 산출물을 수정하거나 같은 build를 재사용하지 않습니다. 기존 준비 폴더가 있으면 자동 덮어쓰지 않습니다.

## 검증된 후보를 draft로 올리기

소스 commit이 GitHub에 존재하고 실제 원격 쓰기가 승인된 뒤 실행합니다. `--dry-run`은 로컬 검사와 명령 미리보기만 수행합니다.

```sh
python3 scripts/release_delivery.py draft dist/releases/1.5.14-build30 --dry-run
python3 scripts/release_delivery.py draft dist/releases/1.5.14-build30
```

`macos-v1.5.14-build30` draft를 명시적인 소스 SHA에서 만들고 ZIP·DMG·노트·라이선스·체크섬·manifest·서명 appcast를 올립니다. 이미 있는 lightweight/annotated 태그는 실제 commit까지 따라가 확인하며 다른 commit이면 draft 생성과 승격 전에 중단합니다. 업로드 후 다시 내려받아 모든 바이트를 로컬 후보와 대조합니다. 기존 태그의 Release는 덮어쓰지 않습니다. 실패한 draft는 원인을 확인한 후 운영자가 처리하며 자동 삭제하지 않습니다.

## 실제 업데이트 시험과 명시적 승격

draft 준비만으로 승격하지 않습니다. 승인된 실제 HappyLulu 업데이트 시험에서 교체·재실행과 캘린더 권한·출근 기록·캘린더 연결 유지가 확인되어야 합니다. 이 시험은 사용자 앱·기록을 다루므로 별도 승인된 절차로 수행합니다. fixture 자동 업데이트 시험만으로 아래 결과를 true로 쓰지 않습니다.

증거 JSON은 Git 밖의 로컬 경로에 둡니다. 기록 원문이나 계정 정보를 넣지 않고 시험 로그의 경로만 참조합니다. 다음 예시는 미완료 상태이며 그대로는 승격되지 않습니다.

```json
{
  "schema": 1,
  "sourceCommit": "release.json의 sourceCommit",
  "version": "1.5.10",
  "build": "26",
  "archiveSHA256": "SHA256SUMS.txt의 ZIP 해시",
  "calendarPermissionPreserved": false,
  "attendancePreserved": false,
  "calendarConnectionsPreserved": false,
  "updateInstalledAndRelaunched": false,
  "testedAt": "",
  "operator": "",
  "evidence": ""
}
```

```sh
python3 scripts/release_delivery.py promote dist/releases/1.5.14-build30 \
  --permission-evidence /absolute/local/permission-evidence.json --dry-run
python3 scripts/release_delivery.py promote dist/releases/1.5.14-build30 \
  --permission-evidence /absolute/local/permission-evidence.json
python3 scripts/release_delivery.py readback dist/releases/1.5.14-build30
```

승격은 후보와 증거를 대조하고 draft 자산을 재다운로드 검증한 뒤 버전 Release를 공개합니다. 이어 고정 `macos-update-feed` prerelease의 appcast를 서명 바이트 그대로 게시하고 Latest 표시를 끕니다. 이전 feed는 서명을 확인하고 로컬 `receipts/`에 보존하며 build 역행·같은 build의 다른 feed는 거부합니다. GitHub의 immutable Releases 정책이 켜져 있으면 고정 feed를 갱신할 수 없으므로 사전에 이 운영 방식과 정책을 조정해야 합니다.

공개 단계는 원자적 트랜잭션이 아닙니다. 버전 공개 후 feed 교체가 실패하면 버전 파일을 유지하고 오류를 고친 뒤 같은 후보의 `promote`를 다시 실행합니다. 이미 공개된 버전도 동일 파일·commit일 때만 재개합니다. `--clobber`는 고정 feed의 appcast 한 파일에만 사용합니다. 업로드 실패 시 보존한 이전 서명본을 복구하려고 시도하고 실패를 보고합니다. 네트워크 문제로 복구도 실패해 자산이 없거나 업로드 미완료 상태·0바이트로 남았다면 `receipts/feed-promotion.json`과 이전 서명본이 같은 후보를 가리킬 때만 재개합니다. 따라서 실패 뒤에도 로컬 준비 폴더와 receipts를 보존합니다. 한 번에 한 운영자만 승격합니다.

최종 readback은 버전 태그 SHA, 원격 자산 목록·다운로드 바이트, 인증 없는 공개 HTTPS URL의 파일 바이트와 고정 feed를 대조합니다. 이 검사 성공도 사용자 설치 성공을 대신하지 않습니다. 기존 사이트 feed를 읽는 앱의 자동 이전은 [UPDATES.md](UPDATES.md)의 별도 이전 조건을 따릅니다.

## 사용자 설치 시험 없이 명시적으로 승인된 공개

위 `promote`는 실제 설치·권한 보존 증거를 요구하며 이 조건을 완화하거나 fixture 결과로 채우지 않습니다. 사용자가 사용자 앱 교체를 제외한 채 릴리즈·사이트·피드 공개를 명시적으로 요청한 경우에는 다음 별도 수동 공개 절차를 사용합니다. 이는 설치 검증 완료를 뜻하지 않습니다.

1. 깨끗한 검토 소스에서 기존 고정 인증서·Sparkle 키로 준비하고 `check`·서명·변조 거부·최종 커밋 CI를 통과합니다. 새 키 생성이나 보안 설정 변경이 필요하면 중단합니다.
2. `draft`로 신규 버전 자산을 올리고 원격 바이트를 대조합니다. 버전별 기존 자산은 덮어쓰지 않습니다.
3. 실제 사용자 앱 교체·권한 유지·사용자 세션이 미검증임을 릴리즈 노트에 명시하고 승인된 신규 버전만 수동으로 공개합니다. 이때 완료되지 않은 설치 증거 JSON을 만들지 않습니다.
4. 이전 고정 피드의 서명·바이트를 비공개 receipts에 보존하고 증가한 build의 서명 appcast만 게시합니다. 고정 피드 한 파일의 갱신과 버전 자산 보존을 구분합니다.
5. 공개 버전 자산·피드의 바이트를 재확인하고 기존 사이트의 다운로드와 피드를 같은 서명본에 맞춥니다. 외부 설치 성공·권한 유지·자동 이전 성공은 별도 검증으로 남깁니다.

## 공개 CI와 Windows

macOS CI는 로직·격리 통합·오프라인 배포 검사를 실행하고 명시적 ad-hoc Universal ZIP·DMG를 artifact로 보관합니다. `HappyLulu-macos-unsigned-for-distribution-<sha>`는 배포 서명·권한 유지 검증을 마친 릴리스가 아닙니다. GitHub Release에 그대로 승격하지 않습니다.

Windows CI의 기존 `HappyLulu-1.5.13-windows-x64`, `HappyLulu-1.5.13-windows-x64-runtime-required` artifact와 새 `HappyLulu-1.5.13-windows-checksums`를 같은 성공한 run에서 받습니다. 두 ZIP은 LICENSE와 THIRD_PARTY_NOTICES.md를 동봉하고, self-contained ZIP은 Windows .NET 배포본의 LICENSE.txt·ThirdPartyNotices.txt도 `licenses/dotnet/`에 보존합니다. 기존 .NET 출력 고지는 삭제하지 않습니다. [Microsoft 배포 구조](https://learn.microsoft.com/en-us/dotnet/core/distribution-packaging)와 [.NET 라이선스 자산 규칙](https://github.com/dotnet/runtime/blob/main/docs/project/licensing-assets.md)을 따릅니다.

```sh
gh run download RUN_ID --repo young221718/happylulu-app \
  --name HappyLulu-1.5.13-windows-x64 --dir dist/windows-release
gh run download RUN_ID --repo young221718/happylulu-app \
  --name HappyLulu-1.5.13-windows-x64-runtime-required --dir dist/windows-release
gh run download RUN_ID --repo young221718/happylulu-app \
  --name HappyLulu-1.5.13-windows-checksums --dir dist/windows-release
(cd dist/windows-release && shasum -a 256 -c SHA256SUMS.txt)
```

다운로드 run의 source SHA와 Windows 버전, 두 ZIP 내부 고지, Windows 실기기 결과를 확인합니다. 새 버전을 낼 때 workflow의 버전·artifact 이름도 함께 갱신합니다. 승인된 별도 `windows-v<VERSION>` Release를 `gh release create ... --draft --target SOURCE_SHA --notes-file NOTES_FILE --latest=false`로 준비하고, 업로드 파일을 다시 받아 체크섬을 대조한 후 명시적으로 `gh release edit TAG --draft=false --latest=false`로 공개합니다. Mac의 고정 feed 태그나 Mac ZIP을 Windows Release에 섞지 않습니다. Windows용 자동 업데이트 서명·설치는 아직 이 경로의 범위가 아닙니다.
