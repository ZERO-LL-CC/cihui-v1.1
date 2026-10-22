/**
 * 词慧 · 内存仓库核心（F2）——纯函数 CRUD，操作数组并返回新状态。
 *
 * 按用户硬性要求：本期以内存数组做临时仓库，新增/编辑/删除直接操作数组，前端自闭环；
 * F2 卡要求的 relationalStore / preferences 落盘通过 Persistence 接口预留（见 DataStore.ets
 * 与 F15 本地 JSON 导出导入），接口形态与表结构一一对应，后续替换不影响 UI。
 *
 * 所有函数不可变更新（返回新数组/新对象），便于：
 * 1) V2 状态管理重新赋值触发刷新；2) 序列化快照模拟“杀进程不丢”；3) 单元测试断言。
 */

import { DEFAULT_SETTINGS, STAGE_OFFSET_DAYS, STAGE_ORDER } from './Types';
import type {
  BookSource,
  CheckInRecord,
  IntakeMode,
  LearnPhase,
  MemeCard,
  MemeSentence,
  ReviewSchedule,
  SavedSentence,
  Settings,
  StageCode,
  StudyRecord,
  StudySession,
  Verdict,
  Word,
  WordBook,
  WordSource,
} from './Types';
import {
  addDays,
  clampDailyNew,
  dayKeyFromTs,
  diffDays,
  evaluateGates,
  judge,
  newImportedSchedule,
  newStudyRecord,
  planNewWords,
  todayKey,
  withDailyNew,
} from './SchedulerCore';
import type { CheckinGateStatus, JudgeResult } from './SchedulerCore';

/** 应用全量数据（即未来关系库各张表 + preferences 的内存投影） */
export interface AppData {
  books: WordBook[];
  words: Word[];
  schedules: ReviewSchedule[];
  records: StudyRecord[];
  checkins: CheckInRecord[];
  settings: Settings;
  /** F17 梗句 */
  memes: MemeSentence[];
  /** F17 梗句背诵会话（可恢复） */
  sessions: StudySession[];
  /** F18 梗卡片 */
  memeCards: MemeCard[];
  /** F19 收藏例句 */
  savedSentences: SavedSentence[];
}

export function emptyData(): AppData {
  return {
    books: [],
    words: [],
    schedules: [],
    records: [],
    checkins: [],
    settings: { ...DEFAULT_SETTINGS },
    memes: [],
    sessions: [],
    memeCards: [],
    savedSentences: [],
  };
}

export function cloneData(d: AppData): AppData {
  return JSON.parse(JSON.stringify(d)) as AppData;
}

/** 表单校验结果（必填校验集中在这里，UI 直接展示 message） */
export interface ValidateResult {
  ok: boolean;
  message: string;
}

let seq: number = 1;

/** ID 生成：时间戳 + 自增序列，内存期足够；接库后由关系库主键替代 */
export function genId(prefix: string): string {
  const now: number = Date.now();
  seq += 1;
  return prefix + '_' + now.toString(36) + '_' + seq.toString(36);
}

/* ================= 词本 ================= */

export interface BookDraft {
  name: string;
  source: BookSource;
  cloudBookId?: string;
}

export function validateBook(draft: BookDraft, books: WordBook[]): ValidateResult {
  const name: string = draft.name.trim();
  if (name.length === 0) {
    return { ok: false, message: '词本名称不能为空' };
  }
  const dup: boolean = books.some((b: WordBook): boolean => b.name === name);
  if (dup) {
    return { ok: false, message: '已存在同名词本' };
  }
  return { ok: true, message: '' };
}

export function addBook(data: AppData, draft: BookDraft, now: number): AppData {
  const v: ValidateResult = validateBook(draft, data.books);
  if (!v.ok) {
    throw new Error(v.message);
  }
  const book: WordBook = {
    id: genId('book'),
    name: draft.name.trim(),
    source: draft.source,
    createdAt: now,
  };
  if (draft.cloudBookId) {
    book.cloudBookId = draft.cloudBookId;
  }
  return { ...data, books: [...data.books, book] };
}

