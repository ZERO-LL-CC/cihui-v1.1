/**
 * F14 登录页：华为账号一键登录（官方组件，符合上架 UX 规范）+ 手机号/邮箱本地注册。
 *
 * 华为账号登录走 Account Kit 客户端直取 unionID，无需服务端；
 * 微信 / QQ 一键登录需企业资质与开放平台审核，个人开发者走不通，已从入口下线。
 * 注册成功回到本页时 onShown 检测已登录，自动关闭回我的页。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { AuthStore } from '../../viewmodel/AuthStore';
import { LocalAuthService } from '../../service/LocalAuthService';
import { AccountKitService } from '../../service/AccountKitService';
import { RouteName } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { promptAction } from '@kit.ArkUI';
import { LoginWithHuaweiIDButton, loginComponentManager } from '@kit.AccountKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

@ComponentV2
export struct LoginPage {
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.LOGIN) {
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
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (_e) {
    }
  }

  /** 华为账号登录回调：失败按错误码给可执行提示，成功落 profile */
  private handleHuaweiCredential(err: BusinessError | null, cred: loginComponentManager.HuaweiIDCredential | null): void {
    if (err) {
      this.toast(AccountKitService.INSTANCE.describeError(err));
      return;
    }
    const auth = AccountKitService.INSTANCE.fromCredential(cred);
    if (!auth.ok) {
      this.toast(auth.message);
      return;
    }
    const r = LocalAuthService.INSTANCE.loginByHuawei(auth.unionID);
    this.toast(r.message);
    if (r.ok) {
      // 稍等 Toast 露出后关闭登录页回「我的」，与注册回流一致
      setTimeout(() => {
        if (AuthStore.INSTANCE.isLoggedIn()) {
          NavStore.INSTANCE.back();
        }
      }, 500);
    }
  }

  private hwController: loginComponentManager.LoginWithHuaweiIDButtonController =
    new loginComponentManager.LoginWithHuaweiIDButtonController()
      .onClickLoginWithHuaweiIDButton((err: BusinessError, cred: loginComponentManager.HuaweiIDCredential): void => {
        this.handleHuaweiCredential(err, cred);
      });

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())
      Text('登录')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)
      Row().width(44).height(44)
    }
    .width('100%').height(56)
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        Column() {
          Stack() {
            Text('词').fontSize(34).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
          }
          .width(84).height(84).borderRadius(24).backgroundColor(Colors.BRAND)
          .shadow({ radius: 18, color: '#330A59F7', offsetX: 0, offsetY: 8 })

          Text('说词').fontSize(26).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
            .margin({ top: 18 })
          Text('拍照导入 · 语音快过 · 艾宾浩斯复习')
            .fontSize(13).fontColor(Colors.TEXT_SUB).margin({ top: 8 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)

        Column({ space: 12 }) {
          LoginWithHuaweiIDButton({
            params: {
              style: loginComponentManager.Style.BUTTON_RED,
              borderRadius: 25,
              loginType: loginComponentManager.LoginType.ID,
              supportDarkMode: true,
              verifyPhoneNumber: false,
            },
            controller: this.hwController
          })
            .width('100%')
            .height(50)

          Button() {
            Text('邮箱账号登录').fontSize(16).fontColor(Colors.BRAND)
          }
          .type(ButtonType.Capsule).width('100%').height(50)
          .backgroundColor(Color.Transparent)
          .border({ width: 1.5, color: Colors.BRAND })
          .onClick(() => NavStore.INSTANCE.push(RouteName.EMAIL_LOGIN))
        }
        .width('100%').padding({ left: 8, right: 8, bottom: 16 })

        Row() {
          Text('首次使用？').fontSize(12).fontColor(Colors.TEXT_SUB)
          Text('注册邮箱账号')
            .fontSize(12).fontColor(Colors.BRAND).fontWeight(FontWeight.Medium)
            .onClick(() => NavStore.INSTANCE.push(RouteName.REGISTER))
        }
        .margin({ top: 4 })

        Text('登录即代表同意《用户协议》与《隐私政策》，未登录也可先体验本机功能')
          .fontSize(11).fontColor(Colors.TEXT_WEAK).textAlign(TextAlign.Center)
          .width('100%').padding({ top: 14, bottom: 6 })
        Text('学习数据保存在本机，换机请在「账号与云备份」中导出备份后导入恢复')
          .fontSize(10).fontColor(Colors.TEXT_WEAK).textAlign(TextAlign.Center)
          .width('100%').padding({ bottom: 22 })
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
      .padding({ left: 24, right: 24 })
    }
    .hideTitleBar(true)
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity + this.showTick * 0)
    .onShown(() => {
      this.showTick++;
      this.animateCovered(true);
      // 注册成功后回到本页：已登录则自动关闭
      if (AuthStore.INSTANCE.isLoggedIn()) {
        NavStore.INSTANCE.back();
      }
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
