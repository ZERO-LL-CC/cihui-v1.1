/**
 * F8 语音快过 · 中文识别结果与释义匹配（纯逻辑，可 Node 单测）。
 *
 * 设计口径（对齐 F8 卡）：
 * - 只记中文意思：用户看英文、口述中文，ASR 语言 zh-CN；
 * - 词性全隔离：词库里 n./v./a./ad./vt./adj. 与「名词/动词/形容词」等标注
 *   出现在释义任意位置都不参与比对（旧实现只剥行首，`；vt. 使` 这类会残留）；
 * - 领域标签 [计][经][医] 删除，但正文里的补字括号（腹[部]）要去括号留字，
 *   否则「腹[部]」被整段删掉只剩「腹」，说「腹部」永远不通过；
 * - 多义词按义项拆分，命中任一核心义项即「认识」；
 * - 不做单字容错：说错一个字就是不通过（「阴密的」≠「精密的」），
 *   释义录错由 MeaningFix 修，判定标准不放宽；
 * - 严格度三档读 settings.asrStrictness：
 *   LEN 宽松：命中任一义项，或说出某义项前两字（容忍尾字丢失/口语化）；
 *   MID 标准：必须说出任一完整义项（允许省略「的/地/得」尾缀）；
 *   STRICT 严格：必须命中该词标注的第一个义项；
 * - 静音、空结果、低置信（本端引擎结果无置信度字段，由调用方按空串判定）不自动过词。
 */
import type { Verdict } from './Types';

export type Strictness = 'LEN' | 'MID' | 'STRICT';

export interface MatchResult {
  known: boolean;
  matched: string;
}

/**
 * 英文词性缩写：必须带点（n. / a. / vt.），且左侧不是字母，才能保证不会误伤英文单词。
 * 词库真实写法是 a. / ad.（不是 adj./adv.），三种都要认。
 */
const POS_EN: RegExp =
  /(^|[^a-z])(?:vt|vi|aux|adj|adv|ad|abbr|art|prep|conj|pron|num|pl|int|n|v|a)\.\s*/gi;
/** 中文词性：只在串首连续剥离，避免误伤「名词性」这类正文 */
const POS_ZH: RegExp =
  /^(?:及物动词|不及物动词|形容词|副词|介词|连词|代词|数词|冠词|感叹词|助动词|量词|名词|动词)\s*/;
/** 领域标签：紧贴行首或分隔符之后的方括号整段删除（保留分隔符） */
const TAG_SQUARE: RegExp = /(^|[\s,，;；、\/|。])[\[［][^\]］]*[\]］]/g;
/** 正文补字：夹在正文中的方括号只去括号保留内容（腹[部] → 腹部） */
const INLINE_SQUARE: RegExp = /[\[［]([^\]］]*)[\]］]/g;
const PAREN: RegExp = /[（(][^）)]*[）)]/g;
const SPLIT: RegExp = /[；;，,、\/|。]/;
const KEEP: RegExp = /[a-z0-9\u4e00-\u9fa5]/g;
/** 形容词/副词尾缀：口述省略「的/地/得」也算说出（能干的 ← 能干） */
const SUFFIX: RegExp = /[的地得]$/;
/** 单字义项（使…、打…）不参与「前两字」放宽，否则半个词就能过 */
const MIN_STEM: number = 3;

/** 反复替换直到稳定：处理 `n.&vt.`、`n. a.` 这种连写词性 */
function replaceUntilStable(input: string, re: RegExp, to: string): string {
  let cur: string = input;
  for (let i: number = 0; i < 8; i++) {
    const next: string = cur.replace(re, to);
    if (next === cur) {
      return cur;
    }
    cur = next;
  }
  return cur;
}

/** 单个释义串归一：去领域标签（保留补字）、括号补充、词性、标点空白
 *  @param keepZhPos 保留中文词性名——释义本身就是词性名时（adverb = n. 副词）必须有这层兜底，
 *                   否则会被自己的隔离规则抹成空串
 */
