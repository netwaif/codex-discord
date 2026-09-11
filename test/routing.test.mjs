import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyMessage, ContextQueue } from '../src/routing.mjs';

const base = { isMe: false, isBot: false, allowed: true, mentionsMe: false, mentionsOthers: false, content: '' };

test('자기 자신 발언은 ignore (에코 루프 방지)', () => {
  assert.equal(classifyMessage({ ...base, isMe: true, isBot: true }), 'ignore');
});

test('다른 봇 발언은 context', () => {
  assert.equal(classifyMessage({ ...base, isBot: true, allowed: false }), 'context');
});

test('봇이 나를 멘션해도 trigger가 아닌 context (루프 가드 우선)', () => {
  assert.equal(
    classifyMessage({ ...base, isBot: true, mentionsMe: true, content: '코덱스야 이것 좀' }),
    'context',
  );
});

test('비허용 사용자는 ignore', () => {
  assert.equal(classifyMessage({ ...base, allowed: false }), 'ignore');
});

test('내 멘션이면 trigger', () => {
  assert.equal(classifyMessage({ ...base, mentionsMe: true }), 'trigger');
});

test('코덱스로 시작하면 trigger', () => {
  assert.equal(classifyMessage({ ...base, content: '코덱스야 a.py 만들어줘' }), 'trigger');
});

test('triggerName 지정 시 그 이름으로 시작하면 trigger', () => {
  assert.equal(classifyMessage({ ...base, content: '제미나이 안녕', triggerName: '제미나이' }), 'trigger');
});

test('triggerName 지정 시 다른 봇 호명은 context', () => {
  assert.equal(classifyMessage({ ...base, content: '코덱스 안녕', triggerName: '제미나이' }), 'context');
});

test('다른 봇 멘션이면 context', () => {
  assert.equal(classifyMessage({ ...base, mentionsOthers: true, content: '@Claude 어때?' }), 'context');
});

test('호명 없는 일반 발언은 context', () => {
  assert.equal(classifyMessage({ ...base, content: '흠 그렇군' }), 'context');
});

test('ContextQueue: drain은 라벨 붙여 합치고 비운다', () => {
  const q = new ContextQueue();
  q.push('soonho', '이 함수 어때?');
  q.push('Claude', '반복문이 낫습니다');
  const block = q.drain('soonho', '코덱스야 너는?');
  assert.equal(block, '[soonho] 이 함수 어때?\n[Claude] 반복문이 낫습니다\n[soonho] 코덱스야 너는?');
  assert.equal(q.drain('soonho', '다음'), '[soonho] 다음'); // 비워졌는지
});

test('ContextQueue.restore: 실패한 블록을 맨 앞에 되돌린다', () => {
  const q = new ContextQueue();
  q.push('soonho', '나중 발언');
  q.restore('[soonho] 실패했던 블록');
  assert.equal(q.drain('soonho', '지금'), '[soonho] 실패했던 블록\n[soonho] 나중 발언\n[soonho] 지금');
});

test('ContextQueue: maxChars 초과 시 오래된 항목부터 버리고 생략 마커를 붙인다', () => {
  const q = new ContextQueue({ maxChars: 30 });
  q.push('a', '가나다라마바사아자차카타파하'); // 이후 넘치면 버려질 후보
  q.push('b', '최신 발언입니다');
  const block = q.drain('c', '트리거');
  assert.ok(block.startsWith('[...이전 대화 일부 생략]'));
  assert.ok(block.includes('[b] 최신 발언입니다'));
  assert.ok(!block.includes('[a]'));
  assert.ok(block.endsWith('[c] 트리거'));
});

test('시스템 메시지(스레드 시작 알림 등)는 허용 사용자여도 ignore', () => {
  assert.equal(classifyMessage({ isMe: false, isBot: false, isSystem: true, allowed: true, mentionsMe: true, mentionsOthers: false, content: '테스트-1' }), 'ignore');
});
