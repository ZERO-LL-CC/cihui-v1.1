/**
 * 今日新词学习会话（分组学习 + 模糊池重考）。
 *
 * 背景：此前 F7 一口气看完当日全部新词、再进 F8 统一测——看的时候只是「眼熟」，
 * 测的时候早已脱离上下文，记忆留存极差。改为：
 *
 *   看第 1 组(10) → 测第 1 组 → 看第 2 组 → 测第 2 组 → … → 模糊池 10 个一批重考
 *
 * 两条硬规则：
 * 1. 会话必须「钉住」当日整批词（batchIds）。调度一旦判定就会把词从今日计划里移走
 *    （认识→R1 次日、模糊→留白、不认识→错词），所以第 2 组绝不能再问
 *    DataStore.todayNewWordList()，否则会少词/串组。
 * 2. 会话按 day 作废。模糊词在调度里是 dueDay='' 的「留白」状态，
 *    跨天后 planNewWords 会自动把它排回计划（不会永久悬空）。
 */
import { LocalStateFiles } from './LocalStateFiles';
import { dayKeyFromTs } from '../model/SchedulerCore';
import { DataStore } from '../viewmodel/DataStore';
import type { RoundVerdict, Word } from '../model/Types';

/** 一组新词（看 → 测 绑定） */
export interface SessionGroup {
  wordIds: string[];
  /** 本组是否已浏览到末张（未看完不允许进测） */
  browseDone: boolean;
}

export interface NewWordSession {
  /** 会话所属日期 yyyy-mm-dd（跨天作废） */
  day: string;
  /** 今日整批新词（创建会话时钉住，不随后续判定收缩） */
  batchIds: string[];
  groups: SessionGroup[];
  /** 当前待处理的组下标；>= groups.length 表示新词组已走完 */
  cursor: number;
  /** 今日「模糊池」：按判定顺序排队，最后按每批 CHUNK_SIZE 个重考 */
  vaguePool: string[];
  /** 已完成的模糊重考批次数（仅用于「第 N 批」文案） */
  retestBatch: number;
  finished: boolean;
  savedAt: number;
}

/** 一次具体的学习动作（入口路由的唯一依据） */
export interface SessionStep {
  /** browse=看词 / test=组内测 / retest=模糊重考 / done=今天的新词全部结束 */
  kind: string;
  wordIds: string[];
  /** 组序号（1 基），retest/done 时为 0 */
  groupIndex: number;
  groupTotal: number;
  /** 重考批次（1 基），非 retest 时为 0 */
  batchIndex: number;
  /** 本批待重考词数（非 retest 时为 0） */
  batchTotal: number;
}

/** 每组词数：10 个一组，看完立刻测（工作记忆容量友好） */
export const CHUNK_SIZE: number = 10;

const FILE: string = 'study-session.json';

export class StudySessionStore {
  static today(): string {
    return dayKeyFromTs(Date.now());
  }

  /** 读会话：不存在 / 解析失败 / 跨天 一律返回 null（跨天顺手清掉） */
  static load(): NewWordSession | null {
    const raw: string | null = LocalStateFiles.read(FILE);
    if (raw === null) {
      return null;
    }
    let s: NewWordSession | null = null;
    try {
      s = JSON.parse(raw) as NewWordSession;
    } catch (_e) {
      s = null;
    }
    if (s === null || s === undefined || s.day !== StudySessionStore.today()
      || s.groups === undefined || s.batchIds === undefined) {
      StudySessionStore.clear();
      return null;
    }
    if (s.vaguePool === undefined) {
      s.vaguePool = [];
    }
    return s;
  }

  static save(s: NewWordSession): void {
    s.savedAt = Date.now();
    try {
      LocalStateFiles.write(FILE, JSON.stringify(s));
    } catch (e) {
      console.warn(`[NewWordSession] save failed: ${(e as Error)?.message ?? e}`);
    }
  }

  static clear(): void {
    LocalStateFiles.remove(FILE);
  }

  /** 用今日新词现造一个会话（不落盘）；今日无新词返回 null */
  static derive(): NewWordSession | null {
    const words: Word[] = DataStore.INSTANCE.todayNewWordList();
    if (words.length === 0) {
      return null;
    }
    const ids: string[] = words.map((w: Word): string => w.id);
    return StudySessionStore.build(ids);
  }

