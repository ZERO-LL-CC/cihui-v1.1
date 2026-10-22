/**
 * 词慧 · F17 梗句「离线梗味翻译」—— 纯逻辑层。
 *
 * 不依赖任何 ArkUI / @kit.* / http / 文件系统，可被 Node 直接 import 做单元测试
 * （与 model/MemeCore.ts 同一范式）。
 *
 * 背景：原方案依赖云端大模型与 API Key，Key 从未配置，链路必然失败；
 * 且端侧自带 116MB Opus-MT 神经网络又会撑爆包体。因此改为「词表 + 改写策略」的
 * 零网络、零密钥、零模型引擎，分三层降级并诚实标注能力边界：
 *
 * - L1 SENTENCE：命中 PHRASE_BANK 的整句（≈245 条）→ 直接给高质量英文，needsManual=false；
 *   先做归一化**完全相等**比对，再做**近似**比对（句库条目是输入的一段，或反之），
 *   近似命中用 matchKind='near' 标注，UI 会提示「匹配到相近说法」；
 * - L2 MEME    ：命中 32 条梗词表 → 中文改写为「标准中文」+ 英文按出现顺序拼「脚手架」
 *                （命中片段换成英文俚语，其余实质中文换成占位符 [...]），needsManual=true；
 * - L3 NONE    ：都没命中 → 不给英文（不编造），按最长公共子串给 3 条相近说法
 *                （suggestions），用户点一条即可拿到对应英文，needsManual=true。
 *
 * 改写口径修正：Demo 注释写「长词优先」但实际按表顺序遍历，这里按梗词长度降序排序后
 * 再替换，保证「破大防」「一顿操作猛如虎」这类长梗不会被短梗截断。
 *
 * 能力边界（产品须知情）：本引擎不是通用翻译器，只认识表内的梗与整句模板；
 * 未命中时宁可留空也不产出错误英文。
 */

/** 一条梗词：梗词 / 标准中文改写 / 英文俚语建议（可含 "/" 分隔的多个候选） */
export interface MemeEntry {
  term: string;
  standard: string;
  slang: string;
}

/** 一次命中；index 为梗词在原文中的首次出现位置（用于按原文顺序展示） */
export interface MemeHit {
  term: string;
  standard: string;
  slang: string;
  index: number;
}

/** 一条整句模板：中文原句 / 预置英文 */
export interface PhrasePair {
  zh: string;
  en: string;
}

/** 梗味模式（改写 + 脚手架） / 直译模式（只检测梗，不产出英文） */
export type TranslateMode = 'MEME' | 'LITERAL';

/** 命中层级：整句模板 / 梗词脚手架 / 未命中 */
export type TranslateLevel = 'SENTENCE' | 'MEME' | 'NONE';

/** 离线翻译结果（UI 直接消费，不抛异常） */
export interface TranslateResult {
  /** 英文结果；L2 为脚手架，L3 为空串 */
  english: string;
  /** 梗味模式下的标准中文改写；直译模式等于原文 */
  rewrittenZh: string;
  /** 命中的梗词（按原文出现顺序） */
  hits: MemeHit[];
  mode: TranslateMode;
  level: TranslateLevel;
  /** 是否必须人工润色/补全（L3 与 L2 为 true） */
  needsManual: boolean;
  /** 可直接 Toast 的提示文案 */
  message: string;
  /** 未命中时推荐的相近整句中文（最多 3 条，UI 展示给用户点选），命中时为 undefined */
  suggestions?: string[];
  /** 命中类型：exact 归一化完全相等 / near 近似（句库条目是输入的一段） */
  matchKind?: string;
}

/* ================= 梗词表（32 条，与 Demo 原文一致） ================= */

export const MEME_TABLE: MemeEntry[] = [
  { term: '卷生卷死', standard: '拼命到极点', slang: 'grinding myself to dust in the rat race' },
  { term: '破大防', standard: '彻底绷不住了', slang: 'utterly shattered my defenses' },
  { term: 'CPU都干烧了', standard: '脑子转不过来了', slang: 'brain overheated' },
  { term: '一顿操作猛如虎', standard: '折腾半天全白费', slang: 'all that hustle for nothing' },
  { term: '这波操作', standard: '这一次的做法', slang: 'this move / this play' },
  { term: '泼天的富贵', standard: '天大的好运', slang: 'sky-high fortune' },
  { term: '家人们谁懂啊', standard: '大家能理解吗', slang: 'who else gets this?' },
  { term: '尊嘟假嘟', standard: '真的假的', slang: 'for real or cap?' },
  { term: '绝绝子', standard: '非常棒', slang: 'absolutely stunning / god-tier' },
  { term: '香迷糊了', standard: '好吃到上瘾', slang: 'so good it\'s addictive' },
  { term: '破防了', standard: '被击中软肋', slang: 'it broke me / hit a nerve' },
  { term: '内卷', standard: '恶性竞争', slang: 'the rat race' },
  { term: '躺平', standard: '不参与竞争', slang: 'lie flat / opt out of the grind' },
  { term: '摆烂', standard: '放弃努力', slang: 'let it rot / give up trying' },
  { term: '摸鱼', standard: '上班偷懒', slang: 'slack off at work' },
  { term: '打工人', standard: '上班族', slang: 'wage warrior' },
  { term: '干饭', standard: '吃饭', slang: 'feast mode' },
  { term: '社死', standard: '当众出丑', slang: 'die of embarrassment in public' },
  { term: '上头', standard: '着迷上瘾', slang: 'hooked / can\'t stop' },
  { term: '下头', standard: '好感全无', slang: 'a total turn-off' },
  { term: '拿捏', standard: '完全掌控', slang: 'nailed it / have it in the bag' },
  { term: '显眼包', standard: '爱出风头的人', slang: 'attention magnet / class clown' },
  { term: '凡尔赛', standard: '炫耀式谦虚', slang: 'humblebrag' },
  { term: '芭比Q', standard: '完蛋了', slang: 'done for / cooked' },
  { term: '栓Q', standard: '谢了（反讽）', slang: 'well thanks a lot (eye-roll)' },
  { term: 'emo了', standard: '情绪低落了', slang: 'feeling down in the dumps' },
  { term: '整活', standard: '搞事情', slang: 'pull a stunt / do something wild' },
  { term: '官宣', standard: '正式公布', slang: 'make it official' },
  { term: '戏精', standard: '爱演的人', slang: 'drama queen' },
  { term: '太细了', standard: '非常精妙', slang: 'silky smooth / executed to a T' },
  { term: '单曲循环', standard: '反复播放', slang: 'on repeat' },
  { term: 'yyds', standard: '最棒的', slang: 'the GOAT (greatest of all time)' },
];

