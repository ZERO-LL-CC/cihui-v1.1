/**
 * 词慧 · 全局数据仓库（F2）
 *
 * 状态管理 V2：@ObservedV2 + @Trace，UI 直接绑定本单例的数组/设置；
 * 所有增删改先在 RepoCore / SchedulerCore 纯函数里完成（可单测、可复算），
 * 再整体替换回 @Trace 字段触发刷新。
 *
 * 本期按用户要求使用内存数组作为临时仓库（前端自闭环，无需后端即可演示）。
 * TODO(F15)：实现 Persistence 接口，结构化数据接 @kit.ArkData relationalStore，
 *           设置接 preferences；每次判定后实时落盘，杀进程不丢。
 *           云备份走 SyncService（本地 JSON 导出导入先跑通）。
 */

import type {
  BookSource,
  CheckInRecord,
  IntakeMode,
  LearnPhase,
  MemeCard,
  MemeSentence,
  ReviewSchedule,
  RoundVerdict,
  SavedSentence,
  Settings,
  StudyRecord,
  StudySession,
  Verdict,
  Word,
  WordBook,
} from '../model/Types';
import {
  addBook,
  addWord,
  applyDailyNewCount,
  applyJudgeToData,
  batchDeleteWords,
  buildMakeupGroups,
  canMakeup,
  cloneData,
  completeMakeup as completeMakeupData,
  deleteBook,
  deleteWord,
  emptyData,
  importCloudBook,
  importTransaction,
  activeScopeWordIds,
  removeWrongFromData,
  renameBook,
  setDailyNewCount,
  switchActiveBookData,
  todayGateStatus,
  updateWord,
  upsertCheckin,
} from '../model/RepoCore';
import type {
  AppData,
  ApplyJudgeResult,
  BookDraft,
  CloudBookImport,
  CloudWordInput,
  MakeupEligibility,
  MakeupGroup,
  WordDraft,
} from '../model/RepoCore';
import type { CloudSampleWord } from '../service/CloudCatalog';
import {
  buildDayPlan,
  buildHomeStats,
  buildMonthGrid,
  buildProfileStats,
  buildWrongEntries,
  clampDailyNew,
  computeStreak,
  dayKeyFromTs,
  markFirstStudy,
  p3Info,
  previewDailyNew,
} from '../model/SchedulerCore';
import type {
  DailyNewPreview,
  HomeStats,
  JudgeResult,
  MonthGrid,
  P3Info,
  ProfileStats,
  SchedulerState,
  WrongEntry,
} from '../model/SchedulerCore';
import type { DayGateStatus } from '../model/RepoCore';
import { genId } from '../model/RepoCore';
import {
  advanceSession,
  buildCandidates,
  bumpMemeCardShareInto,
  createMemeImport,
  createRestudySession,
  findResumableSession,
  removeMemeCardInto,
  sessionPendingCount,
  sortMemeCardsDesc,
  toggleMemeCardFavoriteInto,
  tokenizeEnglish,
  upsertMemeCardInto,
} from '../model/MemeCore';
import type { MemeCandidate } from '../model/MemeCore';
import { collectTodayWordIds, joinWordsByIds } from '../model/SentenceCore';
import { REFRESH_BUS } from '../common/RefreshBus';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalStateFiles } from '../service/LocalStateFiles';

/** 持久化接口（F15 落地；当前为内存实现） */
export interface Persistence {
  save(data: AppData): void;
  load(): AppData | null;
}

/** F17 导入梗句后返回的跳转句柄 */
export interface MemeStartInfo {
  memeId: string;
  sessionId: string;
}

/** F17 一次会话判定后的页面所需信息 */
export interface MemeAdvanceInfo {
  completed: boolean;
  knownCount: number;
  total: number;
  memeId: string;
}

/** F18 落梗卡入参 */
export interface MemeCardInput {
  memeId: string;
  cardImagePath: string;
  masteredCount: number;
  totalCount: number;
  unlockedDay: string;
}