  /** 按 CHUNK_SIZE 切组 */
  static build(batchIds: string[]): NewWordSession {
    const groups: SessionGroup[] = [];
    let i: number = 0;
    while (i < batchIds.length) {
      const g: SessionGroup = { wordIds: batchIds.slice(i, i + CHUNK_SIZE), browseDone: false };
      groups.push(g);
      i += CHUNK_SIZE;
    }
    const s: NewWordSession = {
      day: StudySessionStore.today(),
      batchIds: batchIds,
      groups: groups,
      cursor: 0,
      vaguePool: [],
      retestBatch: 0,
      finished: groups.length === 0,
      savedAt: Date.now(),
    };
    return s;
  }

  /** 入口：有会话续会话，没有就按今日新词新建并落盘；今日无新词返回 null */
  static begin(): NewWordSession | null {
    const existing: NewWordSession | null = StudySessionStore.load();
    if (existing !== null) {
      return existing;
    }
    const fresh: NewWordSession | null = StudySessionStore.derive();
    if (fresh !== null) {
      StudySessionStore.save(fresh);
    }
    return fresh;
  }

  /** 只读预览（首页文案用，不写盘） */
  static peek(): NewWordSession | null {
    const existing: NewWordSession | null = StudySessionStore.load();
    return existing !== null ? existing : StudySessionStore.derive();
  }

  /** 当前该做哪一步（纯函数） */
  static step(s: NewWordSession): SessionStep {
    if (s.finished) {
      return {
        kind: 'done', wordIds: [], groupIndex: 0, groupTotal: s.groups.length,
        batchIndex: 0, batchTotal: 0,
      };
    }
    if (s.cursor < s.groups.length) {
      const g: SessionGroup = s.groups[s.cursor];
      return {
        kind: g.browseDone ? 'test' : 'browse',
        wordIds: g.wordIds,
        groupIndex: s.cursor + 1,
        groupTotal: s.groups.length,
        batchIndex: 0,
        batchTotal: 0,
      };
    }
    // 新词组已走完 → 模糊池按每批 CHUNK_SIZE 个重考，轮完 10 个再轮剩下的几个
    const batch: string[] = s.vaguePool.slice(0, CHUNK_SIZE);
    return {
      kind: 'retest',
      wordIds: batch,
      groupIndex: 0,
      groupTotal: s.groups.length,
      batchIndex: s.retestBatch + 1,
      batchTotal: batch.length,
    };
  }

  /** 本组看完：允许进入本组测试 */
  static markBrowseDone(s: NewWordSession): void {
    if (s.cursor < s.groups.length) {
      s.groups[s.cursor].browseDone = true;
      StudySessionStore.save(s);
    }
  }

  /**
   * 一组（或一批重考）判完：推进会话。
   * - 组内测：本组过关，判「模糊」的词进池排队，游标前进；
   * - 重考：本批出池（认识→R1；再次模糊→调度层已按第 2 次处理，进错词本）；
   * - 池空且组走完 → finished。
   */
  static finishStep(s: NewWordSession, verdicts: RoundVerdict[], retest: boolean): void {
    if (retest) {
      const done: Set<string> = new Set();
      verdicts.forEach((v: RoundVerdict): void => {
        done.add(v.wordId);
      });
      s.vaguePool = s.vaguePool.filter((id: string): boolean => !done.has(id));
      s.retestBatch += 1;
    } else {
      if (s.cursor < s.groups.length) {
        s.groups[s.cursor].browseDone = true;
      }
      verdicts.forEach((v: RoundVerdict): void => {
        if (v.verdict === 'VAGUE' && s.vaguePool.indexOf(v.wordId) < 0) {
          s.vaguePool.push(v.wordId);
        }
      });
      s.cursor += 1;
    }
    s.finished = s.cursor >= s.groups.length && s.vaguePool.length === 0;
    StudySessionStore.save(s);
  }

  /** 今日新词是否已全部走完（含模糊重考） */
  static isDone(): boolean {
    const s: NewWordSession | null = StudySessionStore.load();
    return s !== null && s.finished;
  }
}