/* ================= 整句库（≈235 条，原 Demo 预设 + 高频日常表达） ================= */

/**
 * 为什么扩这么大：原库只有 10 条，且 findPhrase 是「归一化后完全相等」比对，
 * 用户随手一句的自由输入几乎必然落空（实测「我太难了」「今天好开心」都是空）。
 * 这里按真实使用场景铺开：情绪 / 寒暄 / 评价 / 学习工作 / 校园 / 疑问句式。
 * 英文口径：地道、口语、大学英语能读懂，不追求书面腔。
 * 维护约定：一条一句、zh 不带到句末标点（比对前会归一化，带不带都能中）。
 */
export const PHRASE_BANK: PhrasePair[] = [
  /* ---------- 原 Demo 预设（梗句长句，保留） ---------- */
  { zh: '这波操作太细了', en: 'That move was executed to a T.' },
  { zh: '绝绝子，这家店真的香迷糊了', en: 'Absolute god-tier. This place is so good it\'s addictive.' },
  { zh: '破防了，家人们谁懂啊', en: 'I\'m utterly shattered. Who else gets this?' },
  { zh: '天天加班卷生卷死，我想躺平了', en: 'Grinding myself to dust in the rat race every day — I just want to opt out.' },
  { zh: '别内卷了，摸鱼才是打工人的宿命', en: 'Stop feeding the rat race — slacking off is the wage warrior\'s destiny.' },
  { zh: '尊嘟假嘟，你不会还不知道吧', en: 'For real? Don\'t tell me you still don\'t know.' },
  { zh: '他一开口我就社死了，CPU都干烧了', en: 'The moment he opened his mouth I died of embarrassment — my brain overheated.' },
  { zh: '一顿操作猛如虎，一看工资两千五', en: 'All that hustle, and the paycheck is a joke.' },
  { zh: '上头了，这首歌我单曲循环一晚上', en: 'I\'m hooked — I had this song on repeat all night.' },
  { zh: '泼天的富贵终于轮到我了', en: 'Sky-high fortune has finally come my way.' },

  /* ---------- 情绪与状态（45） ---------- */
  { zh: '我太难了', en: 'I\'m really having a hard time.' },
  { zh: '我裂开了', en: 'I\'m completely falling apart.' },
  { zh: '心态崩了', en: 'My mindset just collapsed.' },
  { zh: '我麻了', en: 'I\'m numb to all of this.' },
  { zh: '无语了', en: 'I\'m speechless.' },
  { zh: '服了', en: 'I give up, seriously.' },
  { zh: '崩溃了', en: 'I\'m losing it.' },
  { zh: '想哭', en: 'I feel like crying.' },
  { zh: '好烦', en: 'I\'m so annoyed.' },
  { zh: '累死了', en: 'I\'m dead tired.' },
  { zh: '好困', en: 'I\'m so sleepy.' },
  { zh: '好饿', en: 'I\'m starving.' },
  { zh: '好冷', en: 'It\'s freezing.' },
  { zh: '好热', en: 'It\'s boiling hot.' },
  { zh: '好无聊', en: 'I\'m so bored.' },
  { zh: '好开心', en: 'I\'m so happy.' },
  { zh: '好激动', en: 'I\'m so excited.' },
  { zh: '好紧张', en: 'I\'m so nervous.' },
  { zh: '好尴尬', en: 'This is so awkward.' },
  { zh: '好丢人', en: 'That\'s so embarrassing.' },
  { zh: '压力好大', en: 'I\'m under so much pressure.' },
  { zh: '心累', en: 'I\'m emotionally drained.' },
  { zh: '心碎', en: 'My heart is broken.' },
  { zh: '破防了', en: 'It broke me.' },
  { zh: '蚌埠住了', en: 'I can\'t hold it together anymore.' },
  { zh: '绷不住了', en: 'I can\'t keep it together.' },
  { zh: '笑死我了', en: 'I\'m dying of laughter.' },
  { zh: '笑不活了', en: 'I can\'t stop laughing.' },
  { zh: '太好笑了', en: 'That\'s hilarious.' },
  { zh: '感动到哭', en: 'I\'m moved to tears.' },
  { zh: '有点慌', en: 'I\'m a little panicking.' },
  { zh: '我很慌', en: 'I\'m freaking out.' },
  { zh: '别慌', en: 'Don\'t panic.' },
  { zh: '稳住', en: 'Hold steady.' },
  { zh: '我好了', en: 'I\'m fine now.' },
  { zh: '我想静静', en: 'I need some quiet time.' },
  { zh: '让我静静', en: 'Let me have a moment.' },
  { zh: '不想说话', en: 'I don\'t want to talk.' },
  { zh: '我自闭了', en: 'I\'ve shut myself off.' },
  { zh: '我emo了', en: 'I\'m feeling down.' },
  { zh: '今天心情不错', en: 'I\'m in a good mood today.' },
  { zh: '今天心情很差', en: 'I\'m in a terrible mood today.' },
  { zh: '我有点难受', en: 'I feel a bit unwell.' },
  { zh: '我没事', en: 'I\'m okay.' },
  { zh: '我很好', en: 'I\'m doing great.' },

  /* ---------- 寒暄与社交（30） ---------- */
  { zh: '早上好', en: 'Good morning.' },
  { zh: '晚上好', en: 'Good evening.' },
  { zh: '好久不见', en: 'Long time no see.' },
  { zh: '最近怎么样', en: 'How have you been?' },
  { zh: '你吃了吗', en: 'Have you eaten yet?' },
  { zh: '我先走了', en: 'I\'m heading off first.' },
  { zh: '明天见', en: 'See you tomorrow.' },
  { zh: '路上小心', en: 'Take care on the way.' },
  { zh: '注意安全', en: 'Stay safe.' },
  { zh: '早点休息', en: 'Get some rest early.' },
  { zh: '多喝热水', en: 'Drink more warm water.' },
  { zh: '加油', en: 'You got this.' },
  { zh: '辛苦了', en: 'Thanks for your hard work.' },
  { zh: '麻烦你了', en: 'Sorry to trouble you.' },
  { zh: '拜托了', en: 'I\'m counting on you.' },
  { zh: '谢谢你帮我', en: 'Thanks for helping me out.' },
  { zh: '不客气', en: 'You\'re welcome.' },
  { zh: '对不起是我错了', en: 'I\'m sorry, that was my fault.' },
  { zh: '没关系', en: 'It\'s no big deal.' },
  { zh: '别放在心上', en: 'Don\'t take it to heart.' },
  { zh: '借过一下', en: 'Excuse me, coming through.' },
  { zh: '打扰一下', en: 'Sorry to interrupt.' },
  { zh: '请问几点', en: 'Excuse me, what time is it?' },
  { zh: '你说得对', en: 'You\'re right.' },
  { zh: '我同意', en: 'I agree.' },
  { zh: '我不同意', en: 'I don\'t agree.' },
  { zh: '有道理', en: 'That makes sense.' },
  { zh: '随便你', en: 'It\'s up to you.' },
  { zh: '都可以', en: 'Either way works for me.' },
  { zh: '再说吧', en: 'Let\'s talk about it later.' },

  /* ---------- 评价与吐槽（40） ---------- */
  { zh: '绝了', en: 'That\'s insane.' },
  { zh: '太牛了', en: 'That\'s amazing.' },
  { zh: '太离谱了', en: 'That\'s absurd.' },
  { zh: '太过分了', en: 'That\'s going too far.' },
  { zh: '一般般', en: 'It\'s just so-so.' },
  { zh: '还行', en: 'It\'s alright.' },
  { zh: '挺好的', en: 'It\'s pretty good.' },
  { zh: '太贵了', en: 'That\'s too expensive.' },
  { zh: '太慢了', en: 'It\'s too slow.' },
  { zh: '太难了', en: 'It\'s too hard.' },
  { zh: '太简单了', en: 'It\'s too easy.' },
  { zh: '没意思', en: 'It\'s boring.' },
  { zh: '有意思', en: 'That\'s interesting.' },
  { zh: '真香', en: 'It actually slaps.' },
  { zh: '这不行', en: 'That won\'t work.' },
  { zh: '这不合理', en: 'That doesn\'t make sense.' },
  { zh: '有毛病吧', en: 'What\'s wrong with you?' },
  { zh: '你认真的吗', en: 'Are you serious?' },
  { zh: '你在开玩笑吧', en: 'You must be joking.' },
  { zh: '别闹了', en: 'Stop messing around.' },
  { zh: '少来', en: 'Cut it out.' },
  { zh: '想得美', en: 'In your dreams.' },
  { zh: '做梦吧', en: 'Dream on.' },
  { zh: '我信你个鬼', en: 'I don\'t buy that at all.' },
  { zh: '你被骗了', en: 'You got scammed.' },
  { zh: '我早说了', en: 'I told you so.' },
  { zh: '果然如此', en: 'I knew it.' },
  { zh: '意料之中', en: 'That was expected.' },
  { zh: '没想到', en: 'I didn\'t see that coming.' },
  { zh: '有点厉害', en: 'That\'s pretty impressive.' },
  { zh: '厉害了我的哥', en: 'You really outdid yourself.' },
  { zh: '不值', en: 'It\'s not worth it.' },
  { zh: '值了', en: 'Totally worth it.' },
  { zh: '白费力气', en: 'That was a waste of effort.' },
  { zh: '浪费时间', en: 'That\'s a waste of time.' },
  { zh: '多此一举', en: 'That\'s unnecessary.' },
  { zh: '早干嘛去了', en: 'Where were you earlier?' },
  { zh: '有点东西', en: 'There\'s something to that.' },
  { zh: '上不了台面', en: 'That\'s not presentable.' },
  { zh: '差强人意', en: 'It\'s passable, barely.' },

  /* ---------- 学习与工作（30） ---------- */
  { zh: '我要迟到了', en: 'I\'m going to be late.' },
  { zh: '我在赶论文', en: 'I\'m rushing my paper.' },
  { zh: '明天要交作业', en: 'The assignment is due tomorrow.' },
  { zh: '作业好多', en: 'I have so much homework.' },
  { zh: '作业写完了吗', en: 'Have you finished your homework?' },
  { zh: '我在复习', en: 'I\'m reviewing.' },
  { zh: '我要考试了', en: 'I have an exam coming up.' },
  { zh: '考砸了', en: 'I bombed the exam.' },
  { zh: '挂科了', en: 'I failed the course.' },
  { zh: '及格了', en: 'I passed.' },
  { zh: '满分', en: 'Full marks.' },
  { zh: '这题不会', en: 'I can\'t solve this problem.' },
  { zh: '我懂了', en: 'I get it now.' },
  { zh: '我没听懂', en: 'I didn\'t follow.' },
  { zh: '再说一遍', en: 'Say that again.' },
  { zh: '讲慢一点', en: 'Could you slow down?' },
  { zh: '我记一下', en: 'Let me take a note.' },
  { zh: '上课走神了', en: 'I zoned out in class.' },
  { zh: '老师在点名', en: 'The teacher is taking attendance.' },
  { zh: '下课了', en: 'Class is over.' },
  { zh: '我请假了', en: 'I asked for leave.' },
  { zh: '加班到很晚', en: 'I worked overtime until late.' },
  { zh: '今天开会', en: 'There\'s a meeting today.' },
  { zh: '我有个想法', en: 'I have an idea.' },
  { zh: '这个方案行不行', en: 'Does this plan work?' },
  { zh: '进度怎么样', en: 'How\'s the progress?' },
  { zh: '来不及了', en: 'There\'s no time left.' },
  { zh: '快完成了', en: 'I\'m almost done.' },
  { zh: '我搞定了', en: 'I\'ve got it done.' },
  { zh: '交给我', en: 'Leave it to me.' },

  /* ---------- 校园生活（30） ---------- */
  { zh: '食堂的饭不好吃', en: 'The cafeteria food isn\'t good.' },
  { zh: '今天吃什么', en: 'What should we eat today?' },
  { zh: '一起吃饭吗', en: 'Want to grab a bite?' },
  { zh: '我请你', en: 'It\'s on me.' },
  { zh: '我请客', en: 'My treat.' },
  { zh: '我先回宿舍', en: 'I\'m heading back to the dorm.' },
  { zh: '宿舍停电了', en: 'The dorm has no power.' },
  { zh: '网好卡', en: 'The internet is lagging.' },
  { zh: '断网了', en: 'The connection dropped.' },
  { zh: '手机没电了', en: 'My phone is dead.' },
  { zh: '借我充电宝', en: 'Can I borrow your power bank?' },
  { zh: '图书馆占座', en: 'I\'m saving a seat in the library.' },
  { zh: '明天早八', en: 'I have an 8 a.m. class tomorrow.' },
  { zh: '起不来', en: 'I can\'t get up.' },
  { zh: '闹钟没响', en: 'My alarm didn\'t go off.' },
  { zh: '我睡过头了', en: 'I overslept.' },
  { zh: '熬夜了', en: 'I stayed up late.' },
  { zh: '通宵了', en: 'I pulled an all-nighter.' },
  { zh: '补个觉', en: 'I\'m going to catch up on sleep.' },
  { zh: '我打车过去', en: 'I\'ll take a taxi there.' },
  { zh: '堵车了', en: 'I\'m stuck in traffic.' },
  { zh: '快到了', en: 'I\'m almost there.' },
  { zh: '你在哪', en: 'Where are you?' },
  { zh: '我在楼下', en: 'I\'m downstairs.' },
  { zh: '等你', en: 'Waiting for you.' },
  { zh: '别等我', en: 'Don\'t wait for me.' },
  { zh: '天要下雨了', en: 'It\'s about to rain.' },
  { zh: '记得带伞', en: 'Remember your umbrella.' },
  { zh: '一起走吧', en: 'Let\'s go together.' },
  { zh: '我先撤了', en: 'I\'m taking off.' },

  /* ---------- 口语衔接（35） ---------- */
  { zh: '真的假的', en: 'For real?' },
  { zh: '我不信', en: 'I don\'t believe it.' },
  { zh: '确实', en: 'Exactly.' },
  { zh: '确实如此', en: 'That\'s true.' },
  { zh: '说得好', en: 'Well said.' },
  { zh: '有一说一', en: 'To be fair.' },
  { zh: '实话实说', en: 'Honestly speaking.' },
  { zh: '讲真', en: 'Honestly.' },
  { zh: '说白了', en: 'Basically.' },
  { zh: '换句话说', en: 'In other words.' },
  { zh: '别提了', en: 'Don\'t even mention it.' },
  { zh: '一言难尽', en: 'It\'s a long story.' },
  { zh: '说来话长', en: 'That\'s a long story.' },
  { zh: '慢慢来', en: 'Take your time.' },
  { zh: '别急', en: 'No rush.' },
  { zh: '稳住别慌', en: 'Stay calm.' },
  { zh: '我顶你', en: 'I\'ve got your back.' },
  { zh: '我支持你', en: 'I support you.' },
  { zh: '靠你了', en: 'I\'m counting on you.' },
  { zh: '交给你了', en: 'I\'ll leave it to you.' },
  { zh: '走起', en: 'Let\'s go.' },
  { zh: '干就完了', en: 'Just do it.' },
  { zh: '安排', en: 'Consider it done.' },
  { zh: '好家伙', en: 'Good grief.' },
  { zh: '我的天', en: 'Oh my god.' },
  { zh: '不是吧', en: 'No way.' },
  { zh: '什么情况', en: 'What\'s going on?' },
  { zh: '怎么回事', en: 'What happened?' },
  { zh: '你怎么了', en: 'What\'s wrong with you?' },
  { zh: '有什么事', en: 'What\'s up?' },
  { zh: '在吗', en: 'You there?' },
  { zh: '收到', en: 'Got it.' },
  { zh: '明白', en: 'Understood.' },
  { zh: '好的没问题', en: 'Sure, no problem.' },
  { zh: '没问题', en: 'No problem.' },

  /* ---------- 疑问句式（25，供近似匹配兜底） ---------- */
  { zh: '为什么不行', en: 'Why not?' },
  { zh: '为什么不能', en: 'Why can\'t we?' },
  { zh: '为什么', en: 'Why?' },
  { zh: '怎么办', en: 'What should I do?' },
  { zh: '这怎么办', en: 'What do I do now?' },
  { zh: '怎么会这样', en: 'How did this happen?' },
  { zh: '你怎么知道', en: 'How do you know?' },
  { zh: '能不能行', en: 'Will this work?' },
  { zh: '行不行', en: 'Does it work or not?' },
  { zh: '真的吗', en: 'Really?' },
  { zh: '你觉得呢', en: 'What do you think?' },
  { zh: '你说呢', en: 'You tell me.' },
  { zh: '有什么用', en: 'What\'s the point?' },
  { zh: '有必要吗', en: 'Is that necessary?' },
  { zh: '谁说的', en: 'Who said that?' },
  { zh: '在哪', en: 'Where is it?' },
  { zh: '多久', en: 'How long?' },
  { zh: '多少钱', en: 'How much is it?' },
  { zh: '几点开始', en: 'What time does it start?' },
  { zh: '怎么去', en: 'How do we get there?' },
  { zh: '能帮我吗', en: 'Can you help me?' },
  { zh: '可以吗', en: 'Is that okay?' },
  { zh: '好不好', en: 'Is it good?' },
  { zh: '是不是', en: 'Is that so?' },
  { zh: '对吗', en: 'Am I right?' },
];

