/**
 * F17 梗句导入页（同页两步）
 * 步骤一：中文多行输入 + 自动英译（三级链路：端侧神经网络真翻译 → 离线整句/梗词库兜底）
 *        + 梗味命中建议（点一行把英文俚语插到英文框末尾）+ 英文多行框；
 * 步骤二：拆词确认——逐词三态标签（已掌握绿/学习中黄/新词蓝）、勾选、左滑删除、顶部汇总；
 *        有效词 <2 拦截；全部已掌握给「再背一遍强化」。
 * 「导入并开始背诵」单次事务落库后，回「我的词本」Tab 并压入梗句背诵页。
 *
 * 端侧翻译（F19）三条铁律：
 * 1. 模型只在**本页**存活：aboutToAppear 预热 + 挂载隐藏 Web 宿主，aboutToDisappear 卸载。
 *    真机实测读模型峰值 727MB、稳态 565MB，离开页面必须让渲染进程整体退出；
 * 2. 模型没好也不许卡用户：LOADING 期间点按钮立刻走离线库，且提示语明说「先用离线库」；
 * 3. 来源必须诚实：端侧模型译出的标「端侧翻译」，查表来的标「离线库匹配 / 相近说法」，
 *    绝不把查表结果冒充成翻译结果。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
import type { MemeReviewRouteParam } from '../../common/RouteNames';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { TranslateService } from '../../service/TranslateService';
import { LocalDictService } from '../../service/LocalDictService';
import type { DictHit } from '../../service/LocalDictService';
import type { MemeCandidate, MemeCandidateKind } from '../../model/MemeCore';
import { summarizeCandidates } from '../../model/MemeCore';
import type { MemeHit, TranslateResult } from '../../model/OfflineTranslateCore';
import { appendEnglish, PLACEHOLDER, primarySlang } from '../../model/OfflineTranslateCore';
import type { NmtResult, NmtState } from '../../model/NmtEngine';
import { nmtEngine } from '../../model/NmtEngine';
import { NmtHost } from '../../components/NmtHost';
import type { Word } from '../../model/Types';

/** 英文框内容的来源标注：端侧模型 / 离线整句 / 离线相近 / 离线梗词脚手架 */
type EnglishSource = '' | 'MODEL' | 'BANK' | 'NEAR' | 'SCAFFOLD';

/** 确认页一行候选（offsetX 承担左滑删除手势） */
@ObservedV2
class CandidateRow {
  candidate: MemeCandidate;
  @Trace offsetX: number = 0;

  constructor(c: MemeCandidate) {
    this.candidate = c;
  }
}

@ComponentV2
export struct MemeImportPage {
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 0;
  @Local showTick: number = 0;

  @Local step: number = 1;
  @Local chinese: string = '';
  @Local english: string = '';
  @Local translating: boolean = false;
  /** 上一次离线翻译命中的梗词（用于「梗味命中」建议区） */
  @Local hits: MemeHit[] = [];
  /** 离线库没命中时推荐的相近说法（点一条填入英文） */
  @Local suggestions: string[] = [];
  @Local rows: CandidateRow[] = [];
  /** 步骤切换横向位移（320ms 右滑感） */
  @Local stepShift: number = 40;
  @Local stepOpacity: number = 0;
  /** 正在加载离线词典并匹配中文释义 */
  @Local preparing: boolean = false;
  /** 端侧翻译引擎状态镜像（按钮文案与提示条全部由它驱动） */
  @Local nmtState: NmtState = 'IDLE';
  /** 是否挂载隐藏的 Web 宿主：false = 渲染进程退出，565MB 归还系统 */
  @Local showNmt: boolean = false;
  /** 英文框当前内容来源（结果区必须诚实标注） */
  @Local englishSource: EnglishSource = '';

  aboutToAppear(): void {
    this.playStepEnter();
    // 提前把 3.5MB 词典读进内存：进确认页时已就绪，用户点「拆词」不卡
    this.ensureDict();
    // 预热端侧翻译：用户正在敲这行中文的几秒钟，正好覆盖 3.2s 的模型加载
    this.startNmt();
  }

  aboutToDisappear(): void {
    // 卸载 Web 宿主 → 渲染进程销毁 → 读模型的 727MB / 稳态 565MB 全部释放
    this.showNmt = false;
    nmtEngine.dispose();
  }

