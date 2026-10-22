/**
 * 首页 Home（F6）——今日任务中枢：先新词、后复习、再打卡。
 * 所有数字（六桶、进度环、错词角标、连续天数）全部来自 F2 调度器同源计算，
 * 页面本身不做任何排期/统计口径。
 * F7 新词首学 / F9 复习闪卡 / F10 错词本已接通；F12 计划大表/补卡/果冻日历已接通。
 */
import { promptAction } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';
import { Colors, TypeScale, Radius, Motion, FloatingTab } from '../../common/DesignTokens';
import { RouteName } from '../../common/RouteNames';
import { NavStore } from '../../viewmodel/NavStore';
import { DataStore } from '../../viewmodel/DataStore';
import { AuthStore } from '../../viewmodel/AuthStore';
import { dayKeyFromTs, type HomeStats } from '../../model/SchedulerCore';
import type { Word, StudySession } from '../../model/Types';
import type { CameraRouteParam, MemeReviewRouteParam, ReviewRouteParam } from '../../common/RouteNames';
import { openTodayNewWords, entryLabel, taskSubLabel as studySubLabel } from '../../viewmodel/StudyEntry';
import { MIN_WORDS_FOR_SENTENCE } from '../../model/SentenceCore';
import { REFRESH_BUS, RefreshListener } from '../../common/RefreshBus';

/** 六桶视图模型（今日新词 + R1/R2/R4/R7/R15） */
class BucketItem {
  key: string;
  label: string;
  count: number;

  constructor(key: string, label: string, count: number) {
    this.key = key;
    this.label = label;
    this.count = count;
  }
}

@ComponentV2
export struct HomePage {
  @Param active: boolean = false;
  /** 导航版本号：从二级页返回时强制重算六桶/问候语等派生数据（动态QA BUG-02） */
  @Param tick: number = 0;
  @Local refreshing: boolean = false;
  /** 六桶 stagger 入场开关（减弱动效时直接显现） */
  @Local bucketsShown: boolean = false;
  /** F20 趣味学习区入场开关（排在快捷入口之后 stagger） */
  @Local funShown: boolean = false;
  /** F20 两个入口的按压缩放态 */
  @Local pressedMeme: boolean = false;
  @Local pressedSentence: boolean = false;
  /** F20 例句入口一次性蓝色脉冲缩放（只在置灰→可用瞬间播一次） */
  @Local sentencePulse: number = 1;
  /** F20 续背蓝点淡入透明度 */
  @Local memeDotOpacity: number = 0;
  /** 动态QA：显式刷新版本号，导航/数据事件到达且本 Tab 可见时自增强制重绘（BUG-02） */
  @Local viewTick: number = 0;
  /** 今日新词主按钮文案与副标题（刷新点算一次并缓存，构建期不读文件） */
  @Local entryLabelText: string = '';
  @Local studySubText: string = '';
  /** 上一次例句是否已解锁、蓝点是否已出现，用于捕捉"状态翻转瞬间" */
  private lastSentenceReady: boolean = false;
  private lastMemeInProgress: boolean = false;
  private scroller: Scroller = new Scroller();
  private refreshWhenActive: RefreshListener = (): void => {
    if (this.active) {
      this.viewTick++;
      this.syncFunStates(false);
      this.syncResume();
    }
  };

  /** 刷新今日学习会话文案：只在 Tab 可见/数据变化时读一次会话文件 */
  private syncResume(): void {
    this.entryLabelText = entryLabel();
    this.studySubText = studySubLabel();
  }

  /** 今日任务主卡副标题 */
  private taskSubLabel(): string {
    const s: HomeStats = this.stats();
    if (!s.hasWords) {
      return '还没有要背的单词';
    }
    if (s.newAssigned - s.newDone > 0 && this.studySubText.length > 0) {
      return this.studySubText;
    }
    return `还剩 ${s.remaining} 个词 · 预计约 ${Math.max(1, Math.ceil(s.remaining * 12 / 60))} 分钟`;
  }

