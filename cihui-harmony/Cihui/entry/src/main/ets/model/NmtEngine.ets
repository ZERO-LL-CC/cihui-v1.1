/**
 * 词慧 · 端侧神经机器翻译（NMT）引擎状态机。
 *
 * 为什么需要这一层：真机链路（Opus-MT zh→en + transformers.js + onnxruntime-web）
 * 只在 Web 渲染进程里跑得动，但「读模型峰值 727MB / 稳态 565MB」决定了它绝不能常驻。
 * 因此把「翻译能力」抽象成一台状态机，UI 只跟状态机打交道：
 *
 *   IDLE ──load()──▶ LOADING ──notifyReady()──▶ READY ⇄ RUNNING
 *                      │                          │
 *                      └────── 超时 / 报错 ───────▶ FAILED
 *
 * 关键设计（这是「模型没好也不卡用户」的根本）：
 * 1. translate() **永不抛异常、永不挂起**：任何非 READY 状态立即 resolve 一个
 *    ok=false + 人类可读 message 的结果，调用方拿到后可以零成本降级到离线库；
 * 2. 加载有硬超时（LOAD_TIMEOUT_MS），推理有硬超时（RUN_TIMEOUT_MS），
 *    超时一定把状态推向 FAILED 并 resolve 掉等待中的 Promise，绝不留下永久 pending；
 * 3. 本层不 import 任何 ArkUI / @kit.ArkWeb，UI 与 Web 的耦合全部收敛到
 *    NmtDriver 接口（由 components/NmtHost 实现），因此这一层可被单测直接 import。
 */

/** 引擎状态：界面按钮文案与提示语全部由它驱动 */
export type NmtState = 'IDLE' | 'LOADING' | 'READY' | 'RUNNING' | 'FAILED';

/** 一次端侧翻译的结果（永不抛异常，失败也是正常返回值） */
export interface NmtResult {
  /** 是否真的译出了英文 */
  ok: boolean;
  /** 英文结果；ok=false 时为空串 */
  english: string;
  /** 端侧推理耗时（毫秒）；ok=false 时为 0 */
  costMs: number;
  /** 失败原因，可直接给 UI 展示 / Toast */
  message: string;
}

/**
 * 宿主驱动：由 components/NmtHost 实现，引擎只调这三个方法。
 * 这样引擎不知道 Web 组件、不知道 controller，也不知道页面生命周期。
 */
export interface NmtDriver {
  /** 开始加载模型（宿主已挂载，可以加载 https://mt.local/index.html 了） */
  start(): void;
  /** 请求宿主把 text 送进页面内的 window.nmtTranslate */
  exec(text: string): void;
  /** 页面销毁前释放宿主内部引用（真正省内存靠的是组件被移出渲染树） */
  release(): void;
}

/** 模型加载硬超时：真机实测 3.2s，留足 12s 给低端机与冷启动 */
export const LOAD_TIMEOUT_MS: number = 12000;
/** 单次推理硬超时：真机实测 5.7s，留足 20s 给长句 */
export const RUN_TIMEOUT_MS: number = 20000;

export class NmtEngine {
  private state: NmtState = 'IDLE';
  private listeners: Array<(s: NmtState) => void> = [];
  private driver: NmtDriver | null = null;
  /** load() 是否已被请求过（幂等锁；dispose 后复位，允许下次进页面重新加载） */
  private loadRequested: boolean = false;
  private loadTimer: number = -1;
  private runTimer: number = -1;
  /** 等待中的翻译 Promise 的 resolve（同一时刻最多一个） */
  private pending: ((r: NmtResult) => void) | null = null;
  private pendingText: string = '';
  private runStartAt: number = 0;
  /** 宿主真正开始加载的时刻（用于算出 loadCostMs） */
  private loadStartAt: number = 0;
  /** 最近一次失败原因（UI 想知道「为什么退化成离线库」时可读） */
  private lastError: string = '';
  private loadCostMs: number = 0;

  /** 当前状态 */
  getState(): NmtState {
    return this.state;
  }

  /** 是否可以立刻做真翻译 */
  isReady(): boolean {
    return this.state === 'READY';
  }

  /** 最近一次失败原因；没失败过则为空串 */
  lastMessage(): string {
    return this.lastError;
  }

  /** 模型加载耗时（毫秒）；未就绪为 0 */
  loadCost(): number {
    return this.loadCostMs;
  }

