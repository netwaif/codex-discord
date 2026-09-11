import { stat, open, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';

const SESSIONS_ROOT = join(homedir(), '.codex', 'sessions');

async function listSorted(dir) {
  return (await readdir(dir)).sort().reverse(); // 최근(큰 값) 우선
}

async function readSessionMeta(file) {
  // session_meta 첫 줄은 instructions가 실려 수십 KB에 달한다(2026-08-05 실측
  // 18,450B — 4KB 고정 읽기는 잘린 JSON 파싱 실패로 전 파일을 건너뛰었다).
  // 개행이 나올 때까지 읽고(상한 4MB), 멀티바이트 경계 안전하게 마지막에 디코드.
  let fh;
  try {
    fh = await open(file, 'r');
    const bufs = [];
    let pos = 0;
    while (pos < 4 * 1024 * 1024) {
      const buf = Buffer.alloc(65536);
      const { bytesRead } = await fh.read(buf, 0, buf.length, pos);
      if (bytesRead === 0) break;
      const view = buf.subarray(0, bytesRead);
      const nl = view.indexOf(0x0a);
      if (nl !== -1) {
        bufs.push(view.subarray(0, nl));
        break;
      }
      bufs.push(view);
      pos += bytesRead;
    }
    return JSON.parse(Buffer.concat(bufs).toString('utf8')).payload ?? null;
  } catch {
    return null;
  } finally {
    await fh?.close();
  }
}

// codex v0.146.0 기본 설정은 세션 UUID를 화면에 표시하지 않는다(2026-08-05 E2E
// 실측 — 표시 여부는 버전·로컬 설정에 따라 흔들린다). 화면 스크레이핑 대신
// 롤아웃 첫 줄 session_meta(cwd·session_id)로 세션을 특정하는 안정 검출원.
// 최신 파일 우선 — 같은 cwd의 옛 세션이 남아 있어도 현재 세션이 이긴다
// (tui-up.sh가 기동 직후 더미 턴으로 현재 세션의 롤아웃 존재를 보장한다).
//
// 단, TUI가 같은 cwd로 띄우는 보조 세션(guardian 승인 검토 등)은 제외한다 —
// 2026-09-03 실측: 12:07 guardian_review 롤아웃이 파일명 시각으로 더 뒤라 tail이
// 그쪽으로 갈아타 답변·첨부 릴레이가 끊겼다. 사용자 세션의 session_meta는
// source="cli"(문자열)·thread_source="user"(0.130+) 또는 없음(0.125~0.128).
// 보조 세션은 source가 객체({subagent:...})이고 thread_source가
// subagent(0.130~0.141)·guardian_review(0.152)·없음(0.128)으로 흔들리므로
// "source가 객체" 또는 "thread_source가 있는데 user가 아님" 둘 중 하나면 제외.
function auxiliaryReason(meta) {
  if (meta.source !== null && typeof meta.source === 'object') {
    return `source=${JSON.stringify(meta.source)}`;
  }
  if (meta.thread_source != null && meta.thread_source !== 'user') {
    return `thread_source=${meta.thread_source}`;
  }
  return null;
}

export async function findRolloutByCwd(cwd, root = SESSIONS_ROOT) {
  try {
    for (const y of await listSorted(root))
      for (const m of await listSorted(join(root, y)))
        for (const d of await listSorted(join(root, y, m)))
          for (const f of (await readdir(join(root, y, m, d))).sort().reverse()) {
            const file = join(root, y, m, d, f);
            const meta = await readSessionMeta(file);
            if (meta?.cwd !== cwd) continue;
            const reason = auxiliaryReason(meta);
            if (reason) {
              console.log(`롤아웃 제외(보조 세션): ${f} — ${reason}`);
              continue;
            }
            console.log(`롤아웃 선택(cwd 일치, 사용자 세션): ${f} — source=${JSON.stringify(meta.source ?? null)} thread_source=${meta.thread_source ?? '(없음)'}`);
            return { file, sid: meta.session_id ?? meta.id ?? null };
          }
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }
  return null;
}

export function extractAgentMessages(jsonlChunk) {
  const out = [];
  for (const line of jsonlChunk.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    let d;
    try { d = JSON.parse(trimmed); } catch { continue; }
    const p = d.payload ?? {};
    // codex 0.149.0부터 event_msg agent_message가 롤아웃에서 사라졌다(2026-08-26 실측).
    // response_item message(role=assistant)는 0.146~0.149 전 구간에 동일 텍스트로
    // 기록되므로 이쪽만 읽는다 — 구버전에서 두 소스를 다 읽으면 중복 게시가 된다.
    if (d.type !== 'response_item' || p.type !== 'message' || p.role !== 'assistant') continue;
    const text = (p.content ?? [])
      .filter((c) => c?.type === 'output_text' && typeof c.text === 'string')
      .map((c) => c.text)
      .join('');
    if (text) out.push(text);
  }
  return out;
}

export class RolloutTail {
  // extract: JSONL 청크 → 중계할 본문 배열. 기본은 codex 롤아웃, agy는 transcript 추출기를 넘긴다.
  constructor(filePath, { intervalMs = 700, extract = extractAgentMessages } = {}) {
    this.filePath = filePath;
    this.intervalMs = intervalMs;
    this.extract = extract;
    this.offset = 0;
    this.remainder = '';
    this.timer = null;
    this.stopped = false;
  }

  async start(onAgentMessage) {
    this.offset = (await stat(this.filePath)).size; // 시작 시점 이후의 새 메시지만
    const poll = async () => {
      if (this.stopped) return;
      try {
        const size = (await stat(this.filePath)).size;
        if (size < this.offset) {
          // 파일이 로테이션/트렁케이트됨 — 처음부터 다시 따라간다
          this.offset = 0;
          this.remainder = '';
        }
        if (size > this.offset) {
          const fh = await open(this.filePath, 'r');
          let buf;
          try {
            buf = Buffer.alloc(size - this.offset);
            await fh.read(buf, 0, buf.length, this.offset);
          } finally {
            await fh.close();
          }
          this.offset = size;
          const text = this.remainder + buf.toString('utf8');
          const lastNl = text.lastIndexOf('\n');
          const complete = lastNl === -1 ? '' : text.slice(0, lastNl + 1);
          this.remainder = lastNl === -1 ? text : text.slice(lastNl + 1);
          for (const msg of this.extract(complete)) await onAgentMessage(msg);
        }
      } catch {
        // 일시적 stat/read 실패는 다음 폴에서 재시도
      }
      if (!this.stopped) this.timer = setTimeout(poll, this.intervalMs);
    };
    await poll();
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.timer = null;
  }
}