class MemoryPersistence implements Persistence {
  private cache: AppData | null = null;
  save(data: AppData): void {
    // 内存快照：用于“杀进程恢复”的本地模拟测试；F15 替换为 JSON 文件/relationalStore
    this.cache = cloneData(data);
  }
  load(): AppData | null {
    return this.cache ? cloneData(this.cache) : null;
  }
}

/** qa19 BUG-B：沙箱 JSON 自动落盘，杀进程/重开不丢；写盘失败静默降级内存 */
class FilePersistence implements Persistence {
  private static readonly FILE: string = 'data.json';
  private readonly memory: MemoryPersistence = new MemoryPersistence();

  save(data: AppData): void {
    this.memory.save(data);
    // 性能埋点：真机定位「每次判定全量落盘」的实际耗时（stringify 与 write 分开计时）
    const t0: number = Date.now();
    const json: string = JSON.stringify(data);
    const t1: number = Date.now();
    LocalStateFiles.write(FilePersistence.FILE, json);
    const t2: number = Date.now();
    hilog.info(0x0000, 'CihuiIO',
      'save bytes=%{public}d stringify=%{public}dms write=%{public}dms',
      json.length, t1 - t0, t2 - t1);
  }

  load(): AppData | null {
    const raw: string | null = LocalStateFiles.read(FilePersistence.FILE);
    if (raw !== null) {
      try {
        return JSON.parse(raw) as AppData;
      } catch (_e) {
        // 损坏文件不阻断启动，落回内存空仓
      }
    }
    return this.memory.load();
  }
}

@ObservedV2
export class DataStore {
  static readonly INSTANCE: DataStore = new DataStore();
  private persistence: Persistence = new MemoryPersistence();
  // data 必须可观察：homeStats/streak/gatesToday 等派生方法全部读它，
  // 否则 commit 整体替换后，只在 build 中调用派生方法的页面收不到刷新（动态QA BUG-02）
  @Trace private data: AppData = emptyData();

  @Trace books: WordBook[] = [];
  @Trace words: Word[] = [];
  @Trace schedules: ReviewSchedule[] = [];
  @Trace records: StudyRecord[] = [];
  @Trace checkins: CheckInRecord[] = [];
  @Trace settings: Settings = this.data.settings;
  /** F17 梗句 / 会话，F18 梗卡，F19 收藏例句（V2 发布数组） */
  @Trace memes: MemeSentence[] = [];
  @Trace sessions: StudySession[] = [];
  @Trace memeCards: MemeCard[] = [];
  @Trace savedSentences: SavedSentence[] = [];

  /** 旧版本 data.json 缺 F17–F19 新集合时补空数组，避免页面读 undefined */
  private normalize(d: AppData): AppData {
    const out: AppData = d;
    if (out.memes === undefined) {
      out.memes = [];
    }
    if (out.sessions === undefined) {
      out.sessions = [];
    }
    if (out.memeCards === undefined) {
      out.memeCards = [];
    }
    if (out.savedSentences === undefined) {
      out.savedSentences = [];
    }
    // F-D：旧数据 settings 缺 activeBookId 补空；指向已删除词本时清空
    if (out.settings !== undefined && out.settings.activeBookId === undefined) {
      out.settings.activeBookId = '';
    }
    if (out.settings !== undefined && out.settings.activeBookId !== ''
      && out.settings.activeBookId.length > 0
      && !out.books.some((b: WordBook): boolean => b.id === out.settings.activeBookId)) {
      out.settings.activeBookId = '';
    }
    return out;
  }

  private constructor() {
    const restored: AppData | null = this.persistence.load();
    if (restored) {
      this.data = this.normalize(restored);
      this.publish();
    }
  }

  /** qa19 BUG-B：EntryAbility.onCreate 调用，切换为沙箱文件持久化并读回本机数据 */
  attachContext(context: common.Context): void {
    LocalStateFiles.boot(context);
    this.persistence = new FilePersistence();
    const restored: AppData | null = this.persistence.load();
    if (restored) {
      this.data = this.normalize(restored);
      this.publish();
    }
  }

  /** 统一提交：替换内存数据 → 持久化 → 发布给 UI */
  private commit(next: AppData): void {
    this.data = next;
    this.persistence.save(next);
    this.publish();
    REFRESH_BUS.emitData();
  }

