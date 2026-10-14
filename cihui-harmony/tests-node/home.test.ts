/**
 * F6 首页今日任务统计测试（Node 内置 test runner）。
 * 运行：node --import ./register.mjs --test home.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  addDays,
  buildHomeStats,
  dayKeyFromTs,
  defaultState,
  judge,
  newImportedSchedule,
  newStudyRecord,
  planNewWords,
} from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import type { ReviewSchedule, SchedulerState, StudyRecord } from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';

const NOW = new Date(2026, 8, 12, 10, 0, 0).getTime(); // 2026-09-12 本地
const TODAY = dayKeyFromTs(NOW);

function stateWith(schedules: ReviewSchedule[], records: StudyRecord[]): SchedulerState {
  const base = defaultState();
  base.schedules = schedules;
  base.records = records;
  return base;
}

describe('buildHomeStats 首页同源统计', () => {
  test('空仓库：无单词、进度 0、引导导入', () => {
    const s = buildHomeStats(defaultState(), TODAY);
    assert.equal(s.hasWords, false);
    assert.equal(s.allDone, false);
    assert.equal(s.progress, 0);
    assert.equal(s.dueTotal, 0);
    assert.equal(s.bucketCounts['NEW'], 0);
  });

  test('两个新词排入今天：新词任务 2、完成 0', () => {
    let schedules = [newImportedSchedule('w1'), newImportedSchedule('w2')];
    schedules = planNewWords(schedules, NOW, 20);
    const records = [newStudyRecord('w1'), newStudyRecord('w2')];
    const s = buildHomeStats(stateWith(schedules, records), TODAY);
    assert.equal(s.hasWords, true);
    assert.equal(s.newAssigned, 2);
    assert.equal(s.newDone, 0);
    assert.equal(s.bucketCounts['NEW'], 2);
    assert.equal(s.dueTotal, 2);
    assert.equal(s.remaining, 2);
    assert.equal(s.allDone, false);
  });

  test('首过 1 个：进度 50%，已过词仍计入今日新词任务', () => {
    let schedules = planNewWords([newImportedSchedule('w1'), newImportedSchedule('w2')], NOW, 20);
    const records = [newStudyRecord('w1'), newStudyRecord('w2')];
    const r1 = judge(schedules[0], records[0], 'FIRST', 'KNOWN', NOW);
    schedules[0] = r1.schedule;
    records[0] = r1.record;
    const s = buildHomeStats(stateWith(schedules, records), TODAY);
    assert.equal(s.newAssigned, 2);
    assert.equal(s.newDone, 1);
    assert.equal(s.bucketCounts['NEW'], 1);
    assert.equal(s.doneTotal, 1);
    assert.equal(Math.round(s.progress * 100), 50);
    assert.equal(s.allDone, false);
  });

  test('两个新词都首过：新词任务全部完成', () => {
    let schedules = planNewWords([newImportedSchedule('w1'), newImportedSchedule('w2')], NOW, 20);
    const records = [newStudyRecord('w1'), newStudyRecord('w2')];
    for (let i = 0; i < 2; i++) {
      const r = judge(schedules[i], records[i], 'FIRST', 'KNOWN', NOW);
      schedules[i] = r.schedule;
      records[i] = r.record;
    }
    const s = buildHomeStats(stateWith(schedules, records), TODAY);
    assert.equal(s.newDone, 2);
    assert.equal(s.reviewDue, 0);
    assert.equal(s.allDone, true);
    assert.equal(s.progress, 1);
  });

  test('到期复习判认识：计入今日已完成复习', () => {
    const sch: ReviewSchedule = {
      ...newImportedSchedule('r1'),
      stage: 'R1',
      firstLearnDay: addDays(TODAY, -1),
      dueDay: TODAY,
      status: 'LEARNING',
    };
    const rec = newStudyRecord('r1');
    const r = judge(sch, rec, 'REVIEW', 'KNOWN', NOW);
    const s = buildHomeStats(stateWith([r.schedule], [r.record]), TODAY);
    assert.equal(s.reviewDue, 0);
    assert.equal(s.reviewDone, 1);
    assert.equal(s.dueTotal, 1);
    assert.equal(s.doneTotal, 1);
    assert.equal(s.allDone, true);
  });

  test('判模糊（强制次日复习）不计为今日完成', () => {
    const sch: ReviewSchedule = {
      ...newImportedSchedule('v1'),
      stage: 'R1',
      firstLearnDay: addDays(TODAY, -1),
      dueDay: TODAY,
      status: 'LEARNING',
    };
    const rec = newStudyRecord('v1');
    const r = judge(sch, rec, 'REVIEW', 'VAGUE', NOW);
    const s = buildHomeStats(stateWith([r.schedule], [r.record]), TODAY);
    assert.equal(s.reviewDone, 0);
  });

  test('WRONG 状态词进入错词本计数', () => {
    const sch: ReviewSchedule = { ...newImportedSchedule('x1'), status: 'WRONG', dueDay: addDays(TODAY, 1) };
    const s = buildHomeStats(stateWith([sch], [newStudyRecord('x1')]), TODAY);
    assert.equal(s.wrongCount, 1);
  });
});
