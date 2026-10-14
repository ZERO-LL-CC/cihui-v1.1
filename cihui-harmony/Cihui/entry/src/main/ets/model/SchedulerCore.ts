/**
 * 词慧 · 艾宾浩斯调度器（F2）——纯逻辑，无 ArkUI/系统 API 依赖，可被 Node 直接运行测试。
 *
 * 规则口径（提示词包 F2，必须逐条一致）：
 * 1. 长期节点 R1/R2/R4/R7/R15 = 首学后第 1/2/4/7/15 天；短时 S1/S2/S3 = 当天 5 分/30 分/12 时，默认关。
 * 2. 新词首过判认识 → 次日 R1 到期；复习判认识 → 推进下一节点；R15 仍认识 → 已掌握，退出每日队列。
 * 3. 判模糊 → 停留当前节点，本轮末尾循环重考，且强制加入次日复习。
 * 4. 判不认识 → 节点清零，次日作为新词重新首学，并写入错词本（带原因标签）。
 * 5. 当天所有到期桶 100% 过完才 P2 达标；当日新词 100% 首学 + 首过才 P1 达标。
 * 6. 自动判定与手动判定共用本调度；改判后立即重算（重新调用 judge 即可，状态只保存在返回值里）。
 */

import {
  DEFAULT_SETTINGS,
  SHORT_NODE_MS,
  STAGE_OFFSET_DAYS,
  STAGE_ORDER,
  WRONG_REASON_UNKNOWN,
  WRONG_REASON_VAGUE,
} from './Types';
import type {
  AsrStrictness,
  CheckInRecord,
  LearnPhase,
  ReviewSchedule,
  Settings,
  StageCode,
  StudyRecord,
  Verdict,
  WordStatus,
} from './Types';

/** 调度器只读状态：所有复算函数都从这份状态推导，保证幂等可重算 */
export interface SchedulerState {
  schedules: ReviewSchedule[];
  records: StudyRecord[];
  settings: Settings;
}

/** 一次判定的结果（纯函数：不修改入参，返回新对象 + 副作用标记） */
export interface JudgeResult {
  schedule: ReviewSchedule;
  record: StudyRecord;
  /** 是否需要写入错词本（不认识 / 模糊都进错词本，原因标签不同） */
  wrongAdded: boolean;
  /** 错词原因标签 */
  wrongReason: string;
}

/** 当日学习桶（首页六桶 + 新词桶 + 错词桶的数据源） */
export interface DayPlan {
  /** 今日新词（含逾期未首学的新词） */
  newWords: string[];
  /** 各长期复习桶到期单词 */
  reviewBuckets: Record<string, string[]>;
  /** 逾期复习单词（dueDay 早于今天，仍计入对应桶，首页单独显逾期条） */
  overdue: string[];
  /** 错词强化单词 */
  wrongWords: string[];
}

export function defaultState(): SchedulerState {
  return { schedules: [], records: [], settings: { ...DEFAULT_SETTINGS } };
}

/* ================= 日期工具（本地时区，yyyy-mm-dd） ================= */

function pad2(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}

export function dayKeyFromTs(ts: number): string {
  const d: Date = new Date(ts);
  return d.getFullYear().toString() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}

export function todayKey(now: number): string {
  return dayKeyFromTs(now);
}

/** 日期加减天数 */
export function addDays(day: string, n: number): string {
  const parts: string[] = day.split('-');
  const d: Date = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  d.setDate(d.getDate() + n);
  return d.getFullYear().toString() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}

/** 两个日键相差天数（b - a） */
export function diffDays(a: string, b: string): number {
  const pa: string[] = a.split('-');
  const pb: string[] = b.split('-');
  const da: Date = new Date(Number(pa[0]), Number(pa[1]) - 1, Number(pa[2]));
  const db: Date = new Date(Number(pb[0]), Number(pb[1]) - 1, Number(pb[2]));
  return Math.round((db.getTime() - da.getTime()) / (24 * 60 * 60 * 1000));
}

/* ================= 记录 / 调度构造 ================= */

export function newStudyRecord(wordId: string): StudyRecord {
  return {
    wordId,
    firstStudyAt: 0,
    firstPassedAt: 0,
    s1DoneAt: 0,
    s2DoneAt: 0,
    s3DoneAt: 0,
    lastStudyDay: '',
  };
}

/**
 * 单词刚导入（OCR 校对入库 / 云词书导入 / DIY 新增）后的调度：
 * NEW 且未排期（dueDay 为空），由 planNewWordsForDay 按每日新词量统一分配首学日。
 */
