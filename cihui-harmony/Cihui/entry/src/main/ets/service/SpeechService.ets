/**
 * 词慧 · 语音识别服务（F8）
 *
 * 接口 SpeechService 与 HMS 实现 HmsSpeechService：
 * - HMS @kit.CoreSpeechKit 的 speechRecognizer 为「流式写 PCM」接口（仅 zh-CN、离线）：
 *   createEngine → setListener → startListening(sessionId, audioInfo pcm16k/16bit/mono)
 *   → AudioCapturer('readData') 回调里 writeAudio(sessionId, Uint8Array)
 *   → onResult 给中间/最终结果 → finish(sessionId)；单会话音频上限 60s。
 * - 每个单词一个会话（beginWord/endWord），天然规避 60s 上限并按词切段；
 * - createEngine 失败、无 HMS Core、麦克风被拒等全部抛给页面，页面降级手动三档，进度不丢。
 *
 * 真机踩坑（HUAWEI JUY-AL80 / HarmonyOS，错误码 1002200010
 * "Write audio failed because the start listening is failed."）：
 * 1. 必须「先 startListening，再往会话里写音频」。旧实现先开 AudioCapturer、
 *    在 .then 里才 startListening，readData 可能先于 startListening 到达 → 引擎报未启动。
 * 2. 官方 FAQ：写入的 PCM 必须是 640 或 1280 字节的整帧（16k·16bit·单声道 = 20ms/640B）。
 *    AudioCapturer 的 readData 分片长度不保证是整帧，直接透传会被引擎拒收 → 这里做定长切帧。
 */
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'CihuiAsr';

/** 引擎只吃整帧 PCM：16kHz·16bit·单声道 20ms = 640 字节 */
const FRAME_BYTES: number = 640;

export type AsrState = 'idle' | 'creating' | 'ready' | 'listening' | 'paused' | 'unavailable';

export interface AsrListener {
  onPartial(text: string): void;
  onFinal(text: string): void;
  onError(code: number, message: string): void;
  onStateChange(state: AsrState): void;
}

export interface SpeechService {
  /** 创建引擎；失败返回 false，页面进入手动模式 */
  init(): Promise<boolean>;
  /** 重新创建引擎（先把旧引擎拆干净，避免多引擎并发） */
  rebuild(): Promise<boolean>;
  /** 开始一个单词的识别会话（含麦克风采集） */
  beginWord(): void;
  /** 结束当前单词会话并停采（保留引擎） */
  endWord(): void;
  release(): void;
}

export class HmsSpeechService implements SpeechService {
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private capturer: audio.AudioCapturer | null = null;
  private listener: AsrListener | null = null;
  private sessionId: string = '';
  private seq: number = 0;
  private state: AsrState = 'idle';
  private readCallback: ((buffer: ArrayBuffer) => void) | null = null;
  /** 不足一帧的尾巴，留到下次拼成整帧再写 */
  private pending: Uint8Array = new Uint8Array(0);
  private chunkLogged: boolean = false;

  private setState(s: AsrState): void {
    this.state = s;
    if (this.listener !== null) {
      this.listener.onStateChange(s);
    }
  }

  setListener(listener: AsrListener): void {
    this.listener = listener;
  }

