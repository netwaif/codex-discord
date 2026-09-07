#!/usr/bin/env bash
# codex-discord 브리지 제거 — install.sh 의 대응 제거 경로.
# 데몬·gemini 는 node 직속 job → 안전함. tui 는 tmux 세션을 띄우는 job이므로
# bootout 금지(프로세스 그룹째 킬 위험, 2026-07-31 실측), 세션 종료 + plist 삭제만.
set -euo pipefail
OS_NAME="${HARNESS_OS:-$(uname -s)}"
if [[ "$OS_NAME" == "Linux" ]]; then
  # daemon·gemini는 disable --now, tui는 세션만 종료(유닛 stop은 KillMode=process라 안전하지만 mac 규칙과 동형 유지)
  U="$HOME/.config/systemd/user"
  if [[ "${DRY_RUN:-0}" != "1" ]]; then
    systemctl --user disable --now codex-discord-daemon.service 2>/dev/null || true
    systemctl --user disable --now codex-discord-gemini.service 2>/dev/null || true
    systemctl --user disable codex-discord-tui.service 2>/dev/null || true
    tmux kill-session -t codex-live 2>/dev/null || true
  fi
  rm -f "$U/codex-discord-daemon.service" "$U/codex-discord-tui.service" "$U/codex-discord-gemini.service"
  if [[ "${DRY_RUN:-0}" != "1" ]]; then systemctl --user daemon-reload 2>/dev/null || true; fi
  echo "제거됨: systemd 사용자 유닛 3종 (.env*·logs/·data*/ 는 보존)"
  exit 0
fi
UID_N=$(id -u)

if [[ "${DRY_RUN:-0}" != "1" ]]; then
  launchctl bootout "gui/$UID_N/com.codex-discord.daemon" 2>/dev/null || true
  launchctl bootout "gui/$UID_N/com.codex-discord.gemini" 2>/dev/null || true
  tmux kill-session -t codex-live 2>/dev/null || true
fi
rm -f "$HOME/Library/LaunchAgents/com.codex-discord.daemon.plist" \
      "$HOME/Library/LaunchAgents/com.codex-discord.tui.plist" \
      "$HOME/Library/LaunchAgents/com.codex-discord.gemini.plist"
echo "제거됨: LaunchAgent 3종 (.env*·logs/·data*/ 는 보존)"
