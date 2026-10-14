/**
 * F5 云词本搜索页：自动聚焦输入；热门搜索 8 标签（前 3 带序号）+ 搜索历史（默认空）；
 * 输入即时过滤词书名 / 版本 / 年级 / 示例词。历史为内存态，杀进程清空（F15 随云备份持久化）。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { CloudSearchStore } from '../../viewmodel/CloudSearchStore';
import { RouteName } from '../../common/RouteNames';
import type { CloudBookDetailRouteParam } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { HOT_SEARCH, searchBooks } from '../../service/CloudCatalog';
import type { CloudBookMeta } from '../../service/CloudCatalog';
import { promptAction } from '@kit.ArkUI';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

@ComponentV2
export struct CloudSearchPage {
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.CLOUD_SEARCH) {
      this.showTick++;
    }
  };
  @Local sheetOpacity: number = 0;
  @Local keyword: string = '';
  @Local results: CloudBookMeta[] = [];

  private animateCovered(covered: boolean): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : Motion.PAGE, curve: Curve.EaseOut },
      () => {
        NavStore.INSTANCE.covered = covered;
      }
    );
  }

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    // 自动聚焦键盘
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('cloudSearchInput');
      } catch (e) {
      }
    }, 200);
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
  }

  private applyKeyword(kw: string): void {
    this.keyword = kw;
    this.results = searchBooks(kw);
    if (kw.trim().length > 0) {
      CloudSearchStore.INSTANCE.add(kw);
    }
  }

  private openDetail(meta: CloudBookMeta): void {
    CloudSearchStore.INSTANCE.add(meta.name);
    const p: CloudBookDetailRouteParam = { cloudBookId: meta.id };
    NavStore.INSTANCE.push(RouteName.CLOUD_BOOK_DETAIL, p);
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 1500 });
    } catch (e) {
    }
  }

  @Builder
  SearchBar() {
    Row() {
      Row() {
        Image($r('app.media.ic_search')).width(18).height(18).margin({ right: 8 })
        TextInput({ text: this.keyword, placeholder: '四级 / 高考 / abandon' })
          .id('cloudSearchInput')
          .defaultFocus(true)
          .backgroundColor(Color.Transparent)
          .height(40).padding(0).layoutWeight(1)
          .fontSize(14)
          .onChange((v: string) => {
            this.keyword = v;
            this.results = searchBooks(v);
          })
          .onSubmit(() => {
            this.applyKeyword(this.keyword);
          })
      }
      .layoutWeight(1).height(42).padding({ left: 14, right: 14 })
      .backgroundColor(Colors.WHITE).borderRadius(21)

      Text('取消')
        .fontSize(15).fontColor(Colors.BRAND).height(44).padding({ left: 14 })
        .onClick(() => NavStore.INSTANCE.back())
    }
    .width('100%').height(56).padding({ left: 12, right: 16 })
  }

  @Builder
  HotTag(kw: string, index: number) {
    Row() {
      if (index < 3) {
        Text((index + 1).toString())
          .fontSize(11).fontColor(index === 0 ? Colors.UNKNOWN_RED : index === 1 ? Colors.FUZZY_ORANGE : Colors.KNOW_GREEN)
          .fontWeight(FontWeight.Bold).margin({ right: 5 })
      }
      Text(kw).fontSize(13).fontColor(Colors.TEXT_MAIN)
    }
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor(Colors.WHITE).borderRadius(16).margin({ right: 10, bottom: 10 })
    .onClick(() => this.applyKeyword(kw))
  }

  @Builder
  ResultRow(meta: CloudBookMeta) {
    Row() {
      Column() {
        Text(meta.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
          .width('100%').textAlign(TextAlign.Start)
        Text(`${meta.version} · ${meta.totalCount} 词`)
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB).margin({ top: 4 })
          .width('100%').textAlign(TextAlign.Start)
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('›').fontSize(22).fontColor(Colors.TEXT_WEAK)
    }
    .width('100%').padding(14).backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    .margin({ bottom: 10 })
    .onClick(() => this.openDetail(meta))
  }

  @Builder
  DefaultPanel() {
    Text('热门搜索').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
      .width('100%').margin({ top: 8, bottom: 12 })
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(HOT_SEARCH, (kw: string, index: number) => {
        this.HotTag(kw, index)
      }, (kw: string): string => kw)
    }
    .width('100%')

    if (CloudSearchStore.INSTANCE.history.length > 0) {
      Row() {
        Text('搜索历史').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
          .layoutWeight(1)
        Text('清空').fontSize(12).fontColor(Colors.TEXT_WEAK)
          .onClick(() => {
            CloudSearchStore.INSTANCE.clear();
            this.toast('已清空搜索历史');
          })
      }
      .width('100%').margin({ top: 14, bottom: 10 })

      Column() {
        ForEach(CloudSearchStore.INSTANCE.history, (kw: string) => {
          Row() {
            Stack() {
              Circle({ width: 13, height: 13 })
                .fill(Color.Transparent).stroke(Colors.TEXT_WEAK).strokeWidth(1.4)
            }.width(16).height(16).margin({ right: 10 })
            Text(kw).fontSize(14).fontColor(Colors.TEXT_SUB).layoutWeight(1)
          }
          .width('100%').height(44)
          .onClick(() => this.applyKeyword(kw))
        }, (kw: string, idx: number): string => idx.toString() + '_' + kw)
      }
      .width('100%').padding({ left: 14, right: 14 }).backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    }
  }

  build() {
    NavDestination() {
      Column() {
        this.SearchBar()
        Scroll() {
          Column() {
            if (this.keyword.trim().length === 0) {
              this.DefaultPanel()
            } else if (this.results.length === 0) {
              Column() {
                Text('没有找到相关词书').fontSize(14).fontColor(Colors.TEXT_WEAK)
              }
              .width('100%').margin({ top: 80 }).alignItems(HorizontalAlign.Center)
            } else {
              Text(`找到 ${this.results.length} 本词书`)
                .fontSize(12).fontColor(Colors.TEXT_WEAK).width('100%').margin({ top: 8, bottom: 10 })
              ForEach(this.results, (meta: CloudBookMeta) => {
                this.ResultRow(meta)
              }, (meta: CloudBookMeta): string => meta.id)
            }
          }
          .width('100%').padding({ left: 16, right: 16 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)
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
