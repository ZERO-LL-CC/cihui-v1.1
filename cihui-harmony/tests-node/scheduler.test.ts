/**
 * F2 调度器 + 内存仓库可运行测试（Node 内置 test runner，直接吃 ArkTS 工程里的 .ts 纯逻辑源码）。
 * 运行：node --import ./register.mjs --test scheduler.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  addDays,
  buildDayPlan,
  computeStreak,
  dayKeyFromTs,
  diffDays,
  evaluateGates,
  isP3Required,
  judge,
  markFirstStudy,
  newImportedSchedule,
  newStudyRecord,
  planNewWords,
} from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import { WRONG_REASON_UNKNOWN, WRONG_REASON_VAGUE } from '../Cihui/entry/src/main/ets/model/Types.ts';
import {
  addBook,
  addWord,
  applyJudgeToData,
  batchDeleteWords,
  cloneData,
  deleteBook,
  emptyData,
  importTransaction,
  upsertCheckin,
} from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type { AppData } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';

/** 固定时钟：2026-09-01 12:00 本地时间，避免测试受运行日影响 */
function ts(dayOffset: number, hour: number = 12): number {
  return new Date(2026, 8, 1 + dayOffset, hour, 0, 0).getTime();
}
const D0: string = '2026-09-01';

function seedOneWord(data: AppData, english: string = 'apple'): { data: AppData; wordId: string } {
  let d: AppData = addBook(data, { name: 'DIY 词本', source: 'DIY_PHOTO' }, ts(0));
  const bookId: string = d.books[0].id;
  d = addWord(d, {
    bookId,
    english,
    phonetic: '/ˈæpəl/',
    meanings: ['苹果'],
    source: 'MANUAL',
  }, ts(0));
  return { data: d, wordId: d.words[d.words.length - 1].id };
}

function judgeAt(data: AppData, wordId: string, phase: 'FIRST' | 'REVIEW',
  verdict: 'KNOWN' | 'VAGUE' | 'UNKNOWN', dayOffset: number): AppData {
  return applyJudgeToData(data, wordId, phase, verdict, ts(dayOffset)).data;
}

function scheduleOf(data: AppData, wordId: string) {
  return data.schedules.find((s) => s.wordId === wordId)!;
}

describe('日期工具', () => {
  test('日键 / 加减天 / 天数差', () => {
    assert.equal(dayKeyFromTs(ts(0)), D0);
    assert.equal(addDays(D0, 1), '2026-09-02');
    assert.equal(addDays(D0, -1), '2026-08-31');
    assert.equal(diffDays('2026-09-01', '2026-09-16'), 15);
  });
});

