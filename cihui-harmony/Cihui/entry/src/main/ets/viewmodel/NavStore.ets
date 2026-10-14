/**
 * 全局导航仓库：持有唯一 NavPathStack、二级页覆盖态、系统减弱动效开关。
 * 本期按用户要求以内存态运行（数据仓库在 F2 落地）。
 */
import { accessibility } from '@kit.AccessibilityKit';
import deviceInfo from '@ohos.deviceInfo';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RouteName } from '../common/RouteNames';
import { REFRESH_BUS } from '../common/RefreshBus';

@ObservedV2
export class NavStore {
  static readonly INSTANCE: NavStore = new NavStore();
  @Trace stack: NavPathStack = new NavPathStack();
  /** 是否有二级页覆盖一级页（驱动一级页缩放/位移/压暗） */
  @Trace covered: boolean = false;
  /** F4 导入完成标记：校对页返回后，相机页 onShown 据此再退一层，实现关全部二级页回来源页 */
  @Trace importDone: boolean = false;
  /** 系统“减弱动态效果”开关 */
  @Trace reducedMotion: boolean = false;
  /** F16：通知点击冷启动/回前台时携带的落地页目标（如 checkin），Index 消费一次后清空 */
  @Trace launchTarget: string = '';
  /**
   * 导航版本号：每次 push/back/popTo/finishToHome 自增。
   * 动态 QA 实测：被二级页覆盖的一级 Tab 页 / 栈内已实例化的 NavDestination，
   * 在覆盖期间收不到 @Trace 数据变更的重绘，需要显式刷新信号；
   * Index 把它作为 @Param 传给三个 Tab 页，二级页在 onShown 自增本地 tick。
   */
  @Trace navTick: number = 0;

  /** F6：首页“去打卡”等跨 Tab 跳转，由 Index 注册控制器回调 */
  private tabHandler: ((index: number) => void) | null = null;
  /** F16：通知点击落地回调，由 Index 注册；注册前到达的目标暂存 launchTarget */
  private launchHandler: ((target: string) => void) | null = null;
  /**
   * 动态 QA：路由参数缓存。实测被覆盖的 NavDestination 重新露出后，
   * 即使自增 @Local 也不会重绘（渲染节点冻结），因此任何 POP（含边缘
   * 滑动返回手势）结束后，用 clear + 静默 push 重建整条栈，栈顶为全新
   * 实例，首次 build 一定读取最新仓库。replacePath 在 API 26 模拟器上
   * 会导致空白页，已弃用。
   */
  private rebuildScheduled: boolean = false;
  /** 重建期间 clear 自身也会触发 POP 回调，用此标志忽略，防止无限循环 */
  private rebuilding: boolean = false;

  private constructor() {
    // 动态 QA 实测：POP 后对栈做任何手术（replacePath / clear+push / push 新页再删旧）
    // 在 API 26 模拟器上都会让 Navigation 内容树整屏变白，故拦截重建已停用；
    // 改为「数据变更后回一级 Tab，Tab 用 ForEach 键控重挂载」的可靠方案。
    // 保留 setInterception 仅作日志观察，不再改动栈。
    this.stack.setInterception({
      didShow: (_from: NavDestinationContext | NavBar, _to: NavDestinationContext | NavBar,
        operation: NavigationOperation): void => {
        hilog.debug(0x0000, 'CihuiBus', 'nav didShow op=%{public}d depth=%{public}d',
          operation as number, this.stack.size());
      }
    });
  }

  registerTabHandler(handler: (index: number) => void): void {
    this.tabHandler = handler;
  }

  registerLaunchHandler(handler: (target: string) => void): void {
    this.launchHandler = handler;
    if (this.launchTarget !== '') {
      const t: string = this.launchTarget;
      this.launchTarget = '';
      handler(t);
    }
  }

  goTab(index: number): void {
    if (this.tabHandler !== null) {
      this.tabHandler(index);
    }
  }

  /**
   * 数据变更后的可靠落地：清空二级页栈回一级 Tab（clear 到 navBar 是实测
   * 不变白的原语），再切到指定 Tab 并由 Index 重挂载，保证读到最新仓库。
   * 用于云词书下载完成等「返回列表必须刷新」的场景。
   */
  backToTab(index: number): void {
    this.stack.clear(false);
    this.covered = false;
    this.navTick++;
    REFRESH_BUS.emitNav();
    this.goTab(index);
  }

