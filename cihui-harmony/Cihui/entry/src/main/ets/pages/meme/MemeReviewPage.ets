/**
 * F17 梗句背诵页：复用 F9 闪卡三档判定与手势，会话状态机落库可恢复。
 * - 词序在导入时已随机打乱；模糊卡本轮末尾重考（会话内重排队，调度不改）；
 * - 新词判词走 F2 首测正常排期，学习中词只进本次会话、不改排期（MemeCore 口径）；
 * - 顶部「梗句背诵·第 a/b 词」，右上「看原句」弹中英对照；
 * - 中途退出实时落盘：从 F5 梗句词本再进入时，未完成会话提示「上次还差 n 个词，继续吗」；
 * - 背完（每词完成过一次判定，不要求全对）显示完成页；F18 在此接梗卡半模态。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import type { MemeBadgeLevel, MemeSentence, StudySession, Verdict, Word } from '../../model/Types';
import { TtsService } from '../../service/TtsService';
import type { TtsState } from '../../service/TtsService';
import { MemeCardService } from '../../service/MemeCardService';
import type { MemeCardSpec } from '../../service/MemeCardService';
import { ShareService } from '../../service/ShareService';
import { dayKeyFromTs } from '../../model/SchedulerCore';
import { RouteName } from '../../common/RouteNames';
import type { MemeReviewRouteParam } from '../../common/RouteNames';
import { promptAction } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';
import { common } from '@kit.AbilityKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

@ObservedV2
class MemeCard {
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
export struct MemeReviewPage {
  @Require @Param param: MemeReviewRouteParam;
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 0;
  @Local showTick: number = 0;
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.MEME_REVIEW) {
      this.showTick++;
    }
  };

  @Local queue: MemeCard[] = [];
  @Local finished: boolean = false;
  @Local ttsState: TtsState = 'idle';
  @Local showOriginal: boolean = false;
  @Local knownCount: number = 0;
  @Local vagueCount: number = 0;
  @Local unknownCount: number = 0;

  private total: number = 0;
  private sessionId: string = '';
  private meme: MemeSentence | null = null;

  @Local flipAngle: number = 0;
  @Local dragX: number = 0;
  @Local dragY: number = 0;
  @Local dragRot: number = 0;
  @Local dragOpacity: number = 1;
  @Local tint: TintKind = '';

  // F18 梗卡半模态
  @Local cardSheetShow: boolean = false;
  @Local cardImagePath: string = '';
  @Local cardFavorited: boolean = false;
  @Local cardBusy: boolean = false;
  @Local cardEnter: number = 0;

  private flying: boolean = false;
  private edgeBlocked: boolean = false;
  private speakTimer: number = -1;
  private advanceTimer: number = -1;
  private resumedAsked: boolean = false;
  private sheetSessionId: string = '';
  private cardId: string = '';
  private cardSpec: MemeCardSpec | null = null;

  private static readonly EDGE_ZONE_VP: number = 22;
  private static readonly H_THRESHOLD_VP: number = 110;
  private static readonly V_THRESHOLD_VP: number = 90;
  private static readonly FLY_DISTANCE_VP: number = 520;

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    this.meme = DataStore.INSTANCE.memeById(this.param.memeId);
    if (this.meme === null) {
      // 梗句已被删除：直接退回
      setTimeout(() => NavStore.INSTANCE.back(), 60);
      return;
    }
    let session: StudySession | null = null;
    if (this.param.sessionId !== undefined && this.param.sessionId.length > 0) {
      session = DataStore.INSTANCE.sessionById(this.param.sessionId);
    } else {
      session = DataStore.INSTANCE.resumableSession(this.param.memeId);
    }
    if (session === null || session.status === 'completed') {
      // 没有进行中的会话：再背一遍，新建会话
      const sid: string = DataStore.INSTANCE.restudyMeme(this.param.memeId);
      session = DataStore.INSTANCE.sessionById(sid);
    } else if (!this.resumedAsked && this.param.sessionId === undefined) {
      this.askResume(session);
    }
    if (session !== null) {
      this.loadSession(session);
    }
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

  /** 从 F5 进入且存在未完成会话：继续 / 重新背 */
  private askResume(session: StudySession): void {
    this.resumedAsked = true;
    const pending: number = session.items.filter((it): boolean => it.state === 'pending').length;
    if (pending <= 0) {
      return;
    }
    try {
      promptAction.showDialog({
        title: '继续上次的梗句背诵？',
        message: `上次还有 ${pending} 个词没背完`,
        buttons: [
          { text: '重新背', color: Colors.TEXT_SUB },
          { text: '继续', color: Colors.BRAND },
        ],
      }).then((r): void => {
        if (r.index === 0) {
          const sid: string = DataStore.INSTANCE.restudyMeme(this.param.memeId);
          const s: StudySession | null = DataStore.INSTANCE.sessionById(sid);
          if (s !== null) {
            this.loadSession(s);
          }
        }
      });
    } catch (e) {
      console.warn(`[MemeReview] resume dialog: ${(e as Error)?.message ?? e}`);
    }
  }

  private loadSession(session: StudySession): void {
    this.sessionId = session.id;
    const cards: MemeCard[] = [];
    session.items.forEach((it): void => {
      if (it.state === 'reviewed') {
        return;
      }
      const w: Word | undefined =
        DataStore.INSTANCE.words.find((x: Word): boolean => x.id === it.wordId);
      if (w !== undefined) {
        cards.push(new MemeCard(w));
      }
    });
    this.queue = cards;
    this.total = session.items.length;
    this.knownCount = session.items.filter((it): boolean => it.verdict === 'KNOWN').length;
    this.vagueCount = session.items.filter((it): boolean => it.verdict === 'VAGUE').length;
    this.unknownCount = session.items.filter((it): boolean => it.verdict === 'UNKNOWN').length;
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
      console.warn(`[MemeReview] toast: ${(e as Error)?.message ?? e}`);
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
      console.warn(`[MemeReview] vibrate: ${(e as Error)?.message ?? e}`);
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

  /** 语音状态对应的用户提示（空串表示无需提示） */
  private ttsHintText(): string {
    if (this.ttsState === 'downloading') {
      return '正在下载英文发音音色，请稍候…';
    }
    if (this.ttsState === 'needDownload') {
      return '首次朗读需联网下载英文发音音色，下载后即可离线朗读';
    }
    if (this.ttsState === 'unavailable') {
      return '当前设备语音引擎不可用，可直接看英文翻面背诵';
    }
    return '';
  }

  private replay(): void {
    if (this.queue.length === 0) {
      return;
    }
    if (this.ttsState !== 'ready') {
      const hint: string = this.ttsHintText();
      this.toast(hint.length > 0 ? hint : '语音引擎未就绪，可直接看英文继续');
      return;
    }
    if (!TtsService.speak(this.queue[0].english)) {
      this.toast('朗读失败，可直接看英文继续');
    }
  }

  private toggleFlip(): void {
    if (this.flying || this.queue.length === 0) {
      return;
    }
    const card: MemeCard = this.queue[0];
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
      { duration: reduced ? Motion.MICRO : Motion.FEEDBACK, curve: Curve.EaseOut },
      () => {
        this.dragX = 0;
        this.dragY = 0;
        this.dragRot = 0;
        this.dragOpacity = 1;
        this.tint = '';
      }
    );
  }

  private resolve(card: MemeCard, verdict: Verdict, direction: string): void {
    if (this.flying) {
      return;
    }
    if (!card.flipped) {
      this.toast('请先轻点卡片翻面，查看中文');
      this.resetDrag();
      return;
    }
    this.flying = true;
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    if (verdict === 'VAGUE') {
      this.toast('模糊，本轮稍后重考');
    } else if (verdict === 'UNKNOWN') {
      this.toast('新词已按艾宾浩斯排期');
      this.haptic();
    }

    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : 280, curve: Curve.EaseIn },
      () => {
        if (verdict === 'KNOWN') {
          this.dragX = direction === 'none' ? 0 : MemeReviewPage.FLY_DISTANCE_VP;
          this.dragOpacity = 0;
          this.tint = 'green';
        } else if (verdict === 'UNKNOWN') {
          this.dragX = direction === 'none' ? 0 : -MemeReviewPage.FLY_DISTANCE_VP;
          this.dragOpacity = 0;
          this.tint = 'red';
        } else {
          this.dragY = -MemeReviewPage.FLY_DISTANCE_VP;
          this.dragOpacity = 0;
          this.tint = 'orange';
        }
        this.dragRot = verdict === 'KNOWN' ? 18 : verdict === 'UNKNOWN' ? -18 : 0;
      }
    );

    // 会话判定落库（新词走 F2，学习中词只进会话）
    const info = DataStore.INSTANCE.advanceMemeSession(this.sessionId, card.wordId, verdict);
    if (verdict === 'KNOWN') {
      this.knownCount += 1;
    } else if (verdict === 'VAGUE') {
      this.vagueCount += 1;
    } else {
      this.unknownCount += 1;
    }

    this.advanceTimer = setTimeout(() => {
      this.advanceTimer = -1;
      this.advance(card, verdict, info.completed);
      if (info.completed) {
        this.onSessionCompleted(info.memeId, info.knownCount, info.total);
      }
    }, reduced ? 120 : 300);
  }

  /** F18：会话完成 → 落梗卡 → Canvas 渲染 → 自动滑出半模态（不跳页） */
  private onSessionCompleted(memeId: string, known: number, total: number): void {
    if (this.sheetSessionId === this.sessionId) {
      return; // 同一会话只弹一次（模糊重考收尾时防重）
    }
    const meme: MemeSentence | null = DataStore.INSTANCE.memeById(memeId);
    if (meme === null) {
      return;
    }
    this.sheetSessionId = this.sessionId;
    const day: string = dayKeyFromTs(Date.now());
    const saved = DataStore.INSTANCE.upsertMemeCard({
      memeId,
      cardImagePath: '',
      masteredCount: known,
      totalCount: total,
      unlockedDay: day,
    });
    this.cardId = saved.id;
    this.cardFavorited = saved.isFavorite;
    this.cardImagePath = '';
    this.cardEnter = 0;
    const spec: MemeCardSpec = {
      chinese: meme.chinese,
      english: meme.english,
      masteredCount: known,
      totalCount: total,
      unlockedDay: day,
      badgeLevel: saved.badgeLevel,
    };
    this.cardSpec = spec;
    // ArkUI 卡面离屏快照为 JPEG（失败不阻断，sheet 内卡面与保存/分享仍可走实时快照）
    const ctx = getContext(this) as common.UIAbilityContext;
    ShareService.snapshotBuilderToJpg(ctx, this.SnapshotCard, `meme_card_${meme.id}`)
      .then((path: string): void => {
        this.cardImagePath = path;
        const updated = DataStore.INSTANCE.upsertMemeCard({
          memeId,
          cardImagePath: path,
          masteredCount: known,
          totalCount: total,
          unlockedDay: day,
        });
        this.cardId = updated.id;
      }).catch((e: Object): void => {
        console.warn(`[MemeReview] card snapshot failed: ${(e as Error)?.message ?? e}`);
      });
    // 等完成页勾子动画露出后再滑卡，280ms sheet 曲线
    setTimeout(() => {
      this.cardSheetShow = true;
      const reduced: boolean = NavStore.INSTANCE.reducedMotion;
      this.getUIContext().animateTo(
        { duration: reduced ? Motion.REDUCED : Motion.SHEET, curve: Curve.EaseOut },
        () => {
          this.cardEnter = 1;
        }
      );
    }, 460);
  }

  /** F18 保存到相册（SaveButton 安全控件授权后回调） */
  private async onCardSave(result: SaveButtonOnClickResult): Promise<void> {
    if (result !== SaveButtonOnClickResult.SUCCESS) {
      this.toast('未获得相册授权，梗卡未保存');
      return;
    }
    if (this.cardBusy) {
      return;
    }
    this.cardBusy = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      if (this.cardImagePath !== '') {
        await ShareService.saveFileToGallery(ctx, this.cardImagePath);
      } else {
        // 快照尚未就绪：实时离屏快照后存相册
        await ShareService.saveCardToGallery(ctx, this.SnapshotCard, `meme_card_${this.cardId}`);
      }
      this.toast('已保存到相册');
    } catch (e) {
      console.warn(`[MemeReview] save card: ${(e as Error)?.message ?? e}`);
      this.toast('保存失败，请重试');
    } finally {
      this.cardBusy = false;
    }
  }

  /** F18 系统分享；无可用目标时降级存相册 */
  private async onCardShare(): Promise<void> {
    if (this.cardBusy || this.cardSpec === null) {
      return;
    }
    this.cardBusy = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      let path: string = this.cardImagePath;
      if (path === '') {
        path = await ShareService.snapshotBuilderToJpg(ctx, this.SnapshotCard, `meme_card_share_${this.cardId}`);
      }
      await MemeCardService.shareImage(ctx, path, MemeCardService.shareText(this.cardSpec));
      if (this.cardId !== '') {
        DataStore.INSTANCE.bumpMemeCardShare(this.cardId);
      }
    } catch (e) {
      console.warn(`[MemeReview] share card: ${(e as Error)?.message ?? e}`);
      // 无分享目标 / 面板异常：自动改存相册
      try {
        const ctx = getContext(this) as common.UIAbilityContext;
        if (this.cardImagePath !== '') {
          await ShareService.saveFileToGallery(ctx, this.cardImagePath);
        } else {
          await ShareService.saveCardToGallery(ctx, this.SnapshotCard, `meme_card_${this.cardId}`);
        }
        this.toast('未找到分享目标，已为你保存到相册');
      } catch (_e2) {
        this.toast('分享失败，请稍后再试');
      }
    } finally {
      this.cardBusy = false;
    }
  }

  /** F18 收藏 / 取消收藏 */
  private onCardFavorite(): void {
    if (this.cardId === '') {
      return;
    }
    DataStore.INSTANCE.toggleMemeCardFavorite(this.cardId);
    this.cardFavorited = !this.cardFavorited;
    this.toast(this.cardFavorited ? '已收藏到梗卡册' : '已取消收藏');
  }

  /** F18 sheet 内「再背一遍」：关 sheet 并重建会话 */
  private onSheetRestudy(): void {
    this.cardSheetShow = false;
    setTimeout(() => this.restudy(), Motion.SHEET + 40);
  }

  /** F18 sheet 内「回词本」 */
  private onSheetBackToBooks(): void {
    this.cardSheetShow = false;
    setTimeout(() => NavStore.INSTANCE.backToTab(2), Motion.SHEET + 40);
  }

  /** 点卡片看完整原句（卡面超出截断时兜底） */
  private showFullSentence(): void {
    if (this.cardSpec === null) {
      return;
    }
    try {
      promptAction.showDialog({
        title: '完整原句',
        message: `${this.cardSpec.chinese}\n\n${this.cardSpec.english}`,
        buttons: [{ text: '知道了', color: Colors.BRAND }],
      });
    } catch (e) {
      console.warn(`[MemeReview] full sentence: ${(e as Error)?.message ?? e}`);
    }
  }

  private advance(card: MemeCard, verdict: Verdict, completed: boolean): void {
    const next: MemeCard[] = this.queue.slice(1);
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
    // 会话口径：所有词 reviewed 才完成（VAGUE 会重排，队列清空即完成）
    if (completed || next.length === 0) {
      this.finished = true;
      TtsService.stop();
    } else {
      this.scheduleSpeak(320);
    }
  }

  private onPanStart(globalX: number): void {
    this.edgeBlocked = globalX <= vp2px(MemeReviewPage.EDGE_ZONE_VP);
  }

  private onPanUpdate(offsetX: number, offsetY: number): void {
    if (this.flying || this.edgeBlocked || this.queue.length === 0) {
      return;
    }
    this.dragX = offsetX;
    this.dragY = offsetY;
    this.dragRot = offsetX * 0.04;
    this.dragOpacity = 1 - Math.min(Math.abs(offsetX), 240) / 640;
    if (offsetY < -MemeReviewPage.V_THRESHOLD_VP && Math.abs(offsetY) > Math.abs(offsetX)) {
      this.tint = 'orange';
    } else if (offsetX > MemeReviewPage.H_THRESHOLD_VP) {
      this.tint = 'green';
    } else if (offsetX < -MemeReviewPage.H_THRESHOLD_VP) {
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
    const card: MemeCard = this.queue[0];
    if (offsetY < -MemeReviewPage.V_THRESHOLD_VP && Math.abs(offsetY) > Math.abs(offsetX)) {
      this.resolve(card, 'VAGUE', 'up');
    } else if (offsetX > MemeReviewPage.H_THRESHOLD_VP) {
      this.resolve(card, 'KNOWN', 'right');
    } else if (offsetX < -MemeReviewPage.H_THRESHOLD_VP) {
      this.resolve(card, 'UNKNOWN', 'left');
    } else {
      this.resetDrag();
    }
  }

  private pressVerdict(verdict: Verdict): void {
    if (this.queue.length === 0 || this.flying) {
      return;
    }
    this.resolve(this.queue[0], verdict, 'none');
  }

  /** F17 完成页「再背一遍」：同梗句重新洗牌建新会话 */
  private restudy(): void {
    if (this.meme === null) {
      return;
    }
    const sid: string = DataStore.INSTANCE.restudyMeme(this.meme.id);
    const s: StudySession | null = DataStore.INSTANCE.sessionById(sid);
    this.finished = false;
    this.sheetSessionId = '';
    this.cardSheetShow = false;
    this.knownCount = 0;
    this.vagueCount = 0;
    this.unknownCount = 0;
    if (s !== null) {
      this.loadSession(s);
    }
    this.scheduleSpeak(320);
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

      Column() {
        Text('梗句背诵').fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium)
          .fontColor(Colors.TEXT_MAIN)
        Text(this.progressText()).fontSize(11).fontColor(Colors.TEXT_WEAK).margin({ top: 1 })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Center)

      Button('看原句')
        .fontSize(13).fontColor(Colors.BRAND).backgroundColor(Colors.BRAND_SOFT)
        .borderRadius(Radius.CONTROL).height(34).width(72)
        .onClick(() => {
          this.showOriginal = true;
          TtsService.stop();
        })
    }
    .width('100%').height(56).padding({ left: 4, right: 10 })
  }

  private progressText(): string {
    if (this.total === 0) {
      return '梗句背诵';
    }
    const idx: number = this.total - this.queue.length + 1;
    return `第 ${Math.min(idx, this.total)} / ${this.total} 词`;
  }

  @Builder
  CardFace(card: MemeCard, back: boolean) {
    Column() {
      if (back) {
        Text(card.english)
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_SUB).maxLines(1)
        Text(card.phonetic).fontSize(12).fontColor(Colors.TEXT_WEAK).margin({ top: 4 })
        Divider().color(Colors.DIVIDER).width('70%').margin({ top: 16, bottom: 18 })
        if (card.meanings.length > 0) {
          Text(card.meanings.join('；'))
            .fontSize(24).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
            .textAlign(TextAlign.Center).maxLines(6).width('84%')
        } else {
          Text('（本词暂无释义，结合原句语境理解）')
            .fontSize(17).fontColor(Colors.TEXT_SUB)
            .textAlign(TextAlign.Center).maxLines(4).width('80%')
          Button('看原句')
            .fontSize(13).fontColor(Colors.BRAND).backgroundColor(Colors.BRAND_SOFT)
            .borderRadius(Radius.CONTROL).height(34).margin({ top: 16 })
            .onClick(() => {
              this.showOriginal = true;
            })
        }
        Blank()
        Text('再轻点卡片可翻回英文面')
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_WEAK).margin({ bottom: 10 })
      } else {
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
        Text('轻点卡片翻面查看中文')
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_WEAK).margin({ bottom: 12 })
      }
    }
    .width('100%').height('100%').padding({ left: 20, right: 20, top: 28, bottom: 18 })
    .backgroundColor(Colors.WHITE).borderRadius(Radius.SHEET).justifyContent(FlexAlign.Center)
    .visibility((back && this.flipAngle < 90) || (!back && this.flipAngle >= 90)
      ? Visibility.Hidden : Visibility.Visible)
    .rotate({ x: 0, y: 1, angle: back ? this.flipAngle + 180 : this.flipAngle })
  }

  @Builder
  CardStack() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.queue.length >= 2) {
        Column()
          .width('88%').height('56%')
          .backgroundColor(Colors.WHITE).borderRadius(Radius.SHEET)
          .scale({ x: 0.94, y: 0.94 }).translate({ y: 14 })
          .shadow(ShadowStyle.OUTER_DEFAULT_XS)
      }
      Column() {
        Stack() {
          this.CardFace(this.queue[0], false)
          this.CardFace(this.queue[0], true)
        }
        .width('100%').height('100%')
        .gesture(TapGesture().onAction(() => this.toggleFlip()))
      }
      .width('88%').height('56%').borderRadius(Radius.SHEET)
      .border({ width: 2, color: this.tintBorderColor() }).shadow(ShadowStyle.OUTER_DEFAULT_MD)
      .translate({ x: this.dragX, y: this.dragY }).rotate({ angle: this.dragRot })
      .opacity(this.dragOpacity)
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
      if (this.ttsHintText().length > 0) {
        Text(this.ttsHintText())
          .fontSize(12).fontColor(Colors.FUZZY_ORANGE)
          .width('100%').textAlign(TextAlign.Center).margin({ top: 2 })
      }
      this.CardStack()
      Row() {
        Text('左滑 不认识').fontSize(12).fontColor(Colors.UNKNOWN_RED).layoutWeight(1).textAlign(TextAlign.Center)
        Text('上滑 模糊').fontSize(12).fontColor(Colors.FUZZY_ORANGE).layoutWeight(1).textAlign(TextAlign.Center)
        Text('右滑 认识').fontSize(12).fontColor(Colors.KNOW_GREEN).layoutWeight(1).textAlign(TextAlign.Center)
      }
      .width('100%').padding({ left: 12, right: 12, bottom: 10 })

      Row() {
        this.VerdictButton('不认识', Colors.UNKNOWN_RED_SOFT, Colors.UNKNOWN_RED, 'UNKNOWN')
        this.VerdictButton('模糊', Colors.FUZZY_ORANGE_SOFT, Colors.FUZZY_ORANGE, 'VAGUE')
        Button('认识')
          .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.KNOW_GREEN)
          .borderRadius(Radius.BUTTON).height(50).layoutWeight(1)
          .onClick(() => this.pressVerdict('KNOWN'))
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 24 }).alignItems(VerticalAlign.Center)
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
      }.width(110).height(110)
      Text('这个梗背完啦')
        .fontSize(TypeScale.TITLE_LARGE).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .margin({ top: 20 })
      Text('新词已按艾宾浩斯节点排期，可在首页与我的词本继续复习')
        .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB)
        .textAlign(TextAlign.Center).width('78%').margin({ top: 10 })

      Column() {
        Row() {
          Text('认识').fontSize(15).fontColor(Colors.TEXT_SUB).layoutWeight(1)
          Text(`${this.knownCount}`).fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.KNOW_GREEN)
        }.width('100%').padding({ top: 10, bottom: 10 })
        Divider().color(Colors.DIVIDER)
        Row() {
          Text('模糊重考次数').fontSize(15).fontColor(Colors.TEXT_SUB).layoutWeight(1)
          Text(`${this.vagueCount}`).fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.FUZZY_ORANGE)
        }.width('100%').padding({ top: 10, bottom: 10 })
        Divider().color(Colors.DIVIDER)
        Row() {
          Text('不认识').fontSize(15).fontColor(Colors.TEXT_SUB).layoutWeight(1)
          Text(`${this.unknownCount}`).fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.UNKNOWN_RED)
        }.width('100%').padding({ top: 10, bottom: 10 })
      }
      .width('82%').backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
      .padding({ left: 18, right: 18 }).margin({ top: 28 })

      Blank()
      Row() {
        Button('再背一遍')
          .fontSize(16).fontColor(Colors.BRAND).backgroundColor(Colors.BRAND_SOFT)
          .borderRadius(Radius.BUTTON).height(50).layoutWeight(1).margin({ right: 10 })
          .onClick(() => this.restudy())
        Button('返回我的词本')
          .fontSize(16).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
          .borderRadius(Radius.BUTTON).height(50).layoutWeight(1.4)
          .onClick(() => NavStore.INSTANCE.backToTab(2))
      }
      .width('82%').margin({ bottom: 30 })
    }
    .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
  }

  /** 看原句：全屏压暗 + 中英对照卡，点击空白关闭 */
  @Builder
  OriginalOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%').height('100%').backgroundColor('#99000000')
        .onClick(() => {
          this.showOriginal = false;
          this.scheduleSpeak(200);
        })
      Column() {
        Row() {
          Text('原句').fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Bold)
            .fontColor(Colors.TEXT_MAIN).layoutWeight(1)
          Button() {
            Text('✕').fontSize(16).fontColor(Colors.TEXT_SUB)
          }
          .type(ButtonType.Circle).width(34).height(34).backgroundColor(Colors.PAGE_BG)
          .onClick(() => {
            this.showOriginal = false;
            this.scheduleSpeak(200);
          })
        }.width('100%')

        Text(this.meme !== null ? this.meme.chinese : '')
          .fontSize(20).fontColor(Colors.TEXT_MAIN).width('100%').margin({ top: 16 })
        Divider().color(Colors.DIVIDER).width('100%').margin({ top: 14, bottom: 14 })
        Text(this.meme !== null ? this.meme.english : '')
          .fontSize(17).fontColor(Colors.TEXT_SUB).width('100%')
      }
      .width('84%').backgroundColor(Colors.WHITE).borderRadius(Radius.SHEET)
      .padding(22).shadow(ShadowStyle.OUTER_DEFAULT_LG)
    }
    .width('100%').height('100%')
    .opacity(this.showOriginal ? 1 : 0).visibility(this.showOriginal ? Visibility.Visible : Visibility.None)
  }

  /** F18 徽章色 */
  private badgeColor(level: MemeBadgeLevel): ResourceColor {
    if (level === 'GOLD') {
      return '#F5C542';
    }
    if (level === 'SILVER') {
      return '#C7D0DA';
    }
    return '#D08A4E';
  }

  /** 离屏快照根：固定 360vp 宽，createFromBuilder 无父容器也不会塌陷 */
  @Builder
  SnapshotCard() {
    Column() {
      this.FallbackCard()
    }.width(360)
  }

  /** F18 梗卡卡面（4:5 品牌蓝渐变；sheet 内直接展示，同时作为离屏快照源） */
  @Builder
  FallbackCard() {
    Stack() {
      Column() {
        Row() {
          Text('词慧 · 梗句卡').fontSize(12).fontColor('rgba(255,255,255,0.72)')
          Blank()
          if (this.cardSpec !== null) {
            Stack() {
              Text(MemeCardService.badgeShort(this.cardSpec.badgeLevel))
                .fontSize(12).fontWeight(FontWeight.Bold)
                .fontColor(this.cardSpec.badgeLevel === 'SILVER' ? '#33415C' : Colors.WHITE)
            }
            .width(46).height(46).borderRadius(23)
            .backgroundColor(this.badgeColor(this.cardSpec.badgeLevel))
          }
        }.width('100%')

        if (this.cardSpec !== null) {
          Text(this.cardSpec.chinese)
            .fontSize(23).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
            .maxLines(2).width('100%').margin({ top: 18 })
          Divider().color('rgba(255,255,255,0.35)').width('100%').margin({ top: 14, bottom: 12 })
          Text('ENGLISH').fontSize(10).fontColor('rgba(255,255,255,0.72)').width('100%')
          Text(this.cardSpec.english)
            .fontSize(15).fontColor('rgba(255,255,255,0.92)')
            .maxLines(3).width('100%').margin({ top: 6 })
          Blank()
          Text(`已掌握 ${this.cardSpec.masteredCount}/${this.cardSpec.totalCount} 词`)
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE).width('100%')
          Text(`解锁于 ${this.cardSpec.unlockedDay}`)
            .fontSize(12).fontColor('rgba(255,255,255,0.72)').width('100%').margin({ top: 6 })
        }
        Text('词慧 · 让背单词变有趣')
          .fontSize(11).fontColor('rgba(255,255,255,0.66)').width('100%').margin({ top: 10 })
      }
      .width('100%').height('100%').padding(20).justifyContent(FlexAlign.Start)
    }
    .width('100%').aspectRatio(0.8).borderRadius(20)
    .linearGradient({ angle: 135, colors: [[Colors.BRAND, 0], [Colors.BRAND_PRESSED, 1]] })
  }

  /** F18 背完自动滑出的梗卡半模态（bindSheet，不跳页） */
  @Builder
  MemeCardSheet() {
    Column() {
      Row() {
        Text('解锁梗卡').fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        Blank()
        if (this.cardSpec !== null) {
          Row() {
            Text(MemeCardService.badgeShort(this.cardSpec.badgeLevel))
              .fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor(this.cardSpec.badgeLevel === 'SILVER' ? '#33415C' : Colors.WHITE)
          }
          .height(26).padding({ left: 12, right: 12 }).borderRadius(13)
          .backgroundColor(this.badgeColor(this.cardSpec.badgeLevel))
        }
      }.width('100%').padding({ left: 4, right: 4 })

      Stack({ alignContent: Alignment.Center }) {
        if (this.cardImagePath !== '') {
          Image(`file://${this.cardImagePath}`)
            .width('100%').aspectRatio(0.8).borderRadius(20).objectFit(ImageFit.Cover)
        } else {
          // 快照文件尚未就绪时直接显示 ArkUI 卡面，用户无等待
          this.FallbackCard()
        }
      }
      .width('78%').margin({ top: 14 })
      .onClick(() => this.showFullSentence())

      Text('点卡片查看完整原句').fontSize(11).fontColor(Colors.TEXT_WEAK).margin({ top: 8 })

      Row() {
        Column() {
          SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE, buttonType: ButtonType.Capsule })
            .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => {
              this.onCardSave(result);
            })
            .width('100%').height(46)
        }.layoutWeight(1).margin({ right: 10 })
        Button('分享给朋友')
          .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
          .borderRadius(Radius.BUTTON).height(46).layoutWeight(1)
          .onClick(() => this.onCardShare())
      }.width('100%').margin({ top: 14 })

      Button(this.cardFavorited ? '已收藏 ✓' : '收藏到梗卡册')
        .fontSize(15)
        .fontColor(this.cardFavorited ? Colors.KNOW_GREEN : Colors.BRAND)
        .backgroundColor(this.cardFavorited ? Colors.KNOW_GREEN_SOFT : Colors.BRAND_SOFT)
        .borderRadius(Radius.BUTTON).height(46).width('100%').margin({ top: 10 })
        .onClick(() => this.onCardFavorite())

      Row() {
        Button('再背一遍')
          .fontSize(15).fontColor(Colors.BRAND).backgroundColor(Colors.WHITE)
          .borderRadius(Radius.BUTTON).height(46).layoutWeight(1).margin({ right: 10 })
          .onClick(() => this.onSheetRestudy())
        Button('返回我的词本')
          .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
          .borderRadius(Radius.BUTTON).height(46).layoutWeight(1.2)
          .onClick(() => this.onSheetBackToBooks())
      }.width('100%').margin({ top: 10, bottom: 6 })
    }
    .width('100%').padding({ left: 22, right: 22, top: 16, bottom: 26 })
    .backgroundColor(Colors.PAGE_BG)
    .opacity(this.cardEnter)
    .translate({ y: this.cardEnter === 1 ? 0 : 24 })
  }

  build() {
    NavDestination() {
      Stack() {
        if (this.total === 0 && !this.finished) {
          Column() {
            this.TopBar()
            Blank()
            Text('这个梗句没有需要背的词')
              .fontSize(TypeScale.CARD_TITLE).fontColor(Colors.TEXT_MAIN)
            Button('返回')
              .fontSize(TypeScale.BODY).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
              .borderRadius(Radius.BUTTON).height(46).width(200).margin({ top: 22 })
              .onClick(() => NavStore.INSTANCE.back())
            Blank()
          }
          .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
        } else if (this.finished) {
          this.DoneView()
        } else {
          this.RoundView()
        }
        this.OriginalOverlay()
      }
      .width('100%').height('100%')
      .bindSheet(this.cardSheetShow, this.MemeCardSheet(), {
        detents: [SheetSize.FIT_CONTENT],
        dragBar: true,
        backgroundColor: Colors.PAGE_BG,
        onDisappear: () => {
          this.cardSheetShow = false;
        }
      })
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