describe('F2 验收链路：首学 → R1 认识 → R2 模糊 → 次日强制 → 不认识清零 → 重新走到 R15 掌握', () => {
  test('完整链路到期日与状态全部符合规则', () => {
    let d: AppData = emptyData();
    const r = seedOneWord(d);
    d = r.data;
    const id: string = r.wordId;

    // 首学开始（F7 浏览写 firstStudyAt）
    d = {
      ...d,
      records: d.records.map((rec) => rec.wordId === id ? markFirstStudy(rec, ts(0)) : rec),
    };

    // D0 首测判认识 → 次日 R1
    d = judgeAt(d, id, 'FIRST', 'KNOWN', 0);
    let s = scheduleOf(d, id);
    assert.equal(s.stage, 'R1');
    assert.equal(s.status, 'LEARNING');
    assert.equal(s.dueDay, '2026-09-02');
    assert.ok(d.records.find((rec) => rec.wordId === id)!.firstPassedAt > 0);

    // D1 R1 认识 → R2（首学后第 2 天）
    d = judgeAt(d, id, 'REVIEW', 'KNOWN', 1);
    s = scheduleOf(d, id);
    assert.equal(s.stage, 'R2');
    assert.equal(s.dueDay, '2026-09-03');

    // D2 R2 模糊：停留 R2 + 本轮重考 + 强制次日复习 + 进错词本
    const vague = applyJudgeToData(d, id, 'REVIEW', 'VAGUE', ts(2));
    d = vague.data;
    assert.equal(vague.result.wrongAdded, true);
    assert.equal(vague.result.wrongReason, WRONG_REASON_VAGUE);
    s = scheduleOf(d, id);
    assert.equal(s.stage, 'R2');
    assert.equal(s.forceNextDay, true);
    assert.equal(s.roundRequeue, true);
    assert.equal(s.dueDay, '2026-09-04');

    // D3 次日强制复习判认识 → R4（首学+4 = 09-05，不早于明天 09-05）
    d = judgeAt(d, id, 'REVIEW', 'KNOWN', 3);
    s = scheduleOf(d, id);
    assert.equal(s.stage, 'R4');
    assert.equal(s.dueDay, '2026-09-05');
    assert.equal(s.forceNextDay, false);

    // D4 R4 不认识：节点清零，次日重新首学，写错词本
    const unk = applyJudgeToData(d, id, 'REVIEW', 'UNKNOWN', ts(4));
    d = unk.data;
    assert.equal(unk.result.wrongReason, WRONG_REASON_UNKNOWN);
    s = scheduleOf(d, id);
    assert.equal(s.stage, 'NEW');
    assert.equal(s.status, 'WRONG');
    assert.equal(s.dueDay, '2026-09-06');
    assert.equal(d.records.find((rec) => rec.wordId === id)!.firstStudyAt, 0);

    // D5 重新首学判认识 → R1（首学日重置为 09-06）
    d = judgeAt(d, id, 'FIRST', 'KNOWN', 5);
    s = scheduleOf(d, id);
    assert.equal(s.stage, 'R1');
    assert.equal(s.firstLearnDay, '2026-09-06');
    assert.equal(s.dueDay, '2026-09-07');
    assert.equal(s.status, 'LEARNING');

    // 逐节点推进到掌握
    d = judgeAt(d, id, 'REVIEW', 'KNOWN', 6); // R2 due 09-08
    assert.equal(scheduleOf(d, id).stage, 'R2');
    assert.equal(scheduleOf(d, id).dueDay, '2026-09-08');
    d = judgeAt(d, id, 'REVIEW', 'KNOWN', 7); // R4 due 09-10
    assert.equal(scheduleOf(d, id).stage, 'R4');
    assert.equal(scheduleOf(d, id).dueDay, '2026-09-10');
    d = judgeAt(d, id, 'REVIEW', 'KNOWN', 9); // R7 due 09-13
    assert.equal(scheduleOf(d, id).stage, 'R7');
    assert.equal(scheduleOf(d, id).dueDay, '2026-09-13');
    d = judgeAt(d, id, 'REVIEW', 'KNOWN', 12); // R15 due 09-21
    assert.equal(scheduleOf(d, id).stage, 'R15');
    assert.equal(scheduleOf(d, id).dueDay, '2026-09-21');
    d = judgeAt(d, id, 'REVIEW', 'KNOWN', 20); // 掌握，退出每日队列
    s = scheduleOf(d, id);
    assert.equal(s.stage, 'MASTERED');
    assert.equal(s.status, 'MASTERED');
    assert.equal(s.dueDay, '');

    // 掌握后不再出现在任何学习桶
    const plan = buildDayPlan({ schedules: d.schedules, records: d.records, settings: d.settings }, '2026-09-21');
    assert.equal(plan.newWords.length + plan.overdue.length + plan.wrongWords.length, 0);
  });
});

