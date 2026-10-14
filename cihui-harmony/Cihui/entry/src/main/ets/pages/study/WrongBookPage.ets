/**
 * F10 错词本
 *
 * - 新词快过（F8）与复习闪卡（F9）判「不认识」的词自动进入错词本（status=WRONG，清零转明天新词）；
 *   判「模糊」且本轮未清账（forceNextDay）的词以「模糊 · 次日强制复习」标签出现；
 * - 列表显示英文、中文释义、原因标签；行左滑露出「移出」（系统 SwipeAction，松手在删除区自动收起）；
 * - 底部「开始错词强化复习」复用 F9 同一套闪卡与调度（mode='WRONG'），
 *   通过后按新词重新进入艾宾浩斯 R1 节点；
 * - 首页错词角标与本列表同源（buildWrongEntries），移出 / 强化通过后实时减少；
 * - 空态给鼓励性图标与文案，不展示空列表。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
import type { ReviewRouteParam } from '../../common/RouteNames';
import type { Word } from '../../model/Types';
import type { WrongEntry } from '../../model/SchedulerCore';
import { promptAction } from '@kit.ArkUI';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

/** 列表行视图模型（错词条目 + 单词展示字段） */
@ObservedV2
class WrongRow {
  wordId: string;
  english: string;
  phonetic: string;
  meanings: string;
  reason: string;
  kind: string;

  constructor(word: Word, entry: WrongEntry) {
    this.wordId = word.id;
    this.english = word.english;
    this.phonetic = word.phonetic;
    this.meanings = word.meanings.join('；');
    this.reason = entry.reason;
    this.kind = entry.kind;
  }
}

@ComponentV2
export struct WrongBookPage {
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.WRONG_BOOK) {
      this.showTick++;
    }
  };
  @Local sheetOpacity: number = 0;
  @Local rows: WrongRow[] = [];

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    this.reload();
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
  }

  private reload(): void {
    const entries: WrongEntry[] = DataStore.INSTANCE.wrongEntries();
    const out: WrongRow[] = [];
    entries.forEach((entry: WrongEntry): void => {
      const w: Word | undefined =
        DataStore.INSTANCE.words.find((x: Word): boolean => x.id === entry.wordId);
      if (w !== undefined) {
        out.push(new WrongRow(w, entry));
      }
    });
    this.rows = out;
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
      console.warn(`[WrongBook] toast failed: ${(e as Error)?.message ?? e}`);
    }
  }

  /** 左滑移出：不做强化，恢复普通学习/复习流程 */
  private removeRow(row: WrongRow): void {
    DataStore.INSTANCE.removeWrong(row.wordId);
    this.reload();
    this.toast(`已将「${row.english}」移出错词本`);
  }

  /** 开始错词强化复习：复用 F9 闪卡，通过后按新词重新进入艾宾浩斯节点 */
  private startStrengthen(): void {
    if (this.rows.length === 0) {
      return;
    }
    const ids: string[] = this.rows.map((r: WrongRow): string => r.wordId);
    const param: ReviewRouteParam = { wordIds: ids, title: '错词强化复习', mode: 'WRONG' };
    NavStore.INSTANCE.push(RouteName.REVIEW_CARDS, param);
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())

      Text('错词本')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Row().width(44).height(44)
    }
    .width('100%')
    .height(56)
  }

  @Builder
  RuleBar() {
    Row() {
      Text('判「不认识」转明天新词；判「模糊」次日强制复习。左滑可移出错词本，或点底部按钮开始强化复习。')
        .fontSize(12).fontColor(Colors.FUZZY_ORANGE)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(Colors.FUZZY_ORANGE_SOFT)
    .borderRadius(Radius.CARD)
    .margin({ left: 16, right: 16, bottom: 10 })
  }

  @Builder
  Tag(row: WrongRow) {
    Text(row.reason)
      .fontSize(11)
      .fontColor(row.kind === 'UNKNOWN' ? Colors.UNKNOWN_RED : Colors.FUZZY_ORANGE)
      .backgroundColor(row.kind === 'UNKNOWN' ? Colors.UNKNOWN_RED_SOFT : Colors.FUZZY_ORANGE_SOFT)
      .borderRadius(8)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .margin({ top: 8 })
  }

  @Builder
  RowContent(row: WrongRow) {
    Column() {
      Row() {
        Text(row.english)
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(row.phonetic)
          .fontSize(13).fontColor(Colors.TEXT_WEAK).margin({ left: 10 })
      }
      .width('100%')

      Text(row.meanings)
        .fontSize(14).fontColor(Colors.TEXT_SUB).maxLines(2).width('100%')
        .margin({ top: 5 })
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      this.Tag(row)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .backgroundColor(Colors.WHITE)
  }

  @Builder
  DeleteAction(row: WrongRow) {
    Button('移出')
      .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.UNKNOWN_RED)
      .width(84).height('100%').borderRadius(0)
      .onClick(() => this.removeRow(row))
  }

  @Builder
  ListView() {
    List({ space: 10 }) {
      ForEach(this.rows, (row: WrongRow) => {
        ListItem() {
          this.RowContent(row)
        }
        .borderRadius(Radius.CARD)
        .swipeAction({
          end: {
            builder: () => {
              this.DeleteAction(row)
            },
            onAction: () => this.removeRow(row),
          }
        })
      }, (row: WrongRow): string => row.wordId)
    }
    .width('100%').layoutWeight(1)
    .padding({ left: 16, right: 16, top: 2 })
    .scrollBar(BarState.Off)
  }

  @Builder
  EmptyView() {
    Column() {
      Blank()
      Stack() {
        Circle({ width: 96, height: 96 }).fill(Colors.KNOW_GREEN_SOFT)
        Image($r('app.media.ic_wrong')).width(40).height(40).fillColor(Colors.KNOW_GREEN)
      }
      .width(120).height(120)

      Text('保持得很好')
        .fontSize(TypeScale.TITLE_LARGE).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .margin({ top: 18 })
      Text('近期没有错词，继续按节奏复习就好')
        .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB).margin({ top: 8 })
      Blank()
    }
    .width('100%').layoutWeight(1)
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        if (this.rows.length === 0) {
          this.EmptyView()
        } else {
          this.RuleBar()
          this.ListView()
          Button(`开始错词强化复习（${this.rows.length}）`)
            .fontSize(16).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
            .borderRadius(Radius.BUTTON).height(50).width('92%')
            .margin({ bottom: 24 })
            .onClick(() => this.startStrengthen())
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
