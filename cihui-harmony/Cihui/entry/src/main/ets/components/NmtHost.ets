/**
 * 词慧 · 端侧翻译宿主（隐藏的 Web 组件）
 *
 * 作用：把「页面里的 transformers.js + onnxruntime-web」当成一台**可插拔**的翻译协处理器。
 *
 * 内存纪律（真机实测，决定了整个架构）：
 *   载入页面  render 149MB → 读模型峰值 727MB → 推理后稳态 565MB → 切后台 25s 回落 173MB
 * 所以模型绝不允许常驻：父组件用 @State showNmt 控制本组件是否在渲染树里，
 * 组件被移除 → Web 渲染进程整体销毁 → 565MB 立刻归还系统。
 * 这就是为什么本组件没有任何"暂停/保活"逻辑，只有 on/off。
 *
 * 三个已踩过的坑（照抄 pages/dev/MtProbePage.ets 的结论，勿重新探索）：
 * 1. resource://rawfile/ 下 fetch() 全部失败、ESM 被 CORS 挡（Origin=null）→
 *    伪造 https://mt.local/ 源，用 onInterceptRequest 把该域请求映射回 rawfile；
 * 2. transformers.js 已打成 IIFE 全局挂载到 window.transformers，
 *    普通 <script> 能加载，动态 import 会失败；
 * 3. $rawfile() 只吃编译期字面量，必须 switch 逐个枚举（rawOf）。
 *
 * 与探针页的差别（正式功能要求）：事件驱动，不轮询。
 * JS 侧通过 javaScriptProxy 注入的 window.nmtBridge 主动回调 ArkTS 的
 * onReady / onResult / onError，状态机据此推进，UI 不会靠 3 秒一次读变量来猜进度。
 */
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import type { NmtDriver } from '../model/NmtEngine';
import { nmtEngine } from '../model/NmtEngine';

const DOMAIN: number = 0x0000;
/** 伪造源：rawfile 下 fetch/ESM 都不可用，必须给页面一个 https 出身 */
const ORIGIN: string = 'https://mt.local/';
/** 版本戳：改 index.html 时同步改这里，避免 WebView 用旧缓存 */
const PAGE_URL: string = ORIGIN + 'index.html?v=nmt1';

/**
 * JS → ArkTS 的回调对象。由 Web 的 javaScriptProxy 注入为 window.nmtBridge。
 * 只做转发，不含任何业务判断（业务在 NmtEngine 状态机里）。
 */
class NmtBridge {
  onReadyCb: () => void = (): void => {
  };
  onResultCb: (text: string, english: string, costMs: number) => void =
    (text: string, english: string, costMs: number): void => {
    };
  onErrorCb: (msg: string) => void = (msg: string): void => {
  };
  onStageCb: (stage: string) => void = (stage: string): void => {
  };

  /** 页面内模型加载完成 */
  onReady(): void {
    hilog.info(DOMAIN, 'NmtHost', 'bridge onReady');
    this.onReadyCb();
  }

  /** 页面内单句翻译完成 */
  onResult(text: string, english: string, costMs: number): void {
    hilog.info(DOMAIN, 'NmtHost', 'bridge onResult cost=%{public}s ms', String(costMs));
    this.onResultCb(text, english, costMs);
  }

  /** 页面内任何环节报错（脚本缺失 / 模型加载失败 / 推理异常） */
  onError(msg: string): void {
    hilog.error(DOMAIN, 'NmtHost', 'bridge onError: %{public}s', String(msg));
    this.onErrorCb(msg);
  }

  /** 阶段日志（只用于排查，不参与状态机） */
  onStage(stage: string): void {
    hilog.info(DOMAIN, 'NmtHost', 'stage: %{public}s', String(stage));
    this.onStageCb(stage);
  }
}

/**
 * NmtDriver 的 Web 实现：把状态机的 start/exec/release 翻译成对 controller 的操作。
 * 单独成类是为了让「Web 细节」留在组件层，引擎层一行 ArkUI 代码都没有。
 */
