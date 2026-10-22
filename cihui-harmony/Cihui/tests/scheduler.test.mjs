/**
 * 词慧调度器 Node 原生测试（零 npm 依赖）。
 * 运行：node --experimental-strip-types --import ./tests/register-loader.mjs tests/scheduler.test.mjs
 *
 * 覆盖：
 * A. planNewWords 新旧实现对拍（行为等价硬保证，随机场景矩阵）
 * B. planNewWords 性能（6000 条 < 50ms）
 * C. importTransaction 性能（4000 词全程 < 800ms）+ 行为
 * D. applyDailyNewCount 语义（今日已学回退/逾期保留/未来重排逐日配额/打卡删除/历史不动）
 * E. previewDailyNew 与 applyDailyNewCount 同构
 * F. OCR/addWord 导入链路（新词立即入当日计划）
 * G. judge 三档判定回归锚点
 * H. F-A 拍照导入两模式（TODAY 不占配额 / QUEUE 排队）
 * I. F-B 逾期打散（1/3 几何衰减，数据不改、视图层截断）
 * J. F-D 单词本限制（10–1000 自定义 / 一次背一本 / 拍照例外 / setDailyNewCount）
 */
import {
  planNewWords,
  judge,
  previewDailyNew,
  buildDayPlan,
  buildWrongEntries,
  dayKeyFromTs,
  addDays,
  diffDays,
  clampDailyNew,
  newImportedSchedule,
  newStudyRecord,
  defaultState,
} from '../entry/src/main/ets/model/SchedulerCore.ts';
import {
  addWord,
  importTransaction,
  importCloudBook,
  applyDailyNewCount,
  setDailyNewCount,
  switchActiveBookData,
  activeScopeWordIds,
  exceptionWordIds,
  emptyData,
} from '../entry/src/main/ets/model/RepoCore.ts';
import { DEFAULT_SETTINGS } from '../entry/src/main/ets/model/Types.ts';

/* ============ 微型断言器 ============ */
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

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function summary(name) {
  console.log(`\n[${name}] 通过 ${passed} 项，失败 ${failed} 项`);
  if (failed > 0) {
    process.exit(1);
  }
}

/* ============ 固定种子 PRNG（mulberry32） ============ */
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/* ============ 固定测试时钟 ============ */
const NOW = new Date(2026, 9, 16, 9, 0, 0).getTime(); // 2026-10-16 09:00 本地时间
const TODAY = dayKeyFromTs(NOW);

/* ============ 旧版 planNewWords（O(n²)，原样拷贝自 SchedulerCore.ts L288-306，用于对拍） ============ */
function planNewWordsLegacy(schedules, now, dailyNewCount) {
  const quota = clampDailyNew(dailyNewCount);
  const result = schedules.map((s) => ({ ...s }));
  const today = dayKeyFromTs(now);
  let cursorDay = today;
  // 逾期未学的新词算作今日占用（与生产实现同口径；否则昨天欠 20 个今天又发 20 个）
  const bucketOf = (d) => (d < today ? today : d);
  const remaining = () => result.filter((s) => s.stage === 'NEW' && s.dueDay !== ''
    && s.intake !== 'TODAY' && bucketOf(s.dueDay) === cursorDay).length;
  for (let i = 0; i < result.length; i++) {
    const s = result[i];
    if (s.stage !== 'NEW' || s.dueDay !== '') {
      continue;
    }
    while (remaining() >= quota) {
      cursorDay = addDays(cursorDay, 1);
    }
    s.dueDay = cursorDay;
  }
  return result;
}

/* ============ 随机场景生成 ============ */
const STAGES = ['R1', 'R2', 'R4', 'R7', 'R15'];
function genSchedules(rng, n) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const r = rng();
    let s;
    if (r < 0.35) {
      // 未排期新词（导入后待排期）
      s = newImportedSchedule('w' + i);
    } else if (r < 0.5) {
      // 已排期新词（未来/今天/过去随机）
      const off = Math.floor(rng() * 11) - 5; // -5..+5 天
      s = { ...newImportedSchedule('w' + i), dueDay: addDays(TODAY, off) };
    } else if (r < 0.85) {
      // 长期复习中
      const stage = STAGES[Math.floor(rng() * STAGES.length)];
      const flOff = -(Math.floor(rng() * 14) + 1); // 过去 1..14 天首学
      const firstLearnDay = addDays(TODAY, flOff);
      s = {
        ...newImportedSchedule('w' + i),
        stage,
        firstLearnDay,
        dueDay: addDays(firstLearnDay, { R1: 1, R2: 2, R4: 4, R7: 7, R15: 15 }[stage]),
      };
    } else if (r < 0.93) {
      // 错词（WRONG）
      s = {
        ...newImportedSchedule('w' + i),
        dueDay: addDays(TODAY, 1),
        status: 'WRONG',
        wrongReason: '不认识·转明天新词',
        lastVerdictAt: NOW - 3600_000,
      };
    } else {
      // 已掌握
      s = {
        ...newImportedSchedule('w' + i),
        stage: 'MASTERED',
        firstLearnDay: addDays(TODAY, -20),
        dueDay: '',
        status: 'MASTERED',
      };
    }
    out.push(s);
  }
  return out;
}

