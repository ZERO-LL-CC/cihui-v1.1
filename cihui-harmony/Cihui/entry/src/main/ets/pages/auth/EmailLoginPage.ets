/**
 * F14 邮箱登录页：邮箱 + 密码（本机校验，不发邮件）。
 *
 * 定位：华为账号是主通道；本页给「非华为账号 / AGC 未配置 / 拒绝授权」的用户兜底。
 * 账号不存在时给出明确指引（去注册或改用华为账号），不暴露"该邮箱是否注册"以外的信息。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { AuthStore } from '../../viewmodel/AuthStore';
import { LocalAuthService } from '../../service/LocalAuthService';
import { RouteName } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { promptAction } from '@kit.ArkUI';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

@ComponentV2
export struct EmailLoginPage {
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 0;
  @Local email: string = '';
  @Local password: string = '';
  @Local errorField: string = '';

  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.EMAIL_LOGIN) {
      // 仅用于栈顶刷新，本页无派生数据
    }
  };

  aboutToAppear(): void {
    // 预填上次登录的邮箱，减少重复输入
    const p = AuthStore.INSTANCE.profile;
    if (p !== null && p.email !== '') {
      this.email = p.email;
    }
    REFRESH_BUS.onNav(this.refreshWhenTop);
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
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
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (_e) {
    }
  }

  private submit(): void {
    const r = LocalAuthService.INSTANCE.loginByEmail(this.email, this.password);
    if (!r.ok) {
      this.toast(r.message);
      this.errorField = r.error !== null ? r.error.field : '';
      return;
    }
    this.errorField = '';
    this.toast('登录成功');
    setTimeout(() => {
      if (AuthStore.INSTANCE.isLoggedIn()) {
        // 回到登录页，由 LoginPage.onShown 检测已登录后自动关闭
        NavStore.INSTANCE.back();
      }
    }, 400);
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())
      Text('邮箱登录')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)
      Row().width(44).height(44)
    }
    .width('100%').height(56)
  }

  @Builder
  FormRow(label: string, placeholder: string, value: string, type: InputType,
    field: string, onChange: (v: string) => void) {
    Row() {
      Text(label).fontSize(14).fontColor(Colors.TEXT_MAIN).width(56)
      TextInput({ text: value, placeholder: placeholder })
        .type(type)
        .backgroundColor(Color.Transparent)
        .layoutWeight(1)
        .height(44)
        .fontSize(15)
        .fontColor(Colors.TEXT_MAIN)
        .placeholderColor(Colors.TEXT_WEAK)
        .padding(0)
        .onChange((v: string) => {
          onChange(v);
          if (this.errorField === field) {
            this.errorField = '';
          }
        })
    }
    .width('100%')
    .height(52)
    .borderRadius(Radius.CONTROL)
    .backgroundColor(Colors.WHITE)
    .padding({ left: 14, right: 14 })
    .border({ width: this.errorField === field ? 1.5 : 0, color: Colors.UNKNOWN_RED })
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        Column() {
          Text('用注册时的邮箱和密码登录')
            .fontSize(12).fontColor(Colors.TEXT_WEAK).width('100%')
            .margin({ top: 8, bottom: 16 })

          Column({ space: 12 }) {
            this.FormRow('邮箱', 'you@example.com', this.email, InputType.Email, 'email',
              (v: string): void => {
                this.email = v;
              })
            this.FormRow('密码', '输入密码', this.password, InputType.Password, 'password',
              (v: string): void => {
                this.password = v;
              })
          }
          .width('100%')

          Button('登录')
            .type(ButtonType.Capsule).width('100%').height(50)
            .fontSize(16).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
            .margin({ top: 24 })
            .onClick(() => this.submit())

          Row() {
            Text('还没有账号？').fontSize(13).fontColor(Colors.TEXT_SUB)
            Text('去注册')
              .fontSize(13).fontColor(Colors.BRAND).fontWeight(FontWeight.Medium)
              .onClick(() => {
                NavStore.INSTANCE.push(RouteName.REGISTER);
              })
          }
          .margin({ top: 18 })

          Text('认证信息只保存在本机，换机需重新注册或导入备份')
            .fontSize(11).fontColor(Colors.TEXT_WEAK).textAlign(TextAlign.Center)
            .width('100%').margin({ top: 28 })
        }
        .width('100%').layoutWeight(1).padding({ top: 8 })
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
      .padding({ left: 24, right: 24 })
    }
    .hideTitleBar(true)
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity)
    .onShown(() => {
      this.animateCovered(true);
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
