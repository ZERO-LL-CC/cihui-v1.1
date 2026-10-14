/**
 * F12 艾宾浩斯计划大表：
 * - 打卡页小日历 / 首页连续天数 chip 点击后以 zoomIn（缩放+淡入）放大进入；
 * - 6×7 月历（周一为首列），每格：橙块=当天新学，R1/R2/R4/R7/R15 彩点=计划复习；
 *   今天蓝框、已完成绿✓、已补卡绿底橙「补」、待补卡红格、未来日锁定；
 * - 顶部三统计（连续 / 本月完成 / 待补卡）与打卡页、首页同源；
 * - ‹ › 翻月限当前月前后 3 个月；红格按严格顺序进补卡详情；
 * - 入场 42 格逐格果冻弹入（500ms 内完成），系统「减弱动态效果」时直接落位；
 * - 边缘左滑 / 左上返回：customTransition 缩放淡出缩回小日历。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { RouteName } from '../../common/RouteNames';
import type { MakeupRouteParam } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion, StageColors } from '../../common/DesignTokens';
import { promptAction } from '@kit.ArkUI';
import type { MonthCell, MonthGrid, PlannedDot } from '../../model/SchedulerCore';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

const WEEKDAYS: string[] = ['一', '二', '三', '四', '五', '六', '日'];
const NODE_LEGEND: string[] = ['R1', 'R2', 'R4', 'R7', 'R15'];

/** 单个月历格：负责自己的果冻入场动画（key 含年月，翻月时整体重播） */
@ComponentV2
struct CalendarCell {
  @Require @Param cell: MonthCell;
  @Require @Param row: number;
  @Require @Param col: number;
  @Require @Param animKey: string;
  @Require @Param onTap: (cell: MonthCell) => void;
  @Local jellyScale: number = 0.6;
  @Local jellyTy: number = 22;
  @Local jellyOpacity: number = 0;

  aboutToAppear(): void {
    if (!this.cell.inMonth) {
      this.jellyScale = 1;
      this.jellyTy = 0;
      this.jellyOpacity = 1;
      return;
    }
    if (NavStore.INSTANCE.reducedMotion) {
      this.jellyScale = 1;
      this.jellyTy = 0;
      this.jellyOpacity = 1;
      return;
    }
    // 第一排逐格弹、后面一排排跟上，500ms 内完成
    const delay: number = Math.min(this.row * 62 + this.col * 22, 480);
    setTimeout(() => {
      this.getUIContext().animateTo(
        { duration: 420, curve: Curve.EaseOut },
        () => {
          this.jellyScale = 1;
          this.jellyTy = 0;
          this.jellyOpacity = 1;
        }
      );
    }, delay);
  }

  @Builder
  Dots() {
    Row({ space: 3 }) {
      ForEach(this.cell.dots, (d: PlannedDot) => {
        Circle({ width: 6, height: 6 }).fill(StageColors.colorOf(d.stage))
      }, (d: PlannedDot) => this.animKey + '-dot-' + d.stage)
    }
    .height(8)
    .margin({ top: 2 })
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Text(this.cell.dateNum > 0 ? `${this.cell.dateNum}` : '')
          .fontSize(13)
          .fontWeight(this.cell.state === 'today' ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.dateColor())
        if (this.cell.state === 'made') {
          Text('补')
            .fontSize(9).fontColor(Colors.FUZZY_ORANGE).fontWeight(FontWeight.Bold)
            .backgroundColor(Colors.WHITE).borderRadius(6)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ top: 2, right: 2 })
        }
        if (this.cell.state === 'missed') {
          Text('补')
            .fontSize(9).fontColor(Colors.UNKNOWN_RED).fontWeight(FontWeight.Bold)
            .margin({ top: 2, right: 4 })
        }
      }
      .width('100%')
      .height(20)

      if (this.cell.newCount > 0) {
        Row()
          .width(16).height(4).borderRadius(2)
          .backgroundColor(Colors.STAGE_NEW)
          .margin({ top: 3 })
      }
      this.Dots()
    }
    .width('100%')
    .height(52)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.cellBg())
    .borderWidth(this.cell.state === 'today' ? 1.5 : 0)
    .borderColor(Colors.BRAND)
    .opacity(this.cell.inMonth ? this.jellyOpacity : 0)
    .scale({ x: this.jellyScale, y: this.jellyScale })
    .translate({ y: this.jellyTy })
    .onClick(() => {
      if (this.cell.inMonth) {
        this.onTap(this.cell);
      }
    })
  }

  private dateColor(): string {
    if (!this.cell.inMonth) {
      return Colors.TEXT_WEAK;
    }
    if (this.cell.state === 'missed') {
      return Colors.UNKNOWN_RED;
    }
    if (this.cell.state === 'done' || this.cell.state === 'made') {
      return Colors.KNOW_GREEN;
    }
    if (this.cell.state === 'today') {
      return Colors.BRAND;
    }
    if (this.cell.state === 'future') {
      return Colors.TEXT_WEAK;
    }
    return Colors.TEXT_MAIN;
  }

  private cellBg(): ResourceColor {
    if (this.cell.state === 'done' || this.cell.state === 'made') {
      return Colors.KNOW_GREEN_SOFT;
    }
    if (this.cell.state === 'missed') {
      return Colors.UNKNOWN_RED_SOFT;
    }
    if (this.cell.state === 'today') {
      return Colors.BRAND_SOFT;
    }
    return Colors.WHITE;
  }
}