class NmtWebDriver implements NmtDriver {
  private controller: webview.WebviewController;
  private bridge: NmtBridge;
  /** 页面 onPageEnd 之后才能安全 runJavaScript */
  private pageLoaded: boolean = false;

  constructor(controller: webview.WebviewController, bridge: NmtBridge) {
    this.controller = controller;
    this.bridge = bridge;
  }

  /** 页面 src 固定为 mt.local/index.html，页面 onload 后自己开始加载模型，这里只留日志 */
  start(): void {
    hilog.info(DOMAIN, 'NmtHost', 'driver start (pageLoaded=%{public}s)', String(this.pageLoaded));
  }

  /** 把一句话送进页面内的 window.nmtTranslate，结果由 nmtBridge 事件回来 */
  exec(text: string): void {
    if (!this.pageLoaded) {
      nmtEngine.notifyError('端侧页面还没加载完，本次改用离线库');
      return;
    }
    // JSON.stringify 负责转义（引号 / 换行 / 中文都不会破坏 JS 语句）
    const arg: string = JSON.stringify(text);
    const js: string = 'if (window.nmtTranslate) { window.nmtTranslate(' + arg + '); }' +
      ' else if (window.nmtBridge && nmtBridge.onError) { nmtBridge.onError("页面内翻译函数未就绪"); }';
    this.controller.runJavaScript(js)
      .then((value: string): void => {
        hilog.info(DOMAIN, 'NmtHost', 'exec dispatched: %{public}s', String(value));
      })
      .catch((err: Error): void => {
        hilog.error(DOMAIN, 'NmtHost', 'exec failed: %{public}s', String(err?.message));
        nmtEngine.notifyError('端侧翻译下发失败，本次改用离线库');
      });
  }

  /** 页面卸载：断开引用，不再接受下发 */
  release(): void {
    this.pageLoaded = false;
    hilog.info(DOMAIN, 'NmtHost', 'driver released');
  }

  markPageLoaded(): void {
    this.pageLoaded = true;
  }
}

@ComponentV2
export struct NmtHost {
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: NmtBridge = new NmtBridge();
  private driver: NmtWebDriver | null = null;

  aboutToAppear(): void {
    // JS → ArkTS 路由：只做转发，状态推进全部交给 NmtEngine
    this.bridge.onReadyCb = (): void => {
      nmtEngine.notifyReady();
    };
    this.bridge.onResultCb = (text: string, english: string, costMs: number): void => {
      nmtEngine.notifyResult(text, english, costMs);
    };
    this.bridge.onErrorCb = (msg: string): void => {
      nmtEngine.notifyError(msg);
    };
    this.bridge.onStageCb = (stage: string): void => {
      hilog.debug(DOMAIN, 'NmtHost', 'stage %{public}s', stage);
    };
    const d: NmtWebDriver = new NmtWebDriver(this.controller, this.bridge);
    this.driver = d;
    // 引擎可能在 aboutToAppear 里就调过 load()（早于本组件挂载），attach 负责补发 start
    nmtEngine.attach(d);
  }

  aboutToDisappear(): void {
    // 先摘掉 driver，再由 NmtEngine.dispose() 统一复位状态；组件离树后渲染进程自行退出
    nmtEngine.detach();
    this.driver = null;
  }

  private mimeOf(name: string): string {
    if (name.endsWith('.html')) {
      return 'text/html';
    }
    if (name.endsWith('.js')) {
      return 'application/javascript';
    }
    if (name.endsWith('.wasm')) {
      return 'application/wasm';
    }
    if (name.endsWith('.json')) {
      return 'application/json';
    }
    return 'application/octet-stream';
  }