export function normalizeMeaning(raw: string, keepZhPos: boolean = false): string {
  let s: string = raw.trim();
  s = s.replace(PAREN, ' ');
  s = replaceUntilStable(s, TAG_SQUARE, '$1');
  s = replaceUntilStable(s, INLINE_SQUARE, '$1');
  // 左侧补一个非字母位，让串首的 `vt.` 也能命中「左侧不是字母」这条
  s = replaceUntilStable(' ' + s, POS_EN, '$1');
  // 补位留下的前导空格要先清掉，否则中文词性的 `^` 锚点匹配不到
  if (!keepZhPos) {
    s = replaceUntilStable(s.trim(), POS_ZH, '');
  }
  s = s.toLowerCase();
  // 中文释义里混进来的拉丁字母/阿拉伯数字，都是 OCR 残渣（adj)→ladi、代表n)、竞争(1→竞争1），
  // 留着会把义项污染成「精精密的ladi」，用户说「精密的」永远匹配不上。
  // 纯英文义项（DNA / CPU 这类缩写词）没有中文字，不受影响。
  if (/[\u4e00-\u9fa5]/.test(s)) {
    s = s.replace(/[a-z0-9]/g, '');
  }
  const kept: RegExpMatchArray | null = s.match(KEEP);
  return kept === null ? '' : kept.join('');
}

/** 把词的多个释义字段拆成有序义项（保留顺序，STRICT 用第 0 个） */
export function splitMeanings(meanings: string[]): string[] {
  const out: string[] = [];
  const push = (norm: string): void => {
    if (norm.length > 0 && out.indexOf(norm) < 0) {
      out.push(norm);
    }
  };
  meanings.forEach((entry: string): void => {
    entry.split(SPLIT).forEach((piece: string): void => {
      const norm: string = normalizeMeaning(piece);
      if (norm.length > 0) {
        push(norm);
        return;
      }
      // 「n. 副词」这种释义本身就是词性名，隔离后为空 —— 回退保留中文词性名
      push(normalizeMeaning(piece, true));
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

/** 口述里夹着「名词」「形容词」这类词性词时先摘掉，避免用户复述题型反而蒙过 */
export function stripSpokenPos(raw: string): string {
  let s: string = raw;
  for (let i: number = 0; i < 4; i++) {
    const next: string = s.replace(
      /(及物动词|不及物动词|形容词|副词|介词|连词|代词|数词|冠词|感叹词|助动词|量词|名词|动词)/g,
      '',
    );
    if (next === s) {
      return s;
    }
    s = next;
  }
  return s;
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
  let spoken: string = normalizeSpoken(spokenText);
  if (spoken.length === 0) {
    return { known: false, matched: '' };
  }
  const senses: string[] = splitMeanings(meanings);
  if (senses.length === 0) {
    return { known: false, matched: '' };
  }

  // 只说了「名词」「形容词」这类词性词，不算说出释义；
  // 但该词释义本身就是词性名时（adverb → 副词）要放行，否则永远过不了。
  const noPos: string = stripSpokenPos(spoken);
  if (noPos.length === 0) {
    const self: boolean = senses.indexOf(spoken) >= 0;
    return { known: self, matched: self ? spoken : '' };
  }
  spoken = noPos;

  /** 连续重复字折叠：释义被录成「精精密的」时，用户说「精密的」也该认 */
  const collapse = (s: string): string => s.replace(/(.)\1+/g, '$1');
  const spokenFolded: string = collapse(spoken);

  const hit = (sense: string): boolean => {
    if (spoken.indexOf(sense) >= 0) {
      return true;
    }
    const folded: string = collapse(sense);
    return folded !== sense && folded.length >= 2 && spokenFolded.indexOf(folded) >= 0;
  };
  /**
   * 完整命中，或省略「的/地/得」尾缀后命中。
   *
   * 这里**不做**单字容错（曾经的 withinOneEdit）。「阴密的」和「精密的」只差一个字，
   * 但那是一个完全不同的词——放过它等于教用户把错记进脑子。ASR 听错应由
   * MeaningFix 把释义洗对、把提示给足，而不是把判定标准放宽。
   */
  const hitLoose = (sense: string): boolean => {
    if (hit(sense)) {
      return true;
    }
    if (sense.length >= MIN_STEM && SUFFIX.test(sense)) {
      return hit(sense.substring(0, sense.length - 1));
    }
    return false;
  };

  if (strictness === 'STRICT') {
    const first: string = senses[0];
    const ok: boolean = hitLoose(first);
    return { known: ok, matched: ok ? first : '' };
  }

  if (strictness === 'MID') {
    for (const sense of senses) {
      if (hitLoose(sense)) {
        return { known: true, matched: sense };
      }
    }
    return { known: false, matched: '' };
  }

  // LEN：MID 口径之上，再容忍只说出义项前两字（尾字丢失/近音截断）
  for (const sense of senses) {
    if (hitLoose(sense)) {
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
