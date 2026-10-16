/**
 * F12 艾宾浩斯计划大表（W2 白·蔚蓝版）：
 * - 打卡页小日历 / 首页连续天数 chip 点击后以 zoomIn（缩放+淡入）放大进入；
 * - 顶部蓝色渐变头卡：左侧月份冲刺文案 + 连击胶囊，右侧完成率进度环；
 *   三枚半透明数据 chip（本月已完成 / 待补卡 / 今日待复习），flex 均分防出框；
 * - 6×7 月历（周一为首列）：已完成浅蓝、已补卡深蓝+白✓+橙「补」、
 *   待补卡红格、今天品牌蓝渐变放大、未来日白底虚线框，R1-R15 彩点保留；
 * - ‹ › 翻月限当前月前后 3 个月；红格按严格顺序进补卡详情；
 * - 底部「今日任务」CTA 直达打卡页；
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

/** W2 白·蔚蓝 专用色 */
const BLUE_DONE_BG: string = '#E3EDFF';      // 已完成格底
const BLUE_DONE_FG: string = '#0846C0';      // 已完成格字
const BLUE_MADE: string = '#0846C0';         // 已补卡格底（深蓝）
const FUTURE_DASH: string = '#D8E2F2';       // 未来日虚线框
const FUTURE_FG: string = '#C4CAD4';         // 未来日字
const PLAIN_BG: string = '#F5F7FA';          // 普通格底
const HERO_GRAD_HI: string = '#3D7BFF';      // 头卡渐变亮端
const HERO_GRAD_LO: string = '#0846C0';      // 头卡渐变暗端
const HERO_SUB: string = '#CFE0FF';          // 头卡次级文字
const HERO_CHIP: string = '#24FFFFFF';       // 头卡半透明白块
const PAGE_W2: string = '#FBFCFE';           // 页面底色

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

  private label(): string {
    if (this.cell.state === 'today') {
      return '今天';
    }
    if (this.cell.dateNum > 0) {
      return `${this.cell.dateNum}`;
    }
    const parts: string[] = this.cell.day.split('-');
    return `${Number(parts[2])}`;
  }

  private badgeRadius(): BorderRadiuses {
    const r: BorderRadiuses = { topLeft: 10, topRight: 10, bottomLeft: 10, bottomRight: 10 };
    return r;
  }

  @Builder
  BigCheck(white: boolean) {
    Path()
      .width(16)
      .height(16)
      .commands('M2.5 9 L6.6 13 L13.8 4.6')
      .fillOpacity(0)
      .stroke(white ? Color.White : Colors.BRAND)
      .strokeWidth(3)
      .strokeLineCap(LineCapStyle.Round)
      .strokeLineJoin(LineJoinStyle.Round)
      .margin({ top: 4 })
  }

  @Builder
  CornerBadge(color: ResourceColor) {
    Text('补')
      .fontSize(8)
      .fontColor(Color.White)
      .fontWeight(FontWeight.Bold)
      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
      .backgroundColor(color)
      .borderRadius(this.badgeRadius())
      .margin({ top: 1, right: 1 })
  }

  @Builder
  Dots() {
    Row({ space: 3 }) {
      ForEach(this.cell.dots, (d: PlannedDot) => {
        Circle({ width: 6, height: 6 })
          .fill(StageColors.colorOf(d.stage))
          .border(this.cell.state === 'today' ? { width: 1, color: Color.White } : { width: 0 })
      }, (d: PlannedDot) => this.animKey + '-dot-' + d.stage)
    }
    .height(8)
    .margin({ top: 2 })
  }

  build() {
    // 数字在格内居中，「补」角标独立叠放在右上角，两者不再抢同一布局行
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        Text(this.label())
          .fontSize(this.cell.state === 'today' ? 11 : 13)
          .fontWeight(this.cell.state === 'today' ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.dateColor())

        if (this.cell.inMonth && this.cell.state === 'done') {
          this.BigCheck(false)
        } else if (this.cell.inMonth && this.cell.state === 'made') {
          this.BigCheck(true)
        } else if (this.cell.inMonth) {
          if (this.cell.newCount > 0) {
            Row()
              .width(16).height(4).borderRadius(2)
              .backgroundColor(this.cell.state === 'today' ? Color.White : Colors.STAGE_NEW)
              .margin({ top: 3 })
          }
          this.Dots()
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)

      if (this.cell.state === 'made') {
        this.CornerBadge(Colors.FUZZY_ORANGE)
      } else if (this.cell.state === 'missed') {
        this.CornerBadge(Colors.UNKNOWN_RED)
      }
    }
    .width('100%')
    .height(52)
    .borderRadius(12)
    .backgroundColor(this.cellBg())
    .border(this.cellBorder())
    .opacity(this.jellyOpacity)
    .scale({ x: this.jellyScale * this.todayBoost(), y: this.jellyScale * this.todayBoost() })
    .translate({ y: this.jellyTy })
    .onClick(() => {
      if (this.cell.inMonth) {
        this.onTap(this.cell);
      }
    })
  }

  /** 今天的格子静态放大 1.07，与果冻入场动画叠乘 */
  private todayBoost(): number {
    return this.cell.inMonth && this.cell.state === 'today' ? 1.07 : 1;
  }

  private cellBorder(): BorderOptions {
    if (this.cell.inMonth && this.cell.state === 'future') {
      const o: BorderOptions = { width: 1.5, color: FUTURE_DASH, style: BorderStyle.Dashed };
      return o;
    }
    const none: BorderOptions = { width: 0 };
    return none;
  }

  private dateColor(): string {
    if (!this.cell.inMonth) {
      return '#C6CDD9';
    }
    if (this.cell.state === 'missed') {
      return Colors.UNKNOWN_RED;
    }
    if (this.cell.state === 'made') {
      return '#FFFFFF';
    }
    if (this.cell.state === 'done') {
      return BLUE_DONE_FG;
    }
    if (this.cell.state === 'today') {
      return '#FFFFFF';
    }
    if (this.cell.state === 'future') {
      return FUTURE_FG;
    }
    return Colors.TEXT_MAIN;
  }

  private cellBg(): ResourceColor {
    if (this.cell.state === 'made') {
      return BLUE_MADE;
    }
    if (this.cell.state === 'done') {
      return BLUE_DONE_BG;
    }
    if (this.cell.state === 'missed') {
      return Colors.UNKNOWN_RED_SOFT;
    }
    if (this.cell.state === 'today') {
      return Colors.BRAND;
    }
    if (this.cell.inMonth) {
      return PLAIN_BG;
    }
    return Color.Transparent;
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

  /** 今日剩余待复习词数（CTA 文案用） */
  private todayDue(): number {
    return DataStore.INSTANCE.todayReviewWordList().length;
  }

  /** 打卡完成率：本月已打卡天数 / 已经过天数（跨月查看时按整月） */
  private completionRate(): number {
    let done: number = 0;
    const cells: MonthCell[] = this.grid.cells;
    for (const c of cells) {
      if (c.inMonth && (c.state === 'done' || c.state === 'made')) {
        done++;
      }
    }
    const t: Date = new Date();
    const isCur: boolean = this.year === t.getFullYear() && this.month === t.getMonth() + 1;
    const elapsed: number = isCur ? t.getDate() : new Date(this.year, this.month, 0).getDate();
    if (elapsed <= 0) {
      return 0;
    }
    return Math.min(100, Math.round(done * 100 / elapsed));
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

  /** W2 蓝色渐变头卡：冲刺文案 + 完成率环 + 三枚数据 chip */
  @Builder
  HeroCard() {
    Column() {
      Row() {
        Column() {
          Text(`${this.month} 月冲刺进行中`)
            .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
          Text(this.grid.pendingMakeup > 0
            ? `有 ${this.grid.pendingMakeup} 天待补卡，别让记忆曲线断掉`
            : '按 R1/R2/R4/R7/R15 节点稳步推进')
            .fontSize(11).fontColor(HERO_SUB)
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Row() {
            Image($r('app.media.ic_flame')).width(12).height(12).fillColor(Colors.WHITE)
            Text(`连续 ${this.grid.streak} 天`)
              .fontSize(11).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
              .margin({ left: 4 })
          }
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .borderRadius(99)
          .backgroundColor(HERO_CHIP)
          .margin({ top: 8 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .constraintSize({ minWidth: 0 })

        Stack({ alignContent: Alignment.Center }) {
          Progress({ value: this.completionRate(), total: 100, type: ProgressType.Ring })
            .width(70).height(70).color(Colors.WHITE)
            .style({ strokeWidth: 6 })
            .backgroundColor(HERO_CHIP)
            .animation({ duration: Motion.PAGE, curve: Curve.EaseOut })
          Text(`${this.completionRate()}%`)
            .fontSize(14).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
        }
        .width(70).height(70)
      }
      .width('100%')

      Row({ space: 8 }) {
        this.HeroChip(`${this.grid.monthDone}`, '本月已完成')
        this.HeroChip(`${this.grid.pendingMakeup}`, '待补卡（天）')
        this.HeroChip(`${this.todayDue()}`, '今日待复习')
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding(18)
    .borderRadius(20)
    .linearGradient({ angle: 140, colors: [[HERO_GRAD_HI, 0], [HERO_GRAD_LO, 1]] })
    .shadow({ radius: 20, color: '#730A59F7', offsetX: 0, offsetY: 10 })
  }

  /** 半透明数据 chip：flex 均分 + 数字不缩格，防出框 */
  @Builder
  HeroChip(value: string, label: string) {
    Column() {
      Text(value)
        .fontSize(15).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
        .maxLines(1)
      Text(label)
        .fontSize(9).fontColor(HERO_SUB)
        .margin({ top: 2 })
        .maxLines(1)
    }
    .layoutWeight(1)
    .constraintSize({ minWidth: 0 })
    .padding({ top: 8, bottom: 8 })
    .backgroundColor(HERO_CHIP)
    .borderRadius(12)
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
        Row().width(10).height(10).borderRadius(3).backgroundColor(Colors.BRAND)
        Text('今天').fontSize(11).fontColor(Colors.TEXT_SUB).margin({ left: 4, right: 12 })
        Row().width(10).height(10).borderRadius(3).backgroundColor(BLUE_DONE_BG)
        Text('已完成').fontSize(11).fontColor(Colors.TEXT_SUB).margin({ left: 4, right: 12 })
        Row().width(10).height(10).borderRadius(3).backgroundColor(BLUE_MADE)
        Text('已补卡').fontSize(11).fontColor(Colors.TEXT_SUB).margin({ left: 4, right: 12 })
        Row().width(10).height(10).borderRadius(3).backgroundColor(Colors.UNKNOWN_RED_SOFT)
        Text('待补卡').fontSize(11).fontColor(Colors.TEXT_SUB).margin({ left: 4 })
      }
      .width('100%').margin({ top: 8 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Colors.WHITE)
    .borderRadius(Radius.CONTROL)
    .margin({ top: 12, left: 16, right: 16 })
  }

  @Builder
  TodayCta() {
    Column() {
      Text(this.todayDue() > 0 ? `今日任务 · 剩 ${this.todayDue()} 个待复习` : '今日任务已完成')
        .fontSize(14).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
    }
    .width('100%')
    .padding({ top: 13, bottom: 13 })
    .borderRadius(16)
    .linearGradient({ angle: 135, colors: [[HERO_GRAD_HI, 0], [Colors.BRAND, 1]] })
    .shadow({ radius: 16, color: '#590A59F7', offsetX: 0, offsetY: 8 })
    .margin({ top: 14, left: 16, right: 16, bottom: 28 })
    .onClick(() => {
      NavStore.INSTANCE.goTab(1);
      NavStore.INSTANCE.back();
    })
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
                .fontSize(22).fontColor(Colors.TEXT_MAIN)
                .type(ButtonType.Normal).width(36).height(36)
                .borderRadius(12).backgroundColor(Colors.WHITE)
                .border({ width: 1, color: '#E7EAF1' })
                .onClick(() => this.switchMonth(-1))
              Text(`${this.year} 年 ${this.month} 月`)
                .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
                .layoutWeight(1).textAlign(TextAlign.Center)
              Button('›')
                .fontSize(22).fontColor(Colors.TEXT_MAIN)
                .type(ButtonType.Normal).width(36).height(36)
                .borderRadius(12).backgroundColor(Colors.WHITE)
                .border({ width: 1, color: '#E7EAF1' })
                .onClick(() => this.switchMonth(1))
            }
            .width('100%')
            .padding({ left: 12, right: 12 })

            // W2 蓝色渐变头卡（替代原三统计卡）
            Column() {
              this.HeroCard()
            }
            .width('100%')
            .padding({ left: 16, right: 16 })
            .margin({ top: 4 })

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
            .shadow({ radius: 16, color: '#140A59F7', offsetX: 0, offsetY: 6 })
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
            .margin({ top: 12, left: 16, right: 16 })

            this.TodayCta()
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%').backgroundColor(PAGE_W2)
    }
    .hideTitleBar(true)
    .opacity(1 + this.showTick * 0)
    .scale({ x: this.zoom, y: this.zoom })
    .opacity(this.zoomOpacity)
    .onShown(() => {
      this.showTick++;
      // 从补卡详情返回时重算（红格应变蓝底橙「补」）
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
