/**
 * F11 打卡页 · 任务驱动版（v14）
 *
 * - 无词本：整页待机（「今日任务」+ 空环「还没有任务」+ 拍照导入 / 从词库选一本），
 *   不渲染任务卡、日历、规则；
 * - 有词本：今日任务卡 = 复习 X + 新学 Y = 总量 Z（每日按调度重算的变量），
 *   两行进度条 + 「去完成」直达学习流；错词强化轮到日追加一行；本月欠卡降级为一条红色提示行；
 * - 卡内三态大按钮（还差 N 词 / 完成今日打卡 / 今日已打卡），门槛仍复用 gatesToday；
 * - 艾宾浩斯迷你月历保留在任务卡下方（与 F12 计划大表同源），图例与补卡规则卡保留；
 * - 打卡成功弹层 88 圆绿底 + 对勾描边 draw，可保存分享图到相册。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, StageColors, FloatingTab } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
import type { ReviewRouteParam, MakeupRouteParam } from '../../common/RouteNames';
import type { Word } from '../../model/Types';
import type { MonthCell, MonthGrid, PlannedDot } from '../../model/SchedulerCore';
import { ShareService } from '../../service/ShareService';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';
import { openTodayNewWords } from '../../viewmodel/StudyEntry';

/** 前置条件行视图数据 */
class GateView {
  kind: number = 0; // 1 P1 / 2 P2 / 3 P3
  title: string = '';
  subtitle: string = '';
  done: boolean = false;
  active: boolean = true; // false = P3 非轮到日 ghost
}

/** 今日任务变量：复习 X + 新学 Y = 总量 Z（每日按调度重算） */
class TaskStat {
  reviewTotal: number = 0;
  reviewDone: number = 0;
  newTotal: number = 0;
  newDone: number = 0;
  total: number = 0;
  done: number = 0;
  left: number = 0;
  missed: number = 0; // 本月待补卡天数
}

/** 小米笔记风方形勾选框：对勾用 Path 描边动画 draw */
@ComponentV2
struct GateCheck {
  @Require @Param done: boolean;
  @Require @Param active: boolean;
  @Local dash: number = 18;
  @Local pop: number = 0.5;

  aboutToAppear(): void {
    this.applyState(true);
  }

  @Monitor('done')
  onDoneChange(): void {
    this.applyState(false);
  }

  private applyState(initial: boolean): void {
    if (this.done) {
      if (initial || NavStore.INSTANCE.reducedMotion) {
        this.dash = 0;
        this.pop = 1;
        return;
      }
      this.dash = 18;
      this.pop = 0.4;
      this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseOut }, () => {
        this.dash = 0;
        this.pop = 1;
      });
    } else {
      this.dash = 18;
      this.pop = 0.5;
    }
  }

  build() {
    Stack() {
      Path()
        .width(15)
        .height(15)
        .commands('M2.5 8 L6.4 11.9 L12.6 3.9')
        .fillOpacity(0)
        .stroke(Color.White)
        .strokeWidth(2.8)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .strokeDashArray([18])
        .strokeDashOffset(this.dash)
    }
    .width(23)
    .height(23)
    .borderRadius(7)
    .backgroundColor(this.done ? Colors.KNOW_GREEN : (this.active ? Colors.WHITE : '#F4F6FA'))
    .border(this.done
      ? { width: 0 }
      : { width: 1.5, color: this.active ? '#C6CDD9' : '#DDE2EA', style: BorderStyle.Solid })
    .scale({ x: this.done ? this.pop : 1, y: this.done ? this.pop : 1 })
  }
}

/** 打卡成功弹层的 88 圆绿底描边大对勾 */
@ComponentV2
struct SuccessCheck {
  @Local ring: number = 0.5;
  @Local dash: number = 42;

  aboutToAppear(): void {
    if (NavStore.INSTANCE.reducedMotion) {
      this.ring = 1;
      this.dash = 0;
      return;
    }
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
      this.ring = 1;
    });
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseOut }, () => {
        this.dash = 0;
      });
    }, 170);
  }

  build() {
    Stack() {
      Path()
        .width(42)
        .height(42)
        .commands('M11 25 L20 34 L39 14')
        .fillOpacity(0)
        .stroke(Color.White)
        .strokeWidth(4.4)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .strokeDashArray([42])
        .strokeDashOffset(this.dash)
    }
    .width(88)
    .height(88)
    .borderRadius(44)
    .backgroundColor(Colors.KNOW_GREEN)
    .scale({ x: this.ring, y: this.ring })
  }
}

