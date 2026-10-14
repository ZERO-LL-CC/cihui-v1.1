/**
 * F11 打卡页 · 前置条件实时判定 · 打卡成功弹层 · 艾宾浩斯小日历
 *
 * - 三项前置（P1 今日新词 / P2 到期复习 / P3 错词强化每 5 天）实时复算，
 *   达标行小米笔记风：对勾 200ms 描边出现 + 删除线变暗 + 整行浅绿；
 * - 未全部达标前打卡按钮置灰，文案「还差 N 项，去完成」，点按钮/点行直达缺口；
 * - 打卡当日幂等；成功弹层遮罩 280ms 淡入 + 卡片 .8→1 弹入，可保存分享图到相册
 *   （SaveButton 安全组件授权 + componentSnapshot 离屏快照，无礼花）；
 * - 页内小日历与 F12 计划大表同源，「放大」「日历」缩放进入计划大表，补卡四端同步。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
import type { ReviewRouteParam } from '../../common/RouteNames';
import type { CheckInRecord, Word } from '../../model/Types';
import { ShareService } from '../../service/ShareService';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

/** 小日历格子状态：0 普通/锁定，1 今天，2 已打卡，3 补卡，4 逾期 */
class CalCell {
  key: string = '';
  num: number = 0;
  state: number = 0;
  idx: number = 0;
}

/** 前置条件行视图数据 */
class GateView {
  kind: number = 0; // 1 P1 / 2 P2 / 3 P3
  title: string = '';
  subtitle: string = '';
  done: boolean = false;
  active: boolean = true; // false = P3 非轮到日 ghost
}

@ComponentV2
export struct CheckInPage {
  @Require @Param active: boolean;
  /** 导航版本号：从新词/复习/错词流程返回时实时重算前置条件与小日历（动态QA BUG-02） */
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
  /** 动态QA：显式刷新版本号，学习/打卡/补卡等数据变化后强制重算前置条件与日历 */
  @Local viewTick: number = 0;

  private readonly weekNames: string[] = ['一', '二', '三', '四', '五', '六', '日'];
  private refreshWhenActive: RefreshListener = (): void => {
    if (this.active) {
      this.viewTick++;
    }
  };

