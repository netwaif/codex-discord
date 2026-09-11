#!/bin/bash
# tui-up.sh --window 모드 오프라인 검증 — 가짜 tmux·codex로 (1) 세션 없음 exit 1 (2) 창 생성→더미 턴→롤아웃 검출→SESSION_ID 줄.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/work"
UUID=0195a1b2-1111-4222-8333-444455556666
cat > "$T/bin/tmux" <<FAKE
#!/bin/bash
echo "tmux \$*" >> "$T/tmux.log"
case "\$1" in
  has-session) [[ -n "\${FAKE_SESSION:-}" ]]; exit \$? ;;
  list-windows) exit 0 ;;
  new-window|kill-window) exit 0 ;;
  display-message) echo codex ;;
  capture-pane) echo "› " ;;
  send-keys)
    if [[ "\${@: -1}" == Enter ]]; then
      d="$T/home/.codex/sessions/2026/09/11"; mkdir -p "\$d"
      printf '{"type":"session_meta","payload":{"id":"$UUID","cwd":"$T/work","source":"cli","thread_source":"user"}}\n{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}}\n' > "\$d/rollout-2026-09-11T00-00-00-$UUID.jsonl"
    fi ;;
esac
exit 0
FAKE
printf '#!/bin/bash\nexit 0\n' > "$T/bin/codex"; chmod +x "$T/bin/tmux" "$T/bin/codex"
printf 'CODEX_WORKDIR=%s\nCODEX_BIN=%s/bin/codex\nTUI_PANE=fake-live:0.0\n' "$T/work" "$T" > "$T/env"
fails=0
ok() { echo "  PASS $1"; }; ng() { echo "  FAIL $1"; fails=$((fails+1)); }

bash -n "$ROOT/scripts/tui-up.sh" && ok "bash -n" || ng "bash -n"

# (1) 세션 없음
out=$(HOME="$T/home" PATH="$T/bin:$PATH" bash "$ROOT/scripts/tui-up.sh" "$T/env" --window t000001 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"세션 fake-live 없음"* ]] && ok "세션 없음 → exit 1" || ng "세션 없음 → exit 1 (rc=$rc: $out)"

# (2) 세션 있음 → 창 생성 → 검출
out=$(HOME="$T/home" PATH="$T/bin:$PATH" FAKE_SESSION=1 bash "$ROOT/scripts/tui-up.sh" "$T/env" --window t000001 2>&1); rc=$?
last=$(tail -1 <<<"$out")
[[ $rc -eq 0 ]] && ok "창 모드 exit 0" || ng "창 모드 exit 0 (rc=$rc): $out"
[[ "$last" == "SESSION_ID=$UUID FILE=$T/home/.codex/sessions/2026/09/11/rollout-2026-09-11T00-00-00-$UUID.jsonl" ]] && ok "마지막 줄 SESSION_ID/FILE" || ng "마지막 줄: $last"
grep -q "tmux new-window -d -t =fake-live -n t000001 -c $T/work" "$T/tmux.log" && ok "new-window -n t000001 -c 작업폴더" || ng "new-window 인자: $(grep new-window "$T/tmux.log")"
grep -q "tmux new-session" "$T/tmux.log" && ng "new-session 호출됨(창 모드에서 금지)" || ok "new-session 미호출"
grep -q "send-keys -t =fake-live:t000001.0" "$T/tmux.log" && ok "더미 턴이 창 pane으로" || ng "더미 턴 대상: $(grep send-keys "$T/tmux.log" | head -1)"

# (2b) --thread/--prime
: > "$T/tmux.log"; rm -rf "$T/home/.codex"
out=$(HOME="$T/home" PATH="$T/bin:$PATH" FAKE_SESSION=1 bash "$ROOT/scripts/tui-up.sh" "$T/env" --window t000002 --thread 100 --prime "[스레드 세션] 준비됨 한 단어로" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "--thread/--prime exit 0" || ng "--thread/--prime (rc=$rc): $out"
grep -q -- "-n t000002 -c $T/work -e DISCORD_THREAD_ID=100 " "$T/tmux.log" && ok "new-window -e DISCORD_THREAD_ID" || ng "-e 누락: $(grep new-window "$T/tmux.log")"
grep -q -- "send-keys -t =fake-live:t000002.0 -l \[스레드 세션\] 준비됨 한 단어로" "$T/tmux.log" && ok "프라이밍 문구 전송" || ng "프라이밍: $(grep send-keys "$T/tmux.log" | head -1)"
grep -q "Boot check" "$T/tmux.log" && ng "Boot check 문구가 남아 있음" || ok "Boot check 대체됨"

# (3) 잘못된 인자
HOME="$T/home" PATH="$T/bin:$PATH" bash "$ROOT/scripts/tui-up.sh" "$T/env" --bogus >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "알 수 없는 인자 exit 1" || ng "알 수 없는 인자"

echo "${fails}개 FAIL"; [[ $fails -eq 0 ]]
