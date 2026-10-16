/**
 * 词慧 · 英文朗读服务（F7）
 *
 * 基于 HMS CoreSpeechKit 的 textToSpeech（离线引擎）：
 * - 该 Kit 仅存在于 HMS 侧（@kit.CoreSpeechKit → @hms.ai.textToSpeech），
 *   OpenHarmony 侧没有对应声明；真机需支持 HMS Core 语音引擎。
 * - 语速取设置项 settings.ttsRate（0.5~2.0，默认 1）。
 *
 * v1.2 修复（2026-10-16，畅享90 真机取证）：
 *   旧实现写死 person=0→8，真机实测——
 *     createEngine person=0 → 1002300003「person not support」（该音色根本不存在）
 *     createEngine person=8 → 1002300005「Invalid relative path」（en_US 音色未下载，模型文件缺失）
 *   listVoices 实测设备返回：
 *     zh_CN person=13 status=INSTALLED / zh_CN person=21 status=GA / en_US person=8 status=GA
 *   即：设备**有** en_US 音色(person=8)，但状态为 GA（未下载）；
 *   离线 createEngine 必须先 downloadVoice 把音色下到设备（**需联网一次**，之后可离线）。
 *   现改为：listVoices 选英文音色 → 未安装则 downloadVoice → createEngine(真实 person)；
 *   断网时置 needDownload（可感知，不静默），联网后再次进入页面会自动重试下载。
 *   错误码统一走 hilog(TAG=CihuiTts)，查看：hdc shell hilog -x | grep CihuiTts
 *
 * TODO(待真机继续核验)：
 * 1. [已核验 2026-10-17] extraParams 在 SDK 声明中为 Record<string, Object>，不枚举键名，
 *    'speed' 为官方文档口径（域 0.5~2.0）；设置页仅提供 0.8/1.0/1.2（ProfilePage.ets:233），
 *    不会静默失效 —— 无需改代码，仅需真机听辨确认。
 * 2. 与 F8 speechRecognizer 同时使用时的音频焦点与引擎实例上限（同设备最多 3 实例）。
 */
import { textToSpeech } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'CihuiTts';
const DOMAIN: number = 0x0000;
/** createEngine 的语言标识（官方文档格式，带连字符） */
const EN_LANG: string = 'en-US';
/** listVoices 返回的 status：已安装 */
const STATUS_INSTALLED: string = 'INSTALLED';
/** 音色已下载（downloadVoice 重复调用时的错误码，视为成功） */
const ERR_VOICE_ALREADY_DOWNLOADED: number = 1002300010;
/** 下载音色失败·网络未连接 */
const ERR_NO_NETWORK: number = 1002300008;

export type TtsState = 'idle' | 'initializing' | 'downloading' | 'needDownload' | 'ready' | 'unavailable';

class TtsServiceImpl {
  state: TtsState = 'idle';
  /** 最近一次失败原因（供页面提示；成功时为空） */
  reason: string = '';
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private rate: number = 1;
  private seq: number = 0;

  /**
   * 初始化英文离线引擎。ready/unavailable 直接复用；其余（含 needDownload）会重新尝试。
   * 失败不抛异常给 UI，通过 state/reason 表达。
   */
  async init(rate: number): Promise<TtsState> {
    this.rate = rate;
    if (this.state === 'ready' || this.state === 'unavailable') {
      return this.state;
    }
    return this.bootstrap();
  }

  /** 手动重试（联网后用户点「重试」用）。 */
  async retryDownload(): Promise<TtsState> {
    return this.bootstrap();
  }

