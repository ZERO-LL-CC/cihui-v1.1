/**
 * F19 今日例句纯函数层（可 Node 单测，不依赖 ArkUI / 网络）
 *
 * - 今日词源：今日首学/学过的新词（StudyRecord.lastStudyDay === today）
 *   ＋ 今日做过判定的复习词（ReviewSchedule.lastVerdictAt 落在今天），去重保序；
 * - 分批：每批最多 BATCH_SIZE 词，逐批请求、逐批展示；
 * - 模型返回解析：容忍 ```json 围栏与前后解释文字，只取首个 JSON 数组，
 *   逐句校验、words 只保留确实来自当日词表的词；
 * - 高亮分段：英文句按词边界切，token 小写命中今日词集合则标 hit。
 * 硬规则：例句不进入艾宾浩斯调度，本文件不接触 schedules 的写操作。
 */
import type { GeneratedSentence, ReviewSchedule, SentenceSegment, StudyRecord, Word } from './Types';
import { dayKeyFromTs } from './SchedulerCore';

/** 最少今日词数：不足不请求模型 */
export const MIN_WORDS_FOR_SENTENCE: number = 3;
/** 每批最多送模的词数（Q2 拍板：20） */
export const SENTENCE_BATCH_SIZE: number = 20;
/** 每批生成例句数（Q2 拍板：5） */
export const SENTENCES_PER_BATCH: number = 5;

/** 泛型分批，保持原顺序；空数组成空批次 */
export function chunkItems<T>(items: T[], size: number = SENTENCE_BATCH_SIZE): T[][] {
  if (size <= 0) {
    return items.length === 0 ? [] : [items.slice()];
  }
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(items.slice(i, i + size));
  }
  return out;
}

/**
 * 收集"今日已学新词 + 今日已复习词"的 wordId，去重保序。
 * - records：lastStudyDay 等于 today 视为今日学过；
 * - schedules：lastVerdictAt>0 且其日键等于 today 视为今日复习判定过。
 */
export function collectTodayWordIds(
  records: StudyRecord[],
  schedules: ReviewSchedule[],
  today: string
): string[] {
  const seen: Set<string> = new Set<string>();
  const out: string[] = [];
  const push = (id: string): void => {
    if (id.length === 0 || seen.has(id)) {
      return;
    }
    seen.add(id);
    out.push(id);
  };
  records.forEach((r: StudyRecord): void => {
    if (r.lastStudyDay === today) {
      push(r.wordId);
    }
  });
  schedules.forEach((s: ReviewSchedule): void => {
    if (s.lastVerdictAt > 0 && dayKeyFromTs(s.lastVerdictAt) === today) {
      push(s.wordId);
    }
  });
  return out;
}

/** 按 wordId 顺序 join 出今日 Word 列表（缺失 id 跳过） */
export function joinWordsByIds(words: Word[], ids: string[]): Word[] {
  const map: Map<string, Word> = new Map<string, Word>();
  words.forEach((w: Word): void => {
    map.set(w.id, w);
  });
  const out: Word[] = [];
  ids.forEach((id: string): void => {
    const w: Word | undefined = map.get(id);
    if (w !== undefined) {
      out.push(w);
    }
  });
  return out;
}

/** 剥掉模型可能输出的 ```json 围栏与前后解释，用括号配平截取首个完整 JSON 数组 */
export function extractJsonArray(raw: string): string {
  let text: string = raw.trim();
  const fence: RegExpMatchArray | null = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence !== null) {
    text = fence[1].trim();
  }
  const start: number = text.indexOf('[');
  if (start < 0) {
    return text;
  }
  // 括号深度配平，跳过字符串字面量，避免被解释文字里的 ] 截断
  let depth: number = 0;
  let inStr: boolean = false;
  let escaped: boolean = false;
  for (let i = start; i < text.length; i++) {
    const ch: string = text[i];
    if (inStr) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inStr = false;
      }
      continue;
    }
    if (ch === '"') {
      inStr = true;
    } else if (ch === '[') {
      depth++;
    } else if (ch === ']') {
      depth--;
      if (depth === 0) {
        return text.slice(start, i + 1);
      }
    }
  }
  return text.slice(start);
}

/** 模型返回的原始单句（字段可能缺失，逐字段校验） */
interface RawSentence {
  sentence?: Object;
  translation?: Object;
  words?: Object;
}

