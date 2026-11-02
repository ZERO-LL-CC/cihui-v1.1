/**
 * 释义清洗与校正（纯逻辑，可 Node 单测）。
 *
 * 为什么要有这一层：
 * 拍照 OCR / 手动录入进来的中文释义脏得离谱——`精精密的ladi`、`代表n)`、`竞争(1`、
 * `各种名样的lad))`。匹配层做「错一个字也放过」是错的方向：用户说错一个字就算过，
 * 等于让他把错记进脑子。正确做法是把释义本身修对：
 *
 *   1) 清洗：剥词性、剥领域标签、剥 OCR 残渣（拉丁字母/数字）、折叠重复字；
 *   2) 校正：拿英文去离线词库取标准中文，按编辑距离算相似度；
 *      - ≥90% 相似 → 百分百是录坏了，直接换成词库原文（AUTO）；
 *      - 45%~90%  → 大概率录错，给建议让用户一键替换（ASK）；
 *      - <45%     → 用户的词库里没有近似义项（自建释义/生词），不动（KEEP）。
 *
 * 匹配层因此回归严格：说错一个字就是不过，然后由这里把释义修对，而不是放宽判定。
 */
import { normalizeMeaning, splitMeanings } from './SpeechMatch';
import type { AppData } from './RepoCore';
import type { Word } from './Types';

export type FixAction = 'KEEP' | 'AUTO' | 'ASK';

/** 单条义项的校正结果 */
export interface SenseFix {
  /** 用户录入的原串 */
  raw: string;
  /** 清洗后可读的串（去残渣/折叠重复字） */
  cleaned: string;
  /** 词库标准义项；无则空串 */
  suggestion: string;
  /** 与建议的相似度 0~1 */
  score: number;
  action: FixAction;
}

/** 一个词的整条校正结论 */
export interface MeaningFixResult {
  senses: SenseFix[];
  /** 直接改正后的释义数组（AUTO 已替换、ASK 保留原值待确认） */
  fixed: string[];
  /** 有 AUTO 变更：需要写盘 */
  autoChanged: boolean;
  /** 需要用户确认的义项（ASK） */
  ask: SenseFix[];
  /** 词库是否命中该英文（未命中说明英文可能拼错，或词库没收录） */
  inDict: boolean;
  /** 整条释义都对不上词库时的建议（给 UI 一键替换用），无则空串 */
  suggestAll: string;
}

/**
 * 清洗成「人可读」的释义串：保留中文与必要标点，去掉所有噪声。
 * 与 normalizeMeaning 的区别：那个是给匹配用的纯字集，这个是给界面和写盘用的，
 * 所以要保留可读分隔，不能把多义项糊成一串。
 */
export function cleanForDisplay(raw: string): string {
  let s: string = raw.trim();
  // 括号补充：`控制(1)`、`给人切象深的(adi)` 里的（1）(adi) 都是 OCR 残渣
  s = s.replace(/[（(][^）)]*[）)]/g, ' ');
  // 领域标签整段删（[计][经][医]）；正文补字去括号留字（腹[部] → 腹部）
  let prev: string = '';
  for (let i: number = 0; i < 8 && prev !== s; i++) {
    prev = s;
    s = s.replace(/(^|[\s,，;；、\/|。])[\[［][^\]］]*[\]］]/g, '$1');
  }
  s = s.replace(/[\[［]([^\]］]*)[\]］]/g, '$1');
  // 英文词性：任意位置（`；vt. 使`、`n.&vt.` 都要清），左侧非字母才认，避免误伤英文词
  prev = '';
  for (let i: number = 0; i < 8 && prev !== s; i++) {
    prev = s;
    s = s.replace(
      /(^|[^a-z])(?:vt|vi|aux|adj|adv|ad|abbr|art|prep|conj|pron|num|pl|int|n|v|a)\.\s*/gi, '$1');
  }
  // 中文词性前缀
  s = s.replace(
    /^(?:及物动词|不及物动词|形容词|副词|介词|连词|代词|数词|冠词|感叹词|助动词|量词|名词|动词)\s*/, '');
  // 连写词性 `n.&vt.` 剥完会剩一个 `&`，它是词性分隔符不是释义内容
  s = s.replace(/&/g, ' ');
  // 中文释义里混进的拉丁字母/数字：全是 OCR 残渣（adj)→ladi、代表n)→代表n）。
  // 纯英文释义（DNA、CPU）没有汉字，不动。
  if (/[\u4e00-\u9fa5]/.test(s)) {
    s = s.replace(/[a-z0-9]/gi, '');
  }
  // 尖括号/方头括号里的标签：`<法>运动队`、`【医】腹部` 都要删标签
  s = s.replace(/<[^>]*>/g, ' ').replace(/【[^】]*】/g, ' ');
  // 孤立括号：`代表n)` 去字母后剩 `代表)`，`竞争(1` 剩 `竞争(`，都要清掉
  s = s.replace(/[()（）\[\]［］{}｛｝]/g, '');
  // 收口：去掉首尾与重复的标点空白
  s = s.replace(/^[\s,，;；、\/|。.·:：\-—]+/, '').replace(/[\s,，;；、\/|。.·:：\-—]+$/, '');
  s = s.replace(/[\s,，;；、\/|。.·]{2,}/g, '，');
  // 注意：这里**不折叠**连续重复字。「精精密的」要原样展示给用户看，
  // 让他知道是自己录入多了个「精」；折叠只在匹配侧做（说「精密的」也能过）。
  return s;
}

