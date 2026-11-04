/**
 * F19 今日例句页（离线词库版）
 *
 * 词源硬规则：只取"今日已学新词 + 今日已复习词"（DataStore.todayWords），不碰未学词；
 * 例句只做语境强化，不进入艾宾浩斯调度、不改任何单词节点（本页对调度数据只读）。
 *
 * 例句来源：`rawfile/examples/<cloudBookId>.json`（Tatoeba 真人语料 + AI 补生成，
 * 构建脚本见 `tools/examples/build_examples.py`）。一个词一条，按当前词书懒加载，
 * 全程不联网、不消耗任何额度，也没有 API Key。
 *
 * 从上到下：
 *   1 顶栏（返回 / 今日例句 / 今日 N 词 + 例句本入口）
 *   2 批次条（第 n 批 · 共 m 批 + 圆点指示器）
 *   3 覆盖率卡（本批覆盖 X/Y 词 + 百分比徽章 + 进度条 + 缺例句词 chips）
 *   4 例句卡（逐词一条：序号 / 目标词 / 高亮英文 / 中文）
 *   5 底部固定操作栏（朗读 / 收藏 / 分享 / 重选）
 *
 * 状态机沿用 BatchState：
 *   idle      未组装，先批内勾选本批词（默认全选、各批独立，<3 个拦下）
 *   loading   读本地例句表时的骨架屏
 *   ok        渲染 3、4
 *   fallback  该批一个例句都没有（手动词书 / 未收录），退回释义视图
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
import type { MemeSentence, SentenceSegment, Word, WordBook } from '../../model/Types';
import type { PassageResult, PassageSentence } from '../../model/SentenceCore';
import {
  MIN_WORDS_FOR_SENTENCE,
  PASSAGE_COVERAGE_TARGET,
  SENTENCE_BATCH_SIZE,
  chunkItems,
  highlightSegments,
} from '../../model/SentenceCore';
import { dayKeyFromTs } from '../../model/SchedulerCore';
import { ExampleService } from '../../service/ExampleService';
import { buildWordPassage } from '../../model/ExampleCore';
import type { ExampleEntry } from '../../model/ExampleCore';
import { findMemeExample } from '../../model/MemeExampleCore';
import { TtsService } from '../../service/TtsService';
import type { TtsState } from '../../service/TtsService';
import { MemeCardService } from '../../service/MemeCardService';
import { ShareService } from '../../service/ShareService';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

/* 点名册选词页的局部色：只服务这一屏，不进全局令牌 */
const PICK_ROW_ON_BG: string = '#F4F8FF';
const PICK_ROW_LINE: string = '#F0F3F8';
const PICK_BOX_LINE: string = '#D3DAE6';

/** 单批加载状态机：idle 未生成 / loading 生成中 / ok 成功 / fallback 本地降级 */
@ObservedV2
class BatchState {
  index: number;
  status: string;
  /** 整段结果（ok 时非空） */
  passage: PassageResult | null;
  /** 本批实际送去生成的词（批内勾选后的子集，补漏时复用） */
  words: Word[];

  constructor(index: number) {
    this.index = index;
    this.status = 'idle';
    this.passage = null;
    this.words = [];
  }
}

