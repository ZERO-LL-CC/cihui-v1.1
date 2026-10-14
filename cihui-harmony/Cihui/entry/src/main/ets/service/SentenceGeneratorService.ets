/**
 * F19 例句生成统一接口与火山豆包实现。
 * 页面只依赖 SentenceGeneratorService 接口；未来换模型 / 换 AGC 云函数代理，
 * 只新增一个实现类，TodaySentencePage 不动。
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import type { GeneratedSentence, Word } from '../model/Types';
import { buildPrompt, parseSentencePayload } from '../model/SentenceCore';
import {
  DOUBAO_API_KEY,
  DOUBAO_ENDPOINT,
  DOUBAO_MODEL,
  SENTENCE_MAX_RETRY,
  SENTENCE_TIMEOUT_MS,
} from './SentenceGeneratorConfig';

/** 例句生成器接口（输入一批词，返回若干结构化例句） */
export interface SentenceGeneratorService {
  /** 是否可用（未配置 Key / 未联网环境为 false，页面走降级） */
  available(): boolean;
  generateSentences(words: Word[], count: number): Promise<GeneratedSentence[]>;
}

interface ChatMessage {
  role: string;
  content: string;
}

interface ChatReq {
  model: string;
  messages: ChatMessage[];
  temperature: number;
}

interface ChatChoice {
  message: ChatMessage;
}

interface ChatResp {
  choices: ChatChoice[];
}

/** 火山方舟 Doubao-lite 实现（OpenAI 兼容 chat/completions） */
class DoubaoSentenceGeneratorImpl implements SentenceGeneratorService {
  available(): boolean {
    return DOUBAO_API_KEY.length > 0;
  }

  async generateSentences(words: Word[], count: number): Promise<GeneratedSentence[]> {
    if (!this.available()) {
      throw new Error('未配置大模型 Key，已切换为本地释义');
    }
    if (words.length === 0) {
      throw new Error('本批没有可用单词');
    }
    let lastErr: Error = new Error('生成失败');
    // 首次 + 最多 SENTENCE_MAX_RETRY 次重试（网络抖动 / 返回半截 JSON）
    for (let attempt = 0; attempt <= SENTENCE_MAX_RETRY; attempt++) {
      try {
        const raw: string = await this.requestOnce(words, count);
        return parseSentencePayload(raw, words);
      } catch (e) {
        lastErr = e as Error;
      }
    }
    throw lastErr;
  }

  private async requestOnce(words: Word[], count: number): Promise<string> {
    const req = http.createHttp();
    try {
      const body: ChatReq = {
        model: DOUBAO_MODEL,
        messages: [{ role: 'user', content: buildPrompt(words, count) }],
        temperature: 0.7,
      };
      const resp = await req.request(DOUBAO_ENDPOINT, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          // 不打印、不落盘；只存在于运行时内存
          'Authorization': `Bearer ${DOUBAO_API_KEY}`,
        },
        extraData: JSON.stringify(body),
        connectTimeout: SENTENCE_TIMEOUT_MS,
        readTimeout: SENTENCE_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING,
      });
      if (resp.responseCode !== 200) {
        throw new Error(`造句服务响应异常（${resp.responseCode}）`);
      }
      const raw: string = typeof resp.result === 'string' ? resp.result : '';
      if (raw.length === 0) {
        throw new Error('造句结果为空');
      }
      const parsed = JSON.parse(raw) as ChatResp;
      const first: ChatChoice | undefined = parsed.choices?.[0];
      const content: string = first?.message?.content ?? '';
      if (content.trim().length === 0) {
        throw new Error('造句内容为空');
      }
      return content;
    } catch (e) {
      const msg0: string = (e as Error)?.message ?? '';
      if (msg0.indexOf('造句') >= 0) {
        throw new Error(msg0);
      }
      // 真机网络层错误：透出错误码，便于定位超时 / DNS / 不可达（不含 Key）
      const be = e as BusinessError;
      const code: number = typeof be?.code === 'number' ? be.code : -1;
      const raw: string = be?.message ?? '';
      hilog.error(0x0000, 'CihuiSentence', 'generate net fail code=%{public}d msg=%{public}s', code, raw);
      const low: string = raw.toLowerCase();
      let hint: string = '手机无法连接造句服务，请换 WiFi/流量后重试';
      if (low.indexOf('timeout') >= 0 || low.indexOf('timed out') >= 0) {
        hint = '造句请求超时，当前网络较慢，请换网络或稍后重试';
      } else if (low.indexOf('dns') >= 0 || low.indexOf('resolve') >= 0 || low.indexOf('unreachable') >= 0) {
        hint = '网络无法解析或不可达，请检查手机网络后重试';
      }
      throw new Error(hint + (code > 0 ? '（错误码 ' + code + '）' : ''));
    } finally {
      try {
        req.destroy();
      } catch (_e) {
        // 销毁异常忽略
      }
    }
  }
}

/** 全局唯一实例，页面统一从这里取 */
export const SentenceGenerator: SentenceGeneratorService = new DoubaoSentenceGeneratorImpl();