export function newImportedSchedule(wordId: string): ReviewSchedule {
  return {
    wordId,
    stage: 'NEW',
    firstLearnDay: '',
    dueDay: '',
    status: 'LEARNING',
    forceNextDay: false,
    roundRequeue: false,
    wrongReason: '',
    lastVerdictAt: 0,
  };
}

/** 开始首学（F7 浏览开始时写 firstStudyAt，杀进程不丢由落盘层保证） */
export function markFirstStudy(record: StudyRecord, now: number): StudyRecord {
  if (record.firstStudyAt > 0) {
    return record;
  }
  return { ...record, firstStudyAt: now, lastStudyDay: dayKeyFromTs(now) };
}

/* ================= 核心判定 ================= */

function nextStage(stage: StageCode): StageCode {
  const i: number = STAGE_ORDER.indexOf(stage);
  // R15 的下一节点在调用处判 MASTERED；NEW 的下一节点是 R1
  return STAGE_ORDER[Math.min(i + 1, STAGE_ORDER.length - 1)];
}

/**
 * 三档判定（自动语音判定与手动闪卡判定共用同一入口）。
 * @param schedule 单词当前调度
 * @param record   单词学习记录
 * @param phase    FIRST=新词首测，REVIEW=到期复习
 * @param verdict  认识 / 模糊 / 不认识
 * @param now      当前时间戳
 */
export function judge(
  schedule: ReviewSchedule,
  record: StudyRecord,
  phase: LearnPhase,
  verdict: Verdict,
  now: number,
): JudgeResult {
  const day: string = dayKeyFromTs(now);
  const tomorrow: string = addDays(day, 1);

  if (verdict === 'KNOWN') {
    const base: ReviewSchedule = {
      ...schedule,
      forceNextDay: false,
      roundRequeue: false,
      wrongReason: '',
      lastVerdictAt: now,
    };
    const rec: StudyRecord = { ...record, lastStudyDay: day };

    if (phase === 'FIRST' || schedule.stage === 'NEW' || schedule.status === 'WRONG') {
      // 新词首过（含错词清零后次日重新首学通过）→ 次日 R1
      const firstLearnDay: string = day;
      return {
        schedule: {
          ...base,
          stage: 'R1',
          firstLearnDay,
          dueDay: addDays(firstLearnDay, STAGE_OFFSET_DAYS['R1']),
          status: 'LEARNING',
        },
        record: { ...rec, firstStudyAt: rec.firstStudyAt > 0 ? rec.firstStudyAt : now, firstPassedAt: now },
        wrongAdded: false,
        wrongReason: '',
      };
    }

    if (schedule.stage === 'R15') {
      // R15 仍认识 → 已掌握，退出每日队列
      return {
        schedule: { ...base, stage: 'MASTERED', dueDay: '', status: 'MASTERED' },
        record: rec,
        wrongAdded: false,
        wrongReason: '',
      };
    }

    // 复习认识 → 推进节点；到期日按首学日绝对偏移，但不早于明天（每天最多推进一个节点）
    const advanced: StageCode = nextStage(schedule.stage);
    const absoluteDue: string = addDays(schedule.firstLearnDay, STAGE_OFFSET_DAYS[advanced]);
    // absoluteDue 早于明天（明天 - absoluteDue > 0）时夹到明天
    const dueDay: string = diffDays(absoluteDue, tomorrow) > 0 ? tomorrow : absoluteDue;
    return {
      schedule: { ...base, stage: advanced, dueDay, status: 'LEARNING' },
      record: rec,
      wrongAdded: false,
      wrongReason: '',
    };
  }

  if (verdict === 'VAGUE') {
    // 模糊：停留当前节点 + 本轮末尾重考 + 强制次日复习（到期日一律改明天）；同时进错词本（F10 标签）
    return {
      schedule: {
        ...schedule,
        forceNextDay: true,
        roundRequeue: true,
        dueDay: tomorrow,
        wrongReason: WRONG_REASON_VAGUE,
        lastVerdictAt: now,
      },
      record: { ...record, lastStudyDay: day },
      wrongAdded: true,
      wrongReason: WRONG_REASON_VAGUE,
    };
  }

  // 不认识：节点清零，次日作为新词重新首学，写入错词本
  return {
    schedule: {
      ...schedule,
      stage: 'NEW',
      firstLearnDay: '',
      dueDay: tomorrow,
      status: 'WRONG',
      forceNextDay: false,
      roundRequeue: false,
      wrongReason: WRONG_REASON_UNKNOWN,
      lastVerdictAt: now,
    },
    record: {
      wordId: schedule.wordId,
      firstStudyAt: 0,
      firstPassedAt: 0,
      s1DoneAt: 0,
      s2DoneAt: 0,
      s3DoneAt: 0,
      lastStudyDay: day,
    },
    wrongAdded: true,
    wrongReason: WRONG_REASON_UNKNOWN,
  };
}

