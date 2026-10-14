/**
 * F8 语音快过 · 中文识别结果与释义匹配（纯逻辑，可 Node 单测）。
 *
 * 设计口径（对齐 F8 卡）：
 * - 只记中文意思：用户看英文、口述中文，ASR 语言 zh-CN；
 * - 归一化：去词性（n./v./adj. 与中文词性）、标点、空白、括号补充；
 * - 多义词按义项拆分，命中任一核心义项即「认识」；
 * - 严格度三档读 settings.asrStrictness：
 *   LEN 宽松：命中任一义项，或说出某义项前两字（容忍尾字丢失/口语化）；
 *   MID 标准：必须说出任一完整义项；
 *   STRICT 严格：必须命中该词标注的第一个义项；
 * - 静音、空结果、低置信（本端引擎结果无置信度字段，由调用方按空串判定）不自动过词。
 */
import type { Verdict } from './Types';

export type Strictness = 'LEN' | 'MID' | 'STRICT';

export interface MatchResult {
  known: boolean;
  matched: string;
}

const POS_EN: RegExp = /^(?:vt|vi|aux|n|v|adj|adv|prep|conj|pron|num|art|int|abbr)\.\s*/i;
const POS_ZH: RegExp =
  /^(?:及物动词|不及物动词|名词|动词|形容词|副词|介词|连词|代词|数词|冠词|感叹词|助动词|量词)\s*/;
const SPLIT: RegExp = /[；;；,、\/|]|\s+\/\s+/;
const PAREN: RegExp = /[（(][^）)]*[）)]/g;
const KEEP: RegExp = /[a-z0-9\u4e00-\u9fa5]/g;

/** 单个释义串归一：去括号补充、去词性、去标点空白 */
export function normalizeMeaning(raw: string): string {
  let s: string = raw.trim();
  s = s.replace(PAREN, '');
  s = s.replace(POS_EN, '');
  s = s.replace(POS_ZH, '');
  s = s.toLowerCase();
  const kept: RegExpMatchArray | null = s.match(KEEP);
  s = kept === null ? '' : kept.join('');
  return s;
}

/** 把词的多个释义字段拆成有序义项（保留顺序，STRICT 用第 0 个） */
export function splitMeanings(meanings: string[]): string[] {
  const out: string[] = [];
  meanings.forEach((entry: string): void => {
    entry.split(SPLIT).forEach((piece: string): void => {
      const norm: string = normalizeMeaning(piece);
      if (norm.length > 0 && out.indexOf(norm) < 0) {
        out.push(norm);
      }
    });
  });
  return out;
}

/** 口述识别结果归一：全角转半角、小写、只留中英数字（去标点/停顿词周围空白） */
export function normalizeSpoken(raw: string): string {
  let s: string = raw;
  // 全角 ASCII → 半角
  s = s.replace(/[\uFF01-\uFF5E]/g, (ch: string): string =>
    String.fromCharCode(ch.charCodeAt(0) - 0xFEE0));
  s = s.replace(/\u3000/g, ' ').toLowerCase();
  const kept: RegExpMatchArray | null = s.match(KEEP);
  return kept === null ? '' : kept.join('');
}

/**
 * 判定口述是否命中释义。
 * @param spokenText ASR 最终文本
 * @param meanings    单词原始释义数组
 * @param strictness  LEN/MID/STRICT
 */
export function matchSpoken(
  spokenText: string,
  meanings: string[],
  strictness: Strictness,
): MatchResult {
  const spoken: string = normalizeSpoken(spokenText);
  if (spoken.length === 0) {
    return { known: false, matched: '' };
  }
  const senses: string[] = splitMeanings(meanings);
  if (senses.length === 0) {
    return { known: false, matched: '' };
  }

  const hit = (sense: string): boolean => spoken.indexOf(sense) >= 0;

  if (strictness === 'STRICT') {
    const first: string = senses[0];
    return { known: hit(first), matched: hit(first) ? first : '' };
  }

  if (strictness === 'MID') {
    for (const sense of senses) {
      if (hit(sense)) {
        return { known: true, matched: sense };
      }
    }
    return { known: false, matched: '' };
  }

  // LEN：完整命中，或义项 ≥2 字时命中前两字（容忍尾字丢失/近音截断）
  for (const sense of senses) {
    if (hit(sense)) {
      return { known: true, matched: sense };
    }
    if (sense.length >= 2 && spoken.indexOf(sense.substring(0, 2)) >= 0) {
      return { known: true, matched: sense };
    }
  }
  return { known: false, matched: '' };
}

/** 供页面把匹配结果转成判定（只有「认识」由语音给出，模糊/不认识走手动） */
export function verdictFromMatch(known: boolean): Verdict | null {
  return known ? 'KNOWN' : null;
}