  /** $rawfile 只吃字面量路径（编译期转资源 ID），所以必须逐个枚举，不能用拼接 */
  private rawOf(rel: string): Resource | null {
    switch (rel) {
      case 'index.html':
        return $rawfile('mt/index.html');
      case 'js/transformers.iife.js':
        return $rawfile('mt/js/transformers.iife.js');
      case 'js/ort-wasm-simd.wasm':
        return $rawfile('mt/js/ort-wasm-simd.wasm');
      case 'models/Xenova/opus-mt-zh-en/config.json':
        return $rawfile('mt/models/Xenova/opus-mt-zh-en/config.json');
      case 'models/Xenova/opus-mt-zh-en/generation_config.json':
        return $rawfile('mt/models/Xenova/opus-mt-zh-en/generation_config.json');
      case 'models/Xenova/opus-mt-zh-en/tokenizer.json':
        return $rawfile('mt/models/Xenova/opus-mt-zh-en/tokenizer.json');
      case 'models/Xenova/opus-mt-zh-en/tokenizer_config.json':
        return $rawfile('mt/models/Xenova/opus-mt-zh-en/tokenizer_config.json');
      case 'models/Xenova/opus-mt-zh-en/special_tokens_map.json':
        return $rawfile('mt/models/Xenova/opus-mt-zh-en/special_tokens_map.json');
      case 'models/Xenova/opus-mt-zh-en/vocab.json':
        return $rawfile('mt/models/Xenova/opus-mt-zh-en/vocab.json');
      case 'models/Xenova/opus-mt-zh-en/onnx/encoder_model_quantized.onnx':
        return $rawfile('mt/models/Xenova/opus-mt-zh-en/onnx/encoder_model_quantized.onnx');
      case 'models/Xenova/opus-mt-zh-en/onnx/decoder_model_merged_quantized.onnx':
        return $rawfile('mt/models/Xenova/opus-mt-zh-en/onnx/decoder_model_merged_quantized.onnx');
      default:
        return null;
    }
  }

  build() {
    // 1px + 全透明：不进视野但要留在渲染树里（设成 Hidden 会让页面停止运行，模型就加载不动了）
    Web({ src: PAGE_URL, controller: this.controller })
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .fileAccess(true)
      .imageAccess(false)
      .onlineImageAccess(false)
      .zoomAccess(false)
      .width(1)
      .height(1)
      .opacity(0)
      .hitTestBehavior(HitTestMode.None)
      .javaScriptProxy({
        object: this.bridge,
        name: 'nmtBridge',
        methodList: ['onReady', 'onResult', 'onError', 'onStage'],
        controller: this.controller
      })
      .onInterceptRequest((event) => {
        const url: string = event.request.getRequestUrl();
        let rel: string = url.startsWith(ORIGIN) ? url.substring(ORIGIN.length) : '';
        const q: number = rel.indexOf('?');
        if (q >= 0) {
          rel = rel.substring(0, q);
        }
        const res: Resource | null = rel.length > 0 ? this.rawOf(rel) : null;
        const resp: WebResourceResponse = new WebResourceResponse();
        if (res === null) {
          hilog.warn(DOMAIN, 'NmtHost', 'INTERCEPT miss url=%{public}s', url);
          resp.setResponseCode(404);
          resp.setResponseMimeType('text/plain');
          resp.setResponseData('not found');
          return resp;
        }
        resp.setResponseCode(200);
        resp.setResponseMimeType(this.mimeOf(rel));
        resp.setResponseData(res);
        if (rel.endsWith('.html') || rel.endsWith('.js') || rel.endsWith('.json')) {
          resp.setResponseEncoding('utf-8');
        }
        return resp;
      })
      .onPageEnd(() => {
        if (this.driver !== null) {
          this.driver.markPageLoaded();
        }
        hilog.info(DOMAIN, 'NmtHost', 'page end, model loading begins in page');
      })
      .onErrorReceive((event) => {
        const desc: string = event !== undefined && event.error !== undefined
          ? String(event.error.getErrorInfo()) : 'unknown';
        hilog.error(DOMAIN, 'NmtHost', 'resource error: %{public}s', desc);
      })
      .onConsole((event): boolean => {
        hilog.debug(DOMAIN, 'NmtHost', 'console: %{public}s', event.message);
        return false;
      })
  }
}
