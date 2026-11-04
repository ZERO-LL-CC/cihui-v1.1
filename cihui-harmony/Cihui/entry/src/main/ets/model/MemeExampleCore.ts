/**
 * 梗句兜底例句（纯函数，可单测）
 *
 * 用户从梗句导入的词往往不在词书里，预置例句库覆盖不到；
 * 但梗句本身就是最好的语境——直接拿含这个词的那句梗句当例句，中英都有。
 * 不联网、不参与调度，页面取不到预置例句时才走到这里。
 */
import type { MemeSentence } from './Types';
import type { ExampleEntry } from './ExampleCore';
import { lemmaCandidates } from './LemmaCore';

/** 句中的一个 token 是否就是这个词（含时态/复数等变形） */
export function tokenMatchesWord(token: string, key: string): boolean {
  const t: string = token.trim().toLowerCase();
  if (t.length === 0) {
    return false;
  }
  if (t === key) {
    return true;
  }
  return lemmaCandidates(t).indexOf(key) >= 0;
}

/** 英文句里是否出现该词（短语按整段子串匹配） */
export function sentenceHasWord(english: string, word: string): boolean {
  const key: string = word.trim().toLowerCase();
  if (key.length === 0) {
    return false;
  }
  const low: string = english.toLowerCase();
  if (key.indexOf(' ') >= 0) {
    return low.indexOf(key) >= 0;
  }
  const tokens: string[] = low.split(/[^a-z'-]+/);
  for (let i = 0; i < tokens.length; i++) {
    if (tokenMatchesWord(tokens[i], key)) {
      return true;
    }
  }
  return false;
}

/**
 * 从用户导入的梗句里挑一条含该词的当例句：同分取更短的句子（语境更集中）。
 * 找不到返回 null，页面照旧显示「暂无例句」。
 */
export function findMemeExample(word: string, memes: MemeSentence[]): ExampleEntry | null {
  let best: ExampleEntry | null = null;
  let bestLen: number = 0;
  for (let i = 0; i < memes.length; i++) {
    const m: MemeSentence = memes[i];
    const en: string = m.english.trim();
    const zh: string = m.chinese.trim();
    if (en.length === 0 || zh.length === 0) {
      continue;
    }
    if (!sentenceHasWord(en, word)) {
      continue;
    }
    if (best === null || en.length < bestLen) {
      best = { en: en, zh: zh };
      bestLen = en.length;
    }
  }
  return best;
}
