/**
 * F5 我的词本页：
 * - 默认空列表（硬约束：不预置假数据），词本只来自拍照/OCR 导入、DIY 新建、云词本下载；
 * - 卡片逐行 stagger 入场；右上角「导入云词本」、右下角圆形快门 FAB（等价 F3 入口）；
 * - 新下载的云词书置顶并显示绿色「刚导入」标记（以本页创建时间为界）。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { RouteName } from '../../common/RouteNames';
import type { BookWordsRouteParam, CameraRouteParam } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import type { WordBook } from '../../model/Types';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';
import { resetTodaySession } from '../../viewmodel/StudyEntry';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

function sourceLabel(book: WordBook): string {
  if (book.source === 'MEME') {
    return '梗句词本';
  }
  if (book.source === 'CLOUD') {
    return '云词本 · ECDICT 词库';
  }
  if (book.source === 'DIY_PHOTO') {
    return '拍照导入';
  }
  return '个人 DIY';
}

/** 卡片快照：把「背诵中」等派生状态固化进数据源，切换词本后新数组才能驱动 ForEach 重建 */
interface BookRowVM {
  book: WordBook;
  wordCount: number;
  fresh: boolean;
  learning: boolean;
}

@ComponentV2
struct BookTile {
  @Require @Param book: WordBook;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.book.source === 'DIY_PHOTO') {
        Image($r('app.media.ic_camera')).width(22).height(22).fillColor(Colors.FUZZY_ORANGE)
      } else if (this.book.source === 'MEME') {
        Text('梗').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Colors.BRAND)
      } else {
        Text(this.book.source === 'CLOUD' ? '云' : 'DIY')
          .fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(Colors.WHITE)
      }
    }
    .width(44).height(44).borderRadius(12)
    .backgroundColor(this.book.source === 'DIY_PHOTO' ? Colors.FUZZY_ORANGE_SOFT
      : this.book.source === 'MEME' ? Colors.BRAND_SOFT : Colors.BRAND)
  }
}

@ComponentV2
struct BookCardView {
  @Require @Param book: WordBook;
  @Require @Param wordCount: number;
  @Require @Param fresh: boolean;
  @Require @Param learning: boolean;
  @Require @Param index: number;
  @Require @Param onTap: (book: WordBook) => void;
  @Require @Param onSwitch: (book: WordBook) => void;
  @Local cardOpacity: number = 0;
  @Local cardTy: number = 14;

  aboutToAppear(): void {
    const delay: number = Math.min(this.index * 45, 360);
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
        this.cardOpacity = 1;
        this.cardTy = 0;
      });
    }, delay);
  }

  build() {
    Row() {
      // 详情区：点这里进「全书单词」（与「切换」按钮分开，点切换不会误入详情）
      Row() {
        BookTile({ book: this.book })
        Column() {
          Row() {
            Text(this.book.name)
              .fontSize(TypeScale.CARD_TITLE)
              .fontWeight(FontWeight.Medium)
              .fontColor(Colors.TEXT_MAIN)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.book.source === 'MEME') {
              Text('梗句')
                .fontSize(11)
                .fontColor(Colors.BRAND)
                .backgroundColor(Colors.BRAND_SOFT)
                .borderRadius(8)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .margin({ right: 6 })
            }
            if (this.learning) {
              // F-D 一次只能背一本：当前背诵中的词本
              Text('背诵中')
                .fontSize(11)
                .fontColor(Colors.WHITE)
                .backgroundColor(Colors.BRAND)
                .borderRadius(8)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .margin({ right: 6 })
            }
            if (this.fresh) {
              Text('刚导入')
                .fontSize(11)
                .fontColor(Colors.KNOW_GREEN)
                .backgroundColor(Colors.KNOW_GREEN_SOFT)
                .borderRadius(8)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .margin({ right: 6 })
            }
            Text('›').fontSize(22).fontColor(Colors.TEXT_WEAK)
          }
          .width('100%')

          Text(`${this.wordCount} 个词 · ${sourceLabel(this.book)}`)
            .fontSize(TypeScale.CAPTION)
            .fontColor(Colors.TEXT_SUB)
            .margin({ top: 6 })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
      }
      .layoutWeight(1)
      .onClick(() => this.onTap(this.book))

      // 切换背诵词本入口：解决「导入高考词汇后回不到四级词汇」
      if (!this.learning) {
        Text('切换')
          .fontSize(12)
          .fontColor(Colors.BRAND)
          .borderRadius(13)
          .borderWidth(1)
          .borderColor(Colors.BRAND)
          .height(26)
          .padding({ left: 12, right: 12 })
          .textAlign(TextAlign.Center)
          .margin({ left: 8 })
          .onClick(() => this.onSwitch(this.book))
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Colors.WHITE)
    .borderRadius(Radius.CARD)
    .margin({ bottom: 12 })
    .opacity(this.cardOpacity)
    .translate({ y: this.cardTy })
  }
}

