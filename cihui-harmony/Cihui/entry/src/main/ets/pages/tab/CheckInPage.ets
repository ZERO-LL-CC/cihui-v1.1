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
import { DailyQuote } from '../../common/DailyQuote';
import type { MakeupRouteParam, SpeechRouteParam } from '../../common/RouteNames';
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

/**
 * 小米笔记风方形勾选框。
 * 勾用 SVG 资源而不是 Path：真机实测 Path 会把超出自身包围盒的笔画裁掉，
 * 勾越大裁得越狠（26 的框里只剩左上角一小段），换成 Image 才能稳定撑满、居中。
 */
@ComponentV2
struct GateCheck {
  @Require @Param done: boolean;
  @Require @Param active: boolean;
  @Local pop: number = 0.6;

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
        this.pop = 1;
        return;
      }
      this.pop = 0.4;
      this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseOut }, () => {
        this.pop = 1;
      });
    } else {
      this.pop = 0.6;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.done) {
        Image($r('app.media.ic_check'))
          .width(17)
          .height(17)
          .fillColor(Color.White)
          .scale({ x: this.pop, y: this.pop })
      }
    }
    .width(26)
    .height(26)
    .borderRadius(8)
    .backgroundColor(this.done ? Colors.KNOW_GREEN : (this.active ? Colors.WHITE : '#F4F6FA'))
    .border(this.done
      ? { width: 0 }
      : { width: 1.5, color: this.active ? '#C6CDD9' : '#DDE2EA', style: BorderStyle.Solid })
  }
}

/** 打卡成功页的 88 圆绿底大对勾（勾占圆内约 52%，绿色圆盘先弹入，勾再跟上） */
@ComponentV2
struct SuccessCheck {
  @Local ring: number = 0.5;
  @Local pop: number = 0.5;

