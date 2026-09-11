---
name: setup
description: codex-discord 브리지 설치를 대화로 안내한다. "코덱스 디스코드 설치해줘", "codex discord 브리지 설치", "/codex-discord:setup", 플러그인 설치 직후 셋업 요청에 사용. Discord 봇 생성부터 .env 작성, LaunchAgent 등록(부팅 자동 기동)까지 전 과정을 처리한다.
---

# codex-discord 설치 안내

너는 사용자의 머신에 Discord ↔ Codex CLI 브리지를 설치한다. 플러그인 캐시는 업데이트 때 경로가 바뀌므로, **반드시 안정적인 위치로 복사한 뒤 그곳에서 설치**한다.

## 진행 원칙

- 단계마다 결과를 확인하고 다음으로 넘어간다. 실패하면 멈추고 원인을 보여준다.
- Discord 개발자 포털 조작(봇 생성·토큰 발급)은 사용자만 할 수 있다 — 정확한 클릭 경로를 안내하고 결과값(토큰 등)을 받아 적는다.
- 토큰은 .env에만 쓴다. 채팅에 다시 출력하지 않는다.

## 단계

### 1. 사전 점검

```bash
uname            # Darwin이어야 함 (macOS 전용 — launchd 사용)
node --version   # v22 이상
command -v tmux || ls /opt/homebrew/bin/tmux /usr/local/bin/tmux
command -v codex || ls ~/.local/bin/codex
```

없는 것이 있으면 설치를 안내한다: Node 22+(nvm 권장), `brew install tmux`, Codex CLI(https://developers.openai.com/codex/cli). 전부 갖춰질 때까지 다음 단계로 가지 않는다.

### 2. 프로젝트 복사

설치 위치를 사용자에게 확인한다 (기본 제안: `~/codex-discord`).

플러그인 루트(이 SKILL.md 파일 기준 두 단계 위 디렉토리 — Claude Code는 `${CLAUDE_PLUGIN_ROOT}` 변수로도 참조 가능)를 통째로 복사한다:

```bash
cp -R <플러그인 루트> ~/codex-discord
cd ~/codex-discord && npm install --omit=dev
```

### 3. Discord 봇 준비 (사용자 조작)

사용자에게 순서대로 안내한다:

1. https://discord.com/developers/applications → **New Application** → 이름 입력(예: Codex Bot)
2. 왼쪽 **Bot** 탭 → **Reset Token** → 토큰 복사 (한 번만 표시됨)
3. 같은 화면 아래 **Privileged Gateway Intents** → **MESSAGE CONTENT INTENT** 켜기 → Save
4. 왼쪽 **OAuth2 → URL Generator** → Scopes에서 `bot` 체크 → Bot Permissions에서 `View Channels`, `Send Messages`, `Attach Files`, `Read Message History` 체크 → 생성된 URL로 봇을 서버에 초대
5. Discord 앱에서 **설정 → 고급 → 개발자 모드** 켜기 → 자기 프로필 우클릭 → **ID 복사** (ALLOWED_USER_IDS용)
6. (라이브 TUI 모드를 쓸 경우) 브리지 전용 채널 우클릭 → **ID 복사** (TUI_CHANNEL_ID용)

### 4. .env 작성

`.env.example`을 `.env`로 복사하고 사용자에게 받은 값으로 채운다:

- `DISCORD_TOKEN` — 3-2의 토큰
- `ALLOWED_USER_IDS` — 3-5의 사용자 ID (쉼표 구분으로 여러 명 가능)
- `CODEX_WORKDIR` — codex가 작업할 폴더 절대경로 (사용자에게 확인, 예: `~/codex-workspace` → 절대경로로 변환)
- `CODEX_BIN` — 1단계에서 찾은 codex 절대경로
- `TUI_PANE=codex-live:0.0` / `TUI_CHANNEL_ID` — 라이브 TUI 모드를 쓸 때만 (안 쓰면 둘 다 비움)

### 5. 설치 실행

```bash
bash scripts/install.sh
```

이 스크립트가 하는 일: 경로 자동 탐지 → 워크스페이스에 AGENTS.md 설치 → LaunchAgent 2개 생성·등록(로그인 시 자동 기동: codex TUI + 데몬) → 데몬 로그인 확인. 출력의 "데몬 로그인 확인" 줄이 보이면 성공.

실패 시 `logs/daemon.log`(토큰 오류 등)와 `logs/tui-up.log`를 확인해 원인을 보여준다.

### 6. 동작 확인

사용자에게 안내한다:

- Discord에서 봇이 있는 채널에 아무 메시지 → 봇이 codex 응답을 릴레이하면 성공 (headless 모드)
- 라이브 TUI 모드 채널이면 봇 멘션 또는 `코덱스`로 시작하는 메시지로 호명
- TUI 화면 구경: `tmux attach -t codex-live`
- 이후 재부팅하면 전부 자동으로 올라온다. 낮에 TUI가 죽으면 `npm run tui:up`

## (선택) Gemini 봇 병행 설치

사용자가 Gemini도 원하면 (Antigravity CLI 필요 — `command -v agy`로 확인):

1. 3단계를 반복해 **두 번째 봇 계정**(예: "Gemini Bot")을 만들고 토큰 발급 (같은 서버에 초대)
2. `.env.gemini.example`을 `.env.gemini`로 복사해 채운다 — `ENGINE=agy`, `DATA_DIR=data-gemini`는 그대로 두고, `CODEX_WORKDIR`는 codex와 다른 폴더 권장
3. `bash scripts/install.sh` 재실행 → `com.codex-discord.gemini` 데몬이 추가 등록된다
4. 확인: `logs/daemon-gemini.log`에 "로그인: ... / 엔진 agy" 줄
5. (선택) Gemini도 라이브 TUI 모드로 쓰려면 `.env.gemini`에 `TUI_PANE=gemini-live:0.0`·`TUI_CHANNEL_ID`를 넣고 `bash scripts/tui-up.sh .env.gemini` — codex와 같은 방식으로 pane에 agy TUI가 뜨고 그 채널이 연결된다

agy가 없는 사용자에게는 이 단계를 권하지 않는다 (Antigravity 미사용자는 codex 단독으로 충분).

## 문제 해결

- 봇이 응답 없음: `logs/daemon.log` 확인. "Used disallowed intents" → 3-3 인텐트 누락
- "롤아웃 파일이 아직 없음" 경고: `tmux attach -t codex-live`로 들어가 아무 메시지나 한 번 보내면 해소
- 재설치: `bash scripts/install.sh` 재실행 (멱등)
