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
 * TODO(待真机核验)：
 * 1. 目标机型 HMS Core 语音识别引擎是否存在、zh-CN 离线模型是否预装；
 * 2. AudioCapturer 与 TTS 同会话的音频焦点、真机识别时延与 isFinal 切句频率；
 * 3. 后台/锁屏、蓝牙麦克风、权限永久拒绝后的恢复路径。
 */
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'CihuiAsr';

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

  beginWord(): void {
    const engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
    if (engine === null) {
      this.notifyError(-1, '语音引擎未初始化');
      return;
    }
    this.seq += 1;
    this.sessionId = `cihui-asr-${this.seq}`;
    const sid: string = this.sessionId;
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
        this.capturer = capturer;
        this.readCallback = (buffer: ArrayBuffer): void => {
          try {
            if (this.engine !== null && this.sessionId === sid) {
              this.engine.writeAudio(sid, new Uint8Array(buffer));
            }
          } catch (err) {
            hilog.warn(0x0000, TAG, 'writeAudio failed: %{public}s',
              (err as Error)?.message ?? 'unknown');
          }
        };
        capturer.on('readData', this.readCallback);
        capturer.start().then((): void => {
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
          }
        }).catch((err: Error): void => {
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

  release(): void {
    const engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
    if (engine !== null && this.sessionId.length > 0) {
      try {
        engine.cancel(this.sessionId);
      } catch (e) {
        hilog.warn(0x0000, TAG, 'cancel failed: %{public}s', (e as Error)?.message ?? 'unknown');
      }
    }
    this.stopCapturer();
    if (engine !== null) {
      try {
        engine.shutdown();
      } catch (e) {
        hilog.warn(0x0000, TAG, 'shutdown failed: %{public}s', (e as Error)?.message ?? 'unknown');
      }
    }
    this.engine = null;
    this.setState('idle');
  }
}