  /**
   * 订阅状态变化。页面在 aboutToAppear 里订阅、dispose 时统一清空，
   * 同一个回调重复订阅不会被执行两次。
   */
  onStateChange(cb: (s: NmtState) => void): void {
    if (this.listeners.indexOf(cb) >= 0) {
      return;
    }
    this.listeners.push(cb);
    // 立即回放一次当前状态：页面订阅晚于 load() 时不会漏掉「准备中」
    try {
      cb(this.state);
    } catch (e) {
      console.warn(`[NmtEngine] replay listener failed: ${(e as Error)?.message ?? e}`);
    }
  }

  /**
   * 开始加载模型。幂等：重复调用只生效一次（页面重建、用户连点都不会重复加载）。
   * 真正干活的是宿主 driver.start()，驱动可能还没挂载（aboutToAppear 早于 build），
   * 此时先停在 LOADING，attach() 时补发。
   */
  load(): void {
    if (this.loadRequested) {
      return;
    }
    this.loadRequested = true;
    this.lastError = '';
    this.loadCostMs = 0;
    this.setState('LOADING');
    this.clearLoadTimer();
    this.loadTimer = setTimeout((): void => {
      this.loadTimer = -1;
      if (this.state === 'LOADING') {
        this.fail('端侧模型加载超时，本次改用离线库');
      }
    }, LOAD_TIMEOUT_MS);
    this.driveStart();
  }

  /**
   * 翻译。**任何情况下都会 resolve**：
   * - READY  → 真翻译，结果由宿主回调 notifyResult/notifyError 兑现；
   * - RUNNING→ 立刻返回 ok=false（上一次还没完，UI 本来也是禁用态）；
   * - 其它   → 立刻返回 ok=false + message，调用方据此降级到离线库。
   */
  translate(zh: string): Promise<NmtResult> {
    const text: string = zh.trim();
    if (text.length === 0) {
      return Promise.resolve(this.mkResult(false, '', 0, '请先输入中文句子'));
    }
    if (this.state === 'RUNNING') {
      return Promise.resolve(this.mkResult(false, '', 0, '端侧翻译还在进行，请稍候'));
    }
    if (this.state === 'FAILED') {
      return Promise.resolve(this.mkResult(false, '', 0, '端侧模型不可用，已用离线库匹配'));
    }
    if (this.state !== 'READY') {
      return Promise.resolve(this.mkResult(false, '', 0, '端侧模型准备中，已用离线库匹配'));
    }

    // 先建 Promise 再驱动宿主：回调哪怕同步回来也一定能落到 pending 上
    const task: Promise<NmtResult> = new Promise<NmtResult>(
      (resolve: (r: NmtResult) => void): void => {
        this.pending = resolve;
      });
    this.pendingText = text;
    this.runStartAt = Date.now();
    this.setState('RUNNING');
    this.clearRunTimer();
    this.runTimer = setTimeout((): void => {
      this.runTimer = -1;
      if (this.state === 'RUNNING') {
        this.fail('端侧翻译超时，本次改用离线库');
      }
    }, RUN_TIMEOUT_MS);
    this.driveExec(text);
    return task;
  }

  /** 宿主挂载：把 driver 交给引擎，并补发此前被推迟的 start() */
  attach(driver: NmtDriver): void {
    this.driver = driver;
    if (this.loadRequested && this.state === 'LOADING') {
      this.driveStart();
    }
  }

  /** 宿主卸载：只登记 driver 已消失（状态机保持原样，由 dispose 决定是否复位） */
  detach(): void {
    if (this.driver !== null) {
      this.driver.release();
    }
    this.driver = null;
  }

  /** 页面内模型就绪（nmtBridge.onReady） */
  notifyReady(): void {
    if (this.state === 'READY' || this.state === 'RUNNING') {
      return;
    }
    if (this.state === 'FAILED') {
      return;
    }
    this.clearLoadTimer();
    this.lastError = '';
    this.loadCostMs = this.loadStartAt > 0 ? Date.now() - this.loadStartAt : 0;
    this.setState('READY');
  }

  /** 页面内翻译完成（nmtBridge.onResult） */
  notifyResult(text: string, english: string, costMs: number): void {
    this.clearRunTimer();
    const en: string = english !== undefined && english !== null ? english.trim() : '';
    const cost: number = costMs > 0 ? costMs : Math.max(0, Date.now() - this.runStartAt);
    if (en.length === 0) {
      this.resolvePending(this.mkResult(false, '', 0, '端侧模型没有产出英文，已用离线库匹配'));
    } else {
      this.resolvePending(this.mkResult(true, en, cost, '端侧翻译完成'));
    }
    this.pendingText = '';
    if (this.state === 'RUNNING') {
      this.setState('READY');
    }
  }

