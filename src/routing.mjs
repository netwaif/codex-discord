export function classifyMessage({ isMe, isBot, isSystem = false, allowed, mentionsMe, mentionsOthers, content, triggerName = '코덱스' }) {
  // 디스코드 시스템 메시지(스레드 시작·핀·가입 알림 등)는 사람 발화가 아니다 — 2026-09-11 실측:
  // "스레드를 시작하셨어요"가 부모 채널에 content=스레드명으로 들어와 메인 TUI에 붙여넣어졌다.
  if (isSystem) return 'ignore';
  if (isMe) return 'ignore';
  if (isBot) return 'context';
  if (!allowed) return 'ignore';
  if (mentionsMe || content.trim().startsWith(triggerName)) return 'trigger';
  if (mentionsOthers) return 'context';
  return 'context';
}

export class ContextQueue {
  constructor({ maxChars = 8000 } = {}) {
    this.items = [];
    this.truncated = false;
    this.maxChars = maxChars;
  }

  #totalChars() {
    return this.items.reduce((n, s) => n + s.length, 0);
  }

  push(speaker, text) {
    this.items.push(`[${speaker}] ${text}`);
    while (this.#totalChars() >= this.maxChars && this.items.length > 1) {
      this.items.shift();
      this.truncated = true;
    }
  }

  drain(speaker, text) {
    const lines = [...this.items, `[${speaker}] ${text}`];
    if (this.truncated) lines.unshift('[...이전 대화 일부 생략]');
    this.items = [];
    this.truncated = false;
    return lines.join('\n');
  }

  // drain된 블록을 큐 맨 앞에 되돌린다 — paste 실패 시 컨텍스트 유실 방지
  restore(block) {
    this.items.unshift(block);
  }
}
