import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, mkdir, writeFile, utimes } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  extractPlannerResponses,
  conversationIdFromBanner,
  conversationIdFromOpenFiles,
  findNewestConversation,
  transcriptPath,
} from '../src/agy-transcript.mjs';

const UUID_A = '4b2f5d60-ac23-4328-954c-696b039586e0';
const UUID_B = '468bb206-a9f1-4399-910d-7d63d5a068a5';

test('실물 픽스처(agy 1.2.0)에서 답변 스텝만 뽑는다 — USER_INPUT·GENERIC·빈 PLANNER_RESPONSE 제외', async () => {
  const jsonl = await readFile(new URL('./fixtures/agy-transcript-sample.jsonl', import.meta.url), 'utf8');
  const msgs = extractPlannerResponses(jsonl);
  assert.equal(msgs.length, 1);
  assert.ok(msgs[0].includes('AGY_TUI_OK'));
  assert.ok(!msgs[0].includes('<USER_REQUEST>'));
});

test('JSON 아닌 줄·미완(status≠DONE) 스텝은 무시', () => {
  const jsonl = [
    'garbage',
    '{"step_index":3,"type":"PLANNER_RESPONSE","status":"RUNNING","content":"진행 중"}',
    '{"step_index":4,"type":"PLANNER_RESPONSE","status":"DONE","content":"완료 답변"}',
  ].join('\n') + '\n';
  assert.deepEqual(extractPlannerResponses(jsonl), ['완료 답변']);
});

test('conversationIdFromBanner: 기동/종료 배너의 --conversation=<UUID>를 읽는다', () => {
  const screen = `Resume with -c (or command below):\nagy --conversation=${UUID_B}\n      ▄▀▀▄        Antigravity CLI 1.2.0\n> `;
  assert.equal(conversationIdFromBanner(screen), UUID_B);
  assert.equal(conversationIdFromBanner('아무 UUID 없음'), null);
});

test('conversationIdFromOpenFiles: 열린 파일 목록(lsof/proc)에서 presence/<UUID>.lock을 찾는다', () => {
  const lsof = [
    `agy 885 soonho cwd DIR 1,2 /Users/soonho/ai-folder/x`,
    `agy 885 soonho 12u REG 1,2 0 /Users/soonho/.gemini/antigravity-cli/presence/${UUID_A}.lock`,
  ].join('\n');
  assert.equal(conversationIdFromOpenFiles(lsof), UUID_A);
  // /proc/<pid>/fd readlink 출력도 같은 규칙
  assert.equal(conversationIdFromOpenFiles(`/opt/data/.gemini/antigravity-cli/presence/${UUID_B}.lock`), UUID_B);
  assert.equal(conversationIdFromOpenFiles('/tmp/other.lock'), null);
});

test('findNewestConversation: brain 아래 가장 최근 수정 디렉터리 = 현재 대화', async () => {
  const root = await mkdtemp(join(tmpdir(), 'agy-brain-'));
  for (const [id, t] of [[UUID_B, 1000], [UUID_A, 2000]]) {
    const logs = join(root, id, '.system_generated', 'logs');
    await mkdir(logs, { recursive: true });
    await writeFile(join(logs, 'transcript.jsonl'), '');
    await utimes(join(root, id), t, t);
  }
  await writeFile(join(root, 'not-a-dir.txt'), '');
  assert.equal(await findNewestConversation(root), UUID_A);
  assert.equal(transcriptPath(UUID_A, root), join(root, UUID_A, '.system_generated', 'logs', 'transcript.jsonl'));
});

test('findNewestConversation: brain이 없으면 null', async () => {
  assert.equal(await findNewestConversation('/nonexistent/brain'), null);
});
