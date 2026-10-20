/**
 * 词慧 · F17 梗句「离线梗味翻译」—— 纯逻辑层。
 *
 * 不依赖任何 ArkUI / @kit.* / http / 文件系统，可被 Node 直接 import 做单元测试
 * （与 model/MemeCore.ts 同一范式）。
 *
 * 背景：原方案依赖云端大模型与 API Key，Key 从未配置，链路必然失败；
 * 且端侧自带 116MB Opus-MT 神经网络又会撑爆包体。因此改为「词表 + 改写策略」的
 * 零网络、零密钥、零模型引擎，分三层降级并诚实标注能力边界：
 *
 * - L1 SENTENCE：命中 PHRASE_BANK 的 10 条整句模板 → 直接给高质量英文，needsManual=false；
 * - L2 MEME    ：命中 32 条梗词表 → 中文改写为「标准中文」+ 英文按出现顺序拼「脚手架」
 *                （命中片段换成英文俚语，其余实质中文换成占位符 [...]），needsManual=true；
 * - L3 NONE    ：都没命中 → 不给英文（不编造），提示用户手动填写，needsManual=true。
 *
 * 改写口径修正：Demo 注释写「长词优先」但实际按表顺序遍历，这里按梗词长度降序排序后
 * 再替换，保证「破大防」「一顿操作猛如虎」这类长梗不会被短梗截断。
 *
 * 能力边界（产品须知情）：本引擎不是通用翻译器，只认识表内的梗与整句模板；
 * 未命中时宁可留空也不产出错误英文。
 */

/** 一条梗词：梗词 / 标准中文改写 / 英文俚语建议（可含 "/" 分隔的多个候选） */
export interface MemeEntry {
  term: string;
  standard: string;
  slang: string;
}

/** 一次命中；index 为梗词在原文中的首次出现位置（用于按原文顺序展示） */
export interface MemeHit {
  term: string;
  standard: string;
  slang: string;
  index: number;
}

/** 一条整句模板：中文原句 / 预置英文 */
export interface PhrasePair {
  zh: string;
  en: string;
}

/** 梗味模式（改写 + 脚手架） / 直译模式（只检测梗，不产出英文） */
export type TranslateMode = 'MEME' | 'LITERAL';

/** 命中层级：整句模板 / 梗词脚手架 / 未命中 */
export type TranslateLevel = 'SENTENCE' | 'MEME' | 'NONE';

/** 离线翻译结果（UI 直接消费，不抛异常） */
export interface TranslateResult {
  /** 英文结果；L2 为脚手架，L3 为空串 */
  english: string;
  /** 梗味模式下的标准中文改写；直译模式等于原文 */
  rewrittenZh: string;
  /** 命中的梗词（按原文出现顺序） */
  hits: MemeHit[];
  mode: TranslateMode;
  level: TranslateLevel;
  /** 是否必须人工润色/补全（L3 与 L2 为 true） */
  needsManual: boolean;
  /** 可直接 Toast 的提示文案 */
  message: string;
}

/* ================= 梗词表（32 条，与 Demo 原文一致） ================= */

