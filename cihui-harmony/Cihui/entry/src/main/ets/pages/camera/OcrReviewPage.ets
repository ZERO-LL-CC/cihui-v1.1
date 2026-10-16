/**
 * F4 OCR 校对页（人工校对是入库前置，不可跳过）：
 * - 英文 + 中文逐行配对，缺释义行显橙“补录中文”，补录释义归 DIY 词本口径；
 * - 左滑/图标删行（200ms 收起）、虚线按钮添加行、英文去重在解析阶段完成；
 * - sticky 底栏“确认导入 N 个词”；有缺释义行先拦截弹窗并定位首条；
 * - 单次事务 importTransaction 导入，成功 Toast 后关闭全部二级页回来源页；
 * - 新词立即排期，首页数字同源；缺释义词只能手动闪卡、不进语音快过（F8 消费）。
 */
import { promptAction } from '@kit.ArkUI';
import { NavStore } from '../../viewmodel/NavStore';
import { RouteName } from '../../common/RouteNames';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius } from '../../common/DesignTokens';
import type { OcrReviewRouteParam } from '../../common/RouteNames';
import { OcrImageResult } from '../../service/OcrService';
import { parseOcrLines, OcrDraft } from '../../service/OcrParser';
import { PHOTO_BOOK_NAME } from '../../model/RepoCore';
import type { WordDraft } from '../../model/RepoCore';
import type { IntakeMode, WordBook } from '../../model/Types';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

let rowSeq: number = 1;

@ObservedV2
class ReviewRow {
  @Trace id: string;
  @Trace english: string;
  @Trace phonetic: string;
  @Trace meaning: string;
  /** OCR 原始行（区分来源：OCR 允许缺释义入库；手动添加行必须有释义） */
  @Trace fromOcr: boolean;
  @Trace highlight: boolean;

  constructor(english: string, phonetic: string, meaning: string, fromOcr: boolean) {
    this.id = 'row_' + (rowSeq++);
    this.english = english;
    this.phonetic = phonetic;
    this.meaning = meaning;
    this.fromOcr = fromOcr;
    this.highlight = false;
  }

  missing(): boolean {
    return this.meaning.trim().length === 0;
  }
}

