#!/bin/bash
# codex TUI 인스턴스 원격 재시작 — 디스코드에서 "세션 마감하고 재시작해"를 받은 codex가 호출한다.
#
# codex가 자기 TUI 세션을 죽이면 재기동을 마저 할 수 없으므로, 재시작 작업을 tmux 서버에
# 위탁(run-shell -b)하고 즉시 반환한다. 위탁된 쪽이 세션을 죽이고 tui-up.sh로 재기동한 뒤
# 성패를 웹훅(선택)으로 통지한다 — folder-bot의 bot-restart.sh와 같은 구조.
#
# 사용: tui-restart.sh [env파일]   (기본 .env — tui-up.sh와 동일 규약, 예: tui-restart.sh .env.collab)
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-.env}"
[[ "$ENV_FILE" == /* ]] || ENV_FILE="$PROJECT_DIR/$ENV_FILE"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "오류: $ENV_FILE 없음" >&2
  exit 1
fi
set -a; source "$ENV_FILE"; set +a
PANE="${TUI_PANE:-codex-live:0.0}"
SESSION="${PANE%%:*}"

TMUX_BIN=$(command -v tmux || true)
[[ -z "$TMUX_BIN" && -x /opt/homebrew/bin/tmux ]] && TMUX_BIN=/opt/homebrew/bin/tmux
[[ -z "$TMUX_BIN" && -x /usr/local/bin/tmux ]] && TMUX_BIN=/usr/local/bin/tmux
[[ -n "$TMUX_BIN" ]] || { echo "tmux를 찾을 수 없음" >&2; exit 1; }

LOG="$PROJECT_DIR/logs/tui-restart.log"
mkdir -p "$(dirname "$LOG")"
log() { echo "[tui-restart $(date '+%F %T')] $*"; }

# --- 1단계(codex가 직접 호출): tmux 서버에 위탁하고 즉시 반환 ---
if [[ "${TUI_RESTART_DETACHED:-}" != 1 ]]; then
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  "$TMUX_BIN" run-shell -b "TUI_RESTART_DETACHED=1 '$SELF' '$ENV_FILE' >> '$LOG' 2>&1"
  echo "재시작 예약됨: $SESSION (몇 초 뒤 TUI 교체, 로그: $LOG)"
  exit 0
fi

# --- 2단계(tmux 서버 아래) ---
log "=== $SESSION 재시작 시작 ($ENV_FILE) ==="

# 웹훅 (없으면 통지 생략) — folder-bot config → usage-coach 순
WEBHOOK="${BOT_RESTART_WEBHOOK:-}"
if [[ -z "$WEBHOOK" && -f "$HOME/.config/folder-bot/config.json" ]]; then
  WEBHOOK=$(sed -nE 's/.*"webhook_url" *: *"([^"]+)".*/\1/p' "$HOME/.config/folder-bot/config.json" | head -1)
fi
if [[ -z "$WEBHOOK" && -f "$HOME/.config/usage-coach/discord.json" ]]; then
  WEBHOOK=$(sed -nE 's/.*"webhook_url" *: *"([^"]+)".*/\1/p' "$HOME/.config/usage-coach/discord.json" | head -1)
fi
notify() {
  [[ -n "$WEBHOOK" ]] || return 0
  curl -s -m 15 -H 'Content-Type: application/json' \
    -d "{\"content\":\"♻️ $SESSION 재시작 — $1\"}" "$WEBHOOK" >/dev/null || true
}

sleep 8  # codex의 마지막 디스코드 답장(롤아웃 relay)이 나갈 시간

"$TMUX_BIN" kill-session -t "=$SESSION" 2>/dev/null || true  # =: 정확 일치(접두로 <이름>-daemon 오살 방지)
if "$PROJECT_DIR/scripts/tui-up.sh" "$ENV_FILE" >> "$LOG" 2>&1; then
  log "판정: ✅ 준비 완료"
  notify "✅ 준비 완료 — '이어서하자'로 재정박"
else
  log "판정: ❌ tui-up 실패 — $LOG 확인"
  notify "❌ 실패 — pane 확인 필요"
fi
log "=== $SESSION 재시작 종료 ==="