/** 模糊重考后判认识：清除本轮重队列标记（forceNextDay 保留到次日复习真正完成） */
export function clearRequeue(schedule: ReviewSchedule): ReviewSchedule {
  return { ...schedule, roundRequeue: false };
}

/* ================= 短时节点（默认关闭） ================= */

export function shortNodeDue(fromTs: number, node: string): number {
  return fromTs + (SHORT_NODE_MS[node] ?? 0);
}

/* ================= 新词排期（每日新词量 5–40） ================= */

export const MIN_DAILY_NEW: number = 5;
export const MAX_DAILY_NEW: number = 40;

export function clampDailyNew(n: number): number {
  if (n < MIN_DAILY_NEW) {
    return MIN_DAILY_NEW;
  }
  if (n > MAX_DAILY_NEW) {
    return MAX_DAILY_NEW;
  }
  return n;
}

/**
 * 把未排期（dueDay 为空）的 NEW 单词按每日新词量分配到从今天起的日期。
 * 导入后立即调用（F4：新词立即排期，首页数字同源刷新）。
 */
export function planNewWords(schedules: ReviewSchedule[], now: number, dailyNewCount: number): ReviewSchedule[] {
  const quota: number = clampDailyNew(dailyNewCount);
  const result: ReviewSchedule[] = schedules.map((s: ReviewSchedule) => ({ ...s }));
  let cursorDay: string = dayKeyFromTs(now);
  const remaining: () => number = (): number =>
    result.filter((s: ReviewSchedule): boolean => s.stage === 'NEW' && s.dueDay === cursorDay).length;

  for (let i = 0; i < result.length; i++) {
    const s: ReviewSchedule = result[i];
    if (s.stage !== 'NEW' || s.dueDay !== '') {
      continue;
    }
    while (remaining() >= quota) {
      cursorDay = addDays(cursorDay, 1);
    }
    s.dueDay = cursorDay;
  }
  return result;
}

/* ================= 当日学习桶 ================= */

const REVIEW_STAGES: StageCode[] = ['R1', 'R2', 'R4', 'R7', 'R15'];

export function buildDayPlan(state: SchedulerState, day: string): DayPlan {
  const newWords: string[] = [];
  const overdue: string[] = [];
  const buckets: Record<string, string[]> = { R1: [], R2: [], R4: [], R7: [], R15: [] };
  const wrongWords: string[] = [];

  for (const s of state.schedules) {
    if (s.status === 'WRONG') {
      wrongWords.push(s.wordId);
    }
    // 到期判定：diffDays(dueDay, day) = day - dueDay，>=0 表示到期日不晚于今天
    if (s.stage === 'NEW' && s.status === 'LEARNING' && s.dueDay !== '' && diffDays(s.dueDay, day) >= 0) {
      newWords.push(s.wordId);
    }
    if (s.status === 'LEARNING' && REVIEW_STAGES.indexOf(s.stage) >= 0 && s.dueDay !== ''
      && diffDays(s.dueDay, day) >= 0) {
      buckets[s.stage].push(s.wordId);
      if (diffDays(s.dueDay, day) > 0) {
        overdue.push(s.wordId);
      }
    }
  }
  return { newWords, reviewBuckets: buckets, overdue, wrongWords };
}

/* ================= 错词本（F10） ================= */

export type WrongKind = 'UNKNOWN' | 'VAGUE';

export interface WrongEntry {
  wordId: string;
  /** UNKNOWN=判不认识（清零、转明天新词）；VAGUE=模糊（停留节点、次日强制复习） */
  kind: WrongKind;
  /** 列表展示原因标签 */
  reason: string;
  /** 下次到期日（排序用） */
  dueDay: string;
}

/**
 * 错词本派生口径（无独立错词数组，全部由 schedule 状态派生）：
 * - status=WRONG：新词/复习中判「不认识」，清零转明天新词；
 * - status=LEARNING 且 forceNextDay 且 wrongReason 非空：判「模糊」后本轮未清账（如中途退出），
 *   次日强制复习。按到期日升序。
 */