  async init(): Promise<boolean> {
    this.setState('creating');
    try {
      const params: speechRecognizer.CreateEngineParams = {
        language: 'zh-CN',
        online: 1, // 1 = 离线
      };
      this.engine = await speechRecognizer.createEngine(params);
      const recognitionListener: speechRecognizer.RecognitionListener = {
        onStart: (_sessionId: string, _eventMessage: string): void => {
          hilog.info(0x0000, TAG, 'asr session start');
        },
        onEvent: (_sessionId: string, _eventCode: number, _eventMessage: string): void => {
        },
        onResult: (_sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          if (this.listener === null) {
            return;
          }
          const text: string = result.result ?? '';
          if (result.isFinal) {
            this.listener.onFinal(text);
          } else {
            this.listener.onPartial(text);
          }
        },
        onComplete: (_sessionId: string, _eventMessage: string): void => {
          if (this.state === 'listening') {
            this.setState('ready');
          }
        },
        onError: (_sessionId: string, errorCode: number, errorMessage: string): void => {
          hilog.warn(0x0000, TAG, 'asr error %{public}d %{public}s', errorCode, errorMessage);
          if (this.listener !== null) {
            this.listener.onError(errorCode, errorMessage);
          }
        },
      };
      this.engine.setListener(recognitionListener);
      this.setState('ready');
      return true;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'createEngine failed: %{public}s', (e as Error)?.message ?? 'unknown');
      this.engine = null;
      this.setState('unavailable');
      return false;
    }
  }

  /** 手动→语音、或引擎异常后重建：先拆干净再建，避免多引擎/多会话并发 */
  async rebuild(): Promise<boolean> {
    this.teardown();
    return this.init();
  }

  beginWord(): void {
    const engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
    if (engine === null) {
      this.notifyError(-1, '语音引擎未初始化');
      return;
    }
    this.seq += 1;
    const sid: string = `cihui-asr-${this.seq}`;
    this.sessionId = sid;
    this.pending = new Uint8Array(0);

    // ① 先启动识别任务，再往里写音频（顺序反了就是 1002200010）
    try {
      const startParams: speechRecognizer.StartParams = {
        sessionId: sid,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16,
        },
      };
      engine.startListening(startParams);
      this.setState('listening');
    } catch (err) {
      hilog.warn(0x0000, TAG, 'startListening failed: %{public}s',
        (err as Error)?.message ?? 'unknown');
      this.notifyError(-2, '启动识别失败');
      return;
    }

    // ② 再开麦，readData 里按整帧喂给引擎
    this.startCapturer(sid);
  }

  private startCapturer(sid: string): void {
    try {
      const options: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_MIC,
          capturerFlags: 0,
        },
      };
      audio.createAudioCapturer(options).then((capturer: audio.AudioCapturer): void => {
        if (this.sessionId !== sid) {
          // 会话已切换（用户已翻到下一个词），这路采集直接丢掉
          try {
            capturer.release();
          } catch (e) {
            hilog.warn(0x0000, TAG, 'release stale capturer failed');
          }
          return;
        }
        this.capturer = capturer;
        this.readCallback = (buffer: ArrayBuffer): void => {
          this.feedAudio(buffer, sid);
        };
        capturer.on('readData', this.readCallback);
        capturer.start().catch((err: Error): void => {
          hilog.warn(0x0000, TAG, 'capturer start failed: %{public}s', err?.message ?? 'unknown');
          this.notifyError(-3, '麦克风启动失败');
        });
      }).catch((err: Error): void => {
        hilog.warn(0x0000, TAG, 'createCapturer failed: %{public}s', err?.message ?? 'unknown');
        this.notifyError(-4, '麦克风不可用');
      });
    } catch (e) {
      this.notifyError(-5, (e as Error)?.message ?? '识别启动异常');
    }
  }

  /**
   * 把采集到的 PCM 切成整帧再写：
   * readData 的分片长度由系统决定（常见 3200/4096 字节，也可能零散），
   * 引擎只认 640/1280 字节整帧，直接透传会报 1002200010。
   */
  private feedAudio(buffer: ArrayBuffer, sid: string): void {
    const engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
    if (engine === null || this.sessionId !== sid || this.state !== 'listening') {
      return;
    }
    if (!this.chunkLogged) {
      this.chunkLogged = true;
      hilog.info(0x0000, TAG, 'pcm chunk %{public}d bytes', buffer.byteLength);
    }
    const incoming: Uint8Array = new Uint8Array(buffer);
    const merged: Uint8Array = new Uint8Array(this.pending.length + incoming.length);
    merged.set(this.pending, 0);
    merged.set(incoming, this.pending.length);

    let offset: number = 0;
    while (merged.length - offset >= FRAME_BYTES) {
      try {
        engine.writeAudio(sid, merged.slice(offset, offset + FRAME_BYTES));
      } catch (err) {
        hilog.warn(0x0000, TAG, 'writeAudio failed: %{public}s',
          (err as Error)?.message ?? 'unknown');
        break;
      }
      offset += FRAME_BYTES;
    }
    this.pending = merged.slice(offset);
  }

  endWord(): void {
    const engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
    if (engine !== null && this.sessionId.length > 0) {
      try {
        engine.finish(this.sessionId);
      } catch (e) {
        hilog.warn(0x0000, TAG, 'finish failed: %{public}s', (e as Error)?.message ?? 'unknown');
      }
    }
    this.stopCapturer();
    this.pending = new Uint8Array(0);
    if (this.state === 'listening') {
      this.setState('ready');
    }
  }

  private stopCapturer(): void {
    const capturer: audio.AudioCapturer | null = this.capturer;
    if (capturer === null) {
      return;
    }
    try {
      if (this.readCallback !== null) {
        capturer.off('readData', this.readCallback);
        this.readCallback = null;
      }
      capturer.stop();
      capturer.release();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'stopCapturer failed: %{public}s', (e as Error)?.message ?? 'unknown');
    }
    this.capturer = null;
  }

  private notifyError(code: number, message: string): void {
    if (this.listener !== null) {
      this.listener.onError(code, message);
    }
    this.setState('ready');
  }

  private teardown(): void {
    this.stopCapturer();
    const engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
    if (engine !== null) {
      try {
        if (this.sessionId.length > 0) {
          engine.cancel(this.sessionId);
        }
      } catch (e) {
        hilog.warn(0x0000, TAG, 'cancel failed: %{public}s', (e as Error)?.message ?? 'unknown');
      }
      try {
        engine.shutdown();
      } catch (e) {
        hilog.warn(0x0000, TAG, 'shutdown failed: %{public}s', (e as Error)?.message ?? 'unknown');
      }
    }
    this.engine = null;
    this.sessionId = '';
    this.pending = new Uint8Array(0);
    this.setState('idle');
  }

  release(): void {
    this.teardown();
  }
}