/** 迷你月历单元格（与计划大表 MonthCell 同源数据） */
@ComponentV2
struct MiniCell {
  @Require @Param cell: MonthCell;
  @Require @Param onTap: (c: MonthCell) => void;

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

  private numColor(): ResourceColor {
    if (!this.cell.inMonth) {
      return '#C6CDD9';
    }
    if (this.cell.state === 'missed') {
      return Colors.UNKNOWN_RED;
    }
    if (this.cell.state === 'made') {
      return Color.White;
    }
    if (this.cell.state === 'done') {
      return Colors.KNOW_GREEN;
    }
    if (this.cell.state === 'today') {
      return Color.White;
    }
    return Colors.TEXT_WEAK;
  }

  private bg(): ResourceColor {
    if (this.cell.state === 'made') {
      return Colors.KNOW_GREEN;
    }
    if (this.cell.state === 'done') {
      return Colors.KNOW_GREEN_SOFT;
    }
    if (this.cell.state === 'missed') {
      return Colors.UNKNOWN_RED_SOFT;
    }
    if (this.cell.state === 'today') {
      return Colors.BRAND;
    }
    if (this.cell.inMonth) {
      return '#F3F5F9';
    }
    return Color.Transparent;
  }

  private badgeRadius(): BorderRadiuses {
    const r: BorderRadiuses = { topLeft: 0, topRight: 11, bottomLeft: 8, bottomRight: 0 };
    return r;
  }

  @Builder
  MiniCheck(white: boolean) {
    Path()
      .width(13)
      .height(13)
      .commands('M2.5 7 L5.6 10 L11 3.6')
      .fillOpacity(0)
      .stroke(white ? Color.White : Colors.KNOW_GREEN)
      .strokeWidth(2.6)
      .strokeLineCap(LineCapStyle.Round)
      .strokeLineJoin(LineJoinStyle.Round)
      .margin({ top: 2 })
  }

  @Builder
  Dots() {
    Row({ space: 2 }) {
      ForEach(this.cell.dots, (d: PlannedDot) => {
        Circle({ width: 5, height: 5 })
          .fill(StageColors.colorOf(d.stage))
          .border(this.cell.state === 'today' ? { width: 1, color: Color.White } : { width: 0 })
      }, (d: PlannedDot) => `${d.stage}-${d.count}`)
    }
    .height(7)
    .margin({ top: 2 })
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
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        Text(this.label())
          .fontSize(this.cell.state === 'today' ? 10 : 11)
          .fontWeight(this.cell.state === 'today' ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.numColor())
        if (this.cell.state === 'done') {
          this.MiniCheck(false)
        } else if (this.cell.state === 'made') {
          this.MiniCheck(true)
        } else {
          if (this.cell.inMonth && this.cell.newCount > 0) {
            Row()
              .width(14)
              .height(4)
              .borderRadius(2)
              .backgroundColor(this.cell.state === 'today' ? Color.White : Colors.STAGE_NEW)
              .margin({ top: 3 })
          }
          if (this.cell.inMonth && this.cell.dots.length > 0) {
            this.Dots()
          }
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
    .height(42)
    .borderRadius(11)
    .backgroundColor(this.bg())
    .opacity(this.cell.inMonth ? 1 : 0.5)
    .onClick(() => {
      if (this.cell.inMonth) {
        this.onTap(this.cell);
      }
    })
  }
}

@ComponentV2
export struct CheckInPage {
  @Require @Param active: boolean;
  /** 导航版本号：从新词/复习/错词流程返回时实时重算前置条件与小日历 */
  @Param tick: number = 0;
  @Local enterOpacity: number = 0;
  @Local enterTy: number = 8;

  @Local showSuccess: boolean = false;
  @Local overlayOpacity: number = 0;
  @Local cardScale: number = 0.8;
  @Local shareStreak: number = 0;
  @Local shareDateText: string = '';
  @Local shareNewDone: number = 0;
  @Local shareReviewDone: number = 0;
  @Local saving: boolean = false;
  @Local pressBtn: boolean = false;
  /** 显式刷新版本号，学习/打卡/补卡等数据变化后强制重算 */
  @Local viewTick: number = 0;
  @Local miniVer: number = 0;
  @Local mini: MonthGrid = this.buildMini();

  private readonly weekNames: string[] = ['一', '二', '三', '四', '五', '六', '日'];
  private refreshWhenActive: RefreshListener = (): void => {
    if (this.active) {
      this.viewTick++;
      this.reloadMini();
    }
  };

