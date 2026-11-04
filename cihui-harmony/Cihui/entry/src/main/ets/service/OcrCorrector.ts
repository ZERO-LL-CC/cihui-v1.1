/**
 * OCR 词书约束纠错（F2，纯函数 .ts，可在 Node 下直接单测）。
 *
 * 算法常量与 PRD-ocr-correction-v1 §5.3 及 PC 参考实现 eval_hms_v2.py 严格一致：
 * - 混淆对替换代价 0.45（对称）：w-v / i-l / c-e / u-v / o-a / m-n / h-n / r-n /
 *   t-f / g-q / b-h / d-cl / i-r（"d-cl" 在逐字符比较下不可达，与 PC 实现同语义，保留对齐）；
 * - 普通替换 1.0；插入/删除 0.9；加权距离 >3 直接判不匹配；
 * - 全场扫描按长度分桶索引（只进 len±2 桶，等价于 PRD §4.3 的长度差 ≤2 预剪枝）；
 *   候选门槛：加权距离 ≤ 2.0；
 * - 同分排序：词频排名小者胜（wordbank.f 是 ecdict 排名，越小越常用——勿写反）；
 * - 词库小写直命中 → 原样返回，不纠错不标记。
 *
 * 词组（含空格）不做纠错；wordbank 加载失败 → 纠错整体停用（correct 返回原文、
 * 不置 suspect），行为与未接入纠错时一致，不阻塞导入。
 *
 * 本文件零 @kit 依赖：init 接收 ResourceManager 的最小结构镜像 RawfileReader
 * （真实 ResourceManager 因结构类型兼容可直接传入），UTF-8 解码为内置纯实现。
 */

export interface CorrectResult {
  english: string;
  suspect: boolean;
}

/** ResourceManager 最小结构镜像（Node 测试不经过此路径，用 loadFromText 注入） */
export interface RawfileReader {
  getRawFileContentSync(name: string): Uint8Array;
}

interface WordbankWord {
  w: string;
  f: number;
}

interface WordbankJson {
  version: number;
  count: number;
  words: WordbankWord[];
}

const RAW_NAME: string = 'ocr_correction/wordbank.json';
const CONF_COST: number = 0.45;       // 混淆对替换代价
const SUB_COST: number = 1.0;         // 普通替换代价
const DEL_INS_COST: number = 0.9;     // 插入/删除代价
const MAX_DIST: number = 2.0;         // 候选门槛：加权距离 ≤ 2.0
const MAX_LEN_DIFF_PRE: number = 2;   // 全场扫描预剪枝：长度差 ≤2
const MAX_LEN_DIFF_HARD: number = 3;  // 加权距离硬剪枝：长度差 >3 判不匹配
const MIN_TOKEN_LEN: number = 2;      // 短于 2 的 token 不纠不标
const NOT_FOUND_RANK: number = 999999; // wordbank 缺失词频的约定值

/** 混淆对（对称）序列化键：两段按字典序排序后拼接。"d-cl" 生成 3 字符键 'cdl'，
 *  与 PC 实现的 frozenset 语义一致——逐字符比较永远不会命中它（死配置，保留对齐）。 */
const CONFUSABLE: Set<string> = new Set<string>([
  'vw', 'il', 'ce', 'uv', 'ao', 'mn', 'hn', 'nr', 'ft', 'gq', 'bh', 'cdl', 'ir'
]);

function subCost(a: string, b: string): number {
  if (a === b) {
    return 0.0;
  }
  const key: string = a < b ? a + b : b + a;
  if (CONFUSABLE.has(key)) {
    return CONF_COST;
  }
  return SUB_COST;
}

/** 加权编辑距离（DP），长度差 >3 直接判不匹配（返回 99）。
 *  行最小值 > MAX_DIST 时提前返回 99（编辑距离沿行单调不降，后续不可能再回到门槛内），
 *  早停只影响被丢弃候选的计算量，不影响任何采纳结果（行为等价）。 */
function wdist(a: string, b: string): number {
  const la: number = a.length;
  const lb: number = b.length;
  if (Math.abs(la - lb) > MAX_LEN_DIFF_HARD) {
    return 99.0;
  }
  let prev: number[] = new Array<number>(lb + 1);
  for (let j: number = 0; j <= lb; j++) {
    prev[j] = j * DEL_INS_COST;
  }
  for (let i: number = 1; i <= la; i++) {
    const cur: number[] = new Array<number>(lb + 1);
    cur[0] = prev[0] + DEL_INS_COST;
    let rowMin: number = cur[0];
    for (let j: number = 1; j <= lb; j++) {
      const del: number = prev[j] + DEL_INS_COST;
      const ins: number = cur[j - 1] + DEL_INS_COST;
      const sub: number = prev[j - 1] + subCost(a[i - 1], b[j - 1]);
      const v: number = Math.min(del, ins, sub);
      cur[j] = v;
      if (v < rowMin) {
        rowMin = v;
      }
    }
    if (rowMin > MAX_DIST) {
      return 99.0;
    }
    prev = cur;
  }
  return prev[lb];
}

