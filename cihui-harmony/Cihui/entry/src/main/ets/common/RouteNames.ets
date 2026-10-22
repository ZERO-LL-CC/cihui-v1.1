/**
 * 路由名常量枚举。业务代码只允许引用本枚举，禁止在 pushPath 中写裸字符串。
 * 随功能卡推进追加：F3 相机页、F4 OCR 校对页。
 */
export enum RouteName {
  TEST = 'TestPage',
  /** F3 全屏相机页（微信相机式） */
  CAMERA = 'CameraPage',
  /** F4 OCR 识别结果人工校对页（manual=1 时为手动录入模式） */
  OCR_REVIEW = 'OcrReviewPage',
  /** 真机反馈 #25：拍照识别后单词气泡选词（自动匹配中文），确认后再进校对页 */
  OCR_PICK = 'OcrPickPage',
  /** F5 我的词本（词本列表 + 拍照 FAB + 云词本入口） */
  MY_BOOKS = 'MyBooksPage',
  /** F5 个人 DIY 词本（预览 / 编辑双态） */
  DIY_BOOK = 'DiyBookPage',
  /** F5 云词本库（分类 + 年级 chip + 搜索入口） */
  CLOUD_LIBRARY = 'CloudLibraryPage',
  /** F5 云词本搜索（热门搜索 + 历史 + 即时过滤） */
  CLOUD_SEARCH = 'CloudSearchPage',
  /** F5 词书详情（预览 + 下载导入） */
  CLOUD_BOOK_DETAIL = 'CloudBookDetailPage',
  /** 全书单词浏览（本地词本 bookId 或随包云书 cloudBookId，搜索 + 全量单词列表） */
  BOOK_WORDS = 'BookWordsPage',
  /** F7 新词首学（批量幻灯片 + TTS 朗读） */
  NEW_WORDS = 'NewWordsPage',
  /** F8 语音快过（字幕式 ASR + 手动三档降级） */
  SPEECH_TEST = 'SpeechTestPage',
  /** F9 到期复习闪卡（三档判定 + 手势；F10 错词强化复用） */
  REVIEW_CARDS = 'ReviewCardsPage',
  /** F10 错词本（列表 + 左滑移出 + 开始错词强化复习） */
  WRONG_BOOK = 'WrongBookPage',
  /** F12 艾宾浩斯计划大表（月历 + 彩点 + 翻月 + 红格补卡入口 + 果冻入场） */
  PLAN_TABLE = 'PlanTablePage',
  /** F12 补卡日详情（按节点分组待补词 + 生成补卡词本） */
  MAKEUP_DETAIL = 'MakeupDetailPage',
  /** F12 每日新词量（iOS 时钟式滚轮 + 实时预览） */
  DAILY_NEW = 'DailyNewPage',
  /** F14 登录页（微信 / QQ / 登录注册三按钮） */
  LOGIN = 'LoginPage',
  /** F14 注册表单页（名称 / 手机 / 邮箱 / 微信） */
  REGISTER = 'RegisterPage',
  /** F14 账号资料页（头像昵称 + 字段行 + 退出登录） */
  ACCOUNT = 'AccountPage',
  /** F14 单字段二级编辑页 */
  FIELD_EDIT = 'FieldEditPage',
  /** F17 梗句导入（中文输入/离线翻译/拆词确认两态同页） */
  MEME_IMPORT = 'MemeImportPage',
  /** F17 梗句背诵闪卡（复用 F9 三档手势 + 会话可恢复 + 看原句） */
  MEME_REVIEW = 'MemeReviewPage',
  /** F18 梗卡册（倒序大图 / 再分享 / 左滑删除） */
  MEME_ALBUM = 'MemeAlbumPage',
  /** F19 今日例句（大模型分批生成 + 高亮 + TTS + 收藏） */
  TODAY_SENTENCE = 'TodaySentencePage',
  /** F19 我的例句本（收藏例句回看） */
  SENTENCE_FAVORITES = 'SentenceFavoritesPage'
}

/** F14 字段编辑入参 */
export interface FieldEditRouteParam {
  /** 编辑字段：name/phone/email/wechat/qq */
  field: string;
}

/** F7 入参：分组浏览（每 10 个一组，看完立刻测这一组） */
export interface NewWordsRouteParam {
  wordIds: string[];
  /** 组序号（1 基） */
  groupIndex: number;
  groupTotal: number;
}

/** F8 入参：本轮要测的词 id（一组新词 / 一批模糊重考词） */
export interface SpeechRouteParam {
  wordIds: string[];
  /** 分组学习模式：本组判完即提交并按会话推进下一组 */
  chunk?: boolean;
  groupIndex?: number;
  groupTotal?: number;
  /** 模糊重考批次 */
  retest?: boolean;
  batchIndex?: number;
  batchTotal?: number;
}

/** F9/F10/F12 闪卡入参：本轮要过的词 id、标题与模式（复习 / 错词强化 / 补卡） */
export interface ReviewRouteParam {
  wordIds: string[];
  title: string;
  /** REVIEW=到期复习（P2）；WRONG=错词强化（P3）；MAKEUP=补卡词本（完成后同步计划表） */
  mode: string;
  /** MAKEUP 模式必填：补卡日 yyyy-mm-dd */
  makeupDay?: string;
}

/** F12 补卡日详情入参 */
export interface MakeupRouteParam {
  day: string;
}

/** F3 相机页入参 */
export interface CameraRouteParam {
  /** 来源：home 首页快捷入口；books 我的词本 FAB */
  from: string;
  /** 指定导入词本（我的词本 FAB 场景）；首页入口为空，F4 校对时再选/默认 DIY */
  bookId?: string;
}

/** F4 校对页入参（F3 识别完成后携带，内存对象不走序列化） */
export interface OcrReviewRouteParam {
  /** OCR 原始结果（图片 + 文本行），按拍摄顺序；手动模式或走气泡选词时为空数组 */
  results: object[];
  /** 气泡选词页已选定的词条（OcrDraft[]），存在时直接作为校对初始数据，跳过 results 解析 */
  picks?: object[];
  /** 手动录入模式：无图片、空列表起步 */
  manual: boolean;
  from: string;
  bookId?: string;
}

/** 单词气泡选词页入参（真机反馈 #25） */
export interface OcrPickRouteParam {
  /** OCR 原始结果（图片 + 文本行），按拍摄顺序 */
  results: object[];
  from: string;
  bookId?: string;
}

/** F5 DIY 词本页入参 */
export interface DiyBookRouteParam {
  bookId: string;
}

/** F5 词书详情页入参 */
export interface CloudBookDetailRouteParam {
  cloudBookId: string;
}

/** 全书单词浏览页入参：bookId 走本地词本（云书已导入/拍照/梗句/DIY）；cloudBookId 走随包云书（未导入也可只读浏览全书） */
export interface BookWordsRouteParam {
  bookId?: string;
  cloudBookId?: string;
}

/** F17 梗句背诵入参：指定梗句；sessionId 存在时直接续背指定会话 */
export interface MemeReviewRouteParam {
  memeId: string;
  sessionId?: string;
}
