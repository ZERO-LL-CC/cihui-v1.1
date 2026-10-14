/**
 * 词慧 · F17 梗句中文 → 英文翻译服务
 *
 * 历史：早期走公共 LibreTranslate 实例（libretranslate.de），该公共实例已停止免费开放，
 * 国内请求稳定返回 403（用户实测截图）。现改为复用火山方舟 Doubao-Seed-2.0-lite：
 * - 与 F19 例句生成共用 DOUBAO_API_KEY / ENDPOINT / MODEL，不引入第二套密钥；
 * - @kit.NetworkKit http 后台请求，不阻塞 UI；连接/读取各 10s 超时；
 * - Key 未配置、无网、超时、非 200 一律 reject，页面 Toast 提示且不阻断手动输入；
 * - 不打印、不落盘 Key；错误信息只透传 HTTP 状态码。
 *
 * 产品兜底始终是「用户手动填写英文框」，翻译只是加速器，不是必需路径。
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  DOUBAO_API_KEY,
  DOUBAO_ENDPOINT,
  DOUBAO_MODEL,
  SENTENCE_TIMEOUT_MS,
} from './SentenceGeneratorConfig';

const TAG: string = 'CihuiTranslate';

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

class TranslateServiceImpl {
  /** 是否可用（未配置 Key / 未联网环境为 false，页面走手动输入） */
  available(): boolean {
    return DOUBAO_API_KEY.length > 0;
  }

  /**
   * 中文 → 英文。成功返回译文；任何失败抛 Error（message 可直接 Toast）。
   */
  async zhToEn(zh: string): Promise<string> {
    const text: string = zh.trim();
    if (text.length === 0) {
      throw new Error('请先输入中文句子');
    }
    if (!this.available()) {
      throw new Error('翻译服务未配置，可手动填写英文');
    }
    const req = http.createHttp();
    try {
      const messages: ChatMessage[] = [
        {
          role: 'system',
          content: 'You are a Chinese-to-English translator. Translate the user\'s Chinese sentence into natural, grammatically correct English. Output ONLY the English sentence itself: no quotes, no pinyin, no notes, no original Chinese, no extra explanation.',
        },
        { role: 'user', content: text },
      ];
      const body: ChatReq = {
        model: DOUBAO_MODEL,
        messages,
        temperature: 0.3,
      };
      const resp = await req.request(DOUBAO_ENDPOINT, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${DOUBAO_API_KEY}`,
        },
        extraData: JSON.stringify(body),
        connectTimeout: SENTENCE_TIMEOUT_MS,
        readTimeout: SENTENCE_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING,
      });
      if (resp.responseCode !== 200) {
        const code: number = resp.responseCode;
        hilog.error(0x0000, TAG, 'translate non-200: %{public}d', code);
        if (code === 429) {
          throw new Error('翻译请求过快或免费额度已限流，请稍后再试（429），也可手动填写英文');
        }
        if (code === 401 || code === 403) {
          throw new Error('翻译服务授权失败（' + code + '），请稍后重试或手动填写英文');
        }
        if (code >= 500) {
          throw new Error('翻译服务暂时异常（' + code + '），请稍后再试或手动填写英文');
        }
        throw new Error('翻译服务暂不可用（' + code + '），可手动填写英文');
      }
      const raw: string = typeof resp.result === 'string' ? resp.result : '';
      if (raw.length === 0) {
        throw new Error('翻译结果为空，可手动填写英文');
      }
      const parsed = JSON.parse(raw) as ChatResp;
      const out: string = this.cleanTranslation(parsed.choices?.[0]?.message?.content ?? '');
      if (out.length === 0) {
        throw new Error('翻译结果为空，可手动填写英文');
      }
      return out;
    } catch (e) {
      // 业务层已构造好的中文提示（含翻译/填写/限流/授权）原样上抛，不二次包装
      const msg0: string = (e as Error)?.message ?? '';
      if (msg0.indexOf('翻译') >= 0 || msg0.indexOf('填写') >= 0 || msg0.indexOf('限流') >= 0
        || msg0.indexOf('授权') >= 0) {
        throw new Error(msg0);
      }
      // 真机网络层错误：透出 http BusinessError.code，定位是超时 / DNS / 不可达（不含 Key）
      const be = e as BusinessError;
      const code: number = typeof be?.code === 'number' ? be.code : -1;
      const raw: string = be?.message ?? '';
      hilog.error(0x0000, TAG, 'translate net fail code=%{public}d msg=%{public}s', code, raw);
      let hint: string = '手机无法连接翻译服务，请换 WiFi/流量后重试';
      const low: string = raw.toLowerCase();
      if (low.indexOf('timeout') >= 0 || low.indexOf('timed out') >= 0) {
        hint = '翻译请求超时，当前网络较慢，请换网络或稍后重试';
      } else if (low.indexOf('dns') >= 0 || low.indexOf('resolve') >= 0 || low.indexOf('unreachable') >= 0) {
        hint = '网络无法解析或不可达，请检查手机网络后重试';
      }
      throw new Error('翻译失败：' + hint + (code > 0 ? '（错误码 ' + code + '）' : '') + '，也可手动填写英文');
    } finally {
      try {
        req.destroy();
      } catch (_e) {
        // 销毁异常忽略
      }
    }
  }

  /** 去掉模型可能加的引号、前后缀标签，只留英文句子本身 */
  private cleanTranslation(s: string): string {
    let out: string = (s ?? '').trim();
    // 去掉常见前缀：Translation: / English: / 译文：等
    out = out.replace(/^\s*(translation|english|译文|英文)\s*[:：]\s*/i, '');
    // 去掉首尾成对引号
    if (out.length >= 2) {
      const first: string = out.charAt(0);
      const last: string = out.charAt(out.length - 1);
      if ((first === '"' && last === '"') || (first === '\'' && last === '\'')
        || (first === '“' && last === '”')) {
        out = out.substring(1, out.length - 1);
      }
    }
    return out.trim();
  }
}

export const TranslateService: TranslateServiceImpl = new TranslateServiceImpl();
