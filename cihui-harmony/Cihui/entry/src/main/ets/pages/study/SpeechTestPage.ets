/**
 * F8 语音快过 · 字幕式 ASR（看英文说中文）
 *
 * - 英文大号居中、中文释义隐藏；进卡自动 TTS 朗读英文，随后麦克风流式识别；
 * - HMS speechRecognizer（zh-CN 离线）onResult 中间结果逐字上屏（带光标），
 *   最终结果走 SpeechMatch 按 settings.asrStrictness 三档匹配；
 * - 命中核心义项：绿闪 + 约 1s 自动过词；静音/没说对不自动过，可用底部三档手动判定；
 * - 红色麦克风暂停/继续；一键切手动；权限拒绝给「去设置 / 手动模式」，进度不丢；
 * - 一轮结束进复核清单，可逐词改判，确认后一次性落 FIRST 判定并回首页；
 * - 中途退出不丢：每次判定/推进即时写断点草稿（RoundDraftStore），
 *   重进按 wordId 回填判定并从上次那个词继续，确认后才清草稿。
 *
 * TODO(待真机核验)：TTS 播报与麦克风采集的音频焦点/回声；识别引擎可用性与中文识别率。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { RouteName } from '../../common/RouteNames';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import type { SpeechRouteParam } from '../../common/RouteNames';
import type { ReviewRouteParam } from '../../common/RouteNames';
import type { AsrListener, AsrState } from '../../service/SpeechService';
import { HmsSpeechService } from '../../service/SpeechService';
import { TtsService } from '../../service/TtsService';
import { PermissionUtil } from '../../service/PermissionUtil';
import { matchSpoken } from '../../model/SpeechMatch';
import type { Strictness } from '../../model/SpeechMatch';
import type { RoundVerdict, Verdict, Word } from '../../model/Types';
import { RoundDraftStore } from '../../service/RoundDraftStore';
import type { RoundDraft, RoundDraftEntry } from '../../service/RoundDraftStore';
import { StudySessionStore } from '../../service/StudySessionStore';
import type { SessionStep, NewWordSession } from '../../service/StudySessionStore';
import { continueToday } from '../../viewmodel/StudyEntry';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import type { Permissions } from '@kit.AbilityKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

@ObservedV2
class RoundItem {
  wordId: string;
  english: string;
  phonetic: string;
  meanings: string[];
  @Trace verdict: Verdict | null = null;
  @Trace heard: string = '';

  constructor(word: Word) {
    this.wordId = word.id;
    this.english = word.english;
    this.phonetic = word.phonetic;
    this.meanings = word.meanings;
  }
}

@ComponentV2
export struct SpeechTestPage {
  @Require @Param param: SpeechRouteParam;

  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.SPEECH_TEST) {
      this.showTick++;
    }
  };
  @Local sheetOpacity: number = 0;
  @Local items: RoundItem[] = [];
  @Local index: number = 0;
  /** round 测试中 / review 复核清单 */
  @Local phase: string = 'round';
  /** asr 语音模式 / manual 手动模式 */
  @Local mode: string = 'asr';
  @Local asrState: AsrState = 'idle';
  @Local micPaused: boolean = false;
  @Local interim: string = '';
  @Local flash: string = ''; // '' | green | orange | red
  @Local flashLabel: string = '';
  @Local permDenied: boolean = false;
  @Local cursorVisible: boolean = true;
  /** 本次进入是从上次中断处续上的：onShown 后提示一次 */
  @Local pendingResumeTip: boolean = false;

  private service: HmsSpeechService = new HmsSpeechService();
  private listener: AsrListener = new SpeechPageAsrListener(this);
  private autoTimer: number = -1;
  private micStartTimer: number = -1;
  private cursorTimer: number = -1;
  private wordErrorCount: number = 0;
  private released: boolean = false;

  onAsrPartial(text: string): void {
    this.interim = text;
  }

  onAsrFinal(text: string): void {
    this.handleFinal(text);
  }

  onAsrError(code: number, message: string): void {
    console.warn(`[SpeechTest] asr error ${code} ${message}`);
    this.wordErrorCount += 1;
    if (this.wordErrorCount >= 2) {
      this.asrState = 'unavailable';
      this.mode = 'manual';
      this.toast('语音识别不可用，已切换手动判定');
    } else {
      // 偶发错误：为当前词重开一个会话
      this.service.endWord();
      this.service.beginWord();
    }
  }

  onAsrStateChange(state: AsrState): void {
    this.asrState = state;
  }

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    const words: Word[] = this.param.wordIds
      .map((id: string): Word | undefined =>
        DataStore.INSTANCE.words.find((w: Word): boolean => w.id === id))
      .filter((w: Word | undefined): boolean => w !== undefined)
      .map((w: Word | undefined): Word => w as Word);
    this.items = words.map((w: Word): RoundItem => new RoundItem(w));
    // 断点续做：上次退出时存的判定与位置（跨天/换批自动作废）
    const resumed: boolean = this.restoreDraft();
    if (resumed) {
      this.pendingResumeTip = true;
    }

    this.cursorTimer = setInterval(() => {
      this.cursorVisible = !this.cursorVisible;
    }, 530);

    // TTS 引擎需先初始化（此前遗漏，导致本页喇叭只在别的页面 init 过时才有声）
    TtsService.init(DataStore.INSTANCE.settings.ttsRate);

    if (this.items.length > 0) {
      if (this.phase === 'review') {
        // 续上的是复核态：不申请麦克风，判定都还在草稿里，等用户确认
        this.micPaused = true;
      } else {
        this.bootAsr();
      }
    }
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
    this.released = true;
    this.clearTimers();
    this.service.release();
    TtsService.stop();
  }

  private clearTimers(): void {
    if (this.autoTimer !== -1) {
      clearTimeout(this.autoTimer);
      this.autoTimer = -1;
    }
    if (this.micStartTimer !== -1) {
      clearTimeout(this.micStartTimer);
      this.micStartTimer = -1;
    }
    if (this.cursorTimer !== -1) {
      clearInterval(this.cursorTimer);
      this.cursorTimer = -1;
    }
  }

  /**
   * 从草稿续上本轮：按 wordId 回填判定，定位到第一个未判定的词；
   * 全部判完则直接进复核态。跨天或一个判定都没有时从头开始。
   * @returns 是否真的续上了进度
   */
  private restoreDraft(): boolean {
    if (this.items.length === 0) {
      return false;
    }
    const draft: RoundDraft | null = RoundDraftStore.load(RoundDraftStore.SPEECH);
    if (draft === null) {
      return false;
    }
    const byId: Map<string, RoundDraftEntry> = new Map();
    draft.entries.forEach((e: RoundDraftEntry): void => {
      byId.set(e.wordId, e);
    });
    let restored: number = 0;
    this.items.forEach((it: RoundItem): void => {
      const e: RoundDraftEntry | undefined = byId.get(it.wordId);
      if (e === undefined) {
        return;
      }
      if (e.heard.length > 0) {
        it.heard = e.heard;
      }
      if (e.verdict === 'KNOWN') {
        it.verdict = 'KNOWN';
        restored += 1;
      } else if (e.verdict === 'VAGUE') {
        it.verdict = 'VAGUE';
        restored += 1;
      } else if (e.verdict === 'UNKNOWN') {
        it.verdict = 'UNKNOWN';
        restored += 1;
      }
    });
    if (restored === 0) {
      return false;
    }
    let next: number = -1;
    for (let i: number = 0; i < this.items.length; i++) {
      if (this.items[i].verdict === null) {
        next = i;
        break;
      }
    }
    if (next < 0) {
      this.index = this.items.length - 1;
      this.phase = 'review';
      this.micPaused = true;
    } else {
      this.index = next;
      this.phase = 'round';
    }
    return true;
  }

  /** 保存本轮草稿：每次判定/推进后调用，退出与杀进程都不丢（确认后才清） */
  private saveDraft(): void {
    if (this.items.length === 0) {
      return;
    }
    const entries: RoundDraftEntry[] = this.items.map((it: RoundItem): RoundDraftEntry => {
      const e: RoundDraftEntry = {
        wordId: it.wordId,
        verdict: it.verdict === null ? '' : it.verdict,
        heard: it.heard,
      };
      return e;
    });
    const judged: number = entries.filter((e: RoundDraftEntry): boolean => e.verdict.length > 0).length;
    if (judged === 0) {
      // 一个词都没判过：不留空草稿，重进本来也是从头开始
      RoundDraftStore.clear(RoundDraftStore.SPEECH);
      return;
    }
    const ids: string[] = this.items.map((it: RoundItem): string => it.wordId);
    const draft: RoundDraft = {
      kind: RoundDraftStore.SPEECH,
      mode: 'NEW',
      day: RoundDraftStore.today(),
      wordIds: ids,
      index: this.index,
      phase: this.phase,
      entries: entries,
      total: this.items.length,
      knownCount: 0,
      vagueCount: 0,
      unknownCount: 0,
      savedAt: Date.now(),
    };
    RoundDraftStore.save(draft);
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (e) {
      console.warn(`[SpeechTest] toast failed: ${(e as Error)?.message ?? e}`);
    }
  }

  private strictness(): Strictness {
    const s: string = DataStore.INSTANCE.settings.asrStrictness;
    if (s === 'LOW') {
      return 'LEN';
    }
    if (s === 'HIGH') {
      return 'STRICT';
    }
    return 'MID';
  }

  private async bootAsr(): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const granted: boolean =
        await PermissionUtil.request(context, 'ohos.permission.MICROPHONE' as Permissions);
      if (!granted) {
        this.permDenied = true;
        this.mode = 'manual';
        TtsService.speak(this.items[this.index].english);
        return;
      }
    } catch (e) {
      console.warn(`[SpeechTest] mic permission failed: ${(e as Error)?.message ?? e}`);
      this.permDenied = true;
      this.mode = 'manual';
      TtsService.speak(this.items[this.index].english);
      return;
    }

    this.asrState = 'creating';
    this.service.setListener(this.listener);
    const ok: boolean = await this.service.init();
    if (this.released) {
      return;
    }
    if (!ok) {
      this.asrState = 'unavailable';
      this.mode = 'manual';
      this.toast('语音识别不可用，可用手动三档完成本轮');
      TtsService.speak(this.items[this.index].english);
      return;
    }
    this.startWord();
  }

  /** 进词：先播报英文，再开麦克风（避免 TTS 被识别入口述） */
  private startWord(): void {
    this.interim = '';
    this.flash = '';
    this.flashLabel = '';
    this.wordErrorCount = 0;
    const word: RoundItem = this.items[this.index];
    TtsService.speak(word.english);
    if (this.mode === 'asr' && !this.micPaused && this.asrState !== 'unavailable') {
      if (this.micStartTimer !== -1) {
        clearTimeout(this.micStartTimer);
      }
      this.micStartTimer = setTimeout(() => {
        this.micStartTimer = -1;
        if (this.mode === 'asr' && !this.micPaused && this.phase === 'round') {
          this.service.beginWord();
        }
      }, 680);
    }
  }

  private handleFinal(text: string): void {
    if (this.phase !== 'round' || this.micPaused) {
      return;
    }
    const item: RoundItem = this.items[this.index];
    item.heard = text;
    const r = matchSpoken(text, item.meanings, this.strictness());
    if (r.known) {
      item.verdict = 'KNOWN';
      this.flash = 'green';
      this.flashLabel = `认识：${r.matched}`;
      this.service.endWord();
      this.saveDraft();
      this.autoTimer = setTimeout(() => {
        this.autoTimer = -1;
        this.advance();
      }, 1000);
    }
    // 没命中：静默等待用户再说或手动判定，不自动过词
  }

  /** 手动三档（语音模式下也常显，为等价操作与降级路径） */
  private manualJudge(verdict: Verdict): void {
    if (this.autoTimer !== -1) {
      clearTimeout(this.autoTimer);
      this.autoTimer = -1;
    }
    const item: RoundItem = this.items[this.index];
    item.verdict = verdict;
    if (verdict === 'KNOWN') {
      this.flash = 'green';
      this.flashLabel = '认识';
    } else if (verdict === 'VAGUE') {
      this.flash = 'orange';
      this.flashLabel = '模糊';
    } else {
      this.flash = 'red';
      this.flashLabel = '不认识';
    }
    this.service.endWord();
    this.saveDraft();
    this.autoTimer = setTimeout(() => {
      this.autoTimer = -1;
      this.advance();
    }, 360);
  }

  private advance(): void {
    if (this.index < this.items.length - 1) {
      this.index += 1;
      this.saveDraft();
      this.startWord();
    } else {
      this.enterReview();
    }
  }

  private enterReview(): void {
    this.service.endWord();
    this.phase = 'review';
    this.micPaused = true;
    this.saveDraft();
  }

  private toggleMic(): void {
    if (this.asrState === 'unavailable' || this.asrState === 'creating') {
      this.toast('语音识别未就绪，请用手动按钮');
      return;
    }
    if (this.micPaused) {
      this.micPaused = false;
      this.interim = '';
      this.service.beginWord();
    } else {
      this.micPaused = true;
      this.interim = '';
      this.service.endWord();
    }
  }

  private switchMode(): void {
    if (this.mode === 'asr') {
      this.mode = 'manual';
      this.micPaused = true;
      this.service.endWord();
      this.toast('已切手动模式');
    } else {
      if (this.asrState === 'unavailable') {
        this.toast('语音识别不可用，无法切回');
        return;
      }
      this.mode = 'asr';
      this.micPaused = false;
      this.service.beginWord();
    }
  }

  private openSettings(): void {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      PermissionUtil.openAppSettings(context);
    } catch (e) {
      this.toast('请在系统设置中开启麦克风权限');
    }
  }

  private useManual(): void {
    this.permDenied = false;
    this.mode = 'manual';
    this.toast('已进入手动模式，用下方三档判定');
  }

  private setReviewVerdict(item: RoundItem, verdict: Verdict): void {
    item.verdict = verdict;
    this.saveDraft();
  }

  private allJudged(): boolean {
    return this.items.every((it: RoundItem): boolean => it.verdict !== null);
  }

  private confirmRound(): void {
    if (!this.allJudged()) {
      this.toast('还有单词未判定，请逐词选择认识/模糊/不认识');
      return;
    }
    const verdicts: RoundVerdict[] = this.items.map((it: RoundItem): RoundVerdict => {
      return { wordId: it.wordId, verdict: it.verdict, heard: it.heard };
    });
    DataStore.INSTANCE.applyFirstRound(verdicts);
    // 本轮已确认落调度，断点草稿使命结束（再次进入即全新一轮）
    RoundDraftStore.clear(RoundDraftStore.SPEECH);
    RoundDraftStore.clearBrowse();
    this.clearTimers();
    this.service.release();
    TtsService.stop();

    // 分组学习：本组判完即推进会话，直接进下一步（下一组看词 / 下一批模糊重考 / 收尾）
    if (this.param.chunk === true) {
      const session: NewWordSession | null = StudySessionStore.begin();
      if (session === null) {
        NavStore.INSTANCE.finishToHome();
        return;
      }
      StudySessionStore.finishStep(session, verdicts, this.param.retest === true);
      const step: SessionStep = StudySessionStore.step(session);
      if (step.kind !== 'done') {
        this.toast(this.param.retest === true
          ? '这批重考完成，继续下一批'
          : `第 ${this.param.groupIndex} 组完成，继续下一组`);
        continueToday();
        return;
      }
      // 今日新词全部走完（含模糊重考）：若还有到期复习词，按原口径直接切复习
      const remainAll: Word[] = DataStore.INSTANCE.todayReviewWordList();
      if (remainAll.length > 0) {
        this.toast(`新学完成，进入复习模式（${remainAll.length} 个待复习）`);
        const ids: string[] = remainAll.map((w: Word): string => w.id);
        const p: ReviewRouteParam = { wordIds: ids, title: '到期复习', mode: 'REVIEW' };
        NavStore.INSTANCE.finishToHome();
        NavStore.INSTANCE.push(RouteName.REVIEW_CARDS, p);
      } else {
        this.toast('今日新词已全部完成，调度已更新');
        NavStore.INSTANCE.finishToHome();
      }
      return;
    }

    // F-C 统一入口：新学完成后若当天还有到期复习词，提示并直接切换复习模式（通知式，不强制额外操作）。
    // 中途退出不丢：每次判定/推进都写断点草稿（RoundDraftStore），重进从上次那个词继续。
    const remain: Word[] = DataStore.INSTANCE.todayReviewWordList();
    if (remain.length > 0) {
      this.toast(`新学完成，进入复习模式（${remain.length} 个待复习）`);
      const ids: string[] = remain.map((w: Word): string => w.id);
      const param: ReviewRouteParam = { wordIds: ids, title: '到期复习', mode: 'REVIEW' };
      NavStore.INSTANCE.finishToHome();
      NavStore.INSTANCE.push(RouteName.REVIEW_CARDS, param);
    } else {
      this.toast('本轮完成，调度已更新');
      NavStore.INSTANCE.finishToHome();
    }
  }

  /** 本轮是否存在未提交的判定：round 已过至少一题，或已进入复核清单 */
  private hasUncommitted(): boolean {
    return (this.phase === 'round' && this.index > 0) || this.phase === 'review';
  }

  /** 顶栏返回 / 系统返回统一入口：先存草稿（退出不丢），再给一次防误触确认 */
  private confirmExit(): void {
    this.saveDraft();
    if (!this.hasUncommitted()) {
      NavStore.INSTANCE.back();
      return;
    }
    const total: number = this.items.length;
    const message: string = this.phase === 'review'
      ? `本轮 ${total} 个词已判定完，进度已保存，下次进入直接回到复核清单。`
      : `已背到第 ${this.index + 1} / ${total} 个词，进度已保存，下次进入从这里继续。`;
    try {
      promptAction.showDialog({
        title: '退出本轮？',
        message: message,
        buttons: [
          { text: '继续本轮', color: Colors.BRAND },
          { text: '退出', color: Colors.TEXT_SUB },
        ],
      }, (err: Error, result: promptAction.ShowDialogSuccessResponse) => {
        if (!err && result.index === 1) {
          this.saveDraft();
          NavStore.INSTANCE.back();
        }
      });
    } catch (e) {
      console.warn(`[SpeechTest] confirmExit dialog failed: ${(e as Error)?.message ?? e}`);
      NavStore.INSTANCE.back();
    }
  }

  /** 系统返回键：有未提交进度则拦下并二次确认（返回 true 消费事件） */
  private handleBackPressed(): boolean {
    if (!this.hasUncommitted()) {
      return false;
    }
    this.confirmExit();
    return true;
  }

  /** 顶栏标题：分组/重考时带批次信息 */
  private pageTitle(): string {
    if (this.param.retest === true) {
      const n: number = this.param.batchTotal ?? 0;
      return n > 0 ? `模糊重考 · ${n} 个` : '模糊重考';
    }
    const groupTotal: number = this.param.groupTotal ?? 1;
    if (this.param.chunk === true && groupTotal > 1) {
      const gi: number = this.param.groupIndex ?? 1;
      return `语音快过 · 第 ${gi} / ${groupTotal} 组`;
    }
    return '语音快过';
  }

  /** 复核页标题与确认按钮文案（分组模式下是「本组」而不是「本轮」） */
  private reviewTitle(): string {
    if (this.param.chunk !== true) {
      return '本轮复核';
    }
    return this.param.retest === true ? '本批重考复核' : '本组复核';
  }

  private confirmLabel(): string {
    if (!this.allJudged()) {
      return '还有单词未判定';
    }
    if (this.param.chunk !== true) {
      return '确认并返回首页';
    }
    return this.param.retest === true ? '确认，继续重考' : '确认，继续下一组';
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

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => this.confirmExit())

      Text(this.pageTitle())
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Button(this.mode === 'asr' ? '手动' : '语音')
        .fontSize(13).fontColor(Colors.BRAND).backgroundColor(Colors.BRAND_SOFT)
        .borderRadius(14).height(30).padding({ left: 12, right: 12 }).margin({ right: 4 })
        .onClick(() => this.switchMode())
    }
    .width('100%').height(56)
  }

  @Builder
  RoundBody() {
    Column() {
      // 进度条（固定顶部）
      Row() {
        Row()
          .width(`${((this.index + 1) / this.items.length) * 100}%`)
          .height(4).borderRadius(2).backgroundColor(Colors.BRAND)
          .animation({ duration: Motion.FEEDBACK, curve: Curve.EaseOut })
      }
      .width('100%').height(4).backgroundColor(Colors.DIVIDER).borderRadius(2)
      .margin({ top: 6 })

      Text(`${this.index + 1} / ${this.items.length}`)
        .fontSize(13).fontColor(Colors.TEXT_SUB).margin({ top: 10 })

      // P7：中部内容可滚动，小屏（含模拟器导航条）不再把三档按钮顶出屏幕
      Scroll() {
        Column() {
          // 英文单词
          Text(this.items[this.index].english)
            .fontSize(40).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
            .textAlign(TextAlign.Center).maxLines(2).width('90%')
            .margin({ top: 24 })
          Text(this.items[this.index].phonetic)
            .fontSize(15).fontColor(Colors.TEXT_SUB).margin({ top: 8 })

          // 反馈条
          if (this.flash.length > 0) {
            Text(this.flashLabel)
              .fontSize(18).fontWeight(FontWeight.Medium)
              .fontColor(this.flash === 'green' ? Colors.KNOW_GREEN :
                this.flash === 'orange' ? Colors.FUZZY_ORANGE : Colors.UNKNOWN_RED)
              .margin({ top: 18 })
          } else {
            Text('看英文，大声说出中文意思')
              .fontSize(13).fontColor(Colors.TEXT_WEAK).margin({ top: 18 })
          }

          // 字幕区
          Column() {
            if (this.mode === 'asr' && !this.micPaused && this.asrState !== 'unavailable') {
              Text(this.interim.length > 0 ?
                `${this.interim}${this.cursorVisible ? '▍' : ''}` :
                `${this.cursorVisible ? '正在听… ▍' : '正在听…'}`)
                .fontSize(20).fontColor(Colors.TEXT_MAIN).textAlign(TextAlign.Center)
                .constraintSize({ minHeight: 56 }).width('100%').padding({ left: 16, right: 16 })
            } else if (this.mode === 'manual') {
              Text('手动模式：用下方按钮判定')
                .fontSize(16).fontColor(Colors.TEXT_SUB).textAlign(TextAlign.Center)
                .constraintSize({ minHeight: 56 }).width('100%')
            } else {
              Text(this.micPaused ? '已暂停，点麦克风继续' : '准备中…')
                .fontSize(16).fontColor(Colors.TEXT_SUB).textAlign(TextAlign.Center)
                .constraintSize({ minHeight: 56 }).width('100%')
            }
          }
          .width('92%')
          .backgroundColor(Colors.WHITE)
          .borderRadius(Radius.CARD)
          .padding({ top: 16, bottom: 16 })
          .margin({ top: 22, bottom: 18 })

          // 麦克风（仅语音模式）
          if (this.mode === 'asr') {
            Button() {
              Image($r('app.media.ic_mic')).width(30).height(30).fillColor(Colors.WHITE)
            }
            .type(ButtonType.Circle)
            .width(72).height(72)
            .backgroundColor(this.micPaused ? Colors.TEXT_WEAK : Colors.UNKNOWN_RED)
            .shadow(this.micPaused ? ShadowStyle.OUTER_DEFAULT_XS : ShadowStyle.OUTER_DEFAULT_MD)
            .margin({ bottom: 8 })
            .onClick(() => this.toggleMic())
            Text(this.micPaused ? '已暂停，点击继续' : '点击麦克风可暂停')
              .fontSize(12).fontColor(Colors.TEXT_WEAK).margin({ bottom: 12 })
          }

          if (this.permDenied) {
            Column() {
              Text('需要麦克风权限才能听你口述中文')
                .fontSize(13).fontColor(Colors.FUZZY_ORANGE).textAlign(TextAlign.Center)
              Row() {
                Button('去设置开启')
                  .fontSize(13).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
                  .borderRadius(Radius.BUTTON).height(38).padding({ left: 14, right: 14 })
                  .onClick(() => this.openSettings())
                Button('先用手动')
                  .fontSize(13).fontColor(Colors.TEXT_MAIN).backgroundColor(Colors.WHITE)
                  .borderRadius(Radius.BUTTON).height(38).padding({ left: 14, right: 14 })
                  .margin({ left: 10 })
                  .onClick(() => this.useManual())
              }
              .margin({ top: 10 })
            }
            .margin({ bottom: 12 })
          }
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .justifyContent(FlexAlign.Center)
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      // 手动三档（固定底部，避让系统导航条安全区）
      Row() {
        Button('不认识')
          .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.UNKNOWN_RED)
          .borderRadius(Radius.BUTTON).height(48).layoutWeight(1)
          .onClick(() => this.manualJudge('UNKNOWN'))
        Button('模糊')
          .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.FUZZY_ORANGE)
          .borderRadius(Radius.BUTTON).height(48).layoutWeight(1).margin({ left: 10 })
          .onClick(() => this.manualJudge('VAGUE'))
        Button('认识')
          .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.KNOW_GREEN)
          .borderRadius(Radius.BUTTON).height(48).layoutWeight(1).margin({ left: 10 })
          .onClick(() => this.manualJudge('KNOWN'))
      }
      .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 })
      .safeAreaPadding({ bottom: 14 })
    }
    // 必须用 layoutWeight 而非 height('100%')：build() 根 Column 已含 TopBar，
    // height('100%') 会按 NavDestination 全高解析而溢出父容器 84px，把底部三档按钮
    // 顶进系统导航区（真机实测按钮下半段落在 2322–2406 被系统吞掉）。
    .width('100%').layoutWeight(1)
  }

  @Builder
  VerdictChip(item: RoundItem, verdict: Verdict, label: string, color: string, soft: string) {
    Button(label)
      .fontSize(13)
      .fontColor(item.verdict === verdict ? Colors.WHITE : color)
      .backgroundColor(item.verdict === verdict ? color : soft)
      .borderRadius(14).height(32).padding({ left: 12, right: 12 })
      .onClick(() => this.setReviewVerdict(item, verdict))
  }

  @Builder
  ReviewBody() {
    Column() {
      Text(this.reviewTitle())
        .fontSize(TypeScale.TITLE_LARGE).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .margin({ top: 14 })
      Text(this.param.chunk === true
        ? '判「模糊」的词会排到今天的末尾重考，判完 2 次才进错词本'
        : '可逐词改判，确认后按最终结果更新复习计划')
        .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB).margin({ top: 6 })

      Scroll() {
        Column() {
          ForEach(this.items, (item: RoundItem) => {
            Column() {
              Row() {
                Text(item.english).fontSize(17).fontWeight(FontWeight.Medium)
                  .fontColor(Colors.TEXT_MAIN).layoutWeight(1)
                Text(item.meanings.join('；'))
                  .fontSize(13).fontColor(Colors.TEXT_SUB).maxLines(2)
                  .textAlign(TextAlign.End).layoutWeight(1.4).margin({ left: 10 })
              }
              .width('100%')

              if (item.heard.length > 0) {
                Text(`你说的：${item.heard}`)
                  .fontSize(12).fontColor(Colors.TEXT_WEAK)
                  .width('100%').margin({ top: 6 })
              }

              Row() {
                this.VerdictChip(item, 'KNOWN', '认识', Colors.KNOW_GREEN, Colors.KNOW_GREEN_SOFT)
                this.VerdictChip(item, 'VAGUE', '模糊', Colors.FUZZY_ORANGE, Colors.FUZZY_ORANGE_SOFT)
                this.VerdictChip(item, 'UNKNOWN', '不认识', Colors.UNKNOWN_RED, Colors.UNKNOWN_RED_SOFT)
              }
              .width('100%').margin({ top: 10 })
            }
            .width('100%').backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
            .padding(14).margin({ top: 10 })
            .alignItems(HorizontalAlign.Start)
          }, (item: RoundItem): string => item.wordId)
        }
        .width('100%').padding({ left: 16, right: 16 })
      }
      .layoutWeight(1).width('100%').margin({ top: 8 })

      // 确认按钮：包一层 Row 承载安全区（safeAreaPadding 是内边距语义，
      // 直接加在固定高 50 的 Button 上只会压缩其内容、不会上抬按钮），
      // 口径与 RoundBody 底部三档按钮一致。
      Row() {
        Button(this.confirmLabel())
          .fontSize(16).fontColor(Colors.WHITE)
          .backgroundColor(this.allJudged() ? Colors.BRAND : Colors.TEXT_WEAK)
          .borderRadius(Radius.BUTTON).height(50).width('92%')
          .onClick(() => this.confirmRound())
      }
      .width('100%').justifyContent(FlexAlign.Center)
      .padding({ top: 8, bottom: 12 })
      .safeAreaPadding({ bottom: 14 })
    }
    // 同 RoundBody：layoutWeight 而非 height('100%')，否则溢出父容器、按钮落入系统导航区。
    .width('100%').layoutWeight(1)
  }

  @Builder
  EmptyState() {
    Column() {
      Text('没有要测试的单词')
        .fontSize(TypeScale.CARD_TITLE).fontColor(Colors.TEXT_MAIN)
      Button('返回')
        .fontSize(TypeScale.BODY).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
        .borderRadius(Radius.BUTTON).height(46).width(200).margin({ top: 22 })
        .onClick(() => NavStore.INSTANCE.back())
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        if (this.items.length === 0) {
          this.EmptyState()
        } else if (this.phase === 'review') {
          this.ReviewBody()
        } else {
          this.RoundBody()
        }
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => this.handleBackPressed())
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity + this.showTick * 0)
    .onShown(() => {
      this.animateCovered(true);
      this.showTick++;
      if (this.pendingResumeTip) {
        this.pendingResumeTip = false;
        this.toast(this.phase === 'review'
          ? '已恢复上次进度，直接回到复核清单'
          : `已恢复上次进度，从第 ${this.index + 1} 个词继续`);
      }
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

/** ASR 回调转发到页面（具名类，规避 ArkTS 无类型对象字面量限制） */
class SpeechPageAsrListener implements AsrListener {
  private page: SpeechTestPage;

  constructor(page: SpeechTestPage) {
    this.page = page;
  }

  onPartial(text: string): void {
    this.page.onAsrPartial(text);
  }

  onFinal(text: string): void {
    this.page.onAsrFinal(text);
  }

  onError(code: number, message: string): void {
    this.page.onAsrError(code, message);
  }

  onStateChange(state: AsrState): void {
    this.page.onAsrStateChange(state);
  }
}