export function renameBook(data: AppData, bookId: string, name: string): AppData {
  const trimmed: string = name.trim();
  if (trimmed.length === 0) {
    throw new Error('词本名称不能为空');
  }
  return {
    ...data,
    books: data.books.map((b: WordBook): WordBook =>
      b.id === bookId ? { ...b, name: trimmed } : b),
  };
}

/** 删词本：级联删除其下单词、调度、学习记录；F17 梗句词本连带梗句/会话/梗卡（F5 二次确认在 UI 层） */
export function deleteBook(data: AppData, bookId: string): AppData {
  const wordIds: Set<string> = new Set(
    data.words.filter((w: Word): boolean => w.bookId === bookId).map((w: Word): string => w.id),
  );
  const memeIds: Set<string> = new Set(
    data.memes.filter((m: MemeSentence): boolean => m.bookId === bookId).map((m: MemeSentence): string => m.id),
  );
  return {
    ...data,
    books: data.books.filter((b: WordBook): boolean => b.id !== bookId),
    words: data.words.filter((w: Word): boolean => w.bookId !== bookId),
    schedules: data.schedules.filter((s: ReviewSchedule): boolean => !wordIds.has(s.wordId)),
    records: data.records.filter((r: StudyRecord): boolean => !wordIds.has(r.wordId)),
    memes: data.memes.filter((m: MemeSentence): boolean => m.bookId !== bookId),
    sessions: data.sessions.filter((s: StudySession): boolean => !memeIds.has(s.memeId)),
    memeCards: data.memeCards.filter((c: MemeCard): boolean => !memeIds.has(c.memeId)),
  };
}

/* ================= 单词 ================= */

export interface WordDraft {
  bookId: string;
  english: string;
  phonetic?: string;
  meanings: string[];
  source: WordSource;
  diySupplement?: boolean;
}

export function validateWord(draft: WordDraft): ValidateResult {
  if (draft.bookId.length === 0) {
    return { ok: false, message: '请先选择词本' };
  }
  if (draft.english.trim().length === 0) {
    return { ok: false, message: '英文单词不能为空' };
  }
  const hasMeaning: boolean = draft.meanings.some((m: string): boolean => m.trim().length > 0);
  // 允许缺释义入库：OCR 校对页补录流程、F17 梗句拆词（结合原句语境理解），但都显式标 missingMeaning
  if (!hasMeaning && draft.source !== 'OCR' && draft.source !== 'MEME') {
    return { ok: false, message: '请填写中文释义' };
  }
  return { ok: true, message: '' };
}

function toWord(draft: WordDraft, id: string, now: number): Word {
  const meanings: string[] = draft.meanings
    .map((m: string): string => m.trim())
    .filter((m: string): boolean => m.length > 0);
  return {
    id,
    bookId: draft.bookId,
    english: draft.english.trim(),
    phonetic: draft.phonetic ? draft.phonetic.trim() : '',
    meanings,
    source: draft.source,
    missingMeaning: meanings.length === 0,
    diySupplement: draft.diySupplement ?? false,
    createdAt: now,
  };
}

/** 新增单词并同时建学习记录 + 调度，随后立即按每日新词量排期（与导入事务口径一致）。
 *  F-A：intake='TODAY' 时词当天到期、不占每日新词配额（拍照·加入当天计划同口径）。 */
export function addWord(data: AppData, draft: WordDraft, now: number, intake: IntakeMode = 'QUEUE'): AppData {
  const v: ValidateResult = validateWord(draft);
  if (!v.ok) {
    throw new Error(v.message);
  }
  const id: string = genId('word');
  const word: Word = toWord(draft, id, now);
  let schedule: ReviewSchedule = newImportedSchedule(id);
  if (intake === 'TODAY') {
    schedule = { ...schedule, dueDay: dayKeyFromTs(now), intake: 'TODAY' };
  }
  const next: AppData = {
    ...data,
    words: [...data.words, word],
    records: [...data.records, newStudyRecord(id)],
    schedules: [...data.schedules, schedule],
  };
  // F-D：scope 限制 = 背诵中词本 + 拍照/梗句例外词本
  return {
    ...next,
    schedules: planNewWords(next.schedules, now, next.settings.dailyNewCount, activeScopeWordIds(next)),
  };
}

