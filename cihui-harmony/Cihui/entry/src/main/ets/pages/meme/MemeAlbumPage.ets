/**
 * F18 梗卡册
 *
 * - 展示全部已解锁梗卡，按解锁时间倒序；默认空列表，背完梗句弹卡后才有数据；
 * - 每行：4:5 缩略卡（Canvas PNG；Canvas 失败时显示同构 ArkUI 降级卡）+ 原句/掌握数/日期/徽章；
 * - 点行打开大图浮层，浮层内可「再分享」（Share Kit 系统面板）；
 * - 行左滑露出删除，松手弹二次确认；只删卡，不删梗句、词与会话记录；
 * - 星标切换收藏，收藏状态与背诵页半模态同源（DataStore.toggleMemeCardFavorite）。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { Colors, TypeScale, Radius, Motion } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
import type { MemeBadgeLevel, MemeCard, MemeSentence } from '../../model/Types';
import { MemeCardService } from '../../service/MemeCardService';
import { ShareService } from '../../service/ShareService';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

/** 卡册行视图模型：梗卡 + 对应梗句快照（梗句可能已被删，句子字段兜底为空） */
@ObservedV2
class AlbumRow {
  card: MemeCard;
  chinese: string;
  english: string;

  constructor(card: MemeCard, meme: MemeSentence | null) {
    this.card = card;
    this.chinese = meme === null ? '（原梗句已删除）' : meme.chinese;
    this.english = meme === null ? '' : meme.english;
  }
}