export function buildWrongEntries(state: SchedulerState): WrongEntry[] {
  const out: WrongEntry[] = [];
  for (const s of state.schedules) {
    if (s.status === 'WRONG') {
      out.push({ wordId: s.wordId, kind: 'UNKNOWN', reason: '不认识 · 转明天新词', dueDay: s.dueDay });
    } else if (s.status === 'LEARNING' && s.forceNextDay && s.wrongReason !== '') {
      out.push({ wordId: s.wordId, kind: 'VAGUE', reason: '模糊 · 次日强制复习', dueDay: s.dueDay });
    }
  }
  out.sort((a: WrongEntry, b: WrongEntry): number => (a.dueDay < b.dueDay ? -1 : a.dueDay > b.dueDay ? 1 : 0));
  return out;
}

/* ================= 首页今日任务统计（F6，六桶/进度环/按钮三态同源） ================= */

export interface HomeStats {
  day: string;
  /** 今日分配的新词数（含已首过的，按 firstLearnDay=今天 或 NEW 到期统计） */
  newAssigned: number;
  /** 今日已首过的新词数 */
  newDone: number;
  /** 此刻仍到期未完成的复习词数（五桶之和） */
  reviewDue: number;
  /** 今日已判定推进的复习词数（已离开到期桶） */
  reviewDone: number;
  /** 今日任务总数（新词 + 复习，含已完成） */
  dueTotal: number;
  /** 已完成任务数 */
  doneTotal: number;
  /** 剩余任务数 */
  remaining: number;
  /** 完成比例 0..1（无任何单词时为 0，引导导入） */
  progress: number;
  /** 六桶实时数量：NEW/R1/R2/R4/R7/R15 */
  bucketCounts: Record<string, number>;
  /** 逾期复习词数 */
  overdueCount: number;
  /** 错词本词数（含 WRONG 状态） */
  wrongCount: number;
  /** 仓库里是否已有单词（首日引导用） */
  hasWords: boolean;
  /** 今日任务是否全部完成 */
  allDone: boolean;
}

/**
 * 首页/打卡/个人页唯一同源的今日任务统计。纯函数，可单测。
 * 注意：判定后单词会离开到期桶（dueDay 被推到未来 / stage 变 R1），
 * 因此“已完成”靠 firstPassedAt=今天 与 lastVerdictAt=今天且到期日已推后来还原。
 */
export function buildHomeStats(state: SchedulerState, day: string): HomeStats {
  const plan: DayPlan = buildDayPlan(state, day);

  const passedTodayIds: Set<string> = new Set();
  for (const r of state.records) {
    if (r.firstPassedAt > 0 && dayKeyFromTs(r.firstPassedAt) === day) {
      passedTodayIds.add(r.wordId);
    }
  }

  // 今日分配的新词：当前 NEW 到期 ∪ 今天刚首学/首过（已推进到 R1）的词
  const assignedIds: Set<string> = new Set(plan.newWords);
  for (const s of state.schedules) {
    if (s.firstLearnDay === day) {
      assignedIds.add(s.wordId);
    }
  }
  let newDone = 0;
  assignedIds.forEach((id: string) => {
    if (passedTodayIds.has(id)) {
      newDone += 1;
    }
  });

  // 今日已完成的复习：长期节点（今天之前首学）、今天判定过、到期日已被推到未来
  // （认识推进；模糊仍欠账不计；今天刚首过转 R1 的词归新词任务，不在此重复计数）
  let reviewDone = 0;
  for (const s of state.schedules) {
    if (s.status === 'LEARNING' && REVIEW_STAGES.indexOf(s.stage) >= 0
      && s.firstLearnDay !== day
      && !s.forceNextDay
      && s.lastVerdictAt > 0 && dayKeyFromTs(s.lastVerdictAt) === day
      && s.dueDay !== '' && diffDays(day, s.dueDay) > 0) {
      reviewDone += 1;
    }
  }

  const reviewDue: number = plan.reviewBuckets['R1'].length + plan.reviewBuckets['R2'].length
    + plan.reviewBuckets['R4'].length + plan.reviewBuckets['R7'].length
    + plan.reviewBuckets['R15'].length;

  const bucketCounts: Record<string, number> = {
    NEW: plan.newWords.length,
    R1: plan.reviewBuckets['R1'].length,
    R2: plan.reviewBuckets['R2'].length,
    R4: plan.reviewBuckets['R4'].length,
    R7: plan.reviewBuckets['R7'].length,
    R15: plan.reviewBuckets['R15'].length,
  };

  const newAssigned: number = assignedIds.size;
  const dueTotal: number = newAssigned + reviewDue + reviewDone;
  const doneTotal: number = newDone + reviewDone;
  const remaining: number = Math.max(0, dueTotal - doneTotal);
  const hasWords: boolean = state.schedules.length > 0;

  return {
    day,
    newAssigned,
    newDone,
    reviewDue,
    reviewDone,
    dueTotal,
    doneTotal,
    remaining,
    progress: dueTotal > 0 ? Math.min(1, doneTotal / dueTotal) : 0,
    bucketCounts,
    overdueCount: plan.overdue.length,
    wrongCount: buildWrongEntries(state).length,
    hasWords,
    allDone: hasWords && remaining === 0,
  };
}

