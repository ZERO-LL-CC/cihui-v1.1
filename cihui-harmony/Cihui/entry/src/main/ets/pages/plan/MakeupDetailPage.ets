/**
 * F12 补卡日详情：
 * - 从计划大表红格进入，按 R7/R15/新词/错词等节点分组列出当天欠的任务与词数；
 * - 每组给彩色节点标签 + 前若干个单词预览；
 * - 底部按钮生成「M月D日 补卡」词本并进入闪卡逐张补（复用 ReviewCardsPage mode='MAKEUP'）；
 * - 补卡资格在进页与点击时各校验一次（严格顺序：今天先打卡、由近及远逐天补）。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { RouteName } from '../../common/RouteNames';
import type { MakeupRouteParam, ReviewRouteParam } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion, StageColors } from '../../common/DesignTokens';
import { promptAction } from '@kit.ArkUI';
import type { MakeupGroup } from '../../model/RepoCore';
import type { Word } from '../../model/Types';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

@ComponentV2
export struct MakeupDetailPage {
  @Require @Param param: MakeupRouteParam;
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.MAKEUP_DETAIL) {
      this.showTick++;
    }
  };
  @Local sheetOpacity: number = 0;
  @Local groups: MakeupGroup[] = [];
  @Local blockedReason: string = '';

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    this.refresh();
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
  }

  private refresh(): void {
    const ok = DataStore.INSTANCE.makeupEligibility(this.param.day);
    if (!ok.ok) {
      this.blockedReason = ok.reason;
      this.groups = [];
      return;
    }
    this.blockedReason = '';
    this.groups = DataStore.INSTANCE.makeupGroups(this.param.day);
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

  private dayLabel(): string {
    const parts: string[] = this.param.day.split('-');
    return `${Number(parts[1])}月${Number(parts[2])}日`;
  }

  private totalCount(): number {
    let n: number = 0;
    this.groups.forEach((g: MakeupGroup): void => {
      n += g.count;
    });
    return n;
  }

  private previewWords(ids: string[]): Word[] {
    const out: Word[] = [];
    for (const id of ids) {
      const w: Word | undefined = DataStore.INSTANCE.words.find((x: Word): boolean => x.id === id);
      if (w !== undefined) {
        out.push(w);
      }
      if (out.length >= 6) {
        break;
      }
    }
    return out;
  }

  private startMakeup(): void {
    const ok = DataStore.INSTANCE.makeupEligibility(this.param.day);
    if (!ok.ok) {
      promptAction.showToast({ message: ok.reason, duration: 2200 });
      this.refresh();
      return;
    }
    const ids: string[] = [];
    this.groups.forEach((g: MakeupGroup): void => {
      g.wordIds.forEach((id: string): void => {
        ids.push(id);
      });
    });
    if (ids.length === 0) {
      promptAction.showToast({ message: '该日没有待补的学习任务', duration: 1800 });
      return;
    }
    const p: ReviewRouteParam = {
      wordIds: ids,
      title: `${this.dayLabel()} 补卡`,
      mode: 'MAKEUP',
      makeupDay: this.param.day,
    };
    NavStore.INSTANCE.push(RouteName.REVIEW_CARDS, p);
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())

      Text(`补卡 · ${this.dayLabel()}`)
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Row().width(44).height(44)
    }
    .width('100%').height(56)
  }

  @Builder
  GroupCard(group: MakeupGroup) {
    Column() {
      Row() {
        Text(group.stage)
          .fontSize(12).fontWeight(FontWeight.Bold)
          .fontColor(Colors.WHITE)
          .backgroundColor(StageColors.colorOf(group.stage))
          .borderRadius(8)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        Text(group.title)
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
          .margin({ left: 10 }).layoutWeight(1)
        Text(`${group.count} 词`)
          .fontSize(13).fontColor(Colors.TEXT_SUB)
      }
      .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.previewWords(group.wordIds), (w: Word) => {
          Text(w.english)
            .fontSize(12).fontColor(Colors.TEXT_SUB)
            .backgroundColor(Colors.PAGE_BG).borderRadius(8)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 8, top: 8 })
        }, (w: Word) => 'mk-' + group.stage + '-' + w.id)
      }
      .width('100%').margin({ top: 4 })
      if (group.count > 6) {
        Text(`等 ${group.count} 个词，全部需要补过`)
          .fontSize(11).fontColor(Colors.TEXT_WEAK).width('100%').margin({ top: 6 })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Colors.WHITE)
    .borderRadius(Radius.CARD)
    .margin({ bottom: 12 })
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        if (this.blockedReason !== '') {
          Column() {
            Text('暂时不能补这一天')
              .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium)
              .fontColor(Colors.TEXT_MAIN).margin({ bottom: 10 })
            Text(this.blockedReason)
              .fontSize(TypeScale.BODY).fontColor(Colors.TEXT_SUB)
              .textAlign(TextAlign.Center).lineHeight(22).width('80%')
            Button('返回计划表')
              .fontSize(TypeScale.BODY).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
              .borderRadius(Radius.BUTTON).height(46).width(200).margin({ top: 24 })
              .onClick(() => NavStore.INSTANCE.back())
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.groups.length === 0) {
          Column() {
            Text('该日没有待补任务')
              .fontSize(TypeScale.CARD_TITLE).fontColor(Colors.TEXT_MAIN)
            Button('返回计划表')
              .fontSize(TypeScale.BODY).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
              .borderRadius(Radius.BUTTON).height(46).width(200).margin({ top: 20 })
              .onClick(() => NavStore.INSTANCE.back())
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column() {
              Row() {
                Text(`${this.dayLabel()} 共有 `)
                  .fontSize(14).fontColor(Colors.TEXT_SUB)
                Text(`${this.totalCount()}`)
                  .fontSize(18).fontWeight(FontWeight.Bold).fontColor(Colors.UNKNOWN_RED)
                Text(' 个词没过完，补完后该日标记为已补卡（不恢复连续天数）')
                  .fontSize(14).fontColor(Colors.TEXT_SUB).layoutWeight(1)
              }
              .width('100%').padding(14)
              .backgroundColor(Colors.UNKNOWN_RED_SOFT).borderRadius(Radius.CONTROL)
              .margin({ bottom: 14 })

              ForEach(this.groups, (g: MakeupGroup) => {
                this.GroupCard(g)
              }, (g: MakeupGroup) => 'group-' + g.stage)
            }
            .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 90 })
          }
          .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)

          Column() {
            Button(`生成「${this.dayLabel()} 补卡」词本，开始补卡`)
              .fontSize(16).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
              .borderRadius(Radius.BUTTON).height(50).width('100%')
              .onClick(() => this.startMakeup())
          }
          .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 24 })
          .backgroundColor(Colors.PAGE_BG)
        }
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
    }
    .hideTitleBar(true)
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity + this.showTick * 0)
    .onShown(() => {
      this.showTick++;
      // 从补卡闪卡返回时刷新（理论上完成后会直接回计划表，这里兜底）
      this.refresh();
      this.animateCovered(true);
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