/* ================= A. 新旧实现对拍 ================= */
console.log('[A] planNewWords 新旧实现对拍');
const scenarios = [
  { n: 0, quota: 20, seed: 1 },
  { n: 1, quota: 5, seed: 2 },
  { n: 50, quota: 5, seed: 3 },
  { n: 50, quota: 20, seed: 4 },
  { n: 4000, quota: 5, seed: 5 },
  { n: 4000, quota: 40, seed: 6 },
];
// 显式用例：今天已有已排期新词占用配额（对拍最易漏的细节）
function explicitTodayOccupiedCase() {
  const schedules = [];
  for (let i = 0; i < 3; i++) {
    schedules.push({ ...newImportedSchedule('occupied' + i), dueDay: TODAY });
  }
  for (let i = 0; i < 10; i++) {
    schedules.push(newImportedSchedule('fresh' + i));
  }
  return schedules;
}
const cases = scenarios.map((c) => ({
  name: `n=${c.n},quota=${c.quota},seed=${c.seed}`,
  schedules: genSchedules(mulberry32(c.seed), c.n),
  quota: c.quota,
}));
cases.push({
  name: 'explicit-today-occupied,quota=5',
  schedules: explicitTodayOccupiedCase(),
  quota: 5,
});
cases.push({
  name: 'explicit-today-occupied,quota=40',
  schedules: explicitTodayOccupiedCase(),
  quota: 40,
});

for (const c of cases) {
  const legacy = planNewWordsLegacy(c.schedules, NOW, c.quota);
  const modern = planNewWords(c.schedules, NOW, c.quota);
  check(deepEqual(legacy, modern), `A: 对拍不一致（${c.name}）`);
  // 配额不变式：已排期词本身可能超配额（算法尊重已有排期不重排），
  // 正确口径：排期后某日 NEW 数 ≤ max(该日排期前已有数, 配额)（仅对今天及以后的日子）
  const pre = new Map();
  for (const s of c.schedules) {
    if (s.stage === 'NEW' && s.dueDay !== '') {
      pre.set(s.dueDay, (pre.get(s.dueDay) ?? 0) + 1);
    }
  }
  const post = new Map();
  for (const s of modern) {
    if (s.stage === 'NEW' && s.dueDay !== '') {
      post.set(s.dueDay, (post.get(s.dueDay) ?? 0) + 1);
    }
  }
  let quotaOk = true;
  post.forEach((v, day) => {
    if (diffDays(TODAY, day) >= 0 && v > Math.max(pre.get(day) ?? 0, clampDailyNew(c.quota))) {
      quotaOk = false;
    }
  });
  check(quotaOk, `A: 排期后某日新词数超过 max(已有,配额)（${c.name}）`);
}
console.log('  ✓ 对拍与配额不变式全部通过');

/* ================= B. planNewWords 性能 ================= */
console.log('[B] planNewWords 性能');
{
  const big = [];
  for (let i = 0; i < 6000; i++) {
    big.push(newImportedSchedule('perf' + i));
  }
  const t0 = performance.now();
  const out = planNewWords(big, NOW, 20);
  const dt = performance.now() - t0;
  check(out.length === 6000, 'B: 输出长度不变');
  check(dt < 50, `B: planNewWords 6000 条耗时 ${dt.toFixed(1)}ms ≥ 50ms`);
  console.log(`  planNewWords 6000 条实测 ${dt.toFixed(1)}ms`);
  // 修复前基线（legacy 参照，仅打印）
  const t1 = performance.now();
  planNewWordsLegacy(big, NOW, 20);
  console.log(`  （旧实现参照 ${ (performance.now() - t1).toFixed(1)}ms）`);
}

/* ================= C. importTransaction 性能与行为 ================= */
console.log('[C] importTransaction 性能与行为');
{
  let data = emptyData();
  data = {
    ...data,
    books: [{ id: 'b1', name: 'CET4', source: 'CLOUD', cloudBookId: 'cet4', createdAt: NOW }],
  };
  const drafts = [];
  for (let i = 0; i < 4000; i++) {
    drafts.push({
      bookId: 'b1',
      english: 'word' + i,
      phonetic: '',
      meanings: ['释义' + i],
      source: 'CLOUD',
    });
  }
  const t0 = performance.now();
  const next = importTransaction(data, drafts, NOW);
  const dt = performance.now() - t0;
  check(next.words.length === 4000, 'C: 导入词数正确');
  check(next.schedules.length === 4000, 'C: 调度数正确');
  const todayNew = next.schedules.filter(
    (s) => s.stage === 'NEW' && s.dueDay === TODAY,
  ).length;
  check(todayNew === 20, `C: 今日新词应为 20（实际 ${todayNew}）`);
  check(dt < 800, `C: 4000 词导入全程 ${dt.toFixed(0)}ms ≥ 800ms`);
  console.log(`  importTransaction 4000 词实测 ${dt.toFixed(0)}ms`);
  // 事务性：校验失败整体抛错，data 原样未动
  const bad = [{ bookId: 'b1', english: ' ', phonetic: '', meanings: ['x'], source: 'CLOUD' }];
  let threw = false;
  try {
    importTransaction(data, bad, NOW);
  } catch (e) {
    threw = true;
  }
  check(threw, 'C: 空单词应抛错');
}