export function updateWord(data: AppData, wordId: string, patch: Partial<WordDraft>): AppData {
  return {
    ...data,
    words: data.words.map((w: Word): Word => {
      if (w.id !== wordId) {
        return w;
      }
      const merged: Word = {
        ...w,
        english: patch.english !== undefined ? patch.english.trim() : w.english,
        phonetic: patch.phonetic !== undefined ? patch.phonetic.trim() : w.phonetic,
        meanings: patch.meanings !== undefined
          ? patch.meanings.map((m: string): string => m.trim()).filter((m: string): boolean => m.length > 0)
          : w.meanings,
        diySupplement: patch.diySupplement !== undefined ? patch.diySupplement : w.diySupplement,
      };
      merged.missingMeaning = merged.meanings.length === 0;
      return merged;
    }),
  };
}

export function deleteWord(data: AppData, wordId: string): AppData {
  return {
    ...data,
    words: data.words.filter((w: Word): boolean => w.id !== wordId),
    schedules: data.schedules.filter((s: ReviewSchedule): boolean => s.wordId !== wordId),
    records: data.records.filter((r: StudyRecord): boolean => r.wordId !== wordId),
  };
}

/** 批量删除（DIY 词本编辑 / 词本管理用） */
export function batchDeleteWords(data: AppData, wordIds: string[]): AppData {
  const set: Set<string> = new Set(wordIds);
  return {
    ...data,
    words: data.words.filter((w: Word): boolean => !set.has(w.id)),
    schedules: data.schedules.filter((s: ReviewSchedule): boolean => !set.has(s.wordId)),
    records: data.records.filter((r: StudyRecord): boolean => !set.has(r.wordId)),
  };
}

/**
 * 一次性导入整批单词（F4 OCR 确认导入 / F5 云词书下载）：
 * 单次“事务”——要么全部成功，要么抛异常不产生半截数据；导入后立即按每日新词量排期。
 *
 * F-A 入列方式（拍照导入两模式，口径与算法 Demo 一致）：
 * - QUEUE（默认）：直接加入词本 → planNewWords 从今天起找第一个配额空位插入，满则顺延；
 * - TODAY：加入当天计划 → 词 dueDay=今天、intake='TODAY'，今天立即首学且不占每日新词配额
 *   （planNewWords 预扫描排除 intake='TODAY'，不会挤占当天队列词的配额）。
 *
 * 性能口径（P20 修复）：原实现循环内每条 draft 都做 words/records/schedules
 * 全量数组展开（O(n²)）外加 cloneData JSON 深拷贝，导入几千词的云词本明显卡顿。
 * 现改为各 slice() 一次后 push（摊销 O(1)）。事务语义不变：
 * 校验失败中途抛错时 data 原样未动（slice 是副本），genId 生成时序不变。
 */
export function importTransaction(data: AppData, drafts: WordDraft[], now: number,
  intake: IntakeMode = 'QUEUE'): AppData {
  if (drafts.length === 0) {
    throw new Error('没有可导入的单词');
  }
  const words: Word[] = data.words.slice();
  const records: StudyRecord[] = data.records.slice();
  const schedules: ReviewSchedule[] = data.schedules.slice();
  const todayKey: string = dayKeyFromTs(now);
  for (const draft of drafts) {
    const v: ValidateResult = validateWord(draft);
    if (!v.ok) {
      throw new Error(v.message + '：' + draft.english);
    }
    const id: string = genId('word');
    words.push(toWord(draft, id, now));
    records.push(newStudyRecord(id));
    if (intake === 'TODAY') {
      schedules.push({ ...newImportedSchedule(id), dueDay: todayKey, intake: 'TODAY' });
    } else {
      schedules.push(newImportedSchedule(id));
    }
  }
  const next: AppData = { ...data, words, records, schedules };
  // TODAY 分支也走 planNewWords：给可能存在的未排期词补排期；TODAY 词因 intake 标记不占配额。
  // F-D：scope 限制 = 背诵中词本 + 拍照/梗句例外词本。
  return {
    ...next,
    schedules: planNewWords(schedules, now, next.settings.dailyNewCount, activeScopeWordIds(next)),
  };
}

