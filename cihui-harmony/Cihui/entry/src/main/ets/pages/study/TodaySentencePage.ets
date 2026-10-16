/**
 * F19 今日例句页
 *
 * 词源硬规则：只取"今日已学新词 + 今日已复习词"（DataStore.todayWords），不碰未学词；
 * 例句只做语境强化，不进入艾宾浩斯调度、不改任何单词节点。
 *
 * - 今日有效词 < 3：空态引导，不发任何网络请求；
 * - ≥3：每批最多 20 词，顶部批次切换、逐批加载，每批 5 句；
 * - 大模型（火山豆包 lite）成功：例句卡（今日词品牌蓝高亮 + 中文 + TTS + 收藏 + 分享）；
 * - 未配 Key / 无网络 / 超时 / 非法 JSON（重试 1 次后）：降级为本批单词释义列表 + 重试，不硬造句；
 * - 「换一批」300ms 淡出淡入重新请求本批。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
import type { GeneratedSentence, SentenceSegment, Word } from '../../model/Types';
import {
  MIN_WORDS_FOR_SENTENCE,
  SENTENCES_PER_BATCH,
  SENTENCE_BATCH_SIZE,
  chunkItems,
  highlightSegments,
} from '../../model/SentenceCore';
import { dayKeyFromTs } from '../../model/SchedulerCore';
import { SentenceGenerator } from '../../service/SentenceGeneratorService';
import { TtsService } from '../../service/TtsService';
import type { TtsState } from '../../service/TtsService';
import { MemeCardService } from '../../service/MemeCardService';
import { ShareService } from '../../service/ShareService';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

/** 单批加载状态机：idle 未加载 / loading 加载中 / ok 模型成功 / fallback 本地降级 */
@ObservedV2
class BatchState {
  index: number;
  status: string;
  sentences: GeneratedSentence[];

  constructor(index: number) {
    this.index = index;
    this.status = 'idle';
    this.sentences = [];
  }
}