/* ================= D. applyDailyNewCount 语义 ================= */
console.log('[D] applyDailyNewCount 语义');
{
  let data = emptyData();
  data = { ...data, books: [{ id: 'b1', name: 'B', source: 'CLOUD', createdAt: NOW }] };
  // 构造：昨天已学的词（历史，不动）、今天已学的词（回退）、逾期未学（保留今天）、未来已排期（重排）
  const drafts = [];
  for (let i = 0; i < 30; i++) {
    drafts.push({ bookId: 'b1', english: 'w' + i, phonetic: '', meanings: ['m'], source: 'CLOUD' });
  }
  data = importTransaction(data, drafts, NOW);
  const scheds = data.schedules;
  // 找到分类样本
  const todayDue = scheds.filter((s) => s.dueDay === TODAY && s.firstLearnDay === '');
  const futureDue = scheds.filter(
    (s) => s.stage === 'NEW' && s.dueDay !== '' && s.dueDay !== TODAY && diffDays(TODAY, s.dueDay) > 0,
  );
  check(todayDue.length === 20, 'D: 前置——今日到期新词 20 个');
  check(futureDue.length === 10, 'D: 前置——未来排期新词 10 个');
  // 模拟今天已首学其中 5 个（firstLearnDay=今天，且已转 R1）
  let mutated = data;
  const learnedToday = todayDue.slice(0, 5).map((s) => s.wordId);
  mutated = {
    ...mutated,
    schedules: mutated.schedules.map((s) =>
      learnedToday.includes(s.wordId)
        ? { ...s, stage: 'R1', firstLearnDay: TODAY, dueDay: addDays(TODAY, 1) }
        : s,
    ),
    records: mutated.records.map((r) =>
      learnedToday.includes(r.wordId)
        ? { ...r, firstStudyAt: NOW, firstPassedAt: NOW, lastStudyDay: TODAY }
        : r,
    ),
    checkins: [
      {
        day: TODAY,
        p1NewDone: true,
        p2ReviewDone: true,
        p3WrongDone: true,
        p3Required: false,
        checkedIn: true,
        makeup: false,
        streak: 1,
      },
    ],
  };
  // 改每日新词量 20 → 40
  const after = applyDailyNewCount(mutated, 40, NOW);
  check(after.settings.dailyNewCount === 40, 'D: settings.dailyNewCount 更新为 40');
  check(after.checkins.find((c) => c.day === TODAY) === undefined, 'D: 当天打卡记录被删除');
  // 今天已学的 5 个词回退为未排期新词
  for (const id of learnedToday) {
    const s = after.schedules.find((x) => x.wordId === id);
    check(s.stage === 'NEW' && s.firstLearnDay === '', `D: ${id} 回退为未排期新词`);
  }
  // 历史不动：把昨天学的一个词放进去验证（用 R2 且 firstLearnDay=昨天）
  const withHistory = {
    ...after,
    schedules: [
      ...after.schedules,
      {
        ...newImportedSchedule('hist'),
        stage: 'R2',
        firstLearnDay: addDays(TODAY, -1),
        dueDay: addDays(TODAY, 1),
      },
    ],
  };
  const after2 = applyDailyNewCount(withHistory, 10, NOW);
  const hist = after2.schedules.find((x) => x.wordId === 'hist');
  check(
    hist.stage === 'R2' && hist.dueDay === addDays(TODAY, 1),
    'D: 历史 R 节点词不被重排',
  );
  // 逐日配额不变式：重排后今天及以后某日 NEW 数 ≤ max(重排前该日已有数, 新配额)
  //（applyDailyNewCount 口径：逾期/今日未学词保留原到期日，本身可能已超新配额，不重排）
  const preDays = new Map();
  for (const s of withHistory.schedules) {
    if (s.stage === 'NEW' && s.firstLearnDay === '' && s.dueDay !== '') {
      preDays.set(s.dueDay, (preDays.get(s.dueDay) ?? 0) + 1);
    }
  }
  const postDays = new Map();
  for (const s of after2.schedules) {
    if (s.stage === 'NEW' && s.firstLearnDay === '' && s.dueDay !== '') {
      postDays.set(s.dueDay, (postDays.get(s.dueDay) ?? 0) + 1);
    }
  }
  let quotaOk = true;
  postDays.forEach((v, day) => {
    if (diffDays(TODAY, day) >= 0 && v > Math.max(preDays.get(day) ?? 0, 10)) {
      quotaOk = false;
    }
  });
  check(quotaOk, 'D: 重排后每日新词数 ≤ max(已有,新配额)');
}

/* ================= E. preview 与 apply 同构 ================= */
console.log('[E] previewDailyNew 与 applyDailyNewCount 同构');
{
  const rng = mulberry32(42);
  const schedules = genSchedules(rng, 300);
  const state = {
    schedules,
    records: schedules.map((s) => newStudyRecord(s.wordId)),
    settings: { ...DEFAULT_SETTINGS },
  };
  for (const n of [5, 12, 40]) {
    const preview = previewDailyNew(state, n, NOW);
    const after = applyDailyNewCount(
      { ...emptyData(), schedules, records: state.records, settings: state.settings },
      n,
      NOW,
    );
    const plan = buildDayPlan(
      { schedules: after.schedules, records: after.records, settings: after.settings },
      TODAY,
    );
    check(
      plan.newWords.length === preview.newCount,
      `E: n=${n} 预览新词 ${preview.newCount} ≠ 实际 ${plan.newWords.length}`,
    );
    let reviewCount = 0;
    for (const k of ['R1', 'R2', 'R4', 'R7', 'R15']) {
      reviewCount += plan.reviewBuckets[k].length;
    }
    check(
      reviewCount === preview.reviewCount,
      `E: n=${n} 预览复习 ${preview.reviewCount} ≠ 实际 ${reviewCount}`,
    );
  }
}

/* ================= F. OCR/addWord 导入链路 ================= */
console.log('[F] OCR/addWord 导入链路（新词立即入当日计划）');
{
  let data = emptyData();
  data = { ...data, books: [{ id: 'b1', name: 'B', source: 'DIY_PHOTO', createdAt: NOW }] };
  const draft = { bookId: 'b1', english: 'photo_word', phonetic: '', meanings: ['拍照词'], source: 'OCR' };
  const after = addWord(data, draft, NOW);
  const sched = after.schedules.find((s) => s.wordId === after.words[0].id);
  check(sched !== undefined, 'F: addWord 已建调度');
  check(sched.dueDay === TODAY, 'F: 新词当天到期（额度未满）');
  const plan = buildDayPlan(
    { schedules: after.schedules, records: after.records, settings: after.settings },
    TODAY,
  );
  check(plan.newWords.includes(sched.wordId), 'F: 新词出现在当日 newWords 桶');
  // 批量（模拟 OCR 一次识别多词）走 importTransaction
  const drafts = ['a', 'b', 'c'].map((w) => ({
    bookId: 'b1',
    english: 'ocr_' + w,
    phonetic: '',
    meanings: ['x'],
    source: 'OCR',
  }));
  const after2 = importTransaction(data, drafts, NOW);
  const newIds = after2.words.filter((w) => w.source === 'OCR').map((w) => w.id);
  const plan2 = buildDayPlan(
    { schedules: after2.schedules, records: after2.records, settings: after2.settings },
    TODAY,
  );
  for (const id of newIds) {
    check(plan2.newWords.includes(id), 'F: OCR 批量词入当日计划');
  }
}

