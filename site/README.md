# HappyLulu 소개 사이트

이 디렉터리가 GitHub의 사이트 정본입니다. [공식 사이트](https://happylulu.cy-choi-lulu.chatgpt.site/)는 ‘작은 번거로움은 덜고, 내 일에 집중.’ 컨셉으로 다운로드·할 수 있는 일·사용 방법에 집중합니다. 앱 릴리즈·전체 변경 기록·체크섬·서명 업데이트 피드는 GitHub가 담당합니다. 사이트의 릴리즈 노트 복제본은 제거했으며 기존 `/releases/`와 `/en/releases/`는 GitHub Releases로 이동하는 안내만 남깁니다.

- `dist/`: 빌드 없이 게시할 한·영 HTML/CSS/JS와 브랜드 원본 이미지
- `.openai/hosting.json`: 기존 공식 Sites project_id·공개 범위를 보존하는 정적 배포 선언
- 다운로드: Mac1.5.13 build29 / Windows1.5.13의 GitHub Releases 고정 링크
- 기존 사이트 다운로드 URL은 이전 파일을 보존해 호환합니다. 새 사이트 원본에 앱 바이너리를 커밋하지 않습니다.

```sh
python3 site/check-site.py
python3 -m http.server 8765 --bind 127.0.0.1 --directory site/dist
```

게시할 때 검토·병합된 이 디렉터리의 소스를 기존 Sites checkout으로 반영하고 Sites source helper로 commit/push/archive를 만든 뒤 같은 project_id의 버전으로 게시합니다. Sites 단기 credential은 세션 메모리와 helper stdin으로만 전달하며 GitHub·파일·명령 인자에 저장하지 않습니다. 기존 `dist/downloads/` 호환 파일은 hash 검증 후 게시 checkout에서만 보존합니다. CI는 이 소스의 경로/앵커/버전/외부 목적지/JS 문법을 검사합니다. 공개 URL 화면·모바일·다운로드 응답은 게시 후 확인합니다. 앱 배포는 [DEPLOYMENT.md](../DEPLOYMENT.md)와 별개입니다.

사이트 소스와 그림에도 [비상업·소스 공개 라이선스](../LICENSE)가 적용되며 외부 고지는 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)를 따릅니다.
