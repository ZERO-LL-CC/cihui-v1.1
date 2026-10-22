/**
 * 今日新词统一入口：分组学习会话的路由决策。
 *
 * 学习节奏（替代此前「一次看完当日全部新词、最后统一测」）：
 *   看第 1 组 10 个 → 立刻测这一组 → 看第 2 组 → 测第 2 组 → …
 *   → 所有组走完后，今天判「模糊」的词按每 10 个一批重考（轮完 10 个再轮剩下的几个）
 *
 * 入口只做一件事：问会话「现在该做哪一步」，然后直接进那一步的页面。
 * 这样既不会「学完了还被打回第一次」，也不会「测完一组又被拉回第一组」。
 */
import { NavStore } from './NavStore';
import { DataStore } from './DataStore';
import { RouteName } from '../common/RouteNames';
import type { NewWordsRouteParam, SpeechRouteParam } from '../common/RouteNames';
import { RoundDraftStore } from '../service/RoundDraftStore';
import type { BrowseDraft, RoundDraft, RoundDraftEntry } from '../service/RoundDraftStore';
import { StudySessionStore } from '../service/StudySessionStore';
import type { SessionStep, NewWordSession } from '../service/StudySessionStore';
import { promptAction } from '@kit.ArkUI';
import type { Word } from '../model/Types';

