/**
 * F5 词书详情页：书封 / 书名 / 版本标签 / 总词数 / 单词预览；右上角「下载导入」。
 * 下载：F14 起强制登录，未登录弹引导跳登录页 → 压暗 + 中心卡片转圈百分比
 * → 从随包词库（rawfile，开源 ECDICT）读取整本词书，单次事务落库
 * （失败不产生半截词书，可重试）→ 自动返回我的词本，新书置顶带「刚导入」，可连续导入。
 * 分年级词书内容未接入（coming），详情页显示「筹备中」，不提供下载。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { AuthStore } from '../../viewmodel/AuthStore';
import { RouteName } from '../../common/RouteNames';
import type { BookWordsRouteParam, CloudBookDetailRouteParam } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { findCloudBook, getSampleWords } from '../../service/CloudCatalog';
import { CloudBookLoader } from '../../service/CloudBookLoader';
import type { CloudBookMeta, CloudSampleWord } from '../../service/CloudCatalog';
import type { WordBook } from '../../model/Types';
import { promptAction } from '@kit.ArkUI';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

type Phase = 'idle' | 'gate' | 'downloading' | 'error';

@ComponentV2
export struct CloudBookDetailPage {
  @Require @Param param: CloudBookDetailRouteParam;
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.CLOUD_BOOK_DETAIL) {
      this.showTick++;
    }
  };
  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
  }

  @Local sheetOpacity: number = 0;
  @Local phase: Phase = 'idle';
  @Local percent: number = 0;
  @Local confirmRemove: boolean = false;
  private meta: CloudBookMeta | null = findCloudBook(this.param.cloudBookId);
  private samples: CloudSampleWord[] = getSampleWords(this.param.cloudBookId);
  private timerId: number = -1;

  private animateCovered(covered: boolean): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : Motion.PAGE, curve: Curve.EaseOut },
      () => {
        NavStore.INSTANCE.covered = covered;
      }
    );
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (e) {
    }
  }

  private imported(): boolean {
    return DataStore.INSTANCE.isCloudBookImported(this.param.cloudBookId);
  }

  /** 点击右上角：筹备中词书只提示；未导入走下载；已导入走移除确认 */
  private onHeaderAction(): void {
    if (this.meta && this.meta.coming === true) {
      this.toast('该词书正在接入开源教材词表，暂未开放');
      return;
    }
    if (this.imported()) {
      this.confirmRemove = true;
      return;
    }
    // F14：下载强制登录，未登录弹引导跳登录页；登录后再次点击直接下载
    if (!AuthStore.INSTANCE.isLoggedIn()) {
      this.phase = 'gate';
      return;
    }
    this.startDownload();
  }

  private startDownload(): void {
    this.phase = 'downloading';
    this.percent = 8;
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    // 本地词库读取很快，进度卡主要用于反馈「正在导入」；真实服务端接入后换成网络进度
    this.timerId = setTimeout((): void => {
      this.percent = 46;
      this.runImport();
    }, 260);
  }

  private async runImport(): Promise<void> {
    if (!this.meta) {
      this.phase = 'error';
      return;
    }
    try {
      const words: CloudSampleWord[] = await CloudBookLoader.loadBook(this.meta.id);
      if (words.length === 0) {
        this.phase = 'error';
        return;
      }
      this.percent = 88;
      DataStore.INSTANCE.importCloudBook(this.meta.name, this.meta.id, words);
      this.percent = 100;
      this.toast(`已导入《${this.meta.name}》`);
      setTimeout((): void => {
        // P11：导入完成直接落在「我的词本」且新书立即可见（键控重挂载）。
        NavStore.INSTANCE.backToTabThenPush(2, RouteName.MY_BOOKS);
      }, 500);
    } catch (e) {
      this.phase = 'error';
    }
  }

  private doRemove(): void {
    const book: WordBook | undefined = DataStore.INSTANCE.books.find(
      (b: WordBook): boolean => b.cloudBookId === this.param.cloudBookId);
    if (book) {
      DataStore.INSTANCE.deleteBook(book.id);
      this.toast('已移除该词书');
    }
    this.confirmRemove = false;
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())

      Text(this.meta ? this.meta.name : '词书详情')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(this.imported() ? '已导入' : (this.meta && this.meta.coming === true ? '筹备中' : '下载导入'))
        .fontSize(13)
        .fontColor(this.imported() || (this.meta && this.meta.coming === true) ? Colors.TEXT_WEAK : Colors.WHITE)
        .backgroundColor(this.imported() || (this.meta && this.meta.coming === true) ? Colors.DIVIDER : Colors.BRAND)
        .borderRadius(14)
        .height(30).padding({ left: 12, right: 12 })
        .textAlign(TextAlign.Center)
        .margin({ right: 4 })
        .onClick(() => this.onHeaderAction())
    }
    .width('100%').height(56)
  }

  @Builder
  CoverCard() {
    Row() {
      Column() {
        Text(this.meta ? this.meta.name.substring(0, 1) : '词')
          .fontSize(26).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
      }
      .width(72).height(72).borderRadius(14).backgroundColor(Colors.BRAND)
      .justifyContent(FlexAlign.Center)

      Column() {
        Text(this.meta ? this.meta.name : '')
          .fontSize(19).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
          .width('100%').textAlign(TextAlign.Start)
        Text(this.meta ? this.meta.version : '')
          .fontSize(12).fontColor(Colors.TEXT_SUB).margin({ top: 6 })
          .width('100%').textAlign(TextAlign.Start)
        Row() {
          if (this.meta && this.meta.coming === true) {
            Text('教材词表接入中，暂未开放下载')
              .fontSize(11).fontColor(Colors.FUZZY_ORANGE).layoutWeight(1)
          } else {
            Text(this.meta ? `共 ${this.meta.totalCount} 词 · 离线词库` : '')
              .fontSize(11).fontColor(Colors.TEXT_WEAK).layoutWeight(1)
            Text(`预览 ${this.samples.length} 词`)
              .fontSize(11).fontColor(Colors.BRAND)
              .backgroundColor('#EAF1FF').borderRadius(8)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          }
        }
        .width('100%').margin({ top: 8 })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 14 })
    }
    .width('100%').padding(16).backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
  }

  @Builder
  PreviewList() {
    Row() {
      Text('单词预览')
        .fontSize(14).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN).layoutWeight(1)
      if (this.meta && this.meta.coming !== true) {
        Text(`查看全部 ${this.meta.totalCount} 词 ›`)
          .fontSize(12).fontColor(Colors.BRAND)
          .onClick(() => {
            if (this.meta) {
              const cid: string = this.meta.id;
              const p: BookWordsRouteParam = { cloudBookId: cid };
              NavStore.INSTANCE.push(RouteName.BOOK_WORDS, p);
            }
          })
      }
    }
    .width('100%').margin({ top: 18, bottom: 10 })
    if (this.samples.length === 0) {
      Column() {
        Text('词书内容正在接入开源教材词表')
          .fontSize(13).fontColor(Colors.TEXT_WEAK)
        Text('开放下载后可在此预览单词')
          .fontSize(12).fontColor(Colors.TEXT_WEAK).margin({ top: 6 })
      }
      .width('100%').padding({ top: 28, bottom: 28 })
      .backgroundColor(Colors.WHITE).borderRadius(14)
      .justifyContent(FlexAlign.Center)
    } else {
      Column() {
        ForEach(this.samples, (w: CloudSampleWord) => {
          Row() {
            Text(w.english).fontSize(15).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
              .layoutWeight(1)
            Text(w.meaning).fontSize(13).fontColor(Colors.TEXT_SUB).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '52%' })
              .textAlign(TextAlign.End)
          }
          .width('100%').height(46)
          .padding({ left: 14, right: 14 })
          .backgroundColor(Colors.WHITE)
        }, (w: CloudSampleWord): string => w.english)
      }
      .width('100%').borderRadius(14).clip(true)
    }
  }

  @Builder
  GateModal() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor('#66000000')
        .onClick(() => {
          this.phase = 'idle';
        })
      Column() {
        Text('登录后下载').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        Text('云词本下载与自动备份需要登录账号。登录后词书与学习进度可云备份、换机恢复。')
          .fontSize(13).fontColor(Colors.TEXT_SUB).lineHeight(20).margin({ top: 12 })
          .textAlign(TextAlign.Center)
        Button('去登录')
          .width('100%').height(44).borderRadius(Radius.BUTTON)
          .fontSize(14).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND).margin({ top: 20 })
          .onClick(() => {
            this.phase = 'idle';
            NavStore.INSTANCE.push(RouteName.LOGIN);
          })
        Button('暂不')
          .width('100%').height(42)
          .fontSize(14).fontColor(Colors.TEXT_SUB).type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.phase = 'idle';
          })
      }
      .width('82%').padding(22).backgroundColor(Colors.WHITE).borderRadius(Radius.SHEET)
    }
    .width('100%').height('100%')
  }

  @Builder
  DownloadingModal() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor('#66000000')
      Column() {
        if (this.percent >= 100) {
          Text('✓').fontSize(26).fontColor(Colors.KNOW_GREEN).fontWeight(FontWeight.Bold)
          Text('下载完成').fontSize(15).fontColor(Colors.TEXT_MAIN).margin({ top: 8 })
        } else {
          LoadingProgress().width(38).height(38).color(Colors.BRAND)
          Text('正在导入词书…').fontSize(15).fontColor(Colors.TEXT_MAIN).margin({ top: 10 })
          Text(`${this.percent}%`).fontSize(13).fontColor(Colors.TEXT_SUB).margin({ top: 6 })
        }
      }
      .width(200).padding({ top: 26, bottom: 26 })
      .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%').height('100%')
  }

  @Builder
  ErrorModal() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor('#66000000')
      Column() {
        Text('下载失败').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        Text('词书导入失败，没有产生半截数据。可重试或返回。')
          .fontSize(13).fontColor(Colors.TEXT_SUB).margin({ top: 12 }).textAlign(TextAlign.Center)
        Row() {
          Button('取消')
            .layoutWeight(1).height(42).borderRadius(Radius.BUTTON).fontSize(14)
            .fontColor(Colors.TEXT_SUB).backgroundColor(Colors.PAGE_BG)
            .onClick(() => {
              this.phase = 'idle';
            })
          Button('重试')
            .layoutWeight(1).height(42).borderRadius(Radius.BUTTON).fontSize(14)
            .fontColor(Colors.WHITE).backgroundColor(Colors.BRAND).margin({ left: 12 })
            .onClick(() => this.startDownload())
        }
        .width('100%').margin({ top: 20 })
      }
      .width('80%').padding(22).backgroundColor(Colors.WHITE).borderRadius(Radius.SHEET)
    }
    .width('100%').height('100%')
  }

  @Builder
  RemoveModal() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor('#66000000')
        .onClick(() => {
          this.confirmRemove = false;
        })
      Column() {
        Text('移除该词书？').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        Text('将一并删除其单词、学习记录与复习排期，历史打卡统计可能变化。')
          .fontSize(13).fontColor(Colors.TEXT_SUB).lineHeight(20).margin({ top: 12 })
          .textAlign(TextAlign.Center)
        Row() {
          Button('取消')
            .layoutWeight(1).height(42).borderRadius(Radius.BUTTON).fontSize(14)
            .fontColor(Colors.TEXT_SUB).backgroundColor(Colors.PAGE_BG)
            .onClick(() => {
              this.confirmRemove = false;
            })
          Button('移除')
            .layoutWeight(1).height(42).borderRadius(Radius.BUTTON).fontSize(14)
            .fontColor(Colors.WHITE).backgroundColor(Colors.UNKNOWN_RED).margin({ left: 12 })
            .onClick(() => this.doRemove())
        }
        .width('100%').margin({ top: 20 })
      }
      .width('82%').padding(22).backgroundColor(Colors.WHITE).borderRadius(Radius.SHEET)
    }
    .width('100%').height('100%')
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Column() {
          this.TopBar()
          if (!this.meta) {
            Column() {
              Text('词书不存在或已下架').fontSize(14).fontColor(Colors.TEXT_WEAK)
            }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          } else {
            Scroll() {
              Column() {
                this.CoverCard()
                this.PreviewList()
                if (this.meta && this.meta.coming !== true) {
                  Text('词库来自开源 ECDICT（MIT 许可），随包内置，导入不耗流量')
                    .fontSize(11).fontColor(Colors.TEXT_WEAK).textAlign(TextAlign.Center)
                    .width('100%').margin({ top: 18, bottom: 24 })
                }
              }
              .width('100%').padding({ left: 16, right: 16 })
              .alignItems(HorizontalAlign.Start)
            }
            .layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)
          }
        }
        .width('100%').height('100%')

        if (this.phase === 'gate') {
          this.GateModal()
        } else if (this.phase === 'downloading') {
          this.DownloadingModal()
        } else if (this.phase === 'error') {
          this.ErrorModal()
        }
        if (this.confirmRemove) {
          this.RemoveModal()
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