/* ================= 云词书下载导入（F5，mock 目录见 service/CloudCatalog.ts） ================= */

/** 拍照导入的固定独立词本名（F-D：不随日期建多本，始终参与算法排期） */
export const PHOTO_BOOK_NAME: string = '拍照词本';

/**
 * F-D 单词本限制（一次只能背一本）：
 * 返回当前允许参与每日新词排期的词 id 集合 = 背诵中词本 ∪ 拍照词本（例外） ∪ 梗句词本（例外）。
 * activeBookId 为空（旧数据 / 从未设置）时返回 undefined = 全部参与排期（向后兼容）。
 */
export function activeScopeWordIds(data: AppData): Set<string> | undefined {
  const activeId: string = data.settings.activeBookId ?? '';
  if (activeId.length === 0) {
    return undefined;
  }
  // bookId → 是否例外词本（拍照 / 梗句）
  const freeByBook: Map<string, boolean> = new Map();
  for (const b of data.books) {
    freeByBook.set(b.id, b.source === 'DIY_PHOTO' || b.source === 'MEME');
  }
  const scope: Set<string> = new Set();
  for (const w of data.words) {
    if (w.bookId === activeId || freeByBook.get(w.bookId) === true) {
      scope.add(w.id);
    }
  }
  return scope;
}

/**
 * F-D 切换背诵词本：
 * - 旧背诵词本中「未首学」的新词清空排期（暂停，切回来时再排）；
 * - 已首学的词（R1–R15 复习义务）不动，继续按节点复习；
 * - 设置 activeBookId = 新词本，并立刻为新词本里此前被暂停（dueDay 为空）的新词重排，
 *   否则「切走再切回」的词永远排不上队（BUG：导入高考词汇后回不去四级词汇）；
 * - 重复切到同一本幂等。
 */
export function switchActiveBookData(data: AppData, newBookId: string, now: number): AppData {
  const oldId: string = data.settings.activeBookId ?? '';
  if (oldId === newBookId) {
    return data;
  }
  let schedules: ReviewSchedule[] = data.schedules;
  if (oldId.length > 0) {
    const oldWordIds: Set<string> = new Set();
    for (const w of data.words) {
      if (w.bookId === oldId) {
        oldWordIds.add(w.id);
      }
    }
    schedules = data.schedules.map((s: ReviewSchedule): ReviewSchedule => {
      if (oldWordIds.has(s.wordId) && s.stage === 'NEW' && s.firstLearnDay === '' && s.dueDay !== '') {
        return { ...s, dueDay: '' };
      }
      return s;
    });
  }
  const next: AppData = { ...data, schedules, settings: { ...data.settings, activeBookId: newBookId } };
  // 切回时恢复该词本被暂停的新词排期（scope 已指向新词本，旧词本词保持暂停）
  return {
    ...next,
    schedules: planNewWords(schedules, now, next.settings.dailyNewCount, activeScopeWordIds(next)),
  };
}

/** 云词书下载导入入参中的单词（结构与 service 层 CloudSampleWord 兼容） */
export interface CloudWordInput {
  english: string;
  phonetic: string;
  meaning: string;
}

/** 云词书下载导入入参（词书元数据 + 示例词包） */
export interface CloudBookImport {
  name: string;
  cloudBookId: string;
  words: CloudWordInput[];
}

/**
 * 云词书下载落库：先建 CLOUD 词本，再走整批导入事务（任一单词校验失败整体回滚，
 * 不产生半截词书）；同一 cloudBookId 幂等拦截。
 * F-D：下载即切换背诵词本（一次只能背一本）——旧词本未首学新词暂停排期，
 * 新词本词与拍照/梗句例外词本一起按每日新词量排期。
 */