export const MEME_TABLE: MemeEntry[] = [
  { term: '卷生卷死', standard: '拼命到极点', slang: 'grinding myself to dust in the rat race' },
  { term: '破大防', standard: '彻底绷不住了', slang: 'utterly shattered my defenses' },
  { term: 'CPU都干烧了', standard: '脑子转不过来了', slang: 'brain overheated' },
  { term: '一顿操作猛如虎', standard: '折腾半天全白费', slang: 'all that hustle for nothing' },
  { term: '这波操作', standard: '这一次的做法', slang: 'this move / this play' },
  { term: '泼天的富贵', standard: '天大的好运', slang: 'sky-high fortune' },
  { term: '家人们谁懂啊', standard: '大家能理解吗', slang: 'who else gets this?' },
  { term: '尊嘟假嘟', standard: '真的假的', slang: 'for real or cap?' },
  { term: '绝绝子', standard: '非常棒', slang: 'absolutely stunning / god-tier' },
  { term: '香迷糊了', standard: '好吃到上瘾', slang: 'so good it\'s addictive' },
  { term: '破防了', standard: '被击中软肋', slang: 'it broke me / hit a nerve' },
  { term: '内卷', standard: '恶性竞争', slang: 'the rat race' },
  { term: '躺平', standard: '不参与竞争', slang: 'lie flat / opt out of the grind' },
  { term: '摆烂', standard: '放弃努力', slang: 'let it rot / give up trying' },
  { term: '摸鱼', standard: '上班偷懒', slang: 'slack off at work' },
  { term: '打工人', standard: '上班族', slang: 'wage warrior' },
  { term: '干饭', standard: '吃饭', slang: 'feast mode' },
  { term: '社死', standard: '当众出丑', slang: 'die of embarrassment in public' },
  { term: '上头', standard: '着迷上瘾', slang: 'hooked / can\'t stop' },
  { term: '下头', standard: '好感全无', slang: 'a total turn-off' },
  { term: '拿捏', standard: '完全掌控', slang: 'nailed it / have it in the bag' },
  { term: '显眼包', standard: '爱出风头的人', slang: 'attention magnet / class clown' },
  { term: '凡尔赛', standard: '炫耀式谦虚', slang: 'humblebrag' },
  { term: '芭比Q', standard: '完蛋了', slang: 'done for / cooked' },
  { term: '栓Q', standard: '谢了（反讽）', slang: 'well thanks a lot (eye-roll)' },
  { term: 'emo了', standard: '情绪低落了', slang: 'feeling down in the dumps' },
  { term: '整活', standard: '搞事情', slang: 'pull a stunt / do something wild' },
  { term: '官宣', standard: '正式公布', slang: 'make it official' },
  { term: '戏精', standard: '爱演的人', slang: 'drama queen' },
  { term: '太细了', standard: '非常精妙', slang: 'silky smooth / executed to a T' },
  { term: '单曲循环', standard: '反复播放', slang: 'on repeat' },
  { term: 'yyds', standard: '最棒的', slang: 'the GOAT (greatest of all time)' },
];

/* ================= 整句库（10 条，Demo 预设句 + 预置英文） ================= */

export const PHRASE_BANK: PhrasePair[] = [
  { zh: '这波操作太细了', en: 'That move was executed to a T.' },
  { zh: '绝绝子，这家店真的香迷糊了', en: 'Absolute god-tier. This place is so good it\'s addictive.' },
  { zh: '破防了，家人们谁懂啊', en: 'I\'m utterly shattered. Who else gets this?' },
  { zh: '天天加班卷生卷死，我想躺平了', en: 'Grinding myself to dust in the rat race every day — I just want to opt out.' },
  { zh: '别内卷了，摸鱼才是打工人的宿命', en: 'Stop feeding the rat race — slacking off is the wage warrior\'s destiny.' },
  { zh: '尊嘟假嘟，你不会还不知道吧', en: 'For real? Don\'t tell me you still don\'t know.' },
  { zh: '他一开口我就社死了，CPU都干烧了', en: 'The moment he opened his mouth I died of embarrassment — my brain overheated.' },
  { zh: '一顿操作猛如虎，一看工资两千五', en: 'All that hustle, and the paycheck is a joke.' },
  { zh: '上头了，这首歌我单曲循环一晚上', en: 'I\'m hooked — I had this song on repeat all night.' },
  { zh: '泼天的富贵终于轮到我了', en: 'Sky-high fortune has finally come my way.' },
];

/** 占位符：未命中的实质中文片段（提示用户这里是待补翻译的部分） */
export const PLACEHOLDER: string = '[...]';

/* ================= 归一化 ================= */

/** 是否汉字（梗词全部落在 CJK 基本区） */
function isCjk(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  return code >= 0x4E00 && code <= 0x9FFF;
}

/**
 * 归一化：**只保留汉字、字母、数字**，其余（标点 / 空白 / 引号 / 括号 / 全角符号）全部剥掉。
 * 只用于「整句库比对」，不参与 L2 的原文位置索引（L2 始终在原文上算 index）。
 *
 * 这样「破防了，家人们谁懂啊」「破防了家人们谁懂啊」「（破防了，家人们谁懂啊）」
 * 「"破防了，家人们谁懂啊"」都收敛成同一个键，L1 召回不再被标点写法左右。
 */
