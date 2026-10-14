/**
 * F5 云词本库页：分类分组（大学 / 高中 / 初中小学）+ 年级横排换行 chip + 顶部搜索栏。
 * 大学/高考/中考词书为随包真实词库（开源 ECDICT，MIT）；分年级词书内容接入中标注「筹备中」。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { RouteName } from '../../common/RouteNames';
import type { CloudBookDetailRouteParam } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { getGroups } from '../../service/CloudCatalog';
import type { CloudBookMeta, CloudGroup } from '../../service/CloudCatalog';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

@ComponentV2
export struct CloudLibraryPage {
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.CLOUD_LIBRARY) {
      this.showTick++;
    }
  };
  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
  }

  @Local sheetOpacity: number = 0;
  private groups: CloudGroup[] = getGroups();

  private animateCovered(covered: boolean): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : Motion.PAGE, curve: Curve.EaseOut },
      () => {
        NavStore.INSTANCE.covered = covered;
      }
    );
  }

  private openDetail(meta: CloudBookMeta): void {
    const p: CloudBookDetailRouteParam = { cloudBookId: meta.id };
    NavStore.INSTANCE.push(RouteName.CLOUD_BOOK_DETAIL, p);
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())
      Text('导入云词本')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center).margin({ right: 44 })
    }
    .width('100%').height(56)
  }

  @Builder
  SearchEntry() {
    Row() {
      Image($r('app.media.ic_search')).width(18).height(18).margin({ right: 8 })
      Text('搜索词书 / 单词，如四级、abandon')
        .fontSize(14).fontColor(Colors.TEXT_WEAK).layoutWeight(1)
    }
    .width('100%').height(42).padding({ left: 14, right: 14 })
    .backgroundColor(Colors.WHITE).borderRadius(21)
    .margin({ top: 6, bottom: 14 })
    .onClick(() => NavStore.INSTANCE.push(RouteName.CLOUD_SEARCH))
  }

  @Builder
  FeaturedCard(meta: CloudBookMeta) {
    Row() {
      Column() {
        Text(meta.name.substring(0, 1)).fontSize(18).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
      }
      .width(46).height(46).borderRadius(12).backgroundColor(Colors.BRAND)
      .justifyContent(FlexAlign.Center)

      Column() {
        Text(meta.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
          .width('100%').textAlign(TextAlign.Start)
        Text(`${meta.version} · ${meta.totalCount} 词`)
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB).margin({ top: 5 })
          .width('100%').textAlign(TextAlign.Start)
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 12 })

      Text('›').fontSize(22).fontColor(Colors.TEXT_WEAK)
    }
    .width('100%').padding(14).backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    .margin({ bottom: 10 })
    .onClick(() => this.openDetail(meta))
  }

  @Builder
  Chip(meta: CloudBookMeta) {
    Column() {
      Text(meta.grade.length > 0 ? meta.grade : meta.name)
        .fontSize(14).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
      Text(meta.coming === true ? '筹备中' : `${meta.totalCount} 词`)
        .fontSize(11).fontColor(Colors.TEXT_WEAK).margin({ top: 2 })
    }
    .padding({ left: 16, right: 16, top: 9, bottom: 9 })
    .backgroundColor(Colors.WHITE).borderRadius(16)
    .margin({ right: 10, bottom: 10 })
    .onClick(() => this.openDetail(meta))
  }

  @Builder
  GroupSection(group: CloudGroup) {
    Text(group.title)
      .fontSize(15).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
      .width('100%').margin({ top: 12, bottom: 10 })
    ForEach(group.featured, (meta: CloudBookMeta) => {
      this.FeaturedCard(meta)
    }, (meta: CloudBookMeta): string => meta.id)
    if (group.chips.length > 0) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(group.chips, (meta: CloudBookMeta) => {
          this.Chip(meta)
        }, (meta: CloudBookMeta): string => meta.id)
      }
      .width('100%')
    }
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        Scroll() {
          Column() {
            this.SearchEntry()
            ForEach(this.groups, (group: CloudGroup) => {
              this.GroupSection(group)
            }, (group: CloudGroup): string => group.title)
            Text('已接入词库来自开源 ECDICT（MIT 许可）；分年级教材词书筹备中')
              .fontSize(11).fontColor(Colors.TEXT_WEAK).textAlign(TextAlign.Center)
              .width('100%').margin({ top: 16, bottom: 24 })
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