/* ================= P3 错词强化（每 5 天一次，v1.2 口径，可配置） ================= */

export const P3_INTERVAL_DAYS: number = 5;

/**
 * 当天是否轮到错词强化：有错词，且距最早错词入本天数为 5 的整数倍（入本当天不安排）。
 * 口径为 v1.2 暂定（策略可配置，待用户拍板）。
 */
export function isP3Required(state: SchedulerState, day: string): boolean {
  // F13：打卡严格度 P3 开关关闭时，错词强化不再阻断打卡（设置默认开）
  if (state.settings && state.settings.p3Strict === false) {
    return false;
  }
  let anchor: string = '';
  for (const s of state.schedules) {
    if (s.status === 'WRONG' && s.lastVerdictAt > 0) {
      const d: string = dayKeyFromTs(s.lastVerdictAt);
      if (anchor === '' || diffDays(anchor, d) > 0) {
        anchor = d;
      }
    }
  }
  if (anchor === '') {
    return false;
  }
  const gap: number = diffDays(anchor, day);
  return gap > 0 && gap % P3_INTERVAL_DAYS === 0;
}

export interface P3Info {
  /** 今天是否轮到错词强化（阻断项） */
  required: boolean;
  /** 非轮到日时下次轮到的日期（无错词时为空串） */
  nextDay: string;
}

/**
 * P3 错词强化排期信息（F11 打卡页 ghost 行展示「下次轮到日期」用）。
 * 锚点口径与 isP3Required 完全一致。
 */
export function p3Info(state: SchedulerState, day: string): P3Info {
  let anchor: string = '';
  for (const s of state.schedules) {
    if (s.status === 'WRONG' && s.lastVerdictAt > 0) {
      const d: string = dayKeyFromTs(s.lastVerdictAt);
      if (anchor === '' || diffDays(anchor, d) > 0) {
        anchor = d;
      }
    }
  }
  if (anchor === '') {
    return { required: false, nextDay: '' };
  }
  const gap: number = diffDays(anchor, day);
  if (gap > 0 && gap % P3_INTERVAL_DAYS === 0) {
    return { required: true, nextDay: day };
  }
  const k: number = Math.floor(gap / P3_INTERVAL_DAYS) + 1;
  return { required: false, nextDay: addDays(anchor, k * P3_INTERVAL_DAYS) };
}

/* ================= 打卡前置达标复算（幂等） ================= */

export interface CheckinGateStatus {
  p1: boolean;
  p2: boolean;
  p3: boolean;
  p3Required: boolean;
}

/**
 * 用当天调度/记录状态重新复算 P1/P2/P3，重复计算结果不变。
 * P1：当日应学新词全部首学且首过（不认识清零转明天的词视为今日未过）。
 * P2：当日所有到期复习桶全部清空（没有 LEARNING 且到期日 <= 今天的复习词）。
 * P3：轮到日有错词强化任务时，错词全部清零（重学首过）。
 */
export function evaluateGates(state: SchedulerState, day: string): CheckinGateStatus {
  const plan: DayPlan = buildDayPlan(state, day);

  let p1: boolean = true;
  for (const s of state.schedules) {
    if (s.stage === 'NEW' && s.status === 'LEARNING' && s.dueDay !== '' && diffDays(s.dueDay, day) >= 0) {
      const rec: StudyRecord | undefined = state.records.find((r: StudyRecord): boolean => r.wordId === s.wordId);
      if (!rec || rec.firstPassedAt === 0 || dayKeyFromTs(rec.firstPassedAt) !== day) {
        p1 = false;
      }
    }
  }

  const p2: boolean = plan.reviewBuckets['R1'].length === 0
    && plan.reviewBuckets['R2'].length === 0
    && plan.reviewBuckets['R4'].length === 0
    && plan.reviewBuckets['R7'].length === 0
    && plan.reviewBuckets['R15'].length === 0;

  const p3Required: boolean = isP3Required(state, day);
  const p3: boolean = !p3Required || plan.wrongWords.length === 0;

  return { p1, p2, p3, p3Required };
}

