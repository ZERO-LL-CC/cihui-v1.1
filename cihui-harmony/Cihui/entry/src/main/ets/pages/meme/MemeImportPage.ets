/**
 * F17 梗句导入页（同页两步）
 * 步骤一：中文多行输入 +「AI 翻译（免费）」（复用火山豆包 lite，失败不阻断，可手填英文）+ 英文多行框；
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
import { TranslateService } from '../../service/TranslateService';
import type { MemeCandidate, MemeCandidateKind } from '../../model/MemeCore';
import { summarizeCandidates } from '../../model/MemeCore';

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
  @Local rows: CandidateRow[] = [];
  /** 步骤切换横向位移（320ms 右滑感） */
  @Local stepShift: number = 40;
  @Local stepOpacity: number = 0;

  aboutToAppear(): void {
    this.playStepEnter();
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

  /** AI 翻译：后台请求，按钮 loading 禁用，失败 Toast 且不阻断手填 */
  private doTranslate(): void {
    if (this.translating) {
      return;
    }
    if (this.chinese.trim().length === 0) {
      this.toast('请先输入中文句子');
      return;
    }
    this.translating = true;
    TranslateService.zhToEn(this.chinese)
      .then((out: string): void => {
        this.translating = false;
        this.english = out;
        this.toast('翻译完成，可手动修改英文');
      })
      .catch((e: Error): void => {
        this.translating = false;
        this.toast((e as Error)?.message ?? '翻译失败，可手动填写英文');
      });
  }

  /** 拆词 → 进入确认步 */
  private goConfirm(): void {
    if (this.english.trim().length === 0) {
      this.toast('请先填写英文句子（可点 AI 翻译）');
      return;
    }
    const candidates: MemeCandidate[] = DataStore.INSTANCE.memeCandidates(this.english);
    if (candidates.length === 0) {
      this.toast('没有识别到有效实词，请检查英文句子');
      return;
    }
    const rowList: CandidateRow[] = [];
    candidates.forEach((c: MemeCandidate): void => {
      rowList.push(new CandidateRow(c));
    });
    this.rows = rowList;
    this.step = 2;
    this.playStepEnter();
  }

  private backToInput(): void {
    this.step = 1;
    this.playStepEnter();
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
      const c: MemeCandidate = {
        token: r.candidate.token,
        kind: r.candidate.kind,
        existingWordId: r.candidate.existingWordId,
        selected: !r.candidate.selected,
        toggleable: r.candidate.toggleable,
      };
      const nr: CandidateRow = new CandidateRow(c);
      return nr;
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
      const c: MemeCandidate = {
        token: r.candidate.token,
        kind: r.candidate.kind,
        existingWordId: r.candidate.existingWordId,
        selected: true,
        toggleable: true,
      };
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

  @Builder
  CandidateRowView(row: CandidateRow) {
    Stack({ alignContent: Alignment.End }) {
      // 底层删除区
      Row() {
        Blank()
        Button('删除')
          .fontSize(14).fontColor(Colors.WHITE).backgroundColor(Colors.UNKNOWN_RED)
          .height(48).width(72).borderRadius(Radius.CONTROL)
          .onClick(() => this.removeRow(row))
      }
      .width('100%').height(52).padding({ right: 4 })

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
        .width(34).height(48)

        Text(row.candidate.token)
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
          .layoutWeight(1).margin({ left: 4 })

        this.LabelTag(row.candidate.kind)
      }
      .width('100%').height(52).padding({ left: 12, right: 14 })
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
    .width('100%').height(52).margin({ bottom: 10 })
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
          Button(this.translating ? '翻译中…' : 'AI 翻译（免费）')
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
          })

        // 英文输入
        Row() {
          Text('英文句子').fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium)
            .fontColor(Colors.TEXT_MAIN).margin({ top: 18 })
          Blank()
        }
        .width('100%').margin({ bottom: 10 })

        TextArea({
          placeholder: '点上方 AI 翻译自动填入，也可以自己手动输入英文',
          text: this.english,
        })
          .width('100%').height(128).fontSize(16).fontColor(Colors.TEXT_MAIN)
          .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD).padding(14)
          .placeholderColor(Colors.TEXT_WEAK).placeholderFont({ size: 14 })
          .onChange((v: string) => {
            this.english = v;
          })

        Text('拆词会自动过滤 the / is / you 这类虚词并去重，实词才进背诵')
          .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_WEAK).margin({ top: 12 })
          .width('100%')
      }
      .width('100%').padding({ left: 18, right: 18, top: 6 })
    }
    .layoutWeight(1).align(Alignment.Top)
    .scrollBar(BarState.Off)

    Button('拆词 →')
      .fontSize(17).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
      .borderRadius(Radius.BUTTON).height(52).width('92%').margin({ bottom: 26 })
      .onClick(() => this.goConfirm())
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
    return `本句共 ${s.total} 词 · 已掌握 ${s.mastered} · 学习中 ${s.learning} · 新词 ${s.fresh} · 将学 ${s.willStudy}`;
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
