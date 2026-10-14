/**
 * F13 我的 Profile：
 * - 未登录：顶部虚线「未登录」卡片，统计六宫格显 –，点卡跳登录（F14 落地前 Toast 诚实占位）；
 *   已登录：头像字、昵称、「云备份已开启」徽标（F15 接通状态）；
 * - 六宫格：累计导入 / 学习中 / 已掌握 / 错词 / 连续天数 / 准时率，进入页面数字滚动增长，
 *   口径全部来自 SchedulerCore.buildProfileStats，与首页、打卡页同源；
 * - 设置组：词本管理（F5）、每日新词量（F12 滚轮）、短时复习开关、P3 严格度开关、
 *   TTS 语速、ASR 严格度（ActionSheet 选择）、触感反馈、学习提醒（F16）；
 *   行内开关 120ms 即时生效并经 DataStore 持久化；
 * - 账号与云备份（F14/F15）、隐私与关于入口。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { AuthStore } from '../../viewmodel/AuthStore';
import { SyncStore } from '../../viewmodel/SyncStore';
import { ReminderService } from '../../service/ReminderService';
import { Colors, TypeScale, Radius } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
import type { AsrStrictness } from '../../model/Types';
import type { ProfileStats } from '../../model/SchedulerCore';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

class StatCell {
  key: string;
  label: string;
  value: string;
  suffix: string;

  constructor(key: string, label: string, value: string, suffix: string = '') {
    this.key = key;
    this.label = label;
    this.value = value;
    this.suffix = suffix;
  }
}

@ComponentV2
export struct ProfilePage {
  @Require @Param active: boolean;
  /** 导航版本号：登录/注册/资料编辑/设置变更返回后刷新登录态与统计（动态QA BUG-03/04） */
  @Param tick: number = 0;
  @Local enterOpacity: number = 0;
  @Local enterTy: number = 8;
  // 数字滚动动画的当前显示值
  @Local showTotal: number = 0;
  @Local showLearning: number = 0;
  @Local showMastered: number = 0;
  @Local showWrong: number = 0;
  @Local showStreak: number = 0;
  @Local showRate: number = 0;
  /** 动态QA：显式刷新版本号，登录/资料/设置变更返回后强制重绘账号卡与设置行（BUG-03/04） */
  @Local viewTick: number = 0;
  private timerId: number = -1;
  private refreshWhenActive: RefreshListener = (): void => {
    if (this.active) {
      this.viewTick++;
      this.startCountUp();
    }
  };

  @Monitor('active')
  onActiveChange(): void {
    if (this.active) {
      this.playEnter();
      this.viewTick++;
      this.startCountUp();
    } else {
      this.clearTimer();
    }
  }

  /** 二级页返回（登录、资料编辑、设置调整）：页面可见时重算统计数字 */
  @Monitor('tick')
  onTickChange(): void {
    if (this.active) {
      this.viewTick++;
      this.startCountUp();
    }
  }

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenActive);
    REFRESH_BUS.onData(this.refreshWhenActive);
    if (this.active) {
      this.playEnter();
      this.startCountUp();
    }
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenActive);
    REFRESH_BUS.offData(this.refreshWhenActive);
    this.clearTimer();
  }

  private playEnter(): void {
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut, delay: 20 }, () => {
      this.enterOpacity = 1;
      this.enterTy = 0;
    });
  }

  private clearTimer(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /** 数字滚动：约 600ms 分 12 帧逼近目标 */
  private startCountUp(): void {
    this.clearTimer();
    const logged: boolean = AuthStore.INSTANCE.isLoggedIn();
    if (!logged) {
      this.showTotal = 0;
      this.showLearning = 0;
      this.showMastered = 0;
      this.showWrong = 0;
      this.showStreak = 0;
      this.showRate = 0;
      return;
    }
    const s: ProfileStats = DataStore.INSTANCE.profileStats();
    const frames: number = 12;
    let tick: number = 0;
    const ease = (t: number): number => 1 - Math.pow(1 - t, 3);
    this.timerId = setInterval(() => {
      tick += 1;
      const t: number = ease(Math.min(1, tick / frames));
      this.showTotal = Math.round(s.totalImported * t);
      this.showLearning = Math.round(s.learning * t);
      this.showMastered = Math.round(s.mastered * t);
      this.showWrong = Math.round(s.wrongCount * t);
      this.showStreak = Math.round(s.streak * t);
      this.showRate = s.onTimeRate < 0 ? 0 : Math.round(s.onTimeRate * t);
      if (tick >= frames) {
        this.clearTimer();
      }
    }, 50);
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 1800 });
    } catch (_e) {
    }
  }

  private pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  private reminderSubtitle(): string {
    const s = DataStore.INSTANCE.settings;
    return `每天 ${this.pad2(s.reminderHour)}:${this.pad2(s.reminderMinute)} 提醒今日新词、复习与打卡（每天 1 条）`;
  }

  private async onReminderToggle(on: boolean): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    if (!on) {
      const r = await ReminderService.INSTANCE.disableDailyReminder();
      DataStore.INSTANCE.updateSettings({ reminderEnabled: false });
      this.toast(r.message);
      return;
    }
    const s = DataStore.INSTANCE.settings;
    const r = await ReminderService.INSTANCE.enableDailyReminder(ctx, s.reminderHour, s.reminderMinute);
    if (r.ok) {
      DataStore.INSTANCE.updateSettings({ reminderEnabled: true });
      this.toast(r.message);
      return;
    }
    if (r.kind === 'denied') {
      // 拒绝授权不崩溃：弹窗引导去系统通知设置，开关保持关闭
      try {
        promptAction.showDialog({
          title: '通知权限未开启',
          message: '需要在系统通知设置中允许词慧发送通知，才能收到每日复习提醒。',
          buttons: [
            { text: '取消', color: Colors.TEXT_SUB },
            { text: '去设置', color: Colors.BRAND },
          ],
        }, (err: Error, result: promptAction.ShowDialogSuccessResponse) => {
          if (!err && result.index === 1) {
            ReminderService.INSTANCE.openSettings(ctx);
          }
        });
      } catch (_e) {
        this.toast(r.message);
      }
      return;
    }
    this.toast(r.message);
  }

  private asrLabel(): string {
    const v: AsrStrictness = DataStore.INSTANCE.settings.asrStrictness;
    if (v === 'LOW') {
      return '宽松';
    }
    if (v === 'HIGH') {
      return '严格';
    }
    return '标准';
  }

  private ttsLabel(): string {
    const r: number = DataStore.INSTANCE.settings.ttsRate;
    if (r <= 0.85) {
      return '0.8x 慢速';
    }
    if (r >= 1.1) {
      return '1.2x 快速';
    }
    return '1.0x 常速';
  }

  private chooseTtsRate(): void {
    try {
      promptAction.showActionMenu({
        title: '英文朗读语速',
        buttons: [
          { text: '0.8x 慢速', color: Colors.TEXT_MAIN },
          { text: '1.0x 常速', color: Colors.TEXT_MAIN },
          { text: '1.2x 快速', color: Colors.TEXT_MAIN },
        ],
      }, (err: Error, result: promptAction.ActionMenuSuccessResponse) => {
        if (err) {
          return;
        }
        const rates: number[] = [0.8, 1.0, 1.2];
        if (result.index >= 0 && result.index < rates.length) {
          DataStore.INSTANCE.updateSettings({ ttsRate: rates[result.index] });
          this.toast('朗读语速已更新');
        }
      });
    } catch (_e) {
      this.toast('当前设备不支持操作菜单');
    }
  }

  private chooseAsrStrictness(): void {
    try {
      promptAction.showActionMenu({
        title: '语音识别严格度',
        buttons: [
          { text: '宽松（说个大概也算过）', color: Colors.TEXT_MAIN },
          { text: '标准（推荐）', color: Colors.BRAND },
          { text: '严格（必须完整命中）', color: Colors.TEXT_MAIN },
        ],
      }, (err: Error, result: promptAction.ActionMenuSuccessResponse) => {
        if (err) {
          return;
        }
        const levels: AsrStrictness[] = ['LOW', 'MID', 'HIGH'];
        if (result.index >= 0 && result.index < levels.length) {
          DataStore.INSTANCE.updateSettings({ asrStrictness: levels[result.index] });
          this.toast('识别严格度已更新');
        }
      });
    } catch (_e) {
      this.toast('当前设备不支持操作菜单');
    }
  }

  private statCells(): StatCell[] {
    const s: ProfileStats = DataStore.INSTANCE.profileStats();
    return [
      new StatCell('total', '累计导入', `${this.showTotal}`),
      new StatCell('learning', '学习中', `${this.showLearning}`),
      new StatCell('mastered', '已掌握', `${this.showMastered}`),
      new StatCell('wrong', '错词', `${this.showWrong}`),
      new StatCell('streak', '连续天数', `${this.showStreak}`),
      // 动态QA BUG-08：已登录但尚无打卡记录时准时率无口径，显 – 而不是 0%
      new StatCell('rate', '准时率', s.onTimeRate < 0 ? '–' : `${this.showRate}`, s.onTimeRate < 0 ? '' : '%'),
    ];
  }

  @Builder
  AccountCard() {
    if (AuthStore.INSTANCE.profile === null) {
      // 未登录：虚线卡
      Row({ space: 14 }) {
        Stack() {
          Image($r('app.media.ic_profile')).width(26).height(26).fillColor(Colors.TEXT_WEAK)
        }
        .width(56).height(56).borderRadius(28)
        .border({ width: 1.5, color: Colors.TEXT_WEAK, style: BorderStyle.Dashed })

        Column() {
          Text('未登录')
            .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
          Text('点击登录或注册，开启云备份')
            .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB).margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)

        Text('›').fontSize(22).fontColor(Colors.TEXT_WEAK)
      }
      .width('100%').padding(18)
      .borderRadius(Radius.CARD)
      .backgroundColor(Colors.WHITE)
      .border({ width: 1.5, color: Colors.BRAND, style: BorderStyle.Dashed })
      .onClick(() => NavStore.INSTANCE.push(RouteName.LOGIN))
    } else {
      Row({ space: 14 }) {
        Stack() {
          Text(AuthStore.INSTANCE.profile.avatarText)
            .fontSize(22).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
        }
        .width(56).height(56).borderRadius(28).backgroundColor(Colors.BRAND)

        Column() {
          Text(AuthStore.INSTANCE.profile.name)
            .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
          Row({ space: 6 }) {
            if (SyncStore.INSTANCE.status === 'syncing') {
              Text('云备份同步中…')
                .fontSize(11).fontColor(Colors.BRAND)
                .backgroundColor(Colors.BRAND_SOFT).borderRadius(8)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            } else if (SyncStore.INSTANCE.status === 'failed') {
              Text('云备份同步失败')
                .fontSize(11).fontColor(Colors.UNKNOWN_RED)
                .backgroundColor(Colors.UNKNOWN_RED_SOFT).borderRadius(8)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            } else if (AuthStore.INSTANCE.profile.cloudEnabled) {
              Text('云备份已开启')
                .fontSize(11).fontColor(Colors.KNOW_GREEN)
                .backgroundColor(Colors.KNOW_GREEN_SOFT).borderRadius(8)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            } else {
              Text('云备份未开启')
                .fontSize(11).fontColor(Colors.TEXT_SUB)
                .backgroundColor(Colors.PAGE_BG).borderRadius(8)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            }
          }
          .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)

        Text('›').fontSize(22).fontColor(Colors.TEXT_WEAK)
      }
      .width('100%').padding(18)
      .borderRadius(Radius.CARD)
      .backgroundColor(Colors.WHITE)
      .onClick(() => NavStore.INSTANCE.push(RouteName.ACCOUNT))
    }
  }

  @Builder
  StatGrid() {
    Column() {
      Text('学习统计').fontSize(15).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .width('100%').margin({ bottom: 12 })
      Grid() {
        ForEach(this.statCells(), (cell: StatCell) => {
          GridItem() {
            Column() {
              if (AuthStore.INSTANCE.profile === null) {
                Text('–').fontSize(22).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_WEAK)
              } else {
                Text(`${cell.value}${cell.suffix}`)
                  .fontSize(22).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
              }
              Text(cell.label).fontSize(12).fontColor(Colors.TEXT_SUB).margin({ top: 4 })
            }
            .width('100%').padding({ top: 12, bottom: 12 })
            .justifyContent(FlexAlign.Center)
          }
        }, (cell: StatCell) => cell.key + '_' + cell.value + '_' + (AuthStore.INSTANCE.profile === null ? '0' : '1'))
      }
      .columnsTemplate('1fr 1fr 1fr')
      .rowsTemplate('1fr 1fr')
      .columnsGap(8)
      .rowsGap(8)
      .height(168)
      .width('100%')
    }
    .width('100%').padding(16).borderRadius(Radius.CARD).backgroundColor(Colors.WHITE)
  }

  @Builder
  NavRow(label: string, value: string, action: () => void) {
    Row() {
      Text(label).fontSize(15).fontColor(Colors.TEXT_MAIN).layoutWeight(1)
      if (value !== '') {
        Text(value).fontSize(13).fontColor(Colors.TEXT_WEAK).margin({ right: 4 })
      }
      Text('›').fontSize(20).fontColor(Colors.TEXT_WEAK)
    }
    .width('100%').height(50)
    .onClick(action)
  }

  @Builder
  ToggleRow(label: string, subtitle: string, isOn: boolean, onChange: (v: boolean) => void) {
    Row() {
      Column() {
        Text(label).fontSize(15).fontColor(Colors.TEXT_MAIN)
        if (subtitle !== '') {
          Text(subtitle).fontSize(11).fontColor(Colors.TEXT_WEAK).margin({ top: 3 })
        }
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn })
        .selectedColor(Colors.BRAND)
        .width(46).height(26)
        .onChange((v: boolean) => onChange(v))
    }
    .width('100%').constraintSize({ minHeight: 50 }).padding({ top: 6, bottom: 6 })
  }

  @Builder
  GroupCard(title: string) {
    Column() {
      Text(title).fontSize(12).fontColor(Colors.TEXT_WEAK).width('100%').margin({ bottom: 4, left: 2 })
    }
    .width('100%').margin({ top: 18 })
  }

  build() {
    Column() {
      Text('我的')
        .fontSize(TypeScale.TITLE_LARGE).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .width('100%').margin({ bottom: 14 })

      Scroll() {
        Column() {
          this.AccountCard()
          Column().height(14)
          this.StatGrid()

          this.GroupCard('学习设置')
          Column() {
            this.NavRow('词本管理', '', () => NavStore.INSTANCE.push(RouteName.MY_BOOKS))
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.NavRow('我的梗卡册', '', () => NavStore.INSTANCE.push(RouteName.MEME_ALBUM))
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.NavRow('我的例句本', '', () => NavStore.INSTANCE.push(RouteName.SENTENCE_FAVORITES))
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.NavRow('每日新词量', `${DataStore.INSTANCE.settings.dailyNewCount} 个/天`,
              () => NavStore.INSTANCE.push(RouteName.DAILY_NEW))
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.ToggleRow('当天短时复习', '学完后 5 分钟 / 30 分钟 / 12 小时快速巩固，默认关',
              DataStore.INSTANCE.settings.shortReviewEnabled,
              (v: boolean) => {
                DataStore.INSTANCE.updateSettings({ shortReviewEnabled: v });
                this.toast(v ? '短时复习已开启（5/30 分钟短时提醒为二期能力）' : '短时复习已关闭');
              })
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.ToggleRow('打卡严格度 · P3 错词强化', '关闭后错词强化日不再阻断打卡，默认开',
              DataStore.INSTANCE.settings.p3Strict,
              (v: boolean) => {
                DataStore.INSTANCE.updateSettings({ p3Strict: v });
                this.toast(v ? 'P3 严格模式已开启' : 'P3 严格模式已关闭');
              })
          }
          .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .borderRadius(Radius.CARD).backgroundColor(Colors.WHITE)

          this.GroupCard('语音与反馈')
          Column() {
            this.NavRow('英文朗读语速', this.ttsLabel(), () => this.chooseTtsRate())
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.NavRow('语音识别严格度', this.asrLabel(), () => this.chooseAsrStrictness())
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.ToggleRow('触感反馈', '按钮、过词与打卡时的震动反馈',
              DataStore.INSTANCE.settings.hapticEnabled,
              (v: boolean) => DataStore.INSTANCE.updateSettings({ hapticEnabled: v }))
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.ToggleRow('学习提醒', this.reminderSubtitle(),
              DataStore.INSTANCE.settings.reminderEnabled,
              (v: boolean) => {
                this.onReminderToggle(v);
              })
          }
          .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .borderRadius(Radius.CARD).backgroundColor(Colors.WHITE)

          this.GroupCard('账号')
          Column() {
            this.NavRow('账号与云备份', '', () => {
              if (AuthStore.INSTANCE.isLoggedIn()) {
                NavStore.INSTANCE.push(RouteName.ACCOUNT);
              } else {
                NavStore.INSTANCE.push(RouteName.LOGIN);
              }
            })
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.NavRow('隐私与关于', '', () => this.toast('隐私政策与关于页将在后续版本提供'))
          }
          .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .borderRadius(Radius.CARD).backgroundColor(Colors.WHITE)

          Column().height(110)
        }
        .width('100%')
      }
      .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
    }
    .width('100%').height('100%')
    .padding({ left: 20, right: 20, top: 24 })
    .alignItems(HorizontalAlign.Start)
    .opacity(this.enterOpacity + (this.tick + this.viewTick) * 0)
    .translate({ y: this.enterTy })
  }
}