/* ================= F13 个人页学习统计（与首页/打卡同源） ================= */

export interface ProfileStats {
  /** 累计导入单词总数 */
  totalImported: number;
  /** 学习中：已首学、未掌握、未在错词本（R1–R15 进行中） */
  learning: number;
  /** 已掌握（R15 毕业） */
  mastered: number;
  /** 错词本当前数量 */
  wrongCount: number;
  /** 连续打卡天数（补卡不恢复） */
  streak: number;
  /** 准时率 0–100：首个正常打卡日至今天的正常打卡占比；无打卡为 -1（页面显 –） */
  onTimeRate: number;
}

export function buildProfileStats(
  state: SchedulerState,
  checkins: CheckInRecord[],
  day: string,
  /** 词库总词数；导入但尚未排期的词也计入「累计导入」。缺省回退为排期数 */
  totalWords?: number,
): ProfileStats {
  let learning: number = 0;
  let mastered: number = 0;
  let wrongCount: number = 0;
  for (const s of state.schedules) {
    if (s.status === 'WRONG') {
      wrongCount += 1;
    } else if (s.stage === 'MASTERED') {
      mastered += 1;
    } else if (s.stage !== 'NEW') {
      learning += 1;
    }
  }
  const totalImported: number = totalWords !== undefined ? totalWords : state.schedules.length;
  const streak: number = computeStreak(checkins, day);

  let first: string = '';
  for (const c of checkins) {
    if (c.checkedIn && !c.makeup) {
      if (first === '' || diffDays(first, c.day) < 0) {
        first = c.day;
      }
    }
  }
  let onTimeRate: number = -1;
  if (first !== '') {
    const span: number = diffDays(first, day) + 1;
    let onTime: number = 0;
    for (const c of checkins) {
      if (c.checkedIn && !c.makeup
        && diffDays(first, c.day) >= 0 && diffDays(c.day, day) >= 0) {
        onTime += 1;
      }
    }
    onTimeRate = Math.round((onTime / span) * 100);
  }

  return { totalImported, learning, mastered, wrongCount, streak, onTimeRate };
}

/** 连续天数：只认真实打卡；补卡不恢复连续天数（开放项，默认口径） */
export function computeStreak(records: CheckInRecord[], day: string): number {
  const map: Map<string, CheckInRecord> = new Map();
  for (const r of records) {
    if (r.checkedIn && !r.makeup) {
      map.set(r.day, r);
    }
  }
  let streak: number = 0;
  let cursor: string = day;
  while (map.has(cursor)) {
    streak += 1;
    cursor = addDays(cursor, -1);
  }
  return streak;
}

/** 改设置：每日新词量夹取 5–40 */
export function withDailyNew(settings: Settings, n: number): Settings {
  return { ...settings, dailyNewCount: clampDailyNew(n) };
}

/* ================= F12 计划大表 / 果冻日历 / 每日新词量预览 ================= */

/** 某一天的一个计划标记（橙块=新学；彩点=复习节点） */
export interface PlannedDot {
  /** NEW / R1 / R2 / R4 / R7 / R15 */
  stage: string;
  count: number;
}

/** 月历单元格状态：未来 / 今天 / 已完成 / 待补卡（红） / 已补卡 */
export type CellState = 'future' | 'today' | 'done' | 'missed' | 'made';

export interface MonthCell {
  /** 日键 yyyy-mm-dd（非本月补位格也带日期，便于动画 key） */
  day: string;
  /** 日序号 1–31，非本月为 0 */
  dateNum: number;
  inMonth: boolean;
  state: CellState;
  /** 当天新学词数（橙块，>0 才显示） */
  newCount: number;
  /** 当天计划复习节点彩点（按 R1→R15 顺序） */
  dots: PlannedDot[];
}

export interface MonthGrid {
  year: number;
  /** 月份 1–12 */
  month: number;
  /** 6×7=42 格，周一为首列 */
  cells: MonthCell[];
  /** 当前连续打卡天数 */
  streak: number;
  /** 本月正常打卡完成天数（不含补卡） */
  monthDone: number;
  /** 全局待补卡天数（首个活跃日至昨天之间的红格数） */
  pendingMakeup: number;
  /** 首个活跃日（学习/打卡的最早日期），空串表示还没开始 */
  firstActive: string;
}