  /**
   * 启动端侧翻译：先挂宿主再 load()。
   * 顺序有讲究——引擎的 load() 是幂等的，宿主挂载后 attach() 会补发 start()，
   * 所以谁先谁后都不会漏加载；但先挂载能让页面加载与状态订阅并行，省 200ms 左右。
   */
  private startNmt(): void {
    this.nmtState = nmtEngine.getState();
    nmtEngine.onStateChange((s: NmtState): void => {
      this.nmtState = s;
      // 模型彻底起不来（加载超时 / 脚本缺失）：立刻撤掉宿主，别白占内存
      if (s === 'FAILED') {
        this.showNmt = false;
      }
    });
    this.showNmt = true;
    nmtEngine.load();
  }

  /** 加载离线词典（失败不阻断：拆词/导入仍可用，只是没释义） */
  private ensureDict(): Promise<boolean> {
    if (LocalDictService.isLoaded()) {
      return Promise.resolve(true);
    }
    try {
      const ctx: common.Context = getContext(this) as common.UIAbilityContext;
      return LocalDictService.ensureLoaded(ctx)
        .then((): boolean => true)
        .catch((): boolean => false);
    } catch (e) {
      console.warn(`[MemeImport] dict ctx: ${(e as Error)?.message ?? e}`);
      return Promise.resolve(false);
    }
  }

  /**
   * 给候选词补音标与中文释义：
   * - 已在词库里的词优先用词库自带释义（用户手填的不能被词典覆盖）；
   * - 新词查离线词典（含 shattered→shatter 的词形索引）。
   */
  private enrich(candidates: MemeCandidate[], dictReady: boolean): void {
    candidates.forEach((c: MemeCandidate): void => {
      if (c.existingWordId.length > 0) {
        const existed: Word | null = DataStore.INSTANCE.wordById(c.existingWordId);
        if (existed !== null && existed.meanings.length > 0) {
          c.phonetic = existed.phonetic;
          c.meaning = existed.meanings.join('；');
          return;
        }
      }
      if (!dictReady) {
        return;
      }
      const hit: DictHit | null = LocalDictService.lookupDetail(c.token);
      if (hit === null) {
        return;
      }
      c.phonetic = hit.phonetic;
      c.meaning = hit.meaning;
      // 变形命中时把原形带出来，确认页显示「shattered · 释义见 shatter」
      c.lemma = hit.viaLemma && hit.matchedWord !== c.token ? hit.matchedWord : '';
    });
  }