/** 两组词序是否完全一致（顺序敏感） */
function sameIds(a: string[], b: string[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i: number = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

/** 本组已看到第几张（1 基）；0 = 没有可续的进度 */
function browseIndexOf(wordIds: string[]): number {
  const draft: BrowseDraft | null = RoundDraftStore.loadBrowse();
  if (draft === null || !sameIds(draft.wordIds, wordIds)) {
    return 0;
  }
  if (draft.reachedEnd) {
    return wordIds.length;
  }
  return draft.index > 0 ? Math.min(draft.index + 1, wordIds.length) : 0;
}

/** 本组已判定几个 */
function judgedCount(wordIds: string[]): number {
  const draft: RoundDraft | null = RoundDraftStore.load(RoundDraftStore.SPEECH);
  if (draft === null) {
    return 0;
  }
  const inGroup: Set<string> = new Set(wordIds);
  let n: number = 0;
  draft.entries.forEach((e: RoundDraftEntry): void => {
    if (e.verdict.length > 0 && inGroup.has(e.wordId)) {
      n += 1;
    }
  });
  return n;
}

function toast(msg: string): void {
  try {
    promptAction.showToast({ message: msg, duration: 1800 });
  } catch (e) {
    // 忽略 Toast 异常
  }
}

/** 打开今日新词学习：按会话当前阶段直达「看词 / 组内测 / 模糊重考」 */
export function openTodayNewWords(): void {
  const session: NewWordSession | null = StudySessionStore.begin();
  if (session === null) {
    toast('今天没有新词任务');
    return;
  }
  openStep(StudySessionStore.step(session));
}

/** 在当前栈上打开某一步（首次进入用） */
export function openStep(step: SessionStep): void {
  if (step.kind === 'browse') {
    const p: NewWordsRouteParam = {
      wordIds: step.wordIds,
      groupIndex: step.groupIndex,
      groupTotal: step.groupTotal,
    };
    NavStore.INSTANCE.push(RouteName.NEW_WORDS, p);
    return;
  }
  if (step.kind === 'test' || step.kind === 'retest') {
    NavStore.INSTANCE.push(RouteName.SPEECH_TEST, speechParamOf(step));
    return;
  }
  toast('今日新词已全部完成');
}

function speechParamOf(step: SessionStep): SpeechRouteParam {
  const p: SpeechRouteParam = {
    wordIds: step.wordIds,
    chunk: true,
    groupIndex: step.groupIndex,
    groupTotal: step.groupTotal,
    retest: step.kind === 'retest',
    batchIndex: step.batchIndex,
    batchTotal: step.batchTotal,
  };
  return p;
}

/**
 * 一步做完后接着做下一步：清回首页 Tab 再 push（实测这是让新页面拿到
 * 全新实例的唯一可靠原语；直接 push 会把多组串成多层栈）。
 */
export function continueToday(): void {
  const session: NewWordSession | null = StudySessionStore.begin();
  if (session === null) {
    NavStore.INSTANCE.finishToHome();
    return;
  }
  const step: SessionStep = StudySessionStore.step(session);
  if (step.kind === 'browse') {
    const p: NewWordsRouteParam = {
      wordIds: step.wordIds,
      groupIndex: step.groupIndex,
      groupTotal: step.groupTotal,
    };
    NavStore.INSTANCE.backToTabThenPush(0, RouteName.NEW_WORDS, p);
    return;
  }
  if (step.kind === 'test' || step.kind === 'retest') {
    NavStore.INSTANCE.backToTabThenPush(0, RouteName.SPEECH_TEST, speechParamOf(step));
    return;
  }
  NavStore.INSTANCE.finishToHome();
  toast('今日新词已全部完成');
}

/** 今日新词主按钮文案（只在刷新点调用，构建期不读文件） */
export function entryLabel(): string {
  const session: NewWordSession | null = StudySessionStore.peek();
  if (session === null) {
    return '开始今日学习';
  }
  const step: SessionStep = StudySessionStore.step(session);
  if (step.kind === 'browse') {
    const at: number = browseIndexOf(step.wordIds);
    const total: number = step.wordIds.length;
    return at > 0
      ? `继续今日学习（第 ${step.groupIndex} / ${step.groupTotal} 组 · 看词 ${at} / ${total}）`
      : `开始今日学习（第 ${step.groupIndex} / ${step.groupTotal} 组 · ${total} 个新词）`;
  }
  if (step.kind === 'test') {
    const at: number = judgedCount(step.wordIds);
    const total: number = step.wordIds.length;
    return at > 0
      ? `继续今日学习（第 ${step.groupIndex} / ${step.groupTotal} 组 · 测 ${at} / ${total}）`
      : `继续今日学习（第 ${step.groupIndex} / ${step.groupTotal} 组 · 测这 ${total} 个）`;
  }
  if (step.kind === 'retest') {
    return `继续今日学习（模糊重考 · 剩 ${session.vaguePool.length} 个）`;
  }
  return '今日新词已完成';
}

/** 今日任务主卡副标题 */
export function taskSubLabel(): string {
  const session: NewWordSession | null = StudySessionStore.peek();
  if (session === null) {
    return '';
  }
  const step: SessionStep = StudySessionStore.step(session);
  if (step.kind === 'browse') {
    return `第 ${step.groupIndex} / ${step.groupTotal} 组 · 先看 ${step.wordIds.length} 个，看完马上测`;
  }
  if (step.kind === 'test') {
    return `第 ${step.groupIndex} / ${step.groupTotal} 组 · 测完这 ${step.wordIds.length} 个再进下一组`;
  }
  if (step.kind === 'retest') {
    return `把今天「模糊」的 ${session.vaguePool.length} 个词排队再考一遍`;
  }
  return '今天的新词已经走完，去打卡吧';
}

/** 今日是否已无新词任务（供首页判断按钮态） */
export function todayNewWordsDone(): boolean {
  const session: NewWordSession | null = StudySessionStore.peek();
  if (session === null) {
    return DataStore.INSTANCE.todayNewWordList().length === 0;
  }
  return StudySessionStore.step(session).kind === 'done';
}

/* ============================================================================
 * 临时兼容层（待删除）
 *
 * 背景：本文件已切到 StudySessionStore 新会话架构，导出换成了无参的 entryLabel()；
 * 但 pages/tab/HomePage.ets 仍是旧版本，还在 import 下面三个旧 API，导致整工程
 * ArkTS 编译失败（"has no exported member named 'entryLabelFor'"）。
 *
 * 用途：只为让工程能编译、好做端侧翻译可行性验证，不代表最终逻辑。
 * 收尾：HomePage 切到 entryLabel() 后，把这三个函数整段删掉。
 * ========================================================================== */

/** 旧 API 兼容：新架构由 StudySessionStore 管断点，这里恒 false */
export function isTodayBatchBrowsed(words: Word[]): boolean {
  return words.length === 0;
}

/** 旧 API 兼容：新架构由 StudySessionStore 管进度，这里恒 0 */
export function browseResumeAt(): number {
  return 0;
}

/** 旧 API 兼容：文案统一交给新版 entryLabel() */
export function entryLabelFor(at: number, total: number, browsed: boolean, remaining: number): string {
  return entryLabel();
}
