#!/bin/bash
# 디스코드 스레드 도우미 — codex/agy 봇 세션이 셸에서 부른다(claude 봇의 bot-thread 대응).
#   thread.sh <env파일> open "<이름>" [message_id]   TUI 채널에 스레드 생성 → 스레드 ID 출력
#   thread.sh <env파일> rotate <스레드ID>            스레드에 안내 게시 후 창을 지연 종료(다음 메시지에 새 세션 + SESSION.md 재정박)
#   thread.sh <env파일> post <스레드ID> "<텍스트>"     스레드에 게시(2000자 이내)
# 설정은 env 파일(DISCORD_TOKEN·TUI_CHANNEL_ID·TUI_PANE)에서 읽는다. THREAD_CURL·THREAD_TMUX로 실행 파일 대체(테스트).
set -uo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-}"; CMD="${2:-}"
[[ -n "$ENV_FILE" && -n "$CMD" ]] || { echo "사용법: thread.sh <env파일> open|rotate|post ..." >&2; exit 2; }
[[ "$ENV_FILE" == /* ]] || ENV_FILE="$PROJECT_DIR/$ENV_FILE"
[[ -f "$ENV_FILE" ]] || { echo "오류: $ENV_FILE 없음" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a
: "${DISCORD_TOKEN:?오류: env에 DISCORD_TOKEN 필요}"
CURL="${THREAD_CURL:-curl}"
TMUX_BIN="${THREAD_TMUX:-$(command -v tmux || echo /opt/homebrew/bin/tmux)}"
API=https://discord.com/api/v10

api() { # METHOD PATH [curl args...]
  local m="$1" p="$2"; shift 2
  "$CURL" -sS -X "$m" "$API$p" -H "Authorization: Bot $DISCORD_TOKEN" "$@"
}
json_id() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("id",""))'; }
post_text() { # TID TEXT
  local payload; payload=$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1][:2000], "allowed_mentions": {"parse": []}}))' "$2")
  api POST "/channels/$1/messages" -H "Content-Type: application/json" -d "$payload" >/dev/null
}

case "$CMD" in
  open)
    name="${3:?오류: 스레드 이름 필요}"; mid="${4:-}"
    : "${TUI_CHANNEL_ID:?오류: env에 TUI_CHANNEL_ID 필요}"
    payload=$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1][:100], "type": 11, "auto_archive_duration": 1440}))' "$name")
    if [[ -n "$mid" ]]; then path="/channels/$TUI_CHANNEL_ID/messages/$mid/threads"; else path="/channels/$TUI_CHANNEL_ID/threads"; fi
    body=$(api POST "$path" -H "Content-Type: application/json" -d "$payload") || { echo "오류: 스레드 생성 요청 실패" >&2; exit 1; }
    tid=$(json_id <<<"$body")
    [[ -n "$tid" ]] || { echo "오류: 스레드 생성 실패: $body" >&2; exit 1; }
    echo "$tid"
    ;;
  rotate)
    tid="${3:?오류: 스레드 ID 필요}"
    SESSION="${TUI_PANE%%:*}"; win="t${tid: -6}"
    post_text "$tid" "재시작 들어감 — 다음 메시지부터 새 세션이 threads/$tid/SESSION.md를 읽고 이어갑니다." || true
    # 세션 자신이 이 스크립트를 실행하므로 창 종료를 tmux 서버에 위탁해 완주시킨다
    "$TMUX_BIN" run-shell -b "sleep 3; $TMUX_BIN kill-window -t '$SESSION:$win'"
    echo "회전 예약: 창 $SESSION:$win 3초 뒤 종료"
    ;;
  post)
    tid="${3:?오류: 스레드 ID 필요}"; text="${4:?오류: 텍스트 필요}"
    post_text "$tid" "$text" && echo "게시됨: $tid"
    ;;
  *) echo "오류: 알 수 없는 명령: $CMD (open|rotate|post)" >&2; exit 2 ;;
esac
