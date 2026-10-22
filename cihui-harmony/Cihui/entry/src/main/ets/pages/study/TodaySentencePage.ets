/**
 * F19 今日例句页（整段生成版）
 *
 * 词源硬规则：只取"今日已学新词 + 今日已复习词"（DataStore.todayWords），不碰未学词；
 * 例句只做语境强化，不进入艾宾浩斯调度、不改任何单词节点（本页对调度数据只读）。
 *
 * 界面口径见 `cihui-ui/daily-sentence-passage-demo.html`，从上到下：
 *   1 顶栏（返回 / 今日例句 / 今日 N 词 + 例句本入口）
 *   2 批次条（第 n 批 · 共 m 批 + 圆点指示器）
 *   3 覆盖率卡（本段覆盖 X/Y 词 + 百分比徽章 + 进度条 + 未覆盖词 chips + 补漏按钮）
 *   4 整段卡（AI 生成 · 整段 / 小标题 / **连续一段**英文 + 折叠中文对照）
 *   5 底部固定操作栏（朗读 / 收藏 / 分享 / 换一批）
 *
 * 状态机沿用 BatchState：
 *   idle      未生成，给「生成例句」大按钮（不白扣一次模型调用）
 *   loading   骨架屏 4~7 条灰条呼吸 + 「正在用今天的词写一段…」
 *   ok        渲染 3、4
 *   fallback  本批单词释义 + 重试横幅（未配 Key / 无网 / 超时 / 非法 JSON）
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
import type { SentenceSegment, Word } from '../../model/Types';
import type { PassageResult, PassageSentence } from '../../model/SentenceCore';
import {
  MIN_WORDS_FOR_SENTENCE,
  PASSAGE_COVERAGE_TARGET,
  SENTENCE_BATCH_SIZE,
  chunkItems,
  highlightSegments,
} from '../../model/SentenceCore';
import { dayKeyFromTs } from '../../model/SchedulerCore';
import { SentenceGenerator } from '../../service/SentenceGeneratorService';
import { TtsService } from '../../service/TtsService';
import type { TtsState } from '../../service/TtsService';
import { MemeCardService } from '../../service/MemeCardService';
import { ShareService } from '../../service/ShareService';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

/** 单批加载状态机：idle 未生成 / loading 生成中 / ok 成功 / fallback 本地降级 */
@ObservedV2
class BatchState {
  index: number;
  status: string;
  /** 整段结果（ok 时非空） */
  passage: PassageResult | null;

  constructor(index: number) {
    this.index = index;
    this.status = 'idle';
    this.passage = null;
  }
}