describe('当日学习桶与 P1/P2/P3 达标复算（幂等）', () => {
  test('新词未首过 P1=false；复习桶未清空 P2=false；重复复算结果不变', () => {
    let d: AppData = emptyData();
    d = addBook(d, { name: '测试本', source: 'DIY_MANUAL' }, ts(0));
    const bookId = d.books[0].id;
    d = importTransaction(d, [
      { bookId, english: 'one', meanings: ['一'], source: 'MANUAL' },
      { bookId, english: 'two', meanings: ['二'], source: 'MANUAL' },
    ], ts(0));
    const ids = d.words.map((w) => w.id);

    let g = evaluateGates({ schedules: d.schedules, records: d.records, settings: d.settings }, D0);
    assert.equal(g.p1, false, '新词未首过 P1 不达标');
    assert.equal(g.p2, true, '当天无到期复习 P2 达标');

    // 两个新词首过
    d = judgeAt(d, ids[0], 'FIRST', 'KNOWN', 0);
    d = judgeAt(d, ids[1], 'FIRST', 'KNOWN', 0);
    g = evaluateGates({ schedules: d.schedules, records: d.records, settings: d.settings }, D0);
    assert.equal(g.p1, true);
    assert.equal(g.p2, true);

    // 次日 R1 到期未过：P2=false，桶里有 2 个
    const planD1 = buildDayPlan({ schedules: d.schedules, records: d.records, settings: d.settings }, '2026-09-02');
    assert.equal(planD1.reviewBuckets['R1'].length, 2);
    g = evaluateGates({ schedules: d.schedules, records: d.records, settings: d.settings }, '2026-09-02');
    assert.equal(g.p2, false);

    d = judgeAt(d, ids[0], 'REVIEW', 'KNOWN', 1);
    d = judgeAt(d, ids[1], 'REVIEW', 'KNOWN', 1);
    g = evaluateGates({ schedules: d.schedules, records: d.records, settings: d.settings }, '2026-09-02');
    assert.equal(g.p2, true);

    // 幂等：同一状态重复复算完全一致
    const g2 = evaluateGates({ schedules: d.schedules, records: d.records, settings: d.settings }, '2026-09-02');
    assert.deepEqual(g2, g);
  });

  test('P3 错词强化每 5 天一次，未清零则不达标', () => {
    let d: AppData = emptyData();
    const r = seedOneWord(d, 'banana');
    d = r.data;
    d = judgeAt(d, r.wordId, 'FIRST', 'KNOWN', 0);
    d = judgeAt(d, r.wordId, 'REVIEW', 'UNKNOWN', 1); // 09-02 入错词本

    const state = { schedules: d.schedules, records: d.records, settings: d.settings };
    assert.equal(isP3Required(state, '2026-09-03'), false, '入本次日不安排');
    assert.equal(isP3Required(state, '2026-09-07'), true, '第 5 天轮到 P3');
    let g = evaluateGates(state, '2026-09-07');
    assert.equal(g.p3Required, true);
    assert.equal(g.p3, false, '错词未强化 P3 不达标');

    // 强化：重新首学通过 → 错词清零
    d = judgeAt(d, r.wordId, 'FIRST', 'KNOWN', 6);
    g = evaluateGates({ schedules: d.schedules, records: d.records, settings: d.settings }, '2026-09-07');
    assert.equal(g.p3, true);
  });
});

describe('打卡幂等与连续天数', () => {
  test('同一天重复打卡不重复计数；补卡不恢复连续天数', () => {
    let d: AppData = emptyData();
    const r = seedOneWord(d);
    d = r.data;
    d = judgeAt(d, r.wordId, 'FIRST', 'KNOWN', 0);

    d = upsertCheckin(d, D0, ts(0), false);
    let c = d.checkins.find((x) => x.day === D0)!;
    assert.equal(c.checkedIn, true);
    assert.equal(c.streak, 1);
    d = upsertCheckin(d, D0, ts(0), false); // 重复
    c = d.checkins.find((x) => x.day === D0)!;
    assert.equal(c.streak, 1, '重复计算不变');
    assert.equal(d.checkins.filter((x) => x.day === D0).length, 1);

    // 09-02 真实打卡 → 连续 2
    d = judgeAt(d, r.wordId, 'REVIEW', 'KNOWN', 1);
    d = upsertCheckin(d, '2026-09-02', ts(1), false);
    assert.equal(d.checkins.find((x) => x.day === '2026-09-02')!.streak, 2);

    // 09-03 缺卡，09-04 补卡：不恢复连续
    d = upsertCheckin(d, '2026-09-04', ts(3), true);
    const makeup = d.checkins.find((x) => x.day === '2026-09-04')!;
    assert.equal(makeup.makeup, true);
    assert.equal(computeStreak(d.checkins, '2026-09-04'), 0, '补卡不恢复连续');
  });

  test('前置未达标不能打卡', () => {
    let d: AppData = emptyData();
    const r = seedOneWord(d);
    d = r.data; // 新词未首过
    d = upsertCheckin(d, D0, ts(0), false);
    const c = d.checkins.find((x) => x.day === D0)!;
    assert.equal(c.checkedIn, false);
    assert.equal(c.p1NewDone, false);
  });
});

