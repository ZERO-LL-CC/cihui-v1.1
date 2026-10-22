/**
 * 词慧 · 数据层类型定义（F2）
 * 纯类型文件，不含任何 ArkUI 装饰器，Node 可直接加载做单元测试。
 * 口径来源：提示词包 F2 + PRD v1.2。
 */

/** 词本来源：拍照 DIY / 手动 DIY / 云词书 */
export type BookSource = 'DIY_PHOTO' | 'DIY_MANUAL' | 'CLOUD' | 'MEME';

/** 单词来源：OCR 识别 / 手动录入 / 云词书 / OCR 缺释义后手动补录 */
export type WordSource = 'OCR' | 'MANUAL' | 'CLOUD' | 'DIY_SUPPLEMENT' | 'MEME';

/** 艾宾浩斯长期节点：新词 NEW，长期复习 R1/R2/R4/R7/R15（首学后第 1/2/4/7/15 天），已掌握 MASTERED */
export type StageCode = 'NEW' | 'R1' | 'R2' | 'R4' | 'R7' | 'R15' | 'MASTERED';

/** 单词学习状态：学习中 / 已掌握 / 错词强化 */
export type WordStatus = 'LEARNING' | 'MASTERED' | 'WRONG';

/** 三档判定：认识 / 模糊 / 不认识 */
export type Verdict = 'KNOWN' | 'VAGUE' | 'UNKNOWN';

/** 学习环节：新词首测 / 到期复习（模糊重考也归入对应环节） */
export type LearnPhase = 'FIRST' | 'REVIEW';

/** 新词入列方式：QUEUE=按每日新词量排队（默认）；TODAY=加入当天计划（今天立即首学、不占每日新词配额） */
export type IntakeMode = 'QUEUE' | 'TODAY';

/** 一轮学习中某个单词的判定结果（F8 复核清单 / F9 一轮汇总通用；null=未判定） */
export interface RoundVerdict {
  wordId: string;
  verdict: Verdict | null;
  /** 语音识别到的口述文本（手动判定时为空） */
  heard: string;
}

/** ASR 严格度三档 */
export type AsrStrictness = 'LOW' | 'MID' | 'HIGH';

/** 词本 */
export interface WordBook {
  id: string;
  name: string;
  source: BookSource;
  /** 云词书目录 id（source=CLOUD 时存在） */
  cloudBookId?: string;
  createdAt: number;
}

/** 单词 */
export interface Word {
  id: string;
  bookId: string;
  /** 英文词条 */
  english: string;
  /** 音标，可空 */
  phonetic: string;
  /** 中文义项，可多义项；命中任一核心义项即算认识 */
  meanings: string[];
  source: WordSource;
  /** 是否缺中文释义：缺释义只能手动闪卡，不能进语音快过 */
  missingMeaning: boolean;
  /** 是否 DIY 手动补录的释义 */
  diySupplement: boolean;
  createdAt: number;
}

/** 学习记录（一个单词一条） */
export interface StudyRecord {
  wordId: string;
  /** 首次首学时间戳，0 表示尚未首学；不认识清零后重置为 0，次日重新首学 */
  firstStudyAt: number;
  /** 首学通过（首测判认识）时间戳，0 表示未通过 */
  firstPassedAt: number;
  /** 短时节点 S1=5 分钟，默认关闭 */
  s1DoneAt: number;
  /** 短时节点 S2=30 分钟 */
  s2DoneAt: number;
  /** 短时节点 S3=12 小时 */
  s3DoneAt: number;
  /** 最近一次学习日期 yyyy-mm-dd，用于当日完成度复算 */
  lastStudyDay: string;
}

/** 复习调度（一个单词一条，调度器唯一权威输出） */
export interface ReviewSchedule {
  wordId: string;
  /** 当前节点 */
  stage: StageCode;
  /** 首学日期 yyyy-mm-dd；长期节点到期日 = 该日期 + 1/2/4/7/15 天 */
  firstLearnDay: string;
  /** 当前节点到期日 yyyy-mm-dd；MASTERED 时为空串 */
  dueDay: string;
  status: WordStatus;
  /** 模糊判定后置 true：强制加入次日复习；次日复习完成后清除 */
  forceNextDay: boolean;
  /** 本轮末尾需要循环重考（模糊），UI 出队时用；重考认识后清除 */
  roundRequeue: boolean;
  /** 错词原因标签：不认识·转明天新词 / 模糊·次日强制复习 */
  wrongReason: string;
  lastVerdictAt: number;
  /** 入列方式：QUEUE=按每日新词量排队；TODAY=当天计划（不占每日新词配额）。
   * 旧数据无此字段视为 QUEUE（planNewWords 预扫描排除 intake==='TODAY'）。 */
  intake?: IntakeMode;
  /** 当日「模糊」累计次数（仅新词首学计）：1=留在今日排队重考（不排明天、不进错词本），
   *  2=进错词本并转明天重学。跨日按 vagueDay 归零。旧数据无此字段视为 0。 */
  vagueCount?: number;
  /** vagueCount 所属日期 yyyy-mm-dd（跨日归零的唯一判据） */
  vagueDay?: string;
}

/** 打卡记录（一天一条） */
export interface CheckInRecord {
  /** yyyy-mm-dd */
  day: string;
  /** P1：当日新词 100% 首学且首过 */
  p1NewDone: boolean;
  /** P2：当天所有到期桶 100% 过完 */
  p2ReviewDone: boolean;
  /** P3：错词强化（每 5 天一次） */
  p3WrongDone: boolean;
  /** 当天是否轮到 P3（非轮到日不阻断打卡） */
  p3Required: boolean;
  /** 是否已打卡（0–24 点窗口内幂等，只计一次） */
  checkedIn: boolean;
  /** 是否补卡 */
  makeup: boolean;
  /** 打卡时计算出的连续天数（补卡默认不恢复连续天数，开放项） */
  streak: number;
}

