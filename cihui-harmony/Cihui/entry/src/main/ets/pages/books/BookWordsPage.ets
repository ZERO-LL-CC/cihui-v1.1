/**
 * 全书单词浏览页（真机反馈 #21/#22）：
 * - 任意词本都能打开看「全部」单词，不再只有云书详情的 12 词预览；
 * - 两种数据源：bookId 走本地词本（云书已导入 / 拍照 / 手动 DIY / 梗句），
 *   cloudBookId 走随包云书（未导入也可只读浏览全书，底部可下载导入）；
 * - 顶部搜索（英文 / 中文即时过滤）、总数统计、LazyForEach 懒加载（整本 3846 词不卡）；
 * - 本地 DIY/拍照词本右上「编辑」进 DiyBookPage；梗句词本右上「背诵」进梗句背诵。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { AuthStore } from '../../viewmodel/AuthStore';
import { RouteName } from '../../common/RouteNames';
import type { BookWordsRouteParam, DiyBookRouteParam, MemeReviewRouteParam } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { CloudBookLoader } from '../../service/CloudBookLoader';
import { findCloudBook } from '../../service/CloudCatalog';
import type { CloudBookMeta, CloudSampleWord } from '../../service/CloudCatalog';
import type { MemeSentence, Word, WordBook } from '../../model/Types';
import { promptAction } from '@kit.ArkUI';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

interface BookWordRow {
  english: string;
  phonetic: string;
  meaning: string;
}

class BookWordsDataSource implements IDataSource {
  private rows: BookWordRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): BookWordRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  setRows(rows: BookWordRow[]): void {
    this.rows = rows;
    this.listeners.forEach((l: DataChangeListener): void => {
      l.onDataReloaded();
    });
  }
}

@ComponentV2
export struct BookWordsPage {
  @Require @Param param: BookWordsRouteParam;
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 0;
  @Local showTick: number = 0;
  @Local loading: boolean = false;
  @Local loadError: boolean = false;
  @Local keyword: string = '';
  @Local matchedCount: number = 0;
  @Local gate: boolean = false;
  @Local downloading: boolean = false;
  @Local percent: number = 0;
  private ds: BookWordsDataSource = new BookWordsDataSource();
  private allRows: BookWordRow[] = [];
  private timerId: number = -1;
  private meta: CloudBookMeta | null = null;

  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.BOOK_WORDS) {
      this.showTick++;
      this.reloadLocal();
    }
  };

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    if (this.isCloud()) {
      this.meta = findCloudBook(this.param.cloudBookId ?? '');
      this.loadCloud();
    } else {
      this.reloadLocal();
    }
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
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
      promptAction.showToast({ message: msg, duration: 1800 });
    } catch (e) {
    }
  }

  private isCloud(): boolean {
    return (this.param.cloudBookId ?? '').length > 0;
  }

  private localBook(): WordBook | undefined {
    const id: string = this.param.bookId ?? '';
    return DataStore.INSTANCE.books.find((b: WordBook): boolean => b.id === id);
  }

  private titleText(): string {
    if (this.isCloud()) {
      return this.meta ? this.meta.name : '词书单词';
    }
    const b: WordBook | undefined = this.localBook();
    return b ? b.name : '单词列表';
  }

  /** 本地词本：从仓库实时取全部单词（编辑/导入返回后重算） */
  private reloadLocal(): void {
    if (this.isCloud()) {
      return;
    }
    const id: string = this.param.bookId ?? '';
    const list: Word[] = DataStore.INSTANCE.words.filter((w: Word): boolean => w.bookId === id);
    const rows: BookWordRow[] = [];
    for (const w of list) {
      const row: BookWordRow = { english: w.english, phonetic: w.phonetic, meaning: w.meanings.join('；') };
      rows.push(row);
    }
    this.allRows = rows;
    this.applyFilter();
  }

  /** 云书：从 rawfile 异步加载整本（全量，非预览 12 词） */
  private async loadCloud(): Promise<void> {
    const id: string = this.param.cloudBookId ?? '';
    this.loading = true;
    this.loadError = false;
    try {
      const words: CloudSampleWord[] = await CloudBookLoader.loadBook(id);
      const rows: BookWordRow[] = [];
      for (const w of words) {
        const row: BookWordRow = { english: w.english, phonetic: w.phonetic, meaning: w.meaning };
        rows.push(row);
      }
      this.allRows = rows;
      this.applyFilter();
      this.loading = false;
    } catch (e) {
      this.loading = false;
      this.loadError = true;
    }
  }

  private applyFilter(): void {
    const kw: string = this.keyword.trim();
    let rows: BookWordRow[] = this.allRows;
    if (kw.length > 0) {
      const en: string = kw.toLowerCase();
      rows = this.allRows.filter((r: BookWordRow): boolean =>
        r.english.toLowerCase().indexOf(en) >= 0 || r.meaning.indexOf(kw) >= 0);
    }
    this.matchedCount = rows.length;
    this.ds.setRows(rows);
  }

  private onSearch(text: string): void {
    this.keyword = text;
    this.applyFilter();
  }

  private actionLabel(): string {
    if (this.isCloud()) {
      return '';
    }
    const b: WordBook | undefined = this.localBook();
    if (!b) {
      return '';
    }
    if (b.source === 'DIY_PHOTO' || b.source === 'DIY_MANUAL') {
      return '编辑';
    }
    if (b.source === 'MEME') {
      return '背诵';
    }
    return '';
  }

  private onAction(): void {
    const b: WordBook | undefined = this.localBook();
    if (!b) {
      return;
    }
    if (b.source === 'DIY_PHOTO' || b.source === 'DIY_MANUAL') {
      const p: DiyBookRouteParam = { bookId: b.id };
      NavStore.INSTANCE.push(RouteName.DIY_BOOK, p);
    } else if (b.source === 'MEME') {
      const meme: MemeSentence | null = DataStore.INSTANCE.memeByBook(b.id);
      if (meme === null) {
        return;
      }
      const p: MemeReviewRouteParam = { memeId: meme.id };
      NavStore.INSTANCE.push(RouteName.MEME_REVIEW, p);
    }
  }

  private cloudImported(): boolean {
    const id: string = this.param.cloudBookId ?? '';
    return id.length > 0 && DataStore.INSTANCE.isCloudBookImported(id);
  }

  /** 云书对应的本地词本 */
  private localCloudBook(): WordBook | null {
    const cid: string = this.param.cloudBookId ?? '';
    const found: WordBook | undefined =
      DataStore.INSTANCE.books.find((b: WordBook): boolean => b.cloudBookId === cid);
    return found ?? null;
  }

  /** 云书是否已是当前背诵中的词本 */
  private isActiveCloud(): boolean {
    const b: WordBook | null = this.localCloudBook();
    return b !== null && DataStore.INSTANCE.isBookLearning(b.id);
  }

  /** 已导入但没在背 → 切回这本（替代原来不可点的「已在我的词本中」） */
  private switchToThisCloud(): void {
    const b: WordBook | null = this.localCloudBook();
    if (b === null) {
      return;
    }
    DataStore.INSTANCE.switchActiveBook(b.id);
    this.showTick++;
    this.toast(`已切换到《${b.name}》，今日任务已更新`);
    // 首页/打卡的今日任务在 Tab 首建时计算，回首页触发重挂载才能看到新数字
    setTimeout((): void => {
      NavStore.INSTANCE.backToTab(0);
    }, 700);
  }

  private isComing(): boolean {
    return this.meta !== null && this.meta.coming === true;
  }

  private onDownloadTap(): void {
    if (this.cloudImported()) {
      this.toast('已在我的词本中');
      return;
    }
    if (!AuthStore.INSTANCE.isLoggedIn()) {
      this.gate = true;
      return;
    }
    this.startDownload();
  }

  private startDownload(): void {
    this.gate = false;
    this.downloading = true;
    this.percent = 12;
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    this.timerId = setTimeout((): void => {
      this.percent = 52;
      this.runImport();
    }, 260);
  }

  private async runImport(): Promise<void> {
    if (!this.meta) {
      this.downloading = false;
      this.toast('词书信息缺失');
      return;
    }
    try {
      const words: CloudSampleWord[] = await CloudBookLoader.loadBook(this.meta.id);
      if (words.length === 0) {
        this.downloading = false;
        this.toast('词书内容为空');
        return;
      }
      this.percent = 88;
      DataStore.INSTANCE.importCloudBook(this.meta.name, this.meta.id, words);
      this.percent = 100;
      this.toast(`已导入《${this.meta.name}》`);
      setTimeout((): void => {
        NavStore.INSTANCE.backToTabThenPush(2, RouteName.MY_BOOKS);
      }, 500);
    } catch (e) {
      this.downloading = false;
      this.toast('导入失败，请重试');
    }
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())

      Text(this.titleText())
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.actionLabel().length > 0) {
        Text(this.actionLabel())
          .fontSize(13).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
          .borderRadius(14).height(30).padding({ left: 14, right: 14 })
          .textAlign(TextAlign.Center).margin({ right: 4 })
          .onClick(() => this.onAction())
      } else {
        Row().width(44).height(44)
      }
    }
    .width('100%').height(56)
  }

  @Builder
  WordItem(row: BookWordRow) {
    Row() {
      Column() {
        Text(row.english)
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
          .width('100%').textAlign(TextAlign.Start)
        if (row.phonetic.length > 0) {
          Text(row.phonetic)
            .fontSize(12).fontColor(Colors.TEXT_WEAK).margin({ top: 3 })
            .width('100%').textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)

      Text(row.meaning)
        .fontSize(13).fontColor(Colors.TEXT_SUB).textAlign(TextAlign.End)
        .constraintSize({ maxWidth: '46%' }).maxLines(3)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .backgroundColor(Colors.WHITE)
  }

  @Builder
  StateTip(icon: string, title: string, sub: string, showRetry: boolean) {
    Column() {
      Text(icon).fontSize(34).fontColor(Colors.TEXT_WEAK)
      Text(title).fontSize(TypeScale.CARD_TITLE).fontColor(Colors.TEXT_MAIN).margin({ top: 14 })
      Text(sub).fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB).margin({ top: 8 })
      if (showRetry) {
        Button('重新加载')
          .fontSize(14).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
          .borderRadius(Radius.BUTTON).height(42).width(160).margin({ top: 18 })
          .onClick(() => this.loadCloud())
      }
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  @Builder
  GateModal() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor('#66000000')
        .onClick(() => {
          this.gate = false;
        })
      Column() {
        Text('登录后下载').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        Text('云词本下载与自动备份需要登录账号。登录后词书与学习进度可云备份、换机恢复。')
          .fontSize(13).fontColor(Colors.TEXT_SUB).lineHeight(20).margin({ top: 12 })
          .textAlign(TextAlign.Center)
        Button('去登录')
          .width('100%').height(44).borderRadius(Radius.BUTTON)
          .fontSize(14).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND).margin({ top: 20 })
          .onClick(() => {
            this.gate = false;
            NavStore.INSTANCE.push(RouteName.LOGIN);
          })
        Button('暂不')
          .width('100%').height(42).fontSize(14).fontColor(Colors.TEXT_SUB)
          .type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .onClick(() => {
            this.gate = false;
          })
      }
      .width('82%').padding(22).backgroundColor(Colors.WHITE).borderRadius(Radius.SHEET)
    }
    .width('100%').height('100%')
  }

  @Builder
  DownloadingModal() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor('#66000000')
      Column() {
        if (this.percent >= 100) {
          Text('✓').fontSize(26).fontColor(Colors.KNOW_GREEN).fontWeight(FontWeight.Bold)
          Text('下载完成').fontSize(15).fontColor(Colors.TEXT_MAIN).margin({ top: 8 })
        } else {
          LoadingProgress().width(38).height(38).color(Colors.BRAND)
          Text('正在导入词书…').fontSize(15).fontColor(Colors.TEXT_MAIN).margin({ top: 10 })
          Text(`${this.percent}%`).fontSize(13).fontColor(Colors.TEXT_SUB).margin({ top: 6 })
        }
      }
      .width(200).padding({ top: 26, bottom: 26 })
      .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD).justifyContent(FlexAlign.Center)
    }
    .width('100%').height('100%')
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Column() {
          this.TopBar()

          Column() {
            TextInput({ placeholder: '搜索英文或中文', text: this.keyword })
              .width('100%').height(40).fontSize(14).fontColor(Colors.TEXT_MAIN)
              .placeholderColor(Colors.TEXT_WEAK).backgroundColor(Colors.WHITE)
              .borderRadius(Radius.CONTROL).padding({ left: 14, right: 14 })
              .onChange((t: string): void => this.onSearch(t))
          }
          .width('100%').padding(10).backgroundColor(Colors.WHITE).borderRadius(14)
          .margin({ left: 16, right: 16, bottom: 8 })

          Row() {
            Text(`共 ${this.allRows.length} 词`)
              .fontSize(12).fontColor(Colors.TEXT_WEAK).layoutWeight(1)
            if (this.keyword.trim().length > 0) {
              Text(`匹配 ${this.matchedCount} 词`)
                .fontSize(12).fontColor(Colors.BRAND)
            }
          }
          .width('100%').padding({ left: 6, right: 6, bottom: 8 })

          if (this.loading) {
            Column() {
              LoadingProgress().width(36).height(36).color(Colors.BRAND)
              Text('正在加载词书…').fontSize(13).fontColor(Colors.TEXT_SUB).margin({ top: 12 })
            }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          } else if (this.loadError) {
            this.StateTip('!', '词书加载失败', '词书文件缺失或已损坏', true)
          } else if (this.allRows.length === 0) {
            this.StateTip('空', '这本词书还没有单词', '拍照导入或下载云词书后可在此查看全部单词', false)
          } else if (this.matchedCount === 0 && this.keyword.trim().length > 0) {
            this.StateTip('搜', '没有匹配的单词', '换个英文或中文关键词试试', false)
          } else {
            List({ space: 0 }) {
              LazyForEach(this.ds, (row: BookWordRow, index: number) => {
                ListItem() {
                  this.WordItem(row)
                }
              }, (row: BookWordRow, index: number): string => row.english + '-' + index)
            }
            .layoutWeight(1).width('100%').scrollBar(BarState.Auto)
            .clip(true).borderRadius(14).backgroundColor(Colors.WHITE)
            .divider({ strokeWidth: 1, color: Colors.DIVIDER, startMargin: 16, endMargin: 16 })
          }

          if (this.isCloud()) {
            if (this.cloudImported()) {
              if (this.isActiveCloud()) {
                Text('✓ 背诵中')
                  .width('100%').height(46).textAlign(TextAlign.Center)
                  .fontSize(14).fontColor(Colors.KNOW_GREEN).backgroundColor(Colors.KNOW_GREEN_SOFT)
                  .borderRadius(Radius.BUTTON).margin({ top: 10, bottom: 6 })
              } else {
                Button('切换为背诵词本')
                  .width('100%').height(46).borderRadius(Radius.BUTTON)
                  .fontSize(14).fontColor(Colors.BRAND)
                  .backgroundColor(Colors.BRAND_SOFT)
                  .margin({ top: 10, bottom: 6 })
                  .onClick(() => this.switchToThisCloud())
              }
            } else if (!this.isComing()) {
              Button(`下载导入这本书（共 ${this.allRows.length} 词）`)
                .width('100%').height(48).borderRadius(Radius.BUTTON)
                .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
                .margin({ top: 10, bottom: 6 })
                .onClick(() => this.onDownloadTap())
            }
          }
        }
        .width('100%').height('100%')
        .padding({ left: 16, right: 16 })
        .alignItems(HorizontalAlign.Start)

        if (this.gate) {
          this.GateModal()
        }
        if (this.downloading) {
          this.DownloadingModal()
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
      this.reloadLocal();
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