/** 编辑距离（短串 DP，释义长度基本 <20 字，开销可忽略） */
export function levenshtein(a: string, b: string): number {
  const la: number = a.length;
  const lb: number = b.length;
  if (la === 0) {
    return lb;
  }
  if (lb === 0) {
    return la;
  }
  let prevRow: number[] = [];
  for (let j: number = 0; j <= lb; j++) {
    prevRow.push(j);
  }
  let curRow: number[] = [];
  for (let i: number = 1; i <= la; i++) {
    curRow = [i];
    for (let j: number = 1; j <= lb; j++) {
      const cost: number = a.charCodeAt(i - 1) === b.charCodeAt(j - 1) ? 0 : 1;
      const del: number = (prevRow[j] as number) + 1;
      const ins: number = (curRow[j - 1] as number) + 1;
      const sub: number = (prevRow[j - 1] as number) + cost;
      let m: number = del < ins ? del : ins;
      if (sub < m) {
        m = sub;
      }
      curRow.push(m);
    }
    prevRow = curRow;
  }
  return prevRow[lb] as number;
}

/** 归一化相似度 0~1（1 = 完全相同） */
export function similarity(a: string, b: string): number {
  const la: number = a.length;
  const lb: number = b.length;
  if (la === 0 || lb === 0) {
    return 0;
  }
  const max: number = la > lb ? la : lb;
  return 1 - levenshtein(a, b) / max;
}

/**
 * 校正一个词的整条释义。
 * @param meanings     用户录入的释义数组
 * @param dictMeaning  离线词库的原始释义串（如 `a. 精确的, 严谨的, 明确的；[机] 精密的`）
 *                     null 表示词库没收录
 */
export function fixMeanings(meanings: string[], dictMeaning: string | null): MeaningFixResult {
  const senses: SenseFix[] = [];
  const dictSenses: string[] = dictMeaning === null ? [] : splitMeanings([dictMeaning]);
  const dictVisible: string[] =
    dictMeaning === null ? [] : dictMeaning.split(/[；;]/).map((x: string): string => cleanForDisplay(x));

  meanings.forEach((raw: string): void => {
    const cleaned: string = cleanForDisplay(raw);
    const normClean: string = normalizeMeaning(cleaned);
    // 空白/纯符号义项：清洗后没内容，原样保留（由上层判 missingMeaning）
    if (normClean.length === 0) {
      senses.push({ raw, cleaned: cleaned, suggestion: '', score: 0, action: 'KEEP' });
      return;
    }
    // 用户常把多个义项写在一个字段里（`赝品,模仿`）。整串比较会把本来正确的释义判成
    // 「差几个字」，所以先按分隔符拆开，每个片段各自找最佳匹配，取最好的那一个作为结论。
    const parts: string[] = cleaned
      .split(/[；;，,、\/|。]/)
      .map((x: string): string => normalizeMeaning(x))
      .filter((x: string): boolean => x.length > 0);
    const probes: string[] = parts.length > 0 ? parts : [normClean];
    let best: string = '';
    let bestScore: number = 0;
    for (const probe of probes) {
      for (const ds of dictSenses) {
        const sc: number = similarity(probe, ds);
        if (sc > bestScore) {
          bestScore = sc;
          best = ds;
        }
      }
      // 有一个片段与词库原文完全一致，整条就是对的，不用再往下比
      if (bestScore >= 0.999) {
        break;
      }
    }
    // 建议直接用归一后的纯字串：可读串里常带 `<法>`、`在，下方` 这类噪声
    const bestVisible: string = best;
    let action: FixAction = 'KEEP';
    if (bestScore >= 0.999) {
      action = 'KEEP'; // 已经是词库原文，只是带脏尾巴，属清洗范畴
    } else {
      // 用最接近的那个片段算距离，避免「赝品,模仿」这类多个义项叠在一个字段里的误判
      let probeBest: string = normClean;
      let probeScore: number = 0;
      for (const probe of probes) {
        const sc: number = similarity(probe, best);
        if (sc > probeScore) {
          probeScore = sc;
          probeBest = probe;
        }
      }
      const dist: number = levenshtein(probeBest, best);
      const len: number = probeBest.length > best.length ? probeBest.length : best.length;
      if (dist <= 1 && len >= 3) {
        // 三个字以上只差一个字：该词词库里就有这个义项，百分百是录入/OCR 坏了，直接改
        action = 'AUTO';
      } else if (dist <= 3 && len >= 3) {
        // 差两三个字：大概率录错，但可能是同义改写，交给用户一键确认
        action = 'ASK';
      } else if (dist <= 1 && len === 2 && probeBest.length >= 2) {
        // 两字义项只差一字（腹部↔腹部）容易误判，只提示不自动改
        action = 'ASK';
      }
    }
    senses.push({
      raw,
      cleaned,
      suggestion: action === 'KEEP' ? cleaned : bestVisible,
      score: bestScore,
      action,
    });
  });

  const fixed: string[] = [];
  let autoChanged: boolean = false;
  const ask: SenseFix[] = [];
  senses.forEach((s: SenseFix): void => {
    if (s.action === 'AUTO') {
      fixed.push(s.suggestion);
      if (s.suggestion !== s.raw) {
        autoChanged = true;
      }
      return;
    }
    fixed.push(s.cleaned.length > 0 ? s.cleaned : s.raw);
    if (s.cleaned !== s.raw) {
      autoChanged = true; // 清洗也算改动
    }
    if (s.action === 'ASK') {
      ask.push(s);
    }
  });

  // 整条都对不上词库：说明不是录错一两个字，而是整条释义是别人的/全错，
  // 这时候给「词库标准释义」让用户一键换，但不自动改（不确定就不动用户数据）。
  const inDict: boolean = dictSenses.length > 0;
  // 所有义项都跟词库「完全不像」（连一个字都对不上）→ 整条释义八成是别人的/全错
  const allOrphan: boolean = senses.length > 0 && ask.length === 0
    && senses.every((s: SenseFix): boolean => s.action === 'KEEP' && s.score < 0.999);
  let suggestAll: string = '';
  if (inDict && allOrphan) {
    suggestAll = dictVisible.filter((x: string): boolean => x.length > 0).slice(0, 2).join('；');
  }

  return {
    senses,
    fixed,
    autoChanged,
    ask,
    inDict,
    suggestAll,
  };
}