  /**
   * 数据变更后必须落在一个全新栈内页（如云书下载完成直接回「我的词本」）。
   * 动态 QA 实测：popTo 露出的旧栈页渲染冻结，onShown 里自增 @Local/showTick
   * 也不会让 ForEach 重算（16:40 实证 books=1 但列表仍空态）。可靠路径：
   * 先 clear 回 Tab（实测不变白的原语，Tab 由 Index 键控重挂载），
   * 等转场稳定后再做一次普通 push（push 新页是唯一可靠的新建实例原语）。
   */
  backToTabThenPush(index: number, name: RouteName, param?: object): void {
    this.backToTab(index);
    setTimeout((): void => {
      this.push(name, param);
    }, 320);
  }

  /** 在 EntryAbility 启动时调用一次 */
  init(): void {
    // isAnimationReduceEnabledSync / onAnimationReduceStateChange 自 API 23 起提供，
    // 隶属 SystemCapability.BarrierFree.Accessibility.Core。低版本或设备不具备该
    // SysCap 时直接按完整动效处理，保证 API 23 以下不调用、不崩溃。
    const apiSupported: boolean = Number(deviceInfo.sdkApiVersion) >= 23;
    let capSupported: boolean = true;
    try {
      capSupported = canIUse('SystemCapability.BarrierFree.Accessibility.Core');
    } catch (err) {
      // canIUse 自身异常时不据此误关能力，退回到仅按 API 版本判断
      capSupported = true;
      hilog.warn(0x0000, 'Cihui', 'canIUse accessibility failed: %{public}s', JSON.stringify(err));
    }
    if (!apiSupported || !capSupported) {
      this.reducedMotion = false;
      return;
    }
    try {
      this.reducedMotion = accessibility.isAnimationReduceEnabledSync();
      accessibility.onAnimationReduceStateChange((reduce: boolean) => {
        this.reducedMotion = reduce;
      });
    } catch (err) {
      // 老版本或异常时按不动效降级处理，不阻断启动
      hilog.warn(0x0000, 'Cihui', 'reduced motion query failed: %{public}s', JSON.stringify(err));
      this.reducedMotion = false;
    }
  }

  push(name: RouteName, param?: object): void {
    this.stack.pushPath({ name: name, param: param });
    this.navTick++;
    REFRESH_BUS.emitNav();
  }

  back(): void {
    this.stack.pop();
    this.navTick++;
    REFRESH_BUS.emitNav();
    // POP 结束后由 setInterception.didShow 统一重建栈顶
  }

  /** 弹回到栈中指定的命名页（F5 下载完成后从详情页直接回我的词本） */
  popTo(name: RouteName): void {
    this.stack.popToName(name);
    this.navTick++;
    REFRESH_BUS.emitNav();
    // POP 结束后由 setInterception.didShow 统一重建栈顶
  }

  /**
   * POP 转场结束后刷新栈顶：在栈顶静默 push 同名同参的全新实例，
   * 再移除其下冻结的旧实例。实测 clear()+push 与 replacePath 都会让
   * Navigation 内容树整屏变白；只有 push 新页可靠，故采用「顶上压新、再删旧」。
   */
  private scheduleTopRebuild(): void {
    if (this.rebuildScheduled) {
      return;
    }
    this.rebuildScheduled = true;
    setTimeout((): void => {
      this.rebuildScheduled = false;
      const names: string[] = this.stack.getAllPathName();
      const depth: number = names.length;
      if (depth === 0) {
        // 已回到 Tab 层，由 Index 的总线监听负责重挂载当前 Tab
        return;
      }
      const staleIndex: number = depth - 1;
      const topName: string = names[staleIndex];
      const p: object | undefined = this.stack.getParamByIndex(staleIndex) as object | undefined;
      const info: NavPathInfo = p !== undefined && p !== null
        ? { name: topName, param: p }
        : { name: topName };
      this.rebuilding = true;
      // 静默压入全新实例，再删除其下冻结的旧实例（删除非栈顶页无转场）
      this.stack.pushPath(info, false);
      this.stack.removeByIndexes([staleIndex]);
      hilog.info(0x0000, 'CihuiBus', 'reborn top=%{public}s depth=%{public}d', topName, depth);
      // 等删除触发的拦截回调全部派发完再解除，防止二次重建
      setTimeout((): void => {
        this.rebuilding = false;
      }, 300);
    }, 80);
  }

  /** F8 一轮学习结束：清空二级页栈并回首页 Tab */
  finishToHome(): void {
    this.stack.clear(false);
    this.covered = false;
    this.navTick++;
    REFRESH_BUS.emitNav();
    this.goTab(0);
  }

  /** 根据栈深同步一级页覆盖态 */
  syncCovered(): void {
    this.covered = this.stack.size() > 0;
  }

  /** F16：EntryAbility 从通知 Want 中取到落地目标时调用 */
  setLaunchTarget(target: string): void {
    if (target === '') {
      return;
    }
    if (this.launchHandler !== null) {
      this.launchHandler(target);
    } else {
      this.launchTarget = target;
    }
  }

}
