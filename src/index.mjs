import { fileURLToPath } from 'node:url';
import { readFile, writeFile, mkdir, stat } from 'node:fs/promises';
import { unlinkSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { execFile } from 'node:child_process';
import { Client, GatewayIntentBits, Partials } from 'discord.js';
import { SessionStore } from './sessions.mjs';
import { runCodexTurn, killActiveCodexChildren } from './codex.mjs';
import { runAgyTurn, killActiveAgyChildren } from './agy.mjs';
import { chunkMessage } from './chunk.mjs';
import { pasteToPane, paneCurrentCommand, paneHasEngine, UUID_RE } from './tmux.mjs';
import { findRolloutByCwd, RolloutTail } from './rollout.mjs';
import { findConversationByPane, extractPlannerResponses } from './agy-transcript.mjs';
import { classifyMessage, ContextQueue } from './routing.mjs';
import { ThreadRegistry } from './threads.mjs';
import { extractAttachmentMarkers, resolveUploadPath, saveIncomingAttachments } from './attachments.mjs';

const TOKEN = process.env.DISCORD_TOKEN;
const ALLOWED = new Set(
  (process.env.ALLOWED_USER_IDS ?? '').split(',').map((s) => s.trim()).filter(Boolean),
);
const WORKDIR = process.env.CODEX_WORKDIR;
// 엔진 선택: codex(기본) | agy(Antigravity CLI = Gemini). 인스턴스마다 .env 파일로 분리 실행.
const ENGINE = process.env.ENGINE ?? 'codex';
const runTurn = ENGINE === 'agy' ? runAgyTurn : runCodexTurn;
// 인스턴스별 데이터 폴더 (두 데몬이 락파일·세션맵을 공유하면 안 됨)
const DATA_DIR = process.env.DATA_DIR ?? 'data';
// (선택) 채널 allowlist — 두 봇이 같은 채널을 보면 일반 메시지에 둘 다 응답하므로,
// 인스턴스를 특정 채널로 묶을 때 사용. 비우면 모든 채널·DM 수신(기존 동작).
const CHANNEL_ALLOW = new Set(
  (process.env.CHANNEL_IDS ?? '').split(',').map((s) => s.trim()).filter(Boolean),
);
// 공유 채널 호명 게이트: 이 목록의 채널에서는 헤드리스도 멘션 또는 TRIGGER_NAME 시작일 때만 응답
const TRIGGER_NAME = process.env.TRIGGER_NAME ?? '코덱스';
const NAME_TRIGGER_CHANNELS = new Set(
  (process.env.NAME_TRIGGER_CHANNEL_IDS ?? '').split(',').map((s) => s.trim()).filter(Boolean),
);
const sharedQueues = new Map(); // 공유 채널별 ContextQueue — 호명 안 된 대화도 따라 듣는다

if (!TOKEN || ALLOWED.size === 0 || !WORKDIR) {
  console.error('DISCORD_TOKEN, ALLOWED_USER_IDS, CODEX_WORKDIR를 .env에 설정하세요.');
  process.exit(1);
}
if (!['codex', 'agy'].includes(ENGINE)) {
  console.error(`알 수 없는 ENGINE: ${ENGINE} (codex | agy)`);
  process.exit(1);
}

const LOCK_PATH = fileURLToPath(new URL(`../${DATA_DIR}/daemon.pid`, import.meta.url));
try {
  const oldPid = Number(await readFile(LOCK_PATH, 'utf8'));
  if (oldPid) {
    try {
      process.kill(oldPid, 0); // 살아있으면 예외 없음
      console.error(`이미 다른 데몬(PID ${oldPid})이 실행 중입니다. 중복 실행은 이중 응답/이중 주입을 일으킵니다.`);
      process.exit(1);
    } catch { /* 죽은 PID — 무시하고 진행 */ }
  }
} catch (err) {
  if (err.code !== 'ENOENT') throw err;
}
await mkdir(dirname(LOCK_PATH), { recursive: true });
await writeFile(LOCK_PATH, String(process.pid));

const TUI_PANE = process.env.TUI_PANE || null;            // 예: codex-live:0.0
const TUI_CHANNEL_ID = process.env.TUI_CHANNEL_ID || null;
// 라이브 TUI 모드: codex는 롤아웃, agy는 transcript.jsonl을 tail한다(2026-09-11 agy 지원 —
// "agy는 롤아웃이 없어 불가"는 검증 없는 가정이었다. agy-transcript.mjs 참조).
const TUI_ENABLED = Boolean(TUI_PANE && TUI_CHANNEL_ID);
// TUI 채널이 이 봇 전용이면 off — 호명(멘션·TRIGGER_NAME) 없이 모든 메시지에 응답.
// 기본 on = 기존 동작(공유 수다 채널을 TUI 채널로 쓰는 배치의 호명 게이트) 유지.
const TUI_TRIGGER_GATE = (process.env.TUI_TRIGGER_GATE ?? 'on') !== 'off';
// TUI 채널 아래 디스코드 스레드 = 전용 창 세션(scripts/tui-up.sh --window). off면 스레드 무시(공유 채널 배치).
const TUI_THREADS = TUI_ENABLED && (process.env.TUI_THREADS ?? 'on') !== 'off';
const TUI_SESSION = TUI_PANE ? TUI_PANE.split(':')[0] : null;
const PROJECT_DIR = fileURLToPath(new URL('..', import.meta.url));
const TUI_UP = join(PROJECT_DIR, 'scripts', 'tui-up.sh');
// 이 데몬이 읽은 env 파일 — 스레드 창도 같은 인스턴스 설정으로 띄운다(node --env-file=.env.<이름>)
const ENV_FILE = process.env.TUI_ENV_FILE
  ?? process.execArgv.find((a) => a.startsWith('--env-file='))?.slice('--env-file='.length)
  ?? '.env';

const store = new SessionStore(
  fileURLToPath(new URL(`../${DATA_DIR}/sessions.json`, import.meta.url)),
);
await store.load();

// 채널당 직렬 큐: 턴 진행 중 도착한 메시지는 앞 턴이 끝난 뒤 처리
const queues = new Map();
function enqueue(channelId, job) {
  const prev = queues.get(channelId) ?? Promise.resolve();
  const next = prev.then(job, job);
  queues.set(channelId, next);
  return next;
}

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
    GatewayIntentBits.DirectMessages,
  ],
  partials: [Partials.Channel], // DM 수신에 필요
});