  private publish(): void {
    this.books = this.data.books;
    this.words = this.data.words;
    this.schedules = this.data.schedules;
    this.records = this.data.records;
    this.checkins = this.data.checkins;
    this.settings = this.data.settings;
    this.memes = this.data.memes;
    this.sessions = this.data.sessions;
    this.memeCards = this.data.memeCards;
    this.savedSentences = this.data.savedSentences;
  }

  /* ---------- 词本 ---------- */

  addBook(name: string, source: BookSource, cloudBookId?: string): void {
    const draft: BookDraft = { name, source, cloudBookId };
    this.commit(addBook(this.data, draft, Date.now()));
  }

  renameBook(bookId: string, name: string): void {
    this.commit(renameBook(this.data, bookId, name));
  }

  deleteBook(bookId: string): void {
    this.commit(deleteBook(this.data, bookId));
  }

  /* ---------- 单词 ---------- */

  addWord(draft: WordDraft): void {
    // addWord 内部已统一排期，保证首页数字同源
    this.commit(addWord(this.data, draft, Date.now()));
  }

  updateWord(wordId: string, patch: Partial<WordDraft>): void {
    this.commit(updateWord(this.data, wordId, patch));
  }

  deleteWord(wordId: string): void {
    this.commit(deleteWord(this.data, wordId));
  }

  batchDeleteWords(wordIds: string[]): void {
    this.commit(batchDeleteWords(this.data, wordIds));
  }

  /** 按 id 取词（梗句确认页复用已有词的释义，避免重复查词典） */
  wordById(wordId: string): Word | null {
    const found: Word | undefined =
      this.data.words.find((w: Word): boolean => w.id === wordId);
    return found ?? null;
  }

  /** OCR 确认导入 / 云词书下载：单次事务，失败不产生半截数据。
   *  F-A intake：'QUEUE'=加入词本按每日新词量排队（默认）；'TODAY'=加入当天计划立即首学不占配额。 */
  importWords(drafts: WordDraft[], intake: IntakeMode = 'QUEUE'): void {
    this.commit(importTransaction(this.data, drafts, Date.now(), intake));
  }

  /** F5 云词书下载导入：建 CLOUD 词本 + 整批导入单次事务，重复下载抛错 */
  importCloudBook(name: string, cloudBookId: string, words: CloudSampleWord[]): void {
    const inputWords: CloudWordInput[] = words.map((w: CloudSampleWord): CloudWordInput => {
      const item: CloudWordInput = { english: w.english, phonetic: w.phonetic, meaning: w.meaning };
      return item;
    });
    const draft: CloudBookImport = { name, cloudBookId, words: inputWords };
    this.commit(importCloudBook(this.data, draft, Date.now()));
  }

  /** F5 云词书是否已导入（幂等：已导入的词书详情页显示「已导入」） */
  isCloudBookImported(cloudBookId: string): boolean {
    return this.data.books.some((b: WordBook): boolean => b.cloudBookId === cloudBookId);
  }

  /** F5 某词本下的单词数（词本卡片实时统计，与首页/打卡同源） */
  wordCountOfBook(bookId: string): number {
    return this.data.words.filter((w: Word): boolean => w.bookId === bookId).length;
  }

  /* ---------- F-D 单词本限制（一次只能背一本） ---------- */

  /** 当前背诵中的词本 id（''=未设置，全部词本可排期） */
  activeBookId(): string {
    return this.data.settings.activeBookId ?? '';
  }

  /** 某词本剩余未首学的新词数（切书确认框用） */
  unlearnedCountOfBook(bookId: string): number {
    const ids: Set<string> = new Set();
    for (const w of this.data.words) {
      if (w.bookId === bookId) {
        ids.add(w.id);
      }
    }
    return this.data.schedules.filter((s: ReviewSchedule): boolean =>
      ids.has(s.wordId) && s.stage === 'NEW' && s.firstLearnDay === '').length;
  }

  /** 某词本是否为当前背诵中的词本（我的词本页「背诵中」徽章） */
  isBookLearning(bookId: string): boolean {
    return this.activeBookId() === bookId;
  }

