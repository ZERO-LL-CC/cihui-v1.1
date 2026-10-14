/**
 * F9 到期复习 · 闪卡三档判定（F10 错词强化复用本页，mode='WRONG'）
 *
 * 交互（严格对齐功能卡 F9）：
 * - 中央闪卡：正面英文 + 音标 + 喇叭，轻点卡片 3D 翻转 550ms 显示中文释义；
 *   常规复习必须翻过面才允许判定，未翻面判定给提示，防止误判。
 *   错词强化（mode='WRONG'）以快速过完为准：认识/不认识免翻面直接判定，
 *   判「模糊」时自动翻到中文面、不判定，用户看完再判一次。
 * - 右滑 = 认识（跟手染绿，过阈值向右飞出 280ms，推进下一节点）；
 *   上滑超过 90vp = 模糊（染橙淡出，从牌堆底部重新入队，本轮循环到认识为止，
 *   调度上停留当前节点且次日强制再考）；
 *   左滑 = 不认识（染红飞出 + Toast「已加入错词本」+ 轻震动，清零、次日当新词、入错词本）。
 * - 屏幕左缘 22vp 内起手的横移交给系统返回手势，本页 PanGesture 直接忽略，不劫持系统热区。
 * - 三个手势都有底部等价按钮；每张卡判定实时写 F2 调度（DataStore.applyJudge）。
 * - 一轮必须全部过完（含模糊重考）才显示完成页，P2/P3 达标状态与首页、打卡页同源刷新。
 *
 * 说明：本期数据模型无例句库（PRD 明确不做例句），翻面仅展示中文释义。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import type { Word, Verdict } from '../../model/Types';
import { TtsService } from '../../service/TtsService';
import type { TtsState } from '../../service/TtsService';
import { RouteName } from '../../common/RouteNames';
import type { ReviewRouteParam } from '../../common/RouteNames';
import { promptAction } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

/** 一张闪卡的页面态（flipped=是否已经翻过面，模糊重考后重置） */
@ObservedV2
class ReviewCard {
  wordId: string;
  english: string;
  phonetic: string;
  meanings: string[];
  @Trace flipped: boolean = false;

  constructor(word: Word) {
    this.wordId = word.id;
    this.english = word.english;
    this.phonetic = word.phonetic;
    this.meanings = word.meanings;
  }
}

type TintKind = '' | 'green' | 'orange' | 'red';

