#!/bin/bash
# codex-discord 설치 스크립트 (macOS).
# .env를 읽어 경로를 자동 탐지하고 LaunchAgent 2개를 생성·등록한다.
# 멱등: 재실행하면 기존 등록을 내리고 다시 등록한다.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="$HOME/Library/LaunchAgents"
LABEL_DAEMON=com.codex-discord.daemon
LABEL_TUI=com.codex-discord.tui

fail() { echo "오류: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# ---- 사전 점검 ----
# OS 분기: macOS=launchd, Linux=systemd 사용자 유닛. HARNESS_OS는 테스트 override. DRY_RUN=1이면 파일만.
OS_NAME="${HARNESS_OS:-$(uname -s)}"
case "$OS_NAME" in Darwin|Linux) ;; *) fail "지원하지 않는 OS: $OS_NAME (macOS·Linux만)" ;; esac
[[ -f "$PROJECT_DIR/.env" ]] || fail "$PROJECT_DIR/.env 없음 — .env.example을 복사해 채운 뒤 다시 실행하세요"
set -a; source "$PROJECT_DIR/.env"; set +a
[[ -n "${DISCORD_TOKEN:-}" ]] || fail ".env에 DISCORD_TOKEN 필요"
[[ -n "${ALLOWED_USER_IDS:-}" ]] || fail ".env에 ALLOWED_USER_IDS 필요"
[[ -n "${CODEX_WORKDIR:-}" ]] || fail ".env에 CODEX_WORKDIR 필요"
CODEX_BIN="${CODEX_BIN:-$(command -v codex || true)}"
[[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]] || fail "codex를 찾을 수 없음 — .env에 CODEX_BIN을 지정하거나 PATH에 codex를 두세요"

NODE_BIN=$(command -v node) || fail "node를 찾을 수 없음 (Node 22+ 필요)"
NODE_MAJOR=$("$NODE_BIN" --version | sed 's/^v\([0-9]*\).*/\1/')
[[ "$NODE_MAJOR" -ge 22 ]] || fail "Node 22+ 필요 (현재: $("$NODE_BIN" --version))"

# 라이브 TUI 모드는 선택 — TUI_PANE·TUI_CHANNEL_ID가 둘 다 설정된 경우에만 tmux 필요
TUI_ON=""
[[ -n "${TUI_PANE:-}" && -n "${TUI_CHANNEL_ID:-}" ]] && TUI_ON=1
TMUX_BIN=$(command -v tmux || true)
[[ -z "$TMUX_BIN" && -x /opt/homebrew/bin/tmux ]] && TMUX_BIN=/opt/homebrew/bin/tmux
[[ -z "$TMUX_BIN" && -x /usr/local/bin/tmux ]] && TMUX_BIN=/usr/local/bin/tmux
if [[ -n "$TUI_ON" && -z "$TMUX_BIN" ]]; then
  fail "라이브 TUI 모드(TUI_PANE 설정)에는 tmux 필요 — $([[ "$OS_NAME" == Linux ]] && echo 'apt install tmux' || echo 'brew install tmux')"
fi

log "node=$NODE_BIN / tmux=${TMUX_BIN:-없음} / codex=$CODEX_BIN / TUI=$([[ -n "$TUI_ON" ]] && echo 켬 || echo 끔)"

# ---- 의존성·폴더 준비 ----
if [[ ! -d "$PROJECT_DIR/node_modules" ]]; then
  log "npm install"
  (cd "$PROJECT_DIR" && npm install --omit=dev)
fi
mkdir -p "$PROJECT_DIR/logs" "$CODEX_WORKDIR"
if [[ ! -f "$CODEX_WORKDIR/AGENTS.md" ]]; then
  cp "$PROJECT_DIR/templates/AGENTS.md" "$CODEX_WORKDIR/AGENTS.md"
  log "워크스페이스 AGENTS.md 설치: $CODEX_WORKDIR/AGENTS.md"
else
  log "워크스페이스 AGENTS.md 이미 존재 — 유지"
fi

# ---- plist 생성 ----
# /usr/sbin은 agy(Antigravity CLI)가 내부에서 sysctl을 호출할 때 필요
PATH_LINE="$(dirname "$NODE_BIN"):$(dirname "$CODEX_BIN"):/usr/bin:/bin:/usr/sbin:/sbin"
[[ -n "$TMUX_BIN" ]] && PATH_LINE="$(dirname "$TMUX_BIN"):$PATH_LINE"

