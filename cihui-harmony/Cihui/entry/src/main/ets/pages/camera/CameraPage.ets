/**
 * F3 全屏相机页（微信相机式）：
 * 权限说明 → 运行时申请 → 取景（XComponent + CameraKit 真实会话）/ 拒绝降级；
 * 快门 scale .92 + 白闪 340ms → 定格（重拍不产生任何数据 / 已拍下）；
 * 多图连拍按顺序合并；相册走系统 PhotoViewPicker；
 * 识别卡转圈 18→62→100，对勾停 400ms 才跳 F4 校对页；识别中禁跳转；失败可重试，不产生半截数据；
 * 未检测到英文行提示重拍；拒绝权限给“去设置 / 手动录入生词”。
 */
import { common } from '@kit.AbilityKit';
import type { Permissions } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NavStore } from '../../viewmodel/NavStore';
import { Colors, Radius, Motion } from '../../common/DesignTokens';
import { RouteName, CameraRouteParam } from '../../common/RouteNames';
import type { OcrPickRouteParam, OcrReviewRouteParam } from '../../common/RouteNames';
import { PermissionUtil } from '../../service/PermissionUtil';
import { CameraSession } from '../../service/CameraSession';
import { MediaPickService } from '../../service/MediaPickService';
import { OcrService, OcrImageResult } from '../../service/OcrService';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

type CameraPhase = 'explain' | 'viewfinder' | 'denied' | 'captured' | 'recognizing' | 'failed';
const PERM_CAMERA: Permissions = 'ohos.permission.CAMERA';
const TAG: string = 'CihuiCamera';

