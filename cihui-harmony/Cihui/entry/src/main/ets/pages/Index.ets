/**
 * 词慧根容器（F1）：
 * - Navigation + NavPathStack 承载一级页与全部二级页；
 * - 一级页为 首页 / 打卡 / 我的 三个 Tab，自定义悬浮胶囊导航；
 * - Tab 切换淡入上移 8vp/200ms，指示器滑动；
 * - 二级页覆盖时一级页左移 7%、缩放 0.93、压暗。
 */
import { NavStore } from '../viewmodel/NavStore';
import { RouteName } from '../common/RouteNames';
import { REFRESH_BUS, RefreshListener } from '../common/RefreshBus';
import { Colors, TypeScale, Motion, FloatingTab } from '../common/DesignTokens';
import { HomePage } from './tab/HomePage';
import { CheckInPage } from './tab/CheckInPage';
import { ProfilePage } from './tab/ProfilePage';
import { TestPage } from './TestPage';
import { CameraPage } from './camera/CameraPage';
import { OcrReviewPage } from './camera/OcrReviewPage';
import { OcrPickPage } from './camera/OcrPickPage';
import { MyBooksPage } from './books/MyBooksPage';
import { DiyBookPage } from './books/DiyBookPage';
import { CloudLibraryPage } from './books/CloudLibraryPage';
import { CloudSearchPage } from './books/CloudSearchPage';
import { CloudBookDetailPage } from './books/CloudBookDetailPage';
import { BookWordsPage } from './books/BookWordsPage';
import { NewWordsPage } from './study/NewWordsPage';
import { SpeechTestPage } from './study/SpeechTestPage';
import { ReviewCardsPage } from './study/ReviewCardsPage';
import { WrongBookPage } from './study/WrongBookPage';
import { PlanTablePage } from './plan/PlanTablePage';
import { MakeupDetailPage } from './plan/MakeupDetailPage';
import { DailyNewPage } from './plan/DailyNewPage';
import { LoginPage } from './auth/LoginPage';
import { RegisterPage } from './auth/RegisterPage';
import { AccountPage } from './auth/AccountPage';
import { FieldEditPage } from './auth/FieldEditPage';
import { MemeImportPage } from './meme/MemeImportPage';
import { MemeReviewPage } from './meme/MemeReviewPage';
import { MemeAlbumPage } from './meme/MemeAlbumPage';
import { TodaySentencePage } from './study/TodaySentencePage';
import { SentenceFavoritesPage } from './study/SentenceFavoritesPage';
import type {
  BookWordsRouteParam,
  CameraRouteParam,
  CloudBookDetailRouteParam,
  DiyBookRouteParam,
  FieldEditRouteParam,
  MakeupRouteParam,
  MemeReviewRouteParam,
  NewWordsRouteParam,
  OcrPickRouteParam,
  OcrReviewRouteParam,
  ReviewRouteParam,
  SpeechRouteParam
} from '../common/RouteNames';

class TabSpec {
  title: string;
  icon: Resource;
  iconOn: Resource;

  constructor(title: string, icon: Resource, iconOn: Resource) {
    this.title = title;
    this.icon = icon;
    this.iconOn = iconOn;
  }
}

@Entry
@ComponentV2
struct Index {
  @Local currentTab: number = 0;
  /**
   * 动态 QA：Tab 页重挂载版本号。实测被二级页覆盖过的 Tab 页即使收到
   * @Trace/@Local 变更也不重绘，改用 key 变化强制重建整页实例，首次 build
   * 读取最新仓库。切 Tab、二级页栈清空（回 Tab）时自增当前 Tab。
   */
  @Local tabVersion: number[] = [0, 0, 0];
  private tabsController: TabsController = new TabsController();
  private navListener: RefreshListener = (): void => {
    // 二级页全部关闭、回到一级 Tab 时，重挂载当前 Tab
    if (NavStore.INSTANCE.stack.size() === 0) {
      this.bumpTab(this.currentTab);
    }
  };