@ComponentV2
export struct MyBooksPage {
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 0;
  /** 动态QA：页面每次重新显示时自增，强制重算词本列表（BUG-01） */
  @Local showTick: number = 0;
  /** 词本卡片快照（含「背诵中」派生状态），切换词本后整体替换驱动列表重建 */
  @Local rows: BookRowVM[] = [];
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    const top: string = names.length > 0 ? names[names.length - 1] : '(empty)';
    hilog.info(0x0000, 'CihuiBus', 'MyBooks listener top=%{public}s books=%{public}d tick=%{public}d',
      top, DataStore.INSTANCE.books.length, this.showTick);
    if (names.length > 0 && names[names.length - 1] === RouteName.MY_BOOKS) {
      this.showTick++;
      this.rebuildRows();
    }
  };
  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    this.rebuildRows();
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
  }

  /** 本页创建时刻：之后产生的词本标记「刚导入」 */
  @Local freshCutoff: number = Date.now();

  /** 重建卡片快照：词数 / 刚导入 / 背诵中 全部按仓库当前状态重算 */
  private rebuildRows(): void {
    const out: BookRowVM[] = [];
    for (const b of DataStore.INSTANCE.books) {
      const row: BookRowVM = {
        book: b,
        wordCount: DataStore.INSTANCE.wordCountOfBook(b.id),
        fresh: b.createdAt > this.freshCutoff,
        learning: DataStore.INSTANCE.isBookLearning(b.id),
      };
      out.push(row);
    }
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

  private openBook(book: WordBook): void {
    // 真机反馈 #22：任意词本点进去先看「全书单词」（全量、可搜索），
    // 全书页内再按来源给「编辑（DIY/拍照）/ 背诵（梗句）」主动作。
    const p: BookWordsRouteParam = { bookId: book.id };
    NavStore.INSTANCE.push(RouteName.BOOK_WORDS, p);
  }

  /**
   * F-D 切换背诵词本（真机反馈：导入高考词汇后无法切回四级词汇）。
   * 一次只能背一本：旧词本未学新词暂停排期，已学复习照常；新词本被暂停的新词从今天起重排。
   */
  private onSwitchBook(book: WordBook): void {
    if (DataStore.INSTANCE.isBookLearning(book.id)) {
      return;
    }
    const activeId: string = DataStore.INSTANCE.activeBookId();
    const activeBook: WordBook | null = DataStore.INSTANCE.bookById(activeId);
    const unlearned: number = activeId.length > 0
      ? DataStore.INSTANCE.unlearnedCountOfBook(activeId) : 0;
    let msg: string = '';
    if (activeBook !== null && unlearned > 0) {
      msg = `当前在背《${activeBook.name}》，还有 ${unlearned} 个新词没学。切换后它会暂停排期（已学的复习照常），《${book.name}》的新词从今天起接着排。`;
    } else if (activeBook !== null) {
      msg = `《${activeBook.name}》的新词已全部学完，切换后只保留复习；《${book.name}》的新词从今天起接着排。`;
    } else {
      msg = `《${book.name}》将成为当前背诵词本，新词按每日新词量从今天起排期。`;
    }
    try {
      promptAction.showDialog({
        title: `切换到《${book.name}》？`,
        message: msg,
        buttons: [
          { text: '取消', color: Colors.TEXT_SUB },
          { text: '切换', color: Colors.BRAND },
        ],
      }, (err: Error, result: promptAction.ShowDialogSuccessResponse) => {
        if (!err && result.index === 1) {
          DataStore.INSTANCE.switchActiveBook(book.id);
          // 旧书的今日任务作废：会话里钉住的那批词已暂停排期，不清会继续显示旧书的「第 N 组」
          resetTodaySession();
          this.showTick++;
          this.rebuildRows();
          try {
            promptAction.showToast({ message: `已切换到《${book.name}》，今日任务已更新`, duration: 1800 });
          } catch (e) {
          }
          // 首页/打卡的今日任务由 Tab 页首建时计算：留在本页会使它们显示切书前的数字，
          // 因此切换后回首页，让 Tab 页按最新仓库重建（用户下一步正是去学新书）。
          setTimeout((): void => {
            NavStore.INSTANCE.backToTab(0);
          }, 700);
        }
      });
    } catch (e) {
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

      Text('我的词本')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Row() {
        Image($r('app.media.ic_cloud')).width(18).height(18)
        Text('导入云词本').fontSize(13).fontColor(Colors.BRAND).margin({ left: 3 })
      }
      .height(44)
      .padding({ left: 6, right: 10 })
      .justifyContent(FlexAlign.Center)
      .onClick(() => NavStore.INSTANCE.push(RouteName.CLOUD_LIBRARY))
    }
    .width('100%')
    .height(56)
  }

  @Builder
  EmptyState() {
    Column() {
      Column() {
        Image($r('app.media.ic_camera')).width(34).height(34).fillColor(Colors.TEXT_WEAK)
      }
      .width(76).height(76).borderRadius(38).backgroundColor(Colors.WHITE)
      .justifyContent(FlexAlign.Center)

      Text('还没有词本').fontSize(TypeScale.CARD_TITLE).fontColor(Colors.TEXT_MAIN).margin({ top: 16 })
      Text('拍照导入词表，或从云词本下载一本开始背')
        .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB).margin({ top: 8 })
      Button('浏览云词本')
        .fontSize(TypeScale.BODY).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
        .borderRadius(Radius.BUTTON).height(46).width(200).margin({ top: 22 })
        .onClick(() => NavStore.INSTANCE.push(RouteName.CLOUD_LIBRARY))
      Text('也可以点右下角快门直接拍照导入')
        .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_WEAK).margin({ top: 14 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Column() {
          this.TopBar()
          Text('拍下 / 下载的词本保存在本地，登录后自动上云备份')
            .fontSize(12).fontColor(Colors.TEXT_WEAK)
            .width('100%').padding({ left: 20, right: 20, bottom: 10 })

          if (this.rows.length === 0) {
            this.EmptyState()
          } else {
            List({ space: 0 }) {
              ForEach(this.rows, (row: BookRowVM, index: number) => {
                ListItem() {
                  BookCardView({
                    book: row.book,
                    wordCount: row.wordCount,
                    fresh: row.fresh,
                    learning: row.learning,
                    index,
                    onTap: (b: WordBook): void => this.openBook(b),
                    onSwitch: (b: WordBook): void => this.onSwitchBook(b),
                  })
                }
              }, (row: BookRowVM): string =>
                // key 带上派生状态：ArkUI 对 key 相同的 ForEach item 不做子组件参数更新，
                // 切换词本后「背诵中」徽章不会迁移，故把 learning/词数并入 key 强制重建
                `${row.book.id}-${row.learning ? 'on' : 'off'}-${row.wordCount}`)
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ left: 16, right: 16 })
            .scrollBar(BarState.Off)
          }
        }
        .width('100%').height('100%')

        // 右下角圆形快门 FAB（等价 F3 拍照入口）
        Button() {
          Image($r('app.media.ic_camera')).width(26).height(26)
        }
        .type(ButtonType.Circle)
        .width(60).height(60)
        .backgroundColor(Colors.BRAND)
        .shadow({ radius: 14, color: '#330A59F7', offsetX: 0, offsetY: 6 })
        .margin({ right: 20, bottom: 28 })
        .onClick(() => {
          const p: CameraRouteParam = { from: 'books' };
          NavStore.INSTANCE.push(RouteName.CAMERA, p);
        })
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
    }
    .hideTitleBar(true)
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity + this.showTick * 0)
    .onShown(() => {
      this.animateCovered(true);
      this.showTick++;
      this.rebuildRows();
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
