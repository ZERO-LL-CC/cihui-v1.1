/**
 * F14 注册 / 登录表单页：
 * 名称必填；手机号 / 邮箱至少一项；手机号 11 位；邮箱格式；微信选填。
 * 校验失败：对应行左右轻摇 + 红框 + Toast 原因；通过即本地登录并返回（LoginPage 自动关）。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { RouteName } from '../../common/RouteNames';
import { LocalAuthService } from '../../service/LocalAuthService';
import { LocalFileSyncService } from '../../service/LocalFileSyncService';
import { common } from '@kit.AbilityKit';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import type { AccountField, RegisterForm } from '../../model/AuthCore';
import { emptyRegisterForm } from '../../model/AuthCore';
import { promptAction } from '@kit.ArkUI';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

class FieldSpec {
  field: AccountField;
  label: string;
  placeholder: string;
  inputType: InputType;
  optional: boolean;

  constructor(field: AccountField, label: string, placeholder: string, inputType: InputType,
    optional: boolean = false) {
    this.field = field;
    this.label = label;
    this.placeholder = placeholder;
    this.inputType = inputType;
    this.optional = optional;
  }
}

@ComponentV2
export struct RegisterPage {
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.REGISTER) {
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
  @Local form: RegisterForm = emptyRegisterForm();
  @Local errorField: AccountField | '' = '';
  @Local shakeX: number = 0;
  private specs: FieldSpec[] = [
    new FieldSpec('name', '名称', '怎么称呼你？', InputType.Normal),
    new FieldSpec('phone', '手机号', '11 位手机号（与邮箱至少填一项）', InputType.PhoneNumber),
    new FieldSpec('email', '邮箱', '邮箱地址（与手机号至少填一项）', InputType.Email),
    new FieldSpec('wechat', '微信', '选填，便于微信好友同步', InputType.Normal, true),
  ];

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

  private setField(field: AccountField, v: string): void {
    if (field === 'name') {
      this.form.name = v;
    } else if (field === 'phone') {
      this.form.phone = v;
    } else if (field === 'email') {
      this.form.email = v;
    } else if (field === 'wechat') {
      this.form.wechat = v;
    }
    if (this.errorField === field) {
      this.errorField = '';
    }
  }

  /** 出错行左右轻摇：-8 → 8 → -5 → 5 → 0 */
  private shakeRow(field: AccountField): void {
    this.errorField = field;
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

  private submit(): void {
    const r = LocalAuthService.INSTANCE.register(this.form);
    if (!r.ok) {
      this.toast(r.message);
      if (r.error !== null) {
        this.shakeRow(r.error.field);
      }
      return;
    }
    this.toast('注册成功，已登录，云备份已开启');
    // F15：登录后静默完成首次本地备份（失败不阻断注册流程，状态在账号页可见）
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      LocalFileSyncService.INSTANCE.backupNow(ctx, true).catch((): void => {
      });
    } catch (_e) {
    }
    NavStore.INSTANCE.back();
  }

  private fieldValue(field: AccountField): string {
    if (field === 'name') {
      return this.form.name;
    }
    if (field === 'phone') {
      return this.form.phone;
    }
    if (field === 'email') {
      return this.form.email;
    }
    return this.form.wechat;
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())
      Text('登录 / 注册')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)
      Row().width(44).height(44)
    }
    .width('100%').height(56)
  }

  @Builder
  FormRow(spec: FieldSpec) {
    Column() {
      Row() {
        Text(spec.label).fontSize(14).fontColor(Colors.TEXT_MAIN).width(64)
        if (spec.optional) {
          Text('选填').fontSize(10).fontColor(Colors.TEXT_WEAK)
            .borderRadius(6).backgroundColor(Colors.PAGE_BG)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 }).margin({ right: 8 })
        } else {
          Text('*').fontSize(14).fontColor(Colors.UNKNOWN_RED).margin({ right: 10 })
        }
        TextInput({ text: this.fieldValue(spec.field), placeholder: spec.placeholder })
          .type(spec.inputType)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(Colors.TEXT_MAIN)
          .placeholderColor(Colors.TEXT_WEAK)
          .padding(0)
          .onChange((v: string) => this.setField(spec.field, v))
      }
      .width('100%')
      .height(52)
      .borderRadius(Radius.CONTROL)
      .backgroundColor(Colors.WHITE)
      .padding({ left: 14, right: 14 })
      .border({
        width: this.errorField === spec.field ? 1.5 : 0,
        color: Colors.UNKNOWN_RED,
      })
      .translate({ x: this.errorField === spec.field ? this.shakeX : 0 })
    }
    .width('100%').margin({ bottom: 12 })
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        Scroll() {
          Column() {
            Text('填写基础信息完成注册，资料保存在本机，可在「账号与云备份」中导出备份文件')
              .fontSize(12).fontColor(Colors.TEXT_WEAK).width('100%')
              .margin({ top: 8, bottom: 16 })

            ForEach(this.specs, (spec: FieldSpec) => {
              this.FormRow(spec)
            }, (spec: FieldSpec): string => spec.field)

            Button('注册并登录')
              .type(ButtonType.Capsule).width('100%').height(50)
              .fontSize(16).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
              .margin({ top: 14 })
              .onClick(() => this.submit())

            Text('微信 / QQ 一键登录需对应开放平台资质，当前版本暂未接入')
              .fontSize(11).fontColor(Colors.TEXT_WEAK).textAlign(TextAlign.Center)
              .width('100%').margin({ top: 16 })
          }
          .width('100%').padding({ left: 4, right: 4, bottom: 40 })
        }
        .layoutWeight(1).scrollBar(BarState.Off)
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
      .padding({ left: 20, right: 20 })
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
