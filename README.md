# codex-discord

Discord 채널 ↔ Codex CLI 브리지. 채널마다 독립된 Codex 세션이 이어진다.

## 준비

1. https://discord.com/developers/applications 에서 앱 생성 → Bot 추가
2. Bot 설정에서 **MESSAGE CONTENT INTENT 활성화** (필수)
3. OAuth2 > URL Generator: scope `bot`, 권한 `Send Messages`, `Read Message History` → 서버에 초대
4. `.env.example`을 `.env`로 복사하고 토큰·사용자ID·작업폴더 기입

## 실행

    npm install
    npm start

## 동작

- allowlist 사용자의 메시지만 처리, 채널당 한 턴씩 직렬 처리
- 채널→세션 매핑은 `data/sessions.json`에 저장 (재시작해도 대화 유지)
- Codex는 항상 `-s workspace-write` 샌드박스로 실행 (전역 config 무관)
- 세션을 새로 시작하려면 `data/sessions.json`에서 해당 채널 항목 삭제

## 라이브 TUI 모드 (3자 대화)

`.env`에 `TUI_PANE`(예: `ai:codex-live`)과 `TUI_CHANNEL_ID`를 지정하면 그 채널은
headless 대신 살아있는 codex TUI 세션과 연결된다.

- 준비: 해당 tmux pane에서 `codex`를 켜고 **메시지를 한 번 보내** 세션 파일을 만들어 둔다
- 코덱스 호명: 봇을 멘션하거나 메시지를 `코덱스`로 시작 (예: "코덱스야 a.py 만들어줘")
- 호명 없는 발언·다른 봇(Claude)의 발언은 쌓였다가 다음 호명 때 `[화자]` 라벨로 함께 전달된다
- Codex의 모든 답변(터미널에서 직접 친 것 포함)이 채널로 릴레이된다
- 과정 구경: TUI pane 화면 그대로
- Claude와의 3자 대화: Claude 세션 쪽 CLAUDE.md에 "응답 전 fetch_messages로
  최근 채널 히스토리를 확인하라"를 넣어야 Claude가 코덱스 발언을 본다
- 데몬 재시작 중·트리거 이전의 TUI 턴은 릴레이되지 않음 (tail은 연결 시점 이후만)
- TUI 세션에서 터미널로 직접 작업한 내용도 전부 채널로 방송됨 — 사적 작업은 다른 세션에서
- 권장: TUI 세션 첫 메시지로 "[화자] 라벨이 붙은 여러 사람의 대화가 들어오고 네 답은 Discord로 중계된다"고 프라이밍

## 파일 첨부 (양방향)

- **Discord → Codex**: 메시지에 파일을 첨부하면 워크스페이스 `uploads/`에 저장되고,
  본문 끝에 `(첨부 파일: uploads/이름)` 주석이 붙어 Codex에게 전달된다 (headless·TUI 공통, 다운로드 상한 25MB)
- **Codex → Discord**: Codex가 답변에 `[[첨부: 경로]]` 한 줄을 포함하면 봇이 그 파일을 채널에 첨부한다
  - 경로는 워크스페이스 기준 상대 경로만 허용 (밖 경로·심링크 탈출은 거부, 상한 10MB)
  - 워크스페이스 밖 파일을 보내려면 Codex가 먼저 워크스페이스 안으로 복사해야 한다
  - TUI 모드에서는 프라이밍에 이 규칙을 알려줘야 한다:
    "파일을 채널에 첨부하려면 답변에 `[[첨부: 워크스페이스 상대경로]]` 한 줄을 넣어라"

## Gemini(Antigravity CLI) 인스턴스 (선택)

같은 코드로 Gemini도 별도 봇으로 병행 운영할 수 있다 (엔진: `agy` — Antigravity CLI):

1. Discord 봇 계정을 하나 더 만들고 (예: "Gemini Bot") 토큰 발급
2. `.env.gemini.example`을 `.env.gemini`로 복사해 채우기 (`ENGINE=agy`, `DATA_DIR=data-gemini` 유지)
3. `bash scripts/install.sh` 재실행 → `com.codex-discord.gemini` 데몬이 추가 등록됨 (수동 실행: `npm run start:gemini`)

동작 방식: 첫 턴은 `agy --new-project`로 작업폴더를 워크스페이스로 잡고, 이후 `--conversation <id>`로 채널별 대화를 이어간다.
도구 실행은 `--sandbox` 안에서 자동 승인된다 (headless는 승인 프롬프트를 띄울 수 없어 필수).
라이브 TUI 모드는 agy 인스턴스에서도 된다(v0.1.9) — `.env.gemini`에 `TUI_PANE`·`TUI_CHANNEL_ID`를 넣고 `bash scripts/tui-up.sh .env.gemini`로 TUI를 띄운다.
agy는 대화별 `~/.gemini/antigravity-cli/brain/<대화ID>/.system_generated/logs/transcript.jsonl`을 실시간으로 쓰므로 데몬이 그 파일을 tail해 답변을 중계한다(codex의 롤아웃 tail과 같은 구조).
대화 ID는 pane 프로세스가 쥔 `presence/<대화ID>.lock` → 배너의 `--conversation=` → brain 최신 디렉터리 순으로 찾는다. TUI는 `--dangerously-skip-permissions`로 기동된다(무인 pane에서 승인 프롬프트가 중계를 막으므로).

참고: Gemini CLI(공식 `gemini`)는 개인 OAuth 지원이 종료되어(IneligibleTierError) 엔진으로 채택하지 않았다 (2026-07-24 실측).

## 운영

- **부팅 자동 기동(macOS)**: `.env`를 채운 뒤 `bash scripts/install.sh` 한 번 — 경로 자동 탐지(node·tmux·codex) 후 LaunchAgent 2개를 생성·등록한다 (멱등, 재실행 = 재설치)
  - `com.codex-discord.tui` → 로그인 시 `scripts/tui-up.sh` 실행: 전용 tmux 세션 `codex-live`에 codex TUI 기동 + 더미 턴 1회(롤아웃 파일 생성용)
  - `com.codex-discord.daemon` → 데몬 상주(`KeepAlive` — 죽거나 부팅 직후 네트워크 미연결로 로그인 실패해도 자동 재시작)
- **플러그인으로 설치** (동봉된 `setup` 스킬이 봇 생성부터 자동 기동 등록까지 대화로 안내 — 마지막에 "코덱스 디스코드 설치해줘"):
  - Claude Code: `/plugin marketplace add netwaif/codex-discord` → `/plugin install codex-discord`
  - Codex CLI: `codex plugin marketplace add https://github.com/netwaif/codex-discord` → `codex plugin add codex-discord@codex-discord`
  - 규칙 각인(라벨 금지·`[[첨부:]]`)은 워크스페이스 `AGENTS.md`가 담당 — 세션마다 프라이밍 입력 불필요
  - 낮에 TUI가 죽으면 `npm run tui:up` 한 줄로 복구 (멱등 — 떠 있으면 아무것도 안 함)
  - TUI 구경: `tmux attach -t codex-live` (기존 `ai` 세션이 아니라 전용 세션이다 — 자동복원과의 경쟁 회피)
- `data/sessions.json`이 손상되면 다음 시작 시 자동으로 `data/sessions.json.bad`로 옮겨지고 채널→세션 매핑은 빈 상태로 초기화된다. 특정 채널의 세션만 리셋하고 싶다면 파일 전체가 아니라 해당 채널 항목만 삭제하면 된다.
