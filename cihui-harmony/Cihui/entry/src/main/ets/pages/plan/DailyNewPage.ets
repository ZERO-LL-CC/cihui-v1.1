/**
 * F12 每日新词量（F-D 重做：自定义 10–1000）：
 * - 快捷档位 chips + 数字输入框，任意值 10–1000 均可设置（不再只有 9 个固定档）；
 * - 实时预览当天「新学 N + 复习 M = X 词，预计约 Y 分钟」（previewDailyNew 纯函数，不落数据）；
 * - 确定后 applyDailyNew：重置当日完成态与打卡、按 1/2/4/7/15 重排未来新词，历史不篡改；
 * - 取消 / 边缘左滑直接返回，不改动任何数据。
 * - 导入词本后的弹框设置走 setDailyNew（不重置当日），与本页手动调整口径不同。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { RouteName } from '../../common/RouteNames';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { MIN_DAILY_NEW, MAX_DAILY_NEW } from '../../model/SchedulerCore';
import { promptAction } from '@kit.ArkUI';
import type { DailyNewPreview } from '../../model/SchedulerCore';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

const QUOTA_PRESETS: number[] = [10, 20, 30, 50, 80, 100, 200, 500, 1000];

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
  @Local inputText: string = `${DataStore.INSTANCE.settings.dailyNewCount}`;
  @Local preview: DailyNewPreview = DataStore.INSTANCE.previewDailyNew(DataStore.INSTANCE.settings.dailyNewCount);

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
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

  private updateSelected(value: number, syncInput: boolean): void {
    if (value === this.selected) {
      if (syncInput && `${value}` !== this.inputText) {
        this.inputText = `${value}`;
      }
      return;
    }
    this.selected = value;
    if (syncInput) {
      this.inputText = `${value}`;
    }
    this.preview = DataStore.INSTANCE.previewDailyNew(value);
  }

  private confirm(): void {
    const n: number = parseInt(this.inputText, 10);
    if (isNaN(n) || n < MIN_DAILY_NEW || n > MAX_DAILY_NEW) {
      promptAction.showToast({
        message: `每日新词量需在 ${MIN_DAILY_NEW}–${MAX_DAILY_NEW} 之间`,
        duration: 2200
      });
      return;
    }
    DataStore.INSTANCE.applyDailyNew(n);
    promptAction.showToast({ message: `计划已按每日 ${n} 个新词重新分好`, duration: 2000 });
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
  PresetChip(value: number) {
    Text(`${value}`)
      .fontSize(14)
      .fontColor(this.selected === value ? Colors.WHITE : Colors.TEXT_SUB)
      .backgroundColor(this.selected === value ? Colors.BRAND : Colors.WHITE)
      .borderRadius(16)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .margin(4)
      .onClick(() => this.updateSelected(value, true))
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

          // 快捷档位
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
            ForEach(QUOTA_PRESETS, (value: number) => {
              this.PresetChip(value)
            }, (value: number): string => 'preset-' + value)
          }
          .width('100%').margin({ top: 18 })

          // 自定义输入（10–1000）
          Row() {
            Text('自定义').fontSize(14).fontColor(Colors.TEXT_SUB)
            TextInput({ text: this.inputText, placeholder: `${MIN_DAILY_NEW}–${MAX_DAILY_NEW}` })
              .type(InputType.Number)
              .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
              .textAlign(TextAlign.Center)
              .width(120).height(44)
              .backgroundColor(Colors.WHITE).borderRadius(10)
              .margin({ left: 12 })
              .onChange((v: string): void => {
                this.inputText = v;
                const n: number = parseInt(v, 10);
                if (!isNaN(n)) {
                  this.updateSelected(n, false);
                }
              })
            Text('个 / 天').fontSize(14).fontColor(Colors.TEXT_SUB).margin({ left: 8 })
          }
          .width('100%').justifyContent(FlexAlign.Center).margin({ top: 14 })

          Text(`可选范围 ${MIN_DAILY_NEW}–${MAX_DAILY_NEW}，设置后一直用到本词本学完`)
            .fontSize(12).fontColor(Colors.TEXT_WEAK).width('100%').textAlign(TextAlign.Center)
            .margin({ top: 10 })

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