@ComponentV2
export struct TodaySentencePage {
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 0;
  @Local showTick: number = 0;
  @Local todayCount: number = 0;
  @Local batches: Word[][] = [];
  @Local batchStates: BatchState[] = [];
  @Local current: number = 0;
  @Local contentOpacity: number = 1;
  @Local savedKeys: string[] = [];
  @Local ttsState: TtsState = 'idle';
  /** 分享快照当前句（createFromBuilder 只接受无参 CustomBuilder） */
  @Local shareTarget: GeneratedSentence | null = null;
  @Local busy: boolean = false;
  private sourceDay: string = dayKeyFromTs(Date.now());
  private loadingSeq: number = 0;

  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.TODAY_SENTENCE) {
      this.showTick++;
      this.reload();
    }
  };

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    const rate: number = DataStore.INSTANCE.settings.ttsRate;
    TtsService.init(rate).then((state: TtsState): void => {
      this.ttsState = state;
    });
    this.reload();
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
    TtsService.stop();
  }

  /** 重新收集今日词并重建批次（学习后返回首页再进来会变化） */
  private reload(): void {
    const words: Word[] = DataStore.INSTANCE.todayWords(this.sourceDay);
    this.todayCount = words.length;
    this.savedKeys = DataStore.INSTANCE.savedSentenceList().map((s): string => s.sentence);
    if (words.length < MIN_WORDS_FOR_SENTENCE) {
      this.batches = [];
      this.batchStates = [];
      return;
    }
    this.batches = chunkItems(words, SENTENCE_BATCH_SIZE);
    const states: BatchState[] = [];
    for (let i = 0; i < this.batches.length; i++) {
      states.push(new BatchState(i));
    }
    this.batchStates = states;
    this.current = 0;
    this.loadBatch(0, false);
  }

  /** 请求一批；refresh=true 表示「换一批 / 重试」 */
  private loadBatch(index: number, refresh: boolean): void {
    if (index < 0 || index >= this.batchStates.length || this.batches.length === 0) {
      return;
    }
    const state: BatchState = this.batchStates[index];
    if (state.status === 'loading') {
      return;
    }
    this.loadingSeq++;
    const seq: number = this.loadingSeq;
    state.status = 'loading';
    this.batchStates = this.batchStates.slice();
    const words: Word[] = this.batches[index];
    if (!SentenceGenerator.available()) {
      // 未配置 Key：不发请求，直接本地释义降级
      this.finishFallback(seq, index);
      return;
    }
    SentenceGenerator.generateSentences(words, SENTENCES_PER_BATCH)
      .then((list: GeneratedSentence[]): void => {
        if (seq !== this.loadingSeq) {
          return; // 期间又切了批，丢弃过期结果
        }
        state.sentences = list;
        state.status = 'ok';
        this.batchStates = this.batchStates.slice();
        this.fadeIn();
      })
      .catch((e: Object): void => {
        console.warn(`[Sentence] batch ${index} fallback: ${(e as Error)?.message ?? e}`);
        this.finishFallback(seq, index);
      });
  }

  private finishFallback(seq: number, index: number): void {
    if (seq !== this.loadingSeq) {
      return;
    }
    const state: BatchState = this.batchStates[index];
    state.sentences = [];
    state.status = 'fallback';
    this.batchStates = this.batchStates.slice();
    this.fadeIn();
  }

  private fadeIn(): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    if (reduced) {
      this.contentOpacity = 1;
      return;
    }
    this.contentOpacity = 0.35;
    setTimeout(() => {
      this.getUIContext().animateTo(
        { duration: Motion.FEEDBACK, curve: Curve.EaseOut },
        () => {
          this.contentOpacity = 1;
        }
      );
    }, 60);
  }

  /** 「换一批」：先淡出再请求，回来淡入（整段约 300ms） */
  private refreshBatch(): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    if (reduced) {
      this.loadBatch(this.current, true);
      return;
    }
    this.getUIContext().animateTo(
      { duration: 150, curve: Curve.EaseIn },
      () => {
        this.contentOpacity = 0.2;
      }
    );
    setTimeout(() => this.loadBatch(this.current, true), 160);
  }

  private switchBatch(index: number): void {
    if (index === this.current) {
      return;
    }
    this.current = index;
    const state: BatchState | undefined = this.batchStates[index];
    if (state !== undefined && (state.status === 'idle' || state.status === 'fallback')) {
      this.loadBatch(index, false);
    } else {
      this.fadeIn();
    }
  }

  private speak(text: string): void {
    if (TtsService.speak(text)) {
      return;
    }
    if (TtsService.state === 'needDownload') {
      this.toast('需联网下载英文发音音色后才能朗读');
    } else if (TtsService.state === 'downloading') {
      this.toast('正在下载英文发音音色，请稍候…');
    } else {
      this.toast('当前设备暂不支持朗读');
    }
  }

  private isSaved(sentence: string): boolean {
    return this.savedKeys.includes(sentence);
  }

  private toggleSave(s: GeneratedSentence): void {
    if (this.isSaved(s.sentence)) {
      this.toast('已经在例句本里了');
      return;
    }
    DataStore.INSTANCE.saveSentence(s.sentence, s.translation, s.words, this.sourceDay);
    this.savedKeys = DataStore.INSTANCE.savedSentenceList().map((x): string => x.sentence);
    this.toast('已收藏到例句本');
  }

  /** 分享例句卡：ArkUI 卡面离屏快照 JPEG，再走系统分享 */
  private async shareSentence(s: GeneratedSentence): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.shareTarget = s;
      const path: string = await ShareService.snapshotBuilderToJpg(ctx, this.SnapshotSentence,
        `sentence_${Date.now()}`);
      await MemeCardService.shareImage(ctx, path, s.sentence);
    } catch (e) {
      console.warn(`[Sentence] share: ${(e as Error)?.message ?? e}`);
      this.toast('未找到分享目标，可稍后再试');
    } finally {
      this.busy = false;
    }
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
      console.warn(`[Sentence] toast: ${(e as Error)?.message ?? e}`);
    }
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())

      Text('今日例句')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Button('例句本')
        .fontSize(13).fontColor(Colors.BRAND).backgroundColor(Color.Transparent)
        .height(44).padding({ left: 8, right: 8 })
        .onClick(() => NavStore.INSTANCE.push(RouteName.SENTENCE_FAVORITES))
    }
    .width('100%').height(56).padding({ left: 8, right: 8 })
  }

  /** 今日词不足 3 个：空态，不发请求 */
  @Builder
  EmptyGate() {
    Column() {
      Blank()
      Stack() {
        Circle({ width: 96, height: 96 }).fill(Colors.BRAND_SOFT)
        Image($r('app.media.ic_sentence')).width(42).height(42).fillColor(Colors.BRAND)
      }.width(120).height(120)
      Text('例句还没解锁')
        .fontSize(TypeScale.TITLE_LARGE).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .margin({ top: 18 })
      Text(`今天背了 ${this.todayCount} 个词，再背 ${MIN_WORDS_FOR_SENTENCE - this.todayCount} 个就能生成例句`)
        .fontSize(TypeScale.BODY).fontColor(Colors.TEXT_SUB)
        .textAlign(TextAlign.Center).width('76%').margin({ top: 10 })
      Button('去背单词')
        .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
        .borderRadius(Radius.BUTTON).height(46).width(180).margin({ top: 24 })
        .onClick(() => NavStore.INSTANCE.backToTab(1))
      Blank()
    }.width('100%').layoutWeight(1)
  }

  /** 顶部分批切换 */
  @Builder
  BatchTabs() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.batchStates, (st: BatchState) => {
          Text(`第 ${st.index + 1} 批`)
            .fontSize(13)
            .fontColor(st.index === this.current ? Colors.WHITE : Colors.TEXT_SUB)
            .backgroundColor(st.index === this.current ? Colors.BRAND : Colors.WHITE)
            .borderRadius(14).height(28).padding({ left: 14, right: 14 })
            .textAlign(TextAlign.Center)
            .onClick(() => this.switchBatch(st.index))
        }, (st: BatchState): string => `tab-${st.index}`)
      }.padding({ left: 16, right: 16 })
    }
    .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
    .margin({ top: 4, bottom: 10 })
  }

  @Builder
  BatchHeader() {
    Row() {
      if (this.batchStates.length > 0) {
        Text(`第 ${this.current + 1} 批 / 共 ${this.batchStates.length} 批 · 本批 ${this.batches[this.current].length} 词`)
          .fontSize(12).fontColor(Colors.TEXT_WEAK)
      }
      Blank()
      Button('换一批')
        .fontSize(13).fontColor(Colors.BRAND).backgroundColor(Colors.BRAND_SOFT)
        .height(32).borderRadius(16).padding({ left: 14, right: 14 })
        .onClick(() => this.refreshBatch())
    }.width('100%').padding({ left: 18, right: 18 })
  }

  /** 英文句：今日词品牌蓝加粗，其余正文色 */
  @Builder
  Highlighted(s: GeneratedSentence) {
    Text() {
      ForEach(highlightSegments(s.sentence, s.words), (seg: SentenceSegment) => {
        Span(seg.text)
          .fontColor(seg.hit ? Colors.BRAND : Colors.TEXT_MAIN)
          .fontWeight(seg.hit ? FontWeight.Bold : FontWeight.Regular)
      }, (seg: SentenceSegment, idx: number): string => `seg-${idx}-${seg.hit}`)
    }
    .fontSize(17).lineHeight(26).width('100%')
  }

  @Builder
  SentenceCard(s: GeneratedSentence) {
    Column() {
      Row() {
        Column() {
          this.Highlighted(s)
          Text(s.translation)
            .fontSize(13).fontColor(Colors.TEXT_SUB).lineHeight(20).width('100%').margin({ top: 8 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Button() {
          Image($r('app.media.ic_speaker')).width(22).height(22).fillColor(Colors.BRAND)
        }
        .type(ButtonType.Circle).width(40).height(40).backgroundColor(Colors.BRAND_SOFT)
        .margin({ left: 10 })
        .onClick(() => this.speak(s.sentence))
      }.width('100%')

      Row() {
        Button(this.isSaved(s.sentence) ? '已收藏 ✓' : '☆ 收藏')
          .fontSize(13)
          .fontColor(this.isSaved(s.sentence) ? Colors.KNOW_GREEN : Colors.BRAND)
          .backgroundColor(this.isSaved(s.sentence) ? Colors.KNOW_GREEN_SOFT : Colors.BRAND_SOFT)
          .height(34).borderRadius(17).padding({ left: 14, right: 14 })
          .onClick(() => this.toggleSave(s))
        Button('分享')
          .fontSize(13).fontColor(Colors.TEXT_SUB).backgroundColor(Colors.PAGE_BG)
          .height(34).borderRadius(17).padding({ left: 14, right: 14 }).margin({ left: 10 })
          .onClick(() => this.shareSentence(s))
      }.width('100%').margin({ top: 12 })
    }
    .width('100%').padding(16).backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
  }

  @Builder
  SkeletonCard() {
    Column() {
      Column().width('92%').height(16).borderRadius(8).backgroundColor('#E3E8F0').margin({ top: 4 })
      Column().width('70%').height(16).borderRadius(8).backgroundColor('#E3E8F0').margin({ top: 10 })
      Column().width('50%').height(12).borderRadius(6).backgroundColor('#EDF0F6').margin({ top: 12 })
    }
    .width('100%').padding(16).backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
  }

  /** 降级：本批单词与本地释义，不硬造句 */
  @Builder
  FallbackList() {
    Column() {
      Row() {
        Text('当前无法生成例句，先看看单词释义')
          .fontSize(12).fontColor(Colors.FUZZY_ORANGE).layoutWeight(1)
        Button('重试')
          .fontSize(12).fontColor(Colors.BRAND).backgroundColor(Colors.BRAND_SOFT)
          .height(30).borderRadius(15).padding({ left: 12, right: 12 })
          .onClick(() => this.loadBatch(this.current, true))
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })

      if (this.batches.length > 0) {
        ForEach(this.batches[this.current], (w: Word) => {
          Row() {
            Text(w.english).fontSize(15).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
            Blank()
            Text(w.meanings.length > 0 ? w.meanings[0] : '（暂无释义）')
              .fontSize(13).fontColor(Colors.TEXT_SUB).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 180 })
          }
          .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .backgroundColor(Colors.WHITE).borderRadius(Radius.CONTROL).margin({ bottom: 8 })
        }, (w: Word): string => `fb-${w.id}`)
      }
    }.width('100%')
  }

  @Builder
  SentenceList() {
    List({ space: 12 }) {
      if (this.batchStates.length > 0) {
        ForEach(this.currentState().sentences, (s: GeneratedSentence, idx: number) => {
          ListItem() {
            this.SentenceCard(s)
          }
          .opacity(this.contentOpacity)
          .translate({ y: this.contentOpacity === 1 ? 0 : 8 })
        }, (s: GeneratedSentence, idx: number): string => `sent-${idx}-${s.sentence.slice(0, 12)}`)
      }
    }
    .layoutWeight(1).width('100%').padding({ left: 16, right: 16, top: 2, bottom: 110 })
    .scrollBar(BarState.Off)
  }

  @Builder
  LoadingList() {
    Column({ space: 12 }) {
      Text('正在用今天的词造句…').fontSize(13).fontColor(Colors.TEXT_WEAK).margin({ top: 4 })
      this.SkeletonCard()
      this.SkeletonCard()
      this.SkeletonCard()
      Blank()
    }.layoutWeight(1).width('100%').padding({ left: 16, right: 16 })
  }

  /** 分享卡面（白底 4:5，离屏快照源） */
  @Builder
  SentenceShareView() {
    Column() {
      Row() {
        Text('词慧 · 今日例句').fontSize(12).fontColor('rgba(255,255,255,0.78)')
        Blank()
      }.width('100%')
      Blank()
      if (this.shareTarget !== null) {
        Text(this.shareTarget.sentence)
          .fontSize(22).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE).lineHeight(32).width('100%')
        Text(this.shareTarget.translation)
          .fontSize(14).fontColor('rgba(255,255,255,0.82)').lineHeight(22).width('100%').margin({ top: 14 })
      }
      Blank()
      Text('词慧 · 让背单词变有趣')
        .fontSize(11).fontColor('rgba(255,255,255,0.66)').width('100%')
    }
    .width('100%').aspectRatio(0.8).borderRadius(20).padding(20)
    .linearGradient({ angle: 135, colors: [[Colors.BRAND, 0], [Colors.BRAND_PRESSED, 1]] })
  }

  @Builder
  SnapshotSentence() {
    Column() {
      this.SentenceShareView()
    }.width(360)
  }

  private currentState(): BatchState {
    if (this.batchStates.length === 0) {
      return new BatchState(0);
    }
    return this.batchStates[this.current];
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        if (this.todayCount < MIN_WORDS_FOR_SENTENCE && this.batchStates.length === 0) {
          this.EmptyGate()
        } else {
          this.BatchTabs()
          this.BatchHeader()
          if (this.currentState().status === 'loading') {
            this.LoadingList()
          } else if (this.currentState().status === 'fallback') {
            Scroll() {
              this.FallbackList()
            }.layoutWeight(1).width('100%').scrollBar(BarState.Off).padding({ bottom: 110 })
          } else {
            this.SentenceList()
          }
        }
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
    }
    .hideTitleBar(true)
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity + this.showTick * 0)
    .onShown(() => {
      this.showTick++;
      this.animateCovered(true);
      this.reload();
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