  private bumpTab(index: number): void {
    const next: number[] = this.tabVersion.slice();
    next[index] = next[index] + 1;
    this.tabVersion = next;
  }
  private tabs: TabSpec[] = [
    new TabSpec('首页', $r('app.media.ic_home'), $r('app.media.ic_home_on')),
    new TabSpec('打卡', $r('app.media.ic_checkin'), $r('app.media.ic_checkin_on')),
    new TabSpec('我的', $r('app.media.ic_profile'), $r('app.media.ic_profile_on'))
  ];

  aboutToAppear(): void {
    NavStore.INSTANCE.init();
    NavStore.INSTANCE.registerTabHandler((index: number) => {
      if (index !== this.currentTab) {
        this.getUIContext().animateTo({ duration: Motion.FEEDBACK, curve: Curve.EaseOut }, () => {
          this.currentTab = index;
        });
        this.tabsController.changeIndex(index);
      }
      // 无论是否切换 Tab，都重挂载目标页，保证落地数据最新
      this.bumpTab(index);
    });
    // F16：通知点击直达打卡页（冷启动暂存的目标在此刻回放）
    NavStore.INSTANCE.registerLaunchHandler((target: string) => {
      if (target === 'checkin') {
        NavStore.INSTANCE.goTab(1);
      }
    });
    REFRESH_BUS.onNav(this.navListener);
  }

  aboutToDisappear(): void {
    REFRESH_BUS.offNav(this.navListener);
  }

  @Builder
  PageMap(name: string, param?: object) {
    if (name === RouteName.TEST) {
      TestPage()
    } else if (name === RouteName.CAMERA) {
      CameraPage({ param: param as CameraRouteParam })
    } else if (name === RouteName.OCR_REVIEW) {
      OcrReviewPage({ param: param as OcrReviewRouteParam })
    } else if (name === RouteName.OCR_PICK) {
      OcrPickPage({ param: param as OcrPickRouteParam })
    } else if (name === RouteName.MY_BOOKS) {
      MyBooksPage()
    } else if (name === RouteName.DIY_BOOK) {
      DiyBookPage({ param: param as DiyBookRouteParam })
    } else if (name === RouteName.CLOUD_LIBRARY) {
      CloudLibraryPage()
    } else if (name === RouteName.CLOUD_SEARCH) {
      CloudSearchPage()
    } else if (name === RouteName.CLOUD_BOOK_DETAIL) {
      CloudBookDetailPage({ param: param as CloudBookDetailRouteParam })
    } else if (name === RouteName.BOOK_WORDS) {
      BookWordsPage({ param: param as BookWordsRouteParam })
    } else if (name === RouteName.NEW_WORDS) {
      NewWordsPage({ param: param as NewWordsRouteParam })
    } else if (name === RouteName.SPEECH_TEST) {
      SpeechTestPage({ param: param as SpeechRouteParam })
    } else if (name === RouteName.REVIEW_CARDS) {
      ReviewCardsPage({ param: param as ReviewRouteParam })
    } else if (name === RouteName.WRONG_BOOK) {
      WrongBookPage()
    } else if (name === RouteName.PLAN_TABLE) {
      PlanTablePage()
    } else if (name === RouteName.MAKEUP_DETAIL) {
      MakeupDetailPage({ param: param as MakeupRouteParam })
    } else if (name === RouteName.DAILY_NEW) {
      DailyNewPage()
    } else if (name === RouteName.LOGIN) {
      LoginPage()
    } else if (name === RouteName.REGISTER) {
      RegisterPage()
    } else if (name === RouteName.ACCOUNT) {
      AccountPage()
    } else if (name === RouteName.FIELD_EDIT) {
      FieldEditPage({ param: param as FieldEditRouteParam })
    } else if (name === RouteName.MEME_IMPORT) {
      MemeImportPage()
    } else if (name === RouteName.MEME_REVIEW) {
      MemeReviewPage({ param: param as MemeReviewRouteParam })
    } else if (name === RouteName.MEME_ALBUM) {
      MemeAlbumPage()
    } else if (name === RouteName.TODAY_SENTENCE) {
      TodaySentencePage()
    } else if (name === RouteName.SENTENCE_FAVORITES) {
      SentenceFavoritesPage()
    }
  }