  @Monitor('active')
  onActiveChange(): void {
    if (this.active) {
      this.playEnter();
      this.viewTick++;
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

  private formatMonthDay(day: string): string {
    const parts: string[] = day.split('-');
    return `${Number(parts[1])}月${Number(parts[2])}日`;
  }

  private dateTitle(): string {
    const d: Date = new Date();
    const w: string = ['日', '一', '二', '三', '四', '五', '六'][d.getDay()];
    return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日 星期${w}`;
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
        p3Row.subtitle = `今天不轮到，下次轮到 ${this.formatMonthDay(p3.nextDay)}`;
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
      NavStore.INSTANCE.push(RouteName.NEW_WORDS);
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
      // 动态QA BUG-06：打卡成功后本页不会随 @Trace 数据变更重绘（连续天数、CTA 仍旧），
      // 关闭弹层后强制重挂载打卡 Tab，新实例首次 build 读到最新打卡状态
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

  /** 本月日历格子（含前置空白） */
  private buildCalendar(): CalCell[] {
    const now: Date = new Date();
    const y: number = now.getFullYear();
    const m: number = now.getMonth(); // 0-based
    const today: string = this.todayKey();
    const daysInMonth: number = new Date(y, m + 1, 0).getDate();
    const lead: number = (new Date(y, m, 1).getDay() + 6) % 7;

    const map: Map<string, CheckInRecord> = new Map();
    let firstActive: string = '';
    for (const c of DataStore.INSTANCE.checkins) {
      map.set(c.day, c);
      if (c.checkedIn && (firstActive === '' || c.day < firstActive)) {
        firstActive = c.day;
      }
    }
    for (const s of DataStore.INSTANCE.schedules) {
      if (s.firstLearnDay !== '' && (firstActive === '' || s.firstLearnDay < firstActive)) {
        firstActive = s.firstLearnDay;
      }
    }

    const cells: CalCell[] = [];
    let cellIdx: number = 0;
    for (let i = 0; i < lead; i++) {
      const blank = new CalCell();
      blank.idx = cellIdx;
      cellIdx += 1;
      cells.push(blank);
    }
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    for (let dNum = 1; dNum <= daysInMonth; dNum++) {
      const key: string = `${y}-${pad(m + 1)}-${pad(dNum)}`;
      const cell = new CalCell();
      cell.key = key;
      cell.num = dNum;
      const rec: CheckInRecord | undefined = map.get(key);
      if (key === today) {
        cell.state = rec && rec.checkedIn ? 2 : 1;
      } else if (rec && rec.checkedIn) {
        cell.state = rec.makeup ? 3 : 2;
      } else if (key < today && firstActive !== '' && key >= firstActive) {
        cell.state = 4;
      } else {
        cell.state = 0;
      }
      cell.idx = cellIdx;
      cellIdx += 1;
      cells.push(cell);
    }
    return cells;
  }

  private monthTitle(): string {
    const d: Date = new Date();
    return `${d.getFullYear()}年${d.getMonth() + 1}月`;
  }

  @Builder
  GateCheckbox(done: boolean, active: boolean) {
    Stack() {
      if (done) {
        Text('✓')
          .fontSize(15)
          .fontColor(Colors.WHITE)
          .fontWeight(FontWeight.Bold)
          .scale({ x: 1, y: 1 })
      } else {
        Text('✓')
          .fontSize(15)
          .fontColor(Colors.WHITE)
          .fontWeight(FontWeight.Bold)
          .scale({ x: 0.01, y: 0.01 })
      }
    }
    .width(26)
    .height(26)
    .borderRadius(8)
    .backgroundColor(done ? Colors.KNOW_GREEN : (active ? Colors.WHITE : '#F2F4F8'))
    .border(done
      ? { width: 0 }
      : { width: 1.5, color: active ? '#C6CDD9' : '#DDE2EA' })
  }

  @Builder
  GateRow(row: GateView) {
    Row({ space: 12 }) {
      this.GateCheckbox(row.done, row.active)
      Column({ space: 3 }) {
        Text(row.title)
          .fontSize(TypeScale.BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(row.done ? Colors.TEXT_WEAK : (row.active ? Colors.TEXT_MAIN : Colors.TEXT_WEAK))
          .decoration({ type: row.done ? TextDecorationType.LineThrough : TextDecorationType.None })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(row.subtitle)
          .fontSize(TypeScale.CAPTION)
          .fontColor(row.done ? Colors.KNOW_GREEN : Colors.TEXT_WEAK)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (row.active && !row.done) {
        Text('去完成')
          .fontSize(TypeScale.CAPTION)
          .fontColor(Colors.BRAND)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor(Colors.BRAND_SOFT)
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor(row.done ? Colors.KNOW_GREEN_SOFT : Colors.WHITE)
    .opacity(row.active ? 1 : 0.72)
    .onClick(() => {
      if (row.active && !row.done) {
        this.jumpGap(row.kind);
      }
    })
    .animation({ duration: NavStore.INSTANCE.reducedMotion ? 0 : 200, curve: Curve.EaseOut })
  }

  /** P1：已打卡状态条——与前置条件行同一套 UI（绿勾 + 删除线变暗 + 浅绿底），
   *  内嵌在内容流里，不再用悬浮大按钮压住日历卡 */
  @Builder
  CheckedInBar() {
    Column() {
      Row({ space: 12 }) {
        this.GateCheckbox(true, true)
        Column({ space: 3 }) {
          Text('今日打卡')
            .fontSize(TypeScale.BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor(Colors.TEXT_WEAK)
            .decoration({ type: TextDecorationType.LineThrough })
            .maxLines(1)
          Text('已完成，明天继续保持')
            .fontSize(TypeScale.CAPTION)
            .fontColor(Colors.KNOW_GREEN)
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('✓')
          .fontSize(16)
          .fontColor(Colors.KNOW_GREEN)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .padding(14)
      .borderRadius(16)
      .backgroundColor(Colors.KNOW_GREEN_SOFT)
    }
    .width('100%')
    .padding(16)
    .borderRadius(Radius.CARD)
    .backgroundColor(Colors.WHITE)
  }

  @Builder
  CalCellView(cell: CalCell) {
    Column() {
      if (cell.num === 0) {
        Text('')
      } else if (cell.state === 2) {
        Text('✓')
          .fontSize(13)
          .fontColor(Colors.WHITE)
          .fontWeight(FontWeight.Bold)
      } else if (cell.state === 3) {
        Text('补')
          .fontSize(11)
          .fontColor(Colors.FUZZY_ORANGE)
          .fontWeight(FontWeight.Bold)
      } else {
        Text(`${cell.num}`)
          .fontSize(13)
          .fontColor(cell.state === 1 ? Colors.WHITE : (cell.state === 4 ? Colors.FUZZY_ORANGE : '#9AA3B2'))
      }
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(cell.state === 1 ? Colors.BRAND
      : (cell.state === 2 ? Colors.KNOW_GREEN
        : (cell.state === 3 ? Colors.FUZZY_ORANGE_SOFT : '#00000000')))
    .margin({ top: 4, bottom: 4 })
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
      // 遮罩
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')
        .opacity(this.overlayOpacity)
        .onClick(() => this.closeSuccess())

      // 卡片
      Column({ space: 14 }) {
        Stack() {
          Text('✓')
            .fontSize(34)
            .fontColor(Colors.KNOW_GREEN)
            .fontWeight(FontWeight.Bold)
        }
        .width(72)
        .height(72)
        .borderRadius(36)
        .backgroundColor(Colors.KNOW_GREEN_SOFT)
        .border({ width: 2, color: Colors.KNOW_GREEN })
        .margin({ top: 26 })

        Text('打卡成功')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Colors.TEXT_MAIN)
        Text(`已连续打卡 ${this.shareStreak} 天，继续保持`)
          .fontSize(TypeScale.CAPTION)
          .fontColor(Colors.TEXT_SUB)
          .margin({ bottom: 6 })

        Column() {
          SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE, buttonType: ButtonType.Capsule })
            .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
              this.onSaveClick(result);
            })
            .width('100%')
            .height(46)
        }
        .width('100%')
        .padding({ left: 22, right: 22 })

        Button('返回')
          .width('100%')
          .height(46)
          .fontSize(16)
          .fontColor(Colors.TEXT_SUB)
          .backgroundColor('#F2F4F8')
          .borderRadius(Radius.BUTTON)
          .margin({ left: 22, right: 22, bottom: 24, top: 4 })
          .onClick(() => this.closeSuccess())
      }
      .width('78%')
      .backgroundColor(Colors.WHITE)
      .borderRadius(Radius.SHEET)
      .scale({ x: this.cardScale, y: this.cardScale })
      .opacity(this.overlayOpacity)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      // BUG-A 二次修复：按钮放到 Column 纵向流底部（Scroll layoutWeight 撑满），
      // 不再依赖 Stack 子元素 .align（实测在 TabContent 内不生效，按钮仍居中压卡）
      Column() {
        Scroll() {
          Column({ space: 16 }) {
          // 标题区
          Column({ space: 6 }) {
            Text('今日打卡')
              .fontSize(TypeScale.TITLE_LARGE)
              .fontWeight(FontWeight.Bold)
              .fontColor(Colors.TEXT_MAIN)
              .width('100%')
            Text(this.dateTitle())
              .fontSize(TypeScale.CAPTION)
              .fontColor(Colors.TEXT_WEAK)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 连续天数卡
          Row({ space: 10 }) {
            Image($r('app.media.ic_flame'))
              .width(22)
              .height(22)
              .fillColor(Colors.FUZZY_ORANGE)
            Text(`已连续打卡 ${DataStore.INSTANCE.streak()} 天`)
              .fontSize(TypeScale.CARD_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor(Colors.TEXT_MAIN)
              .layoutWeight(1)
            Text('日历 ›')
              .fontSize(TypeScale.CAPTION)
              .fontColor(Colors.TEXT_WEAK)
          }
          .width('100%')
          .padding(16)
          .borderRadius(Radius.CARD)
          .backgroundColor(Colors.WHITE)
          .onClick(() => {
            NavStore.INSTANCE.push(RouteName.PLAN_TABLE);
          })

          // 前置条件卡
          Column({ space: 4 }) {
            Row() {
              Text('今日前置条件')
                .fontSize(TypeScale.CARD_TITLE)
                .fontWeight(FontWeight.Bold)
                .fontColor(Colors.TEXT_MAIN)
                .layoutWeight(1)
              Text('全部完成才能打卡')
                .fontSize(TypeScale.CAPTION)
                .fontColor(Colors.TEXT_WEAK)
            }
            .width('100%')
            .margin({ bottom: 8 })

            ForEach(this.buildGates(), (row: GateView) => {
              this.GateRow(row)
            }, (row: GateView) => `${row.kind}-${row.done}-${row.active}-${row.subtitle}`)
          }
          .width('100%')
          .padding(16)
          .borderRadius(Radius.CARD)
          .backgroundColor(Colors.WHITE)
          .alignItems(HorizontalAlign.Start)

          // P1：已打卡时在前置条件卡下方显示同风格完成条，替代原悬浮大按钮
          if (DataStore.INSTANCE.isCheckedInToday()) {
            this.CheckedInBar()
          }

          // 小日历卡
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
            }
            .width('100%')
            .onClick(() => {
              NavStore.INSTANCE.push(RouteName.PLAN_TABLE);
            })

            Text(this.monthTitle())
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
              ForEach(this.buildCalendar(), (cell: CalCell) => {
                GridItem() {
                  this.CalCellView(cell)
                }
              }, (cell: CalCell) => cell.key === '' ? `blank-${cell.idx}` : cell.key)
            }
            .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
            .height(264)
            .width('100%')
            .scrollBar(BarState.Off)

            Row({ space: 14 }) {
              this.LegendDot(Colors.KNOW_GREEN, '已打卡')
              this.LegendDot(Colors.BRAND, '今天')
              this.LegendDot(Colors.FUZZY_ORANGE, '逾期')
              Text('补 = 补卡').fontSize(10).fontColor(Colors.TEXT_WEAK)
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .borderRadius(Radius.CARD)
          .backgroundColor(Colors.WHITE)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 24 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      // 底部打卡按钮：已打卡后不再悬浮遮挡日历（P1）；BUG-A：固定在纵向流底部
      if (!DataStore.INSTANCE.isCheckedInToday()) {
        Column() {
          this.BottomButton()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 132 })
        .linearGradient({
          angle: 180,
          colors: [['rgba(237,240,246,0)', 0], ['rgba(237,240,246,0.92)', 0.4], ['#EDF0F6', 1]]
        })
        .justifyContent(FlexAlign.End)
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

  @Builder
  LegendDot(color: string, label: string) {
    Row({ space: 4 }) {
      Circle({ width: 8, height: 8 }).fill(color)
      Text(label).fontSize(10).fontColor(Colors.TEXT_WEAK)
    }
  }

  @Builder
  BottomButton() {
    // 已打卡态由内容流里的 CheckedInBar 承担，此处只渲染未打卡的两种状态
    if (this.missingCount(this.buildGates()) > 0) {
      Row() {
        Text(`还差 ${this.missingCount(this.buildGates())} 项，去完成`)
          .fontSize(17)
          .fontColor(Colors.WHITE)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .height(52)
      .borderRadius(Radius.BUTTON)
      .backgroundColor('#B9C2D0')
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        for (const r of this.buildGates()) {
          if (r.active && !r.done) {
            this.jumpGap(r.kind);
            break;
          }
        }
      })
    } else {
      Row() {
        Text('完成今日打卡')
          .fontSize(17)
          .fontColor(Colors.WHITE)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .height(52)
      .borderRadius(Radius.BUTTON)
      .backgroundColor(Colors.BRAND)
      .justifyContent(FlexAlign.Center)
      .onClick(() => this.doCheckin())
      .animation({ duration: NavStore.INSTANCE.reducedMotion ? 0 : 200, curve: Curve.EaseOut })
    }
  }
}
