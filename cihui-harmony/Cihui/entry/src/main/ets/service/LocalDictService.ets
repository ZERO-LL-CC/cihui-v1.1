/**
 * 离线英汉词典：拍照 OCR 拆成单词气泡、F17 梗句拆词后，用它在本地自动填音标与中文，
 * 不依赖网络、不产生请求失败。数据随包放在 resources/rawfile/dict/ecdict-lite.json，
 * 由开源 ECDICT（MIT，skywind3000/ECDICT）生成，构建脚本见 _ecdict/generate_lite_dict.py。
 *
 * 文件结构（v2）：
 *   {"words":[{"w":"shatter","p":"/.../","m":"vt. 打碎…"}, ...],
 *    "alias":{"shattered":"shatter","gets":"get", ...}}   ← 28k 条词形索引
 *
 * 三级查找（F17 卡片背面必须有中文）：
 *   L1 词形本身命中 → 直接用；
 *   L2 alias 索引命中（shattered→shatter）→ 用原形释义，并标记 viaLemma 供 UI 提示；
 *   L3 规则还原候选（LemmaCore.lemmaCandidates）逐个试，命中即用。
 * 三级都未命中才返回 null，由调用方留空或走「结合原句语境理解」。
 *
 * 句子 / 短语翻译走端侧离线梗味引擎（TranslateService），零网络；本服务只管单词级释义。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { lemmaCandidates } from '../model/LemmaCore';

const TAG: string = 'CihuiDict';

interface RawDictWord {
  w: string;
  p: string;
  m: string;
}

interface RawDictBook {
  words: RawDictWord[];
  /** 派生形 → 原形，如 {"shattered":"shatter"} */
  alias?: Record<string, string>;
}

export interface DictEntry {
  phonetic: string;
  meaning: string;
}

/** 带命中信息的查询结果：命中变形时 matchedWord 是原形，UI 可提示「shattered ← shatter」 */
export interface DictHit {
  phonetic: string;
  meaning: string;
  /** 真正命中的词条（原形）；等于查询词时说明直接命中 */
  matchedWord: string;
  /** true = 经词形索引或规则还原命中，释义来自原形 */
  viaLemma: boolean;
}

export class LocalDictService {
  private static entries: Map<string, DictEntry> = new Map<string, DictEntry>();
  private static alias: Map<string, string> = new Map<string, string>();
  private static loadPromise: Promise<void> | null = null;

  /** 首次调用加载并建索引；重复调用复用同一 Promise，失败可重试 */
  static ensureLoaded(context: common.Context): Promise<void> {
    if (LocalDictService.entries.size > 0) {
      return Promise.resolve();
    }
    if (LocalDictService.loadPromise !== null) {
      return LocalDictService.loadPromise;
    }
    LocalDictService.loadPromise = LocalDictService.doLoad(context);
    return LocalDictService.loadPromise;
  }

  static isLoaded(): boolean {
    return LocalDictService.entries.size > 0;
  }

  private static async doLoad(context: common.Context): Promise<void> {
    try {
      const raw: Uint8Array =
        await context.resourceManager.getRawFileContent('dict/ecdict-lite.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const text: string = decoder.decodeWithStream(raw);
      const parsed: Object = JSON.parse(text);
      const book: RawDictBook = parsed as RawDictBook;
      if (book.words) {
        for (const item of book.words) {
          const key: string = item.w.trim().toLowerCase();
          if (key.length > 0 && !LocalDictService.entries.has(key)) {
            const entry: DictEntry = { phonetic: item.p, meaning: item.m };
            LocalDictService.entries.set(key, entry);
          }
        }
      }
      // 词形索引只存 key→原形字符串，不复制释义对象，省内存
      const aliasMap: Record<string, string> | undefined = book.alias;
      if (aliasMap !== undefined) {
        const names: string[] = Object.keys(aliasMap);
        for (const k of names) {
          const key: string = k.trim().toLowerCase();
          if (key.length > 0 && !LocalDictService.entries.has(key)) {
            LocalDictService.alias.set(key, aliasMap[k].trim().toLowerCase());
          }
        }
      }
      hilog.info(0x0000, TAG, 'lite dict loaded: %{public}d words, %{public}d aliases',
        LocalDictService.entries.size, LocalDictService.alias.size);
    } catch (e) {
      // 允许重试：清空 in-flight 标记
      LocalDictService.loadPromise = null;
      hilog.error(0x0000, TAG, 'lite dict load failed: %{public}s', (e as Error)?.message ?? '');
      throw new Error('离线词典加载失败');
    }
  }

  private static entryOf(key: string): DictEntry | null {
    const hit: DictEntry | undefined = LocalDictService.entries.get(key);
    return hit === undefined ? null : hit;
  }

  /** 查单词（忽略大小写），含词形索引与规则还原兜底；未收录返回 null */
  static lookup(word: string): DictEntry | null {
    const hit: DictHit | null = LocalDictService.lookupDetail(word);
    if (hit === null) {
      return null;
    }
    const out: DictEntry = { phonetic: hit.phonetic, meaning: hit.meaning };
    return out;
  }

  /**
   * 查单词并带上命中路径，供 UI 提示「此释义来自原形 X」。
   * L1 直接命中 → L2 词形索引 → L3 规则还原，任一级命中立即返回。
   */
  static lookupDetail(word: string): DictHit | null {
    const key: string = word.trim().toLowerCase();
    if (key.length === 0) {
      return null;
    }
    // L1：本身在词典里
    const direct: DictEntry | null = LocalDictService.entryOf(key);
    if (direct !== null) {
      return { phonetic: direct.phonetic, meaning: direct.meaning, matchedWord: key, viaLemma: false };
    }
    // L2：词形索引（ECDICT exchange 生成，覆盖 shattered / gets / done ...）
    const base: string | undefined = LocalDictService.alias.get(key);
    if (base !== undefined) {
      const e: DictEntry | null = LocalDictService.entryOf(base);
      if (e !== null) {
        return { phonetic: e.phonetic, meaning: e.meaning, matchedWord: base, viaLemma: true };
      }
    }
    // L3：规则还原（索引没覆盖的新造词 / 拼写变体）
    const cands: string[] = lemmaCandidates(key);
    for (const c of cands) {
      const e: DictEntry | null = LocalDictService.entryOf(c);
      if (e !== null) {
        return { phonetic: e.phonetic, meaning: e.meaning, matchedWord: c, viaLemma: true };
      }
      const b: string | undefined = LocalDictService.alias.get(c);
      if (b !== undefined) {
        const e2: DictEntry | null = LocalDictService.entryOf(b);
        if (e2 !== null) {
          return { phonetic: e2.phonetic, meaning: e2.meaning, matchedWord: b, viaLemma: true };
        }
      }
    }
    return null;
  }

  /** 词典收录的原形词条数（不含词形索引） */
  static wordCount(): number {
    return LocalDictService.entries.size;
  }

  /** 词形索引条数 */
  static aliasCount(): number {
    return LocalDictService.alias.size;
  }
}
