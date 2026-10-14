/**
 * 离线英汉词典（真机反馈 #25）：拍照 OCR 拆成单词气泡后，用它在本地自动填音标与中文，
 * 不依赖网络、不产生请求失败。数据随包放在 resources/rawfile/dict/ecdict-lite.json，
 * 由开源 ECDICT（MIT，skywind3000/ECDICT）合并五本考纲云书与高频词生成，
 * 构建脚本见仓库外 _ecdict/generate_lite_dict.py。
 *
 * 句子 / 短语翻译仍走在线大模型（TranslateService）；本服务只负责单词级释义。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'CihuiDict';

interface RawDictWord {
  w: string;
  p: string;
  m: string;
}

interface RawDictBook {
  words: RawDictWord[];
}

export interface DictEntry {
  phonetic: string;
  meaning: string;
}

export class LocalDictService {
  private static entries: Map<string, DictEntry> = new Map<string, DictEntry>();
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
      hilog.info(0x0000, TAG, 'lite dict loaded: %{public}d', LocalDictService.entries.size);
    } catch (e) {
      // 允许重试：清空 in-flight 标记
      LocalDictService.loadPromise = null;
      hilog.error(0x0000, TAG, 'lite dict load failed: %{public}s', (e as Error)?.message ?? '');
      throw new Error('离线词典加载失败');
    }
  }

  /** 查单词（忽略大小写）；未收录返回 null，由调用方留空手补或走在线翻译 */
  static lookup(word: string): DictEntry | null {
    const key: string = word.trim().toLowerCase();
    if (key.length === 0) {
      return null;
    }
    const hit: DictEntry | undefined = LocalDictService.entries.get(key);
    if (hit === undefined) {
      return null;
    }
    const out: DictEntry = { phonetic: hit.phonetic, meaning: hit.meaning };
    return out;
  }

  static wordCount(): number {
    return LocalDictService.entries.size;
  }
}
