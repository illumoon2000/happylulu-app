# HappyLulu 소개 사이트

이 디렉터리가 [공식 사이트](https://happylulu.cy-choi-lulu.chatgpt.site/)의 GitHub 소스 정본입니다. 기존 로고와 ‘작은 번거로움은 덜고, 내 일에 집중.’ 컨셉을 유지하며 홈, 자세한 사용 방법, 기능별 설명, 릴리즈별 설명을 구분합니다. 앱 바이너리·전체 변경 기록·체크섬의 정본은 GitHub Releases입니다.

## 페이지 구성

- `/`, `/en/`: 제품 소개, Mac1.5.15 build31·Windows1.5.13 다운로드, 핵심 기능과 시작 방법.
- `/guide/`, `/en/guide/`: 설치·첫 실행·매일 사용·출근 수정·근무 유형·플러그인·외관·기록·업데이트·문제 해결·플랫폼 차이를 설명합니다. 사용 안내는 GitHub 문서로 넘기지 않습니다.
- `/features/`, `/en/features/`: 기능12개 목록. 각 항목은 독립된 한·영 설명 페이지로 연결합니다.
- `/features/<기능>/`, `/en/features/<기능>/`: 출근 자동 기록, 출근 수정, 근무 유형, 시간 표시, 기록, 캘린더, 플러그인, 다우오피스, 반차 인식, 외관, 퇴근 이후 안내, 업데이트. 개요·사용 방법·예시·지원 범위·관련 기능을 제공합니다.
- `/releases/`, `/en/releases/`: 현재 Mac·Windows와 이전 Mac 버전 목록. 외부 사이트로 자동 이동하지 않습니다.
- `/releases/macos-1.5.15/`, `/releases/macos-1.5.14/`, `/releases/windows-1.5.13/`와 대응 영어 경로: 주요 변화·개선·지원 범위·기능 설명·공식 다운로드·전체 변경 기록 링크.
- 기존 다운로드·설치·캘린더·FAQ와 overtime 경로, 홈의 예전 앵커를 보존합니다. HTML은 총42개이며 별도 프레임워크 빌드 없이 게시할 수 있습니다.

새 패널·다섯 근무 유형·플러그인 관리·외관은 Mac 전용입니다. Windows1.5.13의 기존 기능과 구분하며 다우오피스 개발자는 손정열로 표시합니다. 출근 기록은 로컬에 저장하지만 선택 캘린더·다우오피스 연결은 해당 서비스의 계정·권한·네트워크를 사용합니다. 예시 화면과 일정은 가상 데이터입니다.

## 검증과 미리보기

```sh
python3 site/check-site.py
node --check site/dist/app.js
python3 -m http.server 8765 --bind 127.0.0.1 --directory site/dist
```

검사기는 기존 경로, 사용 방법과 기능/릴리즈의 목록→상세 연결, 설명 구역, 외부 GitHub 사용 문서 링크 금지, 한·영 대응, 로컬 링크·앵커, 기본 다운로드 화면 각각의 정확한 공개 자산, 라이선스와 project_id 보존을 확인합니다. 캘린더 안내 다섯 곳은 읽기 권한·표시 선택·읽기 전용 새로고침을 선택적 동기화보다 먼저 안내하는지도 검사합니다. 공개 파일의 실제 HTTP 응답과 데스크톱·모바일 화면은 별도 확인합니다. 명세는 [사이트 페이지 명세](../docs/site-detail-pages-spec.md)입니다.

## 게시와 호환 자산

`.openai/hosting.json`의 기존 Sites project_id와 공개 범위를 유지합니다. 검토·병합된 이 디렉터리를 기존 Sites 소스 checkout으로 반영하고 공식 Sites source helper의 commit/push/archive 결과로 같은 프로젝트에 게시합니다. 단기 토큰은 메모리에 보관하고 보조 도구의 숨김 stdin으로만 전달하며 파일·명령 인자·로그에 저장하지 않습니다.

기존 Sites 소스의 `dist/downloads/`, `dist/updates/` 등 과거 호환 자산은 게시 checkout에서 바이트와 해시를 보존합니다. 앱 바이너리·서명 키·개인 기록은 GitHub 사이트 소스에 추가하지 않습니다. 이전 사이트 feed의 자동 이전과 실제 앱 설치 성공은 사이트 게시만으로 주장하지 않습니다. 앱 배포 절차는 [DEPLOYMENT.md](../DEPLOYMENT.md)에서 별도로 관리합니다.

사이트 소스와 그림은 [비상업·소스 공개 라이선스](../LICENSE), 외부 구성요소는 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)를 따릅니다.