  @Builder
  TabItem(spec: TabSpec, index: number) {
    Column() {
      Image(this.currentTab === index ? spec.iconOn : spec.icon)
        .width(24)
        .height(24)
      Text(spec.title)
        .fontSize(12)
        .fontColor(this.currentTab === index ? Colors.BRAND : Colors.TEXT_WEAK)
        .margin({ top: 3 })
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      if (this.currentTab === index) {
        return;
      }
      this.getUIContext().animateTo({ duration: Motion.FEEDBACK, curve: Curve.EaseOut }, () => {
        this.currentTab = index;
      });
      this.bumpTab(index);
      this.tabsController.changeIndex(index);
    })
  }

  @Builder
  FloatingBar() {
    Column() {
      Stack({ alignContent: Alignment.Start }) {
        // 胶囊指示器：宽度为 1/3，translateX 百分比相对自身宽度，正好移动一格
        Row()
          .width('33.33%')
          .height(48)
          .borderRadius(24)
          .backgroundColor(Colors.BRAND_SOFT)
          .translate({ x: `${this.currentTab * 100}%` })
        Row() {
          ForEach(this.tabs, (spec: TabSpec, index: number) => {
            this.TabItem(spec, index)
          })
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height(FloatingTab.CONTENT_HEIGHT)
      .padding({ left: 4, right: 4 })
    }
    .width('90%')
    .height(FloatingTab.HEIGHT)
    .backgroundColor(Colors.WHITE)
    .borderRadius(32)
    .shadow({ radius: 18, color: '#1F17202E', offsetX: 0, offsetY: 6 })
    .margin({ bottom: FloatingTab.MARGIN })
    .safeAreaPadding({ bottom: FloatingTab.SAFE_GAP })
  }

  build() {
    Navigation(NavStore.INSTANCE.stack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Tabs({ controller: this.tabsController, barPosition: BarPosition.End }) {
          TabContent() {
            // 动态 QA：ForEach 键随 tabVersion 变化，强制销毁重建 Tab 页，保证数据最新
            Column() {
              ForEach([this.tabVersion[0]], (v: number) => {
                HomePage({ active: this.currentTab === 0, tick: NavStore.INSTANCE.navTick })
              }, (v: number): string => 'home-tab-' + v)
            }.width('100%').height('100%')
          }.tabBar('')
          TabContent() {
            Column() {
              ForEach([this.tabVersion[1]], (v: number) => {
                CheckInPage({ active: this.currentTab === 1, tick: NavStore.INSTANCE.navTick })
              }, (v: number): string => 'checkin-tab-' + v)
            }.width('100%').height('100%')
          }.tabBar('')
          TabContent() {
            Column() {
              ForEach([this.tabVersion[2]], (v: number) => {
                ProfilePage({ active: this.currentTab === 2, tick: NavStore.INSTANCE.navTick })
              }, (v: number): string => 'profile-tab-' + v)
            }.width('100%').height('100%')
          }.tabBar('')
        }
        .barHeight(0)
        .scrollable(false)
        .animationDuration(0)
        .onChange((index: number) => {
          // 手势/控制器切换时同步指示器（点击已在 onClick 中带动画）
          this.getUIContext().animateTo({ duration: Motion.FEEDBACK, curve: Curve.EaseOut }, () => {
            this.currentTab = index;
          })
          // 切到该 Tab 时重挂载，保证以最新仓库数据首次 build
          this.bumpTab(index);
        })

        this.FloatingBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Colors.PAGE_BG)
      // 二级页覆盖时一级页的层压效果
      .scale({ x: NavStore.INSTANCE.covered ? 0.93 : 1, y: NavStore.INSTANCE.covered ? 0.93 : 1 })
      .translate({ x: NavStore.INSTANCE.covered ? '-7%' : '0%' })
      .brightness(NavStore.INSTANCE.covered ? 0.97 : 1)
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.PageMap)
  }
}