@ComponentV2
export struct CameraPage {
  @Require @Param param: CameraRouteParam;
  @Local phase: CameraPhase = 'explain';
  /** 动态QA：页面每次重新显示时自增，强制重算仓库派生数据 */
  @Local showTick: number = 0;
  /** 动态QA：导航/数据事件总线，本页成为栈顶时强制重算（@Trace 覆盖期投递不可靠） */
  private refreshWhenTop: RefreshListener = (): void => {
    const names: string[] = NavStore.INSTANCE.stack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === RouteName.CAMERA) {
      this.showTick++;
    }
  };
  @Local sheetY: string = '100%';
  @Local sheetOpacity: number = 0;
  @Local shots: image.PixelMap[] = [];
  @Local multiMode: boolean = false;
  @Local shutterDown: boolean = false;
  @Local flashOpacity: number = 0;
  @Local busy: boolean = false;
  @Local flashLabel: string = '自动';
  @Local percent: number = 0;
  @Local recognizeText: string = '正在识别图片…';
  @Local failMessage: string = '识别失败，请重试或重拍';
  @Local cameraError: string = '';

  private xcController: XComponentController = new XComponentController();
  private session: CameraSession = new CameraSession();
  private surfaceId: string = '';
  private sessionStarted: boolean = false;
  private lastResults: OcrImageResult[] = [];

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenTop);
    REFRESH_BUS.onData(this.refreshWhenTop);
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    if (PermissionUtil.isGranted(ctx, PERM_CAMERA)) {
      this.phase = 'viewfinder';
    } else {
      this.phase = 'explain';
    }
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenTop);
    REFRESH_BUS.offData(this.refreshWhenTop);
    this.releaseCamera();
  }

  private async releaseCamera(): Promise<void> {
    this.sessionStarted = false;
    await this.session.release();
  }

  private async startCamera(): Promise<void> {
    if (this.sessionStarted || this.surfaceId.length === 0) {
      return;
    }
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    // 权限说明页（未授权）时 XComponent 已 onLoad，此时不得预启动：无权限必失败，
    // 且授权后 XComponent 不会再次 onLoad，会导致取景页相机永远起不来。未授权直接返回，
    // 授权后由 requestPermission 主动启动。
    if (!PermissionUtil.isGranted(ctx, PERM_CAMERA)) {
      return;
    }
    try {
      await this.session.start(ctx, this.surfaceId);
      this.sessionStarted = true;
      this.cameraError = '';
    } catch (err) {
      // 透出具体阶段 / 错误码（CameraSession 已分阶段打点），不白屏、不阻断相册与手动录入
      const msg: string = (err as Error)?.message ?? '相机启动失败';
      hilog.error(0x0000, TAG, 'startCamera failed: %{public}s', msg);
      this.cameraError = `${msg}，可改用相册选图或手动录入`;
    }
  }

  private async requestPermission(): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const granted: boolean = await PermissionUtil.request(ctx, PERM_CAMERA);
    if (granted) {
      this.phase = 'viewfinder';
      this.cameraError = '';
      // 授权后 XComponent 不会再次 onLoad，必须主动启动一次（surfaceId 在说明页阶段通常已就绪）
      await this.startCamera();
      if (!this.sessionStarted && this.surfaceId.length === 0) {
        // 极端情况下 surface 尚未就绪：onLoad 回调里会再走一次 startCamera（此时已授权）
        hilog.info(0x0000, TAG, 'surface not ready, will start on XComponent onLoad');
      }
    } else {
      this.phase = 'denied';
    }
  }

  private goManual(): void {
    const p: OcrReviewRouteParam = {
      results: [], manual: true, from: this.param.from, bookId: this.param.bookId
    };
    NavStore.INSTANCE.push(RouteName.OCR_REVIEW, p);
  }

  private openSettings(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    PermissionUtil.openAppSettings(ctx);
  }

  /** 快门：按压反馈 + 白闪，随后真实拍照定格 */
  private async onShutter(): Promise<void> {
    if (this.busy || this.phase === 'recognizing') {
      return;
    }
    this.busy = true;
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
      this.shutterDown = true;
    });
    if (!reduced) {
      this.flashOpacity = 0.85;
      this.getUIContext().animateTo({ duration: 340, curve: Curve.EaseOut }, () => {
        this.flashOpacity = 0;
      });
    }
    try {
      if (!this.sessionStarted) {
        // 相机不可用时不允许空拍，引导相册/手动
        await this.delay(140);
        throw new Error('camera not ready');
      }
      const pm: image.PixelMap = await this.session.capture();
      this.shots.push(pm);
      this.phase = 'captured';
    } catch (err) {
      promptAction.showToast({ message: '拍照失败，请改用相册选图或手动录入', duration: 2200 });
    } finally {
      this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
        this.shutterDown = false;
      });
      this.busy = false;
    }
  }

  /** 重拍：单图清空；多图删最后一张；均不产生任何业务数据 */
  private retake(): void {
    if (this.multiMode && this.shots.length > 1) {
      this.shots.pop();
      this.phase = 'captured';
    } else {
      this.shots = [];
      this.phase = 'viewfinder';
    }
  }

  /** 多图模式继续拍下一张 */
  private continueCapture(): void {
    this.phase = 'viewfinder';
  }

  private async pickAlbum(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const picked: image.PixelMap[] = await MediaPickService.pickPhotos(this.multiMode ? 9 : 1);
      if (picked.length === 0) {
        return;
      }
      this.shots = picked;
      await this.runRecognize(this.shots);
    } catch (err) {
      hilog.error(0x0003, 'CameraPage', 'pickAlbum failed: %{public}s', (err as Error)?.message ?? String(err));
      this.failMessage = '选图失败，请重试';
      this.phase = 'failed';
    } finally {
      this.busy = false;
    }
  }

  /** 已拍下 → 识别；识别中禁止离开本页 */
  private async confirmShots(): Promise<void> {
    if (this.shots.length === 0) {
      return;
    }
    await this.runRecognize(this.shots);
  }

  private async runRecognize(images: image.PixelMap[]): Promise<void> {
    this.percent = 0;
    this.recognizeText = '正在识别图片…';
    this.phase = 'recognizing';
    try {
      const results: OcrImageResult[] = await OcrService.recognize(images,
        (p: number, text: string): void => {
          this.percent = p;
          this.recognizeText = text;
        });
      const totalLines: number = results.reduce((sum: number, r: OcrImageResult): number => sum + r.lines.length, 0);
      if (totalLines === 0) {
        this.failMessage = '未检测到英文行，请重拍或换个角度';
        this.phase = 'failed';
        return;
      }
      this.lastResults = results;
      // 100% 对勾停留 400ms 再跳转
      await this.delay(400);
      const routeParam: OcrPickRouteParam = {
        results: results, from: this.param.from, bookId: this.param.bookId
      };
      NavStore.INSTANCE.push(RouteName.OCR_PICK, routeParam);
    } catch (err) {
      hilog.error(0x0003, 'CameraPage', 'recognize failed: %{public}s', (err as Error)?.message ?? String(err));
      this.failMessage = '识别失败，请检查网络后重试，或重拍一张';
      this.phase = 'failed';
    }
  }

  private async retryRecognize(): Promise<void> {
    if (this.shots.length > 0) {
      await this.runRecognize(this.shots);
    } else {
      this.phase = 'viewfinder';
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  @Builder
  IconClose() {
    Stack() {
      Column().width(20).height(2.5).backgroundColor(Colors.WHITE).borderRadius(2).rotate({ angle: 45 })
      Column().width(20).height(2.5).backgroundColor(Colors.WHITE).borderRadius(2).rotate({ angle: -45 })
    }.width(44).height(44).alignContent(Alignment.Center)
  }

  @Builder
  FlashIcon(on: boolean) {
    Path({ width: 22, height: 22 })
      .commands('M12 2 L5 13.5 H10.5 L9 22 L19 9.5 H13 Z')
      .fill(on ? Colors.BRAND : Colors.WHITE)
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        this.IconClose()
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())
      Blank()
      if (this.phase === 'viewfinder') {
        Button() {
          Row() {
            this.FlashIcon(this.flashLabel !== '关闭')
            Text(this.flashLabel).fontSize(12).fontColor(this.flashLabel === '关闭' ? Colors.WHITE : Colors.BRAND)
              .margin({ left: 4 })
          }.padding({ left: 10, right: 12 }).height(34)
          .backgroundColor('#99000000').borderRadius(17)
        }
        .type(ButtonType.Normal).height(44).backgroundColor(Color.Transparent)
        .onClick(() => {
          const labels: string[] = ['自动', '补光', '关闭'];
          const ok: boolean = this.session.toggleFlash();
          if (ok) {
            const idx: number = labels.indexOf(this.flashLabel);
            this.flashLabel = labels[(idx + 1) % labels.length];
          } else {
            promptAction.showToast({ message: '当前设备不支持闪光灯', duration: 1800 });
          }
        })
      }
    }
    .width('100%')
    .padding({ left: 8, right: 16 })
    .safeAreaPadding({ top: 12 })
  }

  @Builder
  CapturedTopBar() {
    Row() {
      Button('重拍')
        .fontSize(15).fontColor(Colors.WHITE).height(44).padding({ left: 12, right: 12 })
        .type(ButtonType.Normal).backgroundColor(Color.Transparent)
        .onClick(() => this.retake())
      Blank()
      Button('已拍下')
        .fontSize(15).fontColor(Colors.WHITE).height(44).padding({ left: 12, right: 12 })
        .type(ButtonType.Normal).backgroundColor(Color.Transparent)
        .onClick(() => this.confirmShots())
    }
    .width('100%')
    .padding({ left: 8, right: 8 })
    .safeAreaPadding({ top: 12 })
  }

  @Builder
  ShutterButton() {
    Stack() {
      Circle({ width: 72, height: 72 }).fill(Color.Transparent).stroke(Colors.WHITE).strokeWidth(4)
      Circle({ width: this.shutterDown ? 52 : 58, height: this.shutterDown ? 52 : 58 }).fill(Colors.WHITE)
    }
    .width(80).height(80).alignContent(Alignment.Center)
    .onClick(() => this.onShutter())
  }

  @Builder
  AlbumEntry() {
    Column() {
      Stack() {
        Path({ width: 26, height: 26 })
          .commands('M4 7 H9 L11 5 H20 V20 H4 Z')
          .fill(Colors.WHITE)
      }.width(44).height(44).alignContent(Alignment.Center)
      Text('相册').fontSize(12).fontColor(Colors.WHITE).margin({ top: 2 })
    }
    .width(72).onClick(() => this.pickAlbum())
  }

  @Builder
  MultiEntry() {
    Column() {
      Stack() {
        Path({ width: 26, height: 26 })
          .commands('M4 8 H16 V20 H4 Z M8 8 V6 H20 V18 H16')
          .fill(this.multiMode ? Colors.BRAND : Colors.WHITE)
      }.width(44).height(44).alignContent(Alignment.Center)
      Text(this.multiMode ? `多图 ${this.shots.length > 0 ? this.shots.length : ''}` : '多图')
        .fontSize(12).fontColor(this.multiMode ? Colors.BRAND : Colors.WHITE).margin({ top: 2 })
    }
    .width(72).onClick(() => {
      this.multiMode = !this.multiMode;
    })
  }

  @Builder
  ViewfinderBottom() {
    Row() {
      this.AlbumEntry()
      Blank()
      this.ShutterButton()
      Blank()
      this.MultiEntry()
    }
    .width('100%')
    .padding({ left: 24, right: 24, bottom: 24 })
    .safeAreaPadding({ bottom: 12 })
  }

  @Builder
  CapturedBottom() {
    Column() {
      if (this.multiMode && this.shots.length > 0) {
        ScrollableImageStrip({ shots: this.shots })
      }
      Row() {
        Button('重拍')
          .fontSize(15).fontColor(Colors.WHITE).height(40)
          .padding({ left: 18, right: 18 }).type(ButtonType.Normal)
          .backgroundColor('#66000000').borderRadius(20)
          .onClick(() => this.retake())
        Blank()
        if (this.multiMode) {
          Button('继续拍摄')
            .fontSize(15).fontColor(Colors.WHITE).height(40)
            .padding({ left: 18, right: 18 }).type(ButtonType.Normal)
            .backgroundColor('#66000000').borderRadius(20)
            .margin({ right: 12 })
            .onClick(() => this.continueCapture())
        }
        Button(this.multiMode ? `已拍下(${this.shots.length})` : '识别导入')
          .fontSize(15).fontColor(Colors.WHITE).height(40)
          .padding({ left: 20, right: 20 }).type(ButtonType.Normal)
          .backgroundColor(Colors.BRAND).borderRadius(20)
          .onClick(() => this.confirmShots())
      }.width('100%').margin({ top: 10 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, bottom: 24 })
    .safeAreaPadding({ bottom: 12 })
  }

  @Builder
  PermissionCard(title: string, desc: string, primary: string, showSettings: boolean) {
    Column() {
      Text(title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
      Text(desc)
        .fontSize(14).fontColor('#CCFFFFFF').lineHeight(22).textAlign(TextAlign.Center)
        .margin({ top: 12, bottom: 28 }).padding({ left: 12, right: 12 })
      Button(primary)
        .width(220).height(46).borderRadius(23).backgroundColor(Colors.BRAND).fontColor(Colors.WHITE)
        .onClick(() => {
          if (showSettings) {
            this.openSettings();
          } else {
            this.requestPermission();
          }
        })
      Button('手动录入生词')
        .width(220).height(44).fontSize(14).fontColor(Colors.WHITE)
        .type(ButtonType.Normal).backgroundColor(Color.Transparent)
        .margin({ top: 8 })
        .onClick(() => this.goManual())
      if (showSettings) {
        Text('授权后返回本页将自动进入取景').fontSize(12).fontColor('#80FFFFFF').margin({ top: 10 })
      }
    }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 160, left: 28, right: 28 })
  }

  @Builder
  RecognizingCard() {
    Column() {
      if (this.percent >= 100) {
        Stack() {
          Circle({ width: 56, height: 56 }).fill(Colors.KNOW_GREEN)
          Path({ width: 30, height: 30 }).commands('M8 15 L13 20 L22 10')
            .stroke(Colors.WHITE).strokeWidth(3).fill(Color.Transparent).strokeLineCap(LineCapStyle.Round)
        }
      } else {
        LoadingProgress().width(48).height(48).color(Colors.BRAND)
      }
      Text(this.percent >= 100 ? '识别完成' : `${this.percent}%`)
        .fontSize(18).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN).margin({ top: 14 })
      Text(this.recognizeText).fontSize(13).fontColor(Colors.TEXT_SUB).margin({ top: 6 })
    }
    .width(200).padding({ top: 28, bottom: 28, left: 16, right: 16 })
    .backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  FailedCard() {
    Column() {
      Text('识别未成功').fontSize(18).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
      Text(this.failMessage).fontSize(13).fontColor(Colors.TEXT_SUB).textAlign(TextAlign.Center)
        .margin({ top: 10, bottom: 22 }).padding({ left: 8, right: 8 })
      Button('重试识别')
        .width(220).height(44).borderRadius(22).backgroundColor(Colors.BRAND).fontColor(Colors.WHITE)
        .onClick(() => this.retryRecognize())
      Button('重拍')
        .width(220).height(42).fontSize(14).fontColor(Colors.TEXT_MAIN)
        .type(ButtonType.Normal).backgroundColor(Color.Transparent)
        .onClick(() => {
          this.shots = [];
          this.phase = 'viewfinder';
        })
      Button('取消')
        .width(220).height(42).fontSize(14).fontColor(Colors.TEXT_WEAK)
        .type(ButtonType.Normal).backgroundColor(Color.Transparent)
        .onClick(() => NavStore.INSTANCE.back())
    }
    .width(280).padding(24).backgroundColor(Colors.WHITE).borderRadius(Radius.CARD)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        // 取景层
        if (this.phase === 'viewfinder' || this.phase === 'explain' || this.phase === 'denied') {
          XComponent({ id: 'cihui_camera_preview', type: XComponentType.SURFACE, controller: this.xcController })
            .onLoad(() => {
              this.surfaceId = this.xcController.getXComponentSurfaceId();
              this.startCamera();
            })
            .width('100%').height('100%').backgroundColor(Color.Black)
          if (this.cameraError.length > 0 && this.phase === 'viewfinder') {
            Column() {
              Text(this.cameraError)
                .fontSize(13).fontColor('#CCFFFFFF').textAlign(TextAlign.Center)
                .padding({ left: 24, right: 24 })
              // P9：模拟器/无相机设备时，相册选图是「模拟拍照」的主路径，给显眼入口
              Button('相册选图识别')
                .width(200).height(42).fontSize(14).fontColor(Colors.WHITE)
                .backgroundColor(Colors.BRAND).borderRadius(21).margin({ top: 18 })
                .onClick(() => this.pickAlbum())
              // 动态QA：无相机设备时错误文案承诺了“手动录入”，给出真实入口，避免断头路
              Button('手动录入生词')
                .width(200).height(42).fontSize(14).fontColor(Colors.WHITE)
                .type(ButtonType.Normal).backgroundColor('#66000000').borderRadius(21)
                .margin({ top: 10 })
                .onClick(() => this.goManual())
            }
            .width('100%').margin({ top: 160 }).alignItems(HorizontalAlign.Center)
          }
        }
        // 定格层
        if ((this.phase === 'captured' || this.phase === 'recognizing' || this.phase === 'failed')
          && this.shots.length > 0) {
          Image(this.shots[this.shots.length - 1])
            .width('100%').height('100%').objectFit(ImageFit.Contain).backgroundColor(Color.Black)
        }
        // 渐变遮罩，保证控件可读
        Column()
          .width('100%').height(140).linearGradient({
            angle: 180,
            colors: [['#80000000', 0], ['#00000000', 1]]
          })
        Column()
          .width('100%').height(180).linearGradient({
            angle: 0,
            colors: [['#00000000', 0], ['#80000000', 1]]
          })
          .position({ x: 0, y: '100%' }).markAnchor({ y: '100%' })

        // 顶部与底部
        Column() {
          if (this.phase === 'captured' || this.phase === 'recognizing' || this.phase === 'failed') {
            this.CapturedTopBar()
          } else {
            this.TopBar()
          }
          Blank()
          if (this.phase === 'viewfinder') {
            this.ViewfinderBottom()
          } else if (this.phase === 'captured') {
            this.CapturedBottom()
          }
        }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)

        // 权限说明 / 拒绝降级
        if (this.phase === 'explain') {
          this.PermissionCard('拍照导入词表',
            '拍摄纸质词表后自动识别英文单词与中文释义，识别结果经你校对确认后才会导入。',
            '启用相机', false)
        }
        if (this.phase === 'denied') {
          this.PermissionCard('需要相机权限',
            '相机权限被拒绝，无法拍照识别。可在系统设置中开启，或先手动录入生词。',
            '去设置开启', true)
        }
        // 识别中卡片
        if (this.phase === 'recognizing') {
          Column() {
            this.RecognizingCard()
          }.width('100%').height('100%').backgroundColor('#66000000').justifyContent(FlexAlign.Center)
        }
        // 失败卡片
        if (this.phase === 'failed') {
          Column() {
            this.FailedCard()
          }.width('100%').height('100%').backgroundColor('#66000000').justifyContent(FlexAlign.Center)
        }
        // 白闪
        Column().width('100%').height('100%').backgroundColor(Color.White).opacity(this.flashOpacity)
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%').height('100%').backgroundColor(Color.Black)
    }
    .hideTitleBar(true)
    .translate({ y: this.sheetY })
    .opacity(this.sheetOpacity + this.showTick * 0)
    .onShown(() => {
      this.showTick++;
      // F4 导入成功：校对页已返回，相机页再退一层，全部二级页关闭回来源页
      if (NavStore.INSTANCE.importDone) {
        NavStore.INSTANCE.importDone = false;
        // 动态 QA：回一级 Tab 整页重挂载，避免落到冻结的旧页面
        // 加入当天计划 → 回首页（今日任务里要能看见这批词）；否则回我的词本
        NavStore.INSTANCE.backToTab(NavStore.INSTANCE.importDoneTab);
        return;
      }
      if (this.phase === 'recognizing' || this.phase === 'failed') {
        // 从校对页手动返回：回到定格态，可重拍或重新识别
        this.phase = this.shots.length > 0 ? 'captured' : 'viewfinder';
      }
      if (this.phase === 'denied') {
        // 从系统设置打开相机权限后返回：复查授权，已授予则切回取景并启动
        const ctx0: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
        if (PermissionUtil.isGranted(ctx0, PERM_CAMERA)) {
          this.phase = 'viewfinder';
          this.cameraError = '';
          this.startCamera();
        }
      }
      if (this.phase === 'viewfinder') {
        this.startCamera();
      }
    })
    .onHidden(() => this.releaseCamera())
    .customTransition((operation: NavigationOperation, isEnter: boolean): NavDestinationTransition[] | undefined => {
      // 全屏相机自底部升起 280ms；减弱动效降级 240ms 淡入淡出
      const reduced: boolean = NavStore.INSTANCE.reducedMotion;
      return [{
        duration: reduced ? Motion.REDUCED : Motion.SHEET,
        curve: Curve.EaseOut,
        event: () => {
          if (reduced) {
            this.sheetY = '0%';
            this.sheetOpacity = isEnter ? 1 : 0;
            return;
          }
          if (operation === NavigationOperation.PUSH && isEnter) {
            this.sheetY = '0%';
            this.sheetOpacity = 1;
          } else if (operation === NavigationOperation.POP && !isEnter) {
            this.sheetY = '100%';
            this.sheetOpacity = 0;
          }
        }
      }];
    })
  }
}

/** 多图连拍缩略图条 */
@ComponentV2
struct ScrollableImageStrip {
  @Require @Param shots: image.PixelMap[];

  build() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.shots, (pm: image.PixelMap, idx: number) => {
          Image(pm).width(48).height(48).borderRadius(8).objectFit(ImageFit.Cover)
            .border({ width: idx === this.shots.length - 1 ? 2 : 0, color: Colors.BRAND })
        }, (pm: image.PixelMap, idx: number) => `${idx}`)
      }.padding({ left: 2, right: 2 })
    }
    .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
    .width('100%').height(52)
  }
}
