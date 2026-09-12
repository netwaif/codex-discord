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
# --window <이름>: 새 세션 대신 기존 세션에 스레드 창을 만든다(디스코드 스레드 = 전용 세션, 2026-09-11).
#   세션이 없으면 exit 1(메인 TUI가 먼저). 끝에 `SESSION_ID=<sid> FILE=<경로>` 한 줄을 찍어 데몬이 읽는다.
# --thread <스레드ID>: 창 환경변수 DISCORD_THREAD_ID로 심는다 / --prime "<문구>": 더미 턴 대신 이 문구를 첫 턴으로 보낸다(스레드 프라이밍).
WINDOW=""; THREAD_ID=""; PRIME=""
ORIG_ARGS=("$@")   # 업데이트 뒤 재기동(exec)용 원본 인자
shift $(( $# > 0 ? 1 : 0 ))
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window) WINDOW="${2:?오류: --window 뒤에 창 이름이 필요}"; shift 2 ;;
    --thread) THREAD_ID="${2:?오류: --thread 뒤에 스레드 ID가 필요}"; shift 2 ;;
    --prime)  PRIME="${2:?오류: --prime 뒤에 문구가 필요}"; shift 2 ;;
    *) echo "오류: 알 수 없는 인자: $1 (사용법: tui-up.sh [env파일] [--window <창이름>] [--thread <ID>] [--prime <문구>])" >&2; exit 1 ;;
  esac
done
BOOT_TEXT="${PRIME:-Boot check. Reply with one short line.}"
BOOT_MARK="${BOOT_TEXT:0:10}"
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

# 엔진: codex(기본) | agy — .env의 ENGINE. 아래 ENGINE_CMD·준비 판정·세션 검출원이 엔진별로 갈린다.
ENGINE="${ENGINE:-codex}"
: "${CODEX_WORKDIR:?오류: .env에 CODEX_WORKDIR 필요}"
PANE="${TUI_PANE:-codex-live:0.0}"
SESSION="${PANE%%:*}"
[[ -n "$WINDOW" ]] && PANE="$SESSION:$WINDOW.0"
# tmux 타깃은 정확 일치(=)로 — 세션이 없을 때 유일 접두 일치가 `<이름>-daemon`(folder-bot 데몬 세션)을
# 잡아 데몬을 죽이거나 그 pane에 키를 넣는다(2026-09-11 컨테이너 실측: TUI 재시작이 데몬 세션을 kill).
TS="=$SESSION"; TP="=$PANE"
if [[ "$ENGINE" == "agy" ]]; then
  AGY_BIN="${AGY_BIN:-$(command -v agy || true)}"
  if [[ -z "$AGY_BIN" || ! -x "$AGY_BIN" ]]; then
    echo "오류: agy를 찾을 수 없음 — .env에 AGY_BIN을 지정하거나 PATH에 agy를 두세요" >&2
    exit 1
  fi
  # 무인 pane에서 승인 프롬프트가 뜨면 중계가 멈추므로 자동 승인. --sandbox는 헤드리스와 달리
  # 붙이지 않는다(codex TUI가 workspace-write로 도는 것과 같은 수준). 2026-09-11.
  ENGINE_CMD="$AGY_BIN --dangerously-skip-permissions"
else
  CODEX_BIN="${CODEX_BIN:-$(command -v codex || true)}"
  if [[ -z "$CODEX_BIN" || ! -x "$CODEX_BIN" ]]; then
    echo "오류: codex를 찾을 수 없음 — .env에 CODEX_BIN을 지정하거나 PATH에 codex를 두세요" >&2
    exit 1
  fi
  if [[ "${CODEX_TUI_SANDBOX:-}" == off ]]; then
    # bwrap이 안 도는 환경(도커 컨테이너 — 네임스페이스 생성 거부): 셸 명령마다 "샌드박스 밖 실행" 승인이 떠
    # 무인 pane이 멈춘다(2026-09-11 실측: thread.sh open이 승인 대기). 컨테이너가 바깥 샌드박스이므로 codex 것을 끈다.
    ENGINE_CMD="$CODEX_BIN --dangerously-bypass-approvals-and-sandbox"
  else
    ENGINE_CMD="$CODEX_BIN -s workspace-write -c sandbox_workspace_write.network_access=true"
  fi
  # 프레시 설치에서 codex hooks 신뢰 프롬프트가 무인 봇 기동을 막는다 — 훅은 사용자 자신의 설치분이라
  # 자동화용 공식 플래그로 넘긴다(디렉터리 신뢰는 install.sh가 config.toml에 선등록). 2026-09-07 실측.
  [[ -f "$HOME/.codex/hooks.json" ]] && ENGINE_CMD="$ENGINE_CMD --dangerously-bypass-hook-trust"
