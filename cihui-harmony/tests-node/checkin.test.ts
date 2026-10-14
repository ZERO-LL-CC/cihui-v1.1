/**
 * F11 打卡前置 P3 排期信息（p3Info）与达标判定测试（Node 内置 test runner）。
 * 运行：node --import ./register.mjs --test checkin.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  addDays,
  dayKeyFromTs,
  defaultState,
  evaluateGates,
  isP3Required,
  p3Info,
  P3_INTERVAL_DAYS,
} from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import type { ReviewSchedule, SchedulerState } from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import { emptyData, importCloudBook } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type { AppData, CloudBookImport } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';

const NOW = new Date(2026, 8, 12, 10, 0, 0).getTime(); // 2026-09-12
const TODAY = dayKeyFromTs(NOW);

function tsOfDay(day: string): number {
  const parts = day.split('-').map((p) => Number(p));
  return new Date(parts[0], parts[1] - 1, parts[2], 10, 0, 0).getTime();
}

function stateWithWrong(verdictDay: string): { state: SchedulerState; schedule: ReviewSchedule } {
  const words = [{ english: 'w0', phonetic: '/w0/', meaning: '释义0' }];
  const draft: CloudBookImport = { name: '测试词书', cloudBookId: 't1', words };
  const data: AppData = importCloudBook(emptyData(), draft, NOW);
  const schedule = data.schedules[0];
  schedule.stage = 'NEW';
  schedule.status = 'WRONG';
  schedule.dueDay = TODAY;
  schedule.wrongReason = '不认识 · 转明天新词';
  schedule.lastVerdictAt = tsOfDay(verdictDay);
  const state = defaultState();
  state.schedules = data.schedules;
  state.records = data.records;
  state.settings = data.settings;
  return { state, schedule };
}

describe('F11 P3 错词强化排期', () => {
  test('无错词：不阻断，nextDay 为空串', () => {
    const state = defaultState();
    const info = p3Info(state, TODAY);
    assert.equal(info.required, false);
    assert.equal(info.nextDay, '');
    assert.equal(isP3Required(state, TODAY), false);
  });

  test('错词判定就在今天(gap=0)：不阻断，下次轮到 5 天后', () => {
    const { state } = stateWithWrong(TODAY);
    const info = p3Info(state, TODAY);
    assert.equal(info.required, false);
    assert.equal(info.nextDay, addDays(TODAY, P3_INTERVAL_DAYS));
    assert.equal(isP3Required(state, TODAY), false);
  });

  test(`错词判定距今恰好 ${P3_INTERVAL_DAYS} 天：轮到强化日，阻断`, () => {
    const anchor = addDays(TODAY, -P3_INTERVAL_DAYS);
    const { state } = stateWithWrong(anchor);
    const info = p3Info(state, TODAY);
    assert.equal(info.required, true);
    assert.equal(info.nextDay, TODAY);
    assert.equal(isP3Required(state, TODAY), true);
    // 有错词未清时 P3 门未达标
    const gates = evaluateGates(state, TODAY);
    assert.equal(gates.p3Required, true);
    assert.equal(gates.p3, false);
  });

  test('错词判定距今 7 天：非轮到日，下次轮到锚点后第 10 天', () => {
    const anchor = addDays(TODAY, -7);
    const { state } = stateWithWrong(anchor);
    const info = p3Info(state, TODAY);
    assert.equal(info.required, false);
    assert.equal(info.nextDay, addDays(anchor, 10));
    assert.equal(isP3Required(state, TODAY), false);
    // 非轮到日即使有错词也不阻断
    const gates = evaluateGates(state, TODAY);
    assert.equal(gates.p3Required, false);
    assert.equal(gates.p3, true);
  });
});
