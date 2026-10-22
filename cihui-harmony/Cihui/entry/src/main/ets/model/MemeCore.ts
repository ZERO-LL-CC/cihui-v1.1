/**
 * 词慧 · F17 梗句导入与背诵 / F18 徽章分级 —— 纯逻辑层。
 *
 * 不依赖任何 ArkUI / 系统 API，可被 Node 直接 import 做单元测试。
 * 口径来源：F17-F20 功能卡（_f17_f20_spec.txt）：
 * - 拆词：小写化 → 按空格与标点分词 → 停用词过滤 → 去重 → 丢纯数字；
 * - 候选三态：已掌握（绿，默认不勾且置灰）/ 学习中（黄，默认勾）/ 新词（蓝，默认勾）；
 * - 有效词 < 2 拦截；全部已掌握给「再背一遍强化」；
 * - 新词走 F2 正常排期，学习中词只进本次会话、不改排期；
 * - 会话每判一词落盘可恢复，全部 reviewed 即 completed（背完=每词完成过一次三档判定，不要求全对）。
 */
import type {
  MemeBadgeLevel,
  MemeCard,
  MemeSentence,
  ReviewSchedule,
  StudyRecord,
  StudySession,
  SessionItem,
  Verdict,
  Word,
  WordBook,
} from './Types';
import type { AppData } from './RepoCore';
import {
  activeScopeWordIds,
  applyJudgeToData,
  exceptionWordIds,
  genId,
} from './RepoCore';
import { newImportedSchedule, newStudyRecord, planNewWords } from './SchedulerCore';

/* ================= 拆词与停用词 ================= */

/**
 * 约 130 个高频英文停用词（功能词/代词/系动词/常见虚词/缩写）。
 * 梗句背诵只背有实义的词；用户在确认页仍可逐行删除。
 *
 * 缩写必须单列：分词器保留词内撇号（don't 是一个 token），
 * 只写 'im' 挡不住 "i'm"，成语化缩写被拆成可背词后词典永远查不到中文。
 */
export const STOP_WORDS: Set<string> = new Set<string>([
  'a', 'an', 'the', 'and', 'or', 'but', 'if', 'then', 'else', 'when',
  'while', 'of', 'at', 'by', 'for', 'with', 'about', 'against', 'between',
  'into', 'through', 'during', 'before', 'after', 'above', 'below', 'to',
  'from', 'up', 'down', 'in', 'out', 'on', 'off', 'over', 'under', 'again',
  'further', 'once', 'here', 'there', 'all', 'any', 'both', 'each', 'few',
  'more', 'most', 'other', 'some', 'such', 'no', 'nor', 'not', 'only',
  'own', 'same', 'so', 'than', 'too', 'very', 'can', 'will', 'just',
  'is', 'am', 'are', 'was', 'were', 'be', 'been', 'being', 'have', 'has',
  'had', 'having', 'do', 'does', 'did', 'doing', 'would', 'could', 'should',
  'shall', 'may', 'might', 'must', 'need', 'dare', 'ought', 'im', 'you',
  'he', 'she', 'it', 'we', 'they', 'me', 'him', 'her', 'us', 'them',
  'my', 'your', 'his', 'its', 'our', 'their', 'mine', 'yours', 'hers',
  'ours', 'theirs', 'this', 'that', 'these', 'those', 'i', 'me', 'as',
  'because', 'until', 'unless', 'however', 'also', 'still', 'even', 'ever',
  'never', 'always', 'often', 'sometimes', 'now', 'oh', 'yeah', 'yes',
  'no', 'ok', 'okay', 'hi', 'hello', 'please', 'thanks', 'thank',
  // 缩写形式（分词后是整词，必须单独列）
  "i'm", "i've", "i'll", "i'd", 'im', 'ive',
  "you're", "you've", "you'll", "you'd", 'youre',
  "he's", "she's", "it's", "that's", "what's", "there's", "here's",
  "we're", "they're", "who's", "how's", "let's", "ain't",
  "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't", "weren't",
  "can't", "cannot", "won't", "wouldn't", "couldn't", "shouldn't", "haven't",
  "hasn't", "hadn't", 'dont', 'cant', 'wont', 'didnt', 'isnt',
  'gonna', 'wanna', 'gotta', 'kinda', 'sorta', 'ya', 'yall', 'em',
]);

