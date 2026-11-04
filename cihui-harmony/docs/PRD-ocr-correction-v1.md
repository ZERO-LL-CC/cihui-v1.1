# PRD：拍照 OCR 词书约束纠错 V1.0

> 状态：待开发 ｜ 作者：team-lead ｜ 日期：2026-11-02
> 实测依据：畅享 90 真机 HMS textRecognition 输出 + PC 复现评测（见「验收标准」），数据与策略均经实测验证，非推测。

## 1. 背景与目标

- 【事实】拍照 OCR（F3→F4 链路，HMS textRecognition）对手写词表裸识别准确率仅 72%（89 词命中 64）。
- 【事实】错误模式集中为"形近字替换"（witter/writer、caracity/capacity、lompel/compel）。
- 【事实】用"并集词库 + 加权编辑距离 + 词频排序"纠错后，同一批数据实测 **95.5%**（85/89），较裸识别 +23.5pp。
- 【事实】词书按版本划分导致单一词书缺词（cet4.json 仅 3846 词，elegant/fossil 等在 cet6.json）→ 纠错候选必须用并集。
- 目标：F4 校对页展示前，对 OCR 英文词条做词书约束纠错；无法纠出的词条标"!"提醒用户手改。

## 2. 用户与场景

| 角色 | 场景 | 触发时机 | 来源 |
|---|---|---|---|
| 背词用户 | 拍手写词表 → 校对页 → 导入词本 | F3 拍照完成进入 F4 时 | 【事实】 |

## 3. 需求列表

| ID | 需求 | 优先级 |
|---|---|---|
| F-1 | 纠错词库资产（并集 7413 词 + ecdict 词频排名）——**已完成**，见 rawfile/ocr_correction/wordbank.json | 必须有 |
| F-2 | OcrCorrector 纯 TS 匹配器：加权编辑距离全场扫描 | 必须有 |
| F-3 | OcrParser.parseOcrLines 集成纠错，OcrDraft 增加 suspect 标记 | 必须有 |
| F-4 | F4 校对页 suspect 词条显示"!"徽标，用户编辑该行英文后徽标消失 | 必须有 |
| F-5 | Node 单测：用真实 OCR 输出 fixture 验证 ≥84/89 | 必须有 |
| F-6 | 词书顺序对齐消歧义（cue/dim/writer 类） | 暂不做（V2） |
| F-7 | 气泡选词路径（tokenizeEnglishWords）纠错 | 暂不做（V2） |

## 4. 流程

### 4.1 主流程
1. F3 拍照识别完成（现有 OcrService.recognize 不动）→ 2. F4 aboutToAppear 调 parseOcrLines(lines, corrector) → 3. 每行英文 head 经 corrector：词库直命中 → 原样返回；有候选 ≤ 阈值 → 返回纠正词；无候选 → 保留原文并置 suspect=true → 4. 校对页渲染，suspect 行英文输入框旁显示"!"徽标 → 5. 用户改词（onChange）清除该行 suspect。

### 4.2 分支
- 英文 head 是词组（≤3 词）：不做纠错，原样返回（词库只有单词）。
- 纠正结果与原文相同（大小写差异）：不置 suspect，按原样。

### 4.3 异常
- wordbank.json 加载失败：纠错整体停用（corrector 返回原文、不置 suspect），行为与现状一致，不阻塞导入。
- 纠错耗时超预算：全场扫描前先按长度差 ≤2 剪枝；若单页 50 词纠错实测超 500ms，再加首字母分桶优化（允许）。

## 5. 数据模型

### 5.1 wordbank.json（已生成，212KB）
```json
{ "version": 1, "count": 7413,
  "words": [{ "w": "apple", "f": 821 }, ...] }
```
- `w`：小写单词；`f`：ecdict bnc/frq 的最小排名，**越小越常用**，缺失=999999。

### 5.2 OcrDraft（OcrParser.ts）
| 字段 | 类型 | 必填 | 规则 |
|---|---|---|---|
| english | string | 是 | 纠错后的词条（纠正不改大小写风格，仅内容） |
| suspect | boolean | 是 | true=纠错失败（损毁/词库外），UI 标"!" |

### 5.3 算法常量（与 PC 实测一致，勿改动）
- 混淆对（替换代价 0.45，对称）：w-v, i-l, c-e, u-v, o-a, m-n, h-n, r-n, t-f, g-q, b-h, d-cl, i-r
- 普通替换 1.0；插入/删除 0.9
- 长度差 >3 直接判不匹配；候选门槛：加权距离 ≤ 2.0
- 同分排序：词频排名小者胜（⚠️ 排名越小越常用，不要写反）
- 词库直命中（小写比较）→ 不纠错不标记

## 6. 集成点（现有代码，勿重构）

- `entry/src/main/ets/service/OcrParser.ts`：parseOcrLines 增加可选第二参 `correct?: (english: string) => CorrectResult`，在 `const english: string = headMatch[1].trim()` 之后应用；CorrectResult = { english: string; suspect: boolean }。
- `entry/src/main/ets/service/OcrCorrector.ts`（新建，纯 .ts）：init(resourceManager) 异步读 wordbank.json → 内存 Map；correct(token) 同步纯函数。
- `entry/src/main/ets/pages/camera/OcrReviewPage.ets`：ReviewRow 增加 @Trace suspect；RowCard 英文行尾显示"!"圆徽标（orange 底白字，参考现有"补录中文"徽标样式）；TextInput.onChange 时置 row.suspect = false。corrector 未初始化时传 undefined（降级）。
- OcrService / OcrService.recognize 不动。

## 7. 验收标准

| ID | 验收（给定 X 应得 Y） | 可判定 |
|---|---|---|
| F-2 | 给定 token "caracity" 应得 "capacity"；"witter" 允许得 "wither"（已知歧义，用户手改）；"inspsrnatton" 应 suspect=true 且原文保留 | 是 |
| F-2 | 给定 "cue"/"dim"（本身是合法词）应原样返回且 suspect=false | 是 |
| F-3 | 给定 fixture（tests-node/fixtures/hms-out_pageAB.txt，取自 _trocr_spike/demo/out_hms.txt）+ GT（见 fixtures/gt.json），parseOcrLines+corrector 应命中 ≥ 84/89 | 是 |
| F-4 | 真机 F3→F4：suspect 行显示"!"；用户修改英文后徽标消失 | 是 |
| F-5 | node tests 全绿（cd tests-node && npm test 或 node --test） | 是 |
| 全局 | _build61.ps1 构建成功 + hdc 安装成功 + F3 拍照→F4 全流程可用 | 是 |
| 性能 | 单页 50 词纠错 ≤ 500ms（console.time 打点实测） | 是 |

## 8. 测试数据位置（只读引用，勿改动）

- 真实 HMS 输出行：`F:/PORJECT/_trocr_spike/demo/out_hms.txt`（格式 `PAGE_X <text>`）
- 词书并集源：`entry/src/main/resources/rawfile/cloudbooks/*.json`
- 词频源：`F:/PORJECT/cihui-harmony/_ecdict/ecdict.csv`
- PC 参考实现：`F:/PORJECT/_trocr_spike/eval_hms_v2.py`（常量以本文档 §5.3 为准）

## Next Steps
1. software-engineer 按 §5/§6 实现 + Node 单测 + 构建装机。
2. software-qa-engineer 独立验证 fixture 命中数与真机流程。
3. 用户真机自测体验。