  /**
   * 页面内报错（nmtBridge.onError）。
   * - 加载阶段报错 → 直接 FAILED（模型没起来，别耗着）；
   * - 推理阶段报错 → 回到 READY（模型仍在，只是这一句失败），这句降级走离线库。
   */
  notifyError(msg: string): void {
    const reason: string = msg !== undefined && msg !== null && msg.length > 0 ? msg : '端侧翻译出错';
    if (this.state === 'RUNNING') {
      this.clearRunTimer();
      this.lastError = reason;
      this.resolvePending(this.mkResult(false, '', 0, reason));
      this.pendingText = '';
      this.setState('READY');
      return;
    }
    this.fail(reason);
  }

  /**
   * 页面销毁时调用：清定时器、兑现挂起的 Promise、断开宿主、清订阅、状态复位 IDLE。
   * 复位很关键——下次进页面时 load() 才会真正重新加载，而不会因为「已请求过」空转。
   */
  dispose(): void {
    this.clearLoadTimer();
    this.clearRunTimer();
    this.resolvePending(this.mkResult(false, '', 0, '端侧翻译已关闭'));
    if (this.driver !== null) {
      this.driver.release();
      this.driver = null;
    }
    this.pendingText = '';
    this.loadRequested = false;
    this.loadCostMs = 0;
    this.runStartAt = 0;
    this.loadStartAt = 0;
    this.lastError = '';
    this.listeners = [];
    // 直接赋值而不走 setState：页面正在销毁，不必再回调 UI
    this.state = 'IDLE';
  }

  /* ================= 内部实现 ================= */

  private driveStart(): void {
    const d: NmtDriver | null = this.driver;
    if (d === null) {
      // 宿主还没挂载：不判失败，等 attach() 补发；加载超时由 loadTimer 兜底
      return;
    }
    if (this.loadStartAt === 0) {
      this.loadStartAt = Date.now();
    }
    try {
      d.start();
    } catch (e) {
      this.fail(`端侧模型启动失败：${(e as Error)?.message ?? e}`);
    }
  }

  private driveExec(text: string): void {
    const d: NmtDriver | null = this.driver;
    if (d === null) {
      this.fail('端侧翻译宿主未挂载');
      return;
    }
    try {
      d.exec(text);
    } catch (e) {
      this.notifyError(`端侧翻译下发失败：${(e as Error)?.message ?? e}`);
    }
  }

  private mkResult(ok: boolean, english: string, costMs: number, message: string): NmtResult {
    const r: NmtResult = {
      ok,
      english,
      costMs,
      message
    };
    return r;
  }

  private resolvePending(r: NmtResult): void {
    const p: ((r: NmtResult) => void) | null = this.pending;
    this.pending = null;
    if (p !== null) {
      try {
        p(r);
      } catch (e) {
        console.warn(`[NmtEngine] resolve pending failed: ${(e as Error)?.message ?? e}`);
      }
    }
  }

  private fail(msg: string): void {
    this.clearLoadTimer();
    this.clearRunTimer();
    this.lastError = msg;
    this.pendingText = '';
    this.resolvePending(this.mkResult(false, '', 0, msg));
    this.setState('FAILED');
  }

  private clearLoadTimer(): void {
    if (this.loadTimer !== -1) {
      clearTimeout(this.loadTimer);
      this.loadTimer = -1;
    }
  }

  private clearRunTimer(): void {
    if (this.runTimer !== -1) {
      clearTimeout(this.runTimer);
      this.runTimer = -1;
    }
  }

  private setState(next: NmtState): void {
    if (this.state === next) {
      return;
    }
    this.state = next;
    // 复制一份再遍历：回调里可能会改订阅表（页面销毁）
    const snapshot: Array<(s: NmtState) => void> = this.listeners.slice();
    snapshot.forEach((cb: (s: NmtState) => void): void => {
      try {
        cb(next);
      } catch (e) {
        console.warn(`[NmtEngine] listener failed: ${(e as Error)?.message ?? e}`);
      }
    });
  }
}

/**
 * 全局唯一引擎实例：页面与 NmtHost 组件共用同一台状态机。
 * 注意：它只持有状态与回调，不持有模型/Web 引用，因此**不构成常驻内存**——
 * 565MB 在 Web 渲染进程里，由组件挂载/卸载决定生死。
 */
export const nmtEngine: NmtEngine = new NmtEngine();