/** 小写化并按非字母（保留词内撇号）分词；丢纯数字、单字符、停用词；按出现顺序去重 */
export function tokenizeEnglish(text: string): string[] {
  const lower: string = text.toLowerCase();
  // 连续字母（含 don't 这类词内撇号）作为一个 token
  const raw: string[] = lower.split(/[^a-z']+/);
  const seen: Set<string> = new Set<string>();
  const out: string[] = [];
  for (const tok0 of raw) {
    let tok: string = tok0;
    // 去掉首尾撇号（'em → em，classroom' → classroom）
    tok = tok.replace(/^'+|'+$/g, '');
    if (tok.length < 2) {
      continue;
    }
    if (/^[0-9]+$/.test(tok)) {
      continue;
    }
    if (STOP_WORDS.has(tok)) {
      continue;
    }
    // 缩写兜底：i'm / it's / you're 这类去掉撇号后的前半段若本身是停用词，
    // 说明整词只是「停用词 + 助动词/系动词」的缩写，不该进背诵（词典也查不到）。
    const apos: number = tok.indexOf("'");
    if (apos > 0) {
      const head: string = tok.substring(0, apos);
      if (head.length < 2 || STOP_WORDS.has(head)) {
        continue;
      }
    }
    if (seen.has(tok)) {
      continue;
    }
    seen.add(tok);
    out.push(tok);
  }
  return out;
}

/* ================= 候选分类 ================= */

export type MemeCandidateKind = 'MASTERED' | 'LEARNING' | 'NEW';

export interface MemeCandidate {
  /** 小写英文词形 */
  token: string;
  /** 已掌握 / 学习中 / 新词 */
  kind: MemeCandidateKind;
  /** 已存在词库时的 wordId，新词为空串（导入时才建） */
  existingWordId: string;
  /** 确认页是否勾选：已掌握默认 false 且不可改，其余默认 true */
  selected: boolean;
  /** 是否允许改选（已掌握置灰不可改） */
  toggleable: boolean;
  /**
   * 离线词典查到的音标（可空）。这一组三个字段由页面层在进确认页/导入前用
   * LocalDictService 填充，MemeCore 本身不依赖系统 API，保持纯逻辑可测。
   */
  phonetic?: string;
  /** 离线词典查到的中文释义（可空；空=词典未收录，卡片走「结合原句语境理解」） */
  meaning?: string;
  /** 释义实际来自哪个原形（shattered → shatter 时为 shatter；与 token 相同则不显示） */
  lemma?: string;
}

/** 由调度判断一个已入库单词的三态：MASTERED 节点=已掌握，其余=学习中 */
export function kindOfScheduled(schedule: ReviewSchedule | undefined): MemeCandidateKind {
  if (schedule === undefined) {
    return 'NEW';
  }
  if (schedule.stage === 'MASTERED' || schedule.status === 'MASTERED') {
    return 'MASTERED';
  }
  return 'LEARNING';
}

/**
 * 由英文句子构建确认页候选列表（保持拆词顺序）。
 * @param words     当前词库全部单词
 * @param schedules 当前全部调度
 */
export function buildCandidates(
  tokens: string[],
  words: Word[],
  schedules: ReviewSchedule[],
): MemeCandidate[] {
  const lowerMap: Map<string, Word> = new Map<string, Word>();
  for (const w of words) {
    const key: string = w.english.toLowerCase();
    if (!lowerMap.has(key)) {
      lowerMap.set(key, w);
    }
  }
  const schedMap: Map<string, ReviewSchedule> = new Map<string, ReviewSchedule>();
  for (const s of schedules) {
    schedMap.set(s.wordId, s);
  }
  const out: MemeCandidate[] = [];
  for (const token of tokens) {
    const existed: Word | undefined = lowerMap.get(token);
    if (existed === undefined) {
      out.push({ token, kind: 'NEW', existingWordId: '', selected: true, toggleable: true });
      continue;
    }
    const kind: MemeCandidateKind = kindOfScheduled(schedMap.get(existed.id));
    out.push({
      token,
      kind,
      existingWordId: existed.id,
      selected: kind !== 'MASTERED',
      toggleable: kind !== 'MASTERED',
    });
  }
  return out;
}

/** 汇总：本句共 X 词 · 已掌握 Y · 将学 Z（Z=勾选中的学习中+新词） */
export interface CandidateSummary {
  total: number;
  mastered: number;
  learning: number;
  fresh: number;
  /** 勾选后将进入会话的词数 */
  willStudy: number;
}

export function summarizeCandidates(candidates: MemeCandidate[]): CandidateSummary {
  let mastered: number = 0;
  let learning: number = 0;
  let fresh: number = 0;
  let willStudy: number = 0;
  for (const c of candidates) {
    if (c.kind === 'MASTERED') {
      mastered += 1;
    } else if (c.kind === 'LEARNING') {
      learning += 1;
    } else {
      fresh += 1;
    }
    if (c.selected) {
      willStudy += 1;
    }
  }
  return { total: candidates.length, mastered, learning, fresh, willStudy };
}

/* ================= 洗牌（可注入随机源，便于单测） ================= */

/** Fisher–Yates 洗牌，返回新数组；rng 缺省用 Math.random */
export function shuffleList<T>(input: T[], rng?: () => number): T[] {
  const out: T[] = input.slice();
  const random: () => number = rng ?? Math.random;
  for (let i: number = out.length - 1; i > 0; i--) {
    const j: number = Math.floor(random() * (i + 1));
    const tmp: T = out[i];
    out[i] = out[j];
    out[j] = tmp;
  }
  return out;
}

/* ================= 导入事务：建梗句词本 + 新词入库 + 建会话 ================= */

export interface MemeImportInput {
  chinese: string;
  english: string;
  /** 确认页最终勾选的候选（顺序无所谓，内部洗牌） */
  candidates: MemeCandidate[];
}

export interface MemeImportResult {
  data: AppData;
  meme: MemeSentence;
  session: StudySession;
}

/**
 * 词典释义文本 → 义项数组。词典用「；」分隔词性分组（n. …；vt. …），
 * 与云词书导入口径一致，逐条拆开存入 meanings，卡片背面再 join('；') 还原。
 */
function splitMeanings(text: string | undefined): string[] {
  if (text === undefined) {
    return [];
  }
  return text
    .split(/[；;]/)
    .map((s: string): string => s.trim())
    .filter((s: string): boolean => s.length > 0);
}

/** 梗句词本名：中文前 10 字 + …，重名时追加序号 */
function uniqueMemeBookName(data: AppData, chinese: string): string {
  const base: string = chinese.trim().length > 10 ? chinese.trim().slice(0, 10) + '…' : chinese.trim();
  let name: string = base;
  let n: number = 2;
  const has = (candidate: string): boolean =>
    data.books.some((b: WordBook): boolean => b.name === candidate);
  while (has(name)) {
    name = `${base}·${n}`;
    n += 1;
  }
  return name;
}

/**
 * 一次性事务导入梗句并创建首场背诵会话：
 * 1) 建 MEME 词本；2) 新词建 Word+Record+Schedule（source=MEME，允许缺释义）；
 * 3) 已存在的学习中词复用 id；4) 统一 planNewWords 排期；5) 建 meme_sentence；
 * 6) 勾选词洗牌后建 in_progress 会话。任一步异常整体不产生半截数据（调用方持原数据）。
 */
export function createMemeImport(data: AppData, input: MemeImportInput, now: number,
  rng?: () => number): MemeImportResult {
  const chinese: string = input.chinese.trim();
  const english: string = input.english.trim();
  if (english.length === 0) {
    throw new Error('英文句子不能为空');
  }
  const chosen: MemeCandidate[] = input.candidates.filter((c: MemeCandidate): boolean => c.selected);
  if (chosen.length < 2) {
    throw new Error('至少保留 2 个有效词才能开始背诵');
  }

  let next: AppData = JSON.parse(JSON.stringify(data)) as AppData;

  // 1) 梗句词本
  const bookId: string = genId('memebook');
  const book: WordBook = {
    id: bookId,
    name: uniqueMemeBookName(next, chinese),
    source: 'MEME',
    createdAt: now,
  };
  next = { ...next, books: [...next.books, book] };

  // 2) 逐词：新词入库，旧词复用（P20 性能口径：先收集再一次性追加，
  //    避免循环内每个新词都全量复制 words/records/schedules 数组）
  const sessionWordIds: string[] = [];
  const allTokenIds: string[] = [];
  const newWords: Word[] = [];
  const newRecords: StudyRecord[] = [];
  const newSchedules: ReviewSchedule[] = [];
  // 已有词但词库里释义为空的（老版本梗句导入的遗留数据）：查到释义就顺手补上，不覆盖用户手填
  const backfill: Map<string, MemeCandidate> = new Map<string, MemeCandidate>();
  for (const c of input.candidates) {
    let wordId: string = c.existingWordId;
    if (wordId === '') {
      wordId = genId('memeword');
      const meanings: string[] = splitMeanings(c.meaning);
      newWords.push({
        id: wordId,
        bookId,
        english: c.token,
        phonetic: (c.phonetic ?? '').trim(),
        meanings,
        source: 'MEME',
        missingMeaning: meanings.length === 0,
        diySupplement: false,
        createdAt: now,
      });
      newRecords.push(newStudyRecord(wordId));
      newSchedules.push(newImportedSchedule(wordId));
    } else if (splitMeanings(c.meaning).length > 0) {
      backfill.set(wordId, c);
    }
    allTokenIds.push(wordId);
    if (c.selected) {
      sessionWordIds.push(wordId);
    }
  }
  let mergedWords: Word[] = [...next.words, ...newWords];
  if (backfill.size > 0) {
    mergedWords = mergedWords.map((w: Word): Word => {
      if (w.meanings.length > 0) {
        return w;
      }
      const c: MemeCandidate | undefined = backfill.get(w.id);
      if (c === undefined) {
        return w;
      }
      const meanings: string[] = splitMeanings(c.meaning);
      if (meanings.length === 0) {
        return w;
      }
      return {
        ...w,
        phonetic: w.phonetic.length > 0 ? w.phonetic : (c.phonetic ?? '').trim(),
        meanings,
        missingMeaning: false,
      };
    });
  }
  next = {
    ...next,
    words: mergedWords,
    records: [...next.records, ...newRecords],
    schedules: [...next.schedules, ...newSchedules],
  };

  // 3) 新词按每日新词量统一排期（与 F4/F5 同口径）
  next = {
    ...next,
    // F-D：梗句词本属例外词本，但重排口径须与全局一致（scope 外暂停词不排期）
    schedules: planNewWords(next.schedules, now, next.settings.dailyNewCount, activeScopeWordIds(next), exceptionWordIds(next)),
  };

  // 4) 梗句记录
  const memeId: string = genId('meme');
  const meme: MemeSentence = {
    id: memeId,
    chinese,
    english,
    bookId,
    wordIds: allTokenIds,
    createdAt: now,
    lastStudiedAt: 0,
  };
  next = { ...next, memes: [...next.memes, meme] };

  // 5) 首场会话（洗牌）
  const order: string[] = shuffleList(sessionWordIds, rng);
  const items: SessionItem[] = order.map((id: string): SessionItem => ({
    wordId: id,
    state: 'pending',
    verdict: null,
  }));
  const session: StudySession = {
    id: genId('memsess'),
    memeId,
    items,
    createdAt: now,
    completedAt: 0,
    status: 'in_progress',
  };
  next = { ...next, sessions: [...next.sessions, session] };

  return { data: next, meme, session };
}

/** 为同一梗句「再背一遍」：全部词（含已掌握）重新洗牌建会话 */
export function createRestudySession(data: AppData, meme: MemeSentence, now: number,
  rng?: () => number): { data: AppData; session: StudySession } {
  const order: string[] = shuffleList(meme.wordIds, rng);
  const items: SessionItem[] = order.map((id: string): SessionItem => ({
    wordId: id,
    state: 'pending',
    verdict: null,
  }));
  const session: StudySession = {
    id: genId('memsess'),
    memeId: meme.id,
    items,
    createdAt: now,
    completedAt: 0,
    status: 'in_progress',
  };
  return { data: { ...data, sessions: [...data.sessions, session] }, session };
}

/* ================= 会话推进（每判一词落盘，强杀可恢复） ================= */

export interface SessionAdvance {
  data: AppData;
  session: StudySession;
  /** 本次判定后是否全部完成（背完=每词都 reviewed 一次，不要求全对） */
  completed: boolean;
  /** 本轮判「认识」的词数（F18 徽章用） */
  knownCount: number;
}

/**
 * 判定会话中的一个词：
 * - 新词（调度仍是 NEW / 记录未首学）走 F2 首测判定，正常排期、不认识入错词本；
 * - 学习中词只进本次会话、不改排期（功能卡 Q 口径），仅记录会话内 verdict；
 * - VAGUE 的本轮重排在 UI 层把词插回队尾（state 仍置 reviewed？——不：
 *   模糊要求重考，重考通过才算 reviewed，因此 VAGUE 保持 pending，仅记 verdict）。
 */
export function advanceSession(
  data: AppData,
  sessionId: string,
  wordId: string,
  verdict: Verdict,
  now: number,
): SessionAdvance {
  const idx: number = data.sessions.findIndex((s: StudySession): boolean => s.id === sessionId);
  if (idx < 0) {
    throw new Error('背诵会话不存在：' + sessionId);
  }
  const session0: StudySession = data.sessions[idx];

  let next: AppData = data;
  const schedule: ReviewSchedule | undefined =
    data.schedules.find((s: ReviewSchedule): boolean => s.wordId === wordId);
  const isNew: boolean = schedule !== undefined && schedule.stage === 'NEW';

  if (isNew) {
    // 新词：首测判定，走 F2 正常调度（认识→次日 R1；不认识→清零入错词本；模糊→停留+错词本）
    const applied = applyJudgeToData(next, wordId, 'FIRST', verdict, now);
    next = applied.data;
  }
  // 学习中词：不动调度（只进本次会话）

  // 更新会话项
  const items: SessionItem[] = session0.items.map((it: SessionItem): SessionItem => {
    if (it.wordId !== wordId) {
      return it;
    }
    // 模糊：本轮末尾重考，保持 pending；认识/不认识：reviewed
    return {
      wordId,
      state: verdict === 'VAGUE' ? 'pending' : 'reviewed',
      verdict,
    };
  });
  const allReviewed: boolean = items.every((it: SessionItem): boolean => it.state === 'reviewed');
  let knownCount: number = 0;
  for (const it of items) {
    if (it.verdict === 'KNOWN') {
      knownCount += 1;
    }
  }
  const completedAt: number = allReviewed ? now : 0;
  const session: StudySession = {
    ...session0,
    items,
    completedAt,
    status: allReviewed ? 'completed' : 'in_progress',
  };
  const sessions: StudySession[] = next.sessions.slice();
  sessions[idx] = session;
  next = { ...next, sessions };

  // 完成时回写梗句最近学习时间
  if (allReviewed) {
    next = {
      ...next,
      memes: next.memes.map((m: MemeSentence): MemeSentence =>
        m.id === session.memeId ? { ...m, lastStudiedAt: now } : m),
    };
  }
  return { data: next, session, completed: allReviewed, knownCount };
}

/** 会话内剩余未背词数 */
export function sessionPendingCount(session: StudySession): number {
  return session.items.filter((it: SessionItem): boolean => it.state === 'pending').length;
}

/** 找某梗句（或全局）最近一场未完成会话，用于「上次还差 n 个词，继续」 */
export function findResumableSession(data: AppData, memeId?: string): StudySession | null {
  let found: StudySession | null = null;
  for (const s of data.sessions) {
    if (s.status !== 'in_progress') {
      continue;
    }
    if (memeId !== undefined && s.memeId !== memeId) {
      continue;
    }
    if (found === null || s.createdAt > found.createdAt) {
      found = s;
    }
  }
  return found;
}

/* ================= F18 徽章分级（纯函数，先落在这里） ================= */

/**
 * 掌握比例徽章：≥80% 梗王金 / 50–79% 梗手银 / <50% 梗新人铜。
 * total<=0 时按最低档（防御，正常不会出现）。
 */
export function badgeOf(knownCount: number, total: number): MemeBadgeLevel {
  if (total <= 0) {
    return 'BRONZE';
  }
  const ratio: number = knownCount / total;
  if (ratio >= 0.8) {
    return 'GOLD';
  }
  if (ratio >= 0.5) {
    return 'SILVER';
  }
  return 'BRONZE';
}

export function badgeLabel(level: MemeBadgeLevel): string {
  if (level === 'GOLD') {
    return '梗王金';
  }
  if (level === 'SILVER') {
    return '梗手银';
  }
  return '梗新人铜';
}

/* ================= F18 梗卡册纯函数（同梗句只留一张，随最新更新） ================= */

/** 落/更新梗卡入参（页面层组装，不依赖 ArkUI） */
export interface MemeCardUpsertInput {
  memeId: string;
  cardImagePath: string;
  masteredCount: number;
  totalCount: number;
  unlockedDay: string;
}

/**
 * 背完一场会话后落/更新梗卡：
 * - 同 memeId 已存在 → 只留一张，更新掌握数/徽章/日期；
 * - cardImagePath 为空串时保留旧图路径（Canvas 尚未画好或失败）；
 * - 收藏状态与分享次数沿用旧卡；
 * - 不存在 → 新建，未收藏、分享 0 次。
 */
export function upsertMemeCardInto(
  cards: MemeCard[],
  input: MemeCardUpsertInput,
  now: number,
): { cards: MemeCard[]; card: MemeCard } {
  const level: MemeBadgeLevel = badgeOf(input.masteredCount, input.totalCount);
  const idx: number = cards.findIndex((c: MemeCard): boolean => c.memeId === input.memeId);
  let card: MemeCard;
  if (idx >= 0) {
    const old: MemeCard = cards[idx];
    card = {
      ...old,
      cardImagePath: input.cardImagePath !== '' ? input.cardImagePath : old.cardImagePath,
      masteredCount: input.masteredCount,
      totalCount: input.totalCount,
      badgeLevel: level,
      unlockedDay: input.unlockedDay,
      unlockedAt: now,
    };
    const nextCards: MemeCard[] = cards.slice();
    nextCards[idx] = card;
    return { cards: nextCards, card };
  }
  card = {
    id: genId('memecard'),
    memeId: input.memeId,
    cardImagePath: input.cardImagePath,
    masteredCount: input.masteredCount,
    totalCount: input.totalCount,
    badgeLevel: level,
    unlockedDay: input.unlockedDay,
    isFavorite: false,
    sharedCount: 0,
    unlockedAt: now,
  };
  return { cards: [...cards, card], card };
}

/** 收藏 / 取消收藏，返回新数组（找不到时原样返回） */
export function toggleMemeCardFavoriteInto(cards: MemeCard[], cardId: string): MemeCard[] {
  return cards.map((c: MemeCard): MemeCard =>
    c.id === cardId ? { ...c, isFavorite: !c.isFavorite } : c);
}

/** 分享成功计数 +1 */
export function bumpMemeCardShareInto(cards: MemeCard[], cardId: string): MemeCard[] {
  return cards.map((c: MemeCard): MemeCard =>
    c.id === cardId ? { ...c, sharedCount: c.sharedCount + 1 } : c);
}

/** 只删卡，不删梗句/词/会话记录 */
export function removeMemeCardInto(cards: MemeCard[], cardId: string): MemeCard[] {
  return cards.filter((c: MemeCard): boolean => c.id !== cardId);
}

/** 梗卡册：按解锁时间倒序（新解锁在前） */
export function sortMemeCardsDesc(cards: MemeCard[]): MemeCard[] {
  return cards.slice().sort((a: MemeCard, b: MemeCard): number => b.unlockedAt - a.unlockedAt);
}
