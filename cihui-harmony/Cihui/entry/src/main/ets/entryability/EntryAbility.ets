import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { NavStore } from '../viewmodel/NavStore';
import { DataStore } from '../viewmodel/DataStore';
import { AuthStore } from '../viewmodel/AuthStore';
import { LAUNCH_TARGET_KEY, TARGET_CHECKIN } from '../service/ReminderService';
import { CloudBookLoader } from '../service/CloudBookLoader';
import { TtsService } from '../service/TtsService';

const DOMAIN: number = 0x0000;

/**
 * 调试用：aa start 时带 --ps devPage pages/dev/MtProbePage 可直达指定页面。
 * 不传则走默认首页，正常启动流程完全不受影响。
 */
const DEV_PAGE_KEY: string = 'devPage';

export default class EntryAbility extends UIAbility {
  private devPage: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // qa19 BUG-B：先接沙箱持久化并读回本机数据/登录态，再加载页面
    try {
      DataStore.INSTANCE.attachContext(this.context);
      AuthStore.INSTANCE.attachContext(this.context);
      CloudBookLoader.attachContext(this.context);
    } catch (err) {
      hilog.warn(DOMAIN, 'Cihui', 'attach local state failed: %{public}s', JSON.stringify(err));
    }
    // 颜色模式跟随系统，设置失败不影响启动流程
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.warn(DOMAIN, 'Cihui', 'setColorMode failed: %{public}s', JSON.stringify(err));
    }
    this.applyLaunchWant(want);
    hilog.info(DOMAIN, 'Cihui', 'Ability onCreate');
  }

  /** F16：通知点击携带的 Want → 落地页（冷启动时 UI 尚未就绪，NavStore 暂存） */
  private applyLaunchWant(want: Want): void {
    try {
      const params: Record<string, Object> | undefined = want?.parameters;
      if (params !== undefined && params !== null) {
        const target: Object | undefined = params[LAUNCH_TARGET_KEY];
        if (target !== undefined && (target as string) === TARGET_CHECKIN) {
          NavStore.INSTANCE.setLaunchTarget(TARGET_CHECKIN);
        }
        const dev: Object | undefined = params[DEV_PAGE_KEY];
        if (dev !== undefined && (dev as string).length > 0) {
          this.devPage = dev as string;
          hilog.info(DOMAIN, 'Cihui', 'devPage override: %{public}s', this.devPage);
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'Cihui', 'applyLaunchWant failed: %{public}s', JSON.stringify(err));
    }
  }

  /** F16：App 在后台/前台时点击通知，走 onNewWant 直达 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyLaunchWant(want);
  }

  onDestroy(): void {
    // TTS 引擎随 Ability 释放（单例只持 1 个引擎，页面级 stop() 已足够；
    // 此处收口避免进程退出后引擎句柄悬留）。
    try {
      TtsService.shutdown();
    } catch (err) {
      hilog.warn(DOMAIN, 'Cihui', 'tts shutdown failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'Cihui', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const page: string = this.devPage.length > 0 ? this.devPage : 'pages/Index';
    windowStage.loadContent(page, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'Cihui', 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'Cihui', 'loadContent succeeded: %{public}s', page);
    });
  }

  onWindowStageDestroy(): void {}

  onForeground(): void {}

  onBackground(): void {}
}