export function importCloudBook(data: AppData, draft: CloudBookImport, now: number): AppData {
  const exists: boolean =
    data.books.some((b: WordBook): boolean => b.cloudBookId === draft.cloudBookId);
  if (exists) {
    throw new Error('该词书已导入，请勿重复下载');
  }
  const withBook: AppData = addBook(
    data,
    { name: draft.name, source: 'CLOUD', cloudBookId: draft.cloudBookId },
    now,
  );
  const book: WordBook = withBook.books[withBook.books.length - 1];
  const withActive: AppData = switchActiveBookData(withBook, book.id, now);
  const drafts: WordDraft[] = [];
  for (const w of draft.words) {
    const meanings: string[] = w.meaning
      .split(/[；;]/)
      .map((s: string): string => s.trim())
      .filter((s: string): boolean => s.length > 0);
    const d: WordDraft = {
      bookId: book.id,
      english: w.english,
      phonetic: w.phonetic,
      meanings,
      source: 'CLOUD',
    };
    drafts.push(d);
  }
  // F-D：用切换后的数据（activeBookId=新书）导入，新书词进入 scope 参与排期
  return importTransaction(withActive, drafts, now);
}

/* ================= 学习判定（语音自动与手动闪卡共用） ================= */

/**
 * 对单个单词应用三档判定，返回新数据与判定结果。
 * 自动语音判定、手动闪卡判定、复核清单改判全部走这里，改判即基于当前调度立即重算。
 */
export interface ApplyJudgeResult {
  data: AppData;
  result: JudgeResult;
}

export function applyJudgeToData(
  data: AppData,
  wordId: string,
  phase: LearnPhase,
  verdict: Verdict,
  now: number,
): ApplyJudgeResult {
  const schedule: ReviewSchedule | undefined =
    data.schedules.find((s: ReviewSchedule): boolean => s.wordId === wordId);
  const record: StudyRecord | undefined =
    data.records.find((r: StudyRecord): boolean => r.wordId === wordId);
  if (!schedule || !record) {
    throw new Error('单词调度不存在：' + wordId);
  }
  const result: JudgeResult = judge(schedule, record, phase, verdict, now);
  const next: AppData = {
    ...data,
    schedules: data.schedules.map((s: ReviewSchedule): ReviewSchedule =>
      s.wordId === wordId ? result.schedule : s),
    records: data.records.map((r: StudyRecord): StudyRecord =>
      r.wordId === wordId ? result.record : r),
  };
  return { data: next, result };
}

/**
 * F10 从错词本移出一个词（用户主动「移出」，不做强化）：
 * - 判不认识（status=WRONG、stage=NEW、次日到期）：恢复 LEARNING，保留 NEW 与次日到期，
 *   即明天按正常新词流程走，不再挂错词标记；
 * - 判模糊（forceNextDay 强制次日复习）：清除强制/重队列/原因，保留当前节点与到期日，
 *   次日按普通复习出现。
 * 找不到调度时原样返回（幂等）。
 */
export function removeWrongFromData(data: AppData, wordId: string): AppData {
  return {
    ...data,
    schedules: data.schedules.map((s: ReviewSchedule): ReviewSchedule => {
      if (s.wordId !== wordId) {
        return s;
      }
      if (s.status === 'WRONG') {
        return { ...s, status: 'LEARNING', forceNextDay: false, roundRequeue: false, wrongReason: '' };
      }
      return { ...s, forceNextDay: false, roundRequeue: false, wrongReason: '' };
    }),
  };
}

/* ================= 打卡 ================= */

/**
 * 复算并写入某天打卡记录（幂等：同一天重复调用，达标状态一致；已打卡不重复计数）。
 * - 正常打卡（makeup=false）：前置全达标才允许 checkedIn=true，连续天数按昨天递推。
 * - 补卡（makeup=true）：由 F12 补卡流程在补卡词本全部过完后调用，代表该日欠账已补完；
 *   记录置达标并标 makeup，但不恢复连续天数（开放项默认口径）。
 */