  aboutToAppear(): void {
    if (NavStore.INSTANCE.reducedMotion) {
      this.ring = 1;
      this.pop = 1;
      return;
    }
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
      this.ring = 1;
    });
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseOut }, () => {
        this.pop = 1;
      });
    }, 150);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Image($r('app.media.ic_check'))
        .width(46)
        .height(46)
        .fillColor(Color.White)
        .scale({ x: this.pop, y: this.pop })
    }
    .width(88)
    .height(88)
    .borderRadius(44)
    .backgroundColor(Colors.KNOW_GREEN)
    .scale({ x: this.ring, y: this.ring })
    .shadow({ radius: 18, color: 'rgba(31,191,107,0.32)', offsetY: 8 })
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
    // 13 的勾放在 42 高的格子里只剩一点绿，放到 16 才看得清
    Image($r('app.media.ic_check'))
      .width(16)
      .height(16)
      .fillColor(white ? Color.White : Colors.KNOW_GREEN)
      .margin({ top: 1 })
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
  @Local shareStreak: number = 0;
  @Local shareDateText: string = '';
  @Local shareNewDone: number = 0;
  @Local shareReviewDone: number = 0;
  /** 分享卡/成功页底部那句：10 条名句按每 10 天轮换 */
  @Local shareQuote: string = DailyQuote.current();
  @Local saving: boolean = false;
  /** 已生成好的分享卡缓存路径（成功页出现时预生成） */
  private cardPath: string = '';
  private preparing: boolean = false;
  @Local pressBtn: boolean = false;
  /** 显式刷新版本号，学习/打卡/补卡等数据变化后强制重算 */
  @Local viewTick: number = 0;
  @Local miniVer: number = 0;
  @Local mini: MonthGrid = this.buildMini();

  private readonly weekNames: string[] = ['一', '二', '三', '四', '五', '六', '日'];
  /** 水印行索引（只用来铺满 320×400 的斜向底纹） */
  private readonly wmRows: number[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
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
      const param: SpeechRouteParam = { wordIds: ids, reviewMode: 'REVIEW', title: '到期复习' };
      NavStore.INSTANCE.push(RouteName.SPEECH_TEST, param);
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
    // 已打卡但没有新任务（重新打卡态）时不重复弹成功页；重新打卡态放行
    if (DataStore.INSTANCE.isCheckedInToday() && !DataStore.INSTANCE.needsRecheckToday()) {
      return;
    }
    DataStore.INSTANCE.checkInToday();
    const stats = DataStore.INSTANCE.homeStats();
    this.shareStreak = DataStore.INSTANCE.streak();
    this.shareDateText = this.dateTitle();
    this.shareNewDone = stats.newDone;
    this.shareReviewDone = stats.reviewDone;
    this.shareQuote = DailyQuote.current();
    this.reloadMini();
    this.showSuccess = true;
    this.cardPath = '';
    // 成功页与离屏分享卡挂载完成后预生成图片，用户点保存时无需等待
    setTimeout(() => {
      this.prepareCard();
    }, 320);
  }

  private closeSuccess(): void {
    this.showSuccess = false;
    this.cardPath = '';
    this.reloadMini();
    NavStore.INSTANCE.goTab(1);
  }

  /**
   * 预生成带水印的分享卡写进缓存。
   * SaveButton 给的临时写权限只有几秒，截图本身要 2s 左右，
   * 所以图片提前备好，点击时只做「写入相册」这一步。
   */
  private async prepareCard(): Promise<void> {
    if (this.cardPath.length > 0 || this.preparing) {
      return;
    }
    this.preparing = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const fileName: string = `shuoci_checkin_${this.todayKey().replace(/-/g, '')}`;
      this.cardPath = await ShareService.snapshotByIdToJpg(ctx, 'shareCardHost', fileName);
    } catch (_e) {
      this.cardPath = '';
    } finally {
      this.preparing = false;
    }
  }

  private async doSaveCard(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      if (this.cardPath.length === 0) {
        await this.prepareCard();
      }
      if (this.cardPath.length === 0) {
        throw new Error('卡片生成失败，请重试');
      }
      // 必须在 SaveButton 点击回调链里调用，此刻临时写权限有效
      await ShareService.saveFileToGallery(ctx, this.cardPath);
      this.toast('已保存到相册，带说词水印');
    } catch (e) {
      const msg: string = (e as Error)?.message ?? '';
      this.toast(msg.indexOf('取消') >= 0 ? '已取消保存' : `保存失败：${msg || '请重试'}`);
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

  /** 卡内大按钮：已打卡（浅绿）/ 还差 N 词（灰）/ 完成今日打卡·重新打卡（蓝渐变）。
   *  已打卡后又进了新词（拍照/梗句导入排到今天）→ 门控重新变红，按钮重开为「重新打卡」。 */
  @Builder
  GateButton() {
    if (this.isChecked() && !DataStore.INSTANCE.needsRecheckToday()) {
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
        Text(this.isChecked()
          ? `还差 ${this.taskStat().left} 词 · 完成后重新打卡`
          : `还差 ${this.taskStat().left} 词 · 完成后可打卡`)
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
        Text(this.isChecked() ? '重新打卡' : '完成今日打卡')
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

  /** 水印层：斜向平铺「说词 SHUOCI」，被裁切的边缘反而说明是底纹而不是贴纸 */
  @Builder
  ShareWatermark() {
    Column({ space: 42 }) {
      ForEach(this.wmRows, (i: number) => {
        Text('说词 · SHUOCI · 说词 · SHUOCI · 说词')
          .fontSize(12).fontColor(Colors.WHITE).letterSpacing(3).maxLines(1)
      }, (i: number): string => `wm-${i}`)
    }
    .width(560)
    .margin({ left: -110, top: -40 })
    .rotate({ angle: -20 })
    .opacity(0.11)
  }

  /** 印章：右上角斜盖的圆章，是这张图"出自说词"的唯一凭据 */
  @Builder
  ShareSeal() {
    Stack() {
      Circle({ width: 54, height: 54 })
        .fill(Color.Transparent)
        .stroke('rgba(255,255,255,0.55)')
        .strokeWidth(1.2)
      Circle({ width: 46, height: 46 })
        .fill(Color.Transparent)
        .stroke('rgba(255,255,255,0.28)')
        .strokeWidth(0.8)
      Column({ space: 0 }) {
        Text('说').fontSize(13).fontColor('rgba(255,255,255,0.92)').fontWeight(FontWeight.Bold)
        Text('词').fontSize(13).fontColor('rgba(255,255,255,0.92)').fontWeight(FontWeight.Bold)
      }
    }
    .width(54).height(54)
    .rotate({ angle: -11 })
    .opacity(0.85)
  }

  @Builder
  ShareCard() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.ShareWatermark()

      Column({ space: 16 }) {
        Column({ space: 6 }) {
          Text('说词')
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

        // 底部署名：左边一句话名句（10 天轮换一次），右边字标，形成「品牌落款」而不是随便一行小字
        Row() {
          Text(this.shareQuote)
            .fontSize(11.5)
            .fontColor('#C9DAFF')
            .layoutWeight(1)
          Text('SHUOCI')
            .fontSize(9)
            .fontColor('rgba(255,255,255,0.6)')
            .letterSpacing(2.5)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 22 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 26, right: 26 })

      // 印章压在右上，和标题错开不打架
      Column() {
        this.ShareSeal()
      }
      .width('100%')
      .alignItems(HorizontalAlign.End)
      .padding({ right: 20, top: 20 })
    }
    .width(320)
    .height(400)
    .borderRadius(24)
    .clip(true)
    .linearGradient({
      angle: 160,
      colors: [['#2F74FF', 0], ['#0A59F7', 0.55], ['#0846C0', 1]]
    })
  }

  /** 成功页的数字块 */
  @Builder
  StatTile(value: number, label: string) {
    Column({ space: 3 }) {
      Text(`${value}`)
        .fontSize(26).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
      Text(label).fontSize(11).fontColor(Colors.TEXT_WEAK)
    }
    .layoutWeight(1)
    .padding({ top: 16, bottom: 16 })
    .backgroundColor(Colors.WHITE).borderRadius(16)
    .border({ width: 1, color: Colors.DIVIDER })
  }

  /** 打卡成功：整页成功态（不覆盖在原页面上，覆盖层的点击会被页面图层吃掉） */
  @Builder
  SuccessPage() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 分享卡离屏宿主：截图要求节点真实挂载并渲染，
      // 所以压在不透明页面层下面（用户看不见），而不是丢到屏幕外（可能被渲染层裁掉）
      Column() {
        this.ShareCard()
      }
      .width(320)
      .height(400)
      .id('shareCardHost')

      this.SuccessBody()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SuccessBody() {
    Column() {
      Blank()

      Column() {
        SuccessCheck()
      }

      Text('打卡成功')
        .fontSize(30).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .margin({ top: 20 })
      if (this.shareDateText.length > 0) {
        Text(this.shareDateText)
          .fontSize(12.5).fontColor(Colors.TEXT_WEAK).margin({ top: 8 })
      }

      Row() {
        Text('连续打卡 ').fontSize(13).fontColor(Colors.TEXT_SUB)
        Text(`${this.shareStreak}`)
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor(Colors.FUZZY_ORANGE)
        Text(' 天').fontSize(13).fontColor(Colors.TEXT_SUB)
      }
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 14 })

      Row({ space: 10 }) {
        this.StatTile(this.shareNewDone, '今日新词')
        this.StatTile(this.shareReviewDone, '完成复习')
      }
      .width('100%').margin({ top: 26 })

      // 名句上移到内容区，底部只留可点区域 —— 底部要留给「保存图片 / 返回首页」足够的空气
      Text(this.shareQuote)
        .fontSize(12).fontColor(Colors.TEXT_WEAK).margin({ top: 18 })
        .textAlign(TextAlign.Center)

      Blank()

      // 写相册走安全控件 SaveButton：点击的瞬间系统临时授予 WRITE_IMAGEVIDEO，
      // 既不用申请受限权限，也不弹「保存确认框」（本机型上 showAssetsCreationDialog 稳定返回 14000011）
      SaveButton({ text: SaveDescription.SAVE_IMAGE, buttonType: ButtonType.Capsule })
        .iconSize(19)
        .fontSize(16)
        .fontColor(Colors.WHITE)
        .backgroundColor(this.saving ? Colors.TEXT_WEAK : Colors.BRAND)
        .width('100%')
        .height(52)
        .borderRadius(Radius.BUTTON)
        .enabled(!this.saving)
        .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
          if (result === SaveButtonOnClickResult.SUCCESS) {
            this.doSaveCard();
          } else {
            this.toast('未获得相册写入授权，请再点一次');
          }
        })

      Text(this.saving ? '正在生成带水印的卡片…' : '保存的是带「说词」水印的卡片')
        .fontSize(10.5).fontColor(Colors.TEXT_WEAK).margin({ top: 8 })

      Text('返回首页')
        .fontSize(14).fontColor(Colors.TEXT_SUB)
        .width('100%').height(48).margin({ top: 4 })
        .textAlign(TextAlign.Center).borderRadius(Radius.BUTTON)
        .onClick(() => this.closeSuccess())
    }
    .width('100%').height('100%')
    // CLEARANCE 已含悬浮 Tab 的栏体高与手势条安全间距，再留 10 的呼吸位：
    // 底部按钮必须停在 Tab 胶囊上沿之上，手指不会滑进系统手势区
    .padding({ left: 24, right: 24, top: 20, bottom: FloatingTab.CLEARANCE + 10 })
    .backgroundColor(Colors.PAGE_BG)
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
      .visibility(this.showSuccess ? Visibility.None : Visibility.Visible)

      // 打卡成功：换成整页成功态而不是覆盖层。
      // 覆盖层在这个页面里会被页面的 opacity/translate 图层吃掉点击（真机上表现为「按钮点了没反应」）。
      if (this.showSuccess) {
        this.SuccessPage()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Colors.PAGE_BG)
    .opacity(this.enterOpacity + (this.tick + this.viewTick) * 0)
    .translate({ y: this.enterTy })
  }
}