/* ================= 批量清洗（纯数据变换，可 Node 单测） ================= */

/** 查词库的回调：返回该词的标准释义串，未收录返回 null */
export type MeaningLookup = (english: string) => string | null;

/** 只清洗不动语义：去词性、领域标签、OCR 残渣、孤立括号。无变更返回 null */
export function cleanMeaningsInData(data: AppData): AppData | null {
  let changed: number = 0;
  const words: Word[] = data.words.map((w: Word): Word => {
    if (w.meanings.length === 0) {
      return w;
    }
    let touched: boolean = false;
    const next: string[] = w.meanings.map((m: string): string => {
      const c: string = cleanForDisplay(m);
      if (c.length === 0 || c === m) {
        return m;
      }
      touched = true;
      return c;
    });
    if (!touched) {
      return w;
    }
    changed += 1;
    const merged: Word = { ...w };
    merged.meanings = next;
    merged.missingMeaning = next.length === 0;
    return merged;
  });
  if (changed === 0) {
    return null;
  }
  const out: AppData = { ...data };
  out.words = words;
  return out;
}

/** 清洗 + 词库校正结果（给上层打日志 / 统计用） */
export interface AuditSummary {
  data: AppData;
  cleaned: number;
  autoFixed: number;
  /** 需要用户确认的「英文: 原释义 → 建议」 */
  asks: string[];
}

/**
 * 清洗 + 词库自动纠正。
 * 只自动改「差 1 字」的（该词词库里就有这个义项，百分百录坏）；
 * 差 2~3 字的只记录，交给用户在语音页一键替换。
 * 用户自己补录过释义（diySupplement）的词不自动改，只清洗。
 * 无任何变更返回 null。
 */
export function auditMeaningsInData(data: AppData, lookup: MeaningLookup | null): AppData | null {
  if (lookup === null) {
    return cleanMeaningsInData(data);
  }
  let cleaned: number = 0;
  let autoFixed: number = 0;
  const asks: string[] = [];
  const words: Word[] = data.words.map((w: Word): Word => {
    if (w.meanings.length === 0) {
      return w;
    }
    const cleanList: string[] = w.meanings.map((m: string): string => {
      const c: string = cleanForDisplay(m);
      return c.length === 0 ? m : c;
    });
    let next: string[] = cleanList;
    if (!w.diySupplement) {
      const r: MeaningFixResult = fixMeanings(cleanList, lookup(w.english));
      next = r.fixed.map((m: string, i: number): string =>
        m.length === 0 ? (cleanList[i] as string) : m);
      if (r.ask.length > 0) {
        const first: SenseFix = r.ask[0];
        asks.push(`${w.english}: ${first.cleaned} → ${first.suggestion}`);
      }
    }
    let same: boolean = next.length === w.meanings.length;
    if (same) {
      for (let i: number = 0; i < next.length; i++) {
        if (next[i] !== w.meanings[i]) {
          same = false;
          break;
        }
      }
    }
    if (same) {
      return w;
    }
    let isAuto: boolean = false;
    for (let i: number = 0; i < next.length; i++) {
      if (next[i] !== cleanList[i]) {
        isAuto = true;
        break;
      }
    }
    if (isAuto) {
      autoFixed += 1;
    } else {
      cleaned += 1;
    }
    const merged: Word = { ...w };
    merged.meanings = next;
    merged.missingMeaning = next.length === 0;
    return merged;
  });
  if (cleaned === 0 && autoFixed === 0) {
    return null;
  }
  const out: AppData = { ...data };
  out.words = words;
  return out;
}