if [[ "$OS_NAME" == "Linux" ]]; then
  # ---- 리눅스: systemd 사용자 유닛 3종 ----
  # daemon·gemini = node 상주(Restart=always, launchd KeepAlive 대응). tui = tmux 세션을 띄우는 oneshot —
  # KillMode=process라 stop 때 공유 tmux 서버(다른 봇 세션)를 죽이지 않는다. VPS는 enable-linger로 부팅 자동 기동,
  # WSL2는 우분투가 켜져 있는 동안만 산다(터미널 열어 두기).
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  write_node_unit() {  # <유닛이름> <env파일> <로그파일> <PATH>
    cat > "$UNIT_DIR/$1.service" <<EOF
[Unit]
Description=codex-discord $1 (Discord ↔ codex 브리지)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$PROJECT_DIR
Environment="PATH=$4"
ExecStart=$NODE_BIN --env-file=$2 src/index.mjs
Restart=always
RestartSec=15
StandardOutput=append:$PROJECT_DIR/logs/$3
StandardError=append:$PROJECT_DIR/logs/$3

[Install]
WantedBy=default.target
EOF
  }
  write_node_unit codex-discord-daemon .env daemon.log "$PATH_LINE"
  UNITS=(codex-discord-daemon)
  if [[ -n "$TUI_ON" ]]; then
    cat > "$UNIT_DIR/codex-discord-tui.service" <<EOF
[Unit]
Description=codex-discord 라이브 TUI (tmux 세션 ${TUI_PANE%%:*})
After=codex-discord-daemon.service

[Service]
Type=oneshot
RemainAfterExit=yes
KillMode=process
WorkingDirectory=$PROJECT_DIR
Environment="PATH=$PATH_LINE" "LANG=en_US.UTF-8"
ExecStart=/bin/bash $PROJECT_DIR/scripts/tui-up.sh
ExecStop=$TMUX_BIN kill-session -t ${TUI_PANE%%:*}
StandardOutput=append:$PROJECT_DIR/logs/tui-up.log
StandardError=append:$PROJECT_DIR/logs/tui-up.log

[Install]
WantedBy=default.target
EOF
    UNITS+=(codex-discord-tui)
  else
    rm -f "$UNIT_DIR/codex-discord-tui.service"
  fi
  if [[ -f "$PROJECT_DIR/.env.gemini" ]]; then
    AGY_PATH=$(command -v agy || true)
    [[ -z "$AGY_PATH" && -x "$HOME/.local/bin/agy" ]] && AGY_PATH="$HOME/.local/bin/agy"
    [[ -n "$AGY_PATH" ]] || fail ".env.gemini가 있으나 agy를 찾을 수 없음 — Antigravity CLI를 설치하세요"
    GEMINI_WORKDIR=$(set -a; source "$PROJECT_DIR/.env.gemini"; set +a; echo "$CODEX_WORKDIR")
    if [[ -n "$GEMINI_WORKDIR" ]]; then
      mkdir -p "$GEMINI_WORKDIR"
      [[ -f "$GEMINI_WORKDIR/AGENTS.md" ]] || cp "$PROJECT_DIR/templates/AGENTS.md" "$GEMINI_WORKDIR/AGENTS.md"
    fi
    write_node_unit codex-discord-gemini .env.gemini daemon-gemini.log "$(dirname "$AGY_PATH"):$PATH_LINE"
    UNITS+=(codex-discord-gemini)
  else
    rm -f "$UNIT_DIR/codex-discord-gemini.service"
  fi
  log "유닛 생성: $UNIT_DIR/{$(IFS=,; echo "${UNITS[*]}")}.service"
  if [[ "${DRY_RUN:-0}" != "1" ]]; then
    systemctl --user daemon-reload
    for u in "${UNITS[@]}"; do systemctl --user enable --now "$u.service"; done
    for u in codex-discord-tui codex-discord-gemini; do
      [[ " ${UNITS[*]} " == *" $u "* ]] || systemctl --user disable --now "$u.service" 2>/dev/null || true
    done
    loginctl enable-linger "$USER" 2>/dev/null || true
    log "systemd --user 등록 완료 (VPS: 부팅 자동 기동 / WSL2: 우분투가 켜져 있는 동안)"
    sleep 5
    if grep -q "로그인:" "$PROJECT_DIR/logs/daemon.log" 2>/dev/null; then
      log "데몬 로그인 확인: $(grep '로그인:' "$PROJECT_DIR/logs/daemon.log" | tail -1)"
    else
      log "데몬 로그인 로그 아직 없음 — logs/daemon.log 또는 systemctl --user status codex-discord-daemon 확인"
    fi
  fi
  log "설치 끝. 상태: systemctl --user status ${UNITS[*]}"
  exit 0
fi

mkdir -p "$AGENTS_DIR"

