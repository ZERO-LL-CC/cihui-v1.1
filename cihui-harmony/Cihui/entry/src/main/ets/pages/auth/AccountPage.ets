/**
 * F14 账号资料页：头像昵称、手机号 / 邮箱 / 微信逐行带 › 进字段二级编辑；
 * QQ 行仅在绑定后出现；退出登录回未登录态。保存后本页与首页问候语由 V2 自动同步。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { AuthStore } from '../../viewmodel/AuthStore';
import { SyncStore } from '../../viewmodel/SyncStore';
import { LocalAuthService } from '../../service/LocalAuthService';
import { LocalFileSyncService } from '../../service/LocalFileSyncService';
import { RouteName } from '../../common/RouteNames';
import type { FieldEditRouteParam } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import type { AccountField } from '../../model/AuthCore';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

class AccountRowSpec {
  field: AccountField;
  label: string;

  constructor(field: AccountField, label: string) {
    this.field = field;
    this.label = label;
  }
}

@ComponentV2
export struct AccountPage {
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.ACCOUNT) {
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
  @Local syncing: boolean = false;
  private rows: AccountRowSpec[] = [
    new AccountRowSpec('name', '昵称'),
    new AccountRowSpec('phone', '手机号'),
    new AccountRowSpec('email', '邮箱'),
    new AccountRowSpec('wechat', '微信'),
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

  private fieldValue(field: AccountField): string {
    const p = AuthStore.INSTANCE.profile;
    if (p === null) {
      return '';
    }
    if (field === 'name') {
      return p.name;
    }
    if (field === 'phone') {
      return p.phone;
    }
    if (field === 'email') {
      return p.email;
    }
    if (field === 'wechat') {
      return p.wechat;
    }
    return p.qq;
  }

  private openEdit(field: AccountField): void {
    const param: FieldEditRouteParam = { field: field };
    NavStore.INSTANCE.push(RouteName.FIELD_EDIT, param);
  }

  /* ---------- F15 云备份 ---------- */

  private cloudBadgeText(): string {
    const st = SyncStore.INSTANCE.status;
    if (st === 'syncing') {
      return '云备份同步中…';
    }
    if (st === 'failed') {
      return '云备份同步失败';
    }
    if (st === 'synced') {
      return '云备份已开启';
    }
    return AuthStore.INSTANCE.profile !== null && AuthStore.INSTANCE.profile.cloudEnabled
      ? '云备份已开启' : '云备份未开启';
  }

  private cloudBadgeColor(): string {
    const st = SyncStore.INSTANCE.status;
    if (st === 'failed') {
      return Colors.UNKNOWN_RED;
    }
    if (st === 'syncing') {
      return Colors.BRAND;
    }
    if (st === 'synced') {
      return Colors.KNOW_GREEN;
    }
    return AuthStore.INSTANCE.profile !== null && AuthStore.INSTANCE.profile.cloudEnabled
      ? Colors.KNOW_GREEN : Colors.TEXT_WEAK;
  }

  private syncTimeText(): string {
    const t: number = SyncStore.INSTANCE.lastSyncAt;
    if (t === 0) {
      return '从未同步';
    }
    const d: Date = new Date(t);
    const p = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `上次同步 ${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  private context(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private async doBackup(): Promise<void> {
    if (this.syncing) {
      return;
    }
    this.syncing = true;
    const r = await LocalFileSyncService.INSTANCE.backupNow(this.context(), false);
    this.syncing = false;
    if (r.message !== '') {
      this.toast(r.message);
    }
  }

  private async doExport(): Promise<void> {
    if (this.syncing) {
      return;
    }
    this.syncing = true;
    const r = await LocalFileSyncService.INSTANCE.exportToFile(this.context());
    this.syncing = false;
    this.toast(r.message);
  }

  private async doImport(): Promise<void> {
    if (this.syncing) {
      return;
    }
    this.syncing = true;
    const r = await LocalFileSyncService.INSTANCE.importFromFile(this.context());
    this.syncing = false;
    this.toast(r.message);
  }

  private confirmWipe(): void {
    try {
      promptAction.showDialog({
        title: '模拟换机',
        message: '将清空本机全部词本、学习进度与打卡记录（账号保留），用于验证备份恢复。确定继续？',
        buttons: [
          { text: '取消', color: Colors.TEXT_SUB },
          { text: '清空', color: Colors.UNKNOWN_RED },
        ],
      }, (err: Error, result: promptAction.ShowDialogSuccessResponse) => {
        if (!err && result.index === 1) {
          const r = LocalFileSyncService.INSTANCE.simulateWipe();
          this.toast(r.message);
        }
      });
    } catch (_e) {
    }
  }

  private confirmLogout(): void {
    try {
      promptAction.showDialog({
        title: '退出登录',
        message: '退出后本机词本、学习进度与打卡记录将清空，新账号空起步；需要保留请先在「备份与恢复」导出 JSON。',
        buttons: [
          { text: '取消', color: Colors.TEXT_SUB },
          { text: '退出', color: Colors.UNKNOWN_RED },
        ],
      }, (err: Error, result: promptAction.ShowDialogSuccessResponse) => {
        if (err) {
          return;
        }
        if (result.index === 1) {
          LocalAuthService.INSTANCE.logout();
          this.toast('已退出登录');
          NavStore.INSTANCE.back();
        }
      });
    } catch (_e) {
      LocalAuthService.INSTANCE.logout();
      NavStore.INSTANCE.back();
    }
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())
      Text('账号与云备份')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)
      Row().width(44).height(44)
    }
    .width('100%').height(56)
  }

  @Builder
  ProfileHeader() {
    Row() {
      Stack() {
        Text(AuthStore.INSTANCE.profile !== null ? AuthStore.INSTANCE.profile.avatarText : '词')
          .fontSize(26).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
      }
      .width(64).height(64).borderRadius(32).backgroundColor(Colors.BRAND)

      Column() {
        Text(this.fieldValue('name'))
          .fontSize(19).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN).maxLines(1)
        Row() {
          if (SyncStore.INSTANCE.status === 'syncing') {
            LoadingProgress().width(12).height(12).color(Colors.BRAND).margin({ right: 5 })
          }
          Text(this.cloudBadgeText()).fontSize(12).fontColor(this.cloudBadgeColor())
        }
        .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start).margin({ left: 14 }).layoutWeight(1)
    }
    .width('100%').padding(18)
    .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD).margin({ top: 8, bottom: 16 })
  }

  @Builder
  RowItem(field: AccountField, label: string) {
    Row() {
      Text(label).fontSize(15).fontColor(Colors.TEXT_MAIN)
      Text(this.fieldValue(field) !== '' ? this.fieldValue(field) : '未绑定')
        .fontSize(14)
        .fontColor(this.fieldValue(field) !== '' ? Colors.TEXT_SUB : Colors.TEXT_WEAK)
        .layoutWeight(1).textAlign(TextAlign.End).margin({ right: 6 }).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('›').fontSize(20).fontColor(Colors.TEXT_WEAK)
    }
    .width('100%').height(54).padding({ left: 16, right: 14 })
    .onClick(() => this.openEdit(field))
  }

  @Builder
  ActionRow(label: string, hint: string, tapped: () => void) {
    Row() {
      Column() {
        Text(label).fontSize(15).fontColor(Colors.TEXT_MAIN)
        if (hint !== '') {
          Text(hint).fontSize(11).fontColor(Colors.TEXT_WEAK).margin({ top: 3 })
        }
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.syncing) {
        LoadingProgress().width(18).height(18).color(Colors.BRAND)
      } else {
        Text('›').fontSize(20).fontColor(Colors.TEXT_WEAK)
      }
    }
    .width('100%').constraintSize({ minHeight: 54 }).padding({ left: 16, right: 14, top: 8, bottom: 8 })
    .onClick(tapped)
  }

  @Builder
  SyncCard() {
    Column() {
      Row() {
        Text('云备份').fontSize(15).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        Blank()
        Text(this.syncTimeText()).fontSize(11).fontColor(Colors.TEXT_WEAK)
      }
      .width('100%').padding({ left: 16, right: 14, top: 13, bottom: 6 })

      this.ActionRow('立即同步', '把词本、学习进度、打卡记录与设置备份到本机备份区（云端通道待接入）',
        (): void => {
          this.doBackup();
        })
      Divider().color(Colors.DIVIDER).margin({ left: 16, right: 16 })
      this.ActionRow('导出备份文件', '生成 .json 备份，通过系统文件选择器存到自选位置，用于换机',
        (): void => {
          this.doExport();
        })
      Divider().color(Colors.DIVIDER).margin({ left: 16, right: 16 })
      this.ActionRow('导入并恢复', '选择备份文件，按时间戳合并恢复；恢复前自动留存本机副本',
        (): void => {
          this.doImport();
        })
      Divider().color(Colors.DIVIDER).margin({ left: 16, right: 16 })
      this.ActionRow('模拟换机（清空本机数据）', '验收用：清空本机学习数据、保留登录，随后可用备份恢复',
        (): void => {
          this.confirmWipe();
        })
    }
    .width('100%').backgroundColor(Colors.WHITE).borderRadius(Radius.CARD).clip(true)
    .margin({ top: 16 })
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        Scroll() {
          Column() {
            this.ProfileHeader()

            Column() {
              ForEach(this.rows, (spec: AccountRowSpec) => {
                this.RowItem(spec.field, spec.label)
              }, (spec: AccountRowSpec): string => spec.field)
              // QQ 行仅在绑定后出现
              if (this.fieldValue('qq') !== '') {
                this.RowItem('qq', 'QQ')
              }
            }
            .width('100%').backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
            .clip(true)

            this.SyncCard()

            Button('退出登录')
              .type(ButtonType.Capsule).width('100%').height(48)
              .fontSize(15).fontColor(Colors.UNKNOWN_RED)
              .backgroundColor(Colors.WHITE).borderRadius(Radius.BUTTON)
              .margin({ top: 28 })
              .onClick(() => this.confirmLogout())

            Text('微信 / QQ 一键登录能力待接入；当前为本地账号，资料保存在本机')
              .fontSize(11).fontColor(Colors.TEXT_WEAK).textAlign(TextAlign.Center)
              .width('100%').margin({ top: 16, bottom: 24 })
          }
          .width('100%').padding({ left: 16, right: 16 })
        }
        .layoutWeight(1).scrollBar(BarState.Off)
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
