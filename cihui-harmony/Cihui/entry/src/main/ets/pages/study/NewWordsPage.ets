/**
 * F7 新词首学 · 批量幻灯片（方案 B）+ 英文 TTS
 *
 * - 今日新词整批快速浏览：英文大号 + 音标 + 喇叭 + 中文释义 + 引导语；
 * - 顶部进度点与 x / 总数；底部「上一个 / 下一个」，最后一张变「开始语音测试」；
 * - 进卡与切卡自动朗读英文（HMS textToSpeech，语速读 settings.ttsRate），喇叭重播；
 * - 左右滑动切换（Swiper 横向滑动 + EaseOut），按钮为等价操作；
 * - 必须浏览到最后一张才允许进 F8（F8 未上线，CTA 为诚实 Toast 占位，非死按钮）；
 * - 浏览到末张时把整批 firstStudyAt 落库；首过 firstPassedAt 仍由 F8 判定写入。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { RouteName } from '../../common/RouteNames';
import type { NewWordsRouteParam, SpeechRouteParam } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import type { Word } from '../../model/Types';
import { TtsService } from '../../service/TtsService';
import type { TtsState } from '../../service/TtsService';
import { promptAction } from '@kit.ArkUI';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';
import { RoundDraftStore } from '../../service/RoundDraftStore';
import type { BrowseDraft } from '../../service/RoundDraftStore';
import { StudySessionStore } from '../../service/StudySessionStore';

@ComponentV2
export struct NewWordsPage {
  /** 本组词（分组学习：每 10 个一组，看完立刻测这一组） */
  @Require @Param param: NewWordsRouteParam;
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.NEW_WORDS) {
      this.showTick++;
    }
  };
  @Local sheetOpacity: number = 0;
  /** 本组词（aboutToAppear 按 param.wordIds 填充，见 loadGroup） */
  @Local words: Word[] = [];
  @Local index: number = 0;
  @Local ttsState: TtsState = 'idle';
  /** 是否已浏览到最后一张（整批浏览完成的唯一凭据） */
  @Local reachedEnd: boolean = false;
  /** 本次是从断点续上的：onShown 后给一次轻提示（此前的静默续位让人以为没存） */
  @Local pendingResumeTip: boolean = false;
  private swiperController: SwiperController = new SwiperController();
  private studiedMarked: boolean = false;
  private speakTimer: number = -1;

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    this.loadGroup();
    if (this.words.length === 0) {
      // 会话钉住的词已被删词本/切书作废：清失效会话与浏览草稿，回首页按当前计划重排
      RoundDraftStore.clearBrowse();
      StudySessionStore.clear();
      this.toast('这批词已不在今日计划，已按当前计划重排');
      setTimeout((): void => {
        NavStore.INSTANCE.finishToHome();
      }, 400);
      return;
    }
    this.restoreBrowse();
    const rate: number = DataStore.INSTANCE.settings.ttsRate;
    TtsService.init(rate).then((state: TtsState): void => {
      this.ttsState = state;
      this.scheduleSpeak(350);
    });
  }

  /** 本组词：按会话传入的 wordIds 取（不再用今日全部新词，否则会串组） */
  private loadGroup(): void {
    const ids: string[] = this.param.wordIds ?? [];
    const out: Word[] = [];
    ids.forEach((id: string): void => {
      const w: Word | undefined = DataStore.INSTANCE.words.find((x: Word): boolean => x.id === id);
      if (w !== undefined) {
        out.push(w);
      }
    });
    this.words = out;
  }

  /** 顶栏标题：多组时带组号 */
  private groupTitle(): string {
    const total: number = this.param.groupTotal > 0 ? this.param.groupTotal : 1;
    if (total <= 1) {
      return '新词首学';
    }
    return `新词首学 · 第 ${this.param.groupIndex} / ${total} 组`;
  }

  /** 同批（词 id 顺序一致）才续上次看到的那张，避免换批后错位 */
  private restoreBrowse(): void {
    const draft: BrowseDraft | null = RoundDraftStore.loadBrowse();
    if (draft === null || this.words.length === 0) {
      return;
    }
    if (draft.wordIds.length !== this.words.length) {
      return;
    }
    for (let i = 0; i < this.words.length; i++) {
      if (draft.wordIds[i] !== this.words[i].id) {
        return;
      }
    }
    if (draft.index < 0 || draft.index >= this.words.length) {
      return;
    }
    this.index = draft.index;
    if (draft.index > 0) {
      this.pendingResumeTip = true;
    }
    if (draft.reachedEnd) {
      // 已浏览完：整批 firstStudyAt 可能已落库，标记为已到头，CTA 直接可用
      this.reachedEnd = true;
      this.studiedMarked = true;
    }
  }

  /** 落盘浏览位置：离开/杀进程后回到这张 */
  private saveBrowse(): void {
    if (this.words.length === 0) {
      return;
    }
    const ids: string[] = this.words.map((w: Word): string => w.id);
    const draft: BrowseDraft = {
      day: RoundDraftStore.today(),
      wordIds: ids,
      index: this.index,
      reachedEnd: this.reachedEnd,
      savedAt: Date.now(),
    };
    RoundDraftStore.saveBrowse(draft);
  }

  /** 本页是否已有值得保留的浏览进度（第 1 张 + 未到头 = 没进度，不必打扰） */
  private hasProgress(): boolean {
    return this.index > 0 || this.reachedEnd;
  }

  /** 顶栏返回 / 系统返回统一入口：先存进度（退出不丢），再给一次防误触确认 */
  private confirmExit(): void {
    this.saveBrowse();
    if (!this.hasProgress()) {
      NavStore.INSTANCE.back();
      return;
    }
    const total: number = this.words.length;
    const message: string = this.reachedEnd
      ? `本组 ${total} 个词已看完，进度已保存，下次进入直接测这一组。`
      : `已看到第 ${this.index + 1} / ${total} 个词，进度已保存，下次进入从这里继续。`;
    try {
      promptAction.showDialog({
        title: '退出首学？',
        message: message,
        buttons: [
          { text: '继续浏览', color: Colors.BRAND },
          { text: '退出', color: Colors.TEXT_SUB },
        ],
      }, (err: Error, result: promptAction.ShowDialogSuccessResponse) => {
        if (!err && result.index === 1) {
          this.saveBrowse();
          NavStore.INSTANCE.back();
        }
      });
    } catch (e) {
      console.warn(`[NewWords] confirmExit dialog failed: ${(e as Error)?.message ?? e}`);
      NavStore.INSTANCE.back();
    }
  }

  /** 系统返回键：有浏览进度则拦下并二次确认（返回 true 消费事件） */
  private handleBackPressed(): boolean {
    if (!this.hasProgress()) {
      return false;
    }
    this.confirmExit();
    return true;
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
    // 兜底：无论走哪条路离开，都留一份当前位置（幂等，仅百余字节）
    this.saveBrowse();
    if (this.speakTimer !== -1) {
      clearTimeout(this.speakTimer);
      this.speakTimer = -1;
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
      promptAction.showToast({ message: msg, duration: 1800 });
    } catch (e) {
      console.warn(`[NewWords] toast failed: ${(e as Error)?.message ?? e}`);
    }
  }

  /** 延迟朗读当前卡（快速滑卡时只保留最后一次请求） */
  private scheduleSpeak(delay: number): void {
    if (this.speakTimer !== -1) {
      clearTimeout(this.speakTimer);
    }
    const text: string = this.words.length > 0 ? this.words[this.index].english : '';
    this.speakTimer = setTimeout(() => {
      this.speakTimer = -1;
      const ok: boolean = TtsService.speak(text);
      if (!ok && this.ttsState === 'ready') {
        this.ttsState = 'unavailable';
      }
    }, delay);
  }

  private onChange(idx: number): void {
    this.index = idx;
    if (idx >= this.words.length - 1 && !this.studiedMarked) {
      this.studiedMarked = true;
      this.reachedEnd = true;
      const ids: string[] = this.words.map((w: Word): string => w.id);
      DataStore.INSTANCE.markBatchFirstStudied(ids);
    }
    this.saveBrowse();
    this.scheduleSpeak(220);
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
      return '当前设备语音引擎不可用，可先看词浏览，喇叭稍后再试';
    }
    return '';
  }

  private replay(): void {
    if (this.ttsState !== 'ready') {
      const hint: string = this.ttsHintText();
      this.toast(hint.length > 0 ? hint : '语音引擎未就绪，可先看英文与中文继续浏览');
      return;
    }
    const ok: boolean = TtsService.speak(this.words[this.index].english);
    if (!ok) {
      this.toast('朗读失败，请检查设备语音引擎后重试');
    }
  }

  private goPrev(): void {
    if (this.index <= 0) {
      return;
    }
    this.swiperController.showPrevious();
  }

  private goNext(): void {
    if (this.index >= this.words.length - 1) {
      return;
    }
    this.swiperController.showNext();
  }

  /** 末张 CTA：本组浏览完 → 立刻测这一组（只传组内 id，避免串组） */
  private startTest(): void {
    if (!this.reachedEnd) {
      this.toast('请先把这一组看完');
      return;
    }
    TtsService.stop();
    const session = StudySessionStore.begin();
    if (session !== null) {
      StudySessionStore.markBrowseDone(session);
    }
    // 本组浏览凭证已交给会话，浏览草稿清掉，下一组重新计
    RoundDraftStore.clearBrowse();
    const ids: string[] = this.words.map((w: Word): string => w.id);
    const param: SpeechRouteParam = {
      wordIds: ids,
      chunk: true,
      groupIndex: this.param.groupIndex,
      groupTotal: this.param.groupTotal,
      retest: false,
      batchIndex: 0,
      batchTotal: 0,
    };
    NavStore.INSTANCE.push(RouteName.SPEECH_TEST, param);
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => this.confirmExit())

      Text(this.groupTitle())
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Row().width(44).height(44)
    }
    .width('100%')
    .height(56)
  }

  @Builder
  Dots() {
    Row() {
      ForEach(this.words, (w: Word, i: number) => {
        Row()
          .width(i === this.index ? 16 : 6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(i === this.index ? Colors.BRAND : Colors.DIVIDER)
          .margin({ left: 3, right: 3 })
          .animation({ duration: Motion.FEEDBACK, curve: Curve.EaseOut })
      }, (w: Word): string => w.id)
    }
    .height(16)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  WordCard(word: Word) {
    Column() {
      Text(word.english)
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor(Colors.TEXT_MAIN)
        .maxLines(2)
        .textAlign(TextAlign.Center)

      Row() {
        Text(word.phonetic.length > 0 ? word.phonetic : '')
          .fontSize(15)
          .fontColor(Colors.TEXT_SUB)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Button() {
          Image($r('app.media.ic_speaker')).width(20).height(20).fillColor(Colors.BRAND)
        }
        .type(ButtonType.Circle)
        .width(38).height(38)
        .backgroundColor(Colors.BRAND_SOFT)
        .margin({ right: 4 })
        .onClick(() => this.replay())
      }
      .width('72%')
      .margin({ top: 14 })

      Divider().color(Colors.DIVIDER).width('72%').margin({ top: 18, bottom: 18 })

      Text(word.meanings.join('；'))
        .fontSize(20)
        .fontColor(Colors.TEXT_MAIN)
        .textAlign(TextAlign.Center)
        .maxLines(6)
        .width('82%')

      Blank()
      Text('先看英文和中文、听一遍发音，待会儿要口述中文意思')
        .fontSize(TypeScale.CAPTION)
        .fontColor(Colors.TEXT_WEAK)
        .textAlign(TextAlign.Center)
        .width('80%')
        .margin({ bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .padding({ top: 36, bottom: 24, left: 20, right: 20 })
    .backgroundColor(Colors.WHITE)
    .borderRadius(Radius.SHEET)
    .justifyContent(FlexAlign.Start)
  }

  @Builder
  EmptyState() {
    Column() {
      Text('今天没有新词任务')
        .fontSize(TypeScale.CARD_TITLE).fontColor(Colors.TEXT_MAIN)
      Text('先拍照导入词表，或从云词本下载一本词书')
        .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB).margin({ top: 10 })
      Button('返回首页')
        .fontSize(TypeScale.BODY).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
        .borderRadius(Radius.BUTTON).height(46).width(200).margin({ top: 22 })
        .onClick(() => NavStore.INSTANCE.back())
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        if (this.words.length === 0) {
          this.EmptyState()
        } else {
          // 进度：x / 总数
          Text(`${this.index + 1} / ${this.words.length}`)
            .fontSize(14).fontColor(Colors.TEXT_SUB)
            .width('100%').textAlign(TextAlign.Center)
            .margin({ top: 4, bottom: 2 })
          this.Dots()

          if (this.ttsHintText().length > 0) {
            Text(this.ttsHintText())
              .fontSize(12).fontColor(Colors.FUZZY_ORANGE)
              .width('100%').textAlign(TextAlign.Center)
              .margin({ top: 8 })
          }

          Swiper(this.swiperController) {
            ForEach(this.words, (word: Word) => {
              this.WordCard(word)
            }, (word: Word): string => word.id)
          }
          .index(this.index)
          .loop(false)
          .indicator(false)
          .curve(NavStore.INSTANCE.reducedMotion ? Curve.Linear : Curve.EaseOut)
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .onChange((idx: number) => this.onChange(idx))

          // 底部导航：上一个 / 下一个（末张变开始语音测试）
          Row() {
            Button('上一个')
              .fontSize(15)
              .fontColor(this.index === 0 ? Colors.TEXT_WEAK : Colors.TEXT_MAIN)
              .backgroundColor(Colors.WHITE)
              .borderRadius(Radius.BUTTON)
              .height(48)
              .layoutWeight(1)
              .enabled(this.index > 0)
              .opacity(this.index > 0 ? 1 : 0.5)
              .onClick(() => this.goPrev())

            if (this.index < this.words.length - 1) {
              Button('下一个')
                .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
                .borderRadius(Radius.BUTTON).height(48).layoutWeight(1).margin({ left: 12 })
                .onClick(() => this.goNext())
            } else {
              Button(`测这 ${this.words.length} 个`)
                .fontSize(15)
                .fontColor(Colors.WHITE)
                .backgroundColor(this.reachedEnd ? Colors.KNOW_GREEN : Colors.TEXT_WEAK)
                .borderRadius(Radius.BUTTON).height(48).layoutWeight(1).margin({ left: 12 })
                .onClick(() => this.startTest())
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 20 })
        }
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => this.handleBackPressed())
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity + this.showTick * 0)
    .onShown(() => {
      this.animateCovered(true);
      this.showTick++;
      if (this.pendingResumeTip) {
        this.pendingResumeTip = false;
        this.toast(this.reachedEnd
          ? '已恢复上次进度，本组已看完，可直接测这一组'
          : `已恢复上次进度，从第 ${this.index + 1} 个词继续`);
      }
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