  /**
   * F-D 切换背诵中的词本（我的词本页 / 云书详情「切换」入口）。
   * 旧词本未首学新词暂停排期，新词本被暂停的新词立即重排；已学复习义务两本都不受影响。
   */
  switchActiveBook(bookId: string): void {
    this.commit(switchActiveBookData(this.data, bookId, Date.now()));
  }

  /** 按 id 取词本（切换后取名字做提示） */
  bookById(bookId: string): WordBook | null {
    const found: WordBook | undefined =
      this.data.books.find((b: WordBook): boolean => b.id === bookId);
    return found ?? null;
  }

  /** 导入词本后的弹框口径：设置每日新词量并重排未学新词（不动今日已学与打卡） */
  setDailyNew(n: number): void {
    this.commit(setDailyNewCount(this.data, n, Date.now()));
  }

  /* ---------- 学习判定（语音自动与手动闪卡共用） ---------- */

  applyJudge(wordId: string, phase: LearnPhase, verdict: Verdict): JudgeResult {
    const out: ApplyJudgeResult =
      applyJudgeToData(this.data, wordId, phase, verdict, Date.now());
    this.commit(out.data);
    return out.result;
  }

  /**
   * F8 一轮语音快过结束（含复核改判）后，一次性落 FIRST 判定。
   * 判定在复核确认前只存页面内存，确认时按最终三档结果逐词应用，避免中途改判造成多次调度。
   */
  applyFirstRound(items: RoundVerdict[]): void {
    let data: AppData = cloneData(this.data);
    const now: number = Date.now();
    items.forEach((item: RoundVerdict): void => {
      if (item.verdict === null) {
        return;
      }
      const out: ApplyJudgeResult = applyJudgeToData(data, item.wordId, 'FIRST', item.verdict, now);
      data = out.data;
    });
    this.commit(data);
  }

  /* ---------- F10 错词本 ---------- */

  /** 错词本条目（派生：status=WRONG 或模糊强制次日复习），按到期日升序 */
  wrongEntries(): WrongEntry[] {
    const state: SchedulerState = {
      schedules: this.data.schedules,
      records: this.data.records,
      settings: this.data.settings,
    };
    return buildWrongEntries(state);
  }

  /** 从错词本移出（不做强化）：恢复普通学习/复习流程，首页角标同源减少 */
  removeWrong(wordId: string): void {
    this.commit(removeWrongFromData(this.data, wordId));
  }

  /* ---------- 设置 ---------- */

  updateSettings(patch: Partial<Settings>): void {
    // ArkTS 限制标准库与对象展开：克隆后逐字段合并设置
    const next: AppData = cloneData(this.data);
    if (patch.dailyNewCount !== undefined) {
      next.settings.dailyNewCount = clampDailyNew(patch.dailyNewCount);
    }
    if (patch.shortReviewEnabled !== undefined) {
      next.settings.shortReviewEnabled = patch.shortReviewEnabled;
    }
    if (patch.p3Strict !== undefined) {
      next.settings.p3Strict = patch.p3Strict;
    }
    if (patch.ttsRate !== undefined) {
      next.settings.ttsRate = patch.ttsRate;
    }
    if (patch.asrStrictness !== undefined) {
      next.settings.asrStrictness = patch.asrStrictness;
    }
    if (patch.hapticEnabled !== undefined) {
      next.settings.hapticEnabled = patch.hapticEnabled;
    }
    if (patch.reminderEnabled !== undefined) {
      next.settings.reminderEnabled = patch.reminderEnabled;
    }
    this.commit(next);
  }

  /* ---------- 首页今日任务（F6，与打卡页/个人页同源） ---------- */

  homeStats(): HomeStats {
    const day: string = dayKeyFromTs(Date.now());
    return buildHomeStats(
      { schedules: this.data.schedules, records: this.data.records, settings: this.data.settings },
      day,
    );
  }