fi

log() { echo "[$(date '+%F %T')] $*"; }

# 기동 실패를 조용히 넘기지 않는다 — 웹훅이 있으면 한 줄 알림(탐색 순서는 tui-restart.sh와 동일).
# 웹훅이 없으면 로그뿐이지만, 데몬이 다음 호명 때 복구 안내를 ⚠️로 게시한다(index.mjs ensureTuiTail).
notify_fail() {
  local hook="${BOT_RESTART_WEBHOOK:-}"
  [[ -z "$hook" && -f "$HOME/.config/folder-bot/config.json" ]] && hook=$(sed -nE 's/.*"webhook_url" *: *"([^"]+)".*/\1/p' "$HOME/.config/folder-bot/config.json" | head -1)
  [[ -z "$hook" && -f "$HOME/.config/usage-coach/discord.json" ]] && hook=$(sed -nE 's/.*"webhook_url" *: *"([^"]+)".*/\1/p' "$HOME/.config/usage-coach/discord.json" | head -1)
  [[ -n "$hook" ]] || return 0
  curl -sS -m 10 -H 'Content-Type: application/json' \
    -d "{\"content\":\"⚠️ $SESSION TUI 기동 실패 — $1. 복구: $0 $(basename "$ENV_FILE") / 로그: $PROJECT_DIR/logs/\"}" "$hook" >/dev/null || true
}

# 창 모드: 데몬 tail이 붙기 전에 더미 턴의 답이 파일에 기록되길 기다린다(최대 90초) —
# 안 기다리면 "System online and ready." 같은 부팅 답이 스레드에 게시된다(2026-09-11 실측).
wait_boot_reply() {
  [[ -n "$WINDOW" && -z "$SKIP_BOOT" ]] || return 0
  local f="$1" pat="$2"
  for _ in $(seq 1 90); do
    grep -qE "$pat" "$f" 2>/dev/null && { log "부팅 답 기록 확인"; return 0; }
    sleep 1
  done
  log "경고: 부팅 답이 90초 내 기록되지 않음 — 스레드에 부팅 답이 한 번 보일 수 있음"
}

# 이미 codex가 떠 있으면 아무것도 하지 않는다 (멱등)
# npm 배포판은 codex가 `#!/usr/bin/env node` 런처라 pane_current_command가 node로
# 잡힌다(2026-08-05 E2E 실측) — 직접 실행 세션에서 node면 codex 런처다.
SKIP_BOOT=""   # 창 모드에서 엔진이 이미 살아 있으면 기동·더미 턴을 건너뛰고 검출만 한다
if [[ -n "$WINDOW" ]]; then
  if ! $TMUX_BIN has-session -t "$TS" 2>/dev/null; then
    echo "오류: 세션 $SESSION 없음 — 메인 TUI를 먼저 띄우세요" >&2
    exit 1
  fi
  if $TMUX_BIN list-windows -t "$TS" -F '#W' 2>/dev/null | grep -qx "$WINDOW"; then
    cmd=$($TMUX_BIN display-message -p -t "$TP" '#{pane_current_command}' 2>/dev/null || true)
    if [[ "$cmd" == *"$ENGINE"* || ( "$ENGINE" == codex && "$cmd" == node ) ]]; then
      log "$ENGINE 이미 실행 중 ($PANE, $cmd) — 세션 검출만"
      SKIP_BOOT=1
    else
      log "창은 있으나 $ENGINE 아님($cmd) — 창 재생성"
      $TMUX_BIN kill-window -t "$TS:$WINDOW"
    fi
  fi
