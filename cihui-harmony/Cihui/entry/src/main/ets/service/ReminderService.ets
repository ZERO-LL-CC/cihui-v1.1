/**
 * F16 学习提醒：本地通知 + 每日定时提醒（reminderAgentManager 系统代理，App 不在后台也能响）。
 *
 * 能力边界（对齐 F16 卡）：
 * - 首次开启引导通知授权（requestEnableNotification）；拒绝后引导去系统通知设置，不崩溃；
 * - 每天仅 1 条汇总提醒（默认 20:00，常量占位待用户确认），点击直达打卡页；
 * - 开关与时间读个人页设置（settings.reminderEnabled / reminderHour / reminderMinute）；
 * - 「云端提醒」随云存储方案（Q8）二期接入，本文件底部预留 CloudReminderPort 接口与 TODO；
 * - 到期词数动态文案需要后台任务/云端推送，本期不做，文案为固定汇总口径。
 *
 * 权限：ohos.permission.PUBLISH_AGENT_REMINDER（system_grant normal，已在 module.json5 声明）。
 */
import notificationManager from '@ohos.notificationManager';
import reminderAgentManager from '@ohos.reminderAgentManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { common } from '@kit.AbilityKit';
import type Want from '@ohos.app.ability.Want';
import {
  EVERY_DAY,
  nextReminderDateTime,
  REMINDER_CONTENT,
  REMINDER_TEST_CONTENT,
  REMINDER_TEST_TITLE,
  REMINDER_TITLE,
} from '../model/ReminderCore';
import type { ReminderDateTime } from '../model/ReminderCore';

export interface ReminderOutcome {
  ok: boolean;
  /** denied=授权被拒（可引导去设置）；failed=其它失败；cancelled=已关闭 */
  kind: string;
  message: string;
}

/** 云端提醒预留接口（F16-cloud，随 Q8 云存储方案实现，本期不接入） */
export interface CloudReminderPort {
  /** 云端按账号下发每日提醒（含动态到期词数） */
  syncDailyReminder(enabled: boolean, hour: number, minute: number): Promise<boolean>;
}

const BUNDLE_NAME: string = 'com.cihui.word';
const ABILITY_NAME: string = 'EntryAbility';
/** 通知/提醒 Want 参数键，EntryAbility 读取后决定落地页 */
export const LAUNCH_TARGET_KEY: string = 'cihui.target';
export const TARGET_CHECKIN: string = 'checkin';
const DAILY_REMINDER_ID: number = 1001;
const TEST_NOTIFICATION_ID: number = 1002;

function outcome(ok: boolean, kind: string, message: string): ReminderOutcome {
  return { ok, kind, message };
}

export class ReminderService {
  static readonly INSTANCE: ReminderService = new ReminderService();
  // TODO(F16-cloud)：云端提醒通道实现 CloudReminderPort 后在此注入，本地提醒作为兜底
  private cloudPort: CloudReminderPort | null = null;

  private constructor() {
  }

  /** 请求通知授权；已授权直接通过，被拒返回 denied（错误码 1600004 等统一归并） */
  async requestEnable(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      await notificationManager.requestEnableNotification(ctx);
      return true;
    } catch (_e) {
      return false;
    }
  }

  /** 跳系统通知设置（拒绝授权后的引导路径） */
  async openSettings(ctx: common.UIAbilityContext): Promise<void> {
    try {
      await notificationManager.openNotificationSettings(ctx);
    } catch (_e) {
    }
  }

  /**
   * 开启每日提醒：先请求授权 → 取消旧提醒 → 注册按天重复的日历提醒 → 发一条测试通知。
   */
  async enableDailyReminder(ctx: common.UIAbilityContext, hour: number, minute: number): Promise<ReminderOutcome> {
    const granted: boolean = await this.requestEnable(ctx);
    if (!granted) {
      return outcome(false, 'denied', '通知权限未开启，可在引导中前往系统设置打开');
    }
    try {
      // 先清理同 ID 旧提醒（不存在时取消会抛错，忽略）
      try {
        await reminderAgentManager.cancelReminder(DAILY_REMINDER_ID);
      } catch (_cancelErr) {
      }
      const when: ReminderDateTime = nextReminderDateTime(new Date(), hour, minute);
      const req: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: {
          year: when.year,
          month: when.month,
          day: when.day,
          hour: when.hour,
          minute: when.minute,
          second: 0,
        },
        daysOfWeek: EVERY_DAY,
        title: REMINDER_TITLE,
        content: REMINDER_CONTENT,
        notificationId: DAILY_REMINDER_ID,
        wantAgent: {
          pkgName: BUNDLE_NAME,
          abilityName: ABILITY_NAME,
          parameters: this.targetParams(TARGET_CHECKIN),
        },
      };
      await reminderAgentManager.publishReminder(req);
      // 授权后立即发一条测试通知，满足「授权后可发出测试通知、点击正确跳转」
      await this.publishTestNotification(ctx);
      return outcome(true, 'enabled', `已开启，每天 ${pad(hour)}:${pad(minute)} 提醒`);
    } catch (e) {
      return outcome(false, 'failed', `提醒开启失败：${(e as Error)?.message ?? '未知错误'}`);
    }
  }

  /** 关闭每日提醒 */
  async disableDailyReminder(): Promise<ReminderOutcome> {
    try {
      await reminderAgentManager.cancelReminder(DAILY_REMINDER_ID);
    } catch (_e) {
      // 没有已注册提醒时取消会报错，视为已关闭
    }
    return outcome(true, 'cancelled', '已关闭学习提醒');
  }

  /** 立即发一条测试通知，点击直达打卡页 */
  async publishTestNotification(ctx: common.UIAbilityContext): Promise<void> {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: ABILITY_NAME,
      parameters: this.targetParams(TARGET_CHECKIN),
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: TEST_NOTIFICATION_ID,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    const agent: object = await wantAgent.getWantAgent(info);
    const req: notificationManager.NotificationRequest = {
      id: TEST_NOTIFICATION_ID,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: REMINDER_TEST_TITLE, text: REMINDER_TEST_CONTENT },
      },
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      wantAgent: agent,
    };
    await notificationManager.publish(req);
  }

  private targetParams(target: string): Record<string, Object> {
    const params: Record<string, Object> = {};
    params[LAUNCH_TARGET_KEY] = target;
    return params;
  }
}

function pad(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}
