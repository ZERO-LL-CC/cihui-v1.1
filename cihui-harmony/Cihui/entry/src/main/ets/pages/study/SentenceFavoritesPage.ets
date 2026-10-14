/**
 * F19 我的例句本
 *
 * - 默认空列表，在今日例句页点「收藏」后才有数据（DataStore.savedSentenceList 倒序）；
 * - 每条：英文句（收藏时记录的今日词高亮）+ 灰色中文 + 来源日期 + 喇叭朗读；
 * - 左滑露出删除，松手二次确认后删除（deleteSavedSentence），列表自动刷新；
 * - 例句只回看语境，不参与艾宾浩斯调度。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
import type { SavedSentence, SentenceSegment } from '../../model/Types';
import { highlightSegments } from '../../model/SentenceCore';
import { TtsService } from '../../service/TtsService';
import { promptAction } from '@kit.ArkUI';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

@ComponentV2
export struct SentenceFavoritesPage {
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 0;
  @Local showTick: number = 0;
  @Local rows: SavedSentence[] = [];

  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.SENTENCE_FAVORITES) {
      this.showTick++;
      this.reload();
    }
  };

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    const rate: number = DataStore.INSTANCE.settings.ttsRate;
    TtsService.init(rate);
    this.reload();
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
    TtsService.stop();
  }

  private reload(): void {
    this.rows = DataStore.INSTANCE.savedSentenceList();
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
      console.warn(`[SentenceFav] toast: ${(e as Error)?.message ?? e}`);
    }
  }

  private speak(text: string): void {
    const ok: boolean = TtsService.speak(text);
    if (!ok) {
      this.toast('当前设备不支持朗读');
    }
  }

  private askDelete(row: SavedSentence): void {
    try {
      promptAction.showDialog({
        title: '删除这条例句？',
        message: '只从例句本移除，不影响单词与学习记录',
        buttons: [
          { text: '取消', color: Colors.TEXT_SUB },
          { text: '删除', color: Colors.UNKNOWN_RED },
        ],
      }).then((r): void => {
        if (r.index === 1) {
          DataStore.INSTANCE.deleteSavedSentence(row.id);
          this.reload();
          this.toast('已删除');
        }
      });
    } catch (e) {
      console.warn(`[SentenceFav] delete dialog: ${(e as Error)?.message ?? e}`);
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

      Text('我的例句本')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Row().width(44).height(44)
    }
    .width('100%').height(56)
  }

  @Builder
  Highlighted(row: SavedSentence) {
    Text() {
      ForEach(highlightSegments(row.sentence, row.words), (seg: SentenceSegment) => {
        Span(seg.text)
          .fontColor(seg.hit ? Colors.BRAND : Colors.TEXT_MAIN)
          .fontWeight(seg.hit ? FontWeight.Bold : FontWeight.Regular)
      }, (seg: SentenceSegment, idx: number): string => `fseg-${idx}-${seg.hit}`)
    }
    .fontSize(16).lineHeight(24).width('100%')
  }

  @Builder
  RowContent(row: SavedSentence) {
    Row() {
      Column() {
        this.Highlighted(row)
        Text(row.translation)
          .fontSize(13).fontColor(Colors.TEXT_SUB).lineHeight(20).width('100%').margin({ top: 6 })
        Text(`收藏于 ${row.sourceDay}`)
          .fontSize(11).fontColor(Colors.TEXT_WEAK).width('100%').margin({ top: 8 })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)

      Button() {
        Image($r('app.media.ic_speaker')).width(22).height(22).fillColor(Colors.BRAND)
      }
      .type(ButtonType.Circle).width(40).height(40).backgroundColor(Colors.BRAND_SOFT)
      .margin({ left: 10 })
      .onClick(() => this.speak(row.sentence))
    }
    .width('100%').padding(16).backgroundColor(Colors.WHITE)
  }

  @Builder
  DeleteAction(row: SavedSentence) {
    Button('删除')
      .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.UNKNOWN_RED)
      .width(84).height('100%').borderRadius(0)
      .onClick(() => this.askDelete(row))
  }

  @Builder
  FavList() {
    List({ space: 10 }) {
      ForEach(this.rows, (row: SavedSentence) => {
        ListItem() {
          this.RowContent(row)
        }
        .borderRadius(Radius.CARD)
        .swipeAction({
          end: {
            builder: () => {
              this.DeleteAction(row)
            },
            onAction: () => this.askDelete(row),
          }
        })
      }, (row: SavedSentence): string => row.id)
    }
    .layoutWeight(1).width('100%').padding({ left: 16, right: 16, top: 2, bottom: 24 })
    .scrollBar(BarState.Off)
  }

  @Builder
  EmptyView() {
    Column() {
      Blank()
      Stack() {
        Circle({ width: 96, height: 96 }).fill(Colors.BRAND_SOFT)
        Image($r('app.media.ic_sentence')).width(42).height(42).fillColor(Colors.BRAND)
      }.width(120).height(120)
      Text('还没有收藏例句')
        .fontSize(TypeScale.TITLE_LARGE).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .margin({ top: 18 })
      Text('在「今日例句」里点☆收藏，好句子都会收在这里')
        .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB)
        .textAlign(TextAlign.Center).width('72%').margin({ top: 8 })
      Blank()
    }.width('100%').layoutWeight(1)
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        if (this.rows.length === 0) {
          this.EmptyView()
        } else {
          this.FavList()
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
