/**
 * 释义清洗与校正的落地层（把纯逻辑接到离线词库上）。
 *
 * 纯变换在 model/MeaningFix.ts（可 Node 单测），这里只负责查词库 + 打日志。
 * 判定标准不放宽（说错一个字就是不过），要治的是释义本身录坏：
 *   差 1 字  → 直接改（该词词库里就有这个义项，百分百录坏）
 *   差 2~3 字 → 给建议，用户在语音页一键替换
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalDictService } from './LocalDictService';
import type { DictEntry } from './LocalDictService';
import { auditMeaningsInData, cleanMeaningsInData, fixMeanings } from '../model/MeaningFix';
import type { MeaningFixResult, MeaningLookup } from '../model/MeaningFix';
import type { AppData } from '../model/RepoCore';

const TAG: string = 'CihuiMeaningFix';

export class MeaningFixService {
  /** 词库是否已就绪（未就绪只有清洗能力，没有校正能力） */
  static available(): boolean {
    return LocalDictService.isLoaded();
  }

  /** 词库查询回调；未加载返回 null */
  private static lookup(): MeaningLookup | null {
    if (!LocalDictService.isLoaded()) {
      return null;
    }
    return (english: string): string | null => {
      const hit: DictEntry | null = LocalDictService.lookup(english);
      return hit === null ? null : hit.meaning;
    };
  }

  /** 单个词的校正结果；词库未加载返回 null（调用方退回「只亮释义」） */
  static fixOne(english: string, meanings: string[]): MeaningFixResult | null {
    if (!LocalDictService.isLoaded()) {
      return null;
    }
    const hit: DictEntry | null = LocalDictService.lookup(english);
    return fixMeanings(meanings, hit === null ? null : hit.meaning);
  }

  /** 只清洗：去词性、领域标签、OCR 残渣、孤立括号。无变更返回 null */
  static cleanAll(data: AppData): AppData | null {
    const next: AppData | null = cleanMeaningsInData(data);
    if (next !== null) {
      hilog.info(0x0000, TAG, 'clean done');
    }
    return next;
  }

  /** 清洗 + 词库自动纠正（差 1 字改写、差 2~3 字记 ASK）。无变更返回 null */
  static auditAll(data: AppData): AppData | null {
    const next: AppData | null = auditMeaningsInData(data, MeaningFixService.lookup());
    if (next !== null) {
      hilog.info(0x0000, TAG, 'audit done');
    }
    return next;
  }
}