/** 占位符：未命中的实质中文片段（提示用户这里是待补翻译的部分） */
export const PLACEHOLDER: string = '[...]';

/* ================= 归一化 ================= */

/** 是否汉字（梗词全部落在 CJK 基本区） */
function isCjk(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  return code >= 0x4E00 && code <= 0x9FFF;
}

/**
 * 归一化：**只保留汉字、字母、数字**，其余（标点 / 空白 / 引号 / 括号 / 全角符号）全部剥掉。
 * 只用于「整句库比对」，不参与 L2 的原文位置索引（L2 始终在原文上算 index）。
 *
 * 这样「破防了，家人们谁懂啊」「破防了家人们谁懂啊」「（破防了，家人们谁懂啊）」
 * 「"破防了，家人们谁懂啊"」都收敛成同一个键，L1 召回不再被标点写法左右。
 */
export function normalizeZh(s: string): string {
  let out: string = '';
  for (let i: number = 0; i < s.length; i++) {
    const ch: string = s.charAt(i);
    if (isCjk(ch) || /[A-Za-z0-9]/.test(ch)) {
      out += ch;
    }
  }
  return out;
}

/** 整句库比对键：归一化 + 小写（拉丁字母不区分大小写） */
function phraseKey(s: string): string {
  return normalizeZh(s).toLowerCase();
}