const tuiQueue = new ContextQueue();
let tuiTail = null;
let tuiSessionId = null;

// 스레드 = 전용 창 세션. 레지스트리는 창 생성(tui-up --window)과 pane 생존 판정을 주입받는다.
const threads = new ThreadRegistry({
  path: join(PROJECT_DIR, DATA_DIR, 'threads.json'),
  session: TUI_SESSION,
  spawn: (window) => new Promise((resolve, reject) => {
    execFile('/bin/bash', [TUI_UP, ENV_FILE, '--window', window], { cwd: PROJECT_DIR, timeout: 400_000 },
      (err, stdout, stderr) => {
        if (err) reject(new Error(`스레드 창 기동 실패(tui-up): ${String(stderr || stdout).trim().split('\n').pop()}`));
        else resolve(stdout);
      });
  }),
  paneAlive: (pane) => paneHasEngine(pane, ENGINE),
});
const threadTails = new Map();   // threadId → { tail, sid }
const threadQueues = new Map();  // threadId → ContextQueue

// 스레드 창의 세션 파일 tail. 레지스트리의 파일(창 생성 때 tui-up이 검출)이 정본이고,
// 그 파일이 사라졌을 때만 pane 기준으로 재검출한다(agy의 brain-최신 폴백이 남의 대화를 집을 수 있어 평소엔 안 쓴다).
async function ensureThreadTail(threadChannel, entry) {
  let { sid, file } = entry;
  const exists = await stat(file).then(() => true, () => false);
  if (!exists) {
    const hit = ENGINE === 'agy'
      ? await findConversationByPane(entry.pane)
      : await findRolloutByCwd(WORKDIR, undefined, { exclude: new Set([tuiTail?.filePath, ...threads.entries().filter((e) => e !== entry).map((e) => e.file)].filter(Boolean)) });
    if (!hit) throw new Error(`스레드 세션 파일 없음: ${file}`);
    ({ sid, file } = { sid: hit.sid ?? sid, file: hit.file });
  }
  const cur = threadTails.get(entry.threadId);
  if (cur && cur.sid === sid) return;
  cur?.tail.stop();
  const tail = new RolloutTail(file, ENGINE === 'agy' ? { extract: extractPlannerResponses } : {});
  await tail.start((text) => relayReply(threadChannel, text));
  threadTails.set(entry.threadId, { tail, sid });
  if (sid !== entry.sid || file !== entry.file) { entry.sid = sid; entry.file = file; await threads.save(); }
  console.log(`스레드 tail 연결: ${entry.window} → 세션 ${sid}`);
}