/** 设置（轻量 KV，后续接 preferences） */
export interface Settings {
  /** 每日新词量 10–1000，默认 20；导入词本后在弹框里一次性设置 */
  dailyNewCount: number;
  /** 当前背诵中的词本 id（F-D：一次只能背一本；''=未设置，全部词本可排期）。
   *  拍照词本与梗句词本例外：独立词本但始终参与算法排期。 */
  activeBookId: string;
  /** 短时复习 S1/S2/S3 开关，默认关闭 */
  shortReviewEnabled: boolean;
  /** P3 错词强化严格度开关 */
  p3Strict: boolean;
  /** TTS 语速，1.0 为常速 */
  ttsRate: number;
  asrStrictness: AsrStrictness;
  /** 触感总开关 */
  hapticEnabled: boolean;
  /** 学习提醒开关（F16） */
  reminderEnabled: boolean;
  /** 每日提醒时间（小时 0–23，默认 20 点；策略常量占位，待用户确认） */
  reminderHour: number;
  /** 每日提醒时间（分钟 0–59，默认 0） */
  reminderMinute: number;
}

export const DEFAULT_SETTINGS: Settings = {
  dailyNewCount: 20,
  activeBookId: '',
  shortReviewEnabled: false,
  p3Strict: true,
  ttsRate: 1.0,
  asrStrictness: 'MID',
  hapticEnabled: true,
  reminderEnabled: false,
  reminderHour: 20,
  reminderMinute: 0,
};

/** 长期节点距首学日的天数偏移（R1/R2/R4/R7/R15 = 第 1/2/4/7/15 天） */
export const STAGE_OFFSET_DAYS: Record<string, number> = {
  R1: 1,
  R2: 2,
  R4: 4,
  R7: 7,
  R15: 15,
};

/** 长期节点推进顺序 */
export const STAGE_ORDER: StageCode[] = ['NEW', 'R1', 'R2', 'R4', 'R7', 'R15', 'MASTERED'];

/** 短时节点间隔（毫秒）：5 分钟 / 30 分钟 / 12 小时 */
export const SHORT_NODE_MS: Record<string, number> = {
  S1: 5 * 60 * 1000,
  S2: 30 * 60 * 1000,
  S3: 12 * 60 * 60 * 1000,
};

/** 错词原因标签 */
export const WRONG_REASON_UNKNOWN: string = '不认识·转明天新词';
export const WRONG_REASON_VAGUE: string = '模糊·次日强制复习';

/* ================= F17 梗句 / F18 梗卡片 / F19 今日例句 ================= */

/** 梗句记录（一条梗句对应一个 MEME 词本与若干学习会话） */
export interface MemeSentence {
  id: string;
  /** 中文原句 */
  chinese: string;
  /** 英文句子（离线翻译或用户手填） */
  english: string;
  /** 对应梗句词本 id（F5 列表带「梗句」标签） */
  bookId: string;
  /** 本梗句拆出的全部单词 id（含已掌握，便于再背一遍） */
  wordIds: string[];
  createdAt: number;
  /** 最近一次完成背诵的时间戳，0 表示未完成过 */
  lastStudiedAt: number;
}

/** 会话内单个词的状态 */
export type SessionItemState = 'pending' | 'reviewed';

/** 会话内单词项：记录判定结果用于 F18 徽章比例 */
export interface SessionItem {
  wordId: string;
  state: SessionItemState;
  /** 最近一次三档判定，pending 时为 null */
  verdict: Verdict | null;
}

/** 梗句背诵会话（强杀可恢复：每判一词即落盘） */
export interface StudySession {
  id: string;
  /** 所属梗句 id */
  memeId: string;
  /** 打乱后的词序（item 顺序即背诵顺序） */
  items: SessionItem[];
  createdAt: number;
  /** 完成时间戳，0 表示进行中 */
  completedAt: number;
  status: 'in_progress' | 'completed';
}

/** F18 梗卡片徽章档位 */
export type MemeBadgeLevel = 'GOLD' | 'SILVER' | 'BRONZE';

/** F18 梗卡片（同梗句多次背完只留一张，随最新结果更新） */
export interface MemeCard {
  id: string;
  memeId: string;
  /** 本地导出的卡片图片路径（缓存目录），空串表示 Canvas 失败的纯文字卡 */
  cardImagePath: string;
  /** 本轮判「认识」的词数 */
  masteredCount: number;
  /** 本轮总词数 */
  totalCount: number;
  badgeLevel: MemeBadgeLevel;
  /** 解锁日期 yyyy-mm-dd */
  unlockedDay: string;
  isFavorite: boolean;
  /** 分享次数 */
  sharedCount: number;
  unlockedAt: number;
}

/** F19 收藏的今日例句（我的例句本） */
export interface SavedSentence {
  id: string;
  /** 英文例句 */
  sentence: string;
  /** 中文翻译 */
  translation: string;
  /** 句中来自当日词表的词（小写原形） */
  words: string[];
  /** 来源批次日期 yyyy-mm-dd */
  sourceDay: string;
  savedAt: number;
}

/** F19 大模型生成的单条例句（解析后结构，未收藏不落库） */
export interface GeneratedSentence {
  /** 英文例句 */
  sentence: string;
  /** 中文翻译 */
  translation: string;
  /** 句中来自当日词表、被高亮的词（列表原词，小写原形） */
  words: string[];
}

/** F19 高亮分段：hit=true 的片段是今日词，需要品牌蓝加粗 */
export interface SentenceSegment {
  text: string;
  hit: boolean;
}