@ComponentV2
export struct OcrReviewPage {
  @Require @Param param: OcrReviewRouteParam;
  @Local rows: ReviewRow[] = [];
  @Local showMissingDialog: boolean = false;
  @Local importing: boolean = false;
  /** F-A 缺释义弹窗拦截时记住用户选择的入列方式，补录后按原选择导入 */
  private pendingIntake: IntakeMode = 'QUEUE';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.OCR_REVIEW) {
      this.showTick++;
    }
  };
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    if (this.param.manual) {
      this.rows = [];
      return;
    }
    // 气泡选词页（#25）已选定并自动匹配中文的词条：直接作为校对初始数据
    if (this.param.picks && this.param.picks.length > 0) {
      const picks: OcrDraft[] = this.param.picks as OcrDraft[];
      this.rows = picks.map((d: OcrDraft): ReviewRow =>
        new ReviewRow(d.english, d.phonetic, d.meaning, true));
      return;
    }
    const results: OcrImageResult[] = this.param.results as OcrImageResult[];
    const lines: string[] = [];
    for (const r of results) {
      for (const line of r.lines) {
        lines.push(line);
      }
    }
    const drafts: OcrDraft[] = parseOcrLines(lines);
    this.rows = drafts.map((d: OcrDraft): ReviewRow =>
      new ReviewRow(d.english, d.phonetic, d.meaning, true));
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
  }

  private addRow(): void {
    this.rows.push(new ReviewRow('', '', '', false));
    setTimeout((): void => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 60);
  }

  private deleteRow(id: string): void {
    const idx: number = this.rows.findIndex((r: ReviewRow): boolean => r.id === id);
    if (idx < 0) {
      return;
    }
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseInOut }, (): void => {
      this.rows.splice(idx, 1);
    });
  }

  private missingCount(): number {
    return this.rows.filter((r: ReviewRow): boolean => r.missing()).length;
  }

  /** 找到/创建本次导入目标 DIY 词本（F-D：拍照导入固定独立词本「拍照词本」，算法一起计算） */
  private resolveBook(now: Date): string {
    if (this.param.bookId && this.param.bookId.length > 0) {
      return this.param.bookId;
    }
    const store: DataStore = DataStore.INSTANCE;
    if (this.param.manual) {
      const exist: WordBook | undefined =
        store.books.find((b: WordBook): boolean => b.name === '手动生词本');
      if (exist) {
        return exist.id;
      }
      store.addBook('手动生词本', 'DIY_MANUAL');
    } else {
      const exist: WordBook | undefined =
        store.books.find((b: WordBook): boolean => b.name === PHOTO_BOOK_NAME);
      if (exist) {
        return exist.id;
      }
      store.addBook(PHOTO_BOOK_NAME, 'DIY_PHOTO');
    }
    const created: WordBook | undefined = [...store.books].pop();
    return created ? created.id : '';
  }

  private async doImport(allowMissing: boolean, intake: IntakeMode = 'QUEUE'): Promise<void> {
    if (this.importing) {
      return;
    }
    // 必填校验：英文单词不能为空
    const emptyEnglish: ReviewRow | undefined =
      this.rows.find((r: ReviewRow): boolean => r.english.trim().length === 0);
    if (emptyEnglish) {
      promptAction.showToast({ message: '存在未填写英文的行，请补全或删除', duration: 2200 });
      return;
    }
    const missing: number = this.missingCount();
    if (missing > 0 && !allowMissing) {
      this.pendingIntake = intake;
      this.showMissingDialog = true;
      return;
    }
    if (!allowMissing) {
      // 手动添加行缺释义不允许入库（validateWord 也会拦，提前给友好提示）
      const manualMissing: ReviewRow | undefined =
        this.rows.find((r: ReviewRow): boolean => !r.fromOcr && r.missing());
      if (manualMissing) {
        promptAction.showToast({ message: '手动添加的单词请填写中文释义', duration: 2200 });
        return;
      }
    }
    this.importing = true;
    try {
      const bookId: string = this.resolveBook(new Date());
      const drafts: WordDraft[] = this.rows.map((r: ReviewRow): WordDraft => {
        return {
          bookId,
          english: r.english.trim(),
          phonetic: r.phonetic.trim(),
          meanings: r.meaning.split(/[；;]/).map((m: string): string => m.trim())
            .filter((m: string): boolean => m.length > 0),
          // OCR 行补录过中文释义标 DIY_SUPPLEMENT；纯 OCR 无释义保留 OCR（允许缺释义入库）
          source: r.fromOcr ? (r.missing() ? 'OCR' : 'DIY_SUPPLEMENT') : 'MANUAL'
        };
      });
      // 单次事务：失败抛异常，不产生半截数据；成功立即排期
      DataStore.INSTANCE.importWords(drafts, intake);
      promptAction.showToast({
        message: intake === 'TODAY'
          ? `已导入 ${drafts.length} 个词，已加入今日计划`
          : `已导入 ${drafts.length} 个词，将按每日新词量排队`,
        duration: 2200
      });
      // 关闭全部二级页回来源页：本页返回后由相机页 onShown 再退一层
      NavStore.INSTANCE.importDone = true;
      NavStore.INSTANCE.back();
    } catch (err) {
      promptAction.showToast({ message: `导入失败：${(err as Error).message}`, duration: 2600 });
      this.importing = false;
    }
  }

  private locateFirstMissing(): void {
    this.showMissingDialog = false;
    const idx: number = this.rows.findIndex((r: ReviewRow): boolean => r.missing());
    if (idx >= 0) {
      for (const r of this.rows) {
        r.highlight = false;
      }
      this.rows[idx].highlight = true;
      this.scroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
      setTimeout((): void => {
        if (this.rows[idx]) {
          this.rows[idx].highlight = false;
        }
      }, 2400);
    }
  }

  @Builder
  RowCard(row: ReviewRow, idx: number) {
    Column() {
      Row() {
        TextInput({ text: row.english, placeholder: '英文单词' })
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
          .backgroundColor(Color.Transparent).layoutWeight(1).height(40)
          .onChange((v: string): void => {
            row.english = v;
          })
        Button() {
          Path({ width: 20, height: 22 })
            .commands('M5 6 H19 M9 6 V4 H15 V6 M7 6 V20 H17 V6')
            .stroke(Colors.TEXT_WEAK).strokeWidth(1.8).fill(Color.Transparent)
            .strokeLineCap(LineCapStyle.Round)
        }
        .type(ButtonType.Normal).width(40).height(44).backgroundColor(Color.Transparent)
        .onClick(() => this.deleteRow(row.id))
      }.width('100%')

      TextInput({ text: row.phonetic, placeholder: '音标（选填）' })
        .fontSize(12.5).fontColor(Colors.TEXT_WEAK)
        .backgroundColor(Color.Transparent).height(32).margin({ top: 2 })
        .onChange((v: string): void => {
          row.phonetic = v;
        })

      Row() {
        TextInput({ text: row.meaning, placeholder: '中文释义，多个义项用；分隔' })
          .fontSize(14.5).fontColor(Colors.TEXT_MAIN)
          .backgroundColor(Color.Transparent).layoutWeight(1).height(40)
          .onChange((v: string): void => {
            row.meaning = v;
          })
        if (row.missing()) {
          Text('补录中文')
            .fontSize(11.5).fontColor(Color.White)
            .backgroundColor(Colors.FUZZY_ORANGE).borderRadius(10)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        }
      }.width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 10, top: 10, bottom: 10 })
    .backgroundColor(Colors.WHITE)
    .borderRadius(Radius.CARD)
    .border({
      width: row.highlight ? 1.5 : 0,
      color: Colors.FUZZY_ORANGE
    })
    .margin({ bottom: 10 })
  }

  @Builder
  MissingDialog() {
    Column() {
      Text('还有单词缺少中文释义').fontSize(17).fontWeight(FontWeight.Medium)
        .fontColor(Colors.TEXT_MAIN)
      Text(`有 ${this.missingCount()} 个词没有中文释义。补录后可进入语音快过；不补录也能导入，但只能手动翻卡复习。`)
        .fontSize(13.5).fontColor(Colors.TEXT_SUB).lineHeight(21)
        .margin({ top: 10, bottom: 20 })
      Button('去补录')
        .width('100%').height(44).borderRadius(22).backgroundColor(Colors.BRAND).fontColor(Color.White)
        .onClick(() => this.locateFirstMissing())
      Button('仍然导入（仅手动闪卡）')
        .width('100%').height(42).fontSize(14).fontColor(Colors.TEXT_SUB)
        .type(ButtonType.Normal).backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showMissingDialog = false;
          this.doImport(true, this.pendingIntake);
        })
      Button('取消')
        .width('100%').height(40).fontSize(13).fontColor(Colors.TEXT_WEAK)
        .type(ButtonType.Normal).backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showMissingDialog = false;
        })
    }
    .width('82%').padding(22).backgroundColor(Colors.WHITE).borderRadius(Radius.SHEET)
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          // 顶栏
          Row() {
            Button() {
              Image($r('app.media.ic_back')).width(26).height(26)
            }
            .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
            .onClick(() => NavStore.INSTANCE.back())
            Column() {
              Text(this.param.manual ? '手动录入生词' : '校对识别结果')
                .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium)
                .fontColor(Colors.TEXT_MAIN)
              Text(`共 ${this.rows.length} 个词 · 校对确认后才会导入`)
                .fontSize(11.5).fontColor(Colors.TEXT_WEAK).margin({ top: 2 })
            }.layoutWeight(1).alignItems(HorizontalAlign.Center)
            Button('+ 添加')
              .fontSize(13.5).fontColor(Colors.BRAND).height(40)
              .padding({ left: 8, right: 8 }).type(ButtonType.Normal)
              .backgroundColor(Color.Transparent)
              .onClick(() => this.addRow())
          }
          .width('100%').height(56).padding({ left: 8, right: 12 })

          if (this.rows.length === 0) {
            Column() {
              Text('还没有单词').fontSize(16).fontColor(Colors.TEXT_SUB)
              Text('点下方“添加单词”录入英文和中文释义').fontSize(13)
                .fontColor(Colors.TEXT_WEAK).margin({ top: 8 })
            }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
          } else {
            List({ scroller: this.scroller }) {
              ForEach(this.rows, (row: ReviewRow, idx: number) => {
                ListItem() {
                  this.RowCard(row, idx)
                }
                .swipeAction({
                  end: this.DeleteSwipe(row.id)
                })
              }, (row: ReviewRow): string => row.id)
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ left: 16, right: 16, top: 6 })
            .scrollBar(BarState.Off)
          }

          // 虚线添加按钮
          Button() {
            Row() {
              Text('+ 添加单词').fontSize(14.5).fontColor(Colors.BRAND)
            }.justifyContent(FlexAlign.Center).width('100%').height(46)
            .border({ width: 1.5, color: Colors.BRAND, radius: 16, style: BorderStyle.Dashed })
          }
          .type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .margin({ left: 16, right: 16 })
          .onClick(() => this.addRow())

          // sticky 底栏：F-A 两种入列方式（加入当天计划=今天立即首学不占配额；加入词本=按每日新词量排队）
          Row() {
            Button('加入当天计划')
              .layoutWeight(1).height(50).borderRadius(25)
              .backgroundColor(this.rows.length === 0 ? '#9EABF9' : Colors.KNOW_GREEN)
              .fontColor(Color.White).fontSize(15)
              .enabled(this.rows.length > 0 && !this.importing)
              .onClick(() => this.doImport(false, 'TODAY'))
            Button('加入词本')
              .layoutWeight(1).height(50).borderRadius(25)
              .backgroundColor(this.rows.length === 0 ? '#9EABF9' : Colors.BRAND)
              .fontColor(Color.White).fontSize(15)
              .enabled(this.rows.length > 0 && !this.importing)
              .onClick(() => this.doImport(false, 'QUEUE'))
          }
          .width('92%').margin({ top: 12, bottom: 8 })
        }
        .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
        .safeAreaPadding({ bottom: 8 })

        if (this.showMissingDialog) {
          Column() {
            this.MissingDialog()
          }
          .width('100%').height('100%').backgroundColor('#66000000')
          .justifyContent(FlexAlign.Center).padding(28)
        }
      }
      .width('100%').height('100%')
    }
    .hideTitleBar(true)
    .opacity(1 + this.showTick * 0)
    .onShown(() => {
      this.showTick++;
    })
  }

  @Builder
  DeleteSwipe(id: string) {
    Button('删除')
      .fontSize(14).fontColor(Color.White).backgroundColor(Colors.UNKNOWN_RED)
      .borderRadius(16)
      .width(76).height('92%')
      .onClick(() => this.deleteRow(id))
  }
}
