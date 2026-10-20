/**
 * 本轮断点草稿（退出可续）。
 *
 * 背景：F8 语音快过此前把一轮判定只放页面内存，退出即整轮丢失；
 * F9 闪卡虽逐卡实时落调度，但没记队列位置，重进会把已判过的词再判一遍
 * （调度被重复推进）。两者都违反「背到哪个词就从哪个词继续」。
 *
 * 本文件只负责「这轮做到哪了」的本机落盘，不碰调度：
 * - SPEECH：词序 + 每词判定 + 阶段（round/review），确认前不改调度；
 * - REVIEW：剩余队列顺序（含「模糊」重排）+ 本轮总数与三档计数。
 * 草稿按 day 作废，跨天不再续（今日任务已换批）。
 */
import { LocalStateFiles } from './LocalStateFiles';
import { dayKeyFromTs } from '../model/SchedulerCore';

/** 一条词的判定快照（verdict 为空串表示尚未判定） */
export interface RoundDraftEntry {
  wordId: string;
  verdict: string;
  heard: string;
}

export interface RoundDraft {
  /** 'speech' | 'review' */
  kind: string;
  /** REVIEW 轮的 mode（REVIEW/WRONG/MAKEUP）；SPEECH 固定 'NEW' */
  mode: string;
  /** 草稿所属日期 yyyy-mm-dd */
  day: string;
  /** SPEECH=本轮全量词序；REVIEW=剩余队列词序（可能含重复的模糊卡） */
  wordIds: string[];
  /** 当前进度位置 */
  index: number;
  /** 'round' | 'review' */
  phase: string;
  entries: RoundDraftEntry[];
  /** REVIEW 轮：本轮总张数与已判档位计数 */
  total: number;
  knownCount: number;
  vagueCount: number;
  unknownCount: number;
  savedAt: number;
}

export class RoundDraftStore {
  static readonly SPEECH: string = 'speech';
  static readonly REVIEW: string = 'review';

  private static fileOf(kind: string): string {
    return `round-draft-${kind}.json`;
  }

  /** 今日日期键（草稿有效期唯一的判据） */
  static today(): string {
    return dayKeyFromTs(Date.now());
  }

  static save(draft: RoundDraft): void {
    try {
      LocalStateFiles.write(RoundDraftStore.fileOf(draft.kind), JSON.stringify(draft));
    } catch (e) {
      console.warn(`[RoundDraft] save ${draft.kind} failed: ${(e as Error)?.message ?? e}`);
    }
  }

  /** 读草稿：不存在 / 解析失败 / 跨天 一律返回 null（跨天顺手清掉） */
  static load(kind: string): RoundDraft | null {
    const raw: string | null = LocalStateFiles.read(RoundDraftStore.fileOf(kind));
    if (raw === null) {
      return null;
    }
    let draft: RoundDraft | null = null;
    try {
      draft = JSON.parse(raw) as RoundDraft;
    } catch (_e) {
      draft = null;
    }
    if (draft === null || draft === undefined) {
      RoundDraftStore.clear(kind);
      return null;
    }
    if (draft.day !== RoundDraftStore.today()) {
      RoundDraftStore.clear(kind);
      return null;
    }
    if (draft.wordIds === undefined || draft.wordIds.length === 0) {
      RoundDraftStore.clear(kind);
      return null;
    }
    return draft;
  }

  static clear(kind: string): void {
    LocalStateFiles.remove(RoundDraftStore.fileOf(kind));
  }
}