/* ================= 梗词匹配与改写 ================= */

/** 按长度降序排序（长词优先；同长度保持表内原顺序，sort 稳定） */
function sortedByLengthDesc(): MemeEntry[] {
  const list: MemeEntry[] = MEME_TABLE.slice();
  list.sort((a: MemeEntry, b: MemeEntry): number => b.term.length - a.term.length);
  return list;
}

/** 预排序结果（模块级常量，避免每次调用重复排序） */
const SORTED_TABLE: MemeEntry[] = sortedByLengthDesc();

/** 英文俚语取第一个候选（"this move / this play" → "this move"） */
export function primarySlang(slang: string): string {
  const idx: number = slang.indexOf('/');
  const first: string = idx >= 0 ? slang.substring(0, idx) : slang;
  return first.trim();
}

/** 首字母大写（空串原样返回） */
function capitalizeFirst(s: string): string {
  if (s.length === 0) {
    return s;
  }
  return s.charAt(0).toUpperCase() + s.substring(1);
}

/** 片段是否已以句末标点收尾（. ? !） */
function endsSentence(s: string): boolean {
  if (s.length === 0) {
    return false;
  }
  const last: string = s.charAt(s.length - 1);
  return last === '.' || last === '?' || last === '!';
}

/**
 * 往英文框追加一段俚语（UI「梗味命中」点选复用，纯函数便于单测）。
 *
 * 规则与 buildScaffold 保持一致，避免人工点选又拼出病句：
 * - 空框 → 直接放首字母大写的片段；
 * - 前文以 . ? ! 结尾 → 补一个空格；
 * - 前文以占位符 [...] 结尾 → 只补一个空格（占位符不是句子）；
 * - 否则补「. 」。
 *
 * @param cur 英文框当前内容
 * @param fragment 待追加片段（通常为 primarySlang 结果）
 */