@ComponentV2
export struct TodaySentencePage {
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 0;
  @Local showTick: number = 0;
  @Local todayCount: number = 0;
  @Local batches: Word[][] = [];
  /** 各批勾选状态，与 batches 平行；默认全选，各批互相独立（切批不继承） */
  @Local selectedFlags: boolean[][] = [];
  @Local batchStates: BatchState[] = [];
  @Local current: number = 0;
  @Local contentOpacity: number = 1;
  @Local savedKeys: string[] = [];
  @Local ttsState: TtsState = 'idle';
  /** 中文对照是否展开（默认收起） */
  @Local zhOpen: boolean = false;
  /** 骨架屏呼吸动画的当前透明度 */
  @Local skOpacity: number = 1;
  /** 正在手动补漏 */
  @Local patching: boolean = false;
  /** 本轮刚补上的词：补漏成功后画成绿色删除线，让"补上了"看得见 */
  @Local patchedWords: string[] = [];
  /** 分享快照目标（createFromBuilder 只接受无参 CustomBuilder） */
  @Local shareTarget: PassageResult | null = null;
  @Local busy: boolean = false;
  /** 点名册列表的错峰入场开关：进页先 false 再置 true，配合每行 animation delay 形成瀑布 */
  @Local rowsIn: boolean = false;
  private sourceDay: string = dayKeyFromTs(Date.now());
  private loadingSeq: number = 0;

  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.TODAY_SENTENCE) {
      this.showTick++;
      this.reload();
    }
  };

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    const rate: number = DataStore.INSTANCE.settings.ttsRate;
    TtsService.init(rate).then((state: TtsState): void => {
      this.ttsState = state;
    });
    this.reload();
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
    TtsService.stop();
  }

  /** 重新收集今日词并重建批次（学习后返回首页再进来会变化） */
  private reload(): void {
    const words: Word[] = DataStore.INSTANCE.todayWords(this.sourceDay);
    this.todayCount = words.length;
    this.savedKeys = DataStore.INSTANCE.savedSentenceList().map((s): string => s.sentence);
    this.zhOpen = false;
    this.patching = false;
    this.patchedWords = [];
    if (words.length < MIN_WORDS_FOR_SENTENCE) {
      this.batches = [];
      this.batchStates = [];
      return;
    }
    this.batches = chunkItems(words, SENTENCE_BATCH_SIZE);
    // 勾选状态与批次同步重建，默认全选；batches 为空则是空数组
    const flags: boolean[][] = [];
    for (let i = 0; i < this.batches.length; i++) {
      const row: boolean[] = [];
      this.batches[i].forEach((): void => {
        row.push(true);
      });
      flags.push(row);
    }
    this.selectedFlags = flags;
    const states: BatchState[] = [];
    for (let i = 0; i < this.batches.length; i++) {
      states.push(new BatchState(i));
    }
    this.batchStates = states;
    this.current = 0;
    this.playRowsIn();
    // 首屏停在 idle：先让用户确认本批词，再读本地例句表。
    // 切到别的批时不拦（用户明确想看那一批），见 switchBatch。
  }

  /* ================= 批内勾选 ================= */

  /** 某批按勾选过滤出的词（防御：勾选行缺失时按全选处理） */
  private selectedWordsOf(index: number): Word[] {
    const batch: Word[] | undefined = this.batches[index];
    if (batch === undefined) {
      return [];
    }
    const flags: boolean[] | undefined = this.selectedFlags[index];
    if (flags === undefined) {
      return batch.slice();
    }
    const out: Word[] = [];
    for (let i = 0; i < batch.length; i++) {
      if (i < flags.length && flags[i]) {
        out.push(batch[i]);
      }
    }
    return out;
  }

  private selectedCount(index: number): number {
    return this.selectedWordsOf(index).length;
  }

  private enoughSelected(): boolean {
    return this.selectedCount(this.current) >= MIN_WORDS_FOR_SENTENCE;
  }

  /** 单个 chip 的勾选态（防御：越界按全选） */
  private wordFlag(wordIndex: number): boolean {
    const flags: boolean[] | undefined = this.selectedFlags[this.current];
    if (flags === undefined || wordIndex >= flags.length) {
      return true;
    }
    return flags[wordIndex];
  }

  /** 点 chip 切换勾选；生成中忽略（防生成词集与展示漂移），整体 slice() 赋值保证响应式 */
  private toggleWordFlag(wordIndex: number): void {
    if (this.currentState().status === 'loading') {
      return;
    }
    const flags: boolean[] | undefined = this.selectedFlags[this.current];
    if (flags === undefined || wordIndex >= flags.length) {
      return;
    }
    const next: boolean[][] = this.selectedFlags.slice();
    const row: boolean[] = flags.slice();
    row[wordIndex] = !row[wordIndex];
    next[this.current] = row;
    this.selectedFlags = next;
  }

  /** 本批是否全选（决定右上角按钮文案：全部取消 / 全选） */
  private allSelected(): boolean {
    const batch: Word[] | undefined = this.batches[this.current];
    if (batch === undefined) {
      return false;
    }
    return this.selectedCount(this.current) === batch.length;
  }

  /** 一键全选 / 全部取消：同样整体 slice() 赋值，保证 ForEach 重算 */
  private setAllFlags(flag: boolean): void {
    if (this.currentState().status === 'loading') {
      return;
    }
    const flags: boolean[] | undefined = this.selectedFlags[this.current];
    if (flags === undefined) {
      return;
    }
    const next: boolean[][] = this.selectedFlags.slice();
    next[this.current] = flags.map((v: boolean): boolean => flag);
    this.selectedFlags = next;
  }

  /** 序号补零：01、02…（点名册的册页感靠它） */
  private pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** 列表错峰入场：复位后再置位，单次状态变化 + 每行不同 delay，比逐帧 setInterval 稳 */
  private playRowsIn(): void {
    this.rowsIn = false;
    setTimeout((): void => {
      this.rowsIn = true;
    }, 40);
  }

  /** 组装一批的例句：全部读本地词库，不联网 */
  private loadBatch(index: number, refresh: boolean): void {
    if (index < 0 || index >= this.batchStates.length || this.batches.length === 0) {
      return;
    }
    const state: BatchState = this.batchStates[index];
    if (state.status === 'loading') {
      return;
    }
    const words: Word[] = this.selectedWordsOf(index);
    if (words.length < MIN_WORDS_FOR_SENTENCE) {
      this.toast(`至少选 ${MIN_WORDS_FOR_SENTENCE} 个词才能看例句，当前选了 ${words.length} 个`);
      return;
    }
    this.loadingSeq++;
    const seq: number = this.loadingSeq;
    state.status = 'loading';
    state.passage = null;
    state.words = words;
    this.zhOpen = true;
    this.batchStates = this.batchStates.slice();

    // 只用这批词所属词书的例句表：切词书才换文件，别的词书不读
    const keys: string[] = [];
    let hasNoBookWord: boolean = false;
    words.forEach((w: Word): void => {
      const k: string = this.exampleKey(w);
      if (k.length > 0) {
        if (keys.indexOf(k) < 0) {
          keys.push(k);
        }
      } else {
        hasNoBookWord = true;
      }
    });
    // 梗句本/自定义词本的词没有例句表，借当前词书兜底，所以当前词书总要读一次
    const activeKey: string = this.keyOfBookId(DataStore.INSTANCE.settings.activeBookId);
    if (activeKey.length > 0 && keys.indexOf(activeKey) < 0) {
      keys.push(activeKey);
    }
    // 还有落在词书之外的词（梗句本/手动加词）：补读通用包，常用词能查到
    if (hasNoBookWord && keys.indexOf(ExampleService.COMMON_KEY) < 0) {
      keys.push(ExampleService.COMMON_KEY);
    }
    ExampleService.INSTANCE.ensure(keys, getContext(this) as common.Context)
      .then((): void => {
        if (seq !== this.loadingSeq) {
          return; // 期间又切了批，丢弃过期结果
        }
        const memes: MemeSentence[] = DataStore.INSTANCE.memes;
        const result: PassageResult = buildWordPassage(words, (w: Word): ExampleEntry | null => {
          const key: string = this.exampleKey(w);
          const hit: ExampleEntry | null = ExampleService.INSTANCE.get(key, w.english);
          if (hit !== null) {
            return hit;
          }
          // 词书/通用包里没有：直接拿用户导入的梗句原句当例句，语境最贴
          const anyHit: ExampleEntry | null = ExampleService.INSTANCE.getAny(w.english);
          return anyHit !== null ? anyHit : findMemeExample(w.english, memes);
        });
        state.passage = result;
        state.status = result.sentences.length > 0 ? 'ok' : 'fallback';
        this.batchStates = this.batchStates.slice();
        this.fadeIn();
      })
      .catch((): void => {
        this.finishFallback(seq, index);
      });
  }

  /** word -> 例句库文件名（云词书 id）；手动词书/自定义词本没有例句表 */
  private exampleKey(w: Word): string {
    return this.keyOfBookId(w.bookId);
  }

  private keyOfBookId(bookId: string): string {
    if (bookId.length === 0) {
      return '';
    }
    const b: WordBook | null = DataStore.INSTANCE.bookById(bookId);
    if (b === null || b.cloudBookId === undefined) {
      return '';
    }
    return b.cloudBookId;
  }

  private finishFallback(seq: number, index: number): void {
    if (seq !== this.loadingSeq) {
      return;
    }
    const state: BatchState = this.batchStates[index];
    state.passage = null;
    state.status = 'fallback';
    this.batchStates = this.batchStates.slice();
    this.fadeIn();
  }

  private fadeIn(): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    if (reduced) {
      this.contentOpacity = 1;
      return;
    }
    this.contentOpacity = 0.35;
    setTimeout(() => {
      this.getUIContext().animateTo(
        { duration: Motion.FEEDBACK, curve: Curve.EaseOut },
        () => {
          this.contentOpacity = 1;
        }
      );
    }, 60);
  }

  /** 「重选」：淡出回到勾选态，让用户改写本批词 */
  private refreshBatch(): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    const back: () => void = (): void => {
      this.currentState().status = 'idle';
      this.batchStates = this.batchStates.slice();
    };
    if (reduced) {
      back();
      return;
    }
    this.getUIContext().animateTo(
      { duration: 150, curve: Curve.EaseIn },
      () => {
        this.contentOpacity = 0.2;
      }
    );
    setTimeout((): void => {
      back();
      this.contentOpacity = 1;
    }, 160);
  }

  private switchBatch(index: number): void {
    if (index === this.current) {
      return;
    }
    this.current = index;
    this.zhOpen = false;
    this.patchedWords = [];
    this.patching = false;
    const state: BatchState | undefined = this.batchStates[index];
    if (state !== undefined && (state.status === 'idle' || state.status === 'fallback')) {
      this.loadBatch(index, false);
    } else {
      this.fadeIn();
    }
  }

  /** 朗读整段（不再按句读） */
  private speakPassage(): void {
    const text: string = this.passageEnglish(this.currentPassage());
    if (text.length === 0) {
      this.toast('还没有可以朗读的短文');
      return;
    }
    if (TtsService.speak(text)) {
      return;
    }
    if (TtsService.state === 'needDownload') {
      this.toast('需联网下载英文发音音色后才能朗读');
    } else if (TtsService.state === 'downloading') {
      this.toast('正在下载英文发音音色，请稍候…');
    } else {
      this.toast('当前设备暂不支持朗读');
    }
  }

  private passageEnglish(p: PassageResult): string {
    return p.sentences.map((s: PassageSentence): string => s.sentence.trim()).join(' ');
  }

  private passageChinese(p: PassageResult): string {
    return p.sentences.map((s: PassageSentence): string => s.translation.trim()).join('');
  }

  private isSaved(sentence: string): boolean {
    return this.savedKeys.includes(sentence);
  }

  /**
   * 收藏整段：写进现有「我的例句本」一条（英文整段 + 中文整段 + 覆盖词），
   * 沿用 DataStore.saveSentence 的幂等判重，不新增存储模型（PRD 5.2 的 SavedPassage 留待后续）。
   */
  private toggleSavePassage(): void {
    const p: PassageResult = this.currentPassage();
    const en: string = this.passageEnglish(p);
    if (en.length === 0) {
      this.toast('还没有可以收藏的短文');
      return;
    }
    if (this.isSaved(en)) {
      this.toast('已经在例句本里了');
      return;
    }
    const ok: boolean = DataStore.INSTANCE.saveSentence(en, this.passageChinese(p), p.coveredWords, this.sourceDay);
    if (!ok) {
      this.toast('已经在例句本里了');
      return;
    }
    this.savedKeys = DataStore.INSTANCE.savedSentenceList().map((x): string => x.sentence);
    this.toast('已收藏到例句本');
  }

  /** 分享短文卡：ArkUI 卡面离屏快照 JPEG，再走系统分享 */
  private async sharePassage(): Promise<void> {
    if (this.busy) {
      return;
    }
    const p: PassageResult = this.currentPassage();
    const en: string = this.passageEnglish(p);
    if (en.length === 0) {
      this.toast('还没有可以分享的短文');
      return;
    }
    this.busy = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.shareTarget = p;
      const path: string = await ShareService.snapshotBuilderToJpg(ctx, this.SnapshotPassage,
        `passage_${Date.now()}`);
      await MemeCardService.shareImage(ctx, path, p.title.length > 0 ? p.title : '今日例句');
    } catch (e) {
      console.warn(`[Sentence] share: ${(e as Error)?.message ?? e}`);
      this.toast('未找到分享目标，可稍后再试');
    } finally {
      this.busy = false;
    }
  }

  private animateCovered(covered: boolean): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : Motion.PAGE, curve: Curve.EaseOut },
      () => {
        NavStore.INSTANCE.covered = covered;
      }
    );
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 1600 });
    } catch (e) {
      console.warn(`[Sentence] toast: ${(e as Error)?.message ?? e}`);
    }
  }

  /* ================= 数据取值 ================= */

  private currentState(): BatchState {
    if (this.batchStates.length === 0) {
      return new BatchState(0);
    }
    return this.batchStates[this.current];
  }

  private currentPassage(): PassageResult {
    const st: BatchState = this.currentState();
    if (st.passage !== null) {
      return st.passage;
    }
    const empty: PassageResult = {
      title: '',
      sentences: [],
      coveredWords: [],
      missedWords: [],
      coverage: 0
    };
    return empty;
  }

  private coveredCount(): number {
    const p: PassageResult = this.currentPassage();
    return p.coveredWords.length;
  }

  private totalCount(): number {
    const p: PassageResult = this.currentPassage();
    const sum: number = p.coveredWords.length + p.missedWords.length;
    return sum > 0 ? sum : 0;
  }

  private percent(): number {
    return Math.round(this.currentPassage().coverage * 100);
  }

  private coverageOk(): boolean {
    return this.currentPassage().coverage >= PASSAGE_COVERAGE_TARGET;
  }

  /** 未覆盖词 chips；补漏成功后改画「刚补上的词 + 删除线」 */
  private chipWords(): string[] {
    const p: PassageResult = this.currentPassage();
    if (p.missedWords.length > 0) {
      return p.missedWords;
    }
    return this.patchedWords;
  }

  private chipsAllDone(): boolean {
    return this.currentPassage().missedWords.length === 0;
  }

  /* ================= 句中高亮 =================
   * 口径与 model/SentenceCore.ts 的 computeCoverage 完全一致（精确 → 词干 → 前缀），
   * 目的是让「覆盖率数字」和「眼前高亮的词」对得上：凡是算进 covered 的词，
   * 在正文里的 refused / improved 这类变形也必须高亮。
   * 该判定在纯函数层里是私有函数（本轮不改 SentenceCore），故在此按同一份规则实现。
   */
  private static readonly WORD_SUFFIXES: string[] = ['ies', 'est', 'ing', 'ed', 'er', 'es', 'ly', 's', 'd'];

  private stemOf(word: string): string {
    const lower: string = word.toLowerCase();
    let out: string = lower;
    const suffixes: string[] = TodaySentencePage.WORD_SUFFIXES;
    for (let i = 0; i < suffixes.length; i++) {
      const suf: string = suffixes[i];
      if (out.length > suf.length && out.endsWith(suf)) {
        const cut: string = out.substring(0, out.length - suf.length);
        if (cut.length >= 3) {
          out = cut;
          break;
        }
      }
    }
    if (out.length >= 4 && out.endsWith('e')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  private tokenHits(token: string, targets: string[]): boolean {
    const tok: string = token.toLowerCase();
    for (let i = 0; i < targets.length; i++) {
      const target: string = targets[i];
      if (tok === target) {
        return true;
      }
      const a: string = this.stemOf(tok);
      const b: string = this.stemOf(target);
      if (a.length >= 3 && b.length >= 3 && a === b) {
        return true;
      }
      if (tok.length >= 4 && target.length >= 4 && tok.substring(0, 4) === target.substring(0, 4)) {
        return true;
      }
    }
    return false;
  }

  /** 把整段拼成一串高亮分段：先拼成整段文本，再**一次性**用 highlightSegments 切 */
  private passageSegments(): SentenceSegment[] {
    const p: PassageResult = this.currentPassage();
    if (p.sentences.length === 0) {
      return [];
    }
    return highlightSegments(this.passageEnglish(p), this.highlightWords());
  }

  /**
   * 交给 highlightSegments 的词表。
   * 直接传 coveredWords 只能高亮原形，句中 refused / improved 这类变形不会亮，
   * 会出现「覆盖 18/20 但只亮了 14 个」的割裂；所以先把正文里**能算作命中**的表层 token
   * 一并收进来（同一套三级口径，与 computeCoverage 对齐），再交给 highlightSegments 切分。
   */
  private highlightWords(): string[] {
    const p: PassageResult = this.currentPassage();
    const covered: string[] = p.coveredWords;
    if (covered.length === 0) {
      return [];
    }
    const out: string[] = [];
    const matched: RegExpMatchArray | null = this.passageEnglish(p).match(/[A-Za-z][A-Za-z'-]*/g);
    if (matched === null) {
      return covered;
    }
    matched.forEach((tok: string): void => {
      const lower: string = tok.toLowerCase();
      if (out.indexOf(lower) >= 0) {
        return;
      }
      if (this.tokenHits(lower, covered)) {
        out.push(lower);
      }
    });
    return out;
  }

  /* ================= UI ================= */

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(40).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())

      Text('今日例句')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      // 右侧副标题（原型 .navsub）。「我的例句本」入口在「我的」页，不在这里重复放
      Text(`今日 ${this.todayCount} 词`)
        .fontSize(11).fontColor(Colors.TEXT_WEAK).margin({ right: 12 })
    }
    .width('100%').height(56).padding({ left: 8, right: 8 })
  }

  /** 今日词不足 3 个：空态，不发请求 */
  @Builder
  EmptyGate() {
    Column() {
      Blank()
      Stack() {
        Circle({ width: 96, height: 96 }).fill(Colors.BRAND_SOFT)
        Image($r('app.media.ic_sentence')).width(42).height(42).fillColor(Colors.BRAND)
      }.width(120).height(120)
      Text(`今天背了 ${this.todayCount} 个词`)
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .margin({ top: 18 })
      Text(`再背 ${MIN_WORDS_FOR_SENTENCE - this.todayCount} 个就能生成例句`)
        .fontSize(TypeScale.BODY).fontColor(Colors.BRAND).fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center).width('76%').margin({ top: 10 })
      Text('每个词配一条真人例句，读完就记住了')
        .fontSize(13).fontColor(Colors.TEXT_SUB)
        .textAlign(TextAlign.Center).width('76%').margin({ top: 6 })
      Button('去背单词 →')
        .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
        .borderRadius(Radius.BUTTON).height(46).width(180).margin({ top: 24 })
        .onClick(() => NavStore.INSTANCE.backToTab(1))
      Blank()
    }.width('100%').layoutWeight(1)
  }

  /** 批次条：BATCH 01 / 8 WORDS 胶囊 + 多批才画的圆点（单批时原实现的蓝条像渲染残留） */
  @Builder
  BatchBar() {
    Row() {
      Row() {
        Text(`BATCH ${this.pad2(this.current + 1)}`)
          .fontSize(10).fontWeight(FontWeight.Bold).fontColor(Colors.BRAND).letterSpacing(0.7)
        Text(` / ${this.batches.length > 0 ? this.batches[this.current].length : 0} WORDS`)
          .fontSize(10).fontColor(Colors.TEXT_WEAK).letterSpacing(0.7)
      }
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(Colors.WHITE).borderRadius(99)
      .border({ width: 1, color: Colors.DIVIDER })

      Blank()

      if (this.batchStates.length > 1) {
        Row({ space: 5 }) {
          ForEach(this.batchStates, (st: BatchState) => {
            Row()
              .width(st.index === this.current ? 18 : 7)
              .height(7)
              .borderRadius(99)
              .backgroundColor(st.index === this.current ? Colors.BRAND : Colors.TEXT_WEAK)
              .opacity(st.index === this.current ? 1 : 0.45)
              .animation({ duration: Motion.FEEDBACK, curve: Motion.pageCurve() })
              .onClick(() => this.switchBatch(st.index))
          }, (st: BatchState): string => `dot-${st.index}`)
        }
      }
    }
    .width('100%').margin({ top: 2, bottom: 12 })
    .padding({ left: 16, right: 16 })
  }

  /** 覆盖率卡：提到段落之前，首屏必须看见（本功能的差异点） */
  @Builder
  CoverageCard() {
    Column() {
      Row() {
        Text('本批覆盖')
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB)
        Text(`${this.coveredCount()}`)
          .fontSize(19).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
          .margin({ left: 6 })
        Text(`/${this.totalCount()} 词`)
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_WEAK)
          .margin({ left: 1 })
        Blank()
        Text(`${this.percent()}%`)
          .fontSize(TypeScale.CAPTION).fontWeight(FontWeight.Medium)
          .fontColor(this.coverageOk() ? Colors.KNOW_GREEN : Colors.FUZZY_ORANGE)
          .backgroundColor(this.coverageOk() ? Colors.KNOW_GREEN_SOFT : Colors.FUZZY_ORANGE_SOFT)
          .borderRadius(6).padding({ left: 8, right: 8, top: 2, bottom: 2 })
      }
      .width('100%').alignItems(VerticalAlign.Center).margin({ bottom: 10 })

      // 进度条：7vp、圆角 99、品牌蓝填充，宽度按 coverage
      Row() {
        Row()
          .width(`${this.percent()}%`)
          .height(7)
          .borderRadius(99)
          .backgroundColor(Colors.BRAND)
      }
      .width('100%').height(7).borderRadius(99).backgroundColor(Colors.PAGE_BG)

      // 未覆盖词 chips（全覆盖时改口径，并把刚补上的词画成删除线）
      if (this.chipWords().length > 0) {
        Row() {
          Text(this.chipsAllDone() ? '已全部用上' : '还没用上')
            .fontSize(11).fontColor(Colors.TEXT_WEAK).margin({ right: 2 })
          ForEach(this.chipWords(), (word: string) => {
            Text(word)
              .fontSize(TypeScale.CAPTION)
              .fontFamily('Georgia')
              .fontColor(this.chipsAllDone() ? Colors.KNOW_GREEN : Colors.TEXT_SUB)
              .backgroundColor(this.chipsAllDone() ? Colors.KNOW_GREEN_SOFT : Colors.PAGE_BG)
              .borderRadius(8).padding({ left: 9, right: 9, top: 4, bottom: 4 })
              .margin({ left: 6 })
              .decoration({ type: this.chipsAllDone() ? TextDecorationType.LineThrough : TextDecorationType.None })
          }, (word: string): string => `chip-${word}`)
        }
        .width('100%').margin({ top: 12 })
      } else {
        Text('今日词全部用上')
          .fontSize(11).fontColor(Colors.KNOW_GREEN).width('100%').margin({ top: 12 })
      }

      // 缺例句的词：只提示，不再请求模型（例句全部来自本地词库）
      if (this.currentPassage().missedWords.length > 0) {
        Text(`这 ${this.currentPassage().missedWords.length} 个词暂未收录例句，先看它们的释义`)
          .fontSize(11).fontColor(Colors.TEXT_WEAK).width('100%').margin({ top: 12 })
      }
    }
    .width('100%').padding({ left: 18, right: 18, top: 16, bottom: 16 })
    .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    .margin({ bottom: 14 })
    .opacity(this.contentOpacity)
  }

  /** 例句卡：一个词一条，逐条列出（序号 / 目标词 / 英文 / 中文） */
  @Builder
  PassageCard() {
    Column() {
      Row() {
        Text('词库例句 · 逐词')
          .fontSize(11).fontWeight(FontWeight.Medium).fontColor(Colors.BRAND)
          .backgroundColor(Colors.BRAND_SOFT).borderRadius(6)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        Blank()
        Text(`${this.currentPassage().sentences.length} 条`)
          .fontSize(11).fontColor(Colors.TEXT_WEAK)
      }
      .width('100%').margin({ bottom: 2 })

      ForEach(this.currentPassage().sentences, (s: PassageSentence, idx: number) => {
        this.ExampleRow(s, idx)
      }, (s: PassageSentence, idx: number): string => `ex-${idx}-${s.sentence}`)
    }
    .width('100%').padding({ left: 18, right: 18, top: 16, bottom: 6 })
    .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    .margin({ bottom: 14 })
    .opacity(this.contentOpacity)
  }

  /** 单条例句：序号 + 目标词 + 高亮英文 + 中文 */
  @Builder
  ExampleRow(s: PassageSentence, idx: number) {
    Column() {
      Row() {
        Text(this.pad2(idx + 1))
          .fontSize(11).fontFamily('Georgia').fontColor(Colors.TEXT_WEAK)
        if (s.words.length > 0) {
          Text(s.words[0])
            .fontSize(12).fontWeight(FontWeight.Medium).fontColor(Colors.BRAND)
            .margin({ left: 8 })
        }
        Blank()
      }
      .width('100%').margin({ bottom: 7 })

      Text() {
        ForEach(highlightSegments(s.sentence, this.highlightWords()), (seg: SentenceSegment, i: number) => {
          Span(seg.text)
            .fontColor(seg.hit ? Colors.BRAND : Colors.TEXT_MAIN)
            .fontWeight(seg.hit ? FontWeight.Bold : FontWeight.Regular)
            .textBackgroundStyle({
              color: seg.hit ? Colors.BRAND_SOFT : Color.Transparent,
              radius: 3
            })
        }, (seg: SentenceSegment, i: number): string => `exs-${idx}-${i}-${seg.hit}`)
      }
      .fontSize(TypeScale.BODY).lineHeight(26).width('100%').fontFamily('Georgia')

      Text(s.translation)
        .fontSize(13).lineHeight(21).fontColor(Colors.TEXT_SUB)
        .width('100%').margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 14, bottom: 12 })
    .border({ width: { top: idx === 0 ? 0 : 1 }, color: Colors.DIVIDER })
  }

  /** 骨架屏：4~7 条灰条呼吸 + 一行进行时文案 */
  @Builder
  LoadingView() {
    Column() {
      Row() {
        Text('正在生成')
          .fontSize(11).fontWeight(FontWeight.Medium).fontColor(Colors.BRAND)
          .backgroundColor(Colors.BRAND_SOFT).borderRadius(6)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        Blank()
      }
      .width('100%').margin({ bottom: 12 })

      Column() {
        ForEach([62, 100, 96, 99, 88, 94], (w: number, idx: number) => {
          Row()
            .width(`${w}%`).height(14).borderRadius(8)
            .backgroundColor(Colors.DIVIDER)
            .opacity(this.skOpacity)
            .margin({ bottom: 11 })
        }, (w: number, idx: number): string => `sk-${idx}`)
      }
      .width('100%').alignItems(HorizontalAlign.Start)

      Row() {
        Text('正在翻这本文库…')
          .fontSize(13).fontColor(Colors.TEXT_SUB)
      }
      .width('100%').padding({ top: 6 })
    }
    .width('100%').padding({ left: 18, right: 18, top: 18, bottom: 16 })
    .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    .onAppear(() => this.startBreathe())
  }

  /** 骨架呼吸动画：减弱动效时静止 */
  private startBreathe(): void {
    if (NavStore.INSTANCE.reducedMotion) {
      this.skOpacity = 1;
      return;
    }
    this.skOpacity = 0.45;
    this.getUIContext().animateTo(
      {
        duration: 1400,
        curve: Curve.EaseInOut,
        iterations: -1,
        playMode: PlayMode.Alternate
      },
      () => {
        this.skOpacity = 1;
      }
    );
  }

  /** 降级：不硬造句，给本批单词与本地释义 */
  @Builder
  FallbackView() {
    Column() {
      Row() {
        Text('这批词还没收例句，先看单词释义。')
          .fontSize(12.5).lineHeight(20).fontColor(Colors.FUZZY_ORANGE).layoutWeight(1)
        Button('重试')
          .fontSize(12).fontColor(Colors.BRAND).backgroundColor(Colors.WHITE)
          .height(30).borderRadius(15).padding({ left: 12, right: 12 })
          .onClick(() => this.loadBatch(this.current, true))
      }
      .width('100%').padding({ left: 13, right: 13, top: 11, bottom: 11 })
      .backgroundColor(Colors.FUZZY_ORANGE_SOFT).borderRadius(Radius.CONTROL)
      .margin({ bottom: 12 })

      Column() {
        if (this.batches.length > 0) {
          ForEach(this.batches[this.current], (w: Word, idx: number) => {
            Row() {
              Text(w.english)
                .fontSize(TypeScale.BODY).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
                .fontFamily('Georgia').width(110)
              Text(w.meanings.length > 0 ? w.meanings[0] : '（暂无释义）')
                .fontSize(13).fontColor(Colors.TEXT_SUB).layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%').padding({ top: 11, bottom: 11 })
            .border({ width: { bottom: idx === this.batches[this.current].length - 1 ? 0 : 1 },
              color: Colors.DIVIDER })
          }, (w: Word): string => `fb-${w.id}`)
        }
      }
      .width('100%').padding({ left: 18, right: 18, top: 6, bottom: 6 })
      .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    }
    .width('100%').opacity(this.contentOpacity)
  }

  /** idle：点名册（默认全选，点掉不想用的）+ 底部单条 CTA；列表自己滚，不再三个 Blank 硬顶居中 */
  @Builder
  IdleView() {
    Column() {
      Scroll() {
        Column() {
          // 标题区：eyebrow → 26fp 主标题 → 12.5fp 说明，三级落差就是"眼睛的落点"
          Column() {
            Text('今天要用的词')
              .fontSize(11).fontColor(Colors.TEXT_WEAK).letterSpacing(1.1)
            Text('点掉不想用的')
              .fontSize(26).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
              .margin({ top: 6 })
            Text('默认全选，扫一眼把不合适的取消就行。')
              .fontSize(12.5).fontColor(Colors.TEXT_SUB).margin({ top: 7 })
          }
          .width('100%').alignItems(HorizontalAlign.Start)
          .padding({ left: 20, right: 20, top: 6 })
          .opacity(this.rowsIn ? 1 : 0)
          .translate({ y: this.rowsIn ? 0 : 8 })
          .animation({ duration: Motion.PAGE, curve: Motion.pageCurve() })

          // 计数行 + 一键全选 / 全部取消
          Row() {
            Text(`已选 ${this.selectedCount(this.current)} / ${this.batches.length > 0 ? this.batches[this.current].length : 0}`)
              .fontSize(11).fontColor(Colors.TEXT_WEAK).letterSpacing(0.6)
            Blank()
            Text(this.allSelected() ? '全部取消' : '全选')
              .fontSize(12).fontWeight(FontWeight.Bold).fontColor(Colors.BRAND)
              .padding({ left: 8, right: 2, top: 5, bottom: 5 })
              .onClick(() => {
                this.setAllFlags(!this.allSelected());
              })
          }
          .width('100%').padding({ left: 20, right: 20 })
          .margin({ top: 16, bottom: 9 })
          .opacity(this.rowsIn ? 1 : 0)
          .animation({ duration: Motion.PAGE, delay: 40, curve: Motion.pageCurve() })

          // 册页：单列 52vp 行 = 序号 / 英文 / 音标 / 释义 / 方勾，扫读最快
          Column() {
            Column() {
              if (this.batches.length > 0) {
                ForEach(this.batches[this.current], (w: Word, wi: number) => {
                  Row() {
                    // 选中标记：左侧 3vp 蓝条从 0 滑出，比整行换色更克制
                    Row()
                      .width(this.wordFlag(wi) ? 3 : 0)
                      .height(22).borderRadius(2)
                      .backgroundColor(Colors.BRAND)
                      .margin({ right: 11 })
                      .animation({ duration: Motion.FEEDBACK, curve: Motion.pageCurve() })

                    Text(this.pad2(wi + 1))
                      .fontSize(10).fontColor(Colors.TEXT_WEAK).width(18)

                    Row() {
                      Text(w.english)
                        .fontSize(15).fontFamily('Georgia')
                        .fontColor(this.wordFlag(wi) ? Colors.BRAND_PRESSED : Colors.TEXT_MAIN)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .flexShrink(1)
                        .animation({ duration: Motion.FEEDBACK, curve: Motion.pageCurve() })
                      if (w.phonetic.length > 0) {
                        Text(w.phonetic)
                          .fontSize(9.5).fontColor(Colors.TEXT_WEAK).maxLines(1)
                          .flexShrink(0).margin({ left: 7 })
                      }
                    }
                    .layoutWeight(1).alignItems(VerticalAlign.Center)

                    Text(w.meanings.length > 0 ? w.meanings[0] : '—')
                      .fontSize(10.5).fontColor(Colors.TEXT_WEAK).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width(70).textAlign(TextAlign.End)
                      .margin({ left: 8, right: 10 })

                    Stack() {
                      if (this.wordFlag(wi)) {
                        Text('✓').fontSize(11).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
                      }
                    }
                    .width(20).height(20).borderRadius(6)
                    .backgroundColor(this.wordFlag(wi) ? Colors.BRAND : Color.Transparent)
                    .border({ width: 1.5, color: this.wordFlag(wi) ? Colors.BRAND : PICK_BOX_LINE })
                    .margin({ left: 10 })
                    .animation({ duration: Motion.FEEDBACK, curve: Motion.pageCurve() })
                  }
                  .width('100%').height(52).padding({ left: 14, right: 14 })
                  .backgroundColor(this.wordFlag(wi) ? PICK_ROW_ON_BG : Colors.WHITE)
                  .border({
                    width: { bottom: wi === this.batches[this.current].length - 1 ? 0 : 1 },
                    color: PICK_ROW_LINE
                  })
                  .opacity(this.rowsIn ? 1 : 0)
                  .translate({ y: this.rowsIn ? 0 : 6 })
                  .animation({
                    duration: Motion.FEEDBACK,
                    delay: 60 + Math.min(wi, 20) * 24,
                    curve: Motion.pageCurve()
                  })
                  .onClick(() => this.toggleWordFlag(wi))
                }, (w: Word, wi: number): string => `pick-${this.current}-${wi}-${w.id}`)
              }
            }
            .width('100%')
            .backgroundColor(Colors.WHITE).borderRadius(16)
            .border({ width: 1, color: Colors.DIVIDER })
            .clip(true)
          }
          .width('100%').padding({ left: 16, right: 16 })
        }
        .width('100%').padding({ bottom: 18 })
      }
      .layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)

      // 底部固定 CTA：一处动作，一个按钮，不当场消耗额度
      Column() {
        Row() {
          Text() {
            Span('已选 ').fontSize(12).fontColor(Colors.TEXT_SUB)
            Span(`${this.selectedCount(this.current)}`)
              .fontSize(13).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
            Span(' 个词').fontSize(12).fontColor(Colors.TEXT_SUB)
          }
          Blank()
          Text(`最低 ${MIN_WORDS_FOR_SENTENCE} 个`).fontSize(11).fontColor(Colors.TEXT_WEAK)
        }
        .width('100%').margin({ bottom: 10 })

        Button(this.enoughSelected()
          ? `看 ${this.selectedCount(this.current)} 个词的例句`
          : `至少选 ${MIN_WORDS_FOR_SENTENCE} 个词`)
          .fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
          .width('100%').height(50).borderRadius(Radius.BUTTON)
          .enabled(this.enoughSelected())
          .opacity(this.enoughSelected() ? 1 : 0.45)
          .animation({ duration: Motion.FEEDBACK, curve: Motion.pageCurve() })
          .onClick(() => this.loadBatch(this.current, false))
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 30 })
      .backgroundColor(Colors.PAGE_BG)
      .border({ width: { top: 1 }, color: Colors.DIVIDER })
    }
    .width('100%').layoutWeight(1)
  }

  /** 底部固定操作栏：朗读 / 收藏 / 分享 / 换一批 */
  @Builder
  ActionBar() {
    Row({ space: 8 }) {
      Button('朗读')
        .fontSize(13).fontColor(Colors.TEXT_SUB).backgroundColor(Colors.WHITE)
        .borderRadius(Radius.BUTTON).height(44).layoutWeight(1)
        .enabled(this.currentState().status === 'ok')
        .opacity(this.currentState().status === 'ok' ? 1 : 0.5)
        .onClick(() => this.speakPassage())

      Button(this.isSaved(this.passageEnglish(this.currentPassage())) && this.currentPassage().sentences.length > 0
        ? '已收藏' : '收藏')
        .fontSize(13).fontColor(Colors.TEXT_SUB).backgroundColor(Colors.WHITE)
        .borderRadius(Radius.BUTTON).height(44).layoutWeight(1)
        .enabled(this.currentState().status === 'ok')
        .opacity(this.currentState().status === 'ok' ? 1 : 0.5)
        .onClick(() => this.toggleSavePassage())

      Button('分享')
        .fontSize(13).fontColor(Colors.TEXT_SUB).backgroundColor(Colors.WHITE)
        .borderRadius(Radius.BUTTON).height(44).layoutWeight(1)
        .enabled(this.currentState().status === 'ok' && !this.busy)
        .opacity(this.currentState().status === 'ok' && !this.busy ? 1 : 0.5)
        .onClick(() => {
          this.sharePassage();
        })

      Button(this.currentState().status === 'loading' ? '加载中…' : '重选')
        .fontSize(13).fontColor(Colors.WHITE)
        .backgroundColor(this.currentState().status === 'loading' ? Colors.TEXT_WEAK : Colors.BRAND)
        .borderRadius(Radius.BUTTON).height(44).layoutWeight(1.35)
        .enabled(this.currentState().status !== 'loading')
        .onClick(() => this.refreshBatch())
    }
    .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 26 })
    .backgroundColor(Colors.PAGE_BG)
    .border({ width: { top: 1 }, color: Colors.DIVIDER })
  }

  /** 分享卡面（离屏快照源）：整段摘录 + 覆盖率 */
  @Builder
  PassageShareView() {
    Column() {
      Row() {
        Text('说词 · 今日例句').fontSize(12).fontColor('rgba(255,255,255,0.78)')
        Blank()
        if (this.shareTarget !== null) {
          Text(`覆盖 ${this.shareTarget.coveredWords.length}/${this.shareTarget.coveredWords.length + this.shareTarget.missedWords.length} 词`)
            .fontSize(11).fontColor('rgba(255,255,255,0.72)')
        }
      }.width('100%')

      Blank()
      if (this.shareTarget !== null) {
        if (this.shareTarget.title.length > 0) {
          Text(this.shareTarget.title)
            .fontSize(15).fontColor('rgba(255,255,255,0.86)').width('100%').margin({ bottom: 10 })
        }
        Text(this.passageEnglish(this.shareTarget))
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.WHITE)
          .lineHeight(26).width('100%').maxLines(9)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Blank()
      Text('说词 · 让背单词变有趣')
        .fontSize(11).fontColor('rgba(255,255,255,0.66)').width('100%')
    }
    .width('100%').aspectRatio(0.8).borderRadius(20).padding(20)
    .linearGradient({ angle: 135, colors: [[Colors.BRAND, 0], [Colors.BRAND_PRESSED, 1]] })
  }

  @Builder
  SnapshotPassage() {
    Column() {
      this.PassageShareView()
    }.width(360)
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        if (this.todayCount < MIN_WORDS_FOR_SENTENCE && this.batchStates.length === 0) {
          this.EmptyGate()
        } else {
          this.BatchBar()
          if (this.currentState().status === 'idle') {
            // idle 不放进 Scroll：要的是按钮垂直居中，Scroll 里 layoutWeight 会塌成内容高
            this.IdleView()
          } else {
            Scroll() {
              Column() {
                if (this.currentState().status === 'loading') {
                  this.LoadingView()
                } else if (this.currentState().status === 'fallback') {
                  this.FallbackView()
                } else {
                  this.CoverageCard()
                  this.PassageCard()
                }
              }
              .width('100%').padding({ left: 16, right: 16, bottom: 24 })
            }
            .layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)

            this.ActionBar()
          }
        }
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
    }
    .hideTitleBar(true)
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity + this.showTick * 0)
    .onShown(() => {
      this.showTick++;
      this.animateCovered(true);
      this.reload();
    })
    .onHidden(() => this.animateCovered(false))
    .customTransition((operation: NavigationOperation, isEnter: boolean): NavDestinationTransition[] | undefined => {
      const reduced: boolean = NavStore.INSTANCE.reducedMotion;
      return [{
        duration: reduced ? Motion.REDUCED : Motion.PAGE,
        curve: Curve.EaseOut,
        event: () => {
          if (reduced) {
            this.sheetX = '0%';
            this.sheetOpacity = isEnter ? 1 : 0;
            return;
          }
          if (operation === NavigationOperation.PUSH && isEnter) {
            this.sheetX = '0%';
            this.sheetOpacity = 1;
          } else if (operation === NavigationOperation.POP && !isEnter) {
            this.sheetX = '100%';
            this.sheetOpacity = 0;
          }
        }
      }];
    })
  }
}