describe('新词排期', () => {
  test('超过每日新词量的词顺延到明天', () => {
    let d: AppData = emptyData();
    d = addBook(d, { name: '大批导入', source: 'CLOUD', cloudBookId: 'cet4' }, ts(0));
    const bookId = d.books[0].id;
    const drafts = [];
    for (let i = 0; i < 25; i++) {
      drafts.push({ bookId, english: 'w' + i, meanings: ['义' + i], source: 'CLOUD' as const });
    }
    d = importTransaction(d, drafts, ts(0)); // 默认每日 20
    const today = d.schedules.filter((s) => s.dueDay === D0).length;
    const tomorrow = d.schedules.filter((s) => s.dueDay === '2026-09-02').length;
    assert.equal(today, 20);
    assert.equal(tomorrow, 5);
  });
});

describe('内存仓库 CRUD 与事务', () => {
  test('词本/单词必填校验、级联删除、批量删除', () => {
    let d: AppData = emptyData();
    assert.throws(() => addBook(d, { name: '  ', source: 'DIY_MANUAL' }, ts(0)), /不能为空/);
    d = addBook(d, { name: '我的本', source: 'DIY_MANUAL' }, ts(0));
    assert.throws(() => addBook(d, { name: '我的本', source: 'DIY_MANUAL' }, ts(0)), /同名/);

    const bookId = d.books[0].id;
    assert.throws(() => addWord(d, { bookId, english: '', meanings: ['x'], source: 'MANUAL' }, ts(0)), /英文/);
    assert.throws(() => addWord(d, { bookId, english: 'cat', meanings: [], source: 'MANUAL' }, ts(0)), /中文释义/);

    // OCR 来源允许缺释义，必须打 missingMeaning
    d = addWord(d, { bookId, english: 'dog', meanings: [], source: 'OCR' }, ts(0));
    const w = d.words[0];
    assert.equal(w.missingMeaning, true);

    // 批量删除
    d = addWord(d, { bookId, english: 'cat', meanings: ['猫'], source: 'MANUAL' }, ts(0));
    d = batchDeleteWords(d, [w.id]);
    assert.equal(d.words.length, 1);
    assert.equal(d.schedules.filter((s) => s.wordId === w.id).length, 0);

    // 删词本级联
    d = deleteBook(d, bookId);
    assert.equal(d.words.length, 0);
    assert.equal(d.schedules.length, 0);
    assert.equal(d.records.length, 0);
  });

  test('导入事务失败不产生半截数据', () => {
    let d: AppData = emptyData();
    d = addBook(d, { name: '本', source: 'DIY_PHOTO' }, ts(0));
    const bookId = d.books[0].id;
    const before = cloneData(d);
    const drafts = [
      { bookId, english: 'good', meanings: ['好'], source: 'MANUAL' as const },
      { bookId, english: 'bad', meanings: [], source: 'MANUAL' as const }, // 手动录入缺释义 → 失败
    ];
    assert.throws(() => importTransaction(d, drafts, ts(0)));
    assert.deepEqual(d, before, '失败后数据与事务前完全一致');
  });
});

describe('杀进程恢复（快照模拟）', () => {
  test('判定后序列化 → 重建状态 → 调度与打卡复算一致', () => {
    let d: AppData = emptyData();
    const r = seedOneWord(d);
    d = r.data;
    d = judgeAt(d, r.wordId, 'FIRST', 'KNOWN', 0);
    d = judgeAt(d, r.wordId, 'REVIEW', 'KNOWN', 1);

    // 模拟杀进程：只剩 JSON 快照
    const snapshot: string = JSON.stringify(d);
    const restored: AppData = JSON.parse(snapshot) as AppData;

    assert.deepEqual(restored.schedules, d.schedules);
    assert.deepEqual(restored.records, d.records);
    const g1 = evaluateGates({ schedules: d.schedules, records: d.records, settings: d.settings }, '2026-09-02');
    const g2 = evaluateGates({ schedules: restored.schedules, records: restored.records, settings: restored.settings }, '2026-09-02');
    assert.deepEqual(g1, g2);

    // 恢复后继续学习链路不断
    const cont = judgeAt(restored, r.wordId, 'REVIEW', 'KNOWN', 2);
    assert.equal(cont.schedules.find((s) => s.wordId === r.wordId)!.stage, 'R4');
  });
});
