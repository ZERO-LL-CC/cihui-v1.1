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

/* ==========================================================================
 * F19+ 整段生成（Passage）：8~12 句连贯短文 + 覆盖率
 *
 * 与上面「逐句 5 句」模式并存，互不影响：既有导出函数一行未改。
 * 纯函数、零 @kit / 零网络依赖，可被 Node 直接 import 做单测。
 * ========================================================================== */

/** 整段短文里的一句（模型产出的最小单元） */
export interface PassageSentence {
  /** 英文句，trim 后非空 */
  sentence: string;
  /** 中文翻译，trim 后非空 */
  translation: string;
  /** 该句用到的词（写回列表原词小写，词表外的丢弃） */
  words: string[];
}

/** 一段短文 + 覆盖率（内存态，不落库、不进调度） */
export interface PassageResult {
  /** 英文小标题，模型没给则为空串 */
  title: string;
  sentences: PassageSentence[];
  /** 被覆盖的原词（小写） */
  coveredWords: string[];
  /** 本批词中未被覆盖的原词（小写），用于补漏 Prompt */
  missedWords: string[];
  /** covered / total，保留两位小数；total=0 时为 0 */
  coverage: number;
}

/** 短文最少句数 */
export const PASSAGE_MIN_SENTENCES: number = 8;
/** 短文最多句数 */
export const PASSAGE_MAX_SENTENCES: number = 12;
/** 覆盖率目标：低于该值触发一次补漏请求 */
export const PASSAGE_COVERAGE_TARGET: number = 0.8;

/**
 * 从 start 处的开括号起做括号配平，返回首个完整片段；配不平（模型被截断）返回空串。
 * 跳过字符串字面量：标题里出现 `}`、引号、反斜杠都不会骗掉计数。
 */
function balancedFrom(text: string, start: number, open: string, close: string): string {
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
    } else if (ch === open) {
      depth++;
    } else if (ch === close) {
      depth--;
      if (depth === 0) {
        return text.slice(start, i + 1);
      }
    }
  }
  return '';
}

/** 这段文本是不是一个合法的 JSON 对象（extractJsonObject 用来排掉误切的片段） */
function isJsonObjectText(text: string): boolean {
  try {
    const value: Object = JSON.parse(text) as Object;
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  } catch (e) {
    return false;
  }
}

/**
 * 剥掉 ```json 围栏与前后解释文字，取出真正的 JSON 对象文本。
 *
 * 与 extractJsonArray 同一思路，但**不能复用**：整段返回是 `{title,sentences[]}`，
 * 用中括号配平会从 sentences 数组的 `[` 开始切，切出半截。
 *
 * 比 extractJsonArray 多一层保护：从每个 `{` 依次试配平 + 试 JSON.parse，
 * 取第一个真能解析的片段。原因是解释文字里经常出现孤立的 `{`（例如「格式如下：{ ... }」），
 * 朴素配平会从那个花括号一路吞到正文末尾，切出来的东西必然解析失败。
 */
export function extractJsonObject(raw: string): string {
  let text: string = raw.trim();
  const fence: RegExpMatchArray | null = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence !== null) {
    text = fence[1].trim();
  }
  const firstBrace: number = text.indexOf('{');
  const firstBracket: number = text.indexOf('[');
  // 模型偶尔退化成旧的数组格式：[{...},{...}]。中括号在前就整段交出，
  // parsePassagePayload 会把它当「无标题整段」收下，不白丢内容。
  if (firstBracket >= 0 && (firstBrace < 0 || firstBracket < firstBrace)) {
    const arrSlice: string = balancedFrom(text, firstBracket, '[', ']');
    return arrSlice.length > 0 ? arrSlice : text.slice(firstBracket);
  }
  if (firstBrace < 0) {
    return text;
  }
  let fallback: string = '';
  let idx: number = firstBrace;
  while (idx >= 0) {
    const slice: string = balancedFrom(text, idx, '{', '}');
    if (slice.length > 0) {
      if (isJsonObjectText(slice)) {
        return slice;
      }
      if (fallback.length === 0) {
        fallback = slice;
      }
    }
    idx = text.indexOf('{', idx + 1);
  }
  // 没有一个片段能解析：把最靠前的那段完整配平片段交出去，让 JSON.parse 报错，调用方走重试/降级
  if (fallback.length > 0) {
    return fallback;
  }
  // 半截 JSON（模型输出被截断）：原样交付
  return text.slice(firstBrace);
}

/** 词形归一时按此顺序剥后缀（长后缀优先，避免 s 先吃掉 es/ies） */
const WORD_SUFFIXES: string[] = ['ies', 'est', 'ing', 'ed', 'er', 'es', 'ly', 's', 'd'];

/**
 * 取「词干」用于词形变化比对：
 * 1. 按 WORD_SUFFIXES 顺序剥一个后缀（要求剥完仍 ≥3 字符，避免把 is/its 剥成空壳）；
 * 2. 再归一一个词尾静音 e：encourage → encourag，
 *    这样 encourage / encouraged 才落在同一个词干上（PRD 4.2 分支 3 的口径）。
 */
