/**
 * 词慧 F17「导入即带中文」Node 原生测试。
 * 运行：node --experimental-strip-types --no-warnings --import ./tests/register-loader.mjs tests/meme-meaning.test.mjs
 *
 * 背景：真机反馈「卡片背面根本没有东西」。根因是 createMemeImport 建新词时硬编码
 * meanings: []、missingMeaning: true，从不查离线词典。本测试锁住修复后的口径：
 * A. 候选带 meaning → 新词入库即写 meanings、missingMeaning=false、带音标
 * B. 候选不带 meaning（词典未收录）→ 仍允许入库，但显式标 missingMeaning
 * C. 已有词释义为空 + 候选带 meaning → 顺手补齐（老数据自愈）
 * D. 已有词有手填释义 → 不被词典覆盖
 * E. 释义「；」拆分与 join 还原一致
 * F. 老调用方（只传 5 个字段）不崩，行为与旧版一致
 */
import {
  createMemeImport,
  buildCandidates,
  tokenizeEnglish,
  STOP_WORDS,
} from '../entry/src/main/ets/model/MemeCore.ts';

let passed = 0;
let failed = 0;
const failures = [];
function check(cond, msg) {
  if (cond) {
    passed += 1;
  } else {
    failed += 1;
    failures.push(msg);
    console.error('  ✗ ' + msg);
  }
}
function group(n) { console.log('\n' + n); }

let seq = 0;
function genId(prefix) {
  seq += 1;
  return `${prefix}_${seq}`;
}

/** 最小可用 AppData */
function emptyData() {
  return {
    books: [{ id: 'book0', name: '我的词本', source: 'DIY', createdAt: 1 }],
    words: [],
    records: [],
    schedules: [],
    memes: [],
    sessions: [],
    settings: {
      dailyNewCount: 20,
      asrStrictness: 'MID',
      ttsRate: 1,
      shortTermEnabled: false,
      activeBookId: 'book0',
      learningBooks: ['book0'],
      memeStudying: true,
      ocrStudying: true,
    },
    checkins: [],
    badges: [],
    wrongEntries: [],
  };
}

function cand(token, extra = {}) {
  return {
    token,
    kind: 'NEW',
    existingWordId: '',
    selected: true,
    toggleable: true,
    ...extra,
  };
}

const NOW = 1730000000000;

/* ================= A. 新词带释义入库 ================= */
group('[A] 新词带释义入库');
{
  const data = emptyData();
  const candidates = [
    cand('shattered', { phonetic: "/'ʃætəd/", meaning: 'a. 极度疲劳的；破碎的' }),
    cand('utterly', { phonetic: '/ˈʌtəli/', meaning: 'adv. 完全地, 全然, 绝对' }),
  ];
  const out = createMemeImport(data, {
    chinese: '我彻底破防了',
    english: "I'm utterly shattered.",
    candidates,
  }, NOW, () => 0);

  const w1 = out.data.words.find((w) => w.english === 'shattered');
  const w2 = out.data.words.find((w) => w.english === 'utterly');
  check(w1 !== undefined, 'A1 shattered 应入词表');
  check(w1 !== undefined && w1.meanings.length === 2, `A2 shattered 应有 2 个义项，实际 ${w1?.meanings?.length}`);
  check(w1 !== undefined && w1.meanings.join('；') === 'a. 极度疲劳的；破碎的', 'A3 义项 join 后应还原原文');
  check(w1 !== undefined && w1.missingMeaning === false, 'A4 有释义时 missingMeaning 必须为 false');
  check(w1 !== undefined && w1.phonetic === "/'ʃætəd/", 'A5 音标应写入');
  check(w2 !== undefined && w2.meanings.length === 1, 'A6 单义项词应只有 1 条');
  check(out.data.words.every((w) => w.source === 'MEME'), 'A7 来源标记为 MEME');
}

/* ================= B. 词典未收录 ================= */
group('[B] 词典未收录的词');
{
  const data = emptyData();
  const candidates = [cand('humblebrag'), cand('slack', { meaning: 'n. 松弛, 松懈' })];
  const out = createMemeImport(data, {
    chinese: '低调炫', english: 'humblebrag and slack', candidates,
  }, NOW, () => 0);
  const hb = out.data.words.find((w) => w.english === 'humblebrag');
  check(hb !== undefined, 'B1 未收录词仍允许入库（不阻断背诵）');
  check(hb !== undefined && hb.meanings.length === 0, 'B2 未收录词 meanings 为空');
  check(hb !== undefined && hb.missingMeaning === true, 'B3 未收录词必须显式标 missingMeaning');
}

/* ================= C. 老数据自愈 ================= */
group('[C] 已有空释义词的自愈');
{
  const data = emptyData();
  // 模拟旧版本导入的梗句词：有记录、有排期、释义为空
  data.words.push({
    id: 'old1', bookId: 'book0', english: 'nailed', phonetic: '',
    meanings: [], source: 'MEME', missingMeaning: true, diySupplement: false, createdAt: 1,
  });
  const candidates = [{
    token: 'nailed', kind: 'LEARNING', existingWordId: 'old1',
    selected: true, toggleable: true, phonetic: '/neild/', meaning: 'a. 用钉钉牢的',
  }, cand('slack', { meaning: 'n. 松弛' })];

  const out = createMemeImport(data, {
    chinese: '你 nailed it', english: 'you nailed it', candidates,
  }, NOW, () => 0);
  const w = out.data.words.find((x) => x.id === 'old1');
  check(w !== undefined && w.meanings.length === 1, 'C1 老空释义词应被补齐');
  check(w !== undefined && w.missingMeaning === false, 'C2 补齐后 missingMeaning 应为 false');
  check(w !== undefined && w.phonetic === '/neild/', 'C3 空音标应被补上');
  check(out.data.words.filter((x) => x.english === 'nailed').length === 1, 'C4 不得重复建词');
}