export function normalizeZh(s: string): string {
  let out: string = '';
  for (let i: number = 0; i < s.length; i++) {
    const ch: string = s.charAt(i);
    if (isCjk(ch) || /[A-Za-z0-9]/.test(ch)) {
      out += ch;
    }
  }
  return out;
}

/** 整句库比对键：归一化 + 小写（拉丁字母不区分大小写） */
function phraseKey(s: string): string {
  return normalizeZh(s).toLowerCase();
}

/* ================= 梗词匹配与改写 ================= */

/** 按长度降序排序（长词优先；同长度保持表内原顺序，sort 稳定） */
function sortedByLengthDesc(): MemeEntry[] {
  const list: MemeEntry[] = MEME_TABLE.slice();
  list.sort((a: MemeEntry, b: MemeEntry): number => b.term.length - a.term.length);
  return list;
}

/** 预排序结果（模块级常量，避免每次调用重复排序） */
const SORTED_TABLE: MemeEntry[] = sortedByLengthDesc();

/** 英文俚语取第一个候选（"this move / this play" → "this move"） */
export function primarySlang(slang: string): string {
  const idx: number = slang.indexOf('/');
  const first: string = idx >= 0 ? slang.substring(0, idx) : slang;
  return first.trim();
}

/** 首字母大写（空串原样返回） */
function capitalizeFirst(s: string): string {
  if (s.length === 0) {
    return s;
  }
  return s.charAt(0).toUpperCase() + s.substring(1);
}

/** 片段是否已以句末标点收尾（. ? !） */
function endsSentence(s: string): boolean {
  if (s.length === 0) {
    return false;
  }
  const last: string = s.charAt(s.length - 1);
  return last === '.' || last === '?' || last === '!';
}

/**
 * 往英文框追加一段俚语（UI「梗味命中」点选复用，纯函数便于单测）。
 *
 * 规则与 buildScaffold 保持一致，避免人工点选又拼出病句：
 * - 空框 → 直接放首字母大写的片段；
 * - 前文以 . ? ! 结尾 → 补一个空格；
 * - 前文以占位符 [...] 结尾 → 只补一个空格（占位符不是句子）；
 * - 否则补「. 」。
 *
 * @param cur 英文框当前内容
 * @param fragment 待追加片段（通常为 primarySlang 结果）
 */
export function appendEnglish(cur: string, fragment: string): string {
  const frag: string = capitalizeFirst(fragment.trim());
  if (frag.length === 0) {
    return cur;
  }
  const base: string = cur.trim();
  if (base.length === 0) {
    return frag;
  }
  const endsWithPlaceholder: boolean =
    base.length >= PLACEHOLDER.length
      && base.substring(base.length - PLACEHOLDER.length) === PLACEHOLDER;
  return base + ((endsWithPlaceholder || endsSentence(base)) ? ' ' : '. ') + frag;
}

/** 只做检测（不改写），命中按原文出现顺序返回；用于直译模式 */
export function detectHits(zh: string): MemeHit[] {
  const hits: MemeHit[] = [];
  const lowerZh: string = zh.toLowerCase();
  for (const entry of SORTED_TABLE) {
    // 拉丁字母梗（yyds / 芭比Q / CPU都干烧了 / emo了）用户不会严格复刻大小写
    const at: number = lowerZh.indexOf(entry.term.toLowerCase());
    if (at >= 0) {
      hits.push({ term: entry.term, standard: entry.standard, slang: entry.slang, index: at });
    }
  }
  hits.sort((a: MemeHit, b: MemeHit): number => a.index - b.index);
  return hits;
}

/**
 * 大小写无关的全量替换（等价 replaceAll + 'i'）。
 * 逐次定位后拼接，避免 ArkTS 不支持 replaceAll、也避免正则转义问题。
 */