@ComponentV2
export struct ReviewCardsPage {
  @Require @Param param: ReviewRouteParam;
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.REVIEW_CARDS) {
      this.showTick++;
    }
  };
  @Local sheetOpacity: number = 0;

  @Local queue: ReviewCard[] = [];
  @Local finished: boolean = false;
  @Local ttsState: TtsState = 'idle';

  // 顶部进度统计
  private total: number = 0;
  @Local knownCount: number = 0;
  @Local vagueCount: number = 0;
  @Local unknownCount: number = 0;

  // 正面卡翻面角度（0=英文面，180=中文面）
  @Local flipAngle: number = 0;
  // 跟手拖拽
  @Local dragX: number = 0;
  @Local dragY: number = 0;
  @Local dragRot: number = 0;
  @Local dragOpacity: number = 1;
  @Local tint: TintKind = '';

  private flying: boolean = false;
  private edgeBlocked: boolean = false;
  private speakTimer: number = -1;
  private advanceTimer: number = -1;

  private static readonly EDGE_ZONE_VP: number = 22;
  private static readonly H_THRESHOLD_VP: number = 110;
  private static readonly V_THRESHOLD_VP: number = 90;
  private static readonly FLY_DISTANCE_VP: number = 520;

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    const cards: ReviewCard[] = [];
    this.param.wordIds.forEach((id: string): void => {
      const w: Word | undefined = DataStore.INSTANCE.words.find((x: Word): boolean => x.id === id);
      if (w !== undefined) {
        cards.push(new ReviewCard(w));
      }
    });
    this.queue = cards;
    this.total = cards.length;
    const rate: number = DataStore.INSTANCE.settings.ttsRate;
    TtsService.init(rate).then((state: TtsState): void => {
      this.ttsState = state;
      this.scheduleSpeak(350);
    });
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
    if (this.speakTimer !== -1) {
      clearTimeout(this.speakTimer);
      this.speakTimer = -1;
    }
    if (this.advanceTimer !== -1) {
      clearTimeout(this.advanceTimer);
      this.advanceTimer = -1;
    }
    TtsService.stop();
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

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 1600 });
    } catch (e) {
      console.warn(`[ReviewCards] toast failed: ${(e as Error)?.message ?? e}`);
    }
  }

  private haptic(): void {
    if (!DataStore.INSTANCE.settings.hapticEnabled) {
      return;
    }
    try {
      vibrator.startVibration(
        { type: 'preset', effectId: 'haptic.clock.timer', count: 1 },
        { id: 0, usage: 'unknown' }
      );
    } catch (e) {
      console.warn(`[ReviewCards] vibrate failed: ${(e as Error)?.message ?? e}`);
    }
  }

  private scheduleSpeak(delay: number): void {
    if (this.speakTimer !== -1) {
      clearTimeout(this.speakTimer);
    }
    if (this.queue.length === 0 || this.finished) {
      return;
    }
    const text: string = this.queue[0].english;
    this.speakTimer = setTimeout(() => {
      this.speakTimer = -1;
      const ok: boolean = TtsService.speak(text);
      if (!ok && this.ttsState === 'ready') {
        this.ttsState = 'unavailable';
      }
    }, delay);
  }

  private replay(): void {
    if (this.queue.length === 0) {
      return;
    }
    if (this.ttsState === 'unavailable' || this.ttsState === 'initializing') {
      this.toast('语音引擎未就绪，可直接看英文继续复习');
      return;
    }
    if (!TtsService.speak(this.queue[0].english)) {
      this.toast('朗读失败，请检查设备语音引擎后重试');
    }
  }

  /** 轻点翻面（3D 翻转 550ms） */
  private toggleFlip(): void {
    if (this.flying || this.queue.length === 0) {
      return;
    }
    const card: ReviewCard = this.queue[0];
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : 550, curve: Curve.EaseInOut },
      () => {
        this.flipAngle = card.flipped ? 0 : 180;
      }
    );
    card.flipped = true;
  }

  private resetDrag(): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : Motion.FEEDBACK, curve: Curve.EaseOut },
      () => {
        this.dragX = 0;
        this.dragY = 0;
        this.dragRot = 0;
        this.dragOpacity = 1;
        this.tint = '';
      }
    );
  }

  /** 判定落库：实时写 F2 调度（复习轮 phase='REVIEW'，错词强化同样走这里，
   *  judge 对 status=WRONG 的词判认识会按「重新首过」推进到 R1） */
  private applyVerdict(wordId: string, verdict: Verdict): void {
    DataStore.INSTANCE.applyJudge(wordId, 'REVIEW', verdict);
    if (verdict === 'KNOWN') {
      this.knownCount += 1;
    } else if (verdict === 'VAGUE') {
      this.vagueCount += 1;
    } else {
      this.unknownCount += 1;
    }
  }

  /**
   * 处理一张卡的判定结果与动画。
   * direction：right=认识飞出；up=模糊上飘重排；left=不认识飞出；none=按钮触发（按判定上色）
   */
  private resolve(card: ReviewCard, verdict: Verdict, direction: string): void {
    if (this.flying) {
      return;
    }
    const wrongMode: boolean = this.param.mode === 'WRONG';
    if (!card.flipped) {
      if (wrongMode && verdict === 'VAGUE') {
        // P2：错词强化里判「模糊」不直接判，自动翻到中文面让用户先看中文
        this.resetDrag();
        this.toggleFlip();
        this.toast('先看中文释义，确认后再判一次');
        return;
      }
      if (!wrongMode) {
        // 常规复习必须先翻面，防止误判
        this.toast('请先轻点卡片翻面，查看中文释义');
        this.resetDrag();
        return;
      }
      // P2：错词强化里「认识 / 不认识」免翻面，直接判定快速过完
    }
    this.flying = true;
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;

    if (verdict === 'VAGUE') {
      this.toast('模糊，本轮稍后重考');
    } else if (verdict === 'UNKNOWN') {
      this.toast(wrongMode ? '已安排明天重新背' : '已加入错词本');
      this.haptic();
    }

    // 飞出/上飘动画
    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : 280, curve: Curve.EaseIn },
      () => {
        if (verdict === 'KNOWN') {
          this.dragX = direction === 'none' ? 0 : ReviewCardsPage.FLY_DISTANCE_VP;
          this.dragOpacity = 0;
          this.tint = 'green';
        } else if (verdict === 'UNKNOWN') {
          this.dragX = direction === 'none' ? 0 : -ReviewCardsPage.FLY_DISTANCE_VP;
          this.dragOpacity = 0;
          this.tint = 'red';
        } else {
          this.dragY = -ReviewCardsPage.FLY_DISTANCE_VP;
          this.dragOpacity = 0;
          this.tint = 'orange';
        }
        this.dragRot = verdict === 'KNOWN' ? 18 : verdict === 'UNKNOWN' ? -18 : 0;
      }
    );

    this.applyVerdict(card.wordId, verdict);

    this.advanceTimer = setTimeout(() => {
      this.advanceTimer = -1;
      this.advance(card, verdict);
    }, reduced ? 120 : 300);
  }

  /** 动画结束后推进队列：模糊卡从底部重新入队并重置翻面，其余移除 */
  private advance(card: ReviewCard, verdict: Verdict): void {
    const next: ReviewCard[] = this.queue.slice(1);
    if (verdict === 'VAGUE') {
      card.flipped = false;
      next.push(card);
    }
    this.queue = next;
    this.dragX = 0;
    this.dragY = 0;
    this.dragRot = 0;
    this.dragOpacity = 1;
    this.tint = '';
    this.flipAngle = 0;
    this.flying = false;
    if (next.length === 0) {
      this.finished = true;
      TtsService.stop();
    } else {
      this.scheduleSpeak(320);
    }
  }

  private onPanStart(globalX: number): void {
    // 屏幕左缘 22vp 内起手：交给系统边缘返回，本页不响应
    this.edgeBlocked = globalX <= vp2px(ReviewCardsPage.EDGE_ZONE_VP);
  }

  private onPanUpdate(offsetX: number, offsetY: number): void {
    if (this.flying || this.edgeBlocked || this.queue.length === 0) {
      return;
    }
    this.dragX = offsetX;
    this.dragY = offsetY;
    this.dragRot = offsetX * 0.04;
    this.dragOpacity = 1 - Math.min(Math.abs(offsetX), 240) / 640;
    if (offsetY < -ReviewCardsPage.V_THRESHOLD_VP && Math.abs(offsetY) > Math.abs(offsetX)) {
      this.tint = 'orange';
    } else if (offsetX > ReviewCardsPage.H_THRESHOLD_VP) {
      this.tint = 'green';
    } else if (offsetX < -ReviewCardsPage.H_THRESHOLD_VP) {
      this.tint = 'red';
    } else {
      this.tint = '';
    }
  }

  private onPanEnd(offsetX: number, offsetY: number): void {
    if (this.edgeBlocked) {
      this.edgeBlocked = false;
      return;
    }
    if (this.queue.length === 0) {
      return;
    }
    const card: ReviewCard = this.queue[0];
    if (offsetY < -ReviewCardsPage.V_THRESHOLD_VP && Math.abs(offsetY) > Math.abs(offsetX)) {
      this.resolve(card, 'VAGUE', 'up');
    } else if (offsetX > ReviewCardsPage.H_THRESHOLD_VP) {
      this.resolve(card, 'KNOWN', 'right');
    } else if (offsetX < -ReviewCardsPage.H_THRESHOLD_VP) {
      this.resolve(card, 'UNKNOWN', 'left');
    } else {
      this.resetDrag();
    }
  }

  private pressVerdict(verdict: Verdict): void {
    if (this.queue.length === 0 || this.flying) {
      return;
    }
    const dir: string = verdict === 'KNOWN' ? 'right' : verdict === 'UNKNOWN' ? 'left' : 'up';
    this.resolve(this.queue[0], verdict, dir);
  }

  private tintBorderColor(): ResourceColor {
    if (this.tint === 'green') {
      return Colors.KNOW_GREEN;
    }
    if (this.tint === 'red') {
      return Colors.UNKNOWN_RED;
    }
    if (this.tint === 'orange') {
      return Colors.FUZZY_ORANGE;
    }
    return Colors.WHITE;
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())

      Text(this.param.title)
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Row().width(44).height(44)
    }
    .width('100%')
    .height(56)
  }

  @Builder
  CardFace(card: ReviewCard, back: boolean) {
    Column() {
      if (back) {
        // 背面：中文释义
        Text(card.english)
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_SUB)
          .maxLines(1)
        Text(card.phonetic)
          .fontSize(12).fontColor(Colors.TEXT_WEAK).margin({ top: 4 })
        Divider().color(Colors.DIVIDER).width('70%').margin({ top: 16, bottom: 18 })
        Text(card.meanings.join('；'))
          .fontSize(24).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
          .textAlign(TextAlign.Center).maxLines(6).width('84%')
        Blank()
        Text('再轻点卡片可翻回英文面')
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_WEAK).margin({ bottom: 10 })
      } else {
        // 正面：英文 + 音标 + 喇叭
        Blank()
        Text(card.english)
          .fontSize(38).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
          .maxLines(2).textAlign(TextAlign.Center)
        Row() {
          Text(card.phonetic)
            .fontSize(16).fontColor(Colors.TEXT_SUB).layoutWeight(1).textAlign(TextAlign.Center)
          Button() {
            Image($r('app.media.ic_speaker')).width(20).height(20).fillColor(Colors.BRAND)
          }
          .type(ButtonType.Circle).width(40).height(40).backgroundColor(Colors.BRAND_SOFT)
          .margin({ right: 8 })
          .onClick(() => this.replay())
        }
        .width('74%').margin({ top: 16 })
        Blank()
        Text('轻点卡片翻面查看中文释义')
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_WEAK).margin({ bottom: 12 })
      }
    }
    .width('100%').height('100%')
    .padding({ left: 20, right: 20, top: 28, bottom: 18 })
    .backgroundColor(Colors.WHITE)
    .borderRadius(Radius.SHEET)
    .justifyContent(FlexAlign.Center)
    // ArkUI 无 backfaceVisibility：翻面中点（90°）切换正反面可见性
    .visibility((back && this.flipAngle < 90) || (!back && this.flipAngle >= 90)
      ? Visibility.Hidden : Visibility.Visible)
    .rotate({ x: 0, y: 1, angle: back ? this.flipAngle + 180 : this.flipAngle })
  }

  @Builder
  CardStack() {
    Stack({ alignContent: Alignment.Center }) {
      // 牌堆底牌（第二张，露出边缘）
      if (this.queue.length >= 2) {
        Column()
          .width('88%').height('56%')
          .backgroundColor(Colors.WHITE).borderRadius(Radius.SHEET)
          .scale({ x: 0.94, y: 0.94 })
          .translate({ y: 14 })
          .shadow(ShadowStyle.OUTER_DEFAULT_XS)
      }
      // 正面卡：翻面只由两个 CardFace 各自旋转承担。
      // P3 修复：父 Stack 此前也带 rotateY，翻面后背面累计 540° 导致整面镜像反字。
      Column() {
        Stack() {
          this.CardFace(this.queue[0], false)
          this.CardFace(this.queue[0], true)
        }
        .width('100%').height('100%')
        // 翻面轻点
        .gesture(
          TapGesture()
            .onAction(() => this.toggleFlip())
        )
      }
      .width('88%').height('56%')
      .borderRadius(Radius.SHEET)
      .border({ width: 2, color: this.tintBorderColor() })
      .shadow(ShadowStyle.OUTER_DEFAULT_MD)
      .translate({ x: this.dragX, y: this.dragY })
      .rotate({ angle: this.dragRot })
      .opacity(this.dragOpacity)
      // 三向拖拽判定（左缘 22vp 起手在回调里忽略，交给系统返回）
      .parallelGesture(
        PanGesture({ fingers: 1, distance: 8 })
          .onActionStart((event: GestureEvent) => {
            const startX: number =
              event.fingerList.length > 0 ? event.fingerList[0].globalX : 999;
            this.onPanStart(startX);
          })
          .onActionUpdate((event: GestureEvent) => {
            this.onPanUpdate(event.offsetX, event.offsetY);
          })
          .onActionEnd((event: GestureEvent) => {
            this.onPanEnd(event.offsetX, event.offsetY);
          })
      )
    }
    .width('100%').layoutWeight(1)
  }

  @Builder
  VerdictButton(label: string, bg: ResourceColor, fg: ResourceColor, verdict: Verdict) {
    Button(label)
      .fontSize(15).fontColor(fg).backgroundColor(bg)
      .borderRadius(Radius.BUTTON).height(50).layoutWeight(1)
      .onClick(() => this.pressVerdict(verdict))
  }

  @Builder
  RoundView() {
    Column() {
      this.TopBar()

      // 本轮进度
      Text(`本轮 ${this.total - this.queue.length + 1} / ${this.total}（还剩 ${this.queue.length} 张）`)
        .fontSize(14).fontColor(Colors.TEXT_SUB)
        .width('100%').textAlign(TextAlign.Center).margin({ top: 2 })
      Text('一轮必须全部过完；判「模糊」的卡会在本轮重考')
        .fontSize(12).fontColor(Colors.TEXT_WEAK)
        .width('100%').textAlign(TextAlign.Center).margin({ top: 4, bottom: 4 })

      if (this.ttsState === 'unavailable') {
        Text('当前设备语音引擎不可用，可直接看英文翻面复习')
          .fontSize(12).fontColor(Colors.FUZZY_ORANGE)
          .width('100%').textAlign(TextAlign.Center)
      }

      this.CardStack()

      // 手势提示
      Row() {
        Text('左滑 不认识').fontSize(12).fontColor(Colors.UNKNOWN_RED).layoutWeight(1).textAlign(TextAlign.Center)
        Text('上滑 模糊').fontSize(12).fontColor(Colors.FUZZY_ORANGE).layoutWeight(1).textAlign(TextAlign.Center)
        Text('右滑 认识').fontSize(12).fontColor(Colors.KNOW_GREEN).layoutWeight(1).textAlign(TextAlign.Center)
      }
      .width('100%').padding({ left: 12, right: 12, bottom: 10 })

      // 等价按钮
      Row() {
        this.VerdictButton('不认识', Colors.UNKNOWN_RED_SOFT, Colors.UNKNOWN_RED, 'UNKNOWN')
        this.VerdictButton('模糊', Colors.FUZZY_ORANGE_SOFT, Colors.FUZZY_ORANGE, 'VAGUE')
        Button('认识')
          .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.KNOW_GREEN)
          .borderRadius(Radius.BUTTON).height(50).layoutWeight(1)
          .onClick(() => this.pressVerdict('KNOWN'))
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 24 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
  }

  @Builder
  DoneView() {
    Column() {
      this.TopBar()
      Blank()
      Stack() {
        Circle({ width: 88, height: 88 }).fill(Colors.KNOW_GREEN_SOFT)
        Text('✓').fontSize(44).fontColor(Colors.KNOW_GREEN).fontWeight(FontWeight.Bold)
      }
      .width(110).height(110)

      Text(this.param.mode === 'WRONG' ? '错词强化完成' : this.param.mode === 'MAKEUP' ? '补卡词本已过完' : '本轮复习完成')
        .fontSize(TypeScale.TITLE_LARGE).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .margin({ top: 20 })
      Text(this.param.mode === 'MAKEUP'
        ? '点「完成，同步计划表」，该日红格将变为已补卡（补卡不恢复连续天数）'
        : '调度已按艾宾浩斯节点更新，首页与打卡进度同步刷新')
        .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB)
        .textAlign(TextAlign.Center).width('78%').margin({ top: 10 })

      Column() {
        Row() {
          Text('认识通过').fontSize(15).fontColor(Colors.TEXT_SUB).layoutWeight(1)
          Text(`${this.knownCount}`).fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.KNOW_GREEN)
        }.width('100%').padding({ top: 10, bottom: 10 })
        Divider().color(Colors.DIVIDER)
        Row() {
          Text('模糊重考次数').fontSize(15).fontColor(Colors.TEXT_SUB).layoutWeight(1)
          Text(`${this.vagueCount}`).fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.FUZZY_ORANGE)
        }.width('100%').padding({ top: 10, bottom: 10 })
        Divider().color(Colors.DIVIDER)
        Row() {
          Text('不认识（已入错词本）').fontSize(15).fontColor(Colors.TEXT_SUB).layoutWeight(1)
          Text(`${this.unknownCount}`).fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.UNKNOWN_RED)
        }.width('100%').padding({ top: 10, bottom: 10 })
      }
      .width('82%').backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
      .padding({ left: 18, right: 18 }).margin({ top: 28 })

      Blank()
      Button(this.param.mode === 'MAKEUP' ? '完成，同步计划表' : '返回')
        .fontSize(16).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
        .borderRadius(Radius.BUTTON).height(50).width('82%').margin({ bottom: 30 })
        .onClick(() => {
          if (this.param.mode === 'MAKEUP' && this.param.makeupDay !== undefined) {
            const day: string = this.param.makeupDay;
            DataStore.INSTANCE.completeMakeup(day);
            promptAction.showToast({ message: '补卡已完成，计划表已同步', duration: 2000 });
            // 动态QA：冻结的计划表不会重绘，清栈回「打卡」Tab 整页重挂载，再进计划表即为最新
            NavStore.INSTANCE.backToTab(1);
          } else {
            NavStore.INSTANCE.back();
          }
        })
    }
    .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
  }

  @Builder
  EmptyView() {
    Column() {
      this.TopBar()
      Blank()
      Text('当前没有需要复习的单词')
        .fontSize(TypeScale.CARD_TITLE).fontColor(Colors.TEXT_MAIN)
      Text('到期复习词会按 R1 / R2 / R4 / R7 / R15 节点自动出现')
        .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB).margin({ top: 10 })
      Button('返回')
        .fontSize(TypeScale.BODY).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
        .borderRadius(Radius.BUTTON).height(46).width(200).margin({ top: 22 })
        .onClick(() => NavStore.INSTANCE.back())
      Blank()
    }
    .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
  }

  build() {
    NavDestination() {
      if (this.total === 0) {
        this.EmptyView()
      } else if (this.finished) {
        this.DoneView()
      } else {
        this.RoundView()
      }
    }
    .hideTitleBar(true)
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity + this.showTick * 0)
    .onShown(() => {
      this.animateCovered(true);
      this.showTick++;
    })
    .onHidden(() => this.animateCovered(false))
    .customTransition((operation: NavigationOperation, isEnter: boolean): NavDestinationTransition[] | undefined => {
      const reduced: boolean = NavStore.INSTANCE.reducedMotion;
      return [{
        duration: reduced ? Motion.REDUCED : Motion.PAGE,
        curve: Curve.EaseOut,
        event: () => {
          if (reduced) {
            this.sheetX = '0%';
            this.sheetOpacity = isEnter ? 1 : 0;
            return;
          }
          if (operation === NavigationOperation.PUSH && isEnter) {
            this.sheetX = '0%';
            this.sheetOpacity = 1;
          } else if (operation === NavigationOperation.POP && !isEnter) {
            this.sheetX = '100%';
            this.sheetOpacity = 0;
          }
        }
      }];
    })
  }
}
