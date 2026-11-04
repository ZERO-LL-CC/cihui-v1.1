/**
 * F17 梗句导入页（同页两步）
 * 步骤一：中文多行输入 + 自动英译（三级链路：端侧神经网络真翻译 → 离线整句/梗词库兜底）
 *        + 梗味命中建议（点一行把英文俚语插到英文框末尾）+ 英文多行框；
 * 步骤二：拆词确认——逐词三态标签（已掌握绿/学习中黄/新词蓝）、勾选、左滑删除、顶部汇总；
 *        有效词 <2 拦截。
 * 「导入」单次事务落库（建梗句词本 + 新词走统一导入流程）后，回「我的」Tab。
 * 梗句背诵已并入统一背词流程：不再创建背诵会话，也不跳梗句闪卡页。
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
import type { IntakeMode, Word } from '../../model/Types';

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
    // 输入页入场：stepOpacity 初值 0，这里必须跑一次动画，否则整页停在透明态
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
    // 有效词 <2 必须在这里拦下：否则会进确认页卡住（导入时 importMeme 也会拒）
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
    this.releaseNmt();
    this.playStepEnter();
    if (!dictReady) {
      this.toast('离线词典未能加载，本次拆出的词暂无中文释义');
    }
  }

  private backToInput(): void {
    this.step = 1;
    this.startNmt();
    this.playStepEnter();
  }

  /** 进确认页就卸载翻译宿主：确认页不需要翻译，却要背着 565MB 的 Web 渲染进程，整页会发卡 */
  private releaseNmt(): void {
    this.showNmt = false;
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

  /** 全部已掌握时的「再背一遍强化」：全部纳入本次导入（梗卡再刷新一遍口径） */
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

  /**
   * 导入梗句（单次事务）：建梗句词本 + 新词走统一导入流程（importWords 同口径），
   * 不再创建背诵会话；成功回「我的」Tab 看新词本。
   */
  private doImport(intake: IntakeMode): void {
    const candidates: MemeCandidate[] = this.currentCandidates();
    const chosen: number = candidates.filter((c: MemeCandidate): boolean => c.selected).length;
    if (chosen < 2) {
      this.toast('至少保留 2 个有效词才能开始背诵');
      return;
    }
    if (this.chinese.trim().length === 0) {
      // 功能卡要求中文原句用于梗卡相册展示，拦截
      this.toast('请补填中文原句，梗卡相册需要展示原句');
      this.step = 1;
      this.playStepEnter();
      return;
    }
    try {
      DataStore.INSTANCE.importMeme(this.chinese.trim(), this.english.trim(), candidates, intake);
      this.toast(intake === 'TODAY'
        ? '梗句词本已创建，新词已加入今日计划'
        : '梗句词本已创建，新词将按每日新词量排队');
      NavStore.INSTANCE.backToTab(2);
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
      Text('新词').fontSize(10).fontColor(Colors.BRAND)
        .backgroundColor(Colors.BRAND_SOFT).borderRadius(6).padding({ left: 7, right: 7, top: 2, bottom: 2 })
    } else if (kind === 'LEARNING') {
      Text('学习中').fontSize(10).fontColor(Colors.FUZZY_ORANGE)
        .backgroundColor(Colors.FUZZY_ORANGE_SOFT).borderRadius(6)
        .padding({ left: 7, right: 7, top: 2, bottom: 2 })
    } else {
      Text('已掌握').fontSize(10).fontColor(Colors.KNOW_GREEN)
        .backgroundColor(Colors.KNOW_GREEN_SOFT).borderRadius(6)
        .padding({ left: 7, right: 7, top: 2, bottom: 2 })
    }
  }

  /** 确认页一行的中文副标题：只给释义本体（原形另起小标签，别把整行挤爆） */
  private rowMeaning(row: CandidateRow): string {
    const m: string = (row.candidate.meaning ?? '').trim();
    return m.length === 0 ? '暂无释义，背诵时看原句语境' : m;
  }

  @Builder
  CandidateRowView(row: CandidateRow, idx: number) {
    Stack({ alignContent: Alignment.End }) {
      // 底层删除区
      Row() {
        Blank()
        Button('删除')
          .fontSize(14).fontColor(Colors.WHITE).backgroundColor(Colors.UNKNOWN_RED)
          .height(68).width(76).borderRadius(0)
          .onClick(() => this.removeRow(row))
      }
      .width('100%').height(68)

      // 前景行（跟手左滑）
      Row() {
        Text(idx < 9 ? `0${idx + 1}` : `${idx + 1}`)
          .fontSize(10).fontColor(Colors.TEXT_WEAK).width(20)

        Column() {
          Row() {
            Text(row.candidate.token)
              .fontSize(15.5).fontFamily('Georgia').fontWeight(FontWeight.Medium)
              .fontColor(row.candidate.selected ? Colors.BRAND_PRESSED : Colors.TEXT_MAIN)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .flexShrink(1)
            if ((row.candidate.phonetic ?? '').length > 0) {
              Text(row.candidate.phonetic ?? '')
                .fontSize(9.5).fontColor(Colors.TEXT_WEAK).flexShrink(0).margin({ left: 6 })
            }
            Blank()
            this.LabelTag(row.candidate.kind)
          }
          .width('100%').alignItems(VerticalAlign.Center)

          Row() {
            if ((row.candidate.lemma ?? '').length > 0
              && (row.candidate.lemma ?? '') !== row.candidate.token) {
              Text(`≡${row.candidate.lemma}`)
                .fontSize(9.5).fontColor(Colors.TEXT_WEAK).flexShrink(0).margin({ right: 5 })
            }
            Text(this.rowMeaning(row))
              .fontSize(11.5).fontColor(Colors.TEXT_SUB)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%').margin({ top: 3 })
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 4 })

        // 勾：方勾和「点名册」选词页同形，选中即填蓝
        Stack() {
          if (row.candidate.selected) {
            Text('✓').fontSize(11).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
          }
        }
        .width(20).height(20).borderRadius(6)
        .backgroundColor(row.candidate.selected ? Colors.BRAND : Color.Transparent)
        .border({
          width: 1.5,
          color: row.candidate.selected ? Colors.BRAND
            : (row.candidate.toggleable ? '#D3DAE6' : Colors.DIVIDER)
        })
        .margin({ left: 10 })
        .animation({ duration: Motion.FEEDBACK, curve: Curve.EaseOut })
      }
      .width('100%').height(68).padding({ left: 14, right: 14 })
      .backgroundColor(Colors.WHITE)
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
    .width('100%').height(68)
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
      .borderRadius(Radius.BUTTON).height(52).width('92%').margin({ bottom: 48 })
      .enabled(!this.preparing)
      .onClick(() => {
        this.goConfirm();
      })
  }

  @Builder
  ConfirmStep() {
    Column() {
      // 标题区：和「今日例句」选词页同一套骨架——小字眉题 → 26fp 主张 → 一句说明
      Column() {
        Text(`本句 ${this.rows.length} 个词`)
          .fontSize(11).fontColor(Colors.TEXT_WEAK).letterSpacing(1.1)
        Text('确认要背的词')
          .fontSize(26).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
          .margin({ top: 6 })
        Text('默认全选；点一下取消，左滑删除，已掌握的不背')
          .fontSize(12.5).fontColor(Colors.TEXT_SUB).margin({ top: 7 })
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 20, right: 20, top: 4 })

      // 汇总 chips：把原来那句长文案拆成可扫读的颗粒；为 0 的维度不占位
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        this.SumChip(`共 ${this.rows.length} 词`, Colors.TEXT_MAIN, Colors.WHITE, Colors.DIVIDER)
        this.SumChip(`新词 ${this.countKind('NEW')}`, Colors.BRAND, Colors.BRAND_SOFT, Colors.BRAND_SOFT)
        if (this.countKind('LEARNING') > 0) {
          this.SumChip(`学习中 ${this.countKind('LEARNING')}`, Colors.FUZZY_ORANGE,
            Colors.FUZZY_ORANGE_SOFT, Colors.FUZZY_ORANGE_SOFT)
        }
        if (this.countKind('MASTERED') > 0) {
          this.SumChip(`已掌握 ${this.countKind('MASTERED')}`, Colors.KNOW_GREEN,
            Colors.KNOW_GREEN_SOFT, Colors.KNOW_GREEN_SOFT)
        }
      }
      .width('100%').padding({ left: 20, right: 20 }).margin({ top: 14 })

      // 计数行 + 一键全选
      Row() {
        Text(`已选 ${this.selectedCount()} / ${this.rows.length}`)
          .fontSize(11).fontColor(Colors.TEXT_WEAK).letterSpacing(0.6)
        Blank()
        Text(this.allSelected() ? '全部取消' : '全选')
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor(Colors.BRAND)
          .padding({ left: 8, right: 2, top: 5, bottom: 5 })
          .onClick(() => this.setAllSelected(!this.allSelected()))
      }
      .width('100%').padding({ left: 20, right: 20 }).margin({ top: 12, bottom: 9 })

      if (this.allMastered()) {
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
        .width('100%').padding({ top: 8, bottom: 8 })
      }

      // 册页：一张白卡内的单列行，而不是三张散卡
      Column() {
        Column() {
          ForEach(this.rows, (row: CandidateRow, idx: number) => {
            Column() {
              this.CandidateRowView(row, idx)
            }
            .width('100%')
            .border({
              width: { bottom: idx === this.rows.length - 1 ? 0 : 1 },
              color: '#F0F3F8'
            })
          }, (row: CandidateRow): string =>
            `${row.candidate.token}-${row.candidate.selected}-${row.candidate.kind}`)
        }
        .width('100%')
        .backgroundColor(Colors.WHITE).borderRadius(16)
        .border({ width: 1, color: Colors.DIVIDER })
        .clip(true)

        // 两种入列方式的区别：紧贴列表下方，别浮在底部悬空
        Column({ space: 6 }) {
          Row({ space: 7 }) {
            Text('今天')
              .fontSize(10).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
              .borderRadius(5).padding({ left: 5, right: 5, top: 1, bottom: 1 })
            Text('加入今天计划，现在就能背，不占每日新词额度')
              .fontSize(11).fontColor(Colors.TEXT_SUB).layoutWeight(1)
          }
          .width('100%').alignItems(VerticalAlign.Center)

          Row({ space: 7 }) {
            Text('排队')
              .fontSize(10).fontColor(Colors.TEXT_SUB).backgroundColor('#E9ECF3')
              .borderRadius(5).padding({ left: 5, right: 5, top: 1, bottom: 1 })
            Text('加入词本，按你设的每日新词量慢慢排')
              .fontSize(11).fontColor(Colors.TEXT_SUB).layoutWeight(1)
          }
          .width('100%').alignItems(VerticalAlign.Center)
        }
        .width('100%').padding({ left: 6, right: 6 }).margin({ top: 12 })
      }
      .width('100%').padding({ left: 16, right: 16 }).layoutWeight(1)

      // 底部：主操作占满一行，两个次操作退到第二行，不再三个挤一行截断
      Column() {
        Row() {
          Text() {
            Span('已选 ').fontSize(12).fontColor(Colors.TEXT_SUB)
            Span(`${this.selectedCount()}`).fontSize(13).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
            Span(' 个词').fontSize(12).fontColor(Colors.TEXT_SUB)
          }
          Blank()
          Text(this.selectedCount() < 2 ? '至少留 2 个词' : '现在就能背')
            .fontSize(11).fontColor(this.selectedCount() < 2 ? Colors.UNKNOWN_RED : Colors.TEXT_WEAK)
        }
        .width('100%').margin({ bottom: 10 })

        Row() {
          Text('加入今天计划 · 现在背')
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor(Colors.WHITE).letterSpacing(0.5)
        }
        .width('100%').height(52).borderRadius(Radius.BUTTON)
        .justifyContent(FlexAlign.Center)
        .linearGradient({ angle: 135, colors: [[Colors.BRAND, 0], [Colors.BRAND_PRESSED, 1]] })
        .shadow({ radius: 14, color: 'rgba(10,89,247,0.28)', offsetY: 6 })
        .opacity(this.selectedCount() < 2 ? 0.45 : 1)
        .enabled(this.selectedCount() >= 2)
        .onClick(() => this.doImport('TODAY'))

        Row({ space: 10 }) {
          Text('加入词本排队')
            .fontSize(14).fontColor(Colors.BRAND).fontWeight(FontWeight.Medium)
            .layoutWeight(1).height(46).textAlign(TextAlign.Center)
            .borderRadius(Radius.BUTTON)
            .backgroundColor(Colors.WHITE)
            .border({ width: 1, color: Colors.BRAND_SOFT })
            .enabled(this.selectedCount() >= 2)
            .onClick(() => this.doImport('QUEUE'))

          Text('返回修改')
            .fontSize(14).fontColor(Colors.TEXT_SUB)
            .width(96).height(46).textAlign(TextAlign.Center)
            .borderRadius(Radius.BUTTON)
            .backgroundColor('#EEF1F6')
            .onClick(() => this.backToInput())
        }
        .width('100%').margin({ top: 10 })
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 48 })
      .backgroundColor(Colors.PAGE_BG)
      .border({ width: { top: 1 }, color: Colors.DIVIDER })
    }
    .width('100%').height('100%')
    .translate({ x: this.stepShift }).opacity(this.stepOpacity)
  }

  @Builder
  SumChip(label: string, fg: ResourceColor, bg: ResourceColor, border: ResourceColor) {
    Text(label)
      .fontSize(11).fontColor(fg).backgroundColor(bg)
      .borderRadius(8).border({ width: 1, color: border })
      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
      .margin({ right: 6, bottom: 6 })
  }

  private countKind(kind: MemeCandidateKind): number {
    let n: number = 0;
    this.rows.forEach((r: CandidateRow): void => {
      if (r.candidate.kind === kind) {
        n++;
      }
    });
    return n;
  }

  private selectedCount(): number {
    let n: number = 0;
    this.rows.forEach((r: CandidateRow): void => {
      if (r.candidate.selected) {
        n++;
      }
    });
    return n;
  }

  private allSelected(): boolean {
    if (this.rows.length === 0) {
      return false;
    }
    return this.selectedCount() === this.rows.length;
  }

  private setAllSelected(flag: boolean): void {
    const next: CandidateRow[] = this.rows.map((r: CandidateRow): CandidateRow => {
      const want: boolean = flag ? (r.candidate.toggleable ? true : r.candidate.selected) : false;
      if (want === r.candidate.selected) {
        return r;
      }
      return new CandidateRow(this.copyCandidate(r.candidate, want, r.candidate.toggleable));
    });
    this.rows = next;
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
          this.TopBar('梗句背单词')
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