/**
 * 构建月历大表（与打卡页小日历同源）。
 * 计划点口径（纯由首学日推导，确定可重算）：
 * - 橙块：已首学词 firstLearnDay=当天；或已排期未学新词 dueDay=当天。
 * - R 彩点：每个已首学词按 firstLearnDay + 1/2/4/7/15 标出计划复习日（理想节点表，
 *   判错清零的词 firstLearnDay 被清空，不会留下残点；补卡/实际提前推后不改变计划表）。
 * 红格：今天之前、首个活跃日之后、没有任何打卡记录（含补卡）的日期。
 */
export function buildMonthGrid(
  state: SchedulerState,
  checkins: CheckInRecord[],
  year: number,
  month: number,
  today: string,
): MonthGrid {
  const newMap: Map<string, number> = new Map();
  const dotMap: Map<string, Map<string, number>> = new Map();

  const bumpNew = (day: string): void => {
    if (day === '') {
      return;
    }
    newMap.set(day, (newMap.get(day) ?? 0) + 1);
  };
  const bumpDot = (day: string, stage: string): void => {
    if (day === '') {
      return;
    }
    let m: Map<string, number> | undefined = dotMap.get(day);
    if (m === undefined) {
      m = new Map<string, number>();
      dotMap.set(day, m);
    }
    m.set(stage, (m.get(stage) ?? 0) + 1);
  };

  let firstActive: string = '';
  const considerActive = (day: string): void => {
    // diffDays(a,b)=b-a：day 比 firstActive 更早时 diffDays(firstActive,day) < 0
    if (day !== '' && (firstActive === '' || diffDays(firstActive, day) < 0)) {
      firstActive = day;
    }
  };

  for (const s of state.schedules) {
    if (s.firstLearnDay !== '') {
      bumpNew(s.firstLearnDay);
      considerActive(s.firstLearnDay);
      REVIEW_STAGES.forEach((stage: StageCode): void => {
        bumpDot(addDays(s.firstLearnDay, STAGE_OFFSET_DAYS[stage]), stage);
      });
    } else if (s.stage === 'NEW' && s.dueDay !== '') {
      bumpNew(s.dueDay);
      considerActive(s.dueDay);
    }
  }
  const checkinMap: Map<string, CheckInRecord> = new Map();
  for (const c of checkins) {
    checkinMap.set(c.day, c);
    considerActive(c.day);
  }

  // 42 格（周一为首列）
  const firstOfMonth: Date = new Date(year, month - 1, 1);
  const lead: number = (firstOfMonth.getDay() + 6) % 7;
  const gridStart: string = addDays(
    year + '-' + (month < 10 ? '0' + month : '' + month) + '-01',
    -lead,
  );

  const cells: MonthCell[] = [];
  for (let i = 0; i < 42; i++) {
    const day: string = addDays(gridStart, i);
    const parts: string[] = day.split('-');
    const dYear: number = Number(parts[0]);
    const dMonth: number = Number(parts[1]);
    const dDate: number = Number(parts[2]);
    const inMonth: boolean = dYear === year && dMonth === month;

    const dots: PlannedDot[] = [];
    const dm: Map<string, number> | undefined = dotMap.get(day);
    if (dm !== undefined) {
      REVIEW_STAGES.forEach((stage: StageCode): void => {
        const cnt: number = dm.get(stage) ?? 0;
        if (cnt > 0) {
          dots.push({ stage, count: cnt });
        }
      });
    }

    let cellState: CellState = 'future';
    const c: CheckInRecord | undefined = checkinMap.get(day);
    if (c !== undefined && c.makeup) {
      cellState = 'made';
    } else if (c !== undefined && c.checkedIn) {
      cellState = 'done';
    } else if (day === today) {
      cellState = 'today';
    } else if (diffDays(today, day) > 0) {
      cellState = 'future';
    } else if (firstActive !== '' && diffDays(firstActive, day) >= 0) {
      cellState = 'missed';
    } else {
      cellState = 'future';
    }

    cells.push({
      day,
      dateNum: inMonth ? dDate : 0,
      inMonth,
      state: cellState,
      newCount: newMap.get(day) ?? 0,
      dots,
    });
  }

  // 本月正常打卡天数
  let monthDone: number = 0;
  for (const c of checkins) {
    const parts: string[] = c.day.split('-');
    if (Number(parts[0]) === year && Number(parts[1]) === month && c.checkedIn && !c.makeup) {
      monthDone += 1;
    }
  }

  // 全局红格数（首个活跃日至昨天）
  let pendingMakeup: number = 0;
  if (firstActive !== '') {
    const span: number = diffDays(firstActive, today);
    for (let i = 0; i < span; i++) {
      const day: string = addDays(firstActive, i);
      const c: CheckInRecord | undefined = checkinMap.get(day);
      const done: boolean = c !== undefined && c.checkedIn;
      if (!done) {
        pendingMakeup += 1;
      }
    }
  }

  return {
    year,
    month,
    cells,
    streak: computeStreak(checkins, today),
    monthDone,
    pendingMakeup,
    firstActive,
  };
}