/* ================= G. judge 三档判定回归锚点 ================= */
console.log('[G] judge 回归锚点');
{
  const sched = { ...newImportedSchedule('w1'), dueDay: TODAY };
  const rec = newStudyRecord('w1');
  // 新词首过 → 次日 R1
  const k = judge(sched, rec, 'FIRST', 'KNOWN', NOW);
  check(k.schedule.stage === 'R1', 'G: 首过→R1');
  check(k.schedule.dueDay === addDays(TODAY, 1), 'G: 首过→次日到期');
  check(k.schedule.firstLearnDay === TODAY, 'G: 首学日=今天');
  // 复习认识 → 推进 R2，不早于明天
  const k2 = judge(k.schedule, k.record, 'REVIEW', 'KNOWN', NOW);
  check(k2.schedule.stage === 'R2', 'G: R1 认识→R2');
  check(k2.schedule.dueDay === addDays(TODAY, 2), 'G: R2 绝对到期=首学+2');
  // R15 认识 → MASTERED
  const masteredSched = {
    ...newImportedSchedule('w2'),
    stage: 'R15',
    firstLearnDay: addDays(TODAY, -15),
    dueDay: TODAY,
  };
  const k3 = judge(masteredSched, rec, 'REVIEW', 'KNOWN', NOW);
  check(k3.schedule.stage === 'MASTERED' && k3.schedule.dueDay === '', 'G: R15 认识→MASTERED');
  // 模糊 → 停留 + 次日强制 + 错词本 VAGUE
  const v = judge(k.schedule, k.record, 'REVIEW', 'VAGUE', NOW);
  check(v.schedule.dueDay === addDays(TODAY, 1), 'G: 模糊→次日到期');
  check(v.schedule.forceNextDay && v.schedule.roundRequeue, 'G: 模糊→强制次日+本轮重考');
  check(v.wrongAdded && v.wrongReason === '模糊·次日强制复习', 'G: 模糊→错词本 VAGUE');
  // 不认识 → 清零 WRONG + 错词本 UNKNOWN
  const u = judge(k.schedule, k.record, 'REVIEW', 'UNKNOWN', NOW);
  check(u.schedule.stage === 'NEW' && u.schedule.status === 'WRONG', 'G: 不认识→清零 WRONG');
  check(u.schedule.dueDay === addDays(TODAY, 1), 'G: 不认识→次日新词');
  check(u.wrongAdded && u.wrongReason === '不认识·转明天新词', 'G: 不认识→错词本 UNKNOWN');
  check(u.record.firstStudyAt === 0, 'G: 不认识→学习记录重置');
}

/* ================= H. 拍照导入两模式（F-A：加入当天计划 / 直接加入词本） ================= */
console.log('[H] 拍照导入两模式');
{
  const mkDraft = (w) => ({ bookId: 'b1', english: w, phonetic: '', meanings: ['x'], source: 'OCR' });
  const data = { ...emptyData(), books: [{ id: 'b1', name: 'B', source: 'DIY_PHOTO', createdAt: NOW }] };

  // H1: TODAY 导入 → dueDay=今天、intake='TODAY'、进当日 newWords
  const before1 = data.words.length;
  const d1 = importTransaction(data, ['t1', 't2', 't3'].map(mkDraft), NOW, 'TODAY');
  const tWords1 = d1.words.slice(before1);
  const tScheds1 = d1.schedules.filter((s) => tWords1.some((w) => w.id === s.wordId));
  check(tScheds1.length === 3, 'H1: 导入 3 词各建调度');
  check(tScheds1.every((s) => s.dueDay === TODAY && s.intake === 'TODAY'), 'H1: TODAY 词当天到期且带 intake 标记');
  const plan1 = buildDayPlan({ schedules: d1.schedules, records: d1.records, settings: d1.settings }, TODAY);
  check(tScheds1.every((s) => plan1.newWords.includes(s.wordId)), 'H1: TODAY 词进当日 newWords');

  // H2: 不占配额。quota=10：QUEUE 导 10 词今天满；TODAY 导 3 词 → 今天 13 个；再 QUEUE 导 1 词排明天
  const dataQ5 = { ...data, settings: { ...DEFAULT_SETTINGS, dailyNewCount: 10 } };
  const d2 = importTransaction(dataQ5, ['q1', 'q2', 'q3', 'q4', 'q5', 'q6', 'q7', 'q8', 'q9', 'q10'].map(mkDraft), NOW);
  const plan2a = buildDayPlan({ schedules: d2.schedules, records: d2.records, settings: d2.settings }, TODAY);
  check(plan2a.newWords.length === 10, 'H2 前置: quota=10 时 QUEUE 10 词全部今天');
  const before2 = d2.words.length;
  const d3 = importTransaction(d2, ['t1', 't2', 't3'].map(mkDraft), NOW, 'TODAY');
  const tIds = d3.words.slice(before2).map((w) => w.id);
  const plan2b = buildDayPlan({ schedules: d3.schedules, records: d3.records, settings: d3.settings }, TODAY);
  check(plan2b.newWords.length === 13, `H2: TODAY 导入后今天新词 10+3=13（实际 ${plan2b.newWords.length}）`);
  const before3 = d3.words.length;
  const d4 = importTransaction(d3, ['q6'].map(mkDraft), NOW);
  const q6 = d4.schedules.find((s) => s.wordId === d4.words[before3].id);
  check(q6 !== undefined && q6.dueDay === addDays(TODAY, 1),
    `H2: 再 QUEUE 导 1 词排到明天（实际 ${q6 ? q6.dueDay : 'undefined'}），TODAY 词未挤占配额`);

  // H3: 改每日新词量后，未学 TODAY 词保持今天到期且 intake 保留
  const d5 = applyDailyNewCount(d4, 10, NOW);
  const tScheds5 = d5.schedules.filter((s) => tIds.includes(s.wordId));
  check(tScheds5.length === 3
    && tScheds5.every((s) => s.dueDay === TODAY && s.intake === 'TODAY'),
    'H3: applyDailyNewCount 后未学 TODAY 词保持今天 + intake 保留');

  // H4: 默认 QUEUE 行为不变（addWord/importTransaction 不传 intake）
  const d6 = addWord(data, mkDraft('plain_word'), NOW);
  const sched6 = d6.schedules.find((s) => s.wordId === d6.words[0].id);
  check(sched6 !== undefined && sched6.dueDay === TODAY && sched6.intake === undefined,
    'H4: 默认导入行为不变（无 intake 字段，当天到期）');
}

