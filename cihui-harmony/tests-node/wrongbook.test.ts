/**
 * F10 错词本派生口径 / 移出恢复 / 强化后重新入轨测试（Node 内置 test runner）。
 * 运行：node --import ./register.mjs --test wrongbook.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  addDays,
  buildDayPlan,
  buildHomeStats,
  buildWrongEntries,
  dayKeyFromTs,
  defaultState,
} from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import type { ReviewSchedule, SchedulerState } from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import { emptyData, importCloudBook, removeWrongFromData } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type { AppData, CloudBookImport } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';

const NOW = new Date(2026, 8, 12, 10, 0, 0).getTime(); // 2026-09-12
const TODAY = dayKeyFromTs(NOW);
const TOMORROW = addDays(TODAY, 1);

function seedData(): AppData {
  const words = [];
  for (let i = 0; i < 3; i++) {
    words.push({ english: `word${i}`, phonetic: `/w${i}/`, meaning: `释义${i}` });
  }
  const draft: CloudBookImport = { name: '测试词书', cloudBookId: 't1', words };
  return importCloudBook(emptyData(), draft, NOW);
}

function scheduleOf(data: AppData, english: string): ReviewSchedule {
  const word = data.words.find((w) => w.english === english);
  assert.ok(word);
  const s = data.schedules.find((x) => x.wordId === word!.id);
  assert.ok(s);
  return s!;
}

function stateOf(data: AppData): SchedulerState {
  const base = defaultState();
  base.schedules = data.schedules;
  base.records = data.records;
  base.settings = data.settings;
  return base;
}

describe('F10 错词本', () => {
  test('不认识(WRONG)与模糊(forceNextDay)两类词派生进错词本，按到期日升序', () => {
    const data = seedData();
    const sUnknown = scheduleOf(data, 'word0');
    sUnknown.stage = 'NEW';
    sUnknown.status = 'WRONG';
    sUnknown.dueDay = TOMORROW;
    sUnknown.wrongReason = '不认识 · 转明天新词';
    const sVague = scheduleOf(data, 'word1');
    sVague.stage = 'R1';
    sVague.status = 'LEARNING';
    sVague.forceNextDay = true;
    sVague.roundRequeue = true;
    sVague.dueDay = TODAY;
    sVague.wrongReason = '模糊 · 次日强制复习';

    const entries = buildWrongEntries(stateOf(data));
    assert.equal(entries.length, 2);
    // 今天到期的模糊词排在明天到期的不认识词之前
    assert.equal(entries[0].kind, 'VAGUE');
    assert.equal(entries[0].reason, '模糊 · 次日强制复习');
    assert.equal(entries[1].kind, 'UNKNOWN');
    assert.equal(entries[1].reason, '不认识 · 转明天新词');
    // 首页角标同源
    assert.equal(buildHomeStats(stateOf(data), TODAY).wrongCount, 2);
  });

  test('移出不认识词：恢复 LEARNING，次日按正常新词出现，离开错词本', () => {
    const data = seedData();
    const sUnknown = scheduleOf(data, 'word0');
    sUnknown.stage = 'NEW';
    sUnknown.status = 'WRONG';
    sUnknown.dueDay = TOMORROW;
    sUnknown.wrongReason = '不认识 · 转明天新词';

    const moved = removeWrongFromData(data, sUnknown.wordId);
    const after = moved.schedules.find((x) => x.wordId === sUnknown.wordId)!;
    assert.equal(after.status, 'LEARNING');
    assert.equal(after.stage, 'NEW');
    assert.equal(after.forceNextDay, false);
    assert.equal(after.roundRequeue, false);
    assert.equal(after.wrongReason, '');
    assert.equal(after.dueDay, TOMORROW); // 到期日保留，明天进新词桶
    const planTomorrow = buildDayPlan(stateOf(moved), TOMORROW);
    assert.ok(planTomorrow.newWords.indexOf(after.wordId) >= 0);
    assert.equal(buildWrongEntries(stateOf(moved)).length, 0);
  });

  test('移出模糊词：清除强制/重队列/原因，次日按普通复习出现', () => {
    const data = seedData();
    const sVague = scheduleOf(data, 'word1');
    sVague.stage = 'R1';
    sVague.status = 'LEARNING';
    sVague.forceNextDay = true;
    sVague.roundRequeue = true;
    sVague.dueDay = TOMORROW;
    sVague.wrongReason = '模糊 · 次日强制复习';

    const moved = removeWrongFromData(data, sVague.wordId);
    const after = moved.schedules.find((x) => x.wordId === sVague.wordId)!;
    assert.equal(after.status, 'LEARNING');
    assert.equal(after.stage, 'R1');
    assert.equal(after.forceNextDay, false);
    assert.equal(after.roundRequeue, false);
    assert.equal(after.wrongReason, '');
    const planTomorrow = buildDayPlan(stateOf(moved), TOMORROW);
    assert.ok(planTomorrow.reviewBuckets['R1'].indexOf(after.wordId) >= 0);
    assert.equal(buildWrongEntries(stateOf(moved)).length, 0);
  });

  test('无错词时派生列表为空，首页角标为 0', () => {
    const data = seedData();
    assert.equal(buildWrongEntries(stateOf(data)).length, 0);
    assert.equal(buildHomeStats(stateOf(data), TODAY).wrongCount, 0);
  });
});
