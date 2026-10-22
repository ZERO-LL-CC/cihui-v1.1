/**
 * 真机反馈 #25 OCR 单词气泡选词页（拍照 → 识别 → 选词 → 校对 → 入库）：
 * - 把识别文本拆成一个个独立英文单词气泡，默认全选，点按勾选 / 取消；
 * - 音标 + 中文优先用 OCR 行级配对结果，缺失的用随包离线词典（LocalDictService）自动补全，
 *   仍无中文的气泡标“补中文”，可取消不要，也能带进校对页手补；
 * - 确认后只把所选词条送 F4 校对页做最终人工校对，再事务入库；
 * - 校对页导入成功返回时，本页消费 importDone 直接回「我的」Tab，与手动录入路径闭环一致。
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { NavStore } from '../../viewmodel/NavStore';
import { RouteName } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import type { OcrPickRouteParam, OcrReviewRouteParam } from '../../common/RouteNames';
import { OcrImageResult } from '../../service/OcrService';
import { parseOcrLines, tokenizeEnglishWords, OcrDraft } from '../../service/OcrParser';
import { LocalDictService } from '../../service/LocalDictService';
import type { DictEntry } from '../../service/LocalDictService';

@ObservedV2
class PickWord {
  @Trace english: string;
  @Trace phonetic: string;
  @Trace meaning: string;
  @Trace selected: boolean;
  @Trace matched: boolean;

  constructor(english: string, phonetic: string, meaning: string, matched: boolean) {
    this.english = english;
    this.phonetic = phonetic;
    this.meaning = meaning;
    this.selected = true;
    this.matched = matched;
  }
}

@ComponentV2
export struct OcrPickPage {
  @Require @Param param: OcrPickRouteParam;
  @Local words: PickWord[] = [];
  @Local loading: boolean = true;
  @Local loadFailed: boolean = false;
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 1;

  aboutToAppear(): void {
    this.prepare();
  }

  private async prepare(): Promise<void> {
    try {
      const results: OcrImageResult[] = this.param.results as OcrImageResult[];
      const lines: string[] = [];
      for (const r of results) {
        for (const line of r.lines) {
          lines.push(line);
        }
      }
      // OCR 行级配对结果（自带中文 / 音标时优先采用）
      const drafts: OcrDraft[] = parseOcrLines(lines);
      const byWord: Map<string, OcrDraft> = new Map<string, OcrDraft>();
      for (const d of drafts) {
        byWord.set(d.english.toLowerCase(), d);
      }
      const tokens: string[] = tokenizeEnglishWords(lines);

      let dictReady: boolean = false;
      const ctx: common.Context = getContext(this) as common.UIAbilityContext;
      try {
        await LocalDictService.ensureLoaded(ctx);
        dictReady = true;
      } catch (e) {
        dictReady = false;
      }

      const list: PickWord[] = [];
      for (const tok of tokens) {
        let phonetic: string = '';
        let meaning: string = '';
        const od: OcrDraft | undefined = byWord.get(tok.toLowerCase());
        if (od !== undefined) {
          phonetic = od.phonetic;
          meaning = od.meaning;
        }
        if (meaning.length === 0 && dictReady) {
          const hit: DictEntry | null = LocalDictService.lookup(tok);
          if (hit !== null) {
            if (phonetic.length === 0) {
              phonetic = hit.phonetic;
            }
            meaning = hit.meaning;
          }
        }
        list.push(new PickWord(tok, phonetic, meaning, meaning.length > 0));
      }
      this.words = list;
      this.loading = false;
    } catch (e) {
      this.loading = false;
      this.loadFailed = true;
    }
  }

  private selectedCount(): number {
    let n: number = 0;
    for (const w of this.words) {
      if (w.selected) {
        n++;
      }
    }
    return n;
  }

  private toggle(w: PickWord): void {
    w.selected = !w.selected;
  }

  private selectAll(): void {
    for (const w of this.words) {
      w.selected = true;
    }
  }

  private clearAll(): void {
    for (const w of this.words) {
      w.selected = false;
    }
  }

  private goManual(): void {
    const mp: OcrReviewRouteParam = {
      results: [],
      manual: true,
      from: this.param.from,
      bookId: this.param.bookId
    };
    NavStore.INSTANCE.push(RouteName.OCR_REVIEW, mp);
  }

  private goReview(): void {
    const picked: OcrDraft[] = [];
    for (const w of this.words) {
      if (w.selected) {
        const d: OcrDraft = { english: w.english, phonetic: w.phonetic, meaning: w.meaning };
        picked.push(d);
      }
    }
    if (picked.length === 0) {
      promptAction.showToast({ message: '请至少选择 1 个单词', duration: 1800 });
      return;
    }
    const rp: OcrReviewRouteParam = {
      results: [],
      picks: picked,
      manual: false,
      from: this.param.from,
      bookId: this.param.bookId
    };
    NavStore.INSTANCE.push(RouteName.OCR_REVIEW, rp);
  }

  @Builder
  Bubble(w: PickWord) {
    Button() {
      Column() {
        Row() {
          if (w.selected) {
            Text('✓')
              .fontSize(11).fontColor(Color.White).margin({ right: 4 })
          }
          Text(w.english)
            .fontSize(15).fontWeight(FontWeight.Medium).maxLines(1)
            .fontColor(w.selected ? Color.White : Colors.TEXT_MAIN)
        }

        Text(w.matched ? w.meaning : '补中文')
          .fontSize(11).maxLines(1).constraintSize({ maxWidth: 156 }).margin({ top: 2 })
          .fontColor(w.selected
            ? (w.matched ? '#DCE7FF' : '#FFD9A8')
            : (w.matched ? Colors.TEXT_WEAK : Colors.FUZZY_ORANGE))
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    }
    .type(ButtonType.Normal)
    .backgroundColor(w.selected ? Colors.BRAND : Colors.WHITE)
    .borderRadius(Radius.CONTROL)
    .border({ width: 1, color: w.selected ? Colors.BRAND : Colors.DIVIDER })
    .margin({ right: 8, bottom: 10 })
    .onClick(() => this.toggle(w))
  }

  build() {
    NavDestination() {
      Column() {
        // 顶栏
        Row() {
          Button() {
            Image($r('app.media.ic_back')).width(26).height(26)
          }
          .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
          .onClick(() => NavStore.INSTANCE.back())
          Column() {
            Text('选择要学的单词')
              .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium)
              .fontColor(Colors.TEXT_MAIN)
            Text(this.loading ? '正在匹配中文释义…' : `识别到 ${this.words.length} 个英文词 · 已选 ${this.selectedCount()}`)
              .fontSize(11.5).fontColor(Colors.TEXT_WEAK).margin({ top: 2 })
          }.layoutWeight(1).alignItems(HorizontalAlign.Center)
          Button('全选')
            .fontSize(13).fontColor(Colors.BRAND).height(40).padding({ left: 6, right: 10 })
            .type(ButtonType.Normal).backgroundColor(Color.Transparent)
            .onClick(() => this.selectAll())
        }
        .width('100%').height(56).padding({ left: 8, right: 8 })

        if (this.loading) {
          Column({ space: 12 }) {
            LoadingProgress().width(40).height(40).color(Colors.BRAND)
            Text('正在识别并匹配中文释义…').fontSize(14).fontColor(Colors.TEXT_SUB)
          }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
        } else if (this.loadFailed) {
          Column({ space: 10 }) {
            Text('识别结果处理失败').fontSize(16).fontColor(Colors.TEXT_MAIN)
            Text('返回重拍，或改用手动录入').fontSize(13).fontColor(Colors.TEXT_WEAK)
            Button('返回')
              .width(160).height(42).borderRadius(21).backgroundColor(Colors.BRAND).fontColor(Color.White)
              .margin({ top: 8 })
              .onClick(() => NavStore.INSTANCE.back())
          }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
        } else if (this.words.length === 0) {
          Column({ space: 10 }) {
            Text('没有识别到英文单词').fontSize(16).fontColor(Colors.TEXT_MAIN)
            Text('尽量正对词表、光线充足，或手动录入').fontSize(13).fontColor(Colors.TEXT_WEAK)
            Row({ space: 12 }) {
              Button('重拍')
                .width(132).height(42).borderRadius(21).backgroundColor(Colors.BRAND).fontColor(Color.White)
                .onClick(() => NavStore.INSTANCE.back())
              Button('手动录入')
                .width(132).height(42).borderRadius(21).backgroundColor(Colors.WHITE)
                .fontColor(Colors.BRAND).border({ width: 1, color: Colors.BRAND })
                .onClick(() => this.goManual())
            }.margin({ top: 10 })
          }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
        } else {
          // 工具行
          Row() {
            Text('点按气泡勾选，橙色为待补中文')
              .fontSize(12.5).fontColor(Colors.TEXT_SUB).layoutWeight(1)
            Button('清空')
              .fontSize(13).fontColor(Colors.TEXT_SUB).height(34)
              .padding({ left: 8, right: 8 }).type(ButtonType.Normal)
              .backgroundColor(Color.Transparent)
              .onClick(() => this.clearAll())
          }
          .width('100%').padding({ left: 18, right: 12, top: 2, bottom: 6 })

          Scroll() {
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.words, (w: PickWord) => {
                this.Bubble(w)
              }, (w: PickWord): string => w.english)
            }
            .width('100%')
            .padding({ left: 16, right: 8, top: 4, bottom: 12 })
          }
          .layoutWeight(1).width('100%').scrollBar(BarState.Off)
          .align(Alignment.Top)

          Button(`导入所选 ${this.selectedCount()} 个词`)
            .width('92%').height(50).borderRadius(25)
            .backgroundColor(this.selectedCount() === 0 ? '#9EABF9' : Colors.BRAND)
            .fontColor(Color.White).fontSize(16).margin({ top: 8, bottom: 8 })
            .enabled(this.selectedCount() > 0)
            .onClick(() => this.goReview())
        }
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
      .safeAreaPadding({ bottom: 8 })
    }
    .hideTitleBar(true)
    .translate({ x: this.sheetX })
    .opacity(this.sheetOpacity)
    .onShown(() => {
      // 校对页导入成功返回：消费标志，直接回「我的」词本（相机页不再需要二次处理）
      if (NavStore.INSTANCE.importDone) {
        NavStore.INSTANCE.importDone = false;
        // 加入当天计划 → 首页（今日任务可见）；加入词本排队 → 我的词本
        NavStore.INSTANCE.backToTab(NavStore.INSTANCE.importDoneTab);
      }
    })
    .customTransition((operation: NavigationOperation, isEnter: boolean): NavDestinationTransition[] | undefined => {
      const reduced: boolean = NavStore.INSTANCE.reducedMotion;
      return [{
        duration: reduced ? Motion.REDUCED : Motion.PAGE,
        curve: Curve.EaseOut,
        event: () => {
          if (reduced) {
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
