/**
 * F16 学习提醒纯逻辑：每日提醒触发时间策略（可 Node 单测）。
 *
 * 策略建议（待用户确认，不擅自增加多条骚扰提醒）：
 * - 每天仅 1 条汇总提醒，默认 20:00（DEFAULT_REMINDER_HOUR/MINUTE 常量占位）；
 * - 当天该时刻已过则排到明天；开启后由系统 reminderAgentManager 按天重复，
 *   App 不在后台轮询、不连发。
 */

export const DEFAULT_REMINDER_HOUR: number = 20;
export const DEFAULT_REMINDER_MINUTE: number = 0;
/** reminderAgentManager 的 daysOfWeek：1=周一 … 7=周日；每天重复即 1–7 */
export const EVERY_DAY: number[] = [1, 2, 3, 4, 5, 6, 7];

/** 与 reminderAgentManager.LocalDateTime 同构（纯数据，便于测试） */
export interface ReminderDateTime {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
}

/**
 * 计算从 now 起下一次提醒的本地日期时间。
 * 当天 hour:minute 尚未到达（含相等时刻留给次日，避免开启瞬间立刻响）排今天，否则排明天。
 */
export function nextReminderDateTime(now: Date, hour: number, minute: number): ReminderDateTime {
  const target: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate(), hour, minute, 0, 0);
  if (target.getTime() <= now.getTime()) {
    target.setDate(target.getDate() + 1);
  }
  return {
    year: target.getFullYear(),
    month: target.getMonth() + 1,
    day: target.getDate(),
    hour: target.getHours(),
    minute: target.getMinutes(),
    second: 0,
  };
}

/** 提醒文案（固定汇总口径；到期词数依赖后台任务才能在触发时刻动态计算，本期不做） */
export const REMINDER_TITLE: string = '该背单词啦';
export const REMINDER_CONTENT: string = '今天的新词与到期复习还没完成，打开词慧学完再打卡';
export const REMINDER_TEST_TITLE: string = '词慧提醒已开启';
export const REMINDER_TEST_CONTENT: string = '这是一条测试通知，点击可直达今日打卡页';