export function upsertCheckin(data: AppData, day: string, now: number, makeup: boolean): AppData {
  const gates = evaluateGates(
    { schedules: data.schedules, records: data.records, settings: data.settings },
    day,
  );
  const existing: CheckInRecord | undefined = data.checkins.find((c: CheckInRecord): boolean => c.day === day);
  const streakBase: CheckInRecord[] = data.checkins.filter((c: CheckInRecord): boolean => c.day !== day);

  if (makeup) {
    const record: CheckInRecord = {
      day,
      p1NewDone: true,
      p2ReviewDone: true,
      p3WrongDone: true,
      p3Required: existing ? existing.p3Required : gates.p3Required,
      checkedIn: true,
      makeup: true,
      streak: existing ? existing.streak : 0,
    };
    return { ...data, checkins: [...streakBase, record] };
  }

  const canCheck: boolean = gates.p1 && gates.p2 && (!gates.p3Required || gates.p3);
  let streak: number = 0;
  if (canCheck) {
    const yesterday: string = addDays(day, -1);
    const y: CheckInRecord | undefined = streakBase.find((c: CheckInRecord): boolean => c.day === yesterday);
    streak = y ? y.streak + 1 : 1;
  }
  const record: CheckInRecord = {
    day,
    p1NewDone: gates.p1,
    p2ReviewDone: gates.p2,
    p3WrongDone: gates.p3,
    p3Required: gates.p3Required,
    checkedIn: existing ? existing.checkedIn : canCheck,
    makeup: existing ? existing.makeup : false,
    streak: existing && existing.checkedIn ? existing.streak : streak,
  };
  return { ...data, checkins: [...streakBase, record] };
}

/** 当日前置达标状态（按钮置灰文案用），不落数据 */
export interface DayGateStatus extends CheckinGateStatus {
  day: string;
}

export function todayGateStatus(data: AppData, now: number): DayGateStatus {
  const day: string = todayKey(now);
  const gates: CheckinGateStatus =
    evaluateGates({ schedules: data.schedules, records: data.records, settings: data.settings }, day);
  return {
    day,
    p1: gates.p1,
    p2: gates.p2,
    p3: gates.p3,
    p3Required: gates.p3Required
  };
}

/* ================= F12 补卡闭环 / 每日新词量调整 ================= */

/** 补卡日详情里的一组待补词（按节点分组） */
export interface MakeupGroup {
  /** NEW / R1 / R2 / R4 / R7 / R15 / WRONG */
  stage: string;
  title: string;
  count: number;
  wordIds: string[];
}

const MAKEUP_REVIEW_STAGES: StageCode[] = ['R1', 'R2', 'R4', 'R7', 'R15'];
const MAKEUP_GROUP_ORDER: string[] = ['NEW', 'R1', 'R2', 'R4', 'R7', 'R15', 'WRONG'];

function makeupGroupTitle(stage: string): string {
  if (stage === 'NEW') {
    return '当天新词未首学';
  }
  if (stage === 'WRONG') {
    return '错词强化未完成';
  }
  return stage + ' 到期复习';
}

/**
 * 计算某个补卡日欠下的任务，按节点分组（F12 补卡详情页数据源）。
 * - NEW：排期到该日（含更早逾期）但从未首学的新词；
 * - R 节点：首学日 + 节点偏移恰好落在该日、且当前尚未推进过该节点；
 *   或当前仍停留在该节点且到期日不晚于该日（逾期复习）；
 * - WRONG：判错清零后一直没重学的词。
 * 已掌握（MASTERED）不计欠账。
 */