function stemOf(word: string): string {
  const lower: string = word.toLowerCase();
  let out: string = lower;
  for (let i = 0; i < WORD_SUFFIXES.length; i++) {
    const suf: string = WORD_SUFFIXES[i];
    if (out.length > suf.length && out.endsWith(suf)) {
      const cut: string = out.substring(0, out.length - suf.length);
      if (cut.length >= 3) {
        out = cut;
        break;
      }
    }
  }
  if (out.length >= 4 && out.endsWith('e')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/** 英文句按「非字母边界」切成小写 token（比 split 更干净：不产生空串与孤立标点） */
function tokenizeSentence(sentence: string): string[] {
  const matched: RegExpMatchArray | null = sentence.toLowerCase().match(/[a-z][a-z'-]*/g);
  if (matched === null) {
    return [];
  }
  return matched;
}

/**
 * 一个 token 是否算覆盖了 target（三级，顺序固定）：
 * 1. 精确：小写完全相等；
 * 2. 词干：都剥后缀后相等（且词干 ≥3 字符）→ refused/refuse、encouraged/encourage；
 * 3. 前缀：都 ≥4 字符且前 4 字符相同 → improved/improve。
 * 明确不做词性分析、不做同义词典匹配（避免把 good/nice 这类算成覆盖）。
 */
function wordMatchesToken(token: string, target: string): boolean {
  if (token.length === 0 || target.length === 0) {
    return false;
  }
  if (token === target) {
    return true;
  }
  const leftStem: string = stemOf(token);
  const rightStem: string = stemOf(target);
  if (leftStem.length >= 3 && rightStem.length >= 3 && leftStem === rightStem) {
    return true;
  }
  if (token.length >= 4 && target.length >= 4
    && token.substring(0, 4) === target.substring(0, 4)) {
    return true;
  }
  return false;
}

/**
 * 覆盖率计算——整段生成最关键的一环，决定「要不要补漏」「覆盖率条显示几比几」。
 *
 * 同时扫描两处证据：每句的 `words` 字段（模型自报）+ 句子正文（按非字母边界切 token）。
 * 只信 words 会被模型的漏报拖低覆盖率，只信正文会漏掉缩写/连字符写法，所以两处都扫。
 *
 * 词表按小写去重后作为分母（同一词重复入批不该把覆盖率拉低）。
 * 命中顺序：精确 → 词干 → 前缀（见 wordMatchesToken）。
 */
export function computeCoverage(sentences: PassageSentence[], words: Word[]): PassageResult {
  const tokens: string[] = [];
  sentences.forEach((item: PassageSentence): void => {
    item.words.forEach((declared: string): void => {
      const lower: string = declared.trim().toLowerCase();
      if (lower.length > 0) {
        tokens.push(lower);
      }
    });
    tokenizeSentence(item.sentence).forEach((tok: string): void => {
      tokens.push(tok);
    });
  });

  const targets: string[] = [];
  const seenTarget: Set<string> = new Set<string>();
  words.forEach((w: Word): void => {
    const lower: string = w.english.trim().toLowerCase();
    if (lower.length === 0 || seenTarget.has(lower)) {
      return;
    }
    seenTarget.add(lower);
    targets.push(lower);
  });

  const coveredWords: string[] = [];
  const missedWords: string[] = [];
  targets.forEach((target: string): void => {
    let hit: boolean = false;
    for (let i = 0; i < tokens.length; i++) {
      if (wordMatchesToken(tokens[i], target)) {
        hit = true;
        break;
      }
    }
    if (hit) {
      coveredWords.push(target);
    } else {
      missedWords.push(target);
    }
  });

  const total: number = targets.length;
  const raw: number = total === 0 ? 0 : coveredWords.length / total;
  // 两位小数：0.3333 → 0.33，避免 UI 显示 33.333333%
  const coverage: number = Math.round(raw * 100) / 100;
  const result: PassageResult = {
    title: '',
    sentences: sentences.slice(),
    coveredWords,
    missedWords,
    coverage
  };
  return result;
}

/** 词表 → `english（中文释义）` 用「、」连接；缺释义只写英文 */
function wordListText(words: Word[]): string {
  if (words.length === 0) {
    return '（本批没有单词）';
  }
  return words.map((w: Word): string => {
    const meaning: string = w.meanings.length > 0 ? w.meanings[0] : '';
    return meaning.length > 0 ? `${w.english}（${meaning}）` : w.english;
  }).join('、');
}

/** 首轮整段生成 Prompt：一次要 8~12 句连贯短文，而不是 12 个孤立句 */
export function buildPassagePrompt(words: Word[]): string {
  const list: string = wordListText(words);
  return '你是英语学习助手。请用下面给定的单词，写一段语境连贯的英文小短文（不是互不相干的句子凑数）：'
    + `共 ${PASSAGE_MIN_SENTENCES}~${PASSAGE_MAX_SENTENCES} 句，句子之间要有自然的衔接与情节推进；`
    + '语法必须正确，难度控制在大学英语四级，用词自然、地道。'
    + '允许使用词形变化（时态、单复数、比较级等），只要句中确实用到了该词即可。'
    + '尽量让一句话覆盖多个给定单词，覆盖率越高越好。每句都配一句自然的中文翻译。\n'
    + '给定单词：' + list + '\n'
    + '严格只输出一个 JSON 对象，不要输出任何解释性文字、不要输出 markdown 代码围栏，格式：'
    + '{"title":"英文小标题","sentences":[{"sentence":"英文句","translation":"中文翻译",'
    + '"words":["该句用到的给定单词原形小写"]}]}';
}

/**
 * 补漏 Prompt：覆盖率不足时用一次。
 * 关键约束是**保留已生成的句子不动**，只追加 2~3 句把漏掉的词补进去——
 * 否则模型会重写整段，用户已经读到的内容跳变，且覆盖率可能反而更低。
 */
export function buildPatchPrompt(missed: Word[], existing: PassageResult): string {
  const list: string = wordListText(missed);
  const body: string[] = existing.sentences.map((s: PassageSentence): string => s.sentence);
  const paragraph: string = body.length > 0 ? body.join(' ') : '（暂未生成正文）';
  const title: string = existing.title.length > 0 ? existing.title : '（无标题）';
  return '你是英语学习助手。下面这段英文短文已经写好，但还有几个给定单词没用上。'
    + '请**保持原有句子一字不改、顺序不变**，只在短文末尾追加 2~3 句，'
    + '把剩余的单词自然写进去，追加的句子要与上文衔接、语法正确、四级难度。'
    + '每个追加句同样配一句自然的中文翻译。\n'
    + '必须补进去的单词：' + list + '\n'
    + `已有短文标题：${title}\n`
    + `已有短文正文（共 ${existing.sentences.length} 句，必须原样保留）：${paragraph}\n`
    + '严格只输出一个 JSON 对象，包含原有全部句子 + 你追加的句子，不要输出任何解释性文字、不要输出 markdown 代码围栏，格式：'
    + '{"title":"英文小标题","sentences":[{"sentence":"英文句","translation":"中文翻译",'
    + '"words":["该句用到的给定单词原形小写"]}]}';
}

/** 模型返回的整段原始结构（字段可能缺失，逐字段校验） */
interface RawPassageSentence {
  sentence?: Object;
  translation?: Object;
  words?: Object;
}

interface RawPassage {
  title?: Object;
  sentences?: Object;
}

/**
 * 解析模型返回的整段 JSON（含容错）。
 *
 * - 先剥围栏 + 花括号配平取首个完整对象；非 JSON / 非对象 → 抛错（调用方重试一次后降级）；
 * - 模型偶尔会直接返回 `[{...}]`（沿用旧的逐句格式）→ 当作无标题整段收下，不白丢内容；
 * - 单句缺 sentence 或 translation → 丢弃该句；
 * - words 只保留 validWords 里真实存在的词（小写去重保序），其余丢弃；
 * - 句子全被丢弃 → **抛错**，绝不返回空结果伪装成功；
 * - 解析成功后用 computeCoverage 填 coveredWords / missedWords / coverage。
 */
export function parsePassagePayload(raw: string, validWords: Word[]): PassageResult {
  const validLower: Set<string> = new Set<string>();
  validWords.forEach((w: Word): void => {
    const lower: string = w.english.trim().toLowerCase();
    if (lower.length > 0) {
      validLower.add(lower);
    }
  });

  const jsonText: string = extractJsonObject(raw);
  let parsed: Object;
  try {
    parsed = JSON.parse(jsonText) as Object;
  } catch (e) {
    throw new Error('模型返回不是合法 JSON');
  }
  if (parsed === null || typeof parsed !== 'object') {
    throw new Error('模型返回不是 JSON 对象');
  }

  let title: string = '';
  let rawList: Object[] = [];
  if (Array.isArray(parsed)) {
    // 容错：模型沿用旧格式直接给了句子数组，标题留空、内容照收
    rawList = parsed as Object[];
  } else {
    const obj: RawPassage = parsed as RawPassage;
    title = asNonEmptyString(obj.title);
    rawList = Array.isArray(obj.sentences) ? (obj.sentences as Object[]) : [];
  }
  if (rawList.length === 0) {
    throw new Error('模型返回中没有可用句子');
  }

  const sentences: PassageSentence[] = [];
  rawList.forEach((item: Object): void => {
    if (item === null || typeof item !== 'object') {
      return;
    }
    const rawSentence: RawPassageSentence = item as RawPassageSentence;
    const sentence: string = asNonEmptyString(rawSentence.sentence);
    const translation: string = asNonEmptyString(rawSentence.translation);
    if (sentence.length === 0 || translation.length === 0) {
      return;
    }
    const words: string[] = [];
    const seen: Set<string> = new Set<string>();
    if (Array.isArray(rawSentence.words)) {
      (rawSentence.words as Object[]).forEach((wv: Object): void => {
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
    const made: PassageSentence = { sentence, translation, words };
    sentences.push(made);
  });

  if (sentences.length === 0) {
    throw new Error('模型返回中没有可用句子');
  }

  const result: PassageResult = computeCoverage(sentences, validWords);
  result.title = title;
  return result;
}
