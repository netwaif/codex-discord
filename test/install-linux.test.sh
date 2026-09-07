#!/usr/bin/env bash
# install.sh 리눅스 분기 오프라인 테스트 — HARNESS_OS=Linux DRY_RUN=1 (systemctl/npm/launchctl 무접촉).
# 임시 프로젝트 사본에 .env를 만들어 유닛 파일 3종(daemon·tui·gemini)이 생기는지 본다.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/proj"; mkdir -p "$PROJ/scripts" "$PROJ/templates" "$PROJ/node_modules" "$TMP/work"
cp "$DIR/scripts/install.sh" "$DIR/scripts/tui-up.sh" "$PROJ/scripts/"
echo "# AGENTS" > "$PROJ/templates/AGENTS.md"
cat > "$PROJ/.env" <<EOF
DISCORD_TOKEN=x
ALLOWED_USER_IDS=1
CODEX_WORKDIR=$TMP/work
TUI_PANE=codex-live:0.0
TUI_CHANNEL_ID=2
EOF
cp "$PROJ/.env" "$PROJ/.env.gemini"
mkdir -p "$TMP/bin"; printf '#!/bin/sh\n' > "$TMP/bin/agy"; chmod +x "$TMP/bin/agy"
# 안전장치: 리눅스 분기가 launchctl/systemctl/npm에 닿으면 즉시 실패(실기기 LaunchAgent 오염 방지, 2026-09-07 실측)
for c in launchctl systemctl loginctl npm; do printf '#!/bin/sh\necho "FAIL: %s 호출됨" >&2; exit 97\n' "$c" > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"; done
HOME="$TMP" HARNESS_OS=Linux DRY_RUN=1 PATH="$TMP/bin:$PATH" bash "$PROJ/scripts/install.sh" > "$TMP/out.log" 2>&1 || { cat "$TMP/out.log"; echo "FAIL: install.sh exit"; exit 1; }
U="$TMP/.config/systemd/user"
for s in codex-discord-daemon codex-discord-tui codex-discord-gemini; do
  [[ -f "$U/$s.service" ]] || { cat "$TMP/out.log"; echo "FAIL: $s.service 없음"; exit 1; }
done
grep -q 'Restart=always' "$U/codex-discord-daemon.service" || { echo "FAIL: daemon Restart=always 없음"; exit 1; }
grep -q -- '--env-file=.env.gemini' "$U/codex-discord-gemini.service" || { echo "FAIL: gemini env-file"; exit 1; }
grep -q 'tui-up.sh' "$U/codex-discord-tui.service" || { echo "FAIL: tui ExecStart"; exit 1; }
grep -q 'RemainAfterExit=yes' "$U/codex-discord-tui.service" || { echo "FAIL: tui oneshot"; exit 1; }
[[ ! -d "$TMP/Library/LaunchAgents" ]] || { echo "FAIL: 리눅스에서 LaunchAgents 생성"; exit 1; }
[[ -f "$TMP/work/AGENTS.md" ]] || { echo "FAIL: 워크스페이스 AGENTS.md"; exit 1; }
# uninstall 리눅스 경로
HOME="$TMP" HARNESS_OS=Linux DRY_RUN=1 bash "$DIR/scripts/uninstall.sh" >/dev/null
for s in codex-discord-daemon codex-discord-tui codex-discord-gemini; do
  [[ ! -f "$U/$s.service" ]] || { echo "FAIL: $s.service 남음"; exit 1; }
done
echo "install-linux.test OK"
