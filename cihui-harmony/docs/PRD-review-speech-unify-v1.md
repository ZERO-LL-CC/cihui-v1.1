# PRD F19 · 复习类统一语音快过（删除闪卡 ReviewCardsPage）

## 背景

用户反馈：「错题卡好像还是闪卡的背单词。统一用一套。但是这个直接语音快过就行。」

- 新词流程已经是「看词浏览 → 语音快过」（SpeechTestPage，ASR 读词判定）。
- 复习类三种模式却走独立的闪卡页 ReviewCardsPage.ets（768 行，翻面三档判定）：
  - `REVIEW` 到期复习、`WRONG` 错词强化、`MAKEUP` 补卡
- 目标：复习类统一复用 SpeechTestPage 的语音快过交互，**删除闪卡页**，记账语义与现闪卡完全一致。

## 现状关键事实（已核实）

- 记账：ReviewCardsPage.ets:309 `applyVerdict` → `DataStore.INSTANCE.applyJudge(wordId, 'REVIEW', verdict)`（实时逐张落库）。WRONG 模式判认识会按「重新首过」推进到 R1（applyJudge 内部处理）。
- VAGUE 语义：闪卡 planNext(L299)——模糊词移到队尾本轮重考。
- WRONG 特殊行为：L330 判模糊先翻面看中文再判（语音场景无翻面，此行为废弃）；L351 toast：UNKNOWN → wrongMode ? '已安排明天重新背' : '已加入错词本'。
- MAKEUP 完成特殊逻辑：L692-694 `completeMakeup(makeupDay)` + 文案 '完成，同步计划表'。
- SpeechTestPage 现状：
  - `SpeechRouteParam`（RouteNames.ets:74）：wordIds/chunk/groupIndex/groupTotal/retest/batchIndex/batchTotal —— **无复习模式概念**。
  - confirmRound(L737) 一律 `applyFirstRound(verdicts)`（新词口径）→ chunk=true 走新词会话 → 结束后把 `todayReviewWordList()` 转 push REVIEW_CARDS（L780/799）。
- REVIEW_CARDS 全部引用点（全工程 grep，.bak 不算）：
  1. `pages/tab/HomePage.ets:206`（REVIEW）
  2. `pages/tab/CheckInPage.ets:444`（REVIEW）
  3. `pages/study/WrongBookPage.ets:112-113`（WRONG，title '错词强化复习'）
  4. `pages/plan/MakeupDetailPage.ets:110-117`（MAKEUP，makeupDay 必填）
  5. `pages/study/SpeechTestPage.ets:782、801`（新学完成转 REVIEW）
  6. `common/RouteNames.ets:30`（枚举）+ `pages/Index.ets:141`（页面注册）
- 语音判定输出：ASR pass→KNOWN / fail→UNKNOWN；手动模式有三档（manualJudge KNOWN/VAGUE/UNKNOWN）——三档语义与闪卡对齐可用。

## 改造方案

### 1. SpeechRouteParam 扩展（RouteNames.ets）

```ts
export interface SpeechRouteParam {
  // ...现有字段不动...
  /** 复习模式：'REVIEW' | 'WRONG' | 'MAKEUP'。缺省=新词流程（现行为不变） */
  reviewMode?: string;
  /** MAKEUP 必填：补卡日 yyyy-mm-dd */
  makeupDay?: string;
  /** 复习模式页顶标题（到期复习/错词强化复习/x月x日 补卡） */
  title?: string;
}
```
注意：页面内已有 `mode`（'asr'|'manual'）局部状态，**不要**用同名参数。

### 2. SpeechTestPage 支持复习模式