  private async bootstrap(): Promise<TtsState> {
    this.state = 'initializing';
    this.reason = '';
    try {
      const voice: textToSpeech.VoiceInfo | null = await this.pickEnglishVoice();
      if (voice === null) {
        hilog.error(DOMAIN, TAG, 'no English voice on device -> unavailable');
        return this.fail('本机未提供英文发音音色');
      }

      if (!this.isInstalled(voice)) {
        this.state = 'downloading';
        const dlErr: BusinessError | null = await this.ensureVoiceDownloaded(voice);
        if (dlErr !== null) {
          if (dlErr.code === ERR_NO_NETWORK) {
            hilog.warn(DOMAIN, TAG, 'voice needs download but device offline -> needDownload');
            this.state = 'needDownload';
            this.reason = '需联网下载英文发音音色';
            return this.state;
          }
          hilog.error(DOMAIN, TAG, 'voice download failed code=%{public}d msg=%{public}s',
            dlErr.code, dlErr.message);
          return this.fail('英文发音音色下载失败');
        }
      }

      this.engine = await this.createWithPerson(voice.person);
      this.attachListener(this.engine);
      this.state = 'ready';
      this.reason = '';
      hilog.info(DOMAIN, TAG, 'TTS ready lang=%{public}s person=%{public}d',
        voice.language, voice.person);
      return this.state;
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'bootstrap failed code=%{public}d msg=%{public}s', be.code, be.message);
      return this.fail(be.message);
    }
  }

  private fail(reason: string): TtsState {
    this.engine = null;
    this.state = 'unavailable';
    this.reason = reason;
    return this.state;
  }

  /** 列出设备音色并挑一个英文音色（language 形如 en_US / en-US）。 */
  private async pickEnglishVoice(): Promise<textToSpeech.VoiceInfo | null> {
    const infos: textToSpeech.VoiceInfo[] = await textToSpeech.listVoices({
      requestId: `cihui-tts-query-${Date.now()}`,
      online: 1,
    });
    hilog.info(DOMAIN, TAG, 'listVoices count=%{public}d', infos.length);
    let picked: textToSpeech.VoiceInfo | null = null;
    for (let i = 0; i < infos.length; i++) {
      const v: textToSpeech.VoiceInfo = infos[i];
      hilog.info(DOMAIN, TAG,
        'voice[%{public}d] lang=%{public}s person=%{public}d status=%{public}s desc=%{public}s',
        i, v.language, v.person, v.status ?? 'null', v.description ?? '');
      if (picked === null && (v.language ?? '').toLowerCase().startsWith('en')) {
        picked = v;
      }
    }
    return picked;
  }

  private isInstalled(v: textToSpeech.VoiceInfo): boolean {
    return (v.status ?? '').toUpperCase() === STATUS_INSTALLED;
  }

  /** 确保音色已下载到设备；已下载（1002300010）视为成功。返回 null 表示成功。 */
  private ensureVoiceDownloaded(v: textToSpeech.VoiceInfo): Promise<BusinessError | null> {
    return new Promise<BusinessError | null>((resolve: (e: BusinessError | null) => void): void => {
      const params: textToSpeech.VoiceDownload = {
        requestId: `cihui-tts-dl-${Date.now()}`,
        language: v.language,
        person: v.person,
        style: v.style ?? '',
      };
      textToSpeech.downloadVoice(params, (err: BusinessError, resp: textToSpeech.DownloadResponse) => {
        if (err) {
          if (err.code === ERR_VOICE_ALREADY_DOWNLOADED) {
            hilog.info(DOMAIN, TAG, 'voice already downloaded, skip');
            resolve(null);
          } else {
            hilog.error(DOMAIN, TAG, 'downloadVoice cb err code=%{public}d msg=%{public}s',
              err.code, err.message);
            resolve(err);
          }
          return;
        }
        hilog.info(DOMAIN, TAG, 'download start rid=%{public}s lang=%{public}s person=%{public}d',
          resp.requestId, v.language, v.person);
        resp.on('progress', (progress: string) => {
          hilog.info(DOMAIN, TAG, 'download progress=%{public}s', progress);
        });
        resp.on('complete', (info: textToSpeech.VoiceInfo) => {
          hilog.info(DOMAIN, TAG, 'download complete lang=%{public}s person=%{public}d status=%{public}s',
            info.language, info.person, info.status ?? 'null');
          resolve(null);
        });
        resp.on('error', (e: BusinessError) => {
          hilog.error(DOMAIN, TAG, 'download error code=%{public}d msg=%{public}s', e.code, e.message);
          resolve(e);
        });
      });
    });
  }

  private createWithPerson(person: number): Promise<textToSpeech.TextToSpeechEngine> {
    const params: textToSpeech.CreateEngineParams = {
      language: EN_LANG,
      person,
      online: 1, // 1 = 离线模式（0 在线模式）
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
        hilog.error(DOMAIN, TAG, 'speak onError rid=%{public}s code=%{public}d msg=%{public}s',
          requestId, errorCode, errorMessage);
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
      hilog.warn(DOMAIN, TAG, 'speak skipped state=%{public}s hasEngine=%{public}s len=%{public}d',
        this.state, engine === null ? 'no' : 'yes', text.length);
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
      const be: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'speak fail code=%{public}d msg=%{public}s', be.code, be.message);
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
      const be: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'stop fail code=%{public}d msg=%{public}s', be.code, be.message);
    }
  }

  /** 释放引擎资源（会重置 state，下次使用需重新 init）。由 EntryAbility.onDestroy 调用，做进程退出收口。 */
  shutdown(): void {
    const engine: textToSpeech.TextToSpeechEngine | null = this.engine;
    if (engine === null) {
      return;
    }
    try {
      engine.shutdown();
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'shutdown fail code=%{public}d msg=%{public}s', be.code, be.message);
    }
    this.engine = null;
    this.state = 'idle';
  }
}

export const TtsService: TtsServiceImpl = new TtsServiceImpl();