elif $TMUX_BIN has-session -t "$TS" 2>/dev/null; then
  cmd=$($TMUX_BIN display-message -p -t "$TP" '#{pane_current_command}' 2>/dev/null || true)
  if [[ "$cmd" == *"$ENGINE"* || ( "$ENGINE" == codex && "$cmd" == node ) ]]; then
    log "$ENGINE 이미 실행 중 ($SESSION, $cmd) — 종료"
    exit 0
  fi
  log "세션은 있으나 $ENGINE 아님($cmd) — 세션 재생성"
  $TMUX_BIN kill-session -t "$TS"
fi

# 셸에 타이핑하지 않고 세션 명령으로 직접 실행한다 — 대화형 zsh의 compinit
# 프롬프트가 send-keys 첫 글자를 삼켜 기동이 통째로 실패하는 경합 실측
# (2026-08-05 E2E, 2/2 재현: insecure directories 프롬프트가 '/'를 응답으로 소비).
# codex가 종료하면 pane·세션도 닫힌다 — 재기동은 이 스크립트 재실행(멱등).
# PATH 전파: env 셔뱅(#!/usr/bin/env node)이 tmux 서버 환경에서도 node를 찾도록.
# 기존 tmux 서버의 maxfiles=256 상속을 피하도록 pane 안에서 soft limit을 올린다.
# 바깥 기동 스크립트에서만 ulimit을 바꾸면 기존 서버의 자식에는 적용되지 않는다.
# SSH_* 제거: SSH로 만든 tmux 세션의 env(SSH_CONNECTION)가 run-shell→new-session 경로로 pane에 복사되면
# agy 1.2.1이 원격(헤드리스) 인증 경로로 빠져 "not signed in"(2026-09-11 실측). 봇 pane은 항상 로컬이다.
if [[ -n "$SKIP_BOOT" ]]; then
  :
elif [[ -n "$WINDOW" ]]; then
  # -n으로 이름을 박으면 tmux automatic-rename이 꺼져 창 이름이 프로세스명으로 바뀌지 않는다
  ENV_ARGS=()
  [[ -n "$THREAD_ID" ]] && ENV_ARGS=(-e "DISCORD_THREAD_ID=$THREAD_ID")
  $TMUX_BIN new-window -d -t "$TS" -n "$WINDOW" -c "$CODEX_WORKDIR" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
    "ulimit -Sn 8192 && unset SSH_CONNECTION SSH_CLIENT SSH_TTY; PATH=\"$PATH\" exec $ENGINE_CMD"
  log "$ENGINE 스레드 창 기동 ($PANE)"
else
  $TMUX_BIN new-session -d -s "$SESSION" -c "$CODEX_WORKDIR" -x 200 -y 50 \
    "ulimit -Sn 8192 && unset SSH_CONNECTION SSH_CLIENT SSH_TTY; PATH=\"$PATH\" exec $ENGINE_CMD"
  log "$ENGINE TUI 직접 기동 (셸 비경유)"
fi

# 세션 특정은 화면 UUID가 아니라 롤아웃 파일 session_meta(cwd)로 한다 —
# codex v0.146.0 기본 설정은 세션 UUID를 화면 어디에도 표시하지 않는다
# (2026-08-05 E2E 실측: 표시 여부가 버전·로컬 설정에 따라 흔들리는 검출원).
# 롤아웃은 첫 턴 후에 생기므로 순서는 "기동 → 준비 대기 → 더미 턴 → 롤아웃 대기".
STAMP=$(mktemp "${TMPDIR:-/tmp}/tui-up-stamp.XXXXXX")
trap 'rm -f "$STAMP"' EXIT
[[ -n "$SKIP_BOOT" ]] && touch -t 197001010000 "$STAMP"

if [[ -z "$SKIP_BOOT" ]]; then