/** 纯 TS UTF-8 解码（零依赖，Node 与 ArkTS 双环境一致） */
function utf8Decode(bytes: Uint8Array): string {
  let out: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const b: number = bytes[i];
    let cp: number;
    if (b < 0x80) {
      cp = b;
      i += 1;
    } else if (b < 0xe0) {
      cp = ((b & 0x1f) << 6) | (bytes[i + 1] & 0x3f);
      i += 2;
    } else if (b < 0xf0) {
      cp = ((b & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f);
      i += 3;
    } else {
      cp = ((b & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12)
        | ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
      i += 4;
    }
    if (cp > 0xffff) {
      cp -= 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
    } else {
      out += String.fromCharCode(cp);
    }
  }
  return out;
}

export interface CorrectorStats {
  count: number;
  ms: number;
}

/** 长度分桶条目：[词, 词频排名, JSON 序]。
 *  idx 用于同分同排名时的确定性 tie-break（等价于旧版按 JSON 序遍历的先后）。 */
type BucketEntry = [string, number, number];

export class OcrCorrector {
  private dict: Map<string, number> = new Map<string, number>();
  /** 词长 → 该长度全部词条（扫描只进 len±2 的桶，免去全量迭代 + 长度过滤开销） */
  private buckets: Map<number, BucketEntry[]> = new Map<number, BucketEntry[]>();
  private readyFlag: boolean = false;
  private statCount: number = 0;
  private statMs: number = 0;

  get isReady(): boolean {
    return this.readyFlag;
  }

  /** 性能打点：累计纠错词数与纯纠错耗时（PRD 验收：单页 50 词 ≤500ms） */
  get stats(): CorrectorStats {
    const s: CorrectorStats = { count: this.statCount, ms: this.statMs };
    return s;
  }

  /**
   * 从 ResourceManager 加载词库（真机路径）。重复调用幂等。
   * 任何失败都降级为「纠错停用」，返回 false，不抛异常不阻塞导入。
   */
  async init(rm: RawfileReader): Promise<boolean> {
    if (this.readyFlag) {
      return true;
    }
    try {
      const bytes: Uint8Array = rm.getRawFileContentSync(RAW_NAME);
      return this.loadFromBytes(bytes);
    } catch (err) {
      // 加载失败：纠错整体降级停用（correct 返回原文、不置 suspect）
      this.readyFlag = false;
      return false;
    }
  }

  /** Node 测试注入口：直接喂 wordbank.json 文本 */
  loadFromText(text: string): boolean {
    try {
      const data: WordbankJson = JSON.parse(text) as WordbankJson;
      const dict: Map<string, number> = new Map<string, number>();
      const buckets: Map<number, BucketEntry[]> = new Map<number, BucketEntry[]>();
      let idx: number = 0;
      for (const it of data.words) {
        const w: string = it.w.toLowerCase();
        const f: number = typeof it.f === 'number' && it.f > 0 ? it.f : NOT_FOUND_RANK;
        dict.set(w, f);
        const list: BucketEntry[] | undefined = buckets.get(w.length);
        const entry: BucketEntry = [w, f, idx];
        if (list === undefined) {
          buckets.set(w.length, [entry]);
        } else {
          list.push(entry);
        }
        idx++;
      }
      if (dict.size === 0) {
        this.readyFlag = false;
        return false;
      }
      this.dict = dict;
      this.buckets = buckets;
      this.readyFlag = true;
      return true;
    } catch (err) {
      this.readyFlag = false;
      return false;
    }
  }

  private loadFromBytes(bytes: Uint8Array): boolean {
    return this.loadFromText(utf8Decode(bytes));
  }

  /**
   * 纠错单个词条（同步纯函数）。
   * - 未就绪 / 词组（含空格）/ 过短 token → 原样返回、suspect=false（降级停用）；
   * - 词库小写直命中 → 原样返回；
   * - 全场扫描最优候选（距离 ≤2.0，同分取词频排名小者）→ 返回纠正词并保留原 head
   *   的大小写风格（原 head 首字母大写且纠正词全小写 → 转为首字母大写）；
   * - 无候选 → 原文保留 + suspect=true（UI 标 "!"）。
   */
  correct(token: string): CorrectResult {
    const t0 = Date.now();
    try {
      const trimmed: string = token.trim();
      if (!this.readyFlag || trimmed.length < MIN_TOKEN_LEN || trimmed.indexOf(' ') >= 0) {
        const r0: CorrectResult = { english: token, suspect: false };
        return r0;
      }
      const lower: string = trimmed.toLowerCase();
      if (this.dict.has(lower)) {
        const r1: CorrectResult = { english: token, suspect: false };
        return r1;
      }
      let best: string | null = null;
      let bestDist: number = MAX_DIST;
      let bestRank: number = NOT_FOUND_RANK + 1;
      let bestIdx: number = -1;
      // 长度分桶扫描：只进 len±2 桶（与旧版「长度差 ≤2 预剪枝 + JSON 序遍历」完全等价）
      for (let len: number = lower.length - MAX_LEN_DIFF_PRE;
        len <= lower.length + MAX_LEN_DIFF_PRE; len++) {
        const bucket: BucketEntry[] | undefined = this.buckets.get(len);
        if (bucket === undefined) {
          continue;
        }
        for (const [w, rank, idx] of bucket) {
          const d: number = wdist(lower, w);
          if (d > MAX_DIST) {
            continue;
          }
          if (d < bestDist
            || (d === bestDist
              && (rank < bestRank || (rank === bestRank && (bestIdx < 0 || idx < bestIdx))))) {
            best = w;
            bestDist = d;
            bestRank = rank;
            bestIdx = idx;
          }
        }
      }
      if (best === null) {
        const r2: CorrectResult = { english: token, suspect: true };
        return r2;
      }
      let styled: string = best;
      const first: string = token.charAt(0);
      if (first >= 'A' && first <= 'Z' && best === best.toLowerCase()) {
        styled = first + best.substring(1);
      }
      const r3: CorrectResult = { english: styled, suspect: false };
      return r3;
    } finally {
      this.statCount++;
      this.statMs += Date.now() - t0;
    }
  }
}

/** 模块级单例（页面与测试共用） */
export const ocrCorrector: OcrCorrector = new OcrCorrector();