export function appendEnglish(cur: string, fragment: string): string {
  const frag: string = capitalizeFirst(fragment.trim());
  if (frag.length === 0) {
    return cur;
  }
  const base: string = cur.trim();
  if (base.length === 0) {
    return frag;
  }
  const endsWithPlaceholder: boolean =
    base.length >= PLACEHOLDER.length
      && base.substring(base.length - PLACEHOLDER.length) === PLACEHOLDER;
  return base + ((endsWithPlaceholder || endsSentence(base)) ? ' ' : '. ') + frag;
}

/** 只做检测（不改写），命中按原文出现顺序返回；用于直译模式 */
export function detectHits(zh: string): MemeHit[] {
  const hits: MemeHit[] = [];
  const lowerZh: string = zh.toLowerCase();
  for (const entry of SORTED_TABLE) {
    // 拉丁字母梗（yyds / 芭比Q / CPU都干烧了 / emo了）用户不会严格复刻大小写
    const at: number = lowerZh.indexOf(entry.term.toLowerCase());
    if (at >= 0) {
      hits.push({ term: entry.term, standard: entry.standard, slang: entry.slang, index: at });
    }
  }
  hits.sort((a: MemeHit, b: MemeHit): number => a.index - b.index);
  return hits;
}

/**
 * 大小写无关的全量替换（等价 replaceAll + 'i'）。
 * 逐次定位后拼接，避免 ArkTS 不支持 replaceAll、也避免正则转义问题。
 */