# TUI 준비 대기: 입력 프롬프트(›)나 배너가 뜰 때까지 (최대 180초 —
# 부팅 직후엔 시스템 부하로 codex 기동이 60초를 넘긴다, 2026-07-30·07-31 실측)
READY=""
TRUST_SENT=""
UPDATE_SENT=""
for _ in $(seq 1 180); do
  sleep 1
  CAP=$($TMUX_BIN capture-pane -p -t "$TP" 2>/dev/null || true)
  if [[ "$ENGINE" == agy ]]; then
    # agy 배너 "Antigravity CLI" 또는 입력 프롬프트 줄 "> "
    if grep -qE 'Antigravity CLI|^> ' <<<"$CAP"; then READY=1; break; fi
  else
    # 미신뢰 새 폴더의 첫 화면 "Do you trust the contents of this directory?" — 배너와 함께 떠서
    # 준비로 오판되고, 더미 턴 텍스트+Enter가 "2. No, quit"을 골라 codex가 종료된다(WSL2 실기 2026-09-12).
    # Enter 한 번이 기본 선택 "1. Yes, continue". 선등록(botctl add → ~/.codex/config.toml)이 1차 방어, 이건 폴백.
    # 업데이트 프롬프트 — 배너·› 와 함께 떠서 준비로 오판되고, 더미 턴 Enter가 "1. Update now"를 골라
    # 설치 뒤 codex가 종료(exit 0)하면서 pane·세션이 사라진다(2026-08-27 부팅 실측, 0.153.4→0.154.0으로 재현 09-12:
    # "✨ Update available! …" / "› 1. Update now (runs …)" / "2. Skip" / "3. Skip until next version" / Enter →
    # "Update ran successfully! Please restart Codex."). 억제(check_for_update_on_startup=false) 대신 업데이트를
    # 받아들이고 종료를 기다린 뒤 1회 재기동한다(사용자 결정 2026-09-12). 아래 루프 뒤 처리.
    if grep -qF 'Update available!' <<<"$CAP"; then
      $TMUX_BIN send-keys -t "$TP" Enter
      UPDATE_SENT=1
      log "codex 업데이트 프롬프트 감지 — Enter(Update now), 설치·종료 대기(최대 600초)"
      break
    fi
    if grep -qF 'Do you trust the contents' <<<"$CAP"; then
      if [[ -z "$TRUST_SENT" ]]; then
        $TMUX_BIN send-keys -t "$TP" Enter
        TRUST_SENT=1
        log "codex 디렉터리 신뢰 프롬프트 감지 — Enter(Yes, continue)"
      fi
      continue
    fi
    if grep -qE '›|OpenAI Codex' <<<"$CAP"; then READY=1; break; fi
  fi
done
if [[ -n "$UPDATE_SENT" ]]; then
  UPDATED=""
  for _ in $(seq 1 600); do
    sleep 1
    if ! $TMUX_BIN list-panes -t "$TP" >/dev/null 2>&1; then UPDATED=1; break; fi
    # 업데이트가 실패해 codex가 프롬프트 없이 살아 있으면 그대로 준비로 본다
    CAP=$($TMUX_BIN capture-pane -p -t "$TP" 2>/dev/null || true)
    if ! grep -qE 'Update available!|Updating Codex' <<<"$CAP" && grep -qE '›|OpenAI Codex' <<<"$CAP"; then READY=1; break; fi
  done
  if [[ -n "$UPDATED" ]]; then
    if [[ -n "${CODEX_UPDATE_RETRIED:-}" ]]; then
      log "실패: 업데이트 뒤 재기동에서도 업데이트 프롬프트·종료 — CODEX_BIN 경로가 옛 버전을 가리키는지 확인"
      notify_fail "업데이트 후 재기동 실패"
      exit 1
    fi
    log "codex 업데이트 완료(종료 확인) — 재기동"
    CODEX_UPDATE_RETRIED=1 exec bash "$0" "${ORIG_ARGS[@]}"
  fi
  if [[ -z "$READY" ]]; then
    log "실패: 업데이트 600초 내 미종료 — pane 화면 확인 필요"
    notify_fail "업데이트 600초 내 미종료"
    exit 1
  fi
fi
if [[ -z "$READY" ]]; then
  log "실패: 180초 내 TUI 미기동 — pane 화면 확인 필요"
  notify_fail "180초 내 TUI 미기동"
  exit 1
fi
log "TUI 준비 확인"

