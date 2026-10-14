/**
 * 显式刷新事件总线（动态 QA 实测补充）。
 *
 * 背景：API 26 模拟器上实测，被二级页覆盖的一级 Tab 页与栈内已实例化的
 * NavDestination，在覆盖期间收不到 @Trace / @Param 的重绘投递，popTo 目标页
 * 甚至不触发 onShown。为不依赖框架的重绘时机，导航与数据提交两类动作额外
 * 通过本总线发出显式事件：页面在 aboutToAppear 订阅、aboutToDisappear 退订，
 * 自己成为栈顶（或当前 Tab 可见）时自增本地版本号，强制重算 build。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

export type RefreshListener = () => void;

const TAG: string = 'CihuiBus';

class RefreshBus {
  private navListeners: Set<RefreshListener> = new Set();
  private dataListeners: Set<RefreshListener> = new Set();

  /** 订阅导航事件（push/back/popTo/finishToHome），返回监听者本身用于退订 */
  onNav(fn: RefreshListener): RefreshListener {
    this.navListeners.add(fn);
    return fn;
  }

  offNav(fn: RefreshListener): void {
    this.navListeners.delete(fn);
  }

  /** 订阅数据提交事件（DataStore 每次 commit） */
  onData(fn: RefreshListener): RefreshListener {
    this.dataListeners.add(fn);
    return fn;
  }

  offData(fn: RefreshListener): void {
    this.dataListeners.delete(fn);
  }

  private emit(set: Set<RefreshListener>, kind: string): void {
    hilog.info(0x0000, TAG, 'emit %{public}s listeners=%{public}d', kind, set.size);
    set.forEach((fn: RefreshListener): void => {
      try {
        fn();
      } catch (e) {
        hilog.error(0x0000, TAG, '%{public}s listener error: %{public}s', kind, (e as Error)?.message ?? 'unknown');
      }
    });
  }

  emitNav(): void {
    this.emit(this.navListeners, 'nav');
  }

  emitData(): void {
    this.emit(this.dataListeners, 'data');
  }
}

export const REFRESH_BUS: RefreshBus = new RefreshBus();
