/**
 * 离线例句纯函数层（可 Node 单测，不依赖 ArkUI / 网络）
 *
 * 数据来源：`tools/examples/build_examples.py` 从 Tatoeba 中英句对 + AI 补生成
 * 构建出的 `rawfile/examples/<bookId>.json`，一词一条。
 * 本文件只做「取到的例句 -> 页面要的 PassageResult」这一层拼装，
 * 不做 IO、不改调度数据（例句不参与艾宾浩斯）。
 */
import type { Word } from './Types';
import type { PassageResult, PassageSentence } from './SentenceCore';

/** 一条例句：英文 + 中文 */
export interface ExampleEntry {
  en: string;
  zh: string;
}

/**
 * 逐词拼装成页面用的 PassageResult：一条句子 = 一个词的一条例句。
 * 缺例句的词进 missedWords（页面显示「暂无例句」），不影响其它词。
 */
export function buildWordPassage(
  words: Word[],
  fetch: (w: Word) => ExampleEntry | null
): PassageResult {
  const sentences: PassageSentence[] = [];
  const covered: string[] = [];
  const missed: string[] = [];
  words.forEach((w: Word): void => {
    const key: string = w.english.trim().toLowerCase();
    if (key.length === 0) {
      return;
    }
    const hit: ExampleEntry | null = fetch(w);
    if (hit === null || hit.en.trim().length === 0 || hit.zh.trim().length === 0) {
      missed.push(key);
      return;
    }
    sentences.push({
      sentence: hit.en.trim(),
      translation: hit.zh.trim(),
      words: [key],
    });
    covered.push(key);
  });
  const total: number = covered.length + missed.length;
  const coverage: number = total === 0 ? 0 : Math.round((covered.length / total) * 100) / 100;
  return {
    title: '',
    sentences: sentences,
    coveredWords: covered,
    missedWords: missed,
    coverage: coverage,
  };
}