  /** 今日新词主按钮文案（会话文案优先，缺省回落到剩余词数） */
  private mainCta(s: HomeStats): string {
    if (this.entryLabelText.length > 0 && this.entryLabelText !== '开始今日学习') {
      return this.entryLabelText;
    }
    return `开始今日学习（剩 ${Math.max(0, s.newAssigned - s.newDone)} 个新词）`;
  }

  @Monitor('active')
  onActiveChange(): void {
    if (this.active) {
      this.viewTick++;
      // 从其他 Tab/二级页回到首页时，捕捉例句解锁、续背会话出现的状态翻转
      this.syncFunStates(false);
      this.syncResume();
    }
  }

  aboutToAppear(): void {
    REFRESH_BUS.onNav(this.refreshWhenActive);
    REFRESH_BUS.onData(this.refreshWhenActive);
    this.syncResume();
    // 首次进入只记录初始状态，不播"解锁脉冲/蓝点淡入"（脉冲只属于状态翻转瞬间）
    this.lastSentenceReady = this.sentenceReady();
    this.lastMemeInProgress = DataStore.INSTANCE.hasMemeInProgress();
    this.memeDotOpacity = this.lastMemeInProgress ? 1 : 0;
    setTimeout(() => {
      this.bucketsShown = true;
    }, 90);
    setTimeout(() => {
      this.funShown = true;
    }, 160);
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.refreshWhenActive);
    REFRESH_BUS.offData(this.refreshWhenActive);
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 1800 });
    } catch (e) {
      // 忽略 Toast 异常
    }
  }

  private stats(): HomeStats {
    return DataStore.INSTANCE.homeStats();
  }

  private greeting(): string {
    const h: number = new Date().getHours();
    let base: string;
    if (h < 5) {
      base = '夜深了';
    } else if (h < 11) {
      base = '早上好';
    } else if (h < 14) {
      base = '中午好';
    } else if (h < 18) {
      base = '下午好';
    } else {
      base = '晚上好';
    }
    // F14：登录后问候语与账号昵称同步，未登录显「同学」
    const p = AuthStore.INSTANCE.profile;
    if (p !== null && p.name !== '') {
      return `${base}，${p.name}`;
    }
    return `${base}，同学`;
  }

  /** 下拉刷新：本期只重算本地数据并轻震动；云同步 F15 接入 */
  private onPullRefresh(): void {
    this.refreshing = true;
    setTimeout(() => {
      this.refreshing = false;
      try {
        vibrator.startVibration({ type: 'preset', effectId: 'haptic.clock.timer', count: 1 },
          { id: 0, usage: 'unknown' });
      } catch (e) {
        // 设备不支持震动时静默
      }
      this.toast('本地数据已刷新，云同步将在后续版本接入');
    }, 320);
  }

  private bucketItems(s: HomeStats): BucketItem[] {
    const items: BucketItem[] = [
      new BucketItem('NEW', '新词', s.bucketCounts['NEW']),
      new BucketItem('R1', 'R1', s.bucketCounts['R1']),
      new BucketItem('R2', 'R2', s.bucketCounts['R2']),
      new BucketItem('R4', 'R4', s.bucketCounts['R4']),
      new BucketItem('R7', 'R7', s.bucketCounts['R7']),
      new BucketItem('R15', 'R15', s.bucketCounts['R15']),
    ];
    return items;
  }

  private tapBucket(item: BucketItem): void {
    if (item.key === 'NEW') {
      if (item.count > 0) {
        openTodayNewWords();
      } else {
        this.toast('今天没有新词任务');
      }
      return;
    }
    if (item.count > 0) {
      this.openReview();
    } else {
      this.toast(`${item.label} 今天没有到期单词`);
    }
  }

  /** F9 进入到期复习闪卡（五桶到期词整轮，与打卡 P2 同源） */
  private openReview(): void {
    const words = DataStore.INSTANCE.todayReviewWordList();
    if (words.length === 0) {
      this.toast('今天没有到期复习词');
      return;
    }
    const ids: string[] = words.map((w: Word): string => w.id);
    const param: ReviewRouteParam = { wordIds: ids, title: '到期复习', mode: 'REVIEW' };
    NavStore.INSTANCE.push(RouteName.REVIEW_CARDS, param);
  }

  private openCamera(): void {
    const param: CameraRouteParam = { from: 'home' };
    NavStore.INSTANCE.push(RouteName.CAMERA, param);
  }

  /** 主按钮三态：未导入→拍照；新词未完→开始学习；新词完→去复习；全完→去打卡 */
  @Builder
  MainButton(s: HomeStats, checkedIn: boolean) {
    if (!s.hasWords) {
      Button('拍照导入词表')
        .width('100%').height(46).borderRadius(Radius.BUTTON)
        .backgroundColor(Colors.WHITE).fontColor(Colors.BRAND)
        .fontSize(16).fontWeight(FontWeight.Medium)
        .onClick(() => this.openCamera());
    } else if (checkedIn && s.remaining === 0) {
      Button('今日已打卡，明天见')
        .width('100%').height(46).borderRadius(Radius.BUTTON)
        .backgroundColor(Colors.WHITE).fontColor(Colors.KNOW_GREEN)
        .fontSize(16).fontWeight(FontWeight.Medium)
        .onClick(() => this.toast('今天的任务已完成，好好休息'));
    } else if (s.allDone) {
      Button('今日已完成，去打卡')
        .width('100%').height(46).borderRadius(Radius.BUTTON)
        .backgroundColor(Colors.KNOW_GREEN).fontColor(Colors.WHITE)
        .fontSize(16).fontWeight(FontWeight.Medium)
        .onClick(() => NavStore.INSTANCE.goTab(1));
    } else if (s.newAssigned - s.newDone > 0) {
      Button(this.mainCta(s))
        .width('100%').height(46).borderRadius(Radius.BUTTON)
        .backgroundColor(Colors.WHITE).fontColor(Colors.BRAND)
        .fontSize(16).fontWeight(FontWeight.Medium)
        .onClick(() => openTodayNewWords());
    } else {
      Button(`去复习（剩 ${s.reviewDue} 个）`)
        .width('100%').height(46).borderRadius(Radius.BUTTON)
        .backgroundColor(Colors.WHITE).fontColor(Colors.BRAND)
        .fontSize(16).fontWeight(FontWeight.Medium)
        .onClick(() => this.openReview());
    }
  }

  @Builder
  BucketCard(item: BucketItem, index: number) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Text(item.label)
          .fontSize(item.key === 'NEW' ? 12 : 15)
          .fontColor(item.count > 0 ? Colors.TEXT_MAIN : Colors.TEXT_WEAK)
          .fontWeight(item.key === 'NEW' ? FontWeight.Regular : FontWeight.Bold)
        if (item.count > 0) {
          Text(item.count.toString())
            .fontSize(11).fontColor(Colors.WHITE)
            .textAlign(TextAlign.Center)
            .minFontSize(9)
            .width(20).height(20).borderRadius(10)
            .backgroundColor(item.key === 'NEW' ? Colors.BRAND : Colors.FUZZY_ORANGE)
            .position({ x: 34, y: -8 });
        }
      }
      .width(50).height(50).borderRadius(14)
      .backgroundColor(item.count > 0 ? Colors.BRAND_SOFT : Colors.WHITE)
      .border({ width: 1, color: item.count > 0 ? Colors.BRAND_SOFT : Colors.DIVIDER })

      Text(item.count > 0 ? `${item.count} 词` : '无到期')
        .fontSize(11).fontColor(Colors.TEXT_WEAK).margin({ top: 6 })
    }
    .width('16.6%')
    .opacity(this.bucketsShown ? 1 : 0)
    .translate({ y: this.bucketsShown ? 0 : 14 })
    .animation({
      duration: NavStore.INSTANCE.reducedMotion ? 0 : 260,
      delay: NavStore.INSTANCE.reducedMotion ? 0 : index * 50,
      curve: Curve.EaseOut,
    })
    .onClick(() => this.tapBucket(item));
  }

  private tapQuickEntry(kind: string): void {
    if (kind === 'camera') {
      this.openCamera();
    } else if (kind === 'books') {
      NavStore.INSTANCE.push(RouteName.MY_BOOKS);
    } else {
      // F10 错词本：无论是否有错词都可进入（空态有鼓励引导）
      NavStore.INSTANCE.push(RouteName.WRONG_BOOK);
    }
  }

  /* ===================== F20 趣味学习 ===================== */

  /** 今日已学新词 + 今日已复习词数量（口径与 F19 今日例句页完全一致） */
  private todayWordCount(): number {
    return DataStore.INSTANCE.todayWords(dayKeyFromTs(Date.now())).length;
  }

  /** 今日词达到 F19 门槛才解锁例句入口 */
  private sentenceReady(): boolean {
    return this.todayWordCount() >= MIN_WORDS_FOR_SENTENCE;
  }

  private memeSubtitle(): string {
    const session: StudySession | null = DataStore.INSTANCE.resumableSession();
    if (session !== null) {
      const left: number = DataStore.INSTANCE.memePendingCount(session.memeId);
      return `上次还差 ${left} 个词，继续`;
    }
    return '用喜欢的句子背单词';
  }

  private sentenceSubtitle(): string {
    const n: number = this.todayWordCount();
    if (n >= MIN_WORDS_FOR_SENTENCE) {
      return '用今天背的词造句';
    }
    return `再背 ${MIN_WORDS_FOR_SENTENCE - n} 个解锁例句`;
  }

  /**
   * 数据/导航变化时同步趣味区状态：
   * - 例句从置灰翻转为可用：一次性 300ms 蓝色脉冲（1→1.06→1，不循环）；
   * - 出现进行中的梗句会话：蓝点 200ms 淡入。
   * initial=true 时只落最终态不播动画（首帧）。
   */
  private syncFunStates(initial: boolean): void {
    const reduced: boolean = NavStore.INSTANCE.reducedMotion;
    const readyNow: boolean = this.sentenceReady();
    const memeNow: boolean = DataStore.INSTANCE.hasMemeInProgress();

    if (!initial && !this.lastSentenceReady && readyNow && !reduced) {
      this.playSentencePulse();
    }
    if (!initial && !this.lastMemeInProgress && memeNow) {
      this.getUIContext().animateTo({ duration: Motion.SHEET, curve: Curve.EaseOut }, () => {
        this.memeDotOpacity = 1;
      });
    } else if (!memeNow) {
      this.memeDotOpacity = 0;
    } else if (initial) {
      this.memeDotOpacity = 1;
    }

    this.lastSentenceReady = readyNow;
    this.lastMemeInProgress = memeNow;
  }

  private playSentencePulse(): void {
    this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
      this.sentencePulse = 1.06;
    });
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: Motion.FEEDBACK, curve: Curve.EaseOut }, () => {
        this.sentencePulse = 1;
      });
    }, 160);
  }

  private tapMemeEntry(): void {
    const session: StudySession | null = DataStore.INSTANCE.resumableSession();
    if (session !== null) {
      // 续背：直接进入上一场未完成会话
      const param: MemeReviewRouteParam = { memeId: session.memeId, sessionId: session.id };
      NavStore.INSTANCE.push(RouteName.MEME_REVIEW, param);
    } else {
      NavStore.INSTANCE.push(RouteName.MEME_IMPORT);
    }
  }

  private tapSentenceEntry(): void {
    if (this.sentenceReady()) {
      NavStore.INSTANCE.push(RouteName.TODAY_SENTENCE);
    } else {
      this.toast(`再背 ${MIN_WORDS_FOR_SENTENCE - this.todayWordCount()} 个今天的词就能生成例句`);
    }
  }

  @Builder
  FunEntry(icon: Resource, title: string, subtitle: string, enabled: boolean,
           isMeme: boolean, pressed: boolean) {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Column() {
          Image(icon)
            .width(26).height(26)
            .fillColor(enabled ? Colors.BRAND : Colors.TEXT_WEAK)
            .scale({
              x: isMeme ? 1 : this.sentencePulse,
              y: isMeme ? 1 : this.sentencePulse
            })
        }
        .width(46).height(46).borderRadius(15)
        .backgroundColor(enabled ? Colors.BRAND_SOFT : Colors.PAGE_BG)
        .justifyContent(FlexAlign.Center)

        if (isMeme) {
          Circle({ width: 9, height: 9 })
            .fill(Colors.BRAND)
            .stroke(Colors.WHITE).strokeWidth(1.5)
            .position({ x: 33, y: -2 })
            .opacity(this.memeDotOpacity)
        }
      }
      .width(46).height(46)

      Text(title)
        .fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(enabled ? Colors.TEXT_MAIN : Colors.TEXT_WEAK)
        .margin({ top: 8 })
      Text(subtitle)
        .fontSize(12).fontColor(enabled ? Colors.TEXT_SUB : Colors.TEXT_WEAK)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
    }
    .layoutWeight(1).height('100%').justifyContent(FlexAlign.Center)
    .opacity(enabled ? 1 : 0.62)
    .scale({ x: pressed ? 0.97 : 1, y: pressed ? 0.97 : 1 })
    .animation({ duration: Motion.MICRO, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        if (isMeme) {
          this.pressedMeme = true;
        } else {
          this.pressedSentence = true;
        }
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedMeme = false;
        this.pressedSentence = false;
      }
    })
    .onClick(() => {
      if (isMeme) {
        this.tapMemeEntry();
      } else {
        this.tapSentenceEntry();
      }
    });
  }

  @Builder
  FunSection() {
    Column() {
      Text('趣味学习').fontSize(15).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
        .width('100%').margin({ bottom: 12 })
      Row() {
        this.FunEntry($r('app.media.ic_meme'), '梗句背单词', this.memeSubtitle(), true, true, this.pressedMeme)
        // 两入口中间 1px 竖向分隔
        Column().width(1).height(46).backgroundColor(Colors.DIVIDER)
        this.FunEntry($r('app.media.ic_sentence'), '今日例句', this.sentenceSubtitle(),
          this.sentenceReady(), false, this.pressedSentence)
      }
      .width('100%').height(96)
    }
    .width('92%').margin({ top: 12 }).padding(16)
    .borderRadius(Radius.CARD).backgroundColor(Colors.WHITE)
    .opacity(this.funShown ? 1 : 0)
    .translate({ y: this.funShown ? 0 : 14 })
    .animation({
      duration: NavStore.INSTANCE.reducedMotion ? 0 : 260,
      curve: Curve.EaseOut,
    })
  }

  /**
   * 快捷入口（渐变玻璃风格）
   * grad: 两段式渐变色 [亮, 深]；glow: 带透明度的同色系投影（ARGB）
   * 字形统一染白，顶部叠加白色高光层模拟玻璃质感
   */
  @Builder
  QuickEntry(icon: Resource, grad: string[], glow: string, label: string, badge: number, kind: string) {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Stack({ alignContent: Alignment.Center }) {
          // 渐变底层
          Column() {
          }
          .width('100%').height('100%')
          .borderRadius(16)
          .linearGradient({ angle: 150, colors: [[grad[0], 0], [grad[1], 1]] })
          .shadow({ radius: 14, color: glow, offsetX: 0, offsetY: 6 })
          // 顶部白色高光层（玻璃质感）
          Column() {
          }
          .width('100%').height('100%')
          .borderRadius(16)
          .linearGradient({
            angle: 180,
            colors: [['#3DFFFFFF', 0], ['#00FFFFFF', 0.5], ['#00FFFFFF', 1]]
          })
          // 白色字形
          Image(icon).width(24).height(24).fillColor(Colors.WHITE)
        }
        .width(48).height(48)

        if (badge > 0) {
          Text(badge > 99 ? '99+' : badge.toString())
            .fontSize(10).fontColor(Colors.WHITE).textAlign(TextAlign.Center)
            .constraintSize({ minWidth: 18 }).height(18).borderRadius(9)
            .padding({ left: 4, right: 4 })
            .backgroundColor(Colors.UNKNOWN_RED)
            .border({ width: 1.5, color: Colors.WHITE })
            .position({ x: 10, y: -8 });
        }
      }
      .width(48).height(48)

      Text(label).fontSize(12).fontColor(Colors.TEXT_SUB).margin({ top: 8 })
    }
    .layoutWeight(1)
    .onClick(() => this.tapQuickEntry(kind));
  }

  build() {
    Refresh({ refreshing: this.refreshing }) {
      Scroll(this.scroller) {
        Column() {
          // ===== 问候语 + 连续天数 chip =====
          Row() {
            Column() {
              Text(this.greeting())
                .fontSize(TypeScale.TITLE_LARGE).fontWeight(FontWeight.Bold)
                .fontColor(Colors.TEXT_MAIN)
              Text('今天也要把单词过一遍')
                .fontSize(TypeScale.CAPTION).fontColor(Colors.TEXT_WEAK)
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)

            Row() {
              Image($r('app.media.ic_flame')).width(16).height(16).fillColor(Colors.FUZZY_ORANGE)
              Text(`连续 ${DataStore.INSTANCE.streak()} 天`)
                .fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor(Colors.TEXT_MAIN).margin({ left: 4 })
            }
            .height(34).padding({ left: 12, right: 12 }).borderRadius(17)
            .backgroundColor(Colors.WHITE)
            .gesture(SwipeGesture({ direction: SwipeDirection.Horizontal })
              .onAction((event: GestureEvent) => {
                if (event.angle >= 90 && event.angle <= 270) {
                  NavStore.INSTANCE.push(RouteName.PLAN_TABLE);
                }
              }))
            .onClick(() => NavStore.INSTANCE.push(RouteName.PLAN_TABLE))
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 14, bottom: 12 })

          // ===== 蓝色今日任务主卡 =====
          Column() {
            Row() {
              Column() {
                Text('今日任务').fontSize(18).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
                Text(this.taskSubLabel())
                  .fontSize(12).fontColor('#D6E3FF').margin({ top: 6 })
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1)

              Stack({ alignContent: Alignment.Center }) {
                Progress({ value: Math.round(this.stats().progress * 100), total: 100, type: ProgressType.Ring })
                  .width(64).height(64).color(Colors.WHITE)
                  .style({ strokeWidth: 6 })
                  .backgroundColor('#3D74FA')
                  .animation({ duration: Motion.PAGE, curve: Curve.EaseOut })
                Text(`${Math.round(this.stats().progress * 100)}%`)
                  .fontSize(14).fontWeight(FontWeight.Bold).fontColor(Colors.WHITE)
              }
              .width(64).height(64)
            }
            .width('100%')

            Row() {
              Text(`新词 ${this.stats().newDone}/${this.stats().newAssigned} · 复习 ${this.stats().reviewDone}/${this.stats().reviewDue + this.stats().reviewDone}`)
                .fontSize(12).fontColor('#D6E3FF')
            }
            .width('100%').margin({ top: 10, bottom: 12 })

            this.MainButton(this.stats(), DataStore.INSTANCE.isCheckedInToday())
          }
          .width('92%')
          .padding(18)
          .borderRadius(Radius.CARD)
          .backgroundColor(Colors.BRAND)
          .shadow({ radius: 16, color: '#2E0A59F7', offsetX: 0, offsetY: 8 })

          // ===== 首日引导 =====
          if (!this.stats().hasWords) {
            Column() {
              Text('第一次使用：拍一张你的词表 / 课本单词页，识别校对后就会自动排好今天和未来的复习计划。')
                .fontSize(13).fontColor(Colors.TEXT_SUB).lineHeight(20)
            }
            .width('92%').margin({ top: 12 }).padding(14)
            .borderRadius(Radius.BUTTON).backgroundColor(Colors.BRAND_SOFT)
          }

          // ===== 逾期积压条 =====
          if (this.stats().overdueCount > 0) {
            Row() {
              Text(`你有 ${this.stats().overdueCount} 个逾期未复习的单词，点此处理`)
                .fontSize(13).fontColor(Colors.FUZZY_ORANGE).layoutWeight(1)
              Text('去补卡 ›').fontSize(13).fontColor(Colors.FUZZY_ORANGE)
            }
            .width('92%').margin({ top: 12 }).padding(14)
            .borderRadius(Radius.BUTTON)
            .backgroundColor(Colors.FUZZY_ORANGE_SOFT)
            .onClick(() => NavStore.INSTANCE.push(RouteName.PLAN_TABLE))
          }

          // ===== 艾宾浩斯六桶 =====
          Column() {
            Row() {
              Text('今日复习桶').fontSize(15).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
              Text('艾宾浩斯 R1/R2/R4/R7/R15').fontSize(11).fontColor(Colors.TEXT_WEAK)
            }
            .width('100%').margin({ bottom: 12 })

            Row() {
              ForEach(this.bucketItems(this.stats()), (item: BucketItem, index: number) => {
                this.BucketCard(item, index)
              }, (item: BucketItem): string => item.key)
            }
            .width('100%')
          }
          .width('92%').margin({ top: 16 }).padding(16)
          .borderRadius(Radius.CARD).backgroundColor(Colors.WHITE)

          // ===== 快捷入口 =====
          Column() {
            Text('快捷入口').fontSize(15).fontWeight(FontWeight.Bold).fontColor(Colors.TEXT_MAIN)
              .width('100%').margin({ bottom: 14 })
            Row() {
              this.QuickEntry($r('app.media.ic_camera'), ['#FFB84D', '#EC6A0F'], '#59EC6A0F',
                '拍照导入', 0, 'camera')
              this.QuickEntry($r('app.media.ic_book'), ['#4C8DFF', '#0A59F7'], '#590A59F7',
                '我的词本', 0, 'books')
              this.QuickEntry($r('app.media.ic_wrong'), ['#FF7A7A', '#E14B4B'], '#59E14B4B',
                '错词本', this.stats().wrongCount, 'wrong')
            }
            .width('100%')
          }
          .width('92%').margin({ top: 14 }).padding(16)
          .borderRadius(Radius.CARD).backgroundColor(Colors.WHITE)

          // ===== F20 趣味学习（梗句背单词 / 今日例句），只新增插入，不改既有区块 =====
          this.FunSection()
        }
        .width('100%').alignItems(HorizontalAlign.Center)
        // 底部避让悬浮胶囊 Tab：由最后一屏内容的容器统一预留（语义正确，
        // 以后在末尾追加区块也不会被吃掉留白）。数值见 FloatingTab.CLEARANCE（真机实测反推）。
        .padding({ bottom: FloatingTab.CLEARANCE })
        .safeAreaPadding({ bottom: FloatingTab.SAFE_GAP })
      }
      .width('100%').height('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
    }
    .onRefreshing(() => this.onPullRefresh())
    .width('100%').height('100%')
    .backgroundColor(Colors.PAGE_BG)
    .opacity(1 + (this.tick + this.viewTick) * 0)
  }
}