  @Monitor('active')
  onActiveChange(): void {
    if (this.active) {
      this.playEnter();
      this.viewTick++;
      this.reloadMini();
    }
  }

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenActive);
    REFRESH_BUS.onData(this.refreshWhenActive);
    if (this.active) {
      this.playEnter();
    }
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenActive);
    REFRESH_BUS.offData(this.refreshWhenActive);
  }

  private playEnter(): void {
    const dur: number = NavStore.INSTANCE.reducedMotion ? 0 : 200;
    this.getUIContext().animateTo({ duration: dur, curve: Curve.EaseOut, delay: dur === 0 ? 0 : 20 }, () => {
      this.enterOpacity = 1;
      this.enterTy = 0;
    });
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 1800 });
    } catch (_e) {
    }
  }

  private todayKey(): string {
    const d: Date = new Date();
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  private dateTitle(): string {
    const d: Date = new Date();
    const w: string = ['日', '一', '二', '三', '四', '五', '六'][d.getDay()];
    return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日 星期${w}`;
  }

  private buildMini(): MonthGrid {
    const d: Date = new Date();
    return DataStore.INSTANCE.monthGrid(d.getFullYear(), d.getMonth() + 1);
  }

  private reloadMini(): void {
    this.mini = this.buildMini();
    this.miniVer++;
  }

  /** 组装三行前置数据 */
  private buildGates(): GateView[] {
    const gates = DataStore.INSTANCE.gatesToday();
    const stats = DataStore.INSTANCE.homeStats();
    const p3 = DataStore.INSTANCE.p3Today();
    const wrongCount: number = DataStore.INSTANCE.wrongEntries().length;

    const p1Done: boolean = stats.newAssigned === 0 || stats.newDone >= stats.newAssigned;
    const p2Done: boolean = stats.reviewDue === 0;
    const p1Remain: number = Math.max(0, stats.newAssigned - stats.newDone);

    const p1 = new GateView();
    p1.kind = 1;
    p1.title = '今日新词全部学完';
    p1.done = p1Done;
    p1.subtitle = p1Done ? `已完成 ${stats.newDone}/${stats.newAssigned}` : `还剩 ${p1Remain} 个新词待学`;

    const p2 = new GateView();
    p2.kind = 2;
    p2.title = '到期复习整轮全部过完';
    p2.done = p2Done;
    p2.subtitle = p2Done ? `已完成 ${stats.reviewDone} 个复习` : `还剩 ${stats.reviewDue} 个到期复习`;

    const p3Row = new GateView();
    p3Row.kind = 3;
    p3Row.title = '错词本强化复习（每 5 天一次）';
    p3Row.active = gates.p3Required;
    if (!gates.p3Required) {
      p3Row.done = true;
      if (p3.nextDay === '') {
        p3Row.subtitle = '当前没有错词，本轮无需强化';
      } else {
        const parts: string[] = p3.nextDay.split('-');
        p3Row.subtitle = `今天不轮到，下次轮到 ${Number(parts[1])}月${Number(parts[2])}日`;
      }
    } else {
      p3Row.done = gates.p3;
      p3Row.subtitle = gates.p3 ? '错词已全部强化完' : `轮到强化日，还剩 ${wrongCount} 个错词`;
    }

    return [p1, p2, p3Row];
  }

  /** 未达标项数（P3 非轮到日不计数） */
  private missingCount(rows: GateView[]): number {
    let n: number = 0;
    for (const r of rows) {
      if (r.active && !r.done) {
        n += 1;
      }
    }
    return n;
  }

  /** 点击未完成行 / 置灰按钮：直达第一个缺口 */
  private jumpGap(kind: number): void {
    if (kind === 1) {
      openTodayNewWords();
      return;
    }
    if (kind === 2) {
      const ids: string[] = DataStore.INSTANCE.todayReviewWordList().map((w: Word): string => w.id);
      if (ids.length === 0) {
        this.toast('复习任务已完成');
        return;
      }
      const param: ReviewRouteParam = { wordIds: ids, title: '到期复习', mode: 'REVIEW' };
      NavStore.INSTANCE.push(RouteName.REVIEW_CARDS, param);
      return;
    }
    NavStore.INSTANCE.push(RouteName.WRONG_BOOK);
  }

  private jumpFirstGap(): void {
    for (const r of this.buildGates()) {
      if (r.active && !r.done) {
        this.jumpGap(r.kind);
        return;
      }
    }
  }

  /** 迷你日历点格：与计划大表 onCellTap 同一套跳转 */
  private onCellTap(cell: MonthCell): void {
    if (cell.state === 'future') {
      this.toast('未到日期，不能提前打卡');
      return;
    }
    if (cell.state === 'today') {
      this.toast(this.isChecked() ? '今天已打卡' : '完成今天的任务后点「完成今日打卡」');
      return;
    }
    if (cell.state === 'done') {
      this.toast('当天已完成打卡');
      return;
    }
    if (cell.state === 'made') {
      this.toast('该日已补卡');
      return;
    }
    const ok = DataStore.INSTANCE.makeupEligibility(cell.day);
    if (!ok.ok) {
      this.toast(ok.reason);
      return;
    }
    const p: MakeupRouteParam = { day: cell.day };
    NavStore.INSTANCE.push(RouteName.MAKEUP_DETAIL, p);
  }

  private isChecked(): boolean {
    return DataStore.INSTANCE.isCheckedInToday();
  }

  /** 真正导入过才进入任务态：既要存在词本，词本里还要真的有词（空词本仍算待机） */
  private hasBooks(): boolean {
    if (DataStore.INSTANCE.books.length === 0) {
      return false;
    }
    return DataStore.INSTANCE.words.length > 0;
  }

  /** 今日任务变量：复习 = 到期 + 已完成；新学 = 当日分配 + 已完成 */
  private taskStat(): TaskStat {
    const stats = DataStore.INSTANCE.homeStats();
    const t = new TaskStat();
    t.newTotal = stats.newAssigned;
    t.newDone = stats.newDone;
    t.reviewDone = stats.reviewDone;
    t.reviewTotal = stats.reviewDue + stats.reviewDone;
    t.total = t.newTotal + t.reviewTotal;
    t.done = t.newDone + t.reviewDone;
    t.left = Math.max(0, t.total - t.done);
    let missed: number = 0;
    this.mini.cells.forEach((c: MonthCell): void => {
      if (c.state === 'missed') {
        missed += 1;
      }
    });
    t.missed = missed;
    return t;
  }

  /** 每日新词量（任务卡副标用） */
  private dailyGoal(): number {
    return DataStore.INSTANCE.settings.dailyNewCount;
  }

  private progressPct(t: TaskStat): number {
    return t.total === 0 ? 100 : Math.round(t.done / t.total * 100);
  }

  private taskSubText(t: TaskStat): string {
    if (t.reviewTotal === 0 && t.newTotal === 0) {
      return '今天没有任务，休息一下';
    }
    if (t.reviewTotal === 0) {
      return `新学 ${t.newTotal} · 导入日不复习`;
    }
    if (t.newTotal === 0) {
      return `只复习 ${t.reviewTotal} · 词库已排空`;
    }
    return `复习 ${t.reviewTotal} + 新学 ${t.newTotal}`;
  }

  private reviewHint(): string {
    const t = this.taskStat();
    if (t.reviewTotal === 0) {
      return '今天没有到期词';
    }
    return `艾宾浩斯到期节点 · 已过 ${t.reviewDone}/${t.reviewTotal}`;
  }

  private doCheckin(): void {
    if (DataStore.INSTANCE.isCheckedInToday()) {
      return;
    }
    DataStore.INSTANCE.checkInToday();
    const stats = DataStore.INSTANCE.homeStats();
    this.shareStreak = DataStore.INSTANCE.streak();
    this.shareDateText = this.dateTitle();
    this.shareNewDone = stats.newDone;
    this.shareReviewDone = stats.reviewDone;
    this.reloadMini();
    this.showSuccess = true;
    this.overlayOpacity = 0;
    this.cardScale = 0.8;
    const dur: number = NavStore.INSTANCE.reducedMotion ? 0 : 280;
    this.getUIContext().animateTo({ duration: dur, curve: Curve.EaseOut }, () => {
      this.overlayOpacity = 1;
      this.cardScale = 1;
    });
  }

  private closeSuccess(): void {
    const dur: number = NavStore.INSTANCE.reducedMotion ? 0 : 200;
    this.getUIContext().animateTo({ duration: dur, curve: Curve.EaseIn }, () => {
      this.overlayOpacity = 0;
      this.cardScale = 0.85;
    });
    setTimeout(() => {
      this.showSuccess = false;
      this.reloadMini();
      NavStore.INSTANCE.goTab(1);
    }, dur + 20);
  }

  private async onSaveClick(result: SaveButtonOnClickResult): Promise<void> {
    if (result !== SaveButtonOnClickResult.SUCCESS) {
      this.toast('未获得相册授权，分享图未保存');
      return;
    }
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const fileName: string = `cihui_checkin_${this.todayKey().replace(/-/g, '')}`;
      await ShareService.saveCardToGallery(ctx, this.ShareCard, fileName);
      this.toast('分享图已保存到相册');
    } catch (_e) {
      this.toast('保存失败，请重试');
    } finally {
      this.saving = false;
    }
  }

  /** 任务行：复习 / 新学，带进度条与「去完成」 */
  @Builder
  TaskRow(title: string, hint: string, done: number, total: number, color: string, kind: number) {
    Row({ space: 11 }) {
      Circle({ width: 9, height: 9 })
        .fill(done >= total && total > 0 ? Colors.KNOW_GREEN : color)
      Column({ space: 5 }) {
        Row({ space: 6 }) {
          Text(title)
            .fontSize(TypeScale.BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(Colors.TEXT_MAIN)
          if (done >= total && total > 0) {
            Text('已完成')
              .fontSize(10)
              .fontColor(Colors.KNOW_GREEN)
              .backgroundColor(Colors.KNOW_GREEN_SOFT)
              .borderRadius(6)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          }
        }
        Text(hint)
          .fontSize(10.5)
          .fontColor(Colors.TEXT_WEAK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(5)
            .borderRadius(3)
            .backgroundColor('#EEF1F6')
          Row()
            .width(`${total > 0 ? Math.min(100, done / total * 100) : 0}%`)
            .height(5)
            .borderRadius(3)
            .backgroundColor(done >= total && total > 0 ? Colors.KNOW_GREEN : color)
        }
        .width('100%')
        .height(5)
        .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(`${done}`)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(Colors.TEXT_MAIN)
      Text(`/${total}`)
        .fontSize(11)
        .fontColor(Colors.TEXT_WEAK)
      if (total > 0 && done < total) {
        Text('去完成')
          .fontSize(11)
          .fontColor(Colors.BRAND)
          .backgroundColor(Colors.BRAND_SOFT)
          .borderRadius(10)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
      }
    }
    .width('100%')
    .padding({ top: 13, bottom: 13 })
    .onClick(() => {
      if (total === 0) {
        this.toast(kind === 1 ? '今天没有新词任务' : '今天没有到期复习');
        return;
      }
      if (kind === 3) {
        NavStore.INSTANCE.push(RouteName.WRONG_BOOK);
        return;
      }
      this.jumpGap(kind);
    })
  }

  /** 卡内三态大按钮：还差 N 词（灰）/ 完成今日打卡（蓝渐变）/ 今日已打卡（浅绿） */
  @Builder
  GateButton() {
    if (this.isChecked()) {
      Row({ space: 8 }) {
        GateCheck({ done: true, active: true })
        Text('今日已打卡')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Colors.KNOW_GREEN)
          .letterSpacing(2)
      }
      .width('100%')
      .height(54)
      .borderRadius(18)
      .backgroundColor(Colors.KNOW_GREEN_SOFT)
      .justifyContent(FlexAlign.Center)
      .margin({ top: 14 })
    } else if (this.missingCount(this.buildGates()) > 0) {
      Row() {
        Text(`还差 ${this.taskStat().left} 词 · 完成后可打卡`)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#7E8798')
          .letterSpacing(0.5)
      }
      .width('100%')
      .height(54)
      .borderRadius(18)
      .backgroundColor('#EEF1F6')
      .justifyContent(FlexAlign.Center)
      .margin({ top: 14 })
      .onClick(() => this.jumpFirstGap())
    } else {
      Row() {
        Text('完成今日打卡')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .letterSpacing(3)
      }
      .width('100%')
      .height(56)
      .borderRadius(18)
      .linearGradient({ angle: 135, colors: [['#1E6BFB', 0], ['#0842B8', 1]] })
      .justifyContent(FlexAlign.Center)
      .margin({ top: 14 })
      .shadow({ radius: 16, color: 'rgba(10,89,247,0.32)', offsetY: 8 })
      .scale({ x: this.pressBtn ? 0.98 : 1, y: this.pressBtn ? 0.98 : 1 })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.getUIContext().animateTo({ duration: 120 }, () => { this.pressBtn = true; });
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.getUIContext().animateTo({ duration: 120 }, () => { this.pressBtn = false; });
        }
      })
      .onClick(() => this.doCheckin())
    }
  }

  @Builder
  LegendSwatch(color: ResourceColor, label: string, square: boolean, whiteBorder: boolean) {
    Row({ space: 4 }) {
      if (square) {
        Row()
          .width(10)
          .height(10)
          .borderRadius(3)
          .backgroundColor(color)
          .border(whiteBorder ? { width: 1, color: Colors.WHITE } : { width: 0 })
      } else {
        Circle({ width: 8, height: 8 }).fill(color)
      }
      Text(label).fontSize(10).fontColor(Colors.TEXT_WEAK)
    }
    .margin({ right: 12 })
  }

  @Builder
  LegendNode(color: ResourceColor, label: string, isNew: boolean) {
    Row({ space: 4 }) {
      if (isNew) {
        Row().width(11).height(7).borderRadius(2).backgroundColor(color)
      } else {
        Circle({ width: 7, height: 7 }).fill(color)
      }
      Text(label).fontSize(10).fontColor(Colors.TEXT_WEAK)
    }
    .margin({ right: 9 })
  }

  @Builder
  ShareCard() {
    Column({ space: 16 }) {
      Column({ space: 6 }) {
        Text('词慧')
          .fontSize(16)
          .fontColor('#DCE7FF')
          .fontWeight(FontWeight.Medium)
          .letterSpacing(4)
        Text('今日打卡成功')
          .fontSize(30)
          .fontColor(Colors.WHITE)
          .fontWeight(FontWeight.Bold)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .margin({ top: 26 })

      Column({ space: 4 }) {
        Text(`连续打卡 ${this.shareStreak} 天`)
          .fontSize(22)
          .fontColor(Colors.WHITE)
          .fontWeight(FontWeight.Bold)
        Text(this.shareDateText)
          .fontSize(12)
          .fontColor('#DCE7FF')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .margin({ top: 24 })

      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(`${this.shareNewDone}`).fontSize(20).fontColor(Colors.WHITE).fontWeight(FontWeight.Bold)
          Text('今日新词').fontSize(11).fontColor('#DCE7FF')
        }
        .layoutWeight(1)
        .padding(12)
        .borderRadius(14)
        .backgroundColor('rgba(255,255,255,0.14)')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 4 }) {
          Text(`${this.shareReviewDone}`).fontSize(20).fontColor(Colors.WHITE).fontWeight(FontWeight.Bold)
          Text('完成复习').fontSize(11).fontColor('#DCE7FF')
        }
        .layoutWeight(1)
        .padding(12)
        .borderRadius(14)
        .backgroundColor('rgba(255,255,255,0.14)')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .margin({ top: 10 })

      Blank()
      Text('按艾宾浩斯节奏，今天又记住了一点')
        .fontSize(12)
        .fontColor('#C9DAFF')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 24 })
    }
    .width(320)
    .height(400)
    .padding({ left: 26, right: 26 })
    .borderRadius(24)
    .linearGradient({
      angle: 160,
      colors: [['#2F74FF', 0], ['#0A59F7', 0.55], ['#0846C0', 1]]
    })
  }

  @Builder
  SuccessModal() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')
        .opacity(this.overlayOpacity)
        .onClick(() => this.closeSuccess())

      Column({ space: 12 }) {
        Column() {
          SuccessCheck()
        }
        .margin({ top: 30 })

        Text('打卡成功')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Colors.TEXT_MAIN)
          .margin({ top: 4 })

        Text('今日新词与到期复习已全部完成')
          .fontSize(13)
          .fontColor(Colors.TEXT_SUB)
        Row() {
          Text('连续打卡 ').fontSize(13).fontColor(Colors.TEXT_SUB)
          Text(`${this.shareStreak}`).fontSize(15).fontWeight(FontWeight.Bold).fontColor(Colors.FUZZY_ORANGE)
          Text(' 天，继续保持').fontSize(13).fontColor(Colors.TEXT_SUB)
        }
        .margin({ bottom: 8 })

        Column() {
          SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE, buttonType: ButtonType.Capsule })
            .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
              this.onSaveClick(result);
            })
            .width('100%')
            .height(50)
        }
        .width('100%')
        .padding({ left: 22, right: 22 })

        Button('返回')
          .width('100%')
          .height(50)
          .fontSize(16)
          .fontColor(Colors.TEXT_SUB)
          .backgroundColor(Colors.WHITE)
          .borderRadius(16)
          .border({ width: 1, color: '#E2E6EE' })
          .margin({ left: 22, right: 22, bottom: 26, top: 2 })
          .onClick(() => this.closeSuccess())
      }
      .width('80%')
      .backgroundColor(Colors.WHITE)
      .borderRadius(28)
      .scale({ x: this.cardScale, y: this.cardScale })
      .opacity(this.overlayOpacity)
    }
    .width('100%')
    .height('100%')
  }

  /** 待机整页：无词本时整页只有空卡 + 导入入口，不渲染任务卡/日历/规则 */
  @Builder
  IdlePage() {
    Column() {
      Column({ space: 5 }) {
        Text('今日任务')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(Colors.TEXT_MAIN)
          .width('100%')
        Text('导入词表后自动生成')
          .fontSize(TypeScale.CAPTION)
          .fontColor(Colors.TEXT_WEAK)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 16, right: 16, top: 14 })

      Column({ space: 0 }) {
        Stack() {
          Circle({ width: 150, height: 150 }).fill('#F0F3F9')
          Text('0').fontSize(26).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_WEAK)
        }
        .width(150)
        .height(150)

        Text('还没有任务')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(Colors.TEXT_MAIN)
          .margin({ top: 20 })
        Text('导入一本词表后，任务会按你的节奏每天自动生成\n复习到期词 + 新学当日量')
          .fontSize(12.5)
          .fontColor(Colors.TEXT_WEAK)
          .lineHeight(21)
          .textAlign(TextAlign.Center)
          .margin({ top: 6 })
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)

      Column({ space: 10 }) {
        Button('拍照导入词表')
          .width('100%')
          .height(54)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .borderRadius(18)
          .linearGradient({ angle: 135, colors: [['#1E6BFB', 0], ['#0842B8', 1]] })
          .shadow({ radius: 16, color: 'rgba(10,89,247,0.28)', offsetY: 8 })
          .onClick(() => {
            NavStore.INSTANCE.push(RouteName.CAMERA);
          })
        Button('从词库选一本')
          .width('100%')
          .height(52)
          .fontSize(15)
          .fontColor(Colors.BRAND)
          .backgroundColor(Colors.WHITE)
          .borderRadius(18)
          .border({ width: 1.5, color: Colors.BRAND_SOFT })
          .onClick(() => {
            NavStore.INSTANCE.push(RouteName.MY_BOOKS);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: FloatingTab.CLEARANCE + 12 })
    }
    .width('100%')
    .height('100%')
    .opacity(this.enterOpacity)
    .translate({ y: this.enterTy })
  }

  build() {
    Stack() {
      Column() {
        if (!this.hasBooks()) {
          // 待机态：整页待机，不渲染任务卡 / 日历 / 规则
          this.IdlePage()
        } else {
          Scroll() {
          Column({ space: 16 }) {
            // 页头：今日任务（待机与任务态共用标题）
            Column({ space: 6 }) {
              Text('今日任务')
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .fontColor(Colors.TEXT_MAIN)
                .width('100%')
              Row({ space: 8 }) {
                Text(this.dateTitle())
                  .fontSize(TypeScale.CAPTION)
                  .fontColor(Colors.TEXT_WEAK)
                if (this.dailyGoal() > 0) {
                  Text(`每日新词 ${this.dailyGoal()}`)
                    .fontSize(10.5)
                    .fontColor(Colors.BRAND)
                    .backgroundColor(Colors.BRAND_SOFT)
                    .borderRadius(10)
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                }
              }
              .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')

            // 今日任务卡：复习 X + 新学 Y = 总量 Z（每日变量）
            Column({ space: 0 }) {
              Row() {
                Column({ space: 2 }) {
                  Row() {
                    Text(`${this.taskStat().total}`)
                      .fontSize(46)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(Colors.TEXT_MAIN)
                      .letterSpacing(-1)
                    Text(' 词 · 今日')
                      .fontSize(12)
                      .fontColor(Colors.TEXT_WEAK)
                      .margin({ bottom: 8 })
                  }
                  .alignItems(VerticalAlign.Bottom)

                  Text(this.taskSubText(this.taskStat()))
                    .fontSize(11.5)
                    .fontColor(Colors.TEXT_WEAK)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Column({ space: 0 }) {
                  Text(`${this.progressPct(this.taskStat())}%`)
                    .fontSize(19)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Colors.BRAND)
                  Text('今日进度')
                    .fontSize(9.5)
                    .fontColor(Colors.TEXT_WEAK)
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)

              Divider()
                .strokeWidth(1)
                .color('#EEF1F6')
                .margin({ top: 12 })

              this.TaskRow('到期复习', this.reviewHint(), this.taskStat().reviewDone,
                this.taskStat().reviewTotal, Colors.BRAND, 2)
              Divider().strokeWidth(1).color('#EEF1F6')
              this.TaskRow('新学单词', `按每日新词量 ${this.dailyGoal()} 排队`,
                this.taskStat().newDone, this.taskStat().newTotal, Colors.FUZZY_ORANGE, 1)

              if (DataStore.INSTANCE.gatesToday().p3Required) {
                Divider().strokeWidth(1).color('#EEF1F6')
                this.TaskRow('错词强化', `还剩 ${DataStore.INSTANCE.wrongEntries().length} 个错词待强化`,
                  DataStore.INSTANCE.gatesToday().p3 ? 1 : 0, 1, Colors.UNKNOWN_RED, 3)
              }

              if (this.taskStat().missed > 0 && !this.isChecked()) {
                Row({ space: 8 }) {
                  Text(`本月有 ${this.taskStat().missed} 天未打卡`)
                    .fontSize(11.5)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Colors.UNKNOWN_RED)
                  Blank()
                  Text('去计划表补卡 ›')
                    .fontSize(11.5)
                    .fontColor('#B96A6A')
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 9, bottom: 9 })
                .borderRadius(12)
                .backgroundColor('#FDF0F0')
                .margin({ top: 12 })
                .onClick(() => {
                  NavStore.INSTANCE.push(RouteName.PLAN_TABLE);
                })
              }

              this.GateButton()
            }
            .width('100%')
            .padding(16)
            .borderRadius(Radius.CARD)
            .backgroundColor(Colors.WHITE)
            .alignItems(HorizontalAlign.Start)

            // 艾宾浩斯迷你月历卡（与计划大表同源）
            Column({ space: 10 }) {
              Row() {
                Text('艾宾浩斯计划表')
                  .fontSize(TypeScale.CARD_TITLE)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Colors.TEXT_MAIN)
                  .layoutWeight(1)
                Text('详情')
                  .fontSize(TypeScale.CAPTION)
                  .fontColor(Colors.BRAND)
                  .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                  .borderRadius(12)
                  .backgroundColor(Colors.BRAND_SOFT)
              }
              .width('100%')
              .onClick(() => {
                NavStore.INSTANCE.push(RouteName.PLAN_TABLE);
              })

              Text(`${this.mini.year}年${this.mini.month}月`)
                .fontSize(TypeScale.CAPTION)
                .fontColor(Colors.TEXT_SUB)
                .width('100%')

              Row() {
                ForEach(this.weekNames, (w: string) => {
                  Text(w)
                    .fontSize(11)
                    .fontColor(Colors.TEXT_WEAK)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                }, (w: string) => w)
              }
              .width('100%')

              Grid() {
                ForEach(this.mini.cells, (cell: MonthCell) => {
                  GridItem() {
                    MiniCell({ cell, onTap: (c: MonthCell): void => this.onCellTap(c) })
                  }
                }, (cell: MonthCell) => `${this.miniVer}-${cell.day}`)
              }
              .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
              .columnsGap(5)
              .rowsGap(5)
              .width('100%')
              .scrollBar(BarState.Off)

              // 双行图例：状态 + 节点
              Flex({ wrap: FlexWrap.Wrap }) {
                this.LegendSwatch(Colors.KNOW_GREEN_SOFT, '已完成', true, false)
                this.LegendSwatch(Colors.BRAND, '今天', true, false)
                this.LegendSwatch(Colors.UNKNOWN_RED_SOFT, '待补卡', true, false)
                this.LegendSwatch(Colors.FUZZY_ORANGE, '已补卡', true, false)
              }
              .width('100%')
              .margin({ top: 2 })

              Flex({ wrap: FlexWrap.Wrap }) {
                this.LegendNode(Colors.STAGE_NEW, '新学', true)
                this.LegendNode(Colors.STAGE_R1, 'R1', false)
                this.LegendNode(Colors.STAGE_R2, 'R2', false)
                this.LegendNode(Colors.STAGE_R4, 'R4', false)
                this.LegendNode(Colors.STAGE_R7, 'R7', false)
                this.LegendNode(Colors.STAGE_R15, 'R15', false)
              }
              .width('100%')
            }
            .width('100%')
            .padding(16)
            .borderRadius(Radius.CARD)
            .backgroundColor(Colors.WHITE)
            .alignItems(HorizontalAlign.Start)

            // 补卡规则说明卡
            Column({ space: 6 }) {
              Text('补卡规则')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(Colors.FUZZY_ORANGE)
                .width('100%')
              Text('红格 = 今天之前欠的任务，点红格进入补卡，补完变绿底橙「补」；补卡不恢复连续天数，未来日期不能提前打卡。')
                .fontSize(12)
                .fontColor('#8A6A2F')
                .lineHeight(19)
                .width('100%')
            }
            .width('100%')
            .padding(14)
            .borderRadius(18)
            .backgroundColor(Colors.FUZZY_ORANGE_SOFT)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: FloatingTab.CLEARANCE })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
          }
      }
      .width('100%')
      .height('100%')

      if (this.showSuccess) {
        this.SuccessModal()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Colors.PAGE_BG)
    .opacity(this.enterOpacity + (this.tick + this.viewTick) * 0)
    .translate({ y: this.enterTy })
  }
}
