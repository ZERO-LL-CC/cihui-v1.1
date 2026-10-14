/**
 * 词慧 · 英文朗读服务（F7）
 *
 * 基于 HMS CoreSpeechKit 的 textToSpeech（离线引擎）：
 * - 该 Kit 仅存在于 HMS 侧（@kit.CoreSpeechKit → @hms.ai.textToSpeech），
 *   OpenHarmony 侧没有对应声明；真机需安装/支持 HMS Core 语音引擎。
 * - 英文音色 person=8（Laura，可能需要在引擎内下载），失败时回退 person=0；
 *   两种音色都创建失败时进入 unavailable，页面给提示而不是崩溃。
 * - 语速取设置项 settings.ttsRate（0.5~2.0，默认 1）。
 *
 * TODO(待真机核验)：
 * 1. HMS Core 语音引擎在目标机型是否存在、en-US 离线音色是否预装/需下载；
 * 2. SpeakParams.extraParams 中语速字段名（官方示例演进中出现过 speed/speakSpeed），
 *    当前以 'speed' 透传，若真机不生效需按官方文档更正；
 * 3. 与 F8 speechRecognizer 同时使用时的音频焦点与引擎实例上限（同设备最多 3 实例）。
 */
import { textToSpeech } from '@kit.CoreSpeechKit';

export type TtsState = 'idle' | 'initializing' | 'ready' | 'unavailable';

class TtsServiceImpl {
  state: TtsState = 'idle';
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private rate: number = 1;
  private seq: number = 0;

  /**
   * 初始化英文离线引擎。重复调用复用结果；全部失败置 unavailable，不抛异常给 UI。
   * 返回最终状态，页面据此显示喇叭或降级提示。
   */
  async init(rate: number): Promise<TtsState> {
    this.rate = rate;
    if (this.state === 'ready' || this.state === 'unavailable') {
      return this.state;
    }
    this.state = 'initializing';
    let engine: textToSpeech.TextToSpeechEngine | null = null;
    try {
      engine = await this.createWithPerson(0);
    } catch (_e1) {
      try {
        // 默认音色不支持英文时回退 Laura（可能需要引擎内下载离线音色）
        engine = await this.createWithPerson(8);
      } catch (_e2) {
        engine = null;
      }
    }
    if (engine === null) {
      // HMS 引擎缺失 / 音色不支持 / 离线资源未安装：降级，不崩
      console.warn('[TtsService] engine unavailable: all createEngine attempts failed');
      this.engine = null;
      this.state = 'unavailable';
      return this.state;
    }
    this.engine = engine;
    this.attachListener(engine);
    this.state = 'ready';
    return this.state;
  }

  private createWithPerson(person: number): Promise<textToSpeech.TextToSpeechEngine> {
    const params: textToSpeech.CreateEngineParams = {
      language: 'en-US',
      person,
      online: 1, // 1 = 离线模式（0 在线模式当前不支持）
    };
    return textToSpeech.createEngine(params);
  }

  private attachListener(engine: textToSpeech.TextToSpeechEngine): void {
    const listener: textToSpeech.SpeakListener = {
      onStart: (_requestId: string, _response: textToSpeech.StartResponse): void => {
      },
      onComplete: (_requestId: string, _response: textToSpeech.CompleteResponse): void => {
      },
      onStop: (_requestId: string, _response: textToSpeech.StopResponse): void => {
      },
      onError: (requestId: string, errorCode: number, errorMessage: string): void => {
        console.warn(`[TtsService] speak error ${requestId} ${errorCode} ${errorMessage}`);
      },
    };
    engine.setListener(listener);
  }

  /** 朗读英文；未就绪时静默返回 false，由页面决定提示。会先打断上一条。 */
  speak(text: string, rate?: number): boolean {
    if (rate !== undefined) {
      this.rate = rate;
    }
    const engine: textToSpeech.TextToSpeechEngine | null = this.engine;
    if (this.state !== 'ready' || engine === null || text.length === 0) {
      return false;
    }
    try {
      if (engine.isBusy()) {
        engine.stop();
      }
      this.seq += 1;
      const extra: Record<string, Object> = { 'speed': this.rate as Object };
      const params: textToSpeech.SpeakParams = {
        requestId: `cihui-tts-${this.seq}`,
        extraParams: extra,
      };
      engine.speak(text, params);
      return true;
    } catch (e) {
      console.warn(`[TtsService] speak failed: ${(e as Error)?.message ?? e}`);
      return false;
    }
  }

  stop(): void {
    const engine: textToSpeech.TextToSpeechEngine | null = this.engine;
    if (engine === null) {
      return;
    }
    try {
      if (engine.isBusy()) {
        engine.stop();
      }
    } catch (e) {
      console.warn(`[TtsService] stop failed: ${(e as Error)?.message ?? e}`);
    }
  }

  /** 页面销毁时释放引擎资源 */
  shutdown(): void {
    const engine: textToSpeech.TextToSpeechEngine | null = this.engine;
    if (engine === null) {
      return;
    }
    try {
      engine.shutdown();
    } catch (e) {
      console.warn(`[TtsService] shutdown failed: ${(e as Error)?.message ?? e}`);
    }
    this.engine = null;
    this.state = 'idle';
  }
}

export const TtsService: TtsServiceImpl = new TtsServiceImpl();
