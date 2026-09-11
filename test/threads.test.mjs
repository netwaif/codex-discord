import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ThreadRegistry, windowNameFor, parseSpawnOutput } from '../src/threads.mjs';

test('windowNameFor·parseSpawnOutput', () => {
  assert.equal(windowNameFor('1547858247917117440'), 't117440');
  assert.deepEqual(parseSpawnOutput('log\nSESSION_ID=abc FILE=/x/r.jsonl\n'), { sid: 'abc', file: '/x/r.jsonl' });
  assert.equal(parseSpawnOutput('no session line'), null);
});

test('ensure: 없으면 spawn·저장, 창 살아 있으면 재사용, 죽었으면 재생성', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'thr-'));
  const calls = [];
  let alive = true;
  const reg = new ThreadRegistry({
    path: join(dir, 'threads.json'), session: 'gemini-live',
    spawn: async (w) => { calls.push(w); return `x\nSESSION_ID=s${calls.length} FILE=/f${calls.length}\n`; },
    paneAlive: async () => alive,
  });
  await reg.load();
  const a = await reg.ensure('1547858247917117440');
  assert.equal(a.created, true);
  assert.deepEqual([a.entry.window, a.entry.pane, a.entry.sid, a.entry.file], ['t117440', 'gemini-live:t117440.0', 's1', '/f1']);
  const b = await reg.ensure('1547858247917117440');
  assert.equal(b.created, false); assert.equal(calls.length, 1);
  alive = false;
  const c = await reg.ensure('1547858247917117440');
  assert.equal(c.created, true); assert.equal(c.entry.sid, 's2');
  const saved = JSON.parse(await readFile(join(dir, 'threads.json'), 'utf8'));
  assert.equal(saved['1547858247917117440'].sid, 's2');
  assert.deepEqual(reg.entries().map((e) => e.threadId), ['1547858247917117440']);
});

test('ensure: spawn 출력에 세션 줄이 없으면 에러, 항목 미저장', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'thr-'));
  const reg = new ThreadRegistry({ path: join(dir, 'threads.json'), session: 's', spawn: async () => 'oops', paneAlive: async () => false });
  await reg.load();
  await assert.rejects(reg.ensure('1'), /검출 실패/);
  assert.equal(reg.get('1'), undefined);
});

test('ensure: 동시 호출은 spawn을 직렬화한다', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'thr-'));
  let running = 0, maxRunning = 0;
  const reg = new ThreadRegistry({
    path: join(dir, 'threads.json'), session: 's',
    spawn: async (w) => { running++; maxRunning = Math.max(maxRunning, running); await new Promise((r) => setTimeout(r, 20)); running--; return `SESSION_ID=${w} FILE=/${w}\n`; },
    paneAlive: async () => false,
  });
  await reg.load();
  await Promise.all([reg.ensure('100001'), reg.ensure('100002')]);
  assert.equal(maxRunning, 1);
  assert.equal(reg.entries().length, 2);
});

test('load: 파일 없으면 빈 맵, delete 뒤 save 반영', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'thr-'));
  const reg = new ThreadRegistry({ path: join(dir, 'threads.json'), session: 's', spawn: async () => 'SESSION_ID=a FILE=/a\n', paneAlive: async () => false });
  await reg.load();
  assert.deepEqual(reg.entries(), []);
  await reg.ensure('7');
  reg.delete('7'); await reg.save();
  assert.deepEqual(JSON.parse(await readFile(join(dir, 'threads.json'), 'utf8')), {});
});
