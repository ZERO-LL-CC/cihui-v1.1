/**
 * F12 每日新词量（iOS 时钟式滚轮）：
 * - 竖向 scroll-snap 滚轮，档位 5/8/10/12/15/20/25/30/40，点按也可定位；
 * - 滑动实时预览当天「新学 N + 复习 M = X 词，预计约 Y 分钟」（previewDailyNew 纯函数，不落数据）；
 * - 确定后 applyDailyNew：重置当日完成态与打卡、按 1/2/4/7/15 重排未来新词，历史不篡改；
 * - 取消 / 边缘左滑直接返回，不改动任何数据。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { RouteName } from '../../common/RouteNames';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { promptAction } from '@kit.ArkUI';
import type { DailyNewPreview } from '../../model/SchedulerCore';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

const WHEEL_VALUES: number[] = [5, 8, 10, 12, 15, 20, 25, 30, 40];
const ITEM_HEIGHT: number = 46;
const VISIBLE_ROWS: number = 5;

@ComponentV2
export struct DailyNewPage {
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.DAILY_NEW) {
      this.showTick++;
    }
  };
  @Local sheetOpacity: number = 0;
  @Local selected: number = DataStore.INSTANCE.settings.dailyNewCount;
  @Local preview: DailyNewPreview = DataStore.INSTANCE.previewDailyNew(DataStore.INSTANCE.settings.dailyNewCount);
  private scroller: Scroller = new Scroller();
  private initialized: boolean = false;

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    // 初始定位到当前设置档位
    setTimeout(() => {
      const idx: number = WHEEL_VALUES.indexOf(this.selected);
      if (idx >= 0) {
        this.scroller.scrollToIndex(idx, false, ScrollAlign.CENTER);
      }
      this.initialized = true;
    }, 60);
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
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

  private updateSelected(value: number): void {
    if (value === this.selected) {
      return;
    }
    this.selected = value;
    this.preview = DataStore.INSTANCE.previewDailyNew(value);
  }

  private onVisibleChange(first: number, last: number, center: number): void {
    if (!this.initialized) {
      return;
    }
    // List onScrollIndex 直接给居中下标；个别机型首帧为 -1 时用 first+2 兜底
    let idx: number = center;
    if (idx < 0) {
      idx = first + Math.floor(VISIBLE_ROWS / 2);
    }
    if (idx < 0) {
      idx = 0;
    }
    if (idx > WHEEL_VALUES.length - 1) {
      idx = WHEEL_VALUES.length - 1;
    }
    this.updateSelected(WHEEL_VALUES[idx]);
  }

  private confirm(): void {
    DataStore.INSTANCE.applyDailyNew(this.selected);
    promptAction.showToast({ message: `计划已按每日 ${this.selected} 个新词重新分好`, duration: 2000 });
    NavStore.INSTANCE.back();
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())

      Text('每日新词量')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Row().width(44).height(44)
    }
    .width('100%').height(56)
  }

  @Builder
  WheelItem(value: number, index: number) {
    Text(`${value}`)
      .fontSize(value === this.selected ? 26 : 18)
      .fontWeight(value === this.selected ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(value === this.selected ? Colors.BRAND : Colors.TEXT_WEAK)
      .width('100%')
      .height(ITEM_HEIGHT)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.scroller.scrollToIndex(index, true, ScrollAlign.CENTER);
        this.updateSelected(value);
      })
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()

        Column() {
          Text('每天计划新学')
            .fontSize(14).fontColor(Colors.TEXT_SUB).margin({ top: 18 })
          Row() {
            Text(`${this.selected}`)
              .fontSize(46).fontWeight(FontWeight.Bold).fontColor(Colors.BRAND)
            Text(' 个/天')
              .fontSize(16).fontColor(Colors.TEXT_SUB).margin({ bottom: 6 })
          }
          .margin({ top: 6 })

          // 滚轮
          Stack({ alignContent: Alignment.Center }) {
            // 中心高亮条
            Column()
              .width('86%').height(ITEM_HEIGHT)
              .borderRadius(Radius.CONTROL)
              .backgroundColor(Colors.BRAND_SOFT)
            // 上下渐隐遮罩
            Column()
              .width('100%').height('100%')
              .linearGradient({
                angle: 180,
                colors: [
                  [Colors.PAGE_BG, 0.0],
                  ['#00EDF0F6', 0.28],
                  ['#00EDF0F6', 0.72],
                  [Colors.PAGE_BG, 1.0],
                ],
              })
            List({ scroller: this.scroller, initialIndex: WHEEL_VALUES.indexOf(this.selected) }) {
              ForEach(WHEEL_VALUES, (value: number, index: number) => {
                ListItem() {
                  this.WheelItem(value, index)
                }
                .height(ITEM_HEIGHT)
              }, (value: number) => 'wheel-' + value)
            }
            .width('100%')
            .height(ITEM_HEIGHT * VISIBLE_ROWS)
            .scrollBar(BarState.Off)
            .scrollSnapAlign(ScrollSnapAlign.CENTER)
            .onScrollIndex((first: number, last: number, center: number) => this.onVisibleChange(first, last, center))
          }
          .width('100%')
          .height(ITEM_HEIGHT * VISIBLE_ROWS)
          .margin({ top: 18 })

          // 实时预览
          Column() {
            Row() {
              Text('按 ').fontSize(14).fontColor(Colors.TEXT_SUB)
              Text(`${this.preview.dailyNew}`).fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor(Colors.BRAND)
              Text(' 个/天排期：今天').fontSize(14).fontColor(Colors.TEXT_SUB)
            }
            .width('100%')

            Row() {
              Text('新学 ')
                .fontSize(14).fontColor(Colors.TEXT_SUB)
              Text(`${this.preview.newCount}`)
                .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Colors.FUZZY_ORANGE)
              Text('  +  复习 ')
                .fontSize(14).fontColor(Colors.TEXT_SUB)
              Text(`${this.preview.reviewCount}`)
                .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Colors.STAGE_R4)
              Text('  =  ')
                .fontSize(14).fontColor(Colors.TEXT_SUB)
              Text(`${this.preview.total}`)
                .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
              Text(' 个词')
                .fontSize(14).fontColor(Colors.TEXT_SUB)
            }
            .width('100%').margin({ top: 8 })

            Text(`预计约 ${this.preview.minutes} 分钟（新学约 40 秒/词、复习约 15 秒/词）`)
              .fontSize(12).fontColor(Colors.TEXT_WEAK).width('100%').margin({ top: 8 })

            // P6：目标档位高于词本剩余库存时，诚实区分「目标」与「今日实际」并引导导入
            if (this.preview.insufficient) {
              Column({ space: 10 }) {
                Text(`词本未学新词只剩 ${this.preview.newCount + this.preview.unlearned} 个：今天按实际 ${this.preview.newCount} 个排满；导入更多词书后，后续每天自动按 ${this.preview.dailyNew} 个分配。`)
                  .fontSize(12).fontColor(Colors.FUZZY_ORANGE).lineHeight(18).width('100%')
                Button('去导入云词本')
                  .fontSize(13).fontColor(Colors.BRAND)
                  .backgroundColor(Colors.BRAND_SOFT).borderRadius(14)
                  .height(34).padding({ left: 16, right: 16 })
                  .onClick(() => NavStore.INSTANCE.push(RouteName.CLOUD_LIBRARY))
              }
              .width('100%').alignItems(HorizontalAlign.Start)
              .padding({ top: 10, bottom: 2 })
              .border({ width: { top: 1 }, color: Colors.DIVIDER })
              .margin({ top: 10 })
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Colors.WHITE)
          .borderRadius(Radius.CARD)
          .margin({ top: 22, left: 20, right: 20 })

          Text('调整后今天的学习与打卡状态会重置，未来新词按艾宾浩斯节点重新分好；已经学过的历史记录不会改变。')
            .fontSize(12).fontColor(Colors.TEXT_WEAK).lineHeight(18)
            .width('100%').padding({ left: 24, right: 24, top: 18 })
        }
        .layoutWeight(1).width('100%')

        // 底部按钮
        Row({ space: 12 }) {
          Button('取消')
            .fontSize(16).fontColor(Colors.TEXT_SUB).backgroundColor(Colors.WHITE)
            .borderRadius(Radius.BUTTON).height(50).layoutWeight(1)
            .onClick(() => NavStore.INSTANCE.back())
          Button('确定')
            .fontSize(16).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
            .borderRadius(Radius.BUTTON).height(50).layoutWeight(1)
            .onClick(() => this.confirm())
        }
        .width('100%').padding({ left: 20, right: 20, top: 10, bottom: 28 })
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