@ComponentV2
export struct TodaySentencePage {
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 0;
  @Local showTick: number = 0;
  @Local todayCount: number = 0;
  @Local batches: Word[][] = [];
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
    const states: BatchState[] = [];
    for (let i = 0; i < this.batches.length; i++) {
      states.push(new BatchState(i));
    }
    this.batchStates = states;
    this.current = 0;
    // 首屏停在 idle：整段生成一次要花十几秒、还会消耗额度，等用户主动点「生成例句」。
    // 切到别的批时不拦（用户明确想看那一批），见 switchBatch。
  }

  /** 生成 / 重新生成一批 */
  private loadBatch(index: number, refresh: boolean): void {
    if (index < 0 || index >= this.batchStates.length || this.batches.length === 0) {
      return;
    }
    const state: BatchState = this.batchStates[index];
    if (state.status === 'loading') {
      return;
    }
    this.loadingSeq++;
    const seq: number = this.loadingSeq;
    state.status = 'loading';
    state.passage = null;
    this.patching = false;
    this.patchedWords = [];
    this.zhOpen = false;
    this.batchStates = this.batchStates.slice();
    const words: Word[] = this.batches[index];
    if (!SentenceGenerator.available()) {
      // 未配置 Key：不发请求，直接本地释义降级
      this.finishFallback(seq, index);
      return;
    }
    SentenceGenerator.generatePassage(words)
      .then((result: PassageResult): void => {
        if (seq !== this.loadingSeq) {
          return; // 期间又切了批，丢弃过期结果
        }
        state.passage = result;
        state.status = 'ok';
        this.batchStates = this.batchStates.slice();
        this.fadeIn();
      })
      .catch((e: Object): void => {
        console.warn(`[Sentence] batch ${index} fallback: ${(e as Error)?.message ?? e}`);
        this.finishFallback(seq, index);
      });
  }

  /** 覆盖率卡上的「补漏一次」：只补一次，失败保留现有短文 */
  private patchCurrent(): void {
    if (this.patching || this.batches.length === 0) {
      return;
    }
    const state: BatchState = this.currentState();
    const before: PassageResult | null = state.passage;
    if (before === null || before.missedWords.length === 0) {
      return;
    }
    if (!SentenceGenerator.available()) {
      this.toast('当前无法生成例句，先看看单词释义');
      return;
    }
    this.patching = true;
    const pending: string[] = before.missedWords.slice();
    SentenceGenerator.patchPassage(before, this.batches[this.current])
      .then((next: PassageResult): void => {
        this.patching = false;
        const gained: number = next.coveredWords.length - before.coveredWords.length;
        state.passage = next;
        state.status = 'ok';
        if (gained > 0) {
          this.patchedWords = pending;
          this.toast(`又用上 ${gained} 个词`);
        } else {
          this.patchedWords = [];
          this.toast('这次没补上新词，换一批试试');
        }
        this.batchStates = this.batchStates.slice();
      })
      .catch((e: Object): void => {
        this.patching = false;
        console.warn(`[Sentence] patch: ${(e as Error)?.message ?? e}`);
        this.toast('补漏没成功，已保留当前短文');
      });
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

  /** 「换一批」：先淡出再请求，回来淡入（整段约 300ms） */
  private refreshBatch(): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    if (reduced) {
      this.loadBatch(this.current, true);
      return;
    }
    this.getUIContext().animateTo(
      { duration: 150, curve: Curve.EaseIn },
      () => {
        this.contentOpacity = 0.2;
      }
    );
    setTimeout(() => this.loadBatch(this.current, true), 160);
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
      Text('用今天背的词写一段，读完就记住了')
        .fontSize(13).fontColor(Colors.TEXT_SUB)
        .textAlign(TextAlign.Center).width('76%').margin({ top: 6 })
      Button('去背单词 →')
        .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
        .borderRadius(Radius.BUTTON).height(46).width(180).margin({ top: 24 })
        .onClick(() => NavStore.INSTANCE.backToTab(1))
      Blank()
    }.width('100%').layoutWeight(1)
  }

  /** 批次条：第 n 批 · 共 m 批 + 圆点指示器（当前批是加长胶囊） */
  @Builder
  BatchBar() {
    Row() {
      Row() {
        Text(`第 ${this.current + 1} 批`)
          .fontSize(TypeScale.CAPTION).fontColor(Colors.BRAND).fontWeight(FontWeight.Medium)
        Text(` · 共 ${this.batchStates.length} 批`)
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB)
      }
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(Colors.WHITE).borderRadius(99)
      .border({ width: 1, color: Colors.DIVIDER })

      Blank()

      Row({ space: 5 }) {
        ForEach(this.batchStates, (st: BatchState) => {
          Row()
            .width(st.index === this.current ? 18 : 7)
            .height(7)
            .borderRadius(99)
            .backgroundColor(st.index === this.current ? Colors.BRAND : Colors.TEXT_WEAK)
            .opacity(st.index === this.current ? 1 : 0.45)
            .onClick(() => this.switchBatch(st.index))
        }, (st: BatchState): string => `dot-${st.index}`)
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
        Text('本段覆盖')
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

      // 补漏按钮：覆盖率不足且有漏词才出现
      if (this.currentPassage().missedWords.length > 0 && !this.coverageOk()) {
        Button() {
          Text(this.patching
            ? `正在补写剩下 ${this.currentPassage().missedWords.length} 个词…`
            : `补漏一次，把剩下 ${this.currentPassage().missedWords.length} 个词写进去`)
            .fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(this.patching ? Colors.TEXT_WEAK : Colors.BRAND)
        }
        .width('100%').height(38).borderRadius(Radius.CONTROL)
        .backgroundColor(Colors.BRAND_SOFT)
        .border({ width: 1, color: this.patching ? Colors.DIVIDER : Colors.BRAND })
        .enabled(!this.patching)
        .margin({ top: 12 })
        .onClick(() => this.patchCurrent())
      }
    }
    .width('100%').padding({ left: 18, right: 18, top: 16, bottom: 16 })
    .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    .margin({ bottom: 14 })
    .opacity(this.contentOpacity)
  }

  /** 整段卡：小标题 + 连续一段英文（今日词高亮）+ 折叠中文对照 */
  @Builder
  PassageCard() {
    Column() {
      Row() {
        Text('AI 生成 · 整段')
          .fontSize(11).fontWeight(FontWeight.Medium).fontColor(Colors.BRAND)
          .backgroundColor(Colors.BRAND_SOFT).borderRadius(6)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        Blank()
      }
      .width('100%').margin({ bottom: 12 })

      if (this.currentPassage().title.length > 0) {
        Text(this.currentPassage().title)
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
          .width('100%').margin({ bottom: 10 })
          .textAlign(TextAlign.Start)
      }

      // 连续段落：所有句子拼成一段，不分句成卡
      Text() {
        ForEach(this.passageSegments(), (seg: SentenceSegment, idx: number) => {
          Span(seg.text)
            .fontColor(seg.hit ? Colors.BRAND : Colors.TEXT_MAIN)
            .fontWeight(seg.hit ? FontWeight.Bold : FontWeight.Regular)
            .textBackgroundStyle({
              color: seg.hit ? Colors.BRAND_SOFT : Color.Transparent,
              radius: 3
            })
        }, (seg: SentenceSegment, idx: number): string => `ps-${idx}-${seg.hit}`)
      }
      .fontSize(TypeScale.BODY).lineHeight(27).width('100%')
      .fontFamily('Georgia')

      // 折叠中文对照
      Row() {
        Text(this.zhOpen ? '收起中文对照' : '展开中文对照')
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB)
        Text(this.zhOpen ? '▴' : '▾')
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB).margin({ left: 4 })
      }
      .width('100%').justifyContent(FlexAlign.Center)
      .padding({ top: 10, bottom: 2 })
      .border({ width: { top: 1 }, color: Colors.DIVIDER })
      .margin({ top: 14 })
      .onClick(() => {
        this.zhOpen = !this.zhOpen;
      })

      if (this.zhOpen) {
        Column() {
          ForEach(this.currentPassage().sentences, (s: PassageSentence, idx: number) => {
            Text(s.translation)
              .fontSize(13.5).lineHeight(24).fontColor(Colors.TEXT_SUB)
              .width('100%').margin({ bottom: 8 })
          }, (s: PassageSentence, idx: number): string => `zh-${idx}`)
        }
        .width('100%').margin({ top: 10 })
      }
    }
    .width('100%').padding({ left: 18, right: 18, top: 18, bottom: 12 })
    .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    .margin({ bottom: 14 })
    .opacity(this.contentOpacity)
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
        Text('正在用今天的词写一段…')
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
        Text('当前无法生成例句，先看看这批单词的意思。网络恢复后点「重试」。')
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

  /** idle：还没生成，给一个大按钮（不替用户白扣额度） */
  @Builder
  IdleView() {
    Column() {
      Blank()
      Text('今天有 ' + this.batches.length + ' 批词')
        .fontSize(13).fontColor(Colors.TEXT_SUB)
      Text('点下面的按钮，用今天的词写一段连贯短文')
        .fontSize(13).fontColor(Colors.TEXT_WEAK).margin({ top: 6 })
      Button('生成例句')
        .fontSize(16).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
        .borderRadius(Radius.BUTTON).height(50).width(220).margin({ top: 22 })
        .onClick(() => this.loadBatch(this.current, false))
      Blank()
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
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

      Button(this.currentState().status === 'loading' ? '生成中…' : '换一批')
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
        Text('词慧 · 今日例句').fontSize(12).fontColor('rgba(255,255,255,0.78)')
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
      Text('词慧 · 让背单词变有趣')
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