// 데몬 재시작: 창이 살아 있는 스레드는 재부착, 죽은 스레드는 항목 폐기(다음 메시지에 새로 생성)
async function reattachThreads() {
  let kept = 0, dropped = 0;
  for (const entry of threads.entries()) {
    try {
      if (!(await paneHasEngine(entry.pane, ENGINE))) throw new Error('창 없음');
      const ch = await client.channels.fetch(entry.threadId);
      await ensureThreadTail(ch, entry);
      kept++;
    } catch (err) {
      console.log(`스레드 폐기: ${entry.window} — ${err.message}`);
      threads.delete(entry.threadId);
      dropped++;
    }
  }
  if (kept || dropped) { await threads.save(); console.log(`스레드 재부착 ${kept} / 폐기 ${dropped}`); }
}

// codex 답변을 채널로 릴레이: [[첨부: 경로]] 마커는 걷어내 검증 후 파일로 첨부
async function relayReply(channel, raw) {
  const { text, paths } = extractAttachmentMarkers(raw);
  for (const chunk of chunkMessage(text)) {
    await channel.send({ content: chunk, allowedMentions: { parse: [] } }).catch((err) => console.error('릴레이 전송 실패:', err.message));
  }
  const files = [];
  const problems = [];
  for (const p of paths) {
    try {
      files.push(await resolveUploadPath(p, WORKDIR));
    } catch (err) {
      problems.push(err.message);
    }
  }
  if (files.length) {
    await channel.send({ files, allowedMentions: { parse: [] } }).catch((err) => problems.push(`전송 실패: ${err.message}`));
  }
  if (problems.length) {
    await channel.send({ content: `⚠️ 첨부 실패: ${problems.join(' / ')}`.slice(0, 1500), allowedMentions: { parse: [] } }).catch(() => {});
  }
}

// 수신 메시지의 첨부를 워크스페이스 uploads/로 내려받아 본문에 경로 주석을 덧붙인다
async function withAttachments(message, content) {
  if (message.attachments.size === 0) return content;
  try {
    const { saved, errors } = await saveIncomingAttachments([...message.attachments.values()], WORKDIR);
    if (saved.length) content += `\n(첨부 파일: ${saved.join(', ')})`;
    if (errors.length) content += `\n(첨부 저장 실패: ${errors.join(' / ')})`;
  } catch (err) {
    content += `\n(첨부 저장 실패: ${err.message})`;
  }
  return content;
}

// TUI pane의 현재 엔진 세션을 찾아 파일 tail을 연결한다.
// pane에서 엔진을 재시작해 세션이 바뀌면 tail도 갈아탄다.
// codex: 롤아웃 session_meta.cwd 매칭 단일 검출원. 화면 UUID 스크레이핑은
//   폐기(2026-09-03) — v0.146.0+ 기본 설정은 상태바에 UUID를 안 띄우고, 채팅 본문에
//   인용된 guardian 세션 UUID를 세션 ID로 오인해 tail이 엉뚱한 파일로 갈아탔다.
// agy: presence 락(pane PID) → 배너 → brain 최신 순으로 대화 ID를 특정한다.
async function ensureTuiTail(channel) {
  // npm 배포판은 codex가 node 런처라 pane_current_command만으로는 오탐한다
  // (2026-08-05 E2E 실측) — pane 프로세스 트리에서 엔진 실존을 본다.
  if (!(await paneHasEngine(TUI_PANE, ENGINE))) {
    const cmd = await paneCurrentCommand(TUI_PANE);
    throw new Error(`TUI pane(${TUI_PANE})에서 ${ENGINE} 프로세스를 찾지 못함(현재: ${cmd}) — 셸에 명령이 입력되는 것을 막기 위해 중단`);
  }
  const hit = ENGINE === 'agy'
    ? await findConversationByPane(TUI_PANE)
    : await findRolloutByCwd(WORKDIR, undefined, { exclude: new Set(threads.entries().map((e) => e.file)) });
  if (!hit) {
    throw new Error(ENGINE === 'agy'
      ? `agy 대화를 특정하지 못함 — pane(${TUI_PANE})의 presence 락·배너·brain 최신 모두 실패. TUI에서 메시지를 한 번 보낸 뒤 다시 시도하세요`
      : `codex 세션을 특정하지 못함 — cwd(${WORKDIR}) 일치 롤아웃이 없음. TUI에서 메시지를 한 번 보낸 뒤 다시 시도하세요`);
  }
  const { file } = hit;
  const fullSid = hit.sid ?? file.match(UUID_RE)?.[0];
  if (fullSid === tuiSessionId && tuiTail) return;
  tuiTail?.stop();
  tuiSessionId = fullSid;
  tuiTail = new RolloutTail(file, ENGINE === 'agy' ? { extract: extractPlannerResponses } : {});
  // 콜백이 캡처하는 channel은 최초 연결 시점의 것 — TUI 채널이 단일 고정이라 안전
  await tuiTail.start((text) => relayReply(channel, text));
  console.log(`TUI tail 연결: 세션 ${fullSid}`);
}

