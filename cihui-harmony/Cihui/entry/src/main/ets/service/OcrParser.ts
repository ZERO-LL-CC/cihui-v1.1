/**
 * OCR 行解析（F4，纯函数 .ts，可在 Node 下直接单测）：
 * 把 textRecognition 返回的原始文本行整理为「英文 + 音标 + 中文释义」候选行。
 * 典型词表行："apple  n. 苹果；苹果树"、"abandon /əˈbændən/ v. 放弃；抛弃"。
 * 解析不出中文的行保留为缺释义行，由校对页标橙并要求补录（只可手动闪卡、不进语音快过）。
 */

export interface OcrDraft {
  english: string;
  phonetic: string;
  meaning: string;
}

const CHINESE_RE: RegExp = /[\u4e00-\u9fff]/;
// 行首英文词条：单词/短语，允许撇号、连字符，最多 3 个单词；后续词不得是 n./v./adj. 等词性标记
const ENGLISH_HEAD_RE: RegExp =
  /^([A-Za-z][A-Za-z''\-]*(?:\s+(?!(?:n|v|adj|adv|prep|conj|pron|num|int|art|aux|vt|vi)\.)[A-Za-z][A-Za-z''\-]*){0,2})/;
const PHONETIC_RE: RegExp = /\s*[\/\[][^\/\[\]]{1,40}[\/\]]\s*/;
// 词性与序号前缀：n. v. adj. adv. prep. conj. pron. num. int. art. aux. 以及 1. ①
const POS_RE: RegExp = /^(?:(?:n|v|adj|adv|prep|conj|pron|num|int|art|aux|vt|vi)\.\s*|\d+[.、)]\s*|[①②③④⑤⑥⑦⑧⑨⑩]\s*)+/i;
// 独占一行的音标：/.../ 或 [...]
const PHONETIC_ONLY_RE: RegExp = /^[\/\[][^\/\[\]]{1,40}[\/\]]$/;
// 单元标题等噪声行：Unit 1 / List 2 / Lesson 3 / Part A / Section / Chapter
const HEADING_RE: RegExp = /^(?:unit|list|lesson|part|section|chapter)\b/i;

/** 解析多行（多张图按顺序拼接后的行集合），返回去重后的候选行 */
export function parseOcrLines(lines: string[]): OcrDraft[] {
  const drafts: OcrDraft[] = [];
  const indexByWord: Map<string, number> = new Map();

  for (const rawLine of lines) {
    const line: string = rawLine.trim().replace(/\s+/g, ' ');
    if (line.length === 0) {
      continue;
    }
    // 单元标题噪声行直接丢弃，避免被当成缺释义词条
    if (HEADING_RE.test(line)) {
      continue;
    }
    // 独占一行的音标：补到上一条词条
    const phOnly: RegExpMatchArray | null = line.match(PHONETIC_ONLY_RE);
    if (phOnly && drafts.length > 0) {
      const last0: OcrDraft = drafts[drafts.length - 1];
      if (last0.phonetic.length === 0) {
        last0.phonetic = line.replace(/[\[\]]/g, '/');
      }
      continue;
    }
    // 词性/序号开头且含中文的行（如 "adj. 有耐心的"、"n. 病人"）：是上一词条的续义
    if (POS_RE.test(line) && CHINESE_RE.test(line) && drafts.length > 0) {
      const last0: OcrDraft = drafts[drafts.length - 1];
      const extra0: string = line.replace(POS_RE, '').trim();
      if (extra0.length > 0 && last0.meaning.indexOf(extra0) < 0) {
        last0.meaning = last0.meaning.length > 0 ? last0.meaning + '；' + extra0 : extra0;
      }
      continue;
    }
    const headMatch: RegExpMatchArray | null = line.match(ENGLISH_HEAD_RE);
    if (!headMatch) {
      // 纯中文行：挂到上一条英文行作为补充释义
      if (CHINESE_RE.test(line) && drafts.length > 0) {
        const last: OcrDraft = drafts[drafts.length - 1];
        const extra: string = line.replace(POS_RE, '').trim();
        if (extra.length > 0) {
          last.meaning = last.meaning.length > 0 ? last.meaning + '；' + extra : extra;
        }
      }
      continue;
    }
    const english: string = headMatch[1].trim();
    let rest: string = line.substring(english.length).trim();
    let phonetic: string = '';
    const phMatch: RegExpMatchArray | null = rest.match(PHONETIC_RE);
    if (phMatch && phMatch.index !== undefined && phMatch.index < 12) {
      phonetic = phMatch[0].trim().replace(/[\[\]]/g, '/');
      rest = (rest.substring(0, phMatch.index) + ' ' + rest.substring(phMatch.index + phMatch[0].length)).trim();
    }
    rest = rest.replace(POS_RE, '').trim();
    const meaning: string = CHINESE_RE.test(rest) ? rest : '';

    const key: string = english.toLowerCase();
    const existIdx: number | undefined = indexByWord.get(key);
    if (existIdx !== undefined) {
      const exist: OcrDraft = drafts[existIdx];
      if (meaning.length > 0 && exist.meaning.indexOf(meaning) < 0) {
        exist.meaning = exist.meaning.length > 0 ? exist.meaning + '；' + meaning : meaning;
      }
      if (phonetic.length > 0 && exist.phonetic.length === 0) {
        exist.phonetic = phonetic;
      }
      continue;
    }
    indexByWord.set(key, drafts.length);
    drafts.push({ english, phonetic, meaning });
  }
  return drafts;
}

/** 词性裸词（OCR 把 "n." 的点切掉后剩 n / adj）与常见缩写：单词气泡里不当成要学的词 */
const POS_BARE_RE: RegExp =
  /^(?:n|v|vt|vi|adj|adv|prep|conj|pron|num|int|art|aux|sth|sb|etc|eg|ie|vs|pm|am)$/i;
/** 高频功能词：例句 / 题干里大量出现，通常不是拍照要背的词条 */
const STOP_WORDS: Set<string> = new Set([
  'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'on', 'at', 'by', 'for', 'with', 'as',
  'it', 'this', 'that', 'these', 'those'
]);
const TOKEN_SOURCE: string = "[A-Za-z][A-Za-z'\\-]*";

/**
 * 把 OCR 行集合拆成独立英文单词（真机反馈 #25：拍照后单词气泡选词）。
 * 去单元标题、词性标记、高频功能词；按小写去重并保留首次出现的原拼写与阅读顺序。
 */
export function tokenizeEnglishWords(lines: string[]): string[] {
  const out: string[] = [];
  const seen: Set<string> = new Set();
  for (const rawLine of lines) {
    const trimmed: string = rawLine.trim();
    if (trimmed.length === 0 || HEADING_RE.test(trimmed)) {
      continue;
    }
    // 先剔除 /.../、[...] 音标段，避免音标里夹带的拉丁片段（如 bændən 的 nd）被当成单词
    const line: string = trimmed
      .replace(/\/[^/]{1,60}\//g, ' ')
      .replace(/\[[^\]]{1,60}\]/g, ' ');
    const re: RegExp = new RegExp(TOKEN_SOURCE, 'g');
    let m: RegExpExecArray | null = re.exec(line);
    while (m !== null) {
      const w: string = m[0].replace(/^['\-]+|['\-]+$/g, '');
      const lower: string = w.toLowerCase();
      if (w.length >= 2 && !POS_BARE_RE.test(w) && !STOP_WORDS.has(lower) && !seen.has(lower)) {
        seen.add(lower);
        out.push(w);
      }
      m = re.exec(line);
    }
  }
  return out;
}
