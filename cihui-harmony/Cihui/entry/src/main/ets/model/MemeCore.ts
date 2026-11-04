/**
 * 词慧 · F17 梗句导入 / F18 徽章与梗卡 —— 纯逻辑层。
 *
 * 不依赖任何 ArkUI / 系统 API，可被 Node 直接 import 做单元测试。
 * 口径来源：F17-F20 功能卡（_f17_f20_spec.txt）+「梗句背诵并入统一背词流程」重构：
 * - 拆词：小写化 → 按空格与标点分词 → 停用词过滤 → 去重 → 丢纯数字；
 * - 候选三态：已掌握（绿，默认不勾且置灰）/ 学习中（黄，默认勾）/ 新词（蓝，默认勾）；
 * - 有效词 < 2 拦截；
 * - 背诵不再有专用会话：新词走 RepoCore.importTransaction 统一排期（QUEUE/TODAY），
 *   F18 梗卡在「梗句关联全部词 mastered」后由 unlockMemeCards 自动落卡。
 */
import type {
  MemeBadgeLevel,
  MemeCard,
  MemeSentence,
  ReviewSchedule,
  Word,
  WordBook,
} from './Types';
import type { AppData, WordDraft } from './RepoCore';
import { genId } from './RepoCore';
import { dayKeyFromTs } from './SchedulerCore';

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

/* ================= 导入事务：建梗句词本 + 新词走统一导入 + 建梗句记录 ================= */

/**
 * 导入第一步：只建 MEME 词本（重名自动加序号）。
 * 新词入库由调用方走 RepoCore.importTransaction（与拍照/云书同一事务、同一 intake 口径），
 * 梗句记录由 createMemeRecord 在词 id 解析后补上。
 */
export function createMemeBook(data: AppData, chinese: string, now: number):
  { data: AppData; bookId: string } {
  const bookId: string = genId('memebook');
  const book: WordBook = {
    id: bookId,
    name: uniqueMemeBookName(data, chinese),
    source: 'MEME',
    createdAt: now,
  };
  return { data: { ...data, books: [...data.books, book] }, bookId };
}

/**
 * 拆词候选 → 统一导入的 WordDraft（只转新词；已有词复用原 id 不重复入库）。
 * 词典查到的音标/释义随 draft 带走；未收录的词允许缺释义入库（source=MEME）。
 * 未勾选的词也入库并排期（与旧版口径一致：整句拆出的词都归梗句词本）。
 */
export function memeWordDrafts(candidates: MemeCandidate[], bookId: string): WordDraft[] {
  const out: WordDraft[] = [];
  for (const c of candidates) {
    if (c.existingWordId !== '') {
      continue;
    }
    out.push({
      bookId,
      english: c.token,
      phonetic: (c.phonetic ?? '').trim(),
      meanings: splitMeanings(c.meaning),
      source: 'MEME',
      diySupplement: false,
    });
  }
  return out;
}

/**
 * 已有词但词库释义为空的（老版本梗句导入的遗留数据）：查到释义就顺手补上，
 * 不覆盖用户手填的释义；音标同理（已有音标优先）。
 */
export function backfillMemeMeanings(data: AppData, candidates: MemeCandidate[]): AppData {
  const backfill: Map<string, MemeCandidate> = new Map<string, MemeCandidate>();
  for (const c of candidates) {
    if (c.existingWordId !== '' && splitMeanings(c.meaning).length > 0) {
      backfill.set(c.existingWordId, c);
    }
  }
  if (backfill.size === 0) {
    return data;
  }
  return {
    ...data,
    words: data.words.map((w: Word): Word => {
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
    }),
  };
}

/** 解析梗句关联词 id：已有词用 existingWordId，新词按词本 + 小写英文回查导入结果 */
export function resolveMemeWordIds(data: AppData, candidates: MemeCandidate[],
  bookId: string): string[] {
  const out: string[] = [];
  for (const c of candidates) {
    if (c.existingWordId !== '') {
      out.push(c.existingWordId);
      continue;
    }
    const hit: Word | undefined = data.words.find((w: Word): boolean =>
      w.bookId === bookId && w.english.toLowerCase() === c.token);
    if (hit !== undefined) {
      out.push(hit.id);
    }
  }
  return out;
}

/** 导入最后一步：建梗句记录（词 id 已全部解析；梗卡相册与 F5 词本都依赖它） */
export function createMemeRecord(data: AppData, chinese: string, english: string,
  bookId: string, wordIds: string[], now: number): { data: AppData; meme: MemeSentence } {
  const meme: MemeSentence = {
    id: genId('meme'),
    chinese,
    english,
    bookId,
    wordIds,
    createdAt: now,
    lastStudiedAt: 0,
  };
  return { data: { ...data, memes: [...data.memes, meme] }, meme };
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

/* ================= F18 徽章分级（纯函数，先落在这里） ================= */

/**
 * 梗句关联词的已掌握数（实时口径：调度 stage/status=MASTERED 计已掌握，
 * 与 buildCandidates 三态判定同源）。
 */
export function memeMasteredCount(data: AppData, meme: MemeSentence): number {
  const schedMap: Map<string, ReviewSchedule> = new Map<string, ReviewSchedule>();
  for (const s of data.schedules) {
    schedMap.set(s.wordId, s);
  }
  let n: number = 0;
  for (const id of meme.wordIds) {
    if (kindOfScheduled(schedMap.get(id)) === 'MASTERED') {
      n += 1;
    }
  }
  return n;
}

/**
 * F18 解锁（梗句背诵并入统一背词流程后的唯一解锁口径）：
 * 梗句关联的全部词都 mastered 时自动落梗卡；同梗句只落一张，已有卡不重复落。
 * masteredCount 实时按梗句关联词内已掌握数计算；cardImagePath 留空串，
 * 相册走同构 ArkUI 降级卡（专用背诵页的 Canvas 出卡入口已删除）。
 * 每次学习判定落库后调用；不满足条件的梗句原样跳过（幂等）。
 */
export function unlockMemeCards(data: AppData, now: number): AppData {
  if (data.memes.length === 0) {
    return data;
  }
  const unlocked: Set<string> = new Set<string>(
    data.memeCards.map((c: MemeCard): string => c.memeId));
  let next: AppData = data;
  for (const meme of data.memes) {
    if (unlocked.has(meme.id) || meme.wordIds.length === 0) {
      continue;
    }
    const mastered: number = memeMasteredCount(next, meme);
    if (mastered < meme.wordIds.length) {
      continue;
    }
    const result = upsertMemeCardInto(next.memeCards, {
      memeId: meme.id,
      cardImagePath: '',
      masteredCount: mastered,
      totalCount: meme.wordIds.length,
      unlockedDay: dayKeyFromTs(now),
    }, now);
    next = { ...next, memeCards: result.cards };
  }
  return next;
}

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
