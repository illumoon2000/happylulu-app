# HappyLulu 사용자별 ChatGPT 연동 검토

검토일: 2026-10-22. 공식 OpenAI 문서를 읽은 설계 검토이며 로그인·클라이언트 등록·토큰 발급/조회/저장·설정 변경·모델 추론을 실행하지 않았다. 계정별 이용 가능 여부는 미검증이다.

## 판단

**각자가 자기 ChatGPT 요금제로 사용하는 로컬 앱은 공식 경로가 있다.** 현재 Sign in with ChatGPT(SIWC) quickstart는 대상 사용자를 자격을 충족하는 Plus/Pro 이용자로 설명한다. OSS 파트너와 선택된 private client의 plan usage, 제한된 상업 파트너 시험을 구분한다. 모든 사내 계정/요금제에서 사용할 수 있다고 단정하면 안 된다. 신원 로그인과 요금제 사용 동의도 별개다. [SIWC quickstart](https://developers.openai.com/siwc/quickstart)

| 실행 형태 | 검토 결과 |
| --- | --- |
| 사용자의 컴퓨터에서 실행하는 오픈소스 HappyLulu 챗봇 | SIWC의 OSS/local 경로를 적용할 후보. 계정별 동의와 권한을 확인한 다음에야 사용 가능 |
| 기존 로컬 Codex app-server 인증을 이용하는 클라이언트 | 공식 문서는 기존 로컬/오픈소스 사용 지속을 허용하면서 SIWC 이전을 권장 |
| HappyLulu가 운영하는 중앙 다중 사용자 서버 | 기존 app-server 인증을 일반 호스팅 인증으로 사용할 수 없음. SIWC 원격/유료 앱 지원 여부를 별도 확인해야 함 |
| 사용자가 직접 운영하는 OSS VM | 별도 self-hosted VM 문서가 있으나 중앙 SaaS 허용을 뜻하지 않음 |

app-server 문서는 기존 app-server 인증이 상업/호스팅 서비스용으로 허용된 적이 없다고 명시한다. 따라서 로컬 로그인 세션을 수집해 중앙 서버에 공급하는 방식을 제안하지 않는다. SIWC OSS 개요는 open-source/locally hosted 범위를 설명하고, paid/remotely hosted 앱은 별도 관심 등록 경로로 안내한다. [app-server 인증 경계](https://learn.chatgpt.com/docs/app-server#auth-endpoints), [SIWC OSS 개요](https://developers.openai.com/siwc/token-sharing-open-source)

## 인증과 권한의 경계

다음은 HappyLulu에 대한 설계 제안이다. 이번 변경에는 인증 구현을 넣지 않는다.

1. **ChatGPT 신원**: OpenAI가 검증한 사용자 신원과 그 사용자가 선택한 workspace/client 등록을 나타낸다.
2. **ChatGPT 추론 권한**: 신원 확인과 별도로 부여되는 plan usage 권한이다. 유효한 ID token만으로 추론을 허용하지 않는다.
3. **HappyLulu 세션**: HappyLulu의 사용자 연결과 기능 접근을 나타낸다.
4. **다우오피스 인증**: 해당 사용자의 다우오피스 계정, 테넌트, 자산 조회/예약 권한을 별도로 검증한다.
5. **개별 예약 확인**: 대상 자산·기간·예약 주체·작업 내용을 확인한 일회성 동의다. ChatGPT 로그인이나 다우오피스 로그인으로 대체하지 않는다.

SIWC는 앱 자체의 세션·권한·connector 접근을 대신 관리하지 않는다. 신원 권한은 ChatGPT 대화나 일반 OpenAI API 리소스 접근을 주지 않는다. 이메일이 같다는 이유로 기존 HappyLulu 또는 다우오피스 계정을 자동 연결하지 말고, 사용자가 확인하는 별도 연결 절차를 설계해야 한다. [SIWC 권한 구분](https://developers.openai.com/siwc/quickstart#understand-scopes)

향후 승인된 구현에서는 검증된 issuer/subject와 issued client ID를 묶어 등록을 분리한다. 동일 이메일의 다른 등록도 구별하고, 계정 전환은 새로운 신원 검증 완료 후 활성화한다. host ID는 실행 환경 식별자이며 인증 수단이 아니다. 토큰 저장소와 갱신 주체는 사용자별로 분리하고, 브라우저 저장소·로그·분석 이벤트·코드·지원 대화에 토큰을 남기지 않는다. [등록과 검증](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [계정과 세션](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)

## 로컬 app-server 후보 구조

```text
사용자별 HappyLulu 로컬 UI
  ├─ ChatGPT 계정/사용량 표시 (향후 SIWC 연동)
  ├─ 로컬 app-server 자식 프로세스 ↔ 승인된 OpenAI 추론 경로
  └─ 다우오피스 도구 경계
       ├─ 기존 읽기 전용 플러그인
       └─ 별도 쓰기 플러그인: 가용성 → 초안 → 사람 확인 → 명령
```

app-server는 JSON-RPC 기반 클라이언트 인터페이스이며 인증·승인·스트리밍 이벤트·자체 thread 기록을 다룬다. SIWC용 문서는 앱과 app-server 사이에 stdio, app-server와 Responses 사이에 HTTP/SSE를 사용하는 구성을 설명한다. SIWC 토큰 갱신은 호스트 앱 책임이고, 문서의 환경변수 provider 방식은 갱신 후 자식 프로세스를 재시작하고 저장한 로컬 thread ID로 재개한다. `model/list`는 번들 카탈로그일 수 있어 사용 권한 증명이 아니다. [app-server](https://learn.chatgpt.com/docs/app-server), [SIWC app-server 구성](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server)

로컬 MCP 도구 실행은 가능하므로 다우오피스 도구 경계를 붙이는 구조는 검토할 수 있다. 단, 이는 연결된 모든 도구나 쓰기 권한이 자동으로 생긴다는 뜻이 아니다. 공개 읽기 전용 API 계약은 그대로 두고, 쓰기 명령은 별도 등록과 별도 확인 경로에 둔다. 이는 HappyLulu 설계 선택이며 실제 다우오피스 endpoint/payload는 아직 계약 확인이 필요하다.

## 요금제와 API 비용

| 경로 | 과금·한도 판단 |
| --- | --- |
| SIWC plan usage | 기존 Codex/ChatGPT Work 이용 한도에 합산. 앱 연결로 별도 무료 할당량이 생기지 않음 |
| 앱별 사용량 제한 | 전체 주간 한도에 대한 상한이며 예약된 별도 용량이 아님 |
| API key | OpenAI Platform의 사용량 과금. ChatGPT 포함 이용량과 별도 |

Plus의 5시간 한도는 plan usage를 쓰는 앱 사이에 공유되며, 현재 세션 문서는 Pro에 같은 5시간 한도가 적용되지 않는다고 설명한다. 이를 Pro 무제한 보장으로 해석하지 않는다. 정확한 이용 가능 모델, 계정/앱 한도, 잔여량은 실제 계정에서 후속 검증해야 한다. 이번 검토는 사용자 계정이나 사용량을 읽지 않았다. [계정과 세션의 usage 설명](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions#tracking-usage), [사용자용 SIWC 안내](https://learn.chatgpt.com/docs/sign-in-with-chatgpt)

Codex의 API key 사용은 표준 API 과금이며 ChatGPT 플랜 credit을 대신 쓰지 않는다. 따라서 SIWC 실패나 한도 초과 시 API key로 자동 전환하지 않는 것이 설계상 적절하다. 과금 경로 변경은 UI에 알리고 별도 선택으로 둔다. [Codex 인증과 과금](https://learn.chatgpt.com/docs/auth#sign-in-with-an-api-key)

## 현재 preview 제약과 대화/기억

SIWC Responses 경로는 `store: false`, `stream: true`가 필요하다. HTTP 요청은 필요한 문맥을 매번 제공하며 영속 conversation 저장을 가정하지 않는다. hosted MCP/connectors, file search, Code Interpreter, 이미지 생성 등은 이 경로에서 지원하지 않는다. Codex의 로컬 MCP/shell 실행은 이 hosted 도구와 구별된다. app-server 로컬 thread 기록과 `thread/resume`는 가능하다. 세부 필드 제한은 구현 직전에 다시 확인한다. [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)

**SIWC는 기존 ChatGPT 대화나 memories에 대한 접근을 부여하지 않는다.** 따라서 “부엉이로 로그인하면 부엉이 기억과 대화가 그대로 이어진다”는 제품 문구는 부정확하다. 새 앱은 자체 대화 기록과 지시문을 관리해야 한다. 필요한 개인화가 있다면 사용자가 선택해 제공한 최소한의 내용만 별도 동의하에 이용하는 기능을 나중에 설계한다. [사용자용 SIWC 안내](https://learn.chatgpt.com/docs/sign-in-with-chatgpt#use-your-chatgpt-plan)

개인 self-hosted VM 문서는 보호된 SIWC 세션 이전을 설명하지만, 이전된 세션의 host별 사용량 귀속/plan-access 철회는 아직 제공되지 않는다고 명시한다. 이번에는 세션 이전을 수행하지 않았으며, 다중 사용자 서버의 격리 근거로 사용하지 않는다. [Self-hosted VMs](https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms)

## 후속 조건과 미검증

- HappyLulu 배포 형태가 로컬 OSS인지, 중앙 원격 서비스인지 확정하고 SIWC 지원 범위를 다시 확인한다.
- 사용자별 요금제/워크스페이스 자격, 모델, consent, 한도와 상업/원격 앱의 별도 승인 여부를 확인한다.
- 승인된 후속 작업에서만 인증 구현·토큰 수명/철회·계정 전환·세션 격리 테스트를 수행한다.
- 다우오피스의 별도 인증과 자산 예약 API 계약, 권한, 동시성/중복 방지, 결과 재조회 방식은 별도로 확인한다.
- 현재 결과는 문서 근거의 가능성 검토다. OAuth, client 등록, token 처리, 네트워크 추론, 실제 예약은 모두 미실행이며 성공 판정을 내리지 않는다.