function replaceTermIgnoreCase(text: string, term: string, standard: string): string {
  const needle: string = term.toLowerCase();
  let out: string = '';
  let cursor: number = 0;
  let from: number = 0;
  let guard: number = 0;
  while (from < text.length && guard < 256) {
    const at: number = text.toLowerCase().indexOf(needle, from);
    if (at < 0) {
      break;
    }
    out += text.substring(cursor, at) + standard;
    cursor = at + term.length;
    from = cursor;
    guard += 1;
  }
  return out + text.substring(cursor);
}

/**
 * 梗味改写：长词优先替换成标准中文，同时收集命中。
 * @param zh 中文原句
 * @returns rewrittenZh 标准中文改写；hits 按原文出现顺序
 */
export function rewriteMeme(zh: string): { rewrittenZh: string; hits: MemeHit[] } {
  let out: string = zh;
  const hits: MemeHit[] = [];
  const lowerZh: string = zh.toLowerCase();
  for (const entry of SORTED_TABLE) {
    const term: string = entry.term;
    const at: number = lowerZh.indexOf(term.toLowerCase());
    if (at < 0) {
      continue;
    }
    hits.push({ term, standard: entry.standard, slang: entry.slang, index: at });
    out = replaceTermIgnoreCase(out, term, entry.standard);
  }
  hits.sort((a: MemeHit, b: MemeHit): number => a.index - b.index);
  // 标准改写常以「了」收尾，原文后紧跟一个「了」时会叠成「了了」，折叠掉更自然。
  // 只在真有命中时做，避免「啊啊啊」这类原文被静默改写。
  if (hits.length > 0) {
    out = out.replace(/([了的啊])\1+/g, '$1');
  }
  return { rewrittenZh: out, hits };
}

/* ================= 英文脚手架（L2） ================= */

/** 片段里可忽略的汉语语气/结构助词（避免「了」这类尾缀被当成待翻译内容） */
const CHUNK_PARTICLES: string = '的了啊吧呢哦嘛啦呀哈嗯么们';

/** 片段是否含「实质内容」：去掉空白/标点/语气助词后仍有汉字，或含拉丁字母数字 */
function hasSubstantive(text: string): boolean {
  let cjk: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (isCjk(ch) && CHUNK_PARTICLES.indexOf(ch) < 0) {
      cjk += 1;
    }
  }
  if (cjk > 0) {
    return true;
  }
  return /[A-Za-z0-9]/.test(text);
}

/** 脚手架片段：文本 + 是否为占位符（占位符不改大小写、不补标点语义） */
interface ScaffoldPart {
  text: string;
  isPlaceholder: boolean;
}

/**
 * 拼英文脚手架：命中片段 → 英文俚语首选；其余实质中文 → [...]。
 *
 * 拼接规则（team-lead 定稿）：
 * - 每个俚语片段首字母大写；
 * - 前一片段以 . ? ! 结尾 → 只补一个空格；否则补「. 」；
 * - 占位符 [...] 原样、不改大小写；占位符后面接片段时**只补空格**（它不是一句句子）。
 * 目的：多梗输出是「以句号分隔的合法短句」，不再是空格硬拼的病句。
 */
function buildScaffold(zh: string, hits: MemeHit[]): string {
  const parts: ScaffoldPart[] = [];
  let cursor: number = 0;
  for (const hit of hits) {
    const at: number = hit.index;
    if (at > cursor) {
      const gap: string = zh.substring(cursor, at);
      if (hasSubstantive(gap)) {
        parts.push({ text: PLACEHOLDER, isPlaceholder: true });
      }
    }
    const slang: string = primarySlang(hit.slang);
    if (slang.length > 0) {
      parts.push({ text: slang, isPlaceholder: false });
    }
    cursor = at + hit.term.length;
  }
  if (cursor < zh.length) {
    const tail: string = zh.substring(cursor);
    if (hasSubstantive(tail)) {
      parts.push({ text: PLACEHOLDER, isPlaceholder: true });
    }
  }

  let out: string = '';
  for (let i: number = 0; i < parts.length; i++) {
    const part: ScaffoldPart = parts[i];
    const frag: string = part.isPlaceholder ? PLACEHOLDER : capitalizeFirst(part.text);
    if (i === 0) {
      out = frag;
      continue;
    }
    // 占位符不是句子：它后面只接空格，避免出现「[...]. Die of embarrassment」这种怪写法
    const prevIsPlaceholder: boolean = parts[i - 1].isPlaceholder;
    out += (prevIsPlaceholder || endsSentence(out)) ? ' ' : '. ';
    out += frag;
  }
  return out.trim();
}

