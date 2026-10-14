/**
 * F5 个人 DIY 词本页（预览 / 编辑双态）：
 * - 默认预览态不可编辑；右上角「编辑」切编辑态，单词/释义变输入框，可单行删、多选批量删、虚线加词；
 * - 底部「完成并保存（自动上云）」：必填校验（英文/中文均不可空）、空词本拦截、loading、成功 Toast 切回预览；
 * - 「删除词本」二次确认，明确提示级联删除单词/学习记录/排期与对历史统计的影响。
 * 所有改动直接操作 DataStore 内存数组，前端自闭环。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { RouteName } from '../../common/RouteNames';
import type { DiyBookRouteParam } from '../../common/RouteNames';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import type { Word, WordBook } from '../../model/Types';
import { promptAction } from '@kit.ArkUI';
import type { WordDraft } from '../../model/RepoCore';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

@ObservedV2
class EditRow {
  @Trace id: string;
  @Trace english: string;
  @Trace meaning: string;
  @Trace selected: boolean;
  isNew: boolean;

  constructor(id: string, english: string, meaning: string, isNew: boolean) {
    this.id = id;
    this.english = english;
    this.meaning = meaning;
    this.selected = false;
    this.isNew = isNew;
  }
}

@ComponentV2
export struct DiyBookPage {
  @Require @Param param: DiyBookRouteParam;
  @Local sheetX: string = '100%';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.DIY_BOOK) {
      this.showTick++;
    }
  };
  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
  }

  @Local sheetOpacity: number = 0;
  @Local mode: string = 'preview'; // preview | edit
  /** 动态QA：本次进入是否改过数据，返回时清栈回「我的」Tab 整页重挂载，避免列表冻结 */
  @Local mutated: boolean = false;
  @Local rows: EditRow[] = [];
  @Local saving: boolean = false;
  @Local confirmDelete: boolean = false;
  private scroller: Scroller = new Scroller();

  private book(): WordBook | undefined {
    return DataStore.INSTANCE.books.find((b: WordBook): boolean => b.id === this.param.bookId);
  }

  private words(): Word[] {
    return DataStore.INSTANCE.words
      .filter((w: Word): boolean => w.bookId === this.param.bookId)
      .sort((a: Word, b: Word): number => a.createdAt - b.createdAt);
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (e) {
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

  private enterEdit(): void {
    const list: EditRow[] = this.words().map((w: Word): EditRow =>
      new EditRow(w.id, w.english, w.meanings.join('；'), false));
    this.rows = list;
    this.mode = 'edit';
  }

  private addRow(): void {
    this.rows.push(new EditRow('', '', '', true));
    setTimeout(() => {
      this.scroller.scrollToIndex(this.rows.length, true, ScrollAlign.END);
    }, 60);
  }

  private removeRow(index: number): void {
    this.getUIContext().animateTo({ duration: Motion.FEEDBACK, curve: Curve.EaseOut }, () => {
      this.rows.splice(index, 1);
    });
  }

  private removeSelected(): void {
    const remain: EditRow[] = this.rows.filter((r: EditRow): boolean => !r.selected);
    this.getUIContext().animateTo({ duration: Motion.FEEDBACK, curve: Curve.EaseOut }, () => {
      this.rows = remain;
    });
  }

  private selectedCount(): number {
    return this.rows.filter((r: EditRow): boolean => r.selected).length;
  }

  /** 校验并保存：删除移除的旧词、更新改过的旧词、新增新词，全部直接操作内存仓库 */
  private save(): void {
    if (this.rows.length === 0) {
      this.toast('词本为空，无法保存；如需删除词本请点底部「删除词本」');
      return;
    }
    for (let i = 0; i < this.rows.length; i++) {
      const r: EditRow = this.rows[i];
      if (r.english.trim().length === 0) {
        this.toast(`第 ${i + 1} 行缺少英文单词`);
        return;
      }
      if (r.meaning.trim().length === 0) {
        this.toast(`第 ${i + 1} 行缺少中文释义`);
        return;
      }
    }
    this.saving = true;
    // 短 loading 让保存反馈可见（与原型一致），随后一次性提交
    setTimeout(() => {
      try {
        const current: Word[] = this.words();
        const currentIds: Set<string> = new Set(this.rows.filter((r: EditRow): boolean => !r.isNew)
          .map((r: EditRow): string => r.id));
        const removedIds: string[] = current
          .filter((w: Word): boolean => !currentIds.has(w.id))
          .map((w: Word): string => w.id);
        if (removedIds.length > 0) {
          DataStore.INSTANCE.batchDeleteWords(removedIds);
        }
        for (const r of this.rows) {
          const meanings: string[] = r.meaning.split(/[；;]/)
            .map((s: string): string => s.trim())
            .filter((s: string): boolean => s.length > 0);
          if (r.isNew) {
            const draft: WordDraft = {
              bookId: this.param.bookId,
              english: r.english.trim(),
              meanings,
              source: 'MANUAL',
            };
            DataStore.INSTANCE.addWord(draft);
          } else {
            DataStore.INSTANCE.updateWord(r.id, { english: r.english.trim(), meanings });
          }
        }
        this.saving = false;
        this.mode = 'preview';
        this.mutated = true;
        this.toast('已保存，登录后将自动上云备份');
      } catch (e) {
        this.saving = false;
        this.toast('保存失败：' + (e as Error).message);
      }
    }, 500);
  }

  private doDeleteBook(): void {
    DataStore.INSTANCE.deleteBook(this.param.bookId);
    this.confirmDelete = false;
    this.toast('词本已删除');
    NavStore.INSTANCE.backToTab(2);
  }

  /** 改过数据则清栈回「我的」Tab（整页重挂载），否则普通返回 */
  private leave(): void {
    if (this.mutated) {
      NavStore.INSTANCE.backToTab(2);
    } else {
      NavStore.INSTANCE.back();
    }
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => this.leave())

      Text(this.book() ? this.book()!.name : '词本')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(this.mode === 'preview' ? '编辑' : '预览')
        .fontSize(15).fontColor(Colors.BRAND)
        .height(44).padding({ left: 12, right: 12 })
        .textAlign(TextAlign.Center)
        .onClick(() => {
          if (this.mode === 'preview') {
            this.enterEdit();
          } else {
            this.save();
          }
        })
    }
    .width('100%').height(56)
  }

  @Builder
  PreviewList() {
    if (this.words().length === 0) {
      Column() {
        Text('词本还是空的').fontSize(TypeScale.CARD_TITLE).fontColor(Colors.TEXT_SUB)
        Text('点右上角「编辑」添加单词').fontSize(TypeScale.CAPTION)
          .fontColor(Colors.TEXT_WEAK).margin({ top: 8 })
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    } else {
      List({ scroller: this.scroller, space: 10 }) {
        ForEach(this.words(), (w: Word) => {
          ListItem() {
            Column() {
              Text(w.english)
                .fontSize(16).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
                .width('100%').textAlign(TextAlign.Start)
              Text(w.meanings.join('；'))
                .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB)
                .width('100%').margin({ top: 5 }).textAlign(TextAlign.Start)
            }
            .width('100%').padding({ left: 14, right: 14, top: 11, bottom: 11 })
            .backgroundColor(Colors.WHITE).borderRadius(14)
            .alignItems(HorizontalAlign.Start)
          }
        }, (w: Word): string => w.id)
      }
      .layoutWeight(1).width('100%').padding({ left: 16, right: 16 }).scrollBar(BarState.Off)
    }
  }

  @Builder
  EditRowCard(r: EditRow, index: number) {
    Row() {
      // 多选：批量删除
      Column() {
        if (r.selected) {
          Text('✓').fontSize(13).fontColor(Colors.WHITE).fontWeight(FontWeight.Bold)
        }
      }
      .width(22).height(22).borderRadius(11)
      .backgroundColor(r.selected ? Colors.UNKNOWN_RED : Color.Transparent)
      .border({ width: 1.5, color: r.selected ? Colors.UNKNOWN_RED : Colors.TEXT_WEAK })
      .justifyContent(FlexAlign.Center)
      .margin({ right: 10 })
      .onClick(() => {
        r.selected = !r.selected;
      })

      Column() {
        TextInput({ text: r.english, placeholder: '英文单词' })
          .fontSize(16).fontColor(Colors.TEXT_MAIN).backgroundColor(Color.Transparent)
          .height(40).padding(0).margin(0)
          .onChange((v: string) => {
            r.english = v;
          })
        Divider().color(Colors.DIVIDER)
        TextInput({ text: r.meaning, placeholder: '输入中文释义' })
          .fontSize(13).fontColor(Colors.TEXT_SUB).backgroundColor(Color.Transparent)
          .height(40).padding(0).margin(0)
          .onChange((v: string) => {
            r.meaning = v;
          })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)

      // 单行删除
      Button() {
        Text('−').fontSize(20).fontColor(Colors.WHITE).fontWeight(FontWeight.Bold)
      }
      .type(ButtonType.Circle).width(24).height(24)
      .backgroundColor(Colors.UNKNOWN_RED).margin({ left: 8 })
      .onClick(() => this.removeRow(index))
    }
    .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(Colors.WHITE).borderRadius(14)
  }

  @Builder
  EditList() {
    Column() {
      List({ scroller: this.scroller, space: 10 }) {
        ForEach(this.rows, (r: EditRow, index: number) => {
          ListItem() {
            this.EditRowCard(r, index)
          }
        }, (r: EditRow, idx: number): string => r.id.length > 0 ? r.id : 'new_' + idx.toString())

        ListItem() {
          Button() {
            Row() {
              Text('+').fontSize(18).fontColor(Colors.BRAND).margin({ right: 6 })
              Text('添加单词').fontSize(14).fontColor(Colors.BRAND)
            }
          }
          .type(ButtonType.Normal)
          .width('100%').height(46)
          .borderRadius(14)
          .backgroundColor(Color.Transparent)
          .border({ width: 1.5, color: Colors.BRAND, style: BorderStyle.Dashed })
          .onClick(() => this.addRow())
        }
        .width('100%').margin({ top: 2, bottom: 12 })
      }
      .layoutWeight(1).width('100%').padding({ left: 16, right: 16 }).scrollBar(BarState.Off)

      // 底部操作条：批量删除 + 保存 + 删除词本
      Column() {
        if (this.selectedCount() > 0) {
          Button(`删除所选（${this.selectedCount()}）`)
            .width('100%').height(42).borderRadius(Radius.BUTTON)
            .fontSize(14).fontColor(Colors.UNKNOWN_RED)
            .backgroundColor(Colors.UNKNOWN_RED_SOFT)
            .margin({ bottom: 10 })
            .onClick(() => this.removeSelected())
        }
        Button('完成并保存（自动上云）')
          .width('100%').height(48).borderRadius(Radius.BUTTON)
          .fontSize(TypeScale.BODY).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
          .onClick(() => this.save())
        Button('删除词本')
          .width('100%').height(40)
          .fontSize(13).fontColor(Colors.TEXT_WEAK)
          .type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .onClick(() => {
            this.confirmDelete = true;
          })
      }
      .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 14 })
      .backgroundColor(Colors.PAGE_BG)
    }
    .layoutWeight(1).width('100%')
  }

  @Builder
  DeleteModal() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%').height('100%').backgroundColor('#66000000')
        .onClick(() => {
          this.confirmDelete = false;
        })
      Column() {
        Text('删除词本？').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        Text(`将一并删除「${this.book() ? this.book()!.name : ''}」下的全部单词、学习记录与复习排期，历史打卡统计可能变化，且不可恢复。`)
          .fontSize(13).fontColor(Colors.TEXT_SUB).lineHeight(20)
          .margin({ top: 12 }).textAlign(TextAlign.Center)
        Row() {
          Button('取消')
            .layoutWeight(1).height(42).borderRadius(Radius.BUTTON)
            .fontSize(14).fontColor(Colors.TEXT_SUB).backgroundColor(Colors.PAGE_BG)
            .onClick(() => {
              this.confirmDelete = false;
            })
          Button('删除')
            .layoutWeight(1).height(42).borderRadius(Radius.BUTTON)
            .fontSize(14).fontColor(Colors.WHITE).backgroundColor(Colors.UNKNOWN_RED)
            .margin({ left: 12 })
            .onClick(() => this.doDeleteBook())
        }
        .width('100%').margin({ top: 20 })
      }
      .width('82%').padding(22).backgroundColor(Colors.WHITE).borderRadius(Radius.SHEET)
    }
    .width('100%').height('100%')
  }

  @Builder
  SavingMask() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        LoadingProgress().width(40).height(40).color(Colors.BRAND)
        Text('正在保存…').fontSize(13).fontColor(Colors.TEXT_SUB).margin({ top: 10 })
      }
      .padding({ left: 34, right: 34, top: 22, bottom: 22 })
      .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    }
    .width('100%').height('100%').backgroundColor('#55000000')
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Column() {
          this.TopBar()
          if (this.mode === 'preview') {
            this.PreviewList()
          } else {
            this.EditList()
          }
        }
        .width('100%').height('100%')

        if (this.confirmDelete) {
          this.DeleteModal()
        }
        if (this.saving) {
          this.SavingMask()
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