  /** F7 今日新词列表（与首页 NEW 桶、打卡前置同源，顺序取 buildDayPlan） */
  todayNewWordList(): Word[] {
    const day: string = dayKeyFromTs(Date.now());
    const state: SchedulerState = {
      schedules: this.data.schedules,
      records: this.data.records,
      settings: this.data.settings,
    };
    const ids: string[] = buildDayPlan(state, day).newWords;
    const out: Word[] = [];
    ids.forEach((id: string): void => {
      const w: Word | undefined = this.data.words.find((x: Word): boolean => x.id === id);
      if (w !== undefined) {
        out.push(w);
      }
    });
    return out;
  }

  /**
   * F9 今日到期复习词列表（五桶 R1/R2/R4/R7/R15 按节点顺序摊平；逾期词本就包含在桶内）。
   * 与首页六桶、打卡 P2 前置同源。
   */
  todayReviewWordList(): Word[] {
    const day: string = dayKeyFromTs(Date.now());
    const state: SchedulerState = {
      schedules: this.data.schedules,
      records: this.data.records,
      settings: this.data.settings,
    };
    const plan = buildDayPlan(state, day);
    const ids: string[] = [];
    const stages: string[] = ['R1', 'R2', 'R4', 'R7', 'R15'];
    stages.forEach((stage: string): void => {
      plan.reviewBuckets[stage].forEach((id: string): void => {
        if (ids.indexOf(id) < 0) {
          ids.push(id);
        }
      });
    });
    const out: Word[] = [];
    ids.forEach((id: string): void => {
      const w: Word | undefined = this.data.words.find((x: Word): boolean => x.id === id);
      if (w !== undefined) {
        out.push(w);
      }
    });
    return out;
  }

  /** F7 整批浏览完成：记录首学时间 firstStudyAt（首过 firstPassedAt 仍等 F8 语音测试） */
  markBatchFirstStudied(wordIds: string[]): void {
    if (wordIds.length === 0) {
      return;
    }
    const next: AppData = cloneData(this.data);
    const now: number = Date.now();
    wordIds.forEach((id: string): void => {
      const idx: number = next.records.findIndex((r: StudyRecord): boolean => r.wordId === id);
      if (idx >= 0) {
        next.records[idx] = markFirstStudy(next.records[idx], now);
      }
    });
    this.commit(next);
  }

  streak(): number {
    return computeStreak(this.data.checkins, dayKeyFromTs(Date.now()));
  }

  /** F13 个人页六宫格统计（与首页、打卡页同源） */
  profileStats(): ProfileStats {
    const day: string = dayKeyFromTs(Date.now());
    const state: SchedulerState = {
      schedules: this.data.schedules,
      records: this.data.records,
      settings: this.data.settings,
    };
    return buildProfileStats(state, this.data.checkins, day, this.data.words.length);
  }

  isCheckedInToday(): boolean {
    const day: string = dayKeyFromTs(Date.now());
    return this.data.checkins.some((c: CheckInRecord): boolean => c.day === day && c.checkedIn);
  }

  /* ---------- 打卡 ---------- */

  gatesToday(): DayGateStatus {
    return todayGateStatus(this.data, Date.now());
  }

  /** F11：P3 错词强化排期（是否轮到 / 下次轮到日期） */
  p3Today(): P3Info {
    return p3Info(this.data, dayKeyFromTs(Date.now()));
  }

  checkInToday(): void {
    const day: string = this.gatesToday().day;
    this.commit(upsertCheckin(this.data, day, Date.now(), false));
  }

  makeupCheckin(day: string): void {
    this.commit(upsertCheckin(this.data, day, Date.now(), true));
  }

  /* ---------- F12 计划大表 / 补卡 / 每日新词量 ---------- */

  /** F12 月历大表（与打卡页小日历同源；month 为 1–12） */
  monthGrid(year: number, month: number): MonthGrid {
    const day: string = dayKeyFromTs(Date.now());
    const state: SchedulerState = {
      schedules: this.data.schedules,
      records: this.data.records,
      settings: this.data.settings,
    };
    return buildMonthGrid(state, this.data.checkins, year, month, day);
  }

  /** F12 补卡日待补任务分组 */
  makeupGroups(day: string): MakeupGroup[] {
    return buildMakeupGroups(this.data, day);
  }

