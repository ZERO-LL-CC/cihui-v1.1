/**
 * F12 计划大表 / 补卡严格顺序 / 每日新词量重排测试（Node 内置 test runner）。
 * 运行：node --import ./register.mjs --test plan.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  addDays,
  buildDayPlan,
  buildMonthGrid,
  dayKeyFromTs,
  newImportedSchedule,
  newStudyRecord,
  planNewWords,
  previewDailyNew,
} from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import type { MonthCell, ReviewSchedule, SchedulerState } from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import {
  applyDailyNewCount,
  buildMakeupGroups,
  canMakeup,
  completeMakeup,
  emptyData,
} from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type { AppData } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type { CheckInRecord, StudyRecord } from '../Cihui/entry/src/main/ets/model/Types.ts';

const NOW = new Date(2026, 8, 12, 10, 0, 0).getTime(); // 2026-09-12
const TODAY = dayKeyFromTs(NOW);
const Y = 2026;
const M = 9;

function reviewSchedule(wordId: string, stage: string, firstLearnDay: string, dueDay: string,
  status: string = 'LEARNING'): ReviewSchedule {
  return {
    wordId,
    stage: stage as ReviewSchedule['stage'],
    firstLearnDay,
    dueDay,
    status: status as ReviewSchedule['status'],
    forceNextDay: false,
    roundRequeue: false,
    wrongReason: '',
    lastVerdictAt: 0,
  };
}

function newWord(wordId: string, dueDay: string): ReviewSchedule {
  const s = newImportedSchedule(wordId);
  s.dueDay = dueDay;
  return s;
}

function normalCheckin(day: string, streak: number): CheckInRecord {
  return {
    day, p1NewDone: true, p2ReviewDone: true, p3WrongDone: true, p3Required: false,
    checkedIn: true, makeup: false, streak,
  };
}

function stateOf(data: AppData): SchedulerState {
  return { schedules: data.schedules, records: data.records, settings: data.settings };
}

function findCell(gridCells: MonthCell[], day: string): MonthCell {
  const c = gridCells.find((x) => x.day === day);
  assert.ok(c, `月历中应存在 ${day}`);
  return c as MonthCell;
}

describe('F12 计划大表 buildMonthGrid', () => {
  test('橙块/彩点/红格/今天/未来 状态正确，待补卡统计正确', () => {
    const data = emptyData();
    // w1：D-4 首学，当前 R4 到期日正好是今天（理想节点 R1=D-3 R2=D-2 R4=今天）
    data.schedules.push(reviewSchedule('w1', 'R4', addDays(TODAY, -4), TODAY));
    data.records.push(newStudyRecord('w1'));
    // w2：D-3 就该学的新词，一直没学（逾期）
    data.schedules.push(newWord('w2', addDays(TODAY, -3)));
    data.records.push(newStudyRecord('w2'));
    // 只有 D-4 正常打卡，D-3 起全缺
    data.checkins.push(normalCheckin(addDays(TODAY, -4), 1));

    const grid = buildMonthGrid(stateOf(data), data.checkins, Y, M, TODAY);

    const cStart = findCell(grid.cells, addDays(TODAY, -4));
    assert.equal(cStart.state, 'done');
    assert.equal(cStart.newCount, 1);

    const cMiss = findCell(grid.cells, addDays(TODAY, -3));
    assert.equal(cMiss.state, 'missed');
    assert.equal(cMiss.newCount, 1); // 逾期新词占橙块
    // w1 的 R1 彩点落在 D-3
    const r1 = cMiss.dots.find((d) => d.stage === 'R1');
    assert.ok(r1);
    assert.equal(r1?.count, 1);

    const cToday = findCell(grid.cells, TODAY);
    assert.equal(cToday.state, 'today');
    const r4 = cToday.dots.find((d) => d.stage === 'R4');
    assert.ok(r4, '今天应有 R4 复习彩点');

    const cFuture = findCell(grid.cells, addDays(TODAY, 1));
    assert.equal(cFuture.state, 'future');

    // D-3、D-2、D-1 三个缺卡日
    assert.equal(grid.pendingMakeup, 3);
    assert.equal(grid.firstActive, addDays(TODAY, -4));
    assert.equal(grid.streak, 0); // 今天没打卡，连续为 0
  });
});

describe('F12 补卡严格顺序 canMakeup / completeMakeup', () => {
  function scenario(): AppData {
    const data = emptyData();
    // w2：D-3 到期未学新词（D-1 补卡时属 NEW 欠账）
    data.schedules.push(newWord('w2', addDays(TODAY, -3)));
    data.records.push(newStudyRecord('w2'));
    // w3：D-2 首学，R1 节点 = D-1，停留在 R1（D-1 欠一次 R1 复习）
    data.schedules.push(reviewSchedule('w3', 'R1', addDays(TODAY, -2), addDays(TODAY, -1)));
    data.records.push(newStudyRecord('w3'));
    // 今天已正常打卡；D-1、D-2 缺卡
    data.checkins.push(normalCheckin(TODAY, 1));
    return data;
  }

  test('今天没打卡不能补；有更近缺卡日时必须由近及远；未来/今天拒绝', () => {
    const d0 = emptyData();
    d0.schedules.push(newWord('w2', addDays(TODAY, -3)));
    d0.records.push(newStudyRecord('w2'));
    const noToday = canMakeup(d0, addDays(TODAY, -1), NOW);
    assert.equal(noToday.ok, false);
    assert.match(noToday.reason, /今天/);

    const data = scenario();
    const far = canMakeup(data, addDays(TODAY, -2), NOW);
    assert.equal(far.ok, false);
    assert.match(far.reason, /更近/);

    const today = canMakeup(data, TODAY, NOW);
    assert.equal(today.ok, false);
    const future = canMakeup(data, addDays(TODAY, 1), NOW);
    assert.equal(future.ok, false);

    const near = canMakeup(data, addDays(TODAY, -1), NOW);
    assert.equal(near.ok, true);
    const groups = buildMakeupGroups(data, addDays(TODAY, -1));
    const stages = groups.map((g) => g.stage).sort();
    assert.deepEqual(stages, ['NEW', 'R1']);
  });

  test('补卡完成：欠词全部判认识推进调度，写入 makeup 打卡；红格变 made；连续不恢复', () => {
    const data = scenario();
    const day = addDays(TODAY, -1);
    const done = completeMakeup(data, day, NOW);

    const rec = done.checkins.find((c) => c.day === day);
    assert.ok(rec);
    assert.equal(rec?.checkedIn, true);
    assert.equal(rec?.makeup, true);

    // w2 新词首过推进到 R1；w3 R1 认识推进到 R2
    const w2 = done.schedules.find((s) => s.wordId === 'w2');
    const w3 = done.schedules.find((s) => s.wordId === 'w3');
    assert.equal(w2?.stage, 'R1');
    assert.equal(w3?.stage, 'R2');

    const grid = buildMonthGrid(stateOf(done), done.checkins, Y, M, TODAY);
    const c = findCell(grid.cells, day);
    assert.equal(c.state, 'made');
    // D-2 仍是红格，待补卡从 2（D-2、D-1）变 1（D-2）
    assert.equal(grid.pendingMakeup, 1);
    // 补卡不恢复连续：今天正常打卡只有 1 天连续（昨天是补卡不计）
    assert.equal(grid.streak, 1);

    // 幂等：重复补卡不报错、不重复
    const again = completeMakeup(done, day, NOW);
    assert.equal(again.checkins.filter((c) => c.day === day).length, 1);
  });
});

describe('F12 每日新词量 applyDailyNewCount / previewDailyNew', () => {
  function scenario(): AppData {
    const data = emptyData();
    // 2 个逾期新词
    data.schedules.push(newWord('o1', addDays(TODAY, -2)));
    data.schedules.push(newWord('o2', addDays(TODAY, -1)));
    data.records.push(newStudyRecord('o1'));
    data.records.push(newStudyRecord('o2'));
    // 1 个今天刚学（已到 R1），调整后应回退为新词重排
    const learned = reviewSchedule('t1', 'R1', TODAY, addDays(TODAY, 1));
    const t1Rec: StudyRecord = newStudyRecord('t1');
    t1Rec.firstStudyAt = NOW - 3600_000;
    t1Rec.firstPassedAt = NOW - 3000_000;
    t1Rec.lastStudyDay = TODAY;
    data.schedules.push(learned);
    data.records.push(t1Rec);
    // 20 个未排期新词
    for (let i = 0; i < 20; i++) {
      const id = `f${i}`;
      data.schedules.push(newWord(id, ''));
      data.records.push(newStudyRecord(id));
    }
    // 1 个历史老词（D-10 首学，R15），不得被篡改
    data.schedules.push(reviewSchedule('h1', 'R15', addDays(TODAY, -10), addDays(TODAY, 5)));
    data.records.push(newStudyRecord('h1'));
    // 今天已打卡（调整后必须删除，要求重新完成）
    data.checkins.push(normalCheckin(TODAY, 3));
    data.settings.dailyNewCount = 20;
    return data;
  }

  test('确定后：今天打卡删除、今天学过的词回退、逾期优先占额度、未来按新额度重排、历史不动', () => {
    const data = scenario();
    const next = applyDailyNewCount(data, 10, NOW);

    assert.equal(next.settings.dailyNewCount, 10);
    assert.equal(next.checkins.some((c) => c.day === TODAY), false);

    const dueCount = (day: string): number =>
      next.schedules.filter((s) => s.stage === 'NEW' && s.dueDay === day).length;
    // 2 个逾期 + 8 个新词 = 10；明天 10；后天剩 3（回退词 t1 + 20 新词 = 21 个空池）
    assert.equal(dueCount(TODAY), 10);
    assert.equal(dueCount(addDays(TODAY, 1)), 10);
    assert.equal(dueCount(addDays(TODAY, 2)), 3);

    const t1 = next.schedules.find((s) => s.wordId === 't1');
    assert.equal(t1?.stage, 'NEW');
    assert.equal(t1?.firstLearnDay, '');

    const h1 = next.schedules.find((s) => s.wordId === 'h1');
    assert.equal(h1?.stage, 'R15');
    assert.equal(h1?.firstLearnDay, addDays(TODAY, -10));

    const t1Rec = next.records.find((r) => r.wordId === 't1');
    assert.equal(t1Rec?.firstPassedAt, 0);
  });

  test('滚轮预览不落数据：额度夹取、新学按额度、耗时为非负整数', () => {
    const data = scenario();
    const p = previewDailyNew(stateOf(data), 10, NOW);
    assert.equal(p.dailyNew, 10);
    assert.equal(p.newCount, 10);
    assert.ok(p.total >= 10);
    assert.ok(Number.isInteger(p.minutes) && p.minutes >= 0);
    // 预览不修改原数据
    assert.equal(data.settings.dailyNewCount, 20);
    // 超范围夹取到 5–40
    assert.equal(previewDailyNew(stateOf(data), 999, NOW).dailyNew, 40);
    assert.equal(previewDailyNew(stateOf(data), 1, NOW).dailyNew, 5);
  });

  test('P6 回归：预览必须镜像确定后的结果（今日已学词回退计入），库存不足诚实标注', () => {
    // 用户实测：当天已学 11 个、共 23 个新词，滚轮调到 40 时预览只显示 12（漏回退今日已学）
    const data = scenario();
    // 额度 40：2 逾期 + t1 回退 + 20 未排期 = 23，全部排今天，库存不足
    const p40 = previewDailyNew(stateOf(data), 40, NOW);
    assert.equal(p40.newCount, 23);
    assert.equal(p40.insufficient, true);
    assert.equal(p40.unlearned, 0);
    // 与 applyDailyNewCount 确定后的当日桶完全一致
    const applied = applyDailyNewCount(data, 40, NOW);
    const dayPlan = buildDayPlan(stateOf(applied), TODAY);
    assert.equal(p40.newCount, dayPlan.newWords.length);

    // 额度 10：今天 10（2 逾期 + 8 新词），剩余 13 排未来，库存充足不标不足
    const data2 = scenario();
    const p10 = previewDailyNew(stateOf(data2), 10, NOW);
    assert.equal(p10.newCount, 10);
    assert.equal(p10.unlearned, 13);
    assert.equal(p10.insufficient, false);
  });

  test('回归：导入整本词书（新词已按额度排到未来），预览/确定后今天只占额度，未来词不被拉回今天', () => {
    const data = emptyData();
    data.settings.dailyNewCount = 25;
    const N = 3846;
    for (let i = 0; i < N; i++) {
      const id = 'b' + i;
      data.schedules.push(newImportedSchedule(id));
      data.records.push(newStudyRecord(id));
    }
    // 模拟 RepoCore.importTransaction：导入后立即按每日额度分摊
    data.schedules = planNewWords(data.schedules, NOW, 25);
    assert.equal(
      data.schedules.filter((s) => s.stage === 'NEW' && s.dueDay === TODAY).length,
      25,
    );

    // 滚轮停在 25：今天新学必须是 25，而不是全书 3846；其余排未来
    const p25 = previewDailyNew(stateOf(data), 25, NOW);
    assert.equal(p25.newCount, 25);
    assert.equal(p25.unlearned, N - 25);
    assert.equal(p25.insufficient, false);

    // 滚轮调到 40：今天只补到 40（从未来拉回 15 个），未来保留 N-40
    const p40 = previewDailyNew(stateOf(data), 40, NOW);
    assert.equal(p40.newCount, 40);
    assert.equal(p40.unlearned, N - 40);

    // 确定 25：今天 25、明天 25，当日桶与预览一致
    const applied = applyDailyNewCount(data, 25, NOW);
    const due = (d: string): number =>
      applied.schedules.filter((s) => s.stage === 'NEW' && s.dueDay === d).length;
    assert.equal(due(TODAY), 25);
    assert.equal(due(addDays(TODAY, 1)), 25);
    assert.equal(buildDayPlan(stateOf(applied), TODAY).newWords.length, 25);
  });
});