  private playStepEnter(): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    this.stepShift = reduced ? 0 : 40;
    this.stepOpacity = 0;
    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : Motion.FEEDBACK, curve: Curve.EaseOut },
      () => {
        this.stepShift = 0;
        this.stepOpacity = 1;
      }
    );
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
      promptAction.showToast({ message: msg, duration: 1800 });
    } catch (e) {
      console.warn(`[MemeImport] toast: ${(e as Error)?.message ?? e}`);
    }
  }

  /**
   * 自动英译（三级链路，顺序不可乱）：
   *   1. 端侧模型 READY  → 真翻译（神经网络，任意中文都能译）；
   *   2. 仍在 LOADING/IDLE → 不阻塞，先用离线库匹配，并明说「模型准备中」；
   *   3. FAILED / 超时 / 端侧翻译失败 → 离线库兜底，并标注「离线库匹配」。
   * 任何一档都会给出可读结果，用户永远不会看到一个转不完的圈。
   */
  private doTranslate(): void {
    if (this.translating) {
      return;
    }
    const zh: string = this.chinese.trim();
    if (zh.length === 0) {
      this.toast('请先输入中文句子');
      return;
    }
    const st: NmtState = nmtEngine.getState();
    if (st === 'RUNNING') {
      this.toast('端侧翻译正在进行，请稍候几秒');
      return;
    }
    if (st === 'READY') {
      this.translateByModel(zh);
      return;
    }
    // 模型没就绪：立刻降级，绝不让用户干等
    if (st === 'FAILED') {
      this.toast('端侧模型没起来，这次用离线库匹配');
    } else {
      this.toast('端侧模型准备中，先用离线库给你匹配');
    }
    this.translateByBank();
  }

  /**
   * 一级：端侧神经翻译。
   * 失败（含超时 / 页面报错）时**立刻**转二级离线库，用户无感。
   */
  private translateByModel(zh: string): void {
    this.translating = true;
    nmtEngine.translate(zh)
      .then((r: NmtResult): void => {
        this.translating = false;
        if (r.ok && r.english.trim().length > 0) {
          this.english = r.english.trim();
          this.englishSource = 'MODEL';
          // 端侧模型不查句库，「相近说法」必然过期；但梗词命中仍有参考价值，只刷新 hits
          this.suggestions = [];
          this.refreshHitsOnly(zh);
          this.toast(`端侧翻译完成 · ${r.costMs}ms`);
          return;
        }
        this.toast(r.message.length > 0 ? r.message : '端侧翻译失败，改用离线库匹配');
        this.translateByBank();
      })
      .catch((e: Error): void => {
        this.translating = false;
        this.toast((e as Error)?.message ?? '端侧翻译失败，改用离线库匹配');
        this.translateByBank();
      });
  }

  /**
   * 二级 / 三级：离线库（原 F18 行为，一字未改）。
   * - 命中整句 → 直接填英文，标「离线库匹配」（近似命中标「离线库相近」）；
   * - 命中梗词 → 填脚手架，标「离线库脚手架」，并给「梗味命中」建议区；
   * - 全未命中 → 不填英文（不编造），只给相近说法。
   */
  private translateByBank(): void {
    this.translating = true;
    TranslateService.translateDetail(this.chinese, 'MEME')
      .then((result: TranslateResult): void => {
        this.translating = false;
        this.hits = result.hits;
        this.suggestions = result.suggestions !== undefined ? result.suggestions : [];
        if (result.english.length > 0) {
          this.english = result.english;
          if (result.level === 'SENTENCE') {
            this.englishSource = result.matchKind === 'near' ? 'NEAR' : 'BANK';
          } else {
            this.englishSource = 'SCAFFOLD';
          }
          // 精确 / 近似 / 梗词脚手架三种口径由引擎给文案，页面不再自己猜
          this.toast(result.message.length > 0 ? result.message : '已填入英文，可手动润色');
        } else {
          this.englishSource = '';
          this.toast(result.message.length > 0 ? result.message : '没有匹配到现成英文，请手动填写');
        }
      })
      .catch((e: Error): void => {
        this.translating = false;
        this.toast((e as Error)?.message ?? '匹配失败，请手动填写英文');
      });
  }

  /**
   * 端侧翻译成功后补一份「梗味命中」。
   * 只为保留 F18 的「点一行追加俚语」能力；中文已改过就丢弃，避免串到上一句。
   */
  private refreshHitsOnly(zh: string): void {
    TranslateService.translateDetail(zh, 'MEME')
      .then((r: TranslateResult): void => {
        if (this.chinese.trim() !== zh) {
          return;
        }
        this.hits = r.hits;
      })
      .catch((): void => {
        this.hits = [];
      });
  }


  /* ================= 端侧翻译的展示口径（按钮 / 提示条 / 来源标签） ================= */

  /**
   * 按钮文案随状态变：就绪 = 「翻译」；进行中 = 「翻译中…」/「匹配中…」；
   * 加载中与失败时仍写「匹配英文」——加载期这条链路照样可用，不能把入口藏了。
   */
  private translateButtonLabel(): string {
    if (this.translating) {
      return this.nmtState === 'RUNNING' ? '翻译中…' : '匹配中…';
    }
    if (this.nmtState === 'READY') {
      return '翻译';
    }
    return '匹配英文';
  }

  /** 状态提示条文案（永远非空：让用户知道现在走的是哪条链路） */
  private nmtHint(): string {
    if (this.nmtState === 'READY') {
      return '端侧翻译已就绪，点「翻译」出真英文';
    }
    if (this.nmtState === 'RUNNING') {
      return '端侧翻译进行中，长句约 6 秒';
    }
    if (this.nmtState === 'FAILED') {
      return '端侧模型没起来，本次用离线库匹配（不影响导入）';
    }
    return '端侧翻译模型准备中（约 3 秒），这期间先用离线库给你匹配';
  }

  private nmtHintColor(): string {
    if (this.nmtState === 'READY') {
      return Colors.KNOW_GREEN;
    }
    if (this.nmtState === 'FAILED') {
      return Colors.FUZZY_ORANGE;
    }
    return Colors.TEXT_SUB;
  }

  private nmtHintBg(): string {
    if (this.nmtState === 'READY') {
      return Colors.KNOW_GREEN_SOFT;
    }
    if (this.nmtState === 'FAILED') {
      return Colors.FUZZY_ORANGE_SOFT;
    }
    return Colors.PAGE_BG;
  }

  /** 英文框来源标签：端侧模型 / 离线整句 / 离线相近 / 离线脚手架，四者绝不混用 */
  private sourceTagText(): string {
    if (this.englishSource === 'MODEL') {
      return '端侧翻译';
    }
    if (this.englishSource === 'BANK') {
      return '离线库匹配';
    }
    if (this.englishSource === 'NEAR') {
      return '离线库相近说法';
    }
    if (this.englishSource === 'SCAFFOLD') {
      return '离线库脚手架';
    }
    return '';
  }

  private sourceTagColor(): string {
    if (this.englishSource === 'MODEL') {
      return Colors.KNOW_GREEN;
    }
    if (this.englishSource === 'SCAFFOLD') {
      return Colors.FUZZY_ORANGE;
    }
    return Colors.BRAND;
  }

  private sourceTagBg(): string {
    if (this.englishSource === 'MODEL') {
      return Colors.KNOW_GREEN_SOFT;
    }
    if (this.englishSource === 'SCAFFOLD') {
      return Colors.FUZZY_ORANGE_SOFT;
    }
    return Colors.BRAND_SOFT;
  }

  /** 点选「相近说法」：查该中文的现成英文，追加进英文框（不覆盖用户已写内容） */
  private insertSuggestion(zh: string): void {
    TranslateService.translateDetail(zh, 'MEME')
      .then((r: TranslateResult): void => {
        if (r.english.length === 0) {
          this.toast('这条也没有现成英文');
          return;
        }
        this.english = appendEnglish(this.english, r.english);
        this.suggestions = [];
        this.toast('已填入，按你的原意改一改');
      })
      .catch((): void => {
        this.toast('填入失败，请手动填写');
      });
  }

  /**
   * 还没进英文框的命中：已插入过的梗不再展示，避免「点一下又追加一遍」。
   * 全梗句（english 为空）时全部展示，用户逐条点成自己想要的句子。
   */
  private pendingHits(): MemeHit[] {
    const cur: string = this.english.toLowerCase();
    const out: MemeHit[] = [];
    this.hits.forEach((hit: MemeHit): void => {
      const word: string = primarySlang(hit.slang).toLowerCase();
      if (word.length > 0 && cur.indexOf(word) < 0) {
        out.push(hit);
      }
    });
    return out;
  }

  /**
   * 点「梗味命中」某一行：把该梗的英文俚语首选词接到英文框末尾。
   * 拼接规则走 appendEnglish（与前文结尾判断句号），框里已有同一表达时跳过。
   */
  private insertSlang(hit: MemeHit): void {
    const word: string = primarySlang(hit.slang);
    if (word.length === 0) {
      return;
    }
    const cur: string = this.english;
    if (cur.toLowerCase().indexOf(word.toLowerCase()) >= 0) {
      this.toast('英文框里已经有这个表达了');
      return;
    }
    this.english = appendEnglish(cur, word);
  }

  /** 拆词 → 匹配中文 → 进入确认步 */
  private async goConfirm(): Promise<void> {
    if (this.preparing) {
      return;
    }
    if (this.english.trim().length === 0) {
      // 英文框为空（用户清空了自动填入的脚手架）：引导去点命中区或手填
      this.toast(this.hits.length > 0
        ? '请先参考「梗味命中」把英文句子写完整'
        : '请先填写英文句子（可点上方按钮自动生成）');
      return;
    }
    // 脚手架里的 [...] 是「这里还缺英文」的占位，别让它混进梗句词本
    if (this.english.indexOf(PLACEHOLDER) >= 0) {
      this.toast('英文里还有 [...] 占位符，请先补成完整英文再拆词');
      return;
    }
    const candidates: MemeCandidate[] = DataStore.INSTANCE.memeCandidates(this.english);
    // 有效词 <2 必须在这里拦下：否则会进确认页卡住（导入时 createMemeImport 也会拒）
    if (candidates.length < 2) {
      this.toast(`这句英文只拆出 ${candidates.length} 个可背词，至少需要 2 个，请补充英文后再拆词`);
      return;
    }
    // 拆出来的词必须带中文，否则卡片背面是空的（真机反馈）
    this.preparing = true;
    const dictReady: boolean = await this.ensureDict();
    if (candidates.length > 0) {
      this.enrich(candidates, dictReady);
    }
    this.preparing = false;

    const rowList: CandidateRow[] = [];
    candidates.forEach((c: MemeCandidate): void => {
      rowList.push(new CandidateRow(c));
    });
    this.rows = rowList;
    this.step = 2;
    this.playStepEnter();
    if (!dictReady) {
      this.toast('离线词典未能加载，本次拆出的词暂无中文释义');
    }
  }

  private backToInput(): void {
    this.step = 1;
    this.playStepEnter();
  }

  /** 复制候选并改勾选态：音标/释义/原形必须一起带走，否则导入后卡片背面又空了 */
  private copyCandidate(c: MemeCandidate, selected: boolean, toggleable: boolean): MemeCandidate {
    const out: MemeCandidate = {
      token: c.token,
      kind: c.kind,
      existingWordId: c.existingWordId,
      selected,
      toggleable,
    };
    const ph: string | undefined = c.phonetic;
    if (ph !== undefined) {
      out.phonetic = ph;
    }
    const m: string | undefined = c.meaning;
    if (m !== undefined) {
      out.meaning = m;
    }
    const lm: string | undefined = c.lemma;
    if (lm !== undefined) {
      out.lemma = lm;
    }
    return out;
  }

  /** 勾选/取消（已掌握置灰不可改，除非走「再背一遍强化」） */
  private toggleRow(row: CandidateRow): void {
    if (!row.candidate.toggleable) {
      return;
    }
    const next: CandidateRow[] = this.rows.map((r: CandidateRow): CandidateRow => {
      if (r !== row) {
        return r;
      }
      const c: MemeCandidate = this.copyCandidate(r.candidate, !r.candidate.selected, r.candidate.toggleable);
      return new CandidateRow(c);
    });
    this.rows = next;
  }

  /** 左滑删除一行 */
  private removeRow(row: CandidateRow): void {
    this.rows = this.rows.filter((r: CandidateRow): boolean => r !== row);
  }

  /** 全部已掌握时的「再背一遍强化」：全部纳入本次会话 */
  private forceRestudyAll(): void {
    const next: CandidateRow[] = this.rows.map((r: CandidateRow): CandidateRow => {
      const c: MemeCandidate = this.copyCandidate(r.candidate, true, true);
      return new CandidateRow(c);
    });
    this.rows = next;
  }

  private currentCandidates(): MemeCandidate[] {
    const out: MemeCandidate[] = [];
    this.rows.forEach((r: CandidateRow): void => {
      out.push(r.candidate);
    });
    return out;
  }

  /** 导入并开始背诵（单次事务） */
  private doImport(): void {
    const candidates: MemeCandidate[] = this.currentCandidates();
    const chosen: number = candidates.filter((c: MemeCandidate): boolean => c.selected).length;
    if (chosen < 2) {
      this.toast('至少保留 2 个有效词才能开始背诵');
      return;
    }
    if (this.chinese.trim().length === 0) {
      // 允许没有中文？功能卡要求中文原句用于看原句/卡片，拦截
      this.toast('请补填中文原句，背诵时可「看原句」');
      this.step = 1;
      this.playStepEnter();
      return;
    }
    try {
      const info = DataStore.INSTANCE.importMeme(this.chinese, this.english, candidates);
      this.toast('梗句词本已创建，开始背诵');
      // 回「我的词本」Tab 再压入背诵页（沿用云书下载可靠落地范式）
      const p: MemeReviewRouteParam = { memeId: info.memeId, sessionId: info.sessionId };
      NavStore.INSTANCE.backToTabThenPush(2, RouteName.MEME_REVIEW, p);
    } catch (e) {
      this.toast((e as Error)?.message ?? '导入失败，请重试');
    }
  }

  @Builder
  TopBar(title: string) {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())

      Text(title)
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Row().width(44).height(44)
    }
    .width('100%').height(56)
  }

  @Builder
  LabelTag(kind: MemeCandidateKind) {
    if (kind === 'NEW') {
      Text('新词').fontSize(11).fontColor(Colors.BRAND)
        .backgroundColor(Colors.BRAND_SOFT).borderRadius(8).padding({ left: 8, right: 8, top: 3, bottom: 3 })
    } else if (kind === 'LEARNING') {
      Text('学习中').fontSize(11).fontColor(Colors.FUZZY_ORANGE)
        .backgroundColor(Colors.FUZZY_ORANGE_SOFT).borderRadius(8)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
    } else {
      Text('已掌握').fontSize(11).fontColor(Colors.KNOW_GREEN)
        .backgroundColor(Colors.KNOW_GREEN_SOFT).borderRadius(8)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
    }
  }

  /** 确认页一行的中文副标题：释义 + 原形提示；未收录时明确告知 */
  private rowMeaning(row: CandidateRow): string {
    const m: string = (row.candidate.meaning ?? '').trim();
    if (m.length === 0) {
      return '暂无释义，背诵时看原句语境';
    }
    const lemma: string = row.candidate.lemma ?? '';
    return lemma.length > 0 ? `释义见原形 ${lemma}：${m}` : m;
  }

  @Builder
  CandidateRowView(row: CandidateRow) {
    Stack({ alignContent: Alignment.End }) {
      // 底层删除区
      Row() {
        Blank()
        Button('删除')
          .fontSize(14).fontColor(Colors.WHITE).backgroundColor(Colors.UNKNOWN_RED)
          .height(60).width(72).borderRadius(Radius.CONTROL)
          .onClick(() => this.removeRow(row))
      }
      .width('100%').height(64).padding({ right: 4 })

      // 前景行（跟手左滑）
      Row() {
        // 勾选圆
        Stack() {
          if (row.candidate.selected) {
            Circle({ width: 22, height: 22 }).fill(Colors.BRAND)
            Text('✓').fontSize(13).fontColor(Colors.WHITE).fontWeight(FontWeight.Bold)
          } else {
            Circle({ width: 22, height: 22 }).fill(Colors.WHITE)
              .stroke(row.candidate.toggleable ? Colors.TEXT_WEAK : Colors.DIVIDER)
              .strokeWidth(1.5)
          }
        }
        .width(34).height(60)

        Column() {
          Row() {
            Text(row.candidate.token)
              .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
            if ((row.candidate.phonetic ?? '').length > 0) {
              Text(row.candidate.phonetic ?? '')
                .fontSize(11).fontColor(Colors.TEXT_WEAK).margin({ left: 6 })
            }
          }
          .width('100%')

          Text(this.rowMeaning(row))
            .fontSize(12).fontColor(Colors.TEXT_SUB)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%').margin({ top: 3 })
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 4, right: 8 })

        this.LabelTag(row.candidate.kind)
      }
      .width('100%').height(64).padding({ left: 12, right: 14 })
      .backgroundColor(Colors.WHITE).borderRadius(Radius.CONTROL)
      .opacity(row.candidate.kind === 'MASTERED' && !row.candidate.selected ? 0.55 : 1)
      .translate({ x: row.offsetX })
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 6 })
          .onActionUpdate((e: GestureEvent) => {
            const x: number = Math.min(0, e.offsetX);
            row.offsetX = x > -88 ? x : -88;
          })
          .onActionEnd(() => {
            const reduced: boolean = NavStore.INSTANCE.reducedMotion;
            if (row.offsetX < -64) {
              this.getUIContext().animateTo(
                { duration: reduced ? Motion.MICRO : Motion.FEEDBACK, curve: Curve.EaseIn },
                () => {
                  row.offsetX = -120;
                }
              );
              setTimeout(() => this.removeRow(row), reduced ? 80 : 180);
            } else {
              this.getUIContext().animateTo(
                { duration: reduced ? Motion.MICRO : Motion.FEEDBACK, curve: Curve.EaseOut },
                () => {
                  row.offsetX = 0;
                }
              );
            }
          })
      )
      .onClick(() => this.toggleRow(row))
    }
    .width('100%').height(64).margin({ bottom: 10 })
  }

  @Builder
  InputStep() {
    Scroll() {
      Column() {
        // 中文输入
        Row() {
          Text('中文原句').fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium)
            .fontColor(Colors.TEXT_MAIN)
          Blank()
          Button(this.translateButtonLabel())
            .fontSize(13).fontColor(this.translating ? Colors.TEXT_WEAK : Colors.BRAND)
            .backgroundColor(Colors.BRAND_SOFT).borderRadius(Radius.CONTROL)
            .height(34).enabled(!this.translating)
            .onClick(() => this.doTranslate())
        }
        .width('100%').margin({ bottom: 8 })

        // 状态提示条：模型准备中 / 已就绪 / 已失败，让用户随时知道走的是哪条链路
        Row() {
          Text(this.nmtHint())
            .fontSize(TypeScale.CAPTION).fontColor(this.nmtHintColor())
            .layoutWeight(1)
        }
        .width('100%').padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(this.nmtHintBg()).borderRadius(Radius.CONTROL)
        .margin({ bottom: 8 })

        TextArea({
          placeholder: '输入一个句子或梗，比如：同学这里不能拉屎',
          text: this.chinese,
        })
          .width('100%').height(128).fontSize(16).fontColor(Colors.TEXT_MAIN)
          .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD).padding(14)
          .placeholderColor(Colors.TEXT_WEAK).placeholderFont({ size: 15 })
          .onChange((v: string) => {
            this.chinese = v;
            // 中文一改，上一轮的梗味命中和相近说法都作废：
            // 否则点一行会把上一句的俚语塞进英文框
            this.hits = [];
            this.suggestions = [];
          })

        // 英文输入
        Row() {
          Text('英文句子').fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium)
            .fontColor(Colors.TEXT_MAIN).margin({ top: 18 })
          // 来源标签：端侧模型译出的写「端侧翻译」，查表来的写「离线库…」，绝不模糊
          if (this.sourceTagText().length > 0) {
            Text(this.sourceTagText())
              .fontSize(11).fontColor(this.sourceTagColor())
              .backgroundColor(this.sourceTagBg()).borderRadius(8)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .margin({ left: 8, top: 18 })
          }
          Blank()
        }
        .width('100%').margin({ bottom: 10 })

        TextArea({
          placeholder: '点上方按钮自动生成英文，也可以自己手动输入',
          text: this.english,
        })
          .width('100%').height(128).fontSize(16).fontColor(Colors.TEXT_MAIN)
          .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD).padding(14)
          .placeholderColor(Colors.TEXT_WEAK).placeholderFont({ size: 14 })
          .onChange((v: string) => {
            this.english = v;
            // 用户把英文框清空了，来源标注就失效，跟着一起清（不让标签撒谎）
            if (v.trim().length === 0) {
              this.englishSource = '';
            }
          })

        // 梗味命中建议：只列「还没进英文框」的梗，点一行追加到英文框末尾
        if (this.pendingHits().length > 0) {
          Column() {
            Text('梗味命中')
              .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB)
              .width('100%').margin({ bottom: 8 })
            ForEach(this.pendingHits(), (hit: MemeHit) => {
              Column() {
                Text(`${hit.term} → ${hit.standard}`)
                  .fontSize(14).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
                  .width('100%')
                Text(hit.slang)
                  .fontSize(13).fontColor(Colors.BRAND).width('100%').margin({ top: 4 })
              }
              .width('100%').padding(10).margin({ bottom: 8 })
              .backgroundColor(Colors.WHITE).borderRadius(Radius.CONTROL)
              .alignItems(HorizontalAlign.Start)
              .onClick(() => this.insertSlang(hit))
            }, (hit: MemeHit) => hit.term)
          }
          .width('100%').padding(12).margin({ top: 12 })
          .backgroundColor(Colors.BRAND_SOFT).borderRadius(Radius.CARD)
          .alignItems(HorizontalAlign.Start)
        }

        // 离线库完全没有命中：给几条相近说法，点一条直接填英文（不再只弹一句「请手填」）
        if (this.suggestions.length > 0) {
          Column() {
            Text('离线库没有这句，相近的说法有：')
              .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB)
              .width('100%').margin({ bottom: 8 })
            ForEach(this.suggestions, (zh: string, idx: number) => {
              Row() {
                Text(zh)
                  .fontSize(14).fontColor(Colors.TEXT_MAIN).layoutWeight(1)
                Text('用这句')
                  .fontSize(12).fontColor(Colors.BRAND)
              }
              .width('100%').padding({ left: 10, right: 10, top: 10, bottom: 10 })
              .margin({ bottom: 8 })
              .backgroundColor(Colors.WHITE).borderRadius(Radius.CONTROL)
              .onClick(() => this.insertSuggestion(zh))
            }, (zh: string, idx: number): string => `sug-${idx}-${zh}`)
          }
          .width('100%').padding(12).margin({ top: 12 })
          .backgroundColor(Colors.PAGE_BG).borderRadius(Radius.CARD)
          .alignItems(HorizontalAlign.Start)
        }

        Text('拆词会自动过滤 the / is / you 这类虚词并去重，实词才进背诵')
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_WEAK).margin({ top: 12 })
          .width('100%')
      }
      .width('100%').padding({ left: 18, right: 18, top: 6 })
    }
    .layoutWeight(1).align(Alignment.Top)
    .scrollBar(BarState.Off)

    Button(this.preparing ? '匹配中文…' : '拆词 →')
      .fontSize(17).fontColor(Colors.WHITE)
      .backgroundColor(this.preparing ? Colors.TEXT_WEAK : Colors.BRAND)
      .borderRadius(Radius.BUTTON).height(52).width('92%').margin({ bottom: 26 })
      .enabled(!this.preparing)
      .onClick(() => {
        this.goConfirm();
      })
  }

  @Builder
  ConfirmStep() {
    Column() {
      // 汇总条
      Column() {
        Text(this.summaryText())
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN).width('100%')
        Text('点词可勾选/取消，左滑删除；已掌握的词默认不背')
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_WEAK).width('100%').margin({ top: 5 })
      }
      .width('100%').backgroundColor(Colors.BRAND_SOFT).borderRadius(Radius.CARD)
      .padding(14).margin({ left: 18, right: 18, top: 6, bottom: 12 })

      if (this.allMastered()) {
        // 全掌握特殊态
        Column() {
          Text('这句里的词你都背过啦')
            .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.KNOW_GREEN)
          Text('想结合这个梗再强化一遍也可以')
            .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB).margin({ top: 8 })
          Button('再背一遍强化')
            .fontSize(15).fontColor(Colors.BRAND).backgroundColor(Colors.BRAND_SOFT)
            .borderRadius(Radius.BUTTON).height(44).margin({ top: 16 })
            .onClick(() => this.forceRestudyAll())
        }
        .width('100%').padding({ top: 30 })
      }

      List({ space: 0 }) {
        ForEach(this.rows, (row: CandidateRow) => {
          ListItem() {
            this.CandidateRowView(row)
          }
        }, (row: CandidateRow) => row.candidate.token)
      }
      .layoutWeight(1).padding({ left: 18, right: 18 })
      .scrollBar(BarState.Off)

      Row() {
        Button('返回修改')
          .fontSize(16).fontColor(Colors.TEXT_SUB).backgroundColor(Colors.WHITE)
          .borderRadius(Radius.BUTTON).height(52).layoutWeight(1).margin({ right: 10 })
          .onClick(() => this.backToInput())
        Button('导入并开始背诵')
          .fontSize(16).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
          .borderRadius(Radius.BUTTON).height(52).layoutWeight(1.4)
          .onClick(() => this.doImport())
      }
      .width('92%').margin({ bottom: 26 })
    }
    .width('100%').height('100%')
    .translate({ x: this.stepShift }).opacity(this.stepOpacity)
  }

  private summaryText(): string {
    const s = summarizeCandidates(this.currentCandidates());
    const withZh: number = this.rows.filter((r: CandidateRow): boolean =>
      (r.candidate.meaning ?? '').trim().length > 0).length;
    return `本句共 ${s.total} 词 · 已掌握 ${s.mastered} · 学习中 ${s.learning} · 新词 ${s.fresh} · 将学 ${s.willStudy} · 有释义 ${withZh}/${s.total}`;
  }

  private allMastered(): boolean {
    if (this.rows.length === 0) {
      return false;
    }
    return this.rows.every((r: CandidateRow): boolean => r.candidate.kind === 'MASTERED');
  }

  build() {
    NavDestination() {
      // 用 Stack 托着页面内容 + 隐藏的端侧翻译宿主：
      // showNmt 变 false 时 Web 组件离树，渲染进程整体退出，565MB 归还系统
      Stack({ alignContent: Alignment.BottomStart }) {
        Column() {
          this.TopBar(this.step === 1 ? '梗句背单词' : '确认要背的词')
          if (this.step === 1) {
            Column() {
              this.InputStep()
            }
            .layoutWeight(1).width('100%')
            .translate({ x: this.stepShift }).opacity(this.stepOpacity)
          } else {
            this.ConfirmStep()
          }
        }
        .width('100%').height('100%')
        .backgroundColor(Colors.PAGE_BG)

        if (this.showNmt) {
          NmtHost()
        }
      }
      .width('100%').height('100%')
    }
    .hideTitleBar(true)
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity + this.showTick * 0)
    .onShown(() => {
      this.animateCovered(true);
      this.showTick++;
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
