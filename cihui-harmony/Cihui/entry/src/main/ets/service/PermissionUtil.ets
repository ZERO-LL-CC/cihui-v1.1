/**
 * 运行时权限工具（F3）：申请前由页面先说明用途，被拒后给“去设置 / 手动录入”降级。
 * 权限必须同时在 module.json5 的 requestPermissions 中声明。
 */
import { abilityAccessCtrl, common, Want } from '@kit.AbilityKit';
import type { Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'CihuiPerm';

export class PermissionUtil {
  /** 查询权限是否已授予（同步） */
  static isGranted(context: common.UIAbilityContext, permission: Permissions): boolean {
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const status: abilityAccessCtrl.GrantStatus =
        atManager.checkAccessTokenSync(context.applicationInfo.accessTokenId, permission);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'check failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /** 弹系统授权框；返回最终是否授予 */
  static async request(context: common.UIAbilityContext, permission: Permissions): Promise<boolean> {
    try {
      if (PermissionUtil.isGranted(context, permission)) {
        return true;
      }
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      // 结果类型随 SDK 版本命名不同，交由类型推断，只用其中的 authResults 数组
      const perms: Permissions[] = [permission];
      const result: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(context, perms);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'request failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /**
   * 跳转本应用的系统设置页（权限被拒后的“去设置”）。
   * action.settings.app.info 为系统设置扩展动作，参数 settingsParamBundleName 指定应用；
   * TODO(真机核验)：个别 ROM 动作名可能不同，失败时 Toast 提示用户手动到设置开启。
   */
  static openAppSettings(context: common.UIAbilityContext): void {
    try {
      const want: Want = {
        action: 'action.settings.app.info',
        parameters: {
          'settingsParamBundleName': context.abilityInfo.bundleName
        }
      };
      context.startAbility(want);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'open settings failed: %{public}s', JSON.stringify(err));
      try {
        promptAction.showToast({ message: '请在系统设置中开启相机权限', duration: 2500 });
      } catch (e) {
        hilog.warn(0x0000, TAG, 'toast failed: %{public}s', JSON.stringify(e));
      }
    }
  }
}
