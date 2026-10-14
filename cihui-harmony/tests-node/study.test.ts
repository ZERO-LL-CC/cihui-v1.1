/**
 * F7 新词首学边界测试（Node 内置 test runner）。
 * 运行：node --import ./register.mjs --test study.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  buildHomeStats,
  dayKeyFromTs,
  defaultState,
  judge,
  markFirstStudy,
  newImportedSchedule,
  newStudyRecord,
  planNewWords,
} from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import type { ReviewSchedule, SchedulerState, StudyRecord } from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';

const NOW = new Date(2026, 8, 12, 10, 0, 0).getTime(); // 2026-09-12 本地
const LATER = NOW + 3 * 60 * 60 * 1000;
const TODAY = dayKeyFromTs(NOW);

function stateWith(schedules: ReviewSchedule[], records: StudyRecord[]): SchedulerState {
  const base = defaultState();
  base.schedules = schedules;
  base.records = records;
  return base;
}

describe('F7 首学浏览与首过边界', () => {
  test('markFirstStudy 首次写入 firstStudyAt 与 lastStudyDay', () => {
    const rec = markFirstStudy(newStudyRecord('w1'), NOW);
    assert.equal(rec.firstStudyAt, NOW);
    assert.equal(rec.lastStudyDay, TODAY);
    assert.equal(rec.firstPassedAt, 0);
  });

  test('markFirstStudy 幂等：整批重复标记不覆盖首次时间', () => {
    const first = markFirstStudy(newStudyRecord('w1'), NOW);
    const second = markFirstStudy(first, LATER);
    assert.equal(second.firstStudyAt, NOW);
    assert.equal(second.lastStudyDay, TODAY);
  });

  test('只浏览（firstStudyAt）不算首过：P1 新词完成数仍为 0', () => {
    let schedules = planNewWords([newImportedSchedule('w1'), newImportedSchedule('w2')], NOW, 20);
    const records = [newStudyRecord('w1'), newStudyRecord('w2')];
    // 模拟 F7 整批浏览完：只写 firstStudyAt
    records[0] = markFirstStudy(records[0], NOW);
    records[1] = markFirstStudy(records[1], NOW);
    const stats = buildHomeStats(stateWith(schedules, records), TODAY);
    assert.equal(stats.newAssigned, 2);
    assert.equal(stats.newDone, 0);
    assert.equal(stats.allDone, false);
  });

  test('F8 首过判定后 firstPassedAt 才写入、新词完成数 +1', () => {
    let schedules = planNewWords([newImportedSchedule('w1')], NOW, 20);
    const records = [newStudyRecord('w1')];
    records[0] = markFirstStudy(records[0], NOW);
    const r = judge(schedules[0], records[0], 'FIRST', 'KNOWN', LATER);
    schedules[0] = r.schedule;
    records[0] = r.record;
    assert.ok(records[0].firstPassedAt > 0);
    const stats = buildHomeStats(stateWith(schedules, records), TODAY);
    assert.equal(stats.newDone, 1);
    assert.equal(stats.allDone, true);
  });
});
