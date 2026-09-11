import { readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);

// agy(Antigravity CLI) 라이브 TUI 모드의 검출원 — codex의 롤아웃(rollout.mjs)에 대응.
// 실측(2026-09-11, agy 1.2.0 맥·1.1.13 컨테이너 동일):
// - 대화별 transcript가 스텝 단위로 실시간 기록된다:
//   ~/.gemini/antigravity-cli/brain/<대화ID>/.system_generated/logs/transcript.jsonl
//   한 줄 = {step_index, source, type, status, created_at, content}.
//   type: USER_INPUT(사용자 턴, <USER_REQUEST> 래핑) / PLANNER_RESPONSE(모델 답변 —
//   도구 호출 중간 스텝은 content가 빈 문자열) / GENERIC(도구 실행 결과).
// - 현재 대화 ID: 살아 있는 agy 프로세스가 presence/<대화ID>.lock 을 열고 있다
//   (pane PID → 열린 파일로 역추적). 기동·종료 배너에도 `agy --conversation=<UUID>`가 찍힌다.
// - 같은 대화를 다른 agy 프로세스로 열면 락 충돌 가능 → 파일 tail만 한다.
// "agy는 롤아웃이 없어 tail 불가"라는 예전 주석은 검증 없는 가정이었다(2026-09-11 정정).
export const AGY_HOME = join(homedir(), '.gemini', 'antigravity-cli');
export const BRAIN_ROOT = join(AGY_HOME, 'brain');

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const BANNER_RE = new RegExp(`--conversation=(${UUID})`);
const PRESENCE_RE = new RegExp(`/presence/(${UUID})\\.lock`);

export function transcriptPath(conversationId, root = BRAIN_ROOT) {
  return join(root, conversationId, '.system_generated', 'logs', 'transcript.jsonl');
}

// 완료된 답변 스텝의 본문만. 빈 content(도구 호출 중간 스텝)·다른 type은 버린다.
export function extractPlannerResponses(jsonlChunk) {
  const out = [];
  for (const line of jsonlChunk.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    let d;
    try { d = JSON.parse(trimmed); } catch { continue; }
    if (d.type !== 'PLANNER_RESPONSE' || d.status !== 'DONE') continue;
    if (typeof d.content === 'string' && d.content.trim()) out.push(d.content);
  }
  return out;
}

export function conversationIdFromBanner(screenText) {
  const m = screenText.match(BANNER_RE);
  return m ? m[1] : null;
}

// lsof -p <pid> 출력 또는 /proc/<pid>/fd readlink 목록 — 형식 불문 경로만 본다.
export function conversationIdFromOpenFiles(text) {
  const m = text.match(PRESENCE_RE);
  return m ? m[1] : null;
}

// brain 아래 가장 최근 수정된 대화 디렉터리. 없으면 null.
export async function findNewestConversation(root = BRAIN_ROOT) {
  let entries;
  try { entries = await readdir(root, { withFileTypes: true }); } catch { return null; }
  let best = null;
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    let s;
    try { s = await stat(join(root, e.name)); } catch { continue; }
    if (!best || s.mtimeMs > best.mtimeMs) best = { id: e.name, mtimeMs: s.mtimeMs };
  }
  return best?.id ?? null;
}

// pane PID(와 자손)가 연 presence 락으로 대화 ID를 찾는다. 맥은 lsof, 리눅스는 /proc.
async function openFilesText(pid) {
  if (process.platform === 'linux') {
    const { stdout } = await run('sh', ['-c',
      `for p in ${pid} $(pgrep -P ${pid} 2>/dev/null); do ls -l /proc/$p/fd 2>/dev/null; done`]);
    return stdout;
  }
  const { stdout: kids } = await run('pgrep', ['-P', String(pid)]).catch(() => ({ stdout: '' }));
  const pids = [String(pid), ...kids.split('\n').map((s) => s.trim()).filter(Boolean)];
  const { stdout } = await run('lsof', ['-p', pids.join(','), '-Fn']).catch(() => ({ stdout: '' }));
  return stdout;
}

// 검출 순서: presence 락(살아 있는 프로세스가 쥔 것 = 확실) → 화면 배너 → brain 최신.
// 반환은 rollout.findRolloutByCwd와 같은 모양 {file, sid}.
export async function findConversationByPane(pane, { root = BRAIN_ROOT } = {}) {
  const { stdout: pidOut } = await run('tmux', ['display-message', '-p', '-t', pane, '#{pane_pid}']);
  const pid = pidOut.trim();
  let sid = null;
  try { sid = conversationIdFromOpenFiles(await openFilesText(pid)); } catch { /* 폴백 */ }
  if (sid) console.log(`agy 대화 선택(presence 락): ${sid}`);
  if (!sid) {
    const { stdout: screen } = await run('tmux', ['capture-pane', '-p', '-t', pane]);
    sid = conversationIdFromBanner(screen);
    if (sid) console.log(`agy 대화 선택(배너): ${sid}`);
  }
  if (!sid) {
    sid = await findNewestConversation(root);
    if (sid) console.log(`agy 대화 선택(brain 최신): ${sid}`);
  }
  if (!sid) return null;
  const file = transcriptPath(sid, root);
  try { await stat(file); } catch { return null; }
  return { file, sid };
}
