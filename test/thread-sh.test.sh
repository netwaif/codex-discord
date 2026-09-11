#!/bin/bash
# scripts/thread.sh 오프라인 검증 — 가짜 curl·tmux로 open/rotate/post 의 REST 경로·인자·출력 확인.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/curl" <<FAKE
#!/bin/bash
echo "curl \$*" >> "$T/curl.log"
echo '{"id":"1547999999999123456"}'
FAKE
cat > "$T/tmux" <<FAKE
#!/bin/bash
echo "tmux \$*" >> "$T/tmux.log"
FAKE
chmod +x "$T/curl" "$T/tmux"
printf 'DISCORD_TOKEN=tok\nTUI_CHANNEL_ID=555\nTUI_PANE=gem-live:0.0\n' > "$T/env"
fails=0; ok() { echo "  PASS $1"; }; ng() { echo "  FAIL $1"; fails=$((fails+1)); }
run() { THREAD_CURL="$T/curl" THREAD_TMUX="$T/tmux" bash "$ROOT/scripts/thread.sh" "$@"; }

bash -n "$ROOT/scripts/thread.sh" && ok "bash -n" || ng "bash -n"

out=$(run "$T/env" open "설계 논의" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "1547999999999123456" ]] && ok "open → 스레드 ID 출력" || ng "open (rc=$rc): $out"
grep -q 'POST https://discord.com/api/v10/channels/555/threads' "$T/curl.log" && ok "open: 채널 threads 경로" || ng "open 경로: $(tail -1 "$T/curl.log")"
grep -q 'Authorization: Bot tok' "$T/curl.log" && ok "open: Bot 토큰 헤더" || ng "토큰 헤더"
grep -q '"type": 11' "$T/curl.log" && ok "open: 공개 스레드(type 11)" || ng "type 11"

run "$T/env" open "답글 스레드" 777 >/dev/null 2>&1
grep -q '/channels/555/messages/777/threads' "$T/curl.log" && ok "open: message_id면 messages/{id}/threads" || ng "message thread 경로"

out=$(run "$T/env" rotate 1547858247917117440 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"gem-live:t117440"* ]] && ok "rotate → 창 이름 t117440 예약" || ng "rotate (rc=$rc): $out"
grep -q '/channels/1547858247917117440/messages' "$T/curl.log" && ok "rotate: 스레드에 안내 게시" || ng "rotate 게시"
grep -q "run-shell -b sleep 3; $T/tmux kill-window -t 'gem-live:t117440'" "$T/tmux.log" && ok "rotate: run-shell 지연 kill-window" || ng "rotate tmux: $(cat "$T/tmux.log")"

out=$(run "$T/env" post 42 "안녕" 2>&1); [[ "$out" == "게시됨: 42" ]] && ok "post" || ng "post: $out"
grep -q '"content": "\\uc548\\ub155"\|"content": "안녕"' "$T/curl.log" && ok "post: content 전달" || ng "post content: $(tail -1 "$T/curl.log")"

run "$T/env" bogus >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "알 수 없는 명령 exit 2" || ng "알 수 없는 명령"
run >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "인자 없음 exit 2" || ng "인자 없음"

echo "${fails}개 FAIL"; [[ $fails -eq 0 ]]
