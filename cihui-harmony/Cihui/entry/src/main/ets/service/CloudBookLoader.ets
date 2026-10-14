/**
 * 云词书内容加载（真实词库）：
 * 词书 JSON 随包放在 resources/rawfile/cloudbooks/<id>.json，
 * 由开源 ECDICT（MIT，skywind3000/ECDICT）按考纲标签筛选生成，
 * 构建脚本见仓库外 _ecdict/generate_books.py。
 *
 * 「下载导入」在无后端阶段即从 rawfile 读取并落库（本地导入，不产生网络流量），
 * 将来接入服务端后，把 loadBook 换成带进度回调的网络请求即可，调用方不变。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import type { CloudSampleWord } from './CloudCatalog';

interface RawCloudWord {
  w: string;
  p: string;
  m: string;
}

interface RawCloudBook {
  words: RawCloudWord[];
}

export class CloudBookLoader {
  private static context: common.Context | null = null;

  static attachContext(context: common.Context): void {
    CloudBookLoader.context = context;
  }

  /** 读取整本词书；失败抛错由调用方进入失败态（不产生半截数据） */
  static async loadBook(bookId: string): Promise<CloudSampleWord[]> {
    if (CloudBookLoader.context === null) {
      throw new Error('词书模块未初始化');
    }
    const raw: Uint8Array =
      await CloudBookLoader.context.resourceManager.getRawFileContent(`cloudbooks/${bookId}.json`);
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    const text: string = decoder.decodeWithStream(raw);
    const parsed: Object = JSON.parse(text);
    const book: RawCloudBook = parsed as RawCloudBook;
    const out: CloudSampleWord[] = [];
    if (book.words) {
      for (const item of book.words) {
        out.push({ english: item.w, phonetic: item.p, meaning: item.m });
      }
    }
    return out;
  }
}