export function buildMakeupGroups(data: AppData, day: string): MakeupGroup[] {
  const map: Map<string, string[]> = new Map();
  const push = (stage: string, wordId: string): void => {
    const arr: string[] = map.get(stage) ?? [];
    arr.push(wordId);
    map.set(stage, arr);
  };

  for (const s of data.schedules) {
    if (s.stage === 'MASTERED' || s.status === 'MASTERED') {
      continue;
    }
    if (s.status === 'WRONG') {
      push('WRONG', s.wordId);
      continue;
    }
    if (s.stage === 'NEW' && s.firstLearnDay === '' && s.dueDay !== '' && diffDays(s.dueDay, day) >= 0) {
      push('NEW', s.wordId);
      continue;
    }
    if (s.status === 'LEARNING' && MAKEUP_REVIEW_STAGES.indexOf(s.stage as StageCode) >= 0
      && s.firstLearnDay !== '') {
      let plannedStage = '';
      for (const node of MAKEUP_REVIEW_STAGES) {
        const nodeDay: string = addDays(s.firstLearnDay, STAGE_OFFSET_DAYS[node]);
        const reached: boolean = STAGE_ORDER.indexOf(s.stage) > STAGE_ORDER.indexOf(node);
        if (nodeDay === day && !reached) {
          plannedStage = node;
          break;
        }
      }
      if (plannedStage !== '') {
        push(plannedStage, s.wordId);
      } else if (s.dueDay !== '' && diffDays(s.dueDay, day) >= 0) {
        push(s.stage, s.wordId);
      }
    }
  }

  const groups: MakeupGroup[] = [];
  MAKEUP_GROUP_ORDER.forEach((stage: string): void => {
    const ids: string[] = map.get(stage) ?? [];
    if (ids.length > 0) {
      groups.push({ stage, title: makeupGroupTitle(stage), count: ids.length, wordIds: ids });
    }
  });
  return groups;
}

export interface MakeupEligibility {
  ok: boolean;
  reason: string;
}

/**
 * 补卡资格（F12 严格顺序）：
 * 1. 只能补今天之前的日期；2. 该日未打卡/未补卡；3. 今天任务已完成并已打卡；
 * 4. 该日与今天之间不能还有缺卡日（只能补最近一个缺卡日，由近及远逐天补）；
 * 5. 该日确实存在欠任务，且当天已开始使用（首个活跃日之后）。
 */
export function canMakeup(data: AppData, day: string, now: number): MakeupEligibility {
  const today: string = todayKey(now);
  if (diffDays(day, today) <= 0) {
    return { ok: false, reason: '只能补今天之前的日期' };
  }
  const existing: CheckInRecord | undefined =
    data.checkins.find((c: CheckInRecord): boolean => c.day === day);
  if (existing !== undefined && existing.checkedIn) {
    return { ok: false, reason: '该日已打卡，无需补卡' };
  }
  const todayRecord: CheckInRecord | undefined =
    data.checkins.find((c: CheckInRecord): boolean => c.day === today);
  if (todayRecord === undefined || !todayRecord.checkedIn || todayRecord.makeup) {
    return { ok: false, reason: '请先完成今天的任务并打卡，再来补卡' };
  }
  // 该日之后、今天之前，不能还有缺卡日
  const gap: number = diffDays(day, today);
  for (let i = 1; i < gap; i++) {
    const d: string = addDays(day, i);
    const c: CheckInRecord | undefined =
      data.checkins.find((x: CheckInRecord): boolean => x.day === d);
    if (c === undefined || !c.checkedIn) {
      return { ok: false, reason: '请先补更近的缺卡日，按顺序逐天补齐' };
    }
  }
  if (buildMakeupGroups(data, day).length === 0) {
    return { ok: false, reason: '该日没有待补的学习任务' };
  }
  return { ok: true, reason: '' };
}

/**
 * 补卡词本全部过完后调用：把待补词统一判「认识」推进调度，
 * 再写入 makeup=true 的打卡记录（不恢复连续天数）。幂等：已补卡直接返回。
 */
