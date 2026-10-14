/**
 * F16 提醒时间策略纯逻辑测试（Node 内置 test runner）。
 * 运行：node --import ./register.mjs --test reminder.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  DEFAULT_REMINDER_HOUR,
  DEFAULT_REMINDER_MINUTE,
  EVERY_DAY,
  nextReminderDateTime,
} from '../Cihui/entry/src/main/ets/model/ReminderCore.ts';

describe('F16 每日提醒时间策略', () => {
  test('默认时间为 20:00，且每天重复（周一到周日 1–7）', () => {
    assert.equal(DEFAULT_REMINDER_HOUR, 20);
    assert.equal(DEFAULT_REMINDER_MINUTE, 0);
    assert.deepEqual(EVERY_DAY, [1, 2, 3, 4, 5, 6, 7]);
  });

  test('当天时刻未到：排在今天', () => {
    // 2026-09-12（周六）10:00，提醒 20:00 → 当天
    const now = new Date(2026, 8, 12, 10, 0, 0);
    const t = nextReminderDateTime(now, 20, 0);
    assert.deepEqual(t, { year: 2026, month: 9, day: 12, hour: 20, minute: 0, second: 0 });
  });

  test('当天时刻已过：排在明天', () => {
    // 2026-09-12 21:00，提醒 20:00 → 次日 09-13
    const now = new Date(2026, 8, 12, 21, 0, 0);
    const t = nextReminderDateTime(now, 20, 0);
    assert.equal(t.day, 13);
    assert.equal(t.hour, 20);
  });

  test('恰好等于提醒时刻：排到明天，避免开启瞬间立刻响', () => {
    const now = new Date(2026, 8, 12, 20, 0, 0);
    const t = nextReminderDateTime(now, 20, 0);
    assert.equal(t.day, 13);
  });

  test('跨月正确：9 月 30 日晚间 → 10 月 1 日', () => {
    const now = new Date(2026, 8, 30, 22, 30, 0);
    const t = nextReminderDateTime(now, 8, 0);
    assert.deepEqual({ month: t.month, day: t.day, hour: t.hour }, { month: 10, day: 1, hour: 8 });
  });
});
