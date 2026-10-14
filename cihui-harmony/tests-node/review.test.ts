/**
 * F9 到期复习闪卡三档判定测试（Node 内置 test runner）。
 * 运行：node --import ./register.mjs --test review.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  addDays,
  buildDayPlan,
  buildHomeStats,
  dayKeyFromTs,
  defaultState,
  judge,
  newStudyRecord,
} from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import type { ReviewSchedule, SchedulerState, StudyRecord } from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';

const NOW = new Date(2026, 8, 12, 10, 0, 0).getTime(); // 2026-09-12
const TODAY = dayKeyFromTs(NOW);
const DAY_MS = 24 * 60 * 60 * 1000;

function reviewSchedule(wordId: string, stage: string, firstLearnDay: string, dueDay: string): ReviewSchedule {
  return {
    wordId,
    stage: stage as ReviewSchedule['stage'],
    firstLearnDay,
    dueDay,
    status: 'LEARNING',
    forceNextDay: false,
    roundRequeue: false,
    wrongReason: '',
    lastVerdictAt: 0,
  };
}

function pastRecord(wordId: string, firstLearnDay: string): StudyRecord {
  const rec = newStudyRecord(wordId);
  rec.firstStudyAt = NOW - 4 * DAY_MS;
  rec.firstPassedAt = rec.firstStudyAt;
  rec.lastStudyDay = firstLearnDay;
  return rec;
}

function stateWith(schedules: ReviewSchedule[], records: StudyRecord[]): SchedulerState {
  const base = defaultState();
  base.schedules = schedules;
  base.records = records;
  return base;
}

describe('F9 复习闪卡三档判定', () => {
  test('复习认识：R2 推进到 R4，到期日夹到明天，离开今日复习桶', () => {
    const fl = addDays(TODAY, -4);
    const s0 = reviewSchedule('w1', 'R2', fl, TODAY);
    const r0 = pastRecord('w1', fl);
    const r = judge(s0, r0, 'REVIEW', 'KNOWN', NOW);
    assert.equal(r.schedule.stage, 'R4');
    assert.equal(r.schedule.status, 'LEARNING');
    assert.equal(r.schedule.forceNextDay, false);
    assert.equal(r.schedule.dueDay, addDays(TODAY, 1));
    const plan = buildDayPlan(stateWith([r.schedule], [r.record]), TODAY);
    let inBucket = false;
    (['R1', 'R2', 'R4', 'R7', 'R15'] as string[]).forEach((k: string) => {
      if (plan.reviewBuckets[k].indexOf('w1') >= 0) {
        inBucket = true;
      }
    });
    assert.equal(inBucket, false);
    // P2 复习完成数同源 +1
    const stats = buildHomeStats(stateWith([r.schedule], [r.record]), TODAY);
    assert.equal(stats.reviewDone, 1);
    assert.equal(stats.reviewDue, 0);
  });

  test('模糊：停留节点、次日强制、本轮重考；随后判认识清除标记并推进', () => {
    const fl = addDays(TODAY, -2);
    const s0 = reviewSchedule('w2', 'R1', fl, TODAY);
    const r0 = pastRecord('w2', fl);
    const vague = judge(s0, r0, 'REVIEW', 'VAGUE', NOW);
    assert.equal(vague.schedule.stage, 'R1'); // 停留节点
    assert.equal(vague.schedule.forceNextDay, true);
    assert.equal(vague.schedule.roundRequeue, true);
    assert.equal(vague.schedule.dueDay, addDays(TODAY, 1));
    assert.ok(vague.schedule.wrongReason.length > 0);
    // 模糊卡本轮重考后判认识：清除强制/重队列/原因，推进 R2
    const known = judge(vague.schedule, vague.record, 'REVIEW', 'KNOWN', NOW + 60000);
    assert.equal(known.schedule.stage, 'R2');
    assert.equal(known.schedule.forceNextDay, false);
    assert.equal(known.schedule.roundRequeue, false);
    assert.equal(known.schedule.wrongReason, '');
    const stats = buildHomeStats(stateWith([known.schedule], [known.record]), TODAY);
    assert.equal(stats.reviewDone, 1);
  });

  test('不认识：清零回 NEW、状态 WRONG、次日到期、进入错词本', () => {
    const fl = addDays(TODAY, -7);
    const s0 = reviewSchedule('w3', 'R7', fl, TODAY);
    const r0 = pastRecord('w3', fl);
    const r = judge(s0, r0, 'REVIEW', 'UNKNOWN', NOW);
    assert.equal(r.schedule.stage, 'NEW');
    assert.equal(r.schedule.status, 'WRONG');
    assert.equal(r.schedule.firstLearnDay, '');
    assert.equal(r.schedule.dueDay, addDays(TODAY, 1));
    assert.equal(r.wrongAdded, true);
    const plan = buildDayPlan(stateWith([r.schedule], [r.record]), TODAY);
    assert.ok(plan.wrongWords.indexOf('w3') >= 0);
  });

  test('R15 仍认识：掌握毕业，退出每日队列', () => {
    const fl = addDays(TODAY, -15);
    const s0 = reviewSchedule('w4', 'R15', fl, TODAY);
    const r0 = pastRecord('w4', fl);
    const r = judge(s0, r0, 'REVIEW', 'KNOWN', NOW);
    assert.equal(r.schedule.stage, 'MASTERED');
    assert.equal(r.schedule.status, 'MASTERED');
    const plan = buildDayPlan(stateWith([r.schedule], [r.record]), TODAY);
    assert.equal(plan.overdue.indexOf('w4') < 0, true);
  });

  test('F10 错词强化：WRONG 词在复习轮判认识按重新首过推进到 R1', () => {
    const s0: ReviewSchedule = {
      wordId: 'w5',
      stage: 'NEW',
      firstLearnDay: '',
      dueDay: TODAY,
      status: 'WRONG',
      forceNextDay: false,
      roundRequeue: false,
      wrongReason: '不认识 · 转明天新词',
      lastVerdictAt: 0,
    };
    const r0 = newStudyRecord('w5');
    const r = judge(s0, r0, 'REVIEW', 'KNOWN', NOW);
    assert.equal(r.schedule.stage, 'R1');
    assert.equal(r.schedule.status, 'LEARNING');
    assert.equal(r.schedule.forceNextDay, false);
    assert.ok(r.record.firstPassedAt > 0);
    const plan = buildDayPlan(stateWith([r.schedule], [r.record]), TODAY);
    assert.equal(plan.wrongWords.indexOf('w5') < 0, true);
  });
});
