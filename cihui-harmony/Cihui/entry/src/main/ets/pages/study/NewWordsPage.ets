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
import type { SpeechRouteParam } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import type { Word } from '../../model/Types';
import { TtsService } from '../../service/TtsService';
import type { TtsState } from '../../service/TtsService';
import { promptAction } from '@kit.ArkUI';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

@ComponentV2
export struct NewWordsPage {
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
  @Local words: Word[] = DataStore.INSTANCE.todayNewWordList();
  @Local index: number = 0;
  @Local ttsState: TtsState = 'idle';
  /** 是否已浏览到最后一张（整批浏览完成的唯一凭据） */
  @Local reachedEnd: boolean = false;
  private swiperController: SwiperController = new SwiperController();
  private studiedMarked: boolean = false;
  private speakTimer: number = -1;

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
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

  /** 末张 CTA：携带本批词 id 进入 F8 语音快过 */
  private startTest(): void {
    if (!this.reachedEnd) {
      this.toast('请先把本批新词浏览完');
      return;
    }
    TtsService.stop();
    const ids: string[] = this.words.map((w: Word): string => w.id);
    const param: SpeechRouteParam = { wordIds: ids };
    NavStore.INSTANCE.push(RouteName.SPEECH_TEST, param);
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())

      Text('新词首学')
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
              Button('开始语音测试')
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