# 더미 턴 1회 — 롤아웃 파일은 첫 턴 이후에 생성된다
sleep 2
if [[ "$ENGINE" == agy ]]; then
  # agy는 배너가 뜬 직후 입력 위젯이 아직 키를 받지 않아 첫 send-keys가 삼켜진다
  # (2026-09-11 실측: "TUI 준비 확인" 1초 뒤 전송분이 통째로 사라짐. 실제 워크스페이스에서는
  # 인덱싱 탓인지 25초 넘게 안 받는 경우도 있었음) — 문구가 화면에 보일 때까지 최대 ~90초 재전송하고,
  # 보인 뒤에만 Enter.
  SENT=""
  for _ in $(seq 1 18); do
    $TMUX_BIN send-keys -t "$TP" -l "$BOOT_TEXT"
    sleep 2
    if $TMUX_BIN capture-pane -p -t "$TP" | grep -qF "$BOOT_MARK"; then SENT=1; break; fi
    sleep 3
  done
  [[ -n "$SENT" ]] || log "경고: 더미 턴 문구가 화면에 안 보임 — 그래도 Enter 시도"
else
  $TMUX_BIN send-keys -t "$TP" -l "$BOOT_TEXT"
fi
sleep 1  # 텍스트 처리 전 Enter가 도착하면 제출되지 않음 (pasteToPane와 동일한 이유)
$TMUX_BIN send-keys -t "$TP" Enter
log "더미 턴 전송"
fi  # SKIP_BOOT

# agy: brain/<대화ID>/ 디렉터리가 첫 턴 뒤 생긴다 — STAMP보다 새 디렉터리 하나면 준비 완료.
# 대화 ID의 정식 검출은 데몬(agy-transcript.mjs: presence 락 → 배너 → brain 최신)이 한다.
if [[ "$ENGINE" == agy ]]; then
  BRAIN="$HOME/.gemini/antigravity-cli/brain"
  for i in $(seq 1 180); do
    sleep 1
    NEWDIR=$(find "$BRAIN" -mindepth 1 -maxdepth 1 -type d -newer "$STAMP" 2>/dev/null | head -1 || true)
    if [[ -n "$NEWDIR" && -f "$NEWDIR/.system_generated/logs/transcript.jsonl" ]]; then
      log "agy 대화 감지(brain): $(basename "$NEWDIR")"
      wait_boot_reply "$NEWDIR/.system_generated/logs/transcript.jsonl" '"PLANNER_RESPONSE".*"DONE"|"DONE".*"PLANNER_RESPONSE"'
      log "준비 완료"
      echo "SESSION_ID=$(basename "$NEWDIR") FILE=$NEWDIR/.system_generated/logs/transcript.jsonl"
      exit 0
    fi
    if (( i % 10 == 0 )); then
      LAST_INPUT=$($TMUX_BIN capture-pane -p -t "$TP" | grep -E '^> ' | tail -1 || true)
      if [[ "$LAST_INPUT" == *"$BOOT_MARK"* ]]; then
        $TMUX_BIN send-keys -t "$TP" Enter
        log "더미 턴 미제출 감지(입력줄 잔류) — Enter 재전송"
      fi
    fi
  done
  log "경고: brain 대화 디렉터리 180초 내 미생성 — 첫 호명 시 Discord 경고가 뜨면 TUI에 메시지 한 번 보낼 것"
  notify_fail "agy 대화 180초 내 미생성"
  exit 1
fi

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
  done < <(find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -type f -newer "$STAMP" 2>/dev/null | sort -r)
  if [[ -n "$FILE" ]]; then
    SID=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$FILE" | tail -1 || true)
    log "codex 세션 감지(롤아웃): ${SID:-확인불가} — $FILE"
    wait_boot_reply "$FILE" '"role":"assistant"'
    log "준비 완료"
    echo "SESSION_ID=${SID:-} FILE=$FILE"
    exit 0
  fi
  if (( i % 10 == 0 )); then
    # 마지막 › 줄 = 입력줄. 제출 전엔 우리 문구, 제출 후엔 빈 줄/codex 제안 문구.
    LAST_INPUT=$($TMUX_BIN capture-pane -p -t "$TP" | grep '›' | tail -1 || true)
    if [[ "$LAST_INPUT" == *"$BOOT_MARK"* ]]; then
      $TMUX_BIN send-keys -t "$TP" Enter
      log "더미 턴 미제출 감지(입력줄 잔류) — Enter 재전송"
    fi
  fi
done
log "경고: cwd 일치 롤아웃 파일 180초 내 미생성 — 첫 호명 시 Discord 경고가 뜨면 TUI에 메시지 한 번 보낼 것"
notify_fail "롤아웃 180초 내 미생성"
exit 1
