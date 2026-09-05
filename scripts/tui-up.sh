#!/bin/bash
# codex TUI 기동 스크립트 — 부팅(LaunchAgent) 및 수동 복구(npm run tui:up) 공용.
# 전용 tmux 세션에 codex TUI를 띄우고, 롤아웃 파일 생성을 위한 더미 턴 1회를 보낸다.
# 규칙 각인은 워크스페이스 AGENTS.md가 담당하므로 여기서는 아무 한마디면 된다.
# 설정은 전부 프로젝트 루트 .env에서 읽는다 (CODEX_BIN, CODEX_WORKDIR, TUI_PANE).
# 인스턴스 지원: 첫 인자로 env 파일을 지정하면 그 설정으로 뜬다 (기본 .env — 하위 호환).
#   예: scripts/tui-up.sh .env.collab
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-.env}"
[[ "$ENV_FILE" == /* ]] || ENV_FILE="$PROJECT_DIR/$ENV_FILE"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "오류: $ENV_FILE 없음 — .env.example을 복사해 채우세요" >&2
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

# tmux 탐지: PATH → Apple Silicon → Intel 순 (변수명 TMUX는 tmux의 소켓 경로 예약 변수라 금지)
TMUX_BIN=$(command -v tmux || true)
[[ -z "$TMUX_BIN" && -x /opt/homebrew/bin/tmux ]] && TMUX_BIN=/opt/homebrew/bin/tmux
[[ -z "$TMUX_BIN" && -x /usr/local/bin/tmux ]] && TMUX_BIN=/usr/local/bin/tmux
if [[ -z "$TMUX_BIN" ]]; then
  echo "오류: tmux를 찾을 수 없음 — brew install tmux" >&2
  exit 1
fi

CODEX_BIN="${CODEX_BIN:-$(command -v codex || true)}"
if [[ -z "$CODEX_BIN" || ! -x "$CODEX_BIN" ]]; then
  echo "오류: codex를 찾을 수 없음 — .env에 CODEX_BIN을 지정하거나 PATH에 codex를 두세요" >&2
  exit 1
fi
: "${CODEX_WORKDIR:?오류: .env에 CODEX_WORKDIR 필요}"
PANE="${TUI_PANE:-codex-live:0.0}"
SESSION="${PANE%%:*}"
CODEX_CMD="$CODEX_BIN -s workspace-write -c sandbox_workspace_write.network_access=true"

log() { echo "[$(date '+%F %T')] $*"; }

# 이미 codex가 떠 있으면 아무것도 하지 않는다 (멱등)
# npm 배포판은 codex가 `#!/usr/bin/env node` 런처라 pane_current_command가 node로
# 잡힌다(2026-08-05 E2E 실측) — 직접 실행 세션에서 node면 codex 런처다.
if $TMUX_BIN has-session -t "$SESSION" 2>/dev/null; then
  cmd=$($TMUX_BIN display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null || true)
  if [[ "$cmd" == *codex* || "$cmd" == node ]]; then
    log "codex 이미 실행 중 ($SESSION, $cmd) — 종료"
    exit 0
  fi
  log "세션은 있으나 codex 아님($cmd) — 세션 재생성"
  $TMUX_BIN kill-session -t "$SESSION"
fi

# 셸에 타이핑하지 않고 세션 명령으로 직접 실행한다 — 대화형 zsh의 compinit
# 프롬프트가 send-keys 첫 글자를 삼켜 기동이 통째로 실패하는 경합 실측
# (2026-08-05 E2E, 2/2 재현: insecure directories 프롬프트가 '/'를 응답으로 소비).
# codex가 종료하면 pane·세션도 닫힌다 — 재기동은 이 스크립트 재실행(멱등).
# PATH 전파: env 셔뱅(#!/usr/bin/env node)이 tmux 서버 환경에서도 node를 찾도록.
# 기존 tmux 서버의 maxfiles=256 상속을 피하도록 pane 안에서 soft limit을 올린다.
# 바깥 기동 스크립트에서만 ulimit을 바꾸면 기존 서버의 자식에는 적용되지 않는다.
$TMUX_BIN new-session -d -s "$SESSION" -c "$CODEX_WORKDIR" -x 200 -y 50 \
  "ulimit -Sn 8192 && PATH=\"$PATH\" exec $CODEX_CMD"
log "codex TUI 직접 기동 (셸 비경유)"

# 세션 특정은 화면 UUID가 아니라 롤아웃 파일 session_meta(cwd)로 한다 —
# codex v0.146.0 기본 설정은 세션 UUID를 화면 어디에도 표시하지 않는다
# (2026-08-05 E2E 실측: 표시 여부가 버전·로컬 설정에 따라 흔들리는 검출원).
# 롤아웃은 첫 턴 후에 생기므로 순서는 "기동 → 준비 대기 → 더미 턴 → 롤아웃 대기".
STAMP=$(mktemp "${TMPDIR:-/tmp}/tui-up-stamp.XXXXXX")
trap 'rm -f "$STAMP"' EXIT

# TUI 준비 대기: 입력 프롬프트(›)나 배너가 뜰 때까지 (최대 180초 —
# 부팅 직후엔 시스템 부하로 codex 기동이 60초를 넘긴다, 2026-07-30·07-31 실측)
READY=""
for _ in $(seq 1 180); do
  sleep 1
  CAP=$($TMUX_BIN capture-pane -p -t "$PANE" 2>/dev/null || true)
  if grep -qE '›|OpenAI Codex' <<<"$CAP"; then READY=1; break; fi
done
if [[ -z "$READY" ]]; then
  log "실패: 180초 내 TUI 미기동 — pane 화면 확인 필요"
  exit 1
fi
log "TUI 준비 확인"

# 더미 턴 1회 — 롤아웃 파일은 첫 턴 이후에 생성된다
sleep 2
$TMUX_BIN send-keys -t "$PANE" "Boot check. Reply with one short line."
sleep 1  # 텍스트 처리 전 Enter가 도착하면 제출되지 않음 (pasteToPane와 동일한 이유)
$TMUX_BIN send-keys -t "$PANE" Enter
log "더미 턴 전송"

# cwd 일치 신규 롤아웃 파일 대기 (최대 180초 — 부팅 부하 여유, 2026-07-31 상향)
# 부팅 부하로 Enter가 텍스트 처리 전에 도착하면 문구가 입력줄에 남고 제출되지 않는다
# (2026-07-29 실측) → 10초마다 입력줄을 확인해 우리가 보낸 문구가 남아 있으면 Enter 재전송.
for i in $(seq 1 180); do
  sleep 1
  FILE=""
  while IFS= read -r f; do
    if head -1 "$f" 2>/dev/null | grep -qF "\"cwd\":\"$CODEX_WORKDIR\""; then
      FILE="$f"; break
    fi
  done < <(find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -type f -newer "$STAMP" 2>/dev/null)
  if [[ -n "$FILE" ]]; then
    SID=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$FILE" | tail -1 || true)
    log "codex 세션 감지(롤아웃): ${SID:-확인불가} — $FILE"
    log "준비 완료"
    exit 0
  fi
  if (( i % 10 == 0 )); then
    # 마지막 › 줄 = 입력줄. 제출 전엔 우리 문구, 제출 후엔 빈 줄/codex 제안 문구.
    LAST_INPUT=$($TMUX_BIN capture-pane -p -t "$PANE" | grep '›' | tail -1 || true)
    if [[ "$LAST_INPUT" == *"Boot check"* ]]; then
      $TMUX_BIN send-keys -t "$PANE" Enter
      log "더미 턴 미제출 감지(입력줄 잔류) — Enter 재전송"
    fi
  fi
done
log "경고: cwd 일치 롤아웃 파일 180초 내 미생성 — 첫 호명 시 Discord 경고가 뜨면 TUI에 메시지 한 번 보낼 것"
exit 1
