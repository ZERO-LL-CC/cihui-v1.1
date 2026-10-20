/**
 * 今日新词统一入口：F7（浏览）与 F8（语音快过）之间的路由决策。
 *
 * 背景：入口此前一律 push F7，导致「已经浏览完 / 已经判了一半」的用户
 * 每次都被打回第一张词卡，必须重新滑完整批才能回到 F8——用户感知就是
 * 「学完了还让我重新首学」。浏览完成与否必须参与路由决策。
 *
 * 决策规则（三条全部满足才跳过 F7）：
 * 1. 今天有今天的新词（非空）；
 * 2. 有当天的浏览草稿且已经翻到末张（reachedEnd）；
 * 3. 草稿里的词序与当前这批完全一致（换批/换天后不得错位）。
 */
import { NavStore } from './NavStore';
import { DataStore } from './DataStore';
import { RouteName } from '../common/RouteNames';
import type { SpeechRouteParam } from '../common/RouteNames';
import { RoundDraftStore } from '../service/RoundDraftStore';
import type { BrowseDraft } from '../service/RoundDraftStore';
import type { Word } from '../model/Types';

/** 草稿是否就是当前这一批（顺序敏感） */
function sameBatch(draft: BrowseDraft, words: Word[]): boolean {
  if (draft.wordIds.length !== words.length) {
    return false;
  }
  for (let i = 0; i < words.length; i++) {
    if (draft.wordIds[i] !== words[i].id) {
      return false;
    }
  }
  return true;
}

/** 本批是否已完整浏览过 */
export function isTodayBatchBrowsed(words: Word[]): boolean {
  if (words.length === 0) {
    return false;
  }
  const browse: BrowseDraft | null = RoundDraftStore.loadBrowse();
  if (browse === null || !browse.reachedEnd) {
    return false;
  }
  return sameBatch(browse, words);
}

/** 待续浏览位置（1 基）；0 表示没有可续的进度 */
export function browseResumeAt(): number {
  const words: Word[] = DataStore.INSTANCE.todayNewWordList();
  if (words.length === 0) {
    return 0;
  }
  const browse: BrowseDraft | null = RoundDraftStore.loadBrowse();
  if (browse === null || !sameBatch(browse, words)) {
    return 0;
  }
  if (browse.index <= 0) {
    return 0;
  }
  return Math.min(browse.index + 1, words.length);
}

/** 首页入口文案（纯计算，调用方传入已缓存的断点值，避免在 build 里读文件） */
export function entryLabelFor(at: number, total: number, browsed: boolean, remaining: number): string {
  if (browsed) {
    return '继续今日学习（做语音测试）';
  }
  if (at > 0 && total > 0) {
    return `继续今日学习（第 ${at} / ${total} 个）`;
  }
  return `开始今日学习（剩 ${remaining} 个新词）`;
}

/**
 * 打开今日新词学习：已浏览完本批 → 直接回 F8（草稿会自动续到上次那个词）；
 * 否则进 F7 从上次看到的那张继续浏览。
 */
export function openTodayNewWords(): void {
  const words: Word[] = DataStore.INSTANCE.todayNewWordList();
  if (isTodayBatchBrowsed(words)) {
    const ids: string[] = words.map((w: Word): string => w.id);
    const param: SpeechRouteParam = { wordIds: ids };
    NavStore.INSTANCE.push(RouteName.SPEECH_TEST, param);
    return;
  }
  NavStore.INSTANCE.push(RouteName.NEW_WORDS);
}