  /** F12 补卡资格（严格顺序） */
  makeupEligibility(day: string): MakeupEligibility {
    return canMakeup(this.data, day, Date.now());
  }

  /** F12 补卡词本过完：判认识推进调度 + 写入补卡记录（不恢复连续） */
  completeMakeup(day: string): void {
    this.commit(completeMakeupData(this.data, day, Date.now()));
  }

  /** F12 每日新词量滚轮实时预览（不落数据） */
  previewDailyNew(n: number): DailyNewPreview {
    const state: SchedulerState = {
      schedules: this.data.schedules,
      records: this.data.records,
      settings: this.data.settings,
    };
    return previewDailyNew(state, n, Date.now(), activeScopeWordIds(this.data));
  }

  /** F12 确定每日新词量：重置当日完成态、重排未来新词，历史不篡改 */
  applyDailyNew(n: number): void {
    this.commit(applyDailyNewCount(this.data, n, Date.now()));
  }

  /* ---------- F17 梗句导入与背诵 ---------- */

  /** 英文句子 → 拆词 → 与现有词库比对的确认页候选 */
  memeCandidates(english: string): MemeCandidate[] {
    const tokens: string[] = tokenizeEnglish(english);
    return buildCandidates(tokens, this.data.words, this.data.schedules);
  }

  /**
   * 导入梗句并创建首场背诵会话（单次事务）。
   * 返回 memeId / sessionId 供页面直接跳转。
   */
  importMeme(chinese: string, english: string, candidates: MemeCandidate[]): MemeStartInfo {
    const out = createMemeImport(this.data, { chinese, english, candidates }, Date.now());
    this.commit(out.data);
    return { memeId: out.meme.id, sessionId: out.session.id };
  }

  memeById(memeId: string): MemeSentence | null {
    const found: MemeSentence | undefined = this.data.memes.find((m: MemeSentence): boolean => m.id === memeId);
    return found ?? null;
  }

  /** F5 梗句词本卡片点击：由 bookId 找梗句 */
  memeByBook(bookId: string): MemeSentence | null {
    const found: MemeSentence | undefined =
      this.data.memes.find((m: MemeSentence): boolean => m.bookId === bookId);
    return found ?? null;
  }

  sessionById(sessionId: string): StudySession | null {
    const found: StudySession | undefined =
      this.data.sessions.find((s: StudySession): boolean => s.id === sessionId);
    return found ?? null;
  }

  /** 续背：找指定梗句（或全局）最近一场未完成会话 */
  resumableSession(memeId?: string): StudySession | null {
    return findResumableSession(this.data, memeId);
  }

  /** 再背一遍：同梗句全部词重新洗牌建新会话 */
  restudyMeme(memeId: string): string {
    const meme: MemeSentence | null = this.memeById(memeId);
    if (meme === null) {
      throw new Error('梗句不存在');
    }
    const out = createRestudySession(this.data, meme, Date.now());
    this.commit(out.data);
    return out.session.id;
  }

  /**
   * 判定梗句会话中的一个词并落盘（新词走 F2 首测；学习中词只进会话不改排期）。
   * 返回是否完成、本轮认识数与总会话词数，供页面决定飞出/重插/完成弹卡。
   */
  advanceMemeSession(sessionId: string, wordId: string, verdict: Verdict): MemeAdvanceInfo {
    const out = advanceSession(this.data, sessionId, wordId, verdict, Date.now());
    this.commit(out.data);
    const total: number = out.session.items.length;
    return {
      completed: out.completed,
      knownCount: out.knownCount,
      total,
      memeId: out.session.memeId,
    };
  }

  /** 会话剩余未背词数（F20 蓝点副标题用） */
  memePendingCount(memeId: string): number {
    const s: StudySession | null = findResumableSession(this.data, memeId);
    return s === null ? 0 : sessionPendingCount(s);
  }

  /** 是否存在任意进行中的梗句会话（F20 梗句入口蓝点） */
  hasMemeInProgress(): boolean {
    return findResumableSession(this.data) !== null;
  }

