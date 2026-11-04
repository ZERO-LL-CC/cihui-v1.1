/**
 * 离线例句库（词书懒加载）
 *
 * 每本词书一个 `rawfile/examples/<cloudBookId>.json`，只在用到该词书时才读，
 * 切词书才换文件；内存里最多同时留 MAX_BOOKS 本（LRU 淘汰），
 * 所以常驻内存是「当前一两本」的例句表（100~300KB），不是全库 36k 词。
 *
 * 不联网、不读用户数据、不参与调度；读不到就返回 null，页面按「暂无例句」处理。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import type { ExampleEntry } from '../model/ExampleCore';

interface RawExampleItem {
  w: string;
  e: string;
  z: string;
}

interface RawExampleBook {
  book: string;
  src: string;
  v: number;
  items: RawExampleItem[];
}

export class ExampleService {
  /** 同时缓存的词书数：上一本 + 当前本 + 通用包，够覆盖「刚切过去还想回看」的场景 */
  private static readonly MAX_BOOKS: number = 4;
  private static readonly DIR: string = 'examples';
  /** 通用包文件名：梗句本/自定义词本的词靠它兜底，常驻不被淘汰 */
  static readonly COMMON_KEY: string = 'common';
  private static inst: ExampleService = new ExampleService();

  static get INSTANCE(): ExampleService {
    return ExampleService.inst;
  }

  private ctx: common.Context | null = null;
  private cache: Map<string, Map<string, ExampleEntry>> = new Map<string, Map<string, ExampleEntry>>();
  /** 加载顺序，队首是最旧的，淘汰时从队首删 */
  private order: string[] = [];
  private inflight: Set<string> = new Set<string>();

  /** 首次加载时把 context 交进来即可（页面 getContext 拿得到），不需要改应用入口 */
  attachContext(context: common.Context): void {
    this.ctx = context;
  }

  isLoaded(bookKey: string): boolean {
    return this.cache.has(bookKey);
  }

  /** 保证这批词书都已读进内存；失败的跳过（不抛错，页面降级为「暂无例句」） */
  async ensure(bookKeys: string[], context: common.Context): Promise<void> {
    if (this.ctx === null) {
      this.ctx = context;
    }
    for (const key of bookKeys) {
      if (key.length === 0 || this.cache.has(key)) {
        continue;
      }
      await this.load(key);
    }
  }

  /** 取某词书里某词的例句；词书没加载或词没例句都返回 null */
  get(bookKey: string, word: string): ExampleEntry | null {
    if (bookKey.length === 0) {
      return null;
    }
    const map: Map<string, ExampleEntry> | undefined = this.cache.get(bookKey);
    if (map === undefined) {
      return null;
    }
    const hit: ExampleEntry | undefined = map.get(word.trim().toLowerCase());
    return hit !== undefined ? hit : null;
  }

  /**
   * 兜底：已加载的词书里任意一本有这个词就返回。
   * 梗句本 / 自定义词本没有 cloudBookId，借当前词书的同名例句一样能用。
   */
  getAny(word: string): ExampleEntry | null {
    const key: string = word.trim().toLowerCase();
    for (const map of this.cache.values()) {
      const hit: ExampleEntry | undefined = map.get(key);
      if (hit !== undefined) {
        return hit;
      }
    }
    return null;
  }

  private async load(bookKey: string): Promise<void> {
    if (this.ctx === null || this.inflight.has(bookKey)) {
      return;
    }
    this.inflight.add(bookKey);
    try {
      const raw: Uint8Array =
        await this.ctx.resourceManager.getRawFileContent(`${ExampleService.DIR}/${bookKey}.json`);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const text: string = decoder.decodeWithStream(raw);
      const parsed: RawExampleBook = JSON.parse(text) as RawExampleBook;
      const map: Map<string, ExampleEntry> = new Map<string, ExampleEntry>();
      const items: RawExampleItem[] = parsed.items !== undefined ? parsed.items : [];
      items.forEach((it: RawExampleItem): void => {
        map.set(it.w.trim().toLowerCase(), { en: it.e, zh: it.z });
      });
      this.cache.set(bookKey, map);
      this.order.push(bookKey);
      this.evict();
      hilog.info(0x0000, 'CihuiExample', 'loaded %{public}s, %{public}d items', bookKey, map.size);
    } catch (e) {
      hilog.warn(0x0000, 'CihuiExample', 'load %{public}s failed: %{public}s',
        bookKey, (e as Error)?.message ?? 'unknown');
    } finally {
      this.inflight.delete(bookKey);
    }
  }

  private evict(): void {
    while (this.order.length > ExampleService.MAX_BOOKS) {
      let idx: number = 0;
      // 通用包不淘汰，否则梗句本的词会连着掉两轮
      while (idx < this.order.length && this.order[idx] === ExampleService.COMMON_KEY) {
        idx++;
      }
      if (idx >= this.order.length) {
        return;
      }
      const old: string = this.order[idx];
      this.order.splice(idx, 1);
      this.cache.delete(old);
    }
  }
}