/* ================= I. 逾期打散（F-B：缺席补课，视图层截断不改数据） ================= */
console.log('[I] 逾期打散');
{
  const mkSched = (wordId, stage, dueDay) => ({
    ...newImportedSchedule(wordId),
    stage,
    firstLearnDay: addDays(dueDay, -2),
    dueDay,
  });
  const bucketSum = (plan) =>
    ['R1', 'R2', 'R4', 'R7', 'R15'].reduce((n, k) => n + plan.reviewBuckets[k].length, 0);

  // I1: 6 个逾期（前天 R1×3、昨天 R2×3）+ 2 个今日到期 → 桶 = 2 + ⌈6/3⌉
  const schedules = [
    ...['o1', 'o2', 'o3'].map((w) => mkSched(w, 'R1', addDays(TODAY, -2))),
    ...['o4', 'o5', 'o6'].map((w) => mkSched(w, 'R2', addDays(TODAY, -1))),
    ...['d1', 'd2'].map((w) => mkSched(w, 'R4', TODAY)),
  ];
  const plan = buildDayPlan({ schedules, records: [], settings: DEFAULT_SETTINGS }, TODAY);
  check(plan.overdue.length === 6, `I1: overdue 数组保持全量 6（实际 ${plan.overdue.length}）`);
  check(bucketSum(plan) === 4, `I1: 今日桶 = 2 + ⌈6/3⌉=2 → 4（实际 ${bucketSum(plan)}）`);

  // I2: 进桶的逾期词最老的先——⌈6/3⌉=2 个：前天组按数组序放行 o1/o2，o3~o6 留在积压
  const inBucket = new Set([].concat(...['R1', 'R2', 'R4', 'R7', 'R15'].map((k) => plan.reviewBuckets[k])));
  check(['d1', 'd2'].every((w) => inBucket.has(w)), 'I2: 今日到期 2 个在桶');
  check(inBucket.has('o1') && inBucket.has('o2')
    && !inBucket.has('o3') && !inBucket.has('o4') && !inBucket.has('o5') && !inBucket.has('o6'),
    'I2: 逾期按到期日升序只放行最老的 o1/o2，其余留在积压');

  // I3: 未进桶的逾期词数据原样保留（视图层截断，不写 dueDay）
  const o5 = schedules.find((s) => s.wordId === 'o5');
  check(o5.dueDay === addDays(TODAY, -1) && o5.stage === 'R2', 'I3: 未进桶逾期词 dueDay/stage 不变');

  // I4: 无逾期场景行为不变
  const plan0 = buildDayPlan(
    { schedules: ['d1', 'd2'].map((w) => mkSched(w, 'R4', TODAY)), records: [], settings: DEFAULT_SETTINGS },
    TODAY,
  );
  check(plan0.overdue.length === 0 && bucketSum(plan0) === 2 && plan0.newWords.length === 0,
    'I4: 无逾期场景行为与旧实现一致');

  // I5: 全逾期 9 个 → 今日桶 3 个
  const nine = ['x1', 'x2', 'x3', 'x4', 'x5', 'x6', 'x7', 'x8', 'x9']
    .map((w, i) => mkSched(w, i % 2 === 0 ? 'R1' : 'R2', addDays(TODAY, -1)));
  const plan9 = buildDayPlan({ schedules: nine, records: [], settings: DEFAULT_SETTINGS }, TODAY);
  check(bucketSum(plan9) === 3, `I5: 全逾期 9 个 → 今日桶 ⌈9/3⌉=3（实际 ${bucketSum(plan9)}）`);

  // I6: 打散收敛——每天复习露出的词（dueDay 推到未来），积压按约 1/3 几何衰减直至清零
  let remaining9 = nine.map((s) => ({ ...s }));
  let days = 0;
  while (days < 20) {
    const p = buildDayPlan({ schedules: remaining9, records: [], settings: DEFAULT_SETTINGS }, TODAY);
    const shown = [].concat(...['R1', 'R2', 'R4', 'R7', 'R15'].map((k) => p.reviewBuckets[k]));
    if (shown.length === 0) {
      break;
    }
    const shownSet = new Set(shown);
    remaining9 = remaining9.map((s) =>
      shownSet.has(s.wordId) ? { ...s, dueDay: addDays(TODAY, 30 + days) } : s);
    days += 1;
  }
  check(days <= 8, `I6: 积压 9 个按 1/3 摊还应在 ≤8 天内清零（实际 ${days} 天）`);
}

