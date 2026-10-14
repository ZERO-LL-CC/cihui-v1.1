/**
 * F13 个人页统计（buildProfileStats）与 P3 严格度开关测试。
 * 运行：node --import ./register.mjs --test profile.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  addDays,
  buildProfileStats,
  dayKeyFromTs,
  defaultState,
  evaluateGates,
  isP3Required,
} from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import type { SchedulerState } from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import { emptyData, importCloudBook } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type { AppData, CloudBookImport } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type { CheckInRecord } from '../Cihui/entry/src/main/ets/model/Types.ts';

const NOW = new Date(2026, 8, 12, 10, 0, 0).getTime(); // 2026-09-12
const TODAY = dayKeyFromTs(NOW);

function normalCheckin(day: string, streak: number): CheckInRecord {
  return {
    day, p1NewDone: true, p2ReviewDone: true, p3WrongDone: true, p3Required: false,
    checkedIn: true, makeup: false, streak,
  };
}

function stateOf(data: AppData): SchedulerState {
  return { schedules: data.schedules, records: data.records, settings: data.settings };
}

describe('F13 buildProfileStats 六宫格统计', () => {
  test('空仓库：全部为 0，准时率 -1（页面显 –）', () => {
    const state = defaultState();
    const s = buildProfileStats(state, [], TODAY);
    assert.equal(s.totalImported, 0);
    assert.equal(s.learning, 0);
    assert.equal(s.mastered, 0);
    assert.equal(s.wrongCount, 0);
    assert.equal(s.streak, 0);
    assert.equal(s.onTimeRate, -1);
  });

  test('混合状态：学习中/已掌握/错词/连续/准时率口径正确', () => {
    const words = [
      { english: 'a0', phonetic: '/a0/', meaning: '义0' },
      { english: 'a1', phonetic: '/a1/', meaning: '义1' },
      { english: 'a2', phonetic: '/a2/', meaning: '义2' },
      { english: 'a3', phonetic: '/a3/', meaning: '义3' },
      { english: 'a4', phonetic: '/a4/', meaning: '义4' },
    ];
    const draft: CloudBookImport = { name: '统计测试书', cloudBookId: 'stat1', words };
    const data = emptyData();
    const imported = importCloudBook(data, draft, NOW);
    // 1 个已掌握、1 个错词、2 个复习中、1 个未学新词
    imported.schedules[0].stage = 'MASTERED';
    imported.schedules[0].status = 'MASTERED';
    imported.schedules[1].stage = 'R4';
    imported.schedules[2].stage = 'R1';
    imported.schedules[3].stage = 'NEW';
    imported.schedules[3].status = 'WRONG';
    imported.schedules[3].wrongReason = '不认识';
    imported.schedules[3].lastVerdictAt = NOW;
    // a4 保持 NEW/LEARNING 未学
    // 打卡：今天、昨天正常，前天缺卡，大前天是首次打卡 → 跨度 4 天，准时 3 天
    imported.checkins.push(normalCheckin(addDays(TODAY, -3), 1));
    imported.checkins.push(normalCheckin(addDays(TODAY, -1), 1));
    imported.checkins.push(normalCheckin(TODAY, 2));

    const s = buildProfileStats(stateOf(imported), imported.checkins, TODAY);
    assert.equal(s.totalImported, 5);
    assert.equal(s.learning, 2);
    assert.equal(s.mastered, 1);
    assert.equal(s.wrongCount, 1);
    assert.equal(s.streak, 2); // 今天 + 昨天
    assert.equal(s.onTimeRate, 75); // 3/4 = 75%
  });

  test('补卡不计入准时率分子，但占分母（缺卡就是缺卡）', () => {
    const draft: CloudBookImport = {
      name: '补卡统计书', cloudBookId: 'stat2',
      words: [{ english: 'b0', phonetic: '/b0/', meaning: '义0' }],
    };
    const data = importCloudBook(emptyData(), draft, NOW);
    data.checkins.push(normalCheckin(addDays(TODAY, -1), 1));
    const makeup: CheckInRecord = {
      day: TODAY, p1NewDone: true, p2ReviewDone: true, p3WrongDone: true, p3Required: false,
      checkedIn: true, makeup: true, streak: 0,
    };
    data.checkins.push(makeup);
    const s = buildProfileStats(stateOf(data), data.checkins, TODAY);
    assert.equal(s.streak, 0); // 今天是补卡，连续为 0
    assert.equal(s.onTimeRate, 50); // 跨度 2 天，正常打卡 1 天
  });
});

describe('F13 P3 打卡严格度开关', () => {
  test('默认严格：错词满 5 天轮到强化，阻断打卡', () => {
    const draft: CloudBookImport = {
      name: 'p3书', cloudBookId: 'p3a',
      words: [{ english: 'c0', phonetic: '/c0/', meaning: '义0' }],
    };
    const data = importCloudBook(emptyData(), draft, NOW);
    data.schedules[0].stage = 'NEW';
    data.schedules[0].status = 'WRONG';
    data.schedules[0].lastVerdictAt = new Date(2026, 8, 7, 10).getTime(); // 5 天前
    assert.equal(isP3Required(stateOf(data), TODAY), true);
    assert.equal(evaluateGates(stateOf(data), TODAY).p3Required, true);
  });

  test('关闭严格度：同一天不再轮到、不再阻断', () => {
    const draft: CloudBookImport = {
      name: 'p3书2', cloudBookId: 'p3b',
      words: [{ english: 'd0', phonetic: '/d0/', meaning: '义0' }],
    };
    const data = importCloudBook(emptyData(), draft, NOW);
    data.schedules[0].stage = 'NEW';
    data.schedules[0].status = 'WRONG';
    data.schedules[0].lastVerdictAt = new Date(2026, 8, 7, 10).getTime();
    data.settings.p3Strict = false;
    assert.equal(isP3Required(stateOf(data), TODAY), false);
    const gates = evaluateGates(stateOf(data), TODAY);
    assert.equal(gates.p3Required, false);
    assert.equal(gates.p3, true);
  });
});
