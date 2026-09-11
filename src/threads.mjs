// 디스코드 스레드 → 전용 tmux 창(codex/agy 세션) 매핑. 엔진 무관 — 창을 띄우는 spawn과
// pane 생존 판정 paneAlive를 주입받는다(실물은 scripts/tui-up.sh --window 와 tmux.paneHasEngine).
// 상태는 DATA_DIR/threads.json 에 저장해 데몬 재시작 뒤 살아 있는 창에 재부착한다.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

// 창 이름은 folder-bot claude 봇과 같은 규약: t + 스레드 ID 끝 6자리
export function windowNameFor(threadId) {
  return 't' + String(threadId).slice(-6);
}

// tui-up.sh 출력의 마지막 `SESSION_ID=<sid> FILE=<경로>` 줄
export function parseSpawnOutput(stdout) {
  const lines = String(stdout ?? '').split('\n').map((l) => l.trim()).filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i--) {
    const m = lines[i].match(/^SESSION_ID=(\S*) FILE=(.+)$/);
    if (m) return { sid: m[1], file: m[2] };
  }
  return null;
}

export class ThreadRegistry {
  constructor({ path, session, spawn, paneAlive }) {
    this.path = path;
    this.session = session;
    this.spawn = spawn;          // (window) => Promise<string stdout>, 실패 시 throw
    this.paneAlive = paneAlive;  // (pane) => Promise<boolean>
    this.map = new Map();
    this._chain = Promise.resolve(); // 창 생성 직렬화 — 같은 cwd의 새 롤아웃 검출이 섞이지 않게
  }

  async load() {
    try {
      const data = JSON.parse(await readFile(this.path, 'utf8'));
      this.map = new Map(Object.entries(data));
    } catch (err) {
      if (err.code !== 'ENOENT') throw err;
      this.map = new Map();
    }
  }

  async save() {
    await mkdir(dirname(this.path), { recursive: true });
    await writeFile(this.path, JSON.stringify(Object.fromEntries(this.map), null, 2) + '\n');
  }

  get(threadId) { return this.map.get(String(threadId)); }
  delete(threadId) { this.map.delete(String(threadId)); }
  entries() { return [...this.map.values()]; }

  // 창이 살아 있으면 그대로, 아니면 새로 띄워 등록. created=true면 첫 생성(안내 게시용).
  async ensure(threadId) {
    const id = String(threadId);
    const cur = this.map.get(id);
    if (cur && await this.paneAlive(cur.pane)) return { entry: cur, created: false };
    const job = async () => {
      const again = this.map.get(id);   // 직렬 대기 중 다른 호출이 만들었을 수 있다
      if (again && again !== cur && await this.paneAlive(again.pane)) return { entry: again, created: false };
      const window = windowNameFor(id);
      const out = await this.spawn(window);
      const hit = parseSpawnOutput(out);
      if (!hit) throw new Error(`스레드 세션 검출 실패 — tui-up 출력에 SESSION_ID 줄 없음: ${String(out).trim().split('\n').pop()}`);
      const entry = { threadId: id, window, pane: `${this.session}:${window}.0`, sid: hit.sid, file: hit.file,
        created: new Date().toISOString(), last: new Date().toISOString() };
      this.map.set(id, entry);
      await this.save();
      return { entry, created: true };
    };
    const next = this._chain.then(job, job);
    this._chain = next.catch(() => {});
    return next;
  }
}
