/**
 * F17 梗句导入页（同页两步）
 * 步骤一：中文多行输入 +「离线翻译」（端侧梗味引擎，零网络零密钥；未命中不阻断，可手填英文）
 *        + 梗味命中建议（点一行把英文俚语插到英文框末尾）+ 英文多行框；
 * 步骤二：拆词确认——逐词三态标签（已掌握绿/学习中黄/新词蓝）、勾选、左滑删除、顶部汇总；
 *        有效词 <2 拦截；全部已掌握给「再背一遍强化」。
 * 「导入并开始背诵」单次事务落库后，回「我的词本」Tab 并压入梗句背诵页。
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
import type { Word } from '../../model/Types';

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
  @Local rows: CandidateRow[] = [];
  /** 步骤切换横向位移（320ms 右滑感） */
  @Local stepShift: number = 40;
  @Local stepOpacity: number = 0;
  /** 正在加载离线词典并匹配中文释义 */
  @Local preparing: boolean = false;

  aboutToAppear(): void {
    this.playStepEnter();
    // 提前把 3.5MB 词典读进内存：进确认页时已就绪，用户点「拆词」不卡
    this.ensureDict();
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
   * 离线翻译：调端侧梗味引擎，同步返回（仍用 Promise 链保持原交互与 loading 态）。
   * - 有英文（整句命中 / 梗词脚手架）→ 填入英文框，按 level 区分提示；
   * - 无英文（未识别梗词）→ 不覆盖用户已写内容，只提示 result.message。
   */
  private doTranslate(): void {
    if (this.translating) {
      return;
    }
    if (this.chinese.trim().length === 0) {
      this.toast('请先输入中文句子');
      return;
    }
    this.translating = true;
    TranslateService.translateDetail(this.chinese, 'MEME')
      .then((result: TranslateResult): void => {
        this.translating = false;
        this.hits = result.hits;
        if (result.english.length > 0) {
          this.english = result.english;
          if (result.level === 'SENTENCE') {
            this.toast('整句已命中，可直接使用或手动润色');
          } else {
            this.toast(`识别到 ${result.hits.length} 个梗词，已生成英文架子，请手动润色`);
          }
        } else {
          this.toast(result.message.length > 0 ? result.message : '未识别到梗词，请手动填写英文');
        }
      })
      .catch((e: Error): void => {
        this.translating = false;
        this.toast((e as Error)?.message ?? '离线翻译失败，请手动填写英文');
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
        : '请先填写英文句子（可点离线翻译）');
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
          Button(this.translating ? '翻译中…' : '离线翻译')
            .fontSize(13).fontColor(this.translating ? Colors.TEXT_WEAK : Colors.BRAND)
            .backgroundColor(Colors.BRAND_SOFT).borderRadius(Radius.CONTROL)
            .height(34).enabled(!this.translating)
            .onClick(() => this.doTranslate())
        }
        .width('100%').margin({ bottom: 10 })

        TextArea({
          placeholder: '输入一个句子或梗，比如：同学这里不能拉屎',
          text: this.chinese,
        })
          .width('100%').height(128).fontSize(16).fontColor(Colors.TEXT_MAIN)
          .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD).padding(14)
          .placeholderColor(Colors.TEXT_WEAK).placeholderFont({ size: 15 })
          .onChange((v: string) => {
            this.chinese = v;
            // 中文一改，上一轮的梗味命中就作废：否则点一行会把上一句的俚语塞进英文框
            this.hits = [];
          })

        // 英文输入
        Row() {
          Text('英文句子').fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium)
            .fontColor(Colors.TEXT_MAIN).margin({ top: 18 })
          Blank()
        }
        .width('100%').margin({ bottom: 10 })

        TextArea({
          placeholder: '点上方离线翻译自动填入，也可以自己手动输入英文',
          text: this.english,
        })
          .width('100%').height(128).fontSize(16).fontColor(Colors.TEXT_MAIN)
          .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD).padding(14)
          .placeholderColor(Colors.TEXT_WEAK).placeholderFont({ size: 14 })
          .onChange((v: string) => {
            this.english = v;
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
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
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
