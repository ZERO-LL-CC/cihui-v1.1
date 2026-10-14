/**
 * F1 转场测试页：右滑进入 320ms，当前层左移 7% / 缩放 .93 / 压暗；
 * 边缘左滑返回走系统默认手势（不劫持）。减弱动效时降级为 240ms 淡入淡出。
 */
import { NavStore } from '../viewmodel/NavStore';
import { Colors, TypeScale, Radius, Motion } from '../common/DesignTokens';

@ComponentV2
export struct TestPage {
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 0;

  private animateCovered(covered: boolean): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : Motion.PAGE, curve: Curve.EaseOut },
      () => {
        NavStore.INSTANCE.covered = covered;
      }
    );
  }

  build() {
    NavDestination() {
      Column() {
        // 顶部导航条：返回热区 >= 44vp
        Row() {
          Button() {
            Image($r('app.media.ic_back')).width(26).height(26)
          }
          .type(ButtonType.Normal)
          .width(44)
          .height(44)
          .backgroundColor(Color.Transparent)
          .onClick(() => NavStore.INSTANCE.back())
          Text('测试二级页')
            .fontSize(TypeScale.CARD_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(Colors.TEXT_MAIN)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .margin({ right: 44 })
        }
        .width('100%')
        .height(56)

        Column() {
          Text('转场验证')
            .fontSize(TypeScale.TITLE_LARGE)
            .fontWeight(FontWeight.Bold)
            .fontColor(Colors.TEXT_MAIN)
            .width('100%')
          Text('进入时本页自右侧滑入（320ms），一级页左移 7%、缩放 0.93 并压暗；\n屏幕左缘右滑为系统返回手势，未做劫持。')
            .fontSize(TypeScale.BODY)
            .fontColor(Colors.TEXT_SUB)
            .lineHeight(24)
            .width('100%')
            .margin({ top: 16 })
          Button('返回')
            .width('100%')
            .height(48)
            .borderRadius(Radius.BUTTON)
            .backgroundColor(Colors.BRAND)
            .fontColor(Colors.WHITE)
            .margin({ top: 28 })
            .onClick(() => NavStore.INSTANCE.back())
        }
        .layoutWeight(1)
        .width('100%')
        .padding(20)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Colors.PAGE_BG)
    }
    .hideTitleBar(true)
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity)
    .onShown(() => this.animateCovered(true))
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