`aboutToAppear` 读到 `param.reviewMode` 非空时进入复习分支：
- 载词：与现逻辑相同（wordIds → DataStore.words 匹配），跳过新词会话/草稿桶的 chunk 关联（`StudySessionStore`、`RoundDraftStore.SPEECH` 的 chunk 相关逻辑不参与；断点草稿可复用 SPEECH 桶但需在草稿中持久化 reviewMode/makeupDay，恢复时优先按草稿 reviewMode 走分支——若现有草稿 schema 不便扩展，可 simplest：复习模式不支持断点恢复，进入即全新一轮，退出即丢弃。二选一，工程师定，PRD 验收只要求不崩溃不串数据）。
- 交互：直接进语音 round（错词强化等复习类**不需要**浏览环节）。ASR 判定 pass=KNOWN；读不出/读错进复核清单（现有 phase='review' 机制），复核可手动三档。
- VAGUE 语义：复习模式下模糊词**移到队尾本轮重考**（对齐闪卡 planNext），而不是留在复核清单。
- 记账：**不用 applyFirstRound**。confirmRound 时对每个词 `DataStore.INSTANCE.applyJudge(wordId, 'REVIEW', verdict)`（与闪卡同口径，逐词调用）。判完的 toast 文案对齐闪卡：UNKNOWN → reviewMode==='WRONG' ? '已安排明天重新背' : '已加入错词本'。
- 完成分支：
  - `MAKEUP`：`DataStore.INSTANCE.completeMakeup(makeupDay)` + toast '补卡词本已过完，已同步计划表' → finishToHome。
  - `REVIEW`：toast '本轮复习完成' → finishToHome。
  - `WRONG`：toast '错词强化完成' → finishToHome。
  - 复习模式**不执行** L775-805 的「todayReviewWordList 转 REVIEW_CARDS」链式逻辑（防自我递归）。
  - 不走 StudySessionStore.finishStep。
- pageTitle：reviewMode 时优先用 param.title；无 title 则 '语音复习'。

### 3. 入口改造（6 处）

全部改为 push `RouteName.SPEECH_TEST`，构造含 reviewMode 的 SpeechRouteParam：
1. HomePage.ets:206 → `{ wordIds: ids, reviewMode: 'REVIEW', title: '到期复习' }`
2. CheckInPage.ets:444 → 同上
3. WrongBookPage.ets:112 → `{ wordIds: ids, reviewMode: 'WRONG', title: '错词强化复习' }`
4. MakeupDetailPage.ets:110 → `{ wordIds: ids, reviewMode: 'MAKEUP', makeupDay: this.param.day, title: \`${this.dayLabel()} 补卡\` }`
5. SpeechTestPage.ets:782、801 → 新学完成转复习处改为 `{ wordIds: ids, reviewMode: 'REVIEW', title: '到期复习' }`，保持原 finishToHome + push 导航行为不变

### 4. 删除闪卡

- 删除 `pages/study/ReviewCardsPage.ets`（整文件）。
- RouteNames.ets：删 `REVIEW_CARDS` 枚举与 `ReviewRouteParam` 接口（确认无其他引用后）。
- Index.ets:141：删对应注册分支与 import。
- `pages/tab/CheckInPage.ui1318.bak.ets` 是备份不参与编译，**不动**。

## 验收标准

1. 全工程 grep `REVIEW_CARDS|ReviewRouteParam` 命中 0（CheckInPage.ui1318.bak.ets 除外）。
2. 错词本 →「开始错词强化复习」：直接进语音快过（无闪卡/无翻面），读词判定 + 手动三档兜底，VAGUE 队尾重考；判完错词本记账与原闪卡一致（WRONG 判认识推进调度）。
3. 到期复习（首页/打卡页）、补卡（计划表补卡日）同样直接进语音快过；补卡完成后计划表正确同步（completeMakeup）。
4. 新词流程回归不受影响：浏览→分组语音测试→模糊重考→会话推进全链路行为不变（现有 node 测试全绿：scheduler 133 / speech-match 63 / meaning-fix 90 / ocr-parser 35 等）。
5. 复习中途退出不崩溃；无断点恢复时重新进入为全新一轮（可接受）。
6. 真机构建成功（`_build61.ps1`），实机冒烟：错词复习一轮 + 到期复习一轮。

## 边界与注意

- `applyJudge` 的幂等性/重复调用行为需先确认（若不幂等，confirmRound 统一落库要防重）。
- 复习模式与 `chunk`、`retest` 参数互斥；参数同时出现时 reviewMode 优先并忽略会话逻辑。
- 语音引擎不可用时：现有 SpeechTestPage 已有手动三档兜底（mode 切 manual），复习模式直接复用，不额外造轮子。