function replaceTermIgnoreCase(text: string, term: string, standard: string): string {
  const needle: string = term.toLowerCase();
  let out: string = '';
  let cursor: number = 0;
  let from: number = 0;
  let guard: number = 0;
  while (from < text.length && guard < 256) {
    const at: number = text.toLowerCase().indexOf(needle, from);
    if (at < 0) {
      break;
    }
    out += text.substring(cursor, at) + standard;
    cursor = at + term.length;
    from = cursor;
    guard += 1;
  }
  return out + text.substring(cursor);
}

/**
 * 梗味改写：长词优先替换成标准中文，同时收集命中。
 * @param zh 中文原句
 * @returns rewrittenZh 标准中文改写；hits 按原文出现顺序
 */
export function rewriteMeme(zh: string): { rewrittenZh: string; hits: MemeHit[] } {
  let out: string = zh;
  const hits: MemeHit[] = [];
  const lowerZh: string = zh.toLowerCase();
  for (const entry of SORTED_TABLE) {
    const term: string = entry.term;
    const at: number = lowerZh.indexOf(term.toLowerCase());
    if (at < 0) {
      continue;
    }
    hits.push({ term, standard: entry.standard, slang: entry.slang, index: at });
    out = replaceTermIgnoreCase(out, term, entry.standard);
  }
  hits.sort((a: MemeHit, b: MemeHit): number => a.index - b.index);
  // 标准改写常以「了」收尾，原文后紧跟一个「了」时会叠成「了了」，折叠掉更自然。
  // 只在真有命中时做，避免「啊啊啊」这类原文被静默改写。
  if (hits.length > 0) {
    out = out.replace(/([了的啊])\1+/g, '$1');
  }
  return { rewrittenZh: out, hits };
}

/* ================= 英文脚手架（L2） ================= */

/** 片段里可忽略的汉语语气/结构助词（避免「了」这类尾缀被当成待翻译内容） */
const CHUNK_PARTICLES: string = '的了啊吧呢哦嘛啦呀哈嗯么们';

/** 片段是否含「实质内容」：去掉空白/标点/语气助词后仍有汉字，或含拉丁字母数字 */
function hasSubstantive(text: string): boolean {
  let cjk: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (isCjk(ch) && CHUNK_PARTICLES.indexOf(ch) < 0) {
      cjk += 1;
    }
  }
  if (cjk > 0) {
    return true;
  }
  return /[A-Za-z0-9]/.test(text);
}

/** 脚手架片段：文本 + 是否为占位符（占位符不改大小写、不补标点语义） */
interface ScaffoldPart {
  text: string;
  isPlaceholder: boolean;
}

