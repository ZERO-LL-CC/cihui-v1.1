/**
 * F14 单字段二级编辑页：账号页点任意字段进入；保存走 LocalAuthService 校验，
 * 名称必填、手机/邮箱格式与「至少保留一项」规则；失败行轻摇 + Toast，成功 Toast 并返回。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { RouteName } from '../../common/RouteNames';
import { AuthStore } from '../../viewmodel/AuthStore';
import { LocalAuthService } from '../../service/LocalAuthService';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import type { FieldEditRouteParam } from '../../common/RouteNames';
import type { AccountField } from '../../model/AuthCore';
import { promptAction } from '@kit.ArkUI';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

@ComponentV2
export struct FieldEditPage {
  @Require @Param param: FieldEditRouteParam;
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.FIELD_EDIT) {
      this.showTick++;
    }
  };
  @Local sheetOpacity: number = 0;
  @Local value: string = '';
  @Local hasError: boolean = false;
  @Local shakeX: number = 0;

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    this.value = this.currentValue();
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
  }

  private field(): AccountField {
    const f: string = this.param.field;
    if (f === 'name' || f === 'phone' || f === 'email' || f === 'wechat' || f === 'qq') {
      return f;
    }
    return 'name';
  }

  private currentValue(): string {
    const p = AuthStore.INSTANCE.profile;
    if (p === null) {
      return '';
    }
    const f: AccountField = this.field();
    if (f === 'name') {
      return p.name;
    }
    if (f === 'phone') {
      return p.phone;
    }
    if (f === 'email') {
      return p.email;
    }
    if (f === 'wechat') {
      return p.wechat;
    }
    return p.qq;
  }

  private title(): string {
    const f: AccountField = this.field();
    if (f === 'name') {
      return '修改昵称';
    }
    if (f === 'phone') {
      return '修改手机号';
    }
    if (f === 'email') {
      return '修改邮箱';
    }
    if (f === 'wechat') {
      return '修改微信';
    }
    return '修改 QQ';
  }

  private placeholder(): string {
    const f: AccountField = this.field();
    if (f === 'name') {
      return '请输入昵称';
    }
    if (f === 'phone') {
      return '请输入 11 位手机号';
    }
    if (f === 'email') {
      return '请输入邮箱地址';
    }
    if (f === 'wechat') {
      return '请输入微信号（选填，可留空）';
    }
    return '请输入 QQ 号';
  }

  private inputType(): InputType {
    const f: AccountField = this.field();
    if (f === 'phone' || f === 'qq') {
      return InputType.PhoneNumber;
    }
    if (f === 'email') {
      return InputType.Email;
    }
    return InputType.Normal;
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

  private shake(): void {
    this.hasError = true;
    const step = (x: number, delay: number): void => {
      setTimeout(() => {
        this.getUIContext().animateTo({ duration: 55, curve: Curve.EaseInOut }, () => {
          this.shakeX = x;
        });
      }, delay);
    };
    step(-8, 0);
    step(8, 55);
    step(-5, 110);
    step(5, 165);
    step(0, 220);
  }

  private save(): void {
    const r = LocalAuthService.INSTANCE.updateField(this.field(), this.value);
    if (!r.ok) {
      this.toast(r.message);
      this.shake();
      return;
    }
    this.toast('已保存，账号与首页问候语已同步');
    // 动态 QA：返回冻结的账号页不会重绘，清栈回「我的」Tab 整页重挂载
    NavStore.INSTANCE.backToTab(2);
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())
      Text(this.title())
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)
      Text('保存').fontSize(15).fontColor(Colors.BRAND).width(52).textAlign(TextAlign.Center)
        .onClick(() => this.save())
    }
    .width('100%').height(56)
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        Column() {
          Row() {
            TextInput({ text: this.value, placeholder: this.placeholder() })
              .type(this.inputType())
              .backgroundColor(Color.Transparent)
              .layoutWeight(1).height(50).fontSize(16).fontColor(Colors.TEXT_MAIN)
              .placeholderColor(Colors.TEXT_WEAK).padding(0)
              .defaultFocus(true)
              .onChange((v: string) => {
                this.value = v;
                this.hasError = false;
              })
          }
          .width('100%').height(56)
          .borderRadius(Radius.CONTROL).backgroundColor(Colors.WHITE)
          .padding({ left: 14, right: 14 })
          .border({ width: this.hasError ? 1.5 : 0, color: Colors.UNKNOWN_RED })
          .translate({ x: this.shakeX })

          Text(this.field() === 'phone' || this.field() === 'email'
            ? '手机号与邮箱至少保留一项，清空另一项时本项不可为空'
            : this.field() === 'name' ? '昵称不能为空' : '')
            .fontSize(12).fontColor(Colors.TEXT_WEAK).width('100%').margin({ top: 12 })

          Button('保存')
            .type(ButtonType.Capsule).width('100%').height(48)
            .fontSize(16).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
            .margin({ top: 28 })
            .onClick(() => this.save())
        }
        .width('100%').padding({ left: 20, right: 20, top: 8 })
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