/* ================= 整句库查找 ================= */

/** 整句库查找：标点/空白不敏感，少打一个逗号或整句加引号都能命中 */
function findPhrase(text: string): PhrasePair | null {
  const key: string = phraseKey(text);
  if (key.length === 0) {
    return null;
  }
  for (const pair of PHRASE_BANK) {
    if (phraseKey(pair.zh) === key) {
      return pair;
    }
  }
  return null;
}

/* ================= 对外主入口 ================= */

/** 空结果工厂（统一各降级分支的字段，避免裸对象字面量散落） */
function emptyResult(mode: TranslateMode, rewrittenZh: string, message: string): TranslateResult {
  return {
    english: '',
    rewrittenZh,
    hits: [],
    mode,
    level: 'NONE',
    needsManual: true,
    message,
  };
}

/**
 * 离线翻译主入口。永不抛异常，失败/未识别都通过 level + message 表达。
 * @param zh   中文原句
 * @param rawMode 'MEME'（默认，梗味改写 + 脚手架）/ 'LITERAL'（只检测梗，不产出英文）
 */
export function translateOffline(zh: string, rawMode?: TranslateMode): TranslateResult {
  // 运行时兜底：调用方若从 JS 侧传了非法值，不污染 TranslateMode 契约
  const mode: TranslateMode = rawMode === 'LITERAL' ? 'LITERAL' : 'MEME';
  const text: string = zh.trim();
  if (text.length === 0) {
    return emptyResult(mode, '', '请先输入中文句子');
  }

  // 直译模式：不改写、不产出英文，只告诉用户这句里有几个梗
  if (mode === 'LITERAL') {
    const literalHits: MemeHit[] = detectHits(text);
    const msg: string = literalHits.length > 0
      ? '这句里有 ' + literalHits.length + ' 个梗词，直译模式不生成英文，请手动填写'
      : '未识别到梗词，请手动填写英文';
    return {
      english: '',
      rewrittenZh: zh, // 口径：直译模式返回原文（含首尾空白），不做任何改写
      hits: literalHits,
      mode,
      level: 'NONE',
      needsManual: true,
      message: msg,
    };
  }

  const normalized: string = normalizeZh(text);
  if (normalized.length === 0) {
    return emptyResult(mode, text, '未识别到有效中文内容，请手动填写英文');
  }

  // L1：整句模板命中（标点/空白不敏感）
  const phrase: PhrasePair | null = findPhrase(text);
  if (phrase !== null) {
    // 整句已有高质量英文，不再给脚手架提示，避免用户重复追加俚语
    return {
      english: phrase.en,
      rewrittenZh: phrase.zh,
      hits: [],
      mode,
      level: 'SENTENCE',
      needsManual: false,
      message: '整句已命中离线句库，可直接使用或手动润色',
    };
  }

  const rewritten = rewriteMeme(text);

  // L3：无梗词 → 不编造英文
  if (rewritten.hits.length === 0) {
    return emptyResult(mode, rewritten.rewrittenZh, '未识别到梗词，请手动填写英文');
  }

  // L2：梗味脚手架（多梗以「. 」分隔成合法短句，见 buildScaffold 注释）
  const english: string = buildScaffold(text, rewritten.hits);
  const hitCount: number = rewritten.hits.length;

  return {
    english,
    rewrittenZh: rewritten.rewrittenZh,
    hits: rewritten.hits,
    mode,
    level: 'MEME',
    needsManual: true,
    message: '识别到 ' + hitCount + ' 个梗词，已生成英文脚手架，请手动润色',
  };
}