/**
 * 拼英文脚手架：命中片段 → 英文俚语首选；其余实质中文 → [...]。
 *
 * 拼接规则（team-lead 定稿）：
 * - 每个俚语片段首字母大写；
 * - 前一片段以 . ? ! 结尾 → 只补一个空格；否则补「. 」；
 * - 占位符 [...] 原样、不改大小写；占位符后面接片段时**只补空格**（它不是一句句子）。
 * 目的：多梗输出是「以句号分隔的合法短句」，不再是空格硬拼的病句。
 */
function buildScaffold(zh: string, hits: MemeHit[]): string {
  const parts: ScaffoldPart[] = [];
  let cursor: number = 0;
  for (const hit of hits) {
    const at: number = hit.index;
    if (at > cursor) {
      const gap: string = zh.substring(cursor, at);
      if (hasSubstantive(gap)) {
        parts.push({ text: PLACEHOLDER, isPlaceholder: true });
      }
    }
    const slang: string = primarySlang(hit.slang);
    if (slang.length > 0) {
      parts.push({ text: slang, isPlaceholder: false });
    }
    cursor = at + hit.term.length;
  }
  if (cursor < zh.length) {
    const tail: string = zh.substring(cursor);
    if (hasSubstantive(tail)) {
      parts.push({ text: PLACEHOLDER, isPlaceholder: true });
    }
  }

  let out: string = '';
  for (let i: number = 0; i < parts.length; i++) {
    const part: ScaffoldPart = parts[i];
    const frag: string = part.isPlaceholder ? PLACEHOLDER : capitalizeFirst(part.text);
    if (i === 0) {
      out = frag;
      continue;
    }
    // 占位符不是句子：它后面只接空格，避免出现「[...]. Die of embarrassment」这种怪写法
    const prevIsPlaceholder: boolean = parts[i - 1].isPlaceholder;
    out += (prevIsPlaceholder || endsSentence(out)) ? ' ' : '. ';
    out += frag;
  }
  return out.trim();
}

/* ================= 整句库查找 ================= */

/** 精确命中：归一化后完全相等 */
function findPhrase(text: string): PhrasePair | null {
  const key: string = phraseKey(text);
  if (key.length === 0) {
    return null;
  }
  for (const pair of PHRASE_BANK) {
    if (phraseKey(pair.zh) === key) {
      return pair;
    }
  }
  return null;
}

/**
 * 近似命中：句库条目是输入的一段（或输入是条目的一段），取重叠最长的那条。
 *
 * 为什么需要它：精确比对要求用户把整句一字不差打出来，现实里几乎不可能。
 * 加了这层后，「为什么不能翻译」能匹配到库里的「为什么不能」，
 * 「今天好开心」能匹配到「好开心」—— 比弹「未识别」有用得多。
 *
 * 保守约束（避免瞎匹配）：
 * - 重叠长度至少 MIN_NEAR_LEN 个字；
 * - 重叠占较短一方比例至少 MIN_NEAR_RATIO，防止长句里蹭到半个词就出英文。
 */
const MIN_NEAR_LEN: number = 3;
const MIN_NEAR_RATIO: number = 0.5;

function findPhraseLoose(text: string): PhrasePair | null {
  const key: string = phraseKey(text);
  if (key.length < 2) {
    return null;
  }
  const raw: string = text.trim();
  let best: PhrasePair | null = null;
  let bestLen: number = 0;
  for (const pair of PHRASE_BANK) {
    const pk: string = phraseKey(pair.zh);
    const shorter: number = Math.min(pk.length, key.length);
    const longer: number = Math.max(pk.length, key.length);

    // 两字短条（好烦 / 心累 / 绝了）只认「整句开头或结尾」：
    // 「好烦，明天还要早起」该命中，「我不知道」不能命中「我不信」这种半截碰巧。
    if (pk.length < MIN_NEAR_LEN) {
      if (shorter <= bestLen) {
        continue;
      }
      if (raw.indexOf(pair.zh) === 0 || raw.lastIndexOf(pair.zh) === raw.length - pair.zh.length) {
        best = pair;
        bestLen = shorter;
      }
      continue;
    }

    const contained: boolean = key.indexOf(pk) >= 0 || pk.indexOf(key) >= 0;
    if (!contained || shorter <= bestLen || shorter / longer < MIN_NEAR_RATIO) {
      continue;
    }
    best = pair;
    bestLen = shorter;
  }
  return best;
}

/** 两个串的最长公共连续子串长度（封顶 cap，只为排序用，不必求全） */
function commonRun(a: string, b: string, cap: number): number {
  let best: number = 0;
  for (let i: number = 0; i < a.length; i++) {
    for (let j: number = 0; j < b.length; j++) {
      let k: number = 0;
      while (k < cap && i + k < a.length && j + k < b.length && a.charAt(i + k) === b.charAt(j + k)) {
        k++;
      }
      if (k > best) {
        best = k;
      }
    }
  }
  return best;
}

