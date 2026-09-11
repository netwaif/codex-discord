import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let bufferSeq = 0;

// 붙여넣기 전 제어문자 제거 — bracketed paste 종료 마커(ESC[201~) 조기 종료 방지.
// \n(0x0a)과 \t(0x09)는 보존.
export function sanitizeForPaste(text) {
  return text.replace(/[\x00-\x08\x0b-\x1f\x7f]/g, '');
}

// 스파이크 검증(2026-07-23): 텍스트와 Enter를 한 호출로 보내면 TUI가 제출하지 않고,
// send-keys로 보낸 줄바꿈은 Enter로 해석돼 중간 제출된다. 그래서
// (1) bracketed paste(-p)로 본문을 붙여넣고 (2) 잠시 후 Enter를 별도 전송한다.
export async function pasteToPane(pane, text) {
  const clean = sanitizeForPaste(text);
  const buf = `codex-bridge-${process.pid}-${++bufferSeq}`;
  await run('tmux', ['set-buffer', '-b', buf, '--', clean]);
  await run('tmux', ['paste-buffer', '-p', '-d', '-b', buf, '-t', pane]);
  await sleep(200 + Math.min(800, Math.floor(clean.length / 50)));
  await run('tmux', ['send-keys', '-t', pane, 'Enter']);
}

export async function paneCurrentCommand(pane) {
  const { stdout } = await run('tmux', ['display-message', '-p', '-t', pane, '#{pane_current_command}']);
  return stdout.trim();
}

export const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g;

// pane 프로세스 트리에 엔진 프로세스가 실존하는가 — 순수 판정부.
// codex: npm 배포판은 `#!/usr/bin/env node` 런처라 pane_current_command가 node로
// 잡힌다(2026-08-05 E2E 실측: 살아 있는 TUI를 죽은 것으로 오탐해 전송 차단).
// 판정: argv0 basename이 <엔진>* 이거나, node/bun 런처의 첫 인자 basename이 <엔진>*.
// agy: Go 단일 바이너리라 argv0 basename이 곧 agy(런처 없음).
function isEngineProc(cmdline, engine) {
  const [argv0, argv1] = cmdline.split(' ');
  const base = (p) => (p ?? '').split('/').pop();
  if (base(argv0).startsWith(engine)) return true;
  return ['node', 'bun'].includes(base(argv0)) && base(argv1).startsWith(engine);
}

export function treeHasEngine(psText, rootPid, engine) {
  const rows = [];
  for (const line of psText.split('\n')) {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
    if (m) rows.push({ pid: m[1], ppid: m[2], cmdline: m[3] });
  }
  const kids = new Map();
  for (const r of rows) {
    if (!kids.has(r.ppid)) kids.set(r.ppid, []);
    kids.get(r.ppid).push(r.pid);
  }
  const ids = new Set([String(rootPid)]);
  const todo = [String(rootPid)];
  while (todo.length) {
    for (const c of kids.get(todo.pop()) ?? []) {
      if (!ids.has(c)) { ids.add(c); todo.push(c); }
    }
  }
  return rows.some((r) => ids.has(r.pid) && isEngineProc(r.cmdline, engine));
}

export const treeHasCodex = (psText, rootPid) => treeHasEngine(psText, rootPid, 'codex');

export async function paneHasEngine(pane, engine = 'codex') {
  const cmd = await paneCurrentCommand(pane);
  if (cmd.includes(engine)) return true;
  const { stdout: pidOut } = await run('tmux', ['display-message', '-p', '-t', pane, '#{pane_pid}']);
  const { stdout: psOut } = await run('ps', ['-axo', 'pid=,ppid=,command=']);
  return treeHasEngine(psOut, pidOut.trim(), engine);
}

export const paneHasCodex = (pane) => paneHasEngine(pane, 'codex');
