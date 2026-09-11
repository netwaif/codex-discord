import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sanitizeForPaste } from '../src/tmux.mjs';

test('sanitizeForPaste: 제어문자는 지우고 개행·탭은 보존', () => {
  assert.equal(sanitizeForPaste('a\x1b[201~b\nc\td\x7f'), 'a[201~b\nc\td');
});

test('treeHasCodex: npm 런처 — pane이 node여도 자손에 codex 바이너리가 있으면 참 (2026-08-05 E2E 실측)', async () => {
  const { treeHasCodex } = await import('../src/tmux.mjs');
  const ps = [
    ' 5325     1 node /Users/t/.local/bin/codex -s workspace-write',
    ' 5400  5325 /Users/t/.local/lib/node_modules/@openai/codex/vendor/codex-aarch64-apple-darwin exec',
    ' 9999     1 node /Users/t/some/other/app.js',
  ].join('\n');
  assert.equal(treeHasCodex(ps, '5325'), true);
});

test('treeHasCodex: 런처만 있고 네이티브 자식이 없어도 node <경로>/codex 형태면 참', async () => {
  const { treeHasCodex } = await import('../src/tmux.mjs');
  const ps = ' 5325     1 node /Users/t/.local/bin/codex -s workspace-write';
  assert.equal(treeHasCodex(ps, '5325'), true);
});

test('treeHasCodex: 트리에 codex가 없으면 거짓 (맨 zsh — 죽은 TUI)', async () => {
  const { treeHasCodex } = await import('../src/tmux.mjs');
  const ps = [
    '  964     1 zsh',
    ' 9999     1 node /Users/t/some/other/app.js',
  ].join('\n');
  assert.equal(treeHasCodex(ps, '964'), false);
});

test('treeHasCodex: 다른 트리의 codex는 무시 (pane 자손만 판정)', async () => {
  const { treeHasCodex } = await import('../src/tmux.mjs');
  const ps = [
    '  964     1 zsh',
    ' 7777     1 codex -s workspace-write',
  ].join('\n');
  assert.equal(treeHasCodex(ps, '964'), false);
});

test('treeHasEngine(agy): Go 단일 바이너리 — pane 루트 argv0 basename이 agy면 참', async () => {
  const { treeHasEngine } = await import('../src/tmux.mjs');
  const ps = ' 7001     1 /Users/t/.local/bin/agy --dangerously-skip-permissions';
  assert.equal(treeHasEngine(ps, '7001', 'agy'), true);
  assert.equal(treeHasEngine(ps, '7001', 'codex'), false);
});

test('treeHasEngine(agy): 셸 루트 아래 자손에 agy가 있어도 참, 없으면 거짓', async () => {
  const { treeHasEngine } = await import('../src/tmux.mjs');
  const ps = [
    ' 7000     1 -zsh',
    ' 7001  7000 agy',
  ].join('\n');
  assert.equal(treeHasEngine(ps, '7000', 'agy'), true);
  assert.equal(treeHasEngine(' 7000     1 -zsh', '7000', 'agy'), false);
});