/** 完全没命中时，按最长公共子串挑 3 条最接近的中文句，供用户点选 */
function nearbyPhrases(text: string): string[] {
  const key: string = phraseKey(text);
  if (key.length === 0) {
    return [];
  }
  const scored: PhrasePair[] = [];
  const scores: number[] = [];
  for (const pair of PHRASE_BANK) {
    const pk: string = phraseKey(pair.zh);
    if (pk.length === 0) {
      continue;
    }
    const run: number = commonRun(key, pk, 8);
    if (run < 2) {
      continue;
    }
    scored.push(pair);
    scores.push(run);
  }
  // 插入排序（句库规模有限，避免 ArkTS 对 sort 比较器的额外约束）
  for (let i: number = 1; i < scored.length; i++) {
    const p: PhrasePair = scored[i];
    const s: number = scores[i];
    let j: number = i - 1;
    while (j >= 0 && scores[j] < s) {
      scored[j + 1] = scored[j];
      scores[j + 1] = scores[j];
      j--;
    }
    scored[j + 1] = p;
    scores[j + 1] = s;
  }
  const out: string[] = [];
  for (let i: number = 0; i < scored.length && out.length < 3; i++) {
    const zh: string = scored[i].zh;
    if (out.indexOf(zh) < 0) {
      out.push(zh);
    }
  }
  return out;
}

/* ================= 对外主入口 ================= */

/** 空结果工厂（统一各降级分支的字段，避免裸对象字面量散落） */
function emptyResult(
  mode: TranslateMode,
  rewrittenZh: string,
  message: string,
  suggestions?: string[]
): TranslateResult {
  const out: TranslateResult = {
    english: '',
    rewrittenZh,
    hits: [],
    mode,
    level: 'NONE',
    needsManual: true,
    message,
  };
  if (suggestions !== undefined) {
    // 未命中分支统一给数组（可能是空数组）：调用方不用再判 undefined，
    // 「没有相近说法」和「字段缺失」不必是两种状态。
    out.suggestions = suggestions;
  }
  return out;
}

/**
 * 离线翻译主入口。永不抛异常，失败/未识别都通过 level + message 表达。
 * @param zh   中文原句
 * @param rawMode 'MEME'（默认，梗味改写 + 脚手架）/ 'LITERAL'（只检测梗，不产出英文）
 */
export function translateOffline(zh: string, rawMode?: TranslateMode): TranslateResult {
  // 运行时兜底：调用方若从 JS 侧传了非法值，不污染 TranslateMode 契约
  const mode: TranslateMode = rawMode === 'LITERAL' ? 'LITERAL' : 'MEME';
  const text: string = zh.trim();
  if (text.length === 0) {
    return emptyResult(mode, '', '请先输入中文句子');
  }

  // 直译模式：不改写、不产出英文，只告诉用户这句里有几个梗
  if (mode === 'LITERAL') {
    const literalHits: MemeHit[] = detectHits(text);
    const msg: string = literalHits.length > 0
      ? '这句里有 ' + literalHits.length + ' 个梗词，直译模式不生成英文，请手动填写'
      : '未识别到梗词，请手动填写英文';
    return {
      english: '',
      rewrittenZh: zh, // 口径：直译模式返回原文（含首尾空白），不做任何改写
      hits: literalHits,
      mode,
      level: 'NONE',
      needsManual: true,
      message: msg,
    };
  }

  const normalized: string = normalizeZh(text);
  if (normalized.length === 0) {
    return emptyResult(mode, text, '未识别到有效中文内容，请手动填写英文');
  }

  // L1：整句精确命中（标点/空白不敏感）
  const phrase: PhrasePair | null = findPhrase(text);
  if (phrase !== null) {
    // 整句已有高质量英文，不再给脚手架提示，避免用户重复追加俚语
    return {
      english: phrase.en,
      rewrittenZh: phrase.zh,
      hits: [],
      mode,
      level: 'SENTENCE',
      needsManual: false,
      message: '整句已命中离线句库，可直接使用或手动润色',
      matchKind: 'exact',
    };
  }

  // L2：梗词表优先于「近似整句」。
  // 顺序很关键：「破防了社死」这类多梗句如果先走近似匹配，会命中开头的「破防了」
  // 然后只返回一句英文，把「社死」整个丢掉 —— 有梗时必须走脚手架，才能一词不落。
  const rewritten: { rewrittenZh: string; hits: MemeHit[] } = rewriteMeme(text);
  if (rewritten.hits.length > 0) {
    // L2：梗味脚手架（多梗以「. 」分隔成合法短句，见 buildScaffold 注释）
    const english: string = buildScaffold(text, rewritten.hits);
    const hitCount: number = rewritten.hits.length;
    return {
      english,
      rewrittenZh: rewritten.rewrittenZh,
      hits: rewritten.hits,
      mode,
      level: 'MEME',
      needsManual: true,
      message: '识别到 ' + hitCount + ' 个梗词，已生成英文脚手架，请手动润色',
    };
  }

  // L1.5：近似命中（句库条目是输入的一段，或反之）
  // 自由输入的常态：用户写的句子和库里的永远差几个字，没有这层就必然落空。
  const near: PhrasePair | null = findPhraseLoose(text);
  if (near !== null) {
    return {
      english: near.en,
      rewrittenZh: near.zh,
      hits: [],
      mode,
      level: 'SENTENCE',
      needsManual: false,
      message: '匹配到相近说法「' + near.zh + '」，可改成你自己的原意',
      matchKind: 'near',
    };
  }

  // L3：都没有 → 不编造英文，但给几条意思接近的让用户点选，别只丢一句「请手填」
  const suggestions: string[] = nearbyPhrases(text);
  const msg: string = suggestions.length > 0
    ? '离线库没有这句的现成英文，下面几条意思接近，点一条再改'
    : '离线库没有这句的现成英文，请手动填写，或换个更常见的说法';
  return emptyResult(mode, rewritten.rewrittenZh, msg, suggestions);
}