@ComponentV2
export struct MemeAlbumPage {
  @Local sheetX: string = '100%';
  @Local sheetOpacity: number = 0;
  @Local showTick: number = 0;
  @Local rows: AlbumRow[] = [];
  @Local preview: AlbumRow | null = null;
  @Local previewEnter: number = 0;
  @Local busy: boolean = false;
  /** 组件快照离屏导出时的当前行（createFromBuilder 只接受无参 CustomBuilder） */
  @Local snapshotRow: AlbumRow | null = null;

  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.MEME_ALBUM) {
      this.showTick++;
      this.reload();
    }
  };

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    this.reload();
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
  }

  private reload(): void {
    const cards: MemeCard[] = DataStore.INSTANCE.memeCardAlbum();
    const out: AlbumRow[] = [];
    cards.forEach((card: MemeCard): void => {
      const meme: MemeSentence | null = DataStore.INSTANCE.memeById(card.memeId);
      out.push(new AlbumRow(card, meme));
    });
    this.rows = out;
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
      console.warn(`[MemeAlbum] toast: ${(e as Error)?.message ?? e}`);
    }
  }

  private badgeColor(level: MemeBadgeLevel): ResourceColor {
    if (level === 'GOLD') {
      return '#F5C542';
    }
    if (level === 'SILVER') {
      return '#C7D0DA';
    }
    return '#D08A4E';
  }

  /** 左滑删除：二次确认，只删卡 */
  private askDelete(row: AlbumRow): void {
    try {
      promptAction.showDialog({
        title: '删除这张梗卡？',
        message: '只删除卡片，不影响梗句、单词与学习记录',
        buttons: [
          { text: '取消', color: Colors.TEXT_SUB },
          { text: '删除', color: Colors.UNKNOWN_RED },
        ],
      }).then((r): void => {
        if (r.index === 1) {
          DataStore.INSTANCE.deleteMemeCard(row.card.id);
          if (this.preview !== null && this.preview.card.id === row.card.id) {
            this.preview = null;
          }
          this.reload();
          this.toast('梗卡已删除');
        }
      });
    } catch (e) {
      console.warn(`[MemeAlbum] delete dialog: ${(e as Error)?.message ?? e}`);
    }
  }

  private toggleFavorite(row: AlbumRow): void {
    DataStore.INSTANCE.toggleMemeCardFavorite(row.card.id);
    this.reload();
  }

  private openPreview(row: AlbumRow): void {
    this.preview = row;
    this.previewEnter = 0;
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    setTimeout(() => {
      this.getUIContext().animateTo(
        { duration: reduced ? Motion.REDUCED : Motion.SHEET, curve: Curve.EaseOut },
        () => {
          this.previewEnter = 1;
        }
      );
    }, 20);
  }

  private closePreview(): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    this.getUIContext().animateTo(
      { duration: reduced ? Motion.REDUCED : Motion.FEEDBACK, curve: Curve.EaseIn },
      () => {
        this.previewEnter = 0;
      }
    );
    setTimeout(() => {
      this.preview = null;
    }, reduced ? 120 : 200);
  }

  /** 大图浮层「再分享」 */
  private async shareRow(row: AlbumRow): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      let path: string = row.card.cardImagePath;
      if (path === '') {
        this.snapshotRow = row;
        path = await ShareService.snapshotBuilderToJpg(ctx, this.SnapshotFallback,
          `meme_album_${row.card.id}`);
      }
      const text: string = `我在词慧解锁了一个梗，已掌握 ${row.card.masteredCount} 个词！`;
      await MemeCardService.shareImage(ctx, path, text);
      DataStore.INSTANCE.bumpMemeCardShare(row.card.id);
      this.reload();
    } catch (e) {
      console.warn(`[MemeAlbum] share: ${(e as Error)?.message ?? e}`);
      this.toast('未找到分享目标，可先保存到相册');
    } finally {
      this.busy = false;
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

      Text('梗卡册')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)

      Row().width(44).height(44)
    }
    .width('100%').height(56)
  }

  /** 4:5 缩略卡：PNG 优先，缺失时同构降级卡 */
  @Builder
  Thumb(row: AlbumRow, big: boolean) {
    Stack() {
      if (row.card.cardImagePath !== '') {
        Image(`file://${row.card.cardImagePath}`)
          .width('100%').height('100%').objectFit(ImageFit.Cover).borderRadius(big ? 20 : 14)
      } else {
        this.FallbackCard(row, big)
      }
    }
    .width('100%').aspectRatio(0.8).borderRadius(big ? 20 : 14).clip(true)
  }

  @Builder
  FallbackCard(row: AlbumRow, big: boolean) {
    Stack() {
      Column() {
        Row() {
          Text('词慧 · 梗句卡').fontSize(big ? 12 : 9).fontColor('rgba(255,255,255,0.72)')
          Blank()
          Text(MemeCardService.badgeShort(row.card.badgeLevel))
            .fontSize(big ? 12 : 9).fontWeight(FontWeight.Bold)
            .fontColor(row.card.badgeLevel === 'SILVER' ? '#33415C' : Colors.WHITE)
            .height(big ? 46 : 30).padding({ left: 10, right: 10 })
            .textAlign(TextAlign.Center).borderRadius(23)
            .backgroundColor(this.badgeColor(row.card.badgeLevel))
        }.width('100%')
        Text(row.chinese)
          .fontSize(big ? 22 : 13).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
          .maxLines(2).width('100%').margin({ top: big ? 16 : 8 })
        Blank()
        Text(`已掌握 ${row.card.masteredCount}/${row.card.totalCount} 词`)
          .fontSize(big ? 19 : 11).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE).width('100%')
        Text(`解锁于 ${row.card.unlockedDay}`)
          .fontSize(big ? 12 : 9).fontColor('rgba(255,255,255,0.72)').width('100%').margin({ top: 5 })
      }
      .width('100%').height('100%').padding(big ? 20 : 10).justifyContent(FlexAlign.Start)
    }
    .width('100%').height('100%')
    .linearGradient({ angle: 135, colors: [[Colors.BRAND, 0], [Colors.BRAND_PRESSED, 1]] })
  }

  /** 离屏快照专用无参降级卡（对齐 F11 CheckInPage 传 this.XxxBuilder 的范式） */
  @Builder
  SnapshotFallback() {
    Column() {
      if (this.snapshotRow !== null) {
        this.FallbackCard(this.snapshotRow, true)
      }
    }.width(300)
  }

  @Builder
  BadgeTag(row: AlbumRow) {
    Text(MemeCardService.badgeShort(row.card.badgeLevel))
      .fontSize(10).fontWeight(FontWeight.Medium)
      .fontColor(row.card.badgeLevel === 'SILVER' ? '#33415C' : Colors.WHITE)
      .backgroundColor(this.badgeColor(row.card.badgeLevel))
      .borderRadius(8).padding({ left: 7, right: 7, top: 2, bottom: 2 })
  }

  @Builder
  RowContent(row: AlbumRow) {
    Row() {
      Column() {
        this.Thumb(row, false)
      }.width(96)

      Column() {
        Text(row.chinese)
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Row() {
          this.BadgeTag(row)
          Text(`已掌握 ${row.card.masteredCount}/${row.card.totalCount}`)
            .fontSize(12).fontColor(Colors.TEXT_SUB).margin({ left: 8 })
        }.width('100%').margin({ top: 8 })
        Text(`解锁于 ${row.card.unlockedDay}${row.card.sharedCount > 0 ? ` · 已分享 ${row.card.sharedCount} 次` : ''}`)
          .fontSize(11).fontColor(Colors.TEXT_WEAK).width('100%').margin({ top: 5 })
      }
      .layoutWeight(1).margin({ left: 12, right: 8 }).alignItems(HorizontalAlign.Start)

      Button(row.card.isFavorite ? '★' : '☆')
        .fontSize(22).fontColor(row.card.isFavorite ? '#F5C542' : Colors.TEXT_WEAK)
        .backgroundColor(Color.Transparent).width(40).height(40)
        .onClick(() => this.toggleFavorite(row))
    }
    .width('100%').padding(12).backgroundColor(Colors.WHITE)
  }

  @Builder
  DeleteAction(row: AlbumRow) {
    Button('删除')
      .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.UNKNOWN_RED)
      .width(84).height('100%').borderRadius(0)
      .onClick(() => this.askDelete(row))
  }

  @Builder
  AlbumList() {
    List({ space: 10 }) {
      ForEach(this.rows, (row: AlbumRow) => {
        ListItem() {
          this.RowContent(row)
        }
        .borderRadius(Radius.CARD)
        .onClick(() => this.openPreview(row))
        .swipeAction({
          end: {
            builder: () => {
              this.DeleteAction(row)
            },
            onAction: () => this.askDelete(row),
          }
        })
      }, (row: AlbumRow): string => row.card.id)
    }
    .width('100%').layoutWeight(1)
    .padding({ left: 16, right: 16, top: 2 })
    .scrollBar(BarState.Off)
  }

  @Builder
  EmptyView() {
    Column() {
      Blank()
      Stack() {
        Circle({ width: 96, height: 96 }).fill(Colors.BRAND_SOFT)
        Image($r('app.media.ic_meme')).width(42).height(42).fillColor(Colors.BRAND)
      }.width(120).height(120)
      Text('还没有梗卡')
        .fontSize(TypeScale.TITLE_LARGE).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .margin({ top: 18 })
      Text('从我的词本进入「梗句」背完一场，就会解锁一张梗卡')
        .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_SUB)
        .textAlign(TextAlign.Center).width('72%').margin({ top: 8 })
      Blank()
    }.width('100%').layoutWeight(1)
  }

  /** 大图浮层：点空白关闭，底部再分享 / 删除 */
  @Builder
  PreviewOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%').height('100%').backgroundColor('#B3000000')
        .onClick(() => this.closePreview())
      Column() {
        if (this.preview !== null) {
          Column() {
            this.Thumb(this.preview, true)
          }.width('76%')

          Row() {
            Button('再分享')
              .fontSize(15).fontColor(Colors.WHITE).backgroundColor(Colors.BRAND)
              .borderRadius(Radius.BUTTON).height(46).layoutWeight(1).margin({ right: 10 })
              .onClick(() => {
                if (this.preview !== null) {
                  this.shareRow(this.preview);
                }
              })
            Button('删除')
              .fontSize(15).fontColor(Colors.UNKNOWN_RED).backgroundColor(Colors.WHITE)
              .borderRadius(Radius.BUTTON).height(46).layoutWeight(1)
              .onClick(() => {
                if (this.preview !== null) {
                  const target: AlbumRow = this.preview;
                  this.closePreview();
                  setTimeout(() => this.askDelete(target), 240);
                }
              })
          }.width('76%').margin({ top: 20 })
        }
      }
      .opacity(this.previewEnter)
      .scale({ x: this.previewEnter === 1 ? 1 : 0.9, y: this.previewEnter === 1 ? 1 : 0.9 })
    }
    .width('100%').height('100%')
    .visibility(this.preview === null ? Visibility.None : Visibility.Visible)
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          this.TopBar()
          if (this.rows.length === 0) {
            this.EmptyView()
          } else {
            this.AlbumList()
          }
        }
        .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
        this.PreviewOverlay()
      }
      .width('100%').height('100%')
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