/* ================= J. F-D 单词本限制：10–1000 + 一次背一本 + 拍照例外 ================= */
{
  const mkBook = (id, name, source) => ({ id, name, source, createdAt: NOW });
  const mkWord = (id, bookId) => ({
    id, bookId, english: id, phonetic: '', meanings: ['释义'], source: 'CLOUD',
    missingMeaning: false, diySupplement: false, createdAt: NOW,
  });

  // J1 范围边界
  check(clampDailyNew(5) === 10, 'J1: clampDailyNew(5)=10（下限提高）');
  check(clampDailyNew(9) === 10, 'J1: clampDailyNew(9)=10');
  check(clampDailyNew(1000) === 1000, 'J1: clampDailyNew(1000)=1000');
  check(clampDailyNew(1001) === 1000, 'J1: clampDailyNew(1001)=1000');
  check(clampDailyNew(37) === 37, 'J1: 任意中间值原样保留');

  // J2 planNewWords scope：scope 内排期、scope 外暂停、拍照例外
  {
    const d = emptyData();
    d.books = [mkBook('B1', 'CET4', 'CLOUD'), mkBook('BP', '拍照词本', 'DIY_PHOTO'),
      mkBook('B3', '别的书', 'DIY_MANUAL')];
    d.words = [mkWord('a1', 'B1'), mkWord('a2', 'B3'), mkWord('p1', 'BP')];
    d.settings.activeBookId = 'B1';
    d.schedules = ['a1', 'a2', 'p1'].map((id) => newImportedSchedule(id));
    const out = planNewWords(d.schedules, NOW, 10, activeScopeWordIds(d));
    check(out[0].dueDay === TODAY, 'J2: scope 内（背诵中词本）a1 排期今天');
    check(out[1].dueDay === '', 'J2: scope 外（其它词本）a2 保持未排期（暂停）');
    check(out[2].dueDay === TODAY, 'J2: 拍照词本 p1 例外参与排期');
  }

  // J3 switchActiveBookData：旧书暂停、复习义务保留、幂等安全
  {
    const d = emptyData();
    d.books = [mkBook('B1', '旧书', 'CLOUD'), mkBook('B2', '新书', 'CLOUD')];
    d.words = [mkWord('w1', 'B1'), mkWord('w2', 'B1'), mkWord('w3', 'B1'), mkWord('w4', 'B2')];
    d.settings.activeBookId = 'B1';
    d.schedules = [
      { ...newImportedSchedule('w1'), dueDay: TODAY },
      { ...newImportedSchedule('w2'), stage: 'R1', firstLearnDay: addDays(TODAY, -1), dueDay: TODAY },
      newImportedSchedule('w3'),
    ];
    const out = switchActiveBookData(d, 'B2', NOW);
    check(out.schedules[0].dueDay === '', 'J3: 旧书未首学新词清空排期（暂停）');
    check(out.schedules[1].stage === 'R1' && out.schedules[1].dueDay === TODAY, 'J3: 旧书复习义务不动');
    check(out.schedules[2].dueDay === '', 'J3: 旧书本就未排期的词不受影响');
    check(out.settings.activeBookId === 'B2', 'J3: activeBookId 切到新书');
    check(d.schedules[0].dueDay === TODAY, 'J3: 原数据不被篡改');
    const same = switchActiveBookData(out, 'B2', NOW);
    check(same.schedules[0].dueDay === '', 'J3: 重复切到同一本幂等');
  }

  // J3b switchActiveBookData：拍照词本例外——即使它曾被设为背诵中，切走也不暂停它的词
  //（真机 BUG：先切到拍照词本再切回四级，刚「加入当天计划」的词被暂停，看着像分开计划）
  {
    const d = emptyData();
    d.books = [mkBook('BP', '拍照词本', 'DIY_PHOTO'), mkBook('B2', '四级', 'CLOUD')];
    d.words = [mkWord('p1', 'BP'), mkWord('b1', 'B2')];
    d.settings.activeBookId = 'BP';
    d.schedules = [
      { ...newImportedSchedule('p1'), dueDay: TODAY, intake: 'TODAY' },
      newImportedSchedule('b1'),
    ];
    const out = switchActiveBookData(d, 'B2', NOW);
    check(out.schedules[0].dueDay === TODAY, 'J3b: 切走拍照词本，导入的词仍留在今天（不被暂停）');
    check(out.schedules[1].dueDay === TODAY, 'J3b: 新书词汇排到今天（不被白占配额）');
    check(out.settings.activeBookId === 'B2', 'J3b: activeBookId 切到四级');
  }

  // J4 activeScopeWordIds 例外集合
  {
    const d = emptyData();
    d.books = [
      mkBook('B1', '在背', 'CLOUD'), mkBook('BP', '拍照词本', 'DIY_PHOTO'),
      mkBook('BM', '梗句', 'MEME'), mkBook('B3', '别的DIY', 'DIY_MANUAL'),
    ];
    d.words = [mkWord('x1', 'B1'), mkWord('x2', 'BP'), mkWord('x3', 'BM'), mkWord('x4', 'B3')];
    d.settings.activeBookId = 'B1';
    const scope = activeScopeWordIds(d);
    check(scope.has('x1') && scope.has('x2') && scope.has('x3'), 'J4: 在背+拍照+梗句都在 scope');
    check(!scope.has('x4'), 'J4: 其它 DIY 词本不在 scope');
    d.settings.activeBookId = '';
    check(activeScopeWordIds(d) === undefined, 'J4: activeBookId 为空 → undefined（旧数据全兼容）');
  }

  // J5 importCloudBook：下载即切书，新书排期、旧书未学词暂停
  {
    const d = emptyData();
    d.books = [mkBook('B1', '旧书', 'CLOUD')];
    d.words = [mkWord('w1', 'B1')];
    d.settings.activeBookId = 'B1';
    d.schedules = [{ ...newImportedSchedule('w1'), dueDay: TODAY }];
    const words = [];
    for (let i = 0; i < 30; i++) {
      words.push({ english: 'cloud' + i, phonetic: '', meaning: 'n. 词' });
    }
    const out = importCloudBook(d, { name: 'CET6', cloudBookId: 'cet6', words }, NOW);
    check(out.settings.activeBookId !== 'B1' && out.settings.activeBookId.length > 0,
      'J5: 下载即切换背诵词本到新书');
    const newIds = out.words.filter((w) => w.bookId !== 'B1').map((w) => w.id);
    const newSched = out.schedules.filter((s) => newIds.indexOf(s.wordId) >= 0);
    check(newSched.length === 30 && newSched.every((s) => s.dueDay !== ''),
      'J5: 新书 30 词全部排期（默认 20/天：今天 20 + 明天 10）');
    check(out.schedules.find((s) => s.wordId === 'w1').dueDay === '', 'J5: 旧书未学新词被暂停');
  }

  // J6 setDailyNewCount：不回退今日已学、不删打卡、未来重排
  {
    const d = emptyData();
    d.books = [mkBook('B1', '书', 'CLOUD')];
    d.words = [mkWord('s1', 'B1'), mkWord('s2', 'B1')];
    d.settings.activeBookId = 'B1';
    d.schedules = [
      { ...newImportedSchedule('s1'), stage: 'R1', firstLearnDay: TODAY, dueDay: addDays(TODAY, 1) },
      { ...newImportedSchedule('s2'), dueDay: addDays(TODAY, 3) },
    ];
    d.checkins = [{
      day: TODAY, p1NewDone: true, p2ReviewDone: false, p3WrongDone: false,
      p3Required: false, checkedIn: true, makeup: false, streak: 3,
    }];
    const out = setDailyNewCount(d, 100, NOW);
    check(out.schedules[0].stage === 'R1' && out.schedules[0].firstLearnDay === TODAY,
      'J6: 今日已学的词不回退');
    check(out.checkins.length === 1 && out.checkins[0].checkedIn === true, 'J6: 当天打卡保留');
    check(out.settings.dailyNewCount === 100, 'J6: 设置更新为 100');
    check(out.schedules[1].dueDay === TODAY, 'J6: 未来新词按新额度重排（今天有空位先排今天）');
    const over = setDailyNewCount(d, 5000, NOW);
    check(over.settings.dailyNewCount === 1000, 'J6: 超上限夹取 1000');
  }
}


