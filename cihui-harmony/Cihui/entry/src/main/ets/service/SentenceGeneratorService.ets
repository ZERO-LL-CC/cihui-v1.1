/**
 * F19 例句生成统一接口与火山豆包实现。
 * 页面只依赖 SentenceGeneratorService 接口；未来换模型 / 换 AGC 云函数代理，
 * 只新增一个实现类，TodaySentencePage 不动。
 *
 * 两种产出并存（PRD Q1：整段为主、逐句保留可切）：
 * - generateSentences：逐句 N 句（老路径，保留）；
 * - generatePassage：8~12 句连贯短文 + 覆盖率，覆盖率不足时自动补漏一次。
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import type { GeneratedSentence, Word } from '../model/Types';
import type { PassageResult, PassageSentence } from '../model/SentenceCore';
import {
  PASSAGE_COVERAGE_TARGET,
  buildPassagePrompt,
  buildPatchPrompt,
  buildPrompt,
  computeCoverage,
  parsePassagePayload,
  parseSentencePayload,
} from '../model/SentenceCore';
import {
  DOUBAO_API_KEY,
  DOUBAO_ENDPOINT,
  DOUBAO_MODEL,
  SENTENCE_MAX_RETRY,
  SENTENCE_TIMEOUT_MS,
} from './SentenceGeneratorConfig';

/** 例句生成器接口（输入一批词，返回结构化例句 / 整段短文） */
export interface SentenceGeneratorService {
  /** 是否可用（未配置 Key / 未联网环境为 false，页面走降级） */
  available(): boolean;
  generateSentences(words: Word[], count: number): Promise<GeneratedSentence[]>;
  /** 整段生成（内部已自动补漏一次）；首次不可用 / 全失败时抛错，页面走降级 */
  generatePassage(words: Word[]): Promise<PassageResult>;
  /**
   * 手动再补漏一次（覆盖率卡上的「补漏一次」按钮用）。
   * 不重试；失败时直接把首轮结果原样返回，绝不吞掉用户已经看到的短文。
   */
  patchPassage(existing: PassageResult, words: Word[]): Promise<PassageResult>;
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
    const prompt: string = buildPrompt(words, count);
    let lastErr: Error = new Error('生成失败');
    // 首次 + 最多 SENTENCE_MAX_RETRY 次重试（网络抖动 / 返回半截 JSON）
    for (let attempt = 0; attempt <= SENTENCE_MAX_RETRY; attempt++) {
      try {
        const raw: string = await this.requestOnce(prompt);
        return parseSentencePayload(raw, words);
      } catch (e) {
        lastErr = e as Error;
      }
    }
    throw lastErr;
  }

  /**
   * 整段生成（主路径）。
   * 1. 首轮：8~12 句连贯短文（失败按 SENTENCE_MAX_RETRY 重试）；
   * 2. 覆盖率 < 80% 且确实有漏词 → **自动补漏一次**（补漏不再重试，见 PRD 异常 5）；
   * 3. 补漏失败就保留首轮结果，覆盖率如实显示，不抛错、不白屏。
   */
  async generatePassage(words: Word[]): Promise<PassageResult> {
    if (!this.available()) {
      throw new Error('未配置大模型 Key，已切换为本地释义');
    }
    if (words.length === 0) {
      throw new Error('本批没有可用单词');
    }
    const first: PassageResult = await this.requestPassage(buildPassagePrompt(words), words, true);
    if (first.coverage >= PASSAGE_COVERAGE_TARGET || first.missedWords.length === 0) {
      return first;
    }
    return this.patchOnce(first, words);
  }

  /** 手动补漏：一次机会，失败保留原结果（给覆盖率卡上的按钮用） */
  async patchPassage(existing: PassageResult, words: Word[]): Promise<PassageResult> {
    if (!this.available() || words.length === 0 || existing.missedWords.length === 0) {
      return existing;
    }
    return this.patchOnce(existing, words);
  }

  /**
   * 一轮请求 + 解析（withRetry=true 才重试）。
   * 抽出来是因为首轮与补漏共用同一套请求/超时/错误码透传逻辑。
   */
  private async requestPassage(prompt: string, words: Word[], withRetry: boolean): Promise<PassageResult> {
    const maxAttempt: number = withRetry ? SENTENCE_MAX_RETRY : 0;
    let lastErr: Error = new Error('生成失败');
    for (let attempt = 0; attempt <= maxAttempt; attempt++) {
      try {
        const raw: string = await this.requestOnce(prompt);
        return parsePassagePayload(raw, words);
      } catch (e) {
        lastErr = e as Error;
      }
    }
    throw lastErr;
  }

  /**
   * 补漏一次：把没覆盖的词塞进已有短文。
   *
   * 合并规则（这里有个坑，必须去重）：
   * 补漏 Prompt 要求模型「输出原有全部句子 + 追加句」，所以补漏返回里通常**已经包含原句**。
   * 若直接 concat，原句会整段重复一遍。因此只追加「原文里没出现过」的新句
   * （按 trim + 小写判重），然后对合并后的句子重算覆盖率——覆盖率只认实际文本，
   * 不接受模型自报的 coveredWords。
   */
  private async patchOnce(first: PassageResult, words: Word[]): Promise<PassageResult> {
    const missedWords: Word[] = this.pickMissed(first, words);
    if (missedWords.length === 0) {
      return first;
    }
    try {
      const raw: string = await this.requestOnce(buildPatchPrompt(missedWords, first));
      const patched: PassageResult = parsePassagePayload(raw, words);
      return this.mergePassage(first, patched, words);
    } catch (e) {
      // PRD 异常 5：补漏失败保留首轮结果，不阻塞、不报错
      hilog.warn(0x0000, 'CihuiSentence', 'patch failed, keep first round: %{public}s',
        (e as Error)?.message ?? 'unknown');
      return first;
    }
  }

  /** 把 missedWords（小写原词）映射回 Word[]，保住中文释义与顺序（Prompt 需要释义） */
  private pickMissed(first: PassageResult, words: Word[]): Word[] {
    const out: Word[] = [];
    words.forEach((w: Word): void => {
      if (first.missedWords.indexOf(w.english.trim().toLowerCase()) >= 0) {
        out.push(w);
      }
    });
    return out;
  }

  /** 合并首轮 + 补漏：只收新句，再按实际文本重算覆盖率 */
  private mergePassage(first: PassageResult, patched: PassageResult, words: Word[]): PassageResult {
    const seen: Set<string> = new Set<string>();
    const merged: PassageSentence[] = [];
    first.sentences.forEach((s: PassageSentence): void => {
      const key: string = s.sentence.trim().toLowerCase();
      seen.add(key);
      merged.push(s);
    });
    patched.sentences.forEach((s: PassageSentence): void => {
      const key: string = s.sentence.trim().toLowerCase();
      if (seen.has(key)) {
        return;
      }
      seen.add(key);
      merged.push(s);
    });
    if (merged.length === first.sentences.length) {
      // 补漏没带来任何新句（模型原样复述）：保持首轮，别假装提升了覆盖率
      return first;
    }
    const recomputed: PassageResult = computeCoverage(merged, words);
    recomputed.title = first.title.length > 0 ? first.title : patched.title;
    return recomputed;
  }

  private async requestOnce(prompt: string): Promise<string> {
    const req = http.createHttp();
    try {
      const body: ChatReq = {
        model: DOUBAO_MODEL,
        messages: [{ role: 'user', content: prompt }],
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