/** 每日新词量调整后的当天任务预览（滚轮实时预览用，纯函数，不落数据） */
export interface DailyNewPreview {
  /** 目标档位（夹取后的每日新词量） */
  dailyNew: number;
  /** 确认后今日实际新学词数（库存不足时小于档位） */
  newCount: number;
  reviewCount: number;
  total: number;
  /** 预计耗时（分钟，新学 40s/词、复习 15s/词的估算） */
  minutes: number;
  /** 重排后排在今天之后的未学新词数（词本剩余库存，不含今天这批） */
  unlearned: number;
  /** 今日实际新学达不到目标档位：词本剩余新词不足 */
  insufficient: boolean;
}

export const NEW_WORD_SECONDS: number = 40;
export const REVIEW_WORD_SECONDS: number = 15;

export function previewDailyNew(state: SchedulerState, n: number, now: number): DailyNewPreview {
  const day: string = dayKeyFromTs(now);
  const quota: number = clampDailyNew(n);

  // 必须与 applyDailyNewCount 完全同构（P6：此前预览漏了「今日已学词回退」，
  // 导致滚轮显示新学 12、点确定后实际变 23，预览与结果不一致）：
  // 1) 今天首学且未掌握的词回退为未排期新词；2) 逾期新词保留今天到期、未来新词清空重排。
  const hypot: ReviewSchedule[] = state.schedules.map((s: ReviewSchedule): ReviewSchedule => {
    if (s.firstLearnDay === day && s.stage !== 'MASTERED') {
      return { ...newImportedSchedule(s.wordId) };
    }
    if (s.stage === 'NEW' && s.firstLearnDay === '') {
      // 逾期新词（到期日早于今天）拉回今天，优先占今日额度
      if (s.dueDay !== '' && diffDays(s.dueDay, day) > 0) {
        return { ...s, dueDay: day };
      }
      // 未来排期（到期日晚于今天）清空，按新额度重新分配；修复点：此前两分支 diffDays 参数写反，
      // 导致整本已排到未来的词被误判为逾期全部拉回今天（真机：每日页新学显示全书总量）
      if (s.dueDay !== '' && diffDays(day, s.dueDay) > 0) {
        return { ...s, dueDay: '' };
      }
    }
    return { ...s };
  });
  const planned: ReviewSchedule[] = planNewWords(hypot, now, quota);
  const plan: DayPlan = buildDayPlan(
    { schedules: planned, records: state.records, settings: withDailyNew(state.settings, quota) },
    day,
  );

  let reviewCount: number = 0;
  REVIEW_STAGES.forEach((stage: StageCode): void => {
    reviewCount += plan.reviewBuckets[stage].length;
  });
  const newCount: number = plan.newWords.length;
  const total: number = newCount + reviewCount;
  const minutes: number = Math.round((newCount * NEW_WORD_SECONDS + reviewCount * REVIEW_WORD_SECONDS) / 60);
  // 排在今天之后的未学新词 = 词本剩余库存
  const unlearned: number = planned.filter((s: ReviewSchedule): boolean =>
    s.stage === 'NEW' && s.firstLearnDay === '' && s.dueDay !== '' && diffDays(day, s.dueDay) > 0).length;
  const insufficient: boolean = newCount < quota;
  return { dailyNew: quota, newCount, reviewCount, total, minutes, unlearned, insufficient };
}

/** 供设置页/测试使用：ASR 严格度合法值 */
export const ASR_LEVELS: AsrStrictness[] = ['LOW', 'MID', 'HIGH'];

/** 仅供测试与 UI 引用的状态色语义（不在逻辑层引颜色值） */
export type { WordStatus };