if [[ -n "$TUI_ON" ]]; then
cat > "$AGENTS_DIR/$LABEL_TUI.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL_TUI</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROJECT_DIR/scripts/tui-up.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$PROJECT_DIR/logs/tui-up.log</string>
    <key>StandardErrorPath</key>
    <string>$PROJECT_DIR/logs/tui-up.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$PATH_LINE</string>
        <key>LANG</key>
        <string>en_US.UTF-8</string>
    </dict>
</dict>
</plist>
EOF
fi

cat > "$AGENTS_DIR/$LABEL_DAEMON.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL_DAEMON</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE_BIN</string>
        <string>--env-file=.env</string>
        <string>src/index.mjs</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>15</integer>
    <key>StandardOutPath</key>
    <string>$PROJECT_DIR/logs/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>$PROJECT_DIR/logs/daemon.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$PATH_LINE</string>
    </dict>
</dict>
</plist>
EOF
log "plist 생성: $AGENTS_DIR/$LABEL_DAEMON.plist${TUI_ON:+ + $LABEL_TUI.plist}"

# ---- Gemini(agy) 인스턴스 (.env.gemini 있을 때만) ----
LABEL_GEMINI=com.codex-discord.gemini
if [[ -f "$PROJECT_DIR/.env.gemini" ]]; then
  AGY_PATH=$(command -v agy || true)
  [[ -z "$AGY_PATH" && -x "$HOME/.local/bin/agy" ]] && AGY_PATH="$HOME/.local/bin/agy"
  [[ -n "$AGY_PATH" ]] || fail ".env.gemini가 있으나 agy를 찾을 수 없음 — Antigravity CLI를 설치하세요"
  # gemini 인스턴스 워크스페이스에도 AGENTS.md 설치
  GEMINI_WORKDIR=$(set -a; source "$PROJECT_DIR/.env.gemini"; set +a; echo "$CODEX_WORKDIR")
  if [[ -n "$GEMINI_WORKDIR" ]]; then
    mkdir -p "$GEMINI_WORKDIR"
    [[ -f "$GEMINI_WORKDIR/AGENTS.md" ]] || cp "$PROJECT_DIR/templates/AGENTS.md" "$GEMINI_WORKDIR/AGENTS.md"
  fi
  cat > "$AGENTS_DIR/$LABEL_GEMINI.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL_GEMINI</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE_BIN</string>
        <string>--env-file=.env.gemini</string>
        <string>src/index.mjs</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>15</integer>
    <key>StandardOutPath</key>
    <string>$PROJECT_DIR/logs/daemon-gemini.log</string>
    <key>StandardErrorPath</key>
    <string>$PROJECT_DIR/logs/daemon-gemini.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$(dirname "$AGY_PATH"):$PATH_LINE</string>
    </dict>
</dict>
</plist>
EOF
  log "plist 생성: $AGENTS_DIR/$LABEL_GEMINI.plist (Gemini 인스턴스)"
fi

# ---- 등록 (재실행 대비 bootout 후 bootstrap) ----
UID_N=$(id -u)
launchctl bootout "gui/$UID_N/$LABEL_TUI" 2>/dev/null || true
launchctl bootout "gui/$UID_N/$LABEL_DAEMON" 2>/dev/null || true
launchctl bootout "gui/$UID_N/$LABEL_GEMINI" 2>/dev/null || true
if [[ -n "$TUI_ON" ]]; then
  launchctl bootstrap "gui/$UID_N" "$AGENTS_DIR/$LABEL_TUI.plist"
else
  rm -f "$AGENTS_DIR/$LABEL_TUI.plist"  # 라이브 모드를 껐다면 이전 등록 잔재 제거
fi
launchctl bootstrap "gui/$UID_N" "$AGENTS_DIR/$LABEL_DAEMON.plist"
if [[ -f "$PROJECT_DIR/.env.gemini" && -f "$AGENTS_DIR/$LABEL_GEMINI.plist" ]]; then
  launchctl bootstrap "gui/$UID_N" "$AGENTS_DIR/$LABEL_GEMINI.plist"
fi
log "LaunchAgent 등록 완료 (로그인 시 자동 기동)"

# ---- 확인 ----
sleep 5
if grep -q "로그인:" "$PROJECT_DIR/logs/daemon.log" 2>/dev/null; then
  log "데몬 로그인 확인: $(grep '로그인:' "$PROJECT_DIR/logs/daemon.log" | tail -1)"
else
  log "데몬 로그인 로그 아직 없음 — logs/daemon.log를 확인하세요 (토큰 오류면 여기 찍힘)"
fi
log "설치 끝. TUI 구경: tmux attach -t \${TUI_PANE%%:*} / 수동 복구: npm run tui:up"
