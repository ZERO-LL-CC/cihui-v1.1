/**
 * F13 我的 Profile（无登录版）：
 * - 六宫格：累计导入 / 学习中 / 已掌握 / 错词 / 连续天数 / 准时率，进入页面数字滚动增长，
 *   口径全部来自 SchedulerCore.buildProfileStats，与首页、打卡页同源；
 * - 设置组：词本管理、我的梗卡册、我的例句本；
 * - 隐私与关于入口（承担 Tatoeba 例句库 CC BY 2.0 署名义务）。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { LocalFileSyncService } from '../../service/LocalFileSyncService';
import { Colors, TypeScale, Radius } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
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
  /** 导航版本号：设置变更返回后刷新统计 */
  @Param tick: number = 0;
  @Local enterOpacity: number = 0;
  @Local enterTy: number = 8;
  /** 数据导入/备份进行中防重入 */
  @Local dataBusy: boolean = false;
  // 数字滚动动画的当前显示值
  @Local showTotal: number = 0;
  @Local showLearning: number = 0;
  @Local showMastered: number = 0;
  @Local showWrong: number = 0;
  @Local showStreak: number = 0;
  @Local showRate: number = 0;
  /** 显式刷新版本号 */
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

  private context(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /** 备份数据：把词本、学习进度、打卡记录与设置写入本机备份区 */
  private async doBackup(): Promise<void> {
    if (this.dataBusy) {
      return;
    }
    this.dataBusy = true;
    const r = await LocalFileSyncService.INSTANCE.backupNow(this.context(), false);
    this.dataBusy = false;
    this.toast(r.message);
  }

  /** 导入数据：选择备份文件，按时间戳合并恢复；恢复前自动留存本机副本 */
  private async doImport(): Promise<void> {
    if (this.dataBusy) {
      return;
    }
    this.dataBusy = true;
    const r = await LocalFileSyncService.INSTANCE.importFromFile(this.context());
    this.dataBusy = false;
    this.toast(r.message);
  }

  /** 清除数据：确认后清空本机全部词本、学习进度与打卡记录 */
  private confirmWipe(): void {
    try {
      promptAction.showDialog({
        title: '清除数据',
        message: '将清空本机全部词本、学习进度与打卡记录，且不可恢复。确定继续？',
        buttons: [
          { text: '取消', color: Colors.TEXT_SUB },
          { text: '清空', color: Colors.UNKNOWN_RED },
        ],
      }, (err: Error, result: promptAction.ShowDialogSuccessResponse) => {
        if (!err && result.index === 1) {
          const r = LocalFileSyncService.INSTANCE.simulateWipe();
          this.toast(r.message);
        }
      });
    } catch (_e) {
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
      new StatCell('rate', '准时率', s.onTimeRate < 0 ? '–' : `${this.showRate}`, s.onTimeRate < 0 ? '' : '%'),
    ];
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
              Text(`${cell.value}${cell.suffix}`)
                .fontSize(22).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
              Text(cell.label).fontSize(12).fontColor(Colors.TEXT_SUB).margin({ top: 4 })
            }
            .width('100%').padding({ top: 12, bottom: 12 })
            .justifyContent(FlexAlign.Center)
          }
        }, (cell: StatCell) => cell.key + '_' + cell.value)
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
          this.StatGrid()

          this.GroupCard('学习设置')
          Column() {
            this.NavRow('词本管理', '', () => NavStore.INSTANCE.push(RouteName.MY_BOOKS))
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.NavRow('我的梗卡册', '', () => NavStore.INSTANCE.push(RouteName.MEME_ALBUM))
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.NavRow('我的例句本', '', () => NavStore.INSTANCE.push(RouteName.SENTENCE_FAVORITES))
          }
          .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .borderRadius(Radius.CARD).backgroundColor(Colors.WHITE)

          this.GroupCard('数据')
          Column() {
            this.NavRow('备份数据', '', () => this.doBackup())
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.NavRow('导入数据', '', () => this.doImport())
            Divider().color(Colors.DIVIDER).margin({ left: 0 })
            this.NavRow('清除数据', '', () => this.confirmWipe())
          }
          .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .borderRadius(Radius.CARD).backgroundColor(Colors.WHITE)

          this.GroupCard('关于')
          Column() {
            this.NavRow('隐私与关于', '', () => NavStore.INSTANCE.push(RouteName.PRIVACY))
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