/* ================= D. 不覆盖手填释义 ================= */
group('[D] 不覆盖用户手填');
{
  const data = emptyData();
  data.words.push({
    id: 'mine', bookId: 'book0', english: 'slack', phonetic: '/slæk/',
    meanings: ['我自己的记法：摸鱼'], source: 'DIY', missingMeaning: false,
    diySupplement: true, createdAt: 1,
  });
  const candidates = [{
    token: 'slack', kind: 'LEARNING', existingWordId: 'mine',
    selected: true, toggleable: true, meaning: 'n. 松弛, 松懈, 淡季',
  }, cand('rot', { meaning: 'n. 腐烂' })];
  const out = createMemeImport(data, {
    chinese: '摸鱼烂掉', english: 'slack and rot', candidates,
  }, NOW, () => 0);
  const w = out.data.words.find((x) => x.id === 'mine');
  check(w !== undefined && w.meanings[0] === '我自己的记法：摸鱼', 'D1 手填释义不得被词典覆盖');
  check(w !== undefined && w.diySupplement === true, 'D2 DIY 标记保留');
}

/* ================= E. 「；」拆分还原 ================= */
group('[E] 多义项拆分');
{
  const data = emptyData();
  const long = 'n. 钩, 钩状, 镰刀, 陷阱；vt. 挂...于钩上, 钩住, 沉迷；vi. 钩住';
  const out = createMemeImport(data, {
    chinese: '上钩了', english: 'hooked', candidates: [
      cand('hooked', { meaning: long }), cand('slack', { meaning: 'n. 松弛' }),
    ],
  }, NOW, () => 0);
  const w = out.data.words.find((x) => x.english === 'hooked');
  check(w !== undefined && w.meanings.length === 3, `E1 应拆成 3 个义项，实际 ${w?.meanings?.length}`);
  check(w !== undefined && w.meanings.join('；') === long, 'E2 拆分后 join 必须与原文一致');
  check(w !== undefined && w.meanings.every((m) => m.length > 0), 'E3 不得有空义项');
}

/* ================= F. 老调用方兼容 ================= */
group('[F] 只传 5 字段的候选');
{
  const data = emptyData();
  const out = createMemeImport(data, {
    chinese: '测试', english: 'slack rot',
    candidates: [cand('slack'), cand('rot')],
  }, NOW, () => 0);
  check(out.data.words.length === 2, 'F1 仍能正常导入 2 个词');
  check(out.data.words.every((w) => w.meanings.length === 0 && w.missingMeaning === true),
    'F2 无 meaning 字段时保持旧行为（空释义 + 标记）');
  check(out.session.items.length === 2, 'F3 会话词数正确');
}

/* ================= G. 停用词：缩写不得进候选 ================= */
group('[G] 缩写停用词');
{
  for (const w of ["i'm", "it's", "don't", "can't", "you're", "let's"]) {
    check(STOP_WORDS.has(w), `G1 ${w} 应进停用词表`);
  }
  const tokens = tokenizeEnglish("I'm utterly shattered. Who else gets this?");
  check(!tokens.includes("i'm"), "G2 i'm 不得出现在候选词里");
  check(tokens.includes('utterly') && tokens.includes('shattered') && tokens.includes('gets'),
    'G3 实词仍应保留');
  const tokens2 = tokenizeEnglish("Don't be a stranger, it's gonna be fine.");
  check(!tokens2.includes("don't") && !tokens2.includes("it's") && !tokens2.includes('gonna'),
    `G4 缩写全部过滤，实际 [${tokens2.join(', ')}]`);

  // G5 缩写兜底规则：前半段是停用词或单字母时整词丢弃（不依赖清单是否列全）
  const tokens3 = tokenizeEnglish("Y'all know o'clock, ma'am?");
  check(!tokens3.includes("y'all"), "G5 y'all 应被缩写兜底丢弃");
  check(!tokens3.includes("o'clock"), "G6 o'clock 单字母前缀，按缩写兜底丢弃");
  check(tokens3.includes("ma'am"), "G7 ma'am 前缀 ma 不是停用词，应保留");
  check(tokens3.includes('know'), 'G8 实词不受影响');
}

/* ================= H. buildCandidates 不写死释义 ================= */
group('[H] buildCandidates 保持纯逻辑');
{
  const words = [];
  const scheds = [];
  const out = buildCandidates(['slack'], words, scheds);
  check(out.length === 1 && out[0].kind === 'NEW', 'H1 新词判定不变');
  check(out[0].meaning === undefined, 'H2 候选初始不带 meaning（由页面层查词典填充）');
  check(out[0].selected === true && out[0].toggleable === true, 'H3 新词默认勾选可改');
}

console.log(`\n${'─'.repeat(52)}`);
if (failed === 0) {
  console.log(`✅ 全部通过：${passed} 项断言`);
} else {
  console.log(`❌ ${failed} 项失败 / 共 ${passed + failed} 项`);
  for (const f of failures) console.log('   - ' + f);
  process.exit(1);
}