export function completeMakeup(data: AppData, day: string, now: number): AppData {
  const existing: CheckInRecord | undefined =
    data.checkins.find((c: CheckInRecord): boolean => c.day === day);
  if (existing !== undefined && existing.checkedIn && existing.makeup) {
    return data;
  }
  const groups: MakeupGroup[] = buildMakeupGroups(data, day);
  let next: AppData = data;
  for (const g of groups) {
    for (const wordId of g.wordIds) {
      const sched: ReviewSchedule | undefined =
        next.schedules.find((s: ReviewSchedule): boolean => s.wordId === wordId);
      if (sched === undefined) {
        continue;
      }
      const phase: LearnPhase = (sched.stage === 'NEW' || sched.status === 'WRONG') ? 'FIRST' : 'REVIEW';
      next = applyJudgeToData(next, wordId, phase, 'KNOWN' as Verdict, now).data;
    }
  }
  return upsertCheckin(next, day, now, true);
}

/**
 * 修改每日新词量（F12 滚轮确定后）：
 * - 更新设置并夹取 5–40；
 * - 今天已首学/首过的新词回退为未排期新词（重置当日完成态），对应学习记录重置；
 * - 逾期未学新词保留为今天到期，今天及以后的未学新词重新按新额度排期；
 * - 删除当天打卡记录（需重新完成、重新打卡）；
 * - 历史已学记录与已掌握词不做任何篡改。
 */
export function applyDailyNewCount(data: AppData, n: number, now: number): AppData {
  const today: string = dayKeyFromTs(now);
  const quota: number = clampDailyNew(n);

  const resetIds: Set<string> = new Set();
  const schedules: ReviewSchedule[] = data.schedules.map((s: ReviewSchedule): ReviewSchedule => {
    if (s.firstLearnDay === today && s.stage !== 'MASTERED') {
      // 今天刚学的词：回退为新词，参与重新排期
      resetIds.add(s.wordId);
      return {
        ...newImportedSchedule(s.wordId),
      };
    }
    if (s.stage === 'NEW' && s.firstLearnDay === '') {
      // 逾期新词（到期日早于今天）保留为今天到期
      if (s.dueDay !== '' && diffDays(s.dueDay, today) > 0) {
        return { ...s, dueDay: today };
      }
      // 未来排期（到期日晚于今天）清空，重新分配；与 previewDailyNew 同构（修复 diffDays 参数反转）
      if (s.dueDay !== '' && diffDays(today, s.dueDay) > 0) {
        return { ...s, dueDay: '' };
      }
    }
    return s;
  });

  const records: StudyRecord[] = data.records.map((r: StudyRecord): StudyRecord =>
    resetIds.has(r.wordId) ? newStudyRecord(r.wordId) : r);

  const checkins: CheckInRecord[] = data.checkins.filter((c: CheckInRecord): boolean => c.day !== today);

  const replanned: ReviewSchedule[] =
    planNewWords(schedules, now, quota, activeScopeWordIds(data));

  return {
    ...data,
    schedules: replanned,
    records,
    checkins,
    settings: withDailyNew(data.settings, quota),
  };
}

/**
 * 设置每日新词量（F-D 导入词本后的弹框口径）：
 * 只更新设置并重排「未首学」新词的未来排期——
 * 与 applyDailyNewCount 的区别：不回退今天已学的词、不删除当天打卡
 * （导入新书设定配额时不应影响用户今天在旧词本的学习成果）。
 */
export function setDailyNewCount(data: AppData, n: number, now: number): AppData {
  const today: string = dayKeyFromTs(now);
  const quota: number = clampDailyNew(n);
  const schedules: ReviewSchedule[] = data.schedules.map((s: ReviewSchedule): ReviewSchedule => {
    if (s.stage === 'NEW' && s.firstLearnDay === '') {
      // 逾期未学新词保留为今天到期
      if (s.dueDay !== '' && diffDays(s.dueDay, today) > 0) {
        return { ...s, dueDay: today };
      }
      // 未来排期清空，按新额度重排
      if (s.dueDay !== '' && diffDays(today, s.dueDay) > 0) {
        return { ...s, dueDay: '' };
      }
    }
    return s;
  });
  const replanned: ReviewSchedule[] =
    planNewWords(schedules, now, quota, activeScopeWordIds(data));
  return { ...data, schedules: replanned, settings: withDailyNew(data.settings, quota) };
}