// 디스코드 @멘션 자동완성은 봇의 "통합 역할"을 고르는 경우가 많다 — 역할 멘션도
// 사용자 멘션과 동일하게 인식해야 "됐다 안 됐다" 없이 트리거된다 (2026-08-05 실측)
const mentionsMe = (m) => m.mentions.users.has(client.user.id)
  || m.mentions.roles.some((r) => r.tags?.botId === client.user.id);
const mentionsAnyone = (m) => m.mentions.users.size > 0
  || m.mentions.roles.some((r) => r.tags?.botId);

client.on('messageCreate', async (message) => {
  // TUI 채널 아래 스레드 → 전용 창 세션 (CHANNEL_IDS allowlist보다 먼저 — 스레드 ID는 목록에 없다)
  if (TUI_THREADS && message.channel.isThread?.() && message.channel.parentId === TUI_CHANNEL_ID) {
    const verdict = classifyMessage({
      isMe: message.author.id === client.user.id,
      isBot: message.author.bot,
      isSystem: Boolean(message.system),
      allowed: ALLOWED.has(message.author.id),
      mentionsMe: mentionsMe(message),
      mentionsOthers: mentionsAnyone(message) && !mentionsMe(message),
      content: message.content ?? '',
      triggerName: TUI_TRIGGER_GATE ? TRIGGER_NAME : '',
    });
    if (verdict === 'ignore') return;
    const tid = message.channelId;
    const speaker = message.member?.displayName ?? message.author.username;
    let queue = threadQueues.get(tid);
    if (!queue) { queue = new ContextQueue(); threadQueues.set(tid, queue); }
    if (verdict === 'context') { queue.push(speaker, await withAttachments(message, message.cleanContent)); return; }
    enqueue(tid, async () => {
      let block = null;
      try {
        const { entry, created } = await threads.ensure(tid);
        if (created) {
          await message.channel.send({ content: `이 스레드는 전용 세션 \`${entry.window}\`이 담당합니다 (tmux 창 \`${entry.window}\`).`, allowedMentions: { parse: [] } }).catch(() => {});
        }
        await ensureThreadTail(message.channel, entry);
        block = queue.drain(speaker, await withAttachments(message, message.cleanContent));
        await pasteToPane(entry.pane, block);
        entry.last = new Date().toISOString();
        await threads.save();
      } catch (err) {
        if (block !== null) queue.restore(block);
        await message.channel.send({ content: `⚠️ [스레드 세션] ${String(err.message ?? err).slice(0, 1500)}`, allowedMentions: { parse: [] } }).catch(() => {});
      }
    });
    return;
  }
  if (CHANNEL_ALLOW.size > 0 && !CHANNEL_ALLOW.has(message.channelId)) return;
  if (TUI_ENABLED && message.channelId === TUI_CHANNEL_ID) {
    const verdict = classifyMessage({
      isMe: message.author.id === client.user.id,
      isBot: message.author.bot,
      isSystem: Boolean(message.system),
      allowed: ALLOWED.has(message.author.id),
      mentionsMe: mentionsMe(message),
      mentionsOthers: mentionsAnyone(message) && !mentionsMe(message),
      content: message.content ?? '',
      // 게이트 off = 빈 접두사 — 허용 사용자의 모든 메시지가 trigger로 분류된다
      triggerName: TUI_TRIGGER_GATE ? TRIGGER_NAME : '',
    });
    if (verdict === 'ignore') return;
    const speaker = message.member?.displayName ?? message.author.username;
    if (verdict === 'context') {
      tuiQueue.push(speaker, await withAttachments(message, message.cleanContent));
      return;
    }
    enqueue(message.channelId, async () => {
      let block = null;
      try {
        await ensureTuiTail(message.channel);
        block = tuiQueue.drain(speaker, await withAttachments(message, message.cleanContent));
        await pasteToPane(TUI_PANE, block);
      } catch (err) {
        if (block !== null) tuiQueue.restore(block);
        await message.channel.send({ content: `⚠️ ${String(err.message ?? err).slice(0, 1500)}`, allowedMentions: { parse: [] } }).catch(() => {});
      }
    });
    return;
  }

  // ===== 기존 headless 경로 (기존 코드 그대로) =====
  // 공유 채널: TUI 분기와 동일 의미론(classifyMessage) + 채널별 컨텍스트 큐. 전용 채널 동작은 불변.
  let sharedCtx = null;
  if (NAME_TRIGGER_CHANNELS.has(message.channelId)) {
    const verdict = classifyMessage({
      isMe: message.author.id === client.user.id,
      isBot: message.author.bot,
      isSystem: Boolean(message.system),
      allowed: ALLOWED.has(message.author.id),
      mentionsMe: mentionsMe(message),
      mentionsOthers: mentionsAnyone(message) && !mentionsMe(message),
      content: message.content ?? '',
      triggerName: TRIGGER_NAME,
    });
    if (verdict === 'ignore') return;
    const speaker = message.member?.displayName ?? message.author.username;
    let queue = sharedQueues.get(message.channelId);
    if (!queue) { queue = new ContextQueue(); sharedQueues.set(message.channelId, queue); }
    if (verdict === 'context') { queue.push(speaker, message.cleanContent ?? ''); return; }
    sharedCtx = { queue, speaker };
  } else if (message.author.bot || message.system) return;
  if (!ALLOWED.has(message.author.id)) return;
  // 다른 봇(예: Claude)을 멘션한 메시지는 그 봇의 몫 — 가로채지 않는다
  if (!sharedCtx && mentionsAnyone(message) && !mentionsMe(message)) return;
  const basePrompt = message.content?.trim() ?? '';
  if (!basePrompt && message.attachments.size === 0) return;

  enqueue(message.channelId, async () => {
    const typing = setInterval(() => message.channel.sendTyping().catch(() => {}), 8000);
    let block = null;
    try {
      message.channel.sendTyping().catch(() => {});
      let prompt = await withAttachments(message, basePrompt);
      if (sharedCtx) { block = sharedCtx.queue.drain(sharedCtx.speaker, prompt); prompt = block; }
      const prior = store.get(message.channelId);
      const result = await runTurn({ sessionId: prior, prompt, cwd: WORKDIR });
      await relayReply(message.channel, result.reply);
      if (result.sessionId && result.sessionId !== prior) {
        try {
          await store.set(message.channelId, result.sessionId);
        } catch (err) {
          console.error('세션 매핑 저장 실패:', err);
        }
      }
    } catch (err) {
      if (sharedCtx && block !== null) sharedCtx.queue.restore(block); // 실패 시 컨텍스트 유실 방지
      await message.channel.send(`⚠️ ${String(err.message ?? err).slice(0, 1500)}`).catch(() => {});
    } finally {
      clearInterval(typing);
    }
  });
});

client.once('clientReady', async () => {
  console.log(`로그인: ${client.user.tag} / 엔진 ${ENGINE} / 허용 사용자 ${ALLOWED.size}명 / 작업폴더 ${WORKDIR}`);
  if (TUI_THREADS) {
    try { await threads.load(); await reattachThreads(); } catch (err) { console.error('스레드 재부착 실패:', err.message); }
  }
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.once(sig, () => {
    killActiveCodexChildren();
    killActiveAgyChildren();
    client.destroy();
    try { unlinkSync(LOCK_PATH); } catch { /* 없으면 무시 */ }
    process.exit(0);
  });
}

await client.login(TOKEN);