  /* ---------- F18 梗卡片 ---------- */

  /**
   * 背完一场会话后落/更新梗卡：同梗句多次背完只留一张，随最新结果更新。
   * cardImagePath 为空串表示 Canvas 失败的纯文字降级卡。
   */
  upsertMemeCard(input: MemeCardInput): MemeCard {
    const next: AppData = cloneData(this.data);
    const result = upsertMemeCardInto(next.memeCards, {
      memeId: input.memeId,
      cardImagePath: input.cardImagePath,
      masteredCount: input.masteredCount,
      totalCount: input.totalCount,
      unlockedDay: input.unlockedDay,
    }, Date.now());
    next.memeCards = result.cards;
    this.commit(next);
    return result.card;
  }

  /** 梗卡册：按解锁时间倒序 */
  memeCardAlbum(): MemeCard[] {
    return sortMemeCardsDesc(this.data.memeCards);
  }

  /** 收藏 / 取消收藏梗卡 */
  toggleMemeCardFavorite(cardId: string): void {
    const next: AppData = cloneData(this.data);
    next.memeCards = toggleMemeCardFavoriteInto(next.memeCards, cardId);
    this.commit(next);
  }

  /** 分享成功后计数 +1 */
  bumpMemeCardShare(cardId: string): void {
    const next: AppData = cloneData(this.data);
    next.memeCards = bumpMemeCardShareInto(next.memeCards, cardId);
    this.commit(next);
  }

  /** 左滑删除梗卡（只删卡，不删学习记录） */
  deleteMemeCard(cardId: string): void {
    const next: AppData = cloneData(this.data);
    next.memeCards = removeMemeCardInto(next.memeCards, cardId);
    this.commit(next);
  }

  /* ---------- F19 今日例句 ---------- */

  /** 今日已学新词 + 今日已复习词（去重保序），例句功能唯一词源，不碰未学词 */
  todayWords(today: string): Word[] {
    const ids: string[] = collectTodayWordIds(this.data.records, this.data.schedules, today);
    return joinWordsByIds(this.data.words, ids);
  }

  /* ---------- F19 收藏例句（我的例句本） ---------- */

  /** 收藏例句；同英文句已收藏则返回 false（幂等不重复） */
  saveSentence(sentence: string, translation: string, words: string[], sourceDay: string): boolean {
    const exists: boolean =
      this.data.savedSentences.some((s: SavedSentence): boolean => s.sentence === sentence);
    if (exists) {
      return false;
    }
    const next: AppData = cloneData(this.data);
    const item: SavedSentence = {
      id: genId('sentence'),
      sentence,
      translation,
      words,
      sourceDay,
      savedAt: Date.now(),
    };
    next.savedSentences = [...next.savedSentences, item];
    this.commit(next);
    return true;
  }

  savedSentenceList(): SavedSentence[] {
    return this.data.savedSentences.slice().sort((a: SavedSentence, b: SavedSentence): number =>
      b.savedAt - a.savedAt);
  }

  isSentenceSaved(sentence: string): boolean {
    return this.data.savedSentences.some((s: SavedSentence): boolean => s.sentence === sentence);
  }

  deleteSavedSentence(id: string): void {
    const next: AppData = cloneData(this.data);
    next.savedSentences = next.savedSentences.filter((s: SavedSentence): boolean => s.id !== id);
    this.commit(next);
  }

  /* ---------- 备份 / 恢复（F15 本地 JSON 闭环先用） ---------- */

  snapshot(): string {
    return JSON.stringify(this.data);
  }

  restore(json: string): void {
    const parsed: AppData = JSON.parse(json) as AppData;
    this.commit(parsed);
  }

  /** 退出登录：清空本机学习数据（P4/P5）。
   *  本期为纯前端内存仓库、无后端账号体系，学习数据不随账号隔离，
   *  退出即清空，新账号空起步；用户可先在「备份与恢复」导出 JSON。 */
  resetLearningData(): void {
    this.commit(emptyData());
  }

  /** 测试辅助：清空全部数据（页面不暴露入口） */
  resetForTest(): void {
    this.commit(emptyData());
  }
}