/* ================= K. 四路来源统一队列（梗句 / 拍照 / 词本 / 切书） ================= */
function testFourSources() {
  console.log('[K] 四路来源统一队列');
  const mkBook = (id, name, source) => ({ id, name, source, createdAt: NOW });
  const mkWord = (id, bookId, source) => ({
    id, bookId, english: id, phonetic: '', meanings: ['释义'], source: source ?? 'CLOUD',
    missingMeaning: false, diySupplement: false, createdAt: NOW,
  });
  const state = (schedules, dailyNewCount) => ({
    schedules,
    records: [],
    settings: { ...DEFAULT_SETTINGS, dailyNewCount },
  });

  // K1 昨天没学完的新词不撑爆今天的计划：20 逾期 + 20 今日到期 → 今日只放 20，顺延 20
  {
    const sched = [];
    for (let i = 0; i < 20; i++) {
      sched.push({ ...newImportedSchedule('a' + i), dueDay: addDays(TODAY, -1) });
      sched.push({ ...newImportedSchedule('b' + i), dueDay: TODAY });
    }
    const plan = buildDayPlan(state(sched, 20), TODAY);
    check(plan.newWords.length === 20, 'K1: 今日新词被额度截断为 20（不膨胀成 40）');
    check(plan.newDeferred === 20, 'K1: 剩余 20 个顺延到明天');
    check(plan.newWords[0] === 'a0' && plan.newWords[19] === 'a19',
      'K1: 逾期词优先（先补昨天欠的，今天新排的顺延）');
  }

  // K2 「加入当天计划」词插队且不占额度
  {
    const sched = [];
    for (let i = 0; i < 20; i++) {
      sched.push({ ...newImportedSchedule('x' + i), dueDay: TODAY });
    }
    sched.push({ ...newImportedSchedule('photo1'), dueDay: TODAY, intake: 'TODAY' });
    const plan = buildDayPlan(state(sched, 20), TODAY);
    check(plan.newWords.length === 21, 'K2: 今日插队词不占额度（20 + 1）');
    check(plan.newWords[0] === 'photo1', 'K2: 插队词排最前，进第一组就看得到');
    check(plan.newDeferred === 0, 'K2: 没有顺延');
  }

  // K3 今天已学掉的词消耗额度，不会重复发新词
  {
    const sched = [];
    for (let i = 0; i < 30; i++) {
      sched.push({ ...newImportedSchedule('r' + i), dueDay: TODAY });
    }
    const st = state(sched, 20);
    st.records = [];
    for (let i = 0; i < 5; i++) {
      st.records.push({ ...newStudyRecord('r' + i), firstPassedAt: NOW });
      st.schedules[i] = { ...st.schedules[i], stage: 'R1', firstLearnDay: TODAY, dueDay: addDays(TODAY, 1) };
    }
    const plan = buildDayPlan(st, TODAY);
    check(plan.newWords.length === 15, 'K3: 已学 5 个后今日只剩 15 个新词额度');
  }

  // K4 例外词本优先排期：主书几千词不会把拍照/梗句词挤到几个月后
  {
    const data = emptyData();
    data.books = [mkBook('MAIN', '四级', 'CLOUD'), mkBook('PHOTO', '拍照词本', 'DIY_PHOTO'),
      mkBook('MEME', '梗句词本', 'MEME')];
    data.settings.activeBookId = 'MAIN';
    data.settings.dailyNewCount = 10;
    const sched = [];
    const words = [];
    for (let i = 0; i < 300; i++) {
      words.push(mkWord('m' + i, 'MAIN'));
      sched.push(newImportedSchedule('m' + i));
    }
    for (let i = 0; i < 3; i++) {
      words.push(mkWord('p' + i, 'PHOTO', 'OCR'));
      sched.push(newImportedSchedule('p' + i));
      words.push(mkWord('g' + i, 'MEME', 'MEME'));
      sched.push(newImportedSchedule('g' + i));
    }
    data.words = words;
    data.schedules = sched;
    const planned = planNewWords(data.schedules, NOW, 10, activeScopeWordIds(data), exceptionWordIds(data));
    const out = { ...data, schedules: planned };
    const plan = buildDayPlan({ schedules: out.schedules, records: [], settings: out.settings }, TODAY);
    const todaySet = new Set(plan.newWords);
    const photoToday = ['p0', 'p1', 'p2', 'g0', 'g1', 'g2'].filter((id) => todaySet.has(id));
    check(photoToday.length === 6, 'K4: 拍照 + 梗句 6 个词全部排进今天，不被主书挤走');
    const mainToday = plan.newWords.filter((id) => id.startsWith('m')).length;
    check(mainToday === 4, 'K4: 主书只补剩余额度（4 个），总量仍是 10');
  }

  // K6 昨天欠的 20 个没学完：数据层不再给今天排 20 个，计划量稳定在 20
  {
    const sched = [];
    for (let i = 0; i < 20; i++) {
      sched.push({ ...newImportedSchedule('old' + i), dueDay: addDays(TODAY, -1) });
    }
    for (let i = 0; i < 20; i++) {
      sched.push(newImportedSchedule('new' + i));
    }
    const planned = planNewWords(sched, NOW, 20);
    // 今日占用 = 逾期（dueDay 早于今天）+ 今天到期，两者合计不得超额度
    const todayCount = planned.filter((s) => s.stage === 'NEW' && s.dueDay !== ''
      && diffDays(s.dueDay, TODAY) >= 0).length;
    const plan = buildDayPlan({ schedules: planned, records: [], settings: { ...DEFAULT_SETTINGS, dailyNewCount: 20 } }, TODAY);
    check(todayCount === 20, 'K6: 数据层今日占用仍是 20 个（逾期占满额度，不再追加）');
    check(plan.newWords.length === 20, 'K6: 视图层今日计划 20 个，与数据层一致');
    check(plan.newDeferred === 0, 'K6: 没有额外顺延（明天照常发下一批）');
  }

  // K7 插队词学完不扣额度：25 个计划（20 普通 + 5 插队），学掉 5 个插队后总数仍是 20
  {
    const sched = [];
    for (let i = 0; i < 20; i++) {
      sched.push({ ...newImportedSchedule('n' + i), dueDay: TODAY });
    }
    for (let i = 0; i < 5; i++) {
      sched.push({ ...newImportedSchedule('f' + i), dueDay: TODAY, intake: 'TODAY' });
    }
    const st = { schedules: sched, records: [], settings: { ...DEFAULT_SETTINGS, dailyNewCount: 20 } };
    const before = buildDayPlan(st, TODAY);
    check(before.newWords.length === 25, 'K7: 初始计划 25（20 普通 + 5 插队）');
    // 判掉 5 个插队词（认识 → R1）
    for (let i = 0; i < 5; i++) {
      st.records.push({ ...newStudyRecord('f' + i), firstPassedAt: NOW });
      const idx = st.schedules.findIndex((s) => s.wordId === 'f' + i);
      st.schedules[idx] = { ...st.schedules[idx], stage: 'R1', firstLearnDay: TODAY, dueDay: addDays(TODAY, 1) };
    }
    const after = buildDayPlan(st, TODAY);
    check(after.newWords.length === 20, 'K7: 学完插队词后计划仍是 20（不缩水成 15）');
  }

  // K5 切书：旧书未学暂停、新书恢复、例外词本不受影响
  {
    const data = emptyData();
    data.books = [mkBook('A', '四级', 'CLOUD'), mkBook('B', '高考', 'CLOUD'),
      mkBook('P', '拍照词本', 'DIY_PHOTO')];
    data.settings.activeBookId = 'A';
    data.settings.dailyNewCount = 10;
    data.words = [mkWord('a1', 'A'), mkWord('b1', 'B'), mkWord('p1', 'P', 'OCR')];
    data.schedules = [
      newImportedSchedule('a1'), newImportedSchedule('b1'), newImportedSchedule('p1'),
    ];
    const planned = planNewWords(data.schedules, NOW, 10, activeScopeWordIds(data), exceptionWordIds(data));
    const cur = { ...data, schedules: planned };
    const after = switchActiveBookData(cur, 'B', NOW);
    const byId = new Map(after.schedules.map((s) => [s.wordId, s]));
    check(byId.get('b1').dueDay === TODAY, 'K5: 切到高考后新书词立刻排进今天');
    check(byId.get('p1').dueDay === TODAY, 'K5: 拍照例外词本不受切书影响');
    check(after.settings.activeBookId === 'B', 'K5: 背诵中词本已切换');
  }
}
testFourSources();

/* ================= 汇总 ================= */
summary('词慧调度器测试');