function asNonEmptyString(v: Object | undefined): string {
  return typeof v === 'string' ? (v as string).trim() : '';
}

/**
 * 解析模型返回为合法例句数组。
 * - 非 JSON / 非数组 → 抛错（调用方重试一次后降级）；
 * - 单句缺英文或翻译 → 丢弃该句；
 * - words 只保留命中 validLowerWords 的词（小写比较，去重保序），
 *   模型写了词形变化也能靠句中高亮兜底，收藏只存原词。
 * 全部句子被丢弃时抛错，避免展示空结果伪装成功。
 */
export function parseSentencePayload(raw: string, validWords: Word[]): GeneratedSentence[] {
  const validLower: Set<string> = new Set<string>(validWords.map((w: Word): string => w.english.toLowerCase()));
  const jsonText: string = extractJsonArray(raw);
  let parsed: RawSentence[];
  try {
    parsed = JSON.parse(jsonText) as RawSentence[];
  } catch (e) {
    throw new Error('模型返回不是合法 JSON');
  }
  if (!Array.isArray(parsed)) {
    throw new Error('模型返回不是 JSON 数组');
  }
  const out: GeneratedSentence[] = [];
  parsed.forEach((item: RawSentence): void => {
    if (typeof item !== 'object' || item === null) {
      return;
    }
    const sentence: string = asNonEmptyString(item.sentence);
    const translation: string = asNonEmptyString(item.translation);
    if (sentence.length === 0 || translation.length === 0) {
      return;
    }
    const words: string[] = [];
    const seen: Set<string> = new Set<string>();
    if (Array.isArray(item.words)) {
      (item.words as Object[]).forEach((wv: Object): void => {
        if (typeof wv !== 'string') {
          return;
        }
        const lower: string = (wv as string).trim().toLowerCase();
        if (validLower.has(lower) && !seen.has(lower)) {
          seen.add(lower);
          words.push(lower);
        }
      });
    }
    const made: GeneratedSentence = { sentence, translation, words };
    out.push(made);
  });
  if (out.length === 0) {
    throw new Error('模型返回中没有可用例句');
  }
  return out;
}

/**
 * 英文句按"单词 / 非单词"边界切分，单词 token 小写命中词集合即 hit。
 * 非字母片段（空格、标点、中文翻译）原样保留为非命中段，相邻同类段合并。
 */
export function highlightSegments(sentence: string, words: string[]): SentenceSegment[] {
  const hitSet: Set<string> = new Set<string>(words.map((w: string): string => w.toLowerCase()));
  const tokens: string[] = sentence.split(/([A-Za-z][A-Za-z'-]*)/);
  const raw: SentenceSegment[] = [];
  tokens.forEach((tok: string): void => {
    if (tok.length === 0) {
      return;
    }
    const isWord: boolean = /^[A-Za-z][A-Za-z'-]*$/.test(tok);
    const hit: boolean = isWord && hitSet.has(tok.toLowerCase());
    raw.push({ text: tok, hit });
  });
  // 合并相邻同 hit 状态，减少 Text 节点数
  const merged: SentenceSegment[] = [];
  raw.forEach((seg: SentenceSegment): void => {
    const last: SentenceSegment | undefined = merged[merged.length - 1];
    if (last !== undefined && last.hit === seg.hit) {
      last.text += seg.text;
    } else {
      merged.push({ text: seg.text, hit: seg.hit });
    }
  });
  return merged;
}

/** 组装给大模型的 Prompt（固定输出 JSON 数组，不要解释性文字） */
export function buildPrompt(words: Word[], count: number): string {
  const list: string = words.map((w: Word): string => {
    const meaning: string = w.meanings.length > 0 ? w.meanings[0] : '';
    return meaning.length > 0 ? `${w.english}（${meaning}）` : w.english;
  }).join('、');
  return '你是英语学习助手。请用下面给定的单词造语法正确、语境自然、适合大学英语水平的英文句子，'
    + `共 ${count} 句，每句至少包含列表中的一个词，鼓励一句覆盖多个词；每句附自然的中文翻译。\n`
    + '给定单词：' + list + '\n'
    + '严格只输出 JSON 数组，不要输出任何解释性文字或 markdown，格式：'
    + '[{"sentence":"英文句","translation":"中文翻译","words":["句中用到的列表原词小写"]}]';
}