@ComponentV2
export struct PlanTablePage {
  @Local zoom: number = 0.88;
  @Local zoomOpacity: number = 0;
  @Local year: number = new Date().getFullYear();
  @Local month: number = new Date().getMonth() + 1;
  @Local gridVersion: number = 0;
  @Local grid: MonthGrid = this.loadGrid(new Date().getFullYear(), new Date().getMonth() + 1);
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.PLAN_TABLE) {
      this.showTick++;
    }
  };
  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
  }


  private readonly now: Date = new Date();

  private loadGrid(y: number, m: number): MonthGrid {
    return DataStore.INSTANCE.monthGrid(y, m);
  }

  private switchMonth(delta: number): void {
    let m: number = this.month - 1 + delta;
    let y: number = this.year;
    if (m < 0) {
      m = 11;
      y -= 1;
    } else if (m > 11) {
      m = 0;
      y += 1;
    }
    const mm: number = m + 1;
    // 限当前月前后 3 个月
    const diff: number = (y - this.now.getFullYear()) * 12 + (mm - (this.now.getMonth() + 1));
    if (diff < -3 || diff > 3) {
      promptAction.showToast({ message: '只能查看前后 3 个月的计划', duration: 1600 });
      return;
    }
    this.year = y;
    this.month = mm;
    this.gridVersion += 1;
    this.grid = this.loadGrid(y, mm);
  }

  private onCellTap(cell: MonthCell): void {
    if (cell.state === 'future') {
      promptAction.showToast({ message: '未到日期，不能提前打卡', duration: 1800 });
      return;
    }
    if (cell.state === 'today') {
      promptAction.showToast({ message: '回到打卡页完成今日任务', duration: 1600 });
      NavStore.INSTANCE.goTab(1);
      NavStore.INSTANCE.back();
      return;
    }
    if (cell.state === 'done') {
      promptAction.showToast({ message: '当天已完成打卡', duration: 1400 });
      return;
    }
    if (cell.state === 'made') {
      promptAction.showToast({ message: '该日已补卡', duration: 1400 });
      return;
    }
    // missed：严格顺序校验后进补卡详情
    const ok = DataStore.INSTANCE.makeupEligibility(cell.day);
    if (!ok.ok) {
      promptAction.showToast({ message: ok.reason, duration: 2200 });
      return;
    }
    const p: MakeupRouteParam = { day: cell.day };
    NavStore.INSTANCE.push(RouteName.MAKEUP_DETAIL, p);
  }

  private animateCovered(covered: boolean): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : Motion.PAGE, curve: Curve.EaseOut },
      () => {
        NavStore.INSTANCE.covered = covered;
      }
    );
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())

      Text('艾宾浩斯计划表')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Row().width(44).height(44)
    }
    .width('100%').height(56)
  }

  @Builder
  StatCard(value: string, label: string, danger: boolean) {
    Column() {
      Text(value)
        .fontSize(22).fontWeight(FontWeight.Bold)
        .fontColor(danger ? Colors.UNKNOWN_RED : Colors.TEXT_MAIN)
      Text(label).fontSize(11).fontColor(Colors.TEXT_SUB).margin({ top: 4 })
    }
    .layoutWeight(1)
    .padding({ top: 12, bottom: 12 })
    .backgroundColor(Colors.WHITE)
    .borderRadius(Radius.CONTROL)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  Legend() {
    Column() {
      Row() {
        Row().width(14).height(8).borderRadius(2).backgroundColor(Colors.STAGE_NEW)
        Text('新学').fontSize(11).fontColor(Colors.TEXT_SUB).margin({ left: 4, right: 12 })
        ForEach(NODE_LEGEND, (node: string) => {
          Row() {
            Circle({ width: 7, height: 7 }).fill(StageColors.colorOf(node))
            Text(node).fontSize(11).fontColor(Colors.TEXT_SUB).margin({ left: 3, right: 10 })
          }
        }, (node: string) => 'legend-' + node)
      }
      .width('100%')

      Row() {
        Row().width(10).height(10).borderRadius(3).backgroundColor(Colors.BRAND_SOFT)
          .border({ width: 1, color: Colors.BRAND })
        Text('今天').fontSize(11).fontColor(Colors.TEXT_SUB).margin({ left: 4, right: 14 })
        Row().width(10).height(10).borderRadius(3).backgroundColor(Colors.KNOW_GREEN_SOFT)
        Text('已完成').fontSize(11).fontColor(Colors.TEXT_SUB).margin({ left: 4, right: 14 })
        Row().width(10).height(10).borderRadius(3).backgroundColor(Colors.UNKNOWN_RED_SOFT)
        Text('待补卡').fontSize(11).fontColor(Colors.TEXT_SUB).margin({ left: 4 })
      }
      .width('100%').margin({ top: 8 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Colors.WHITE)
    .borderRadius(Radius.CONTROL)
    .margin({ top: 12 })
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()

        Scroll() {
          Column() {
            // 月份切换
            Row() {
              Button('‹')
                .fontSize(24).fontColor(Colors.TEXT_MAIN)
                .type(ButtonType.Normal).width(44).height(40)
                .backgroundColor(Color.Transparent)
                .onClick(() => this.switchMonth(-1))
              Text(`${this.year} 年 ${this.month} 月`)
                .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
                .layoutWeight(1).textAlign(TextAlign.Center)
              Button('›')
                .fontSize(24).fontColor(Colors.TEXT_MAIN)
                .type(ButtonType.Normal).width(44).height(40)
                .backgroundColor(Color.Transparent)
                .onClick(() => this.switchMonth(1))
            }
            .width('100%')
            .padding({ left: 12, right: 12 })

            // 三统计
            Row({ space: 10 }) {
              this.StatCard(`${this.grid.streak}`, '连续打卡（天）', false)
              this.StatCard(`${this.grid.monthDone}`, '本月已完成', false)
              this.StatCard(`${this.grid.pendingMakeup}`, '待补卡（天）', this.grid.pendingMakeup > 0)
            }
            .width('100%').padding({ left: 16, right: 16 }).margin({ top: 4 })

            // 月历卡
            Column() {
              Row() {
                ForEach(WEEKDAYS, (w: string, idx: number) => {
                  Text(w)
                    .fontSize(12).fontColor(Colors.TEXT_WEAK)
                    .layoutWeight(1).textAlign(TextAlign.Center)
                }, (w: string) => 'wd-' + w)
              }
              .width('100%').margin({ bottom: 6 })

              Grid() {
                ForEach(this.grid.cells, (cell: MonthCell, index: number) => {
                  GridItem() {
                    CalendarCell({
                      cell,
                      row: Math.floor(index / 7),
                      col: index % 7,
                      animKey: `${this.gridVersion}-${this.year}-${this.month}-${cell.day}`,
                      onTap: (c: MonthCell): void => this.onCellTap(c),
                    })
                  }
                }, (cell: MonthCell) => `${this.gridVersion}-${cell.day}`)
              }
              .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
              .rowsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
              .columnsGap(6)
              .rowsGap(6)
              .width('100%')
              .height(342)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Colors.WHITE)
            .borderRadius(Radius.CARD)
            .margin({ top: 12, left: 16, right: 16 })

            this.Legend()

            // 说明卡
            Column() {
              Text('怎么看这张表')
                .fontSize(14).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
                .width('100%')
              Text('每个新词首学当天显示橙色「新学」块，之后按 R1（次日）、R2、R4、R7、R15 安排复习，对应颜色的圆点就是当天要复习的词。红色格子表示当天有任务但没打卡，点红格可按由近及远的顺序补卡；补卡不恢复连续天数。')
                .fontSize(12).fontColor(Colors.TEXT_SUB).lineHeight(19)
                .width('100%').margin({ top: 8 })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Colors.WHITE)
            .borderRadius(Radius.CONTROL)
            .margin({ top: 12, left: 16, right: 16, bottom: 28 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
    }
    .hideTitleBar(true)
    .opacity(1 + this.showTick * 0)
    .scale({ x: this.zoom, y: this.zoom })
    .opacity(this.zoomOpacity)
    .onShown(() => {
      this.showTick++;
      // 从补卡详情返回时重算（红格应变绿底橙「补」）
      this.grid = this.loadGrid(this.year, this.month);
      this.animateCovered(true);
    })
    .onHidden(() => this.animateCovered(false))
    .customTransition((operation: NavigationOperation, isEnter: boolean): NavDestinationTransition[] | undefined => {
      const reduced: boolean = NavStore.INSTANCE.reducedMotion;
      return [{
        duration: reduced ? Motion.REDUCED : Motion.PAGE,
        curve: Curve.EaseOut,
        event: () => {
          if (reduced) {
            this.zoom = 1;
            this.zoomOpacity = isEnter ? 1 : 0;
            return;
          }
          if (operation === NavigationOperation.PUSH && isEnter) {
            this.zoom = 1;
            this.zoomOpacity = 1;
          } else if (operation === NavigationOperation.POP && !isEnter) {
            this.zoom = 0.88;
            this.zoomOpacity = 0;
          }
        }
      }];
    })
  }
}
