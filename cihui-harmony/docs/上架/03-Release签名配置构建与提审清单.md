# 03 · Release 签名配置、构建与提审清单

> 前置：已完成 01 号文档，`signing/release/` 下三件套齐备（.p12/.cer/.p7b）。
> 目标：产出可上传 AGC 的 `.app` 上架包，并备齐提审材料。

## 第 1 步：配置 release 签名

用 DevEco Studio 打开工程 `F:\PORJECT\cihui-harmony\Cihui`：

**方式 A（推荐，图形化）**：`File → Project Structure → Signing Configs`，新建签名配置：
- Signing Config 名称：`release`
- 选择「手动签名」，类型 HarmonyOS
- Certificate file：`signing/release/cihui-release.cer`
- Profile file：`signing/release/cihui-release.p7b`
- Key store：`signing/release/cihui-release.p12`（密码 `（签名密码见本地密码管理，不入库）`，alias `cihuirelease`）

**方式 B（手工编辑）**：在 `build-profile.json5` 的 `signingConfigs` 数组中追加（保持现有 `default` 调试配置不动，两者可共存）：

```json5
{
  "name": "release",
  "type": "HarmonyOS",
  "material": {
    "certpath": "F:/PORJECT/cihui-harmony/signing/release/cihui-release.cer",
    "profile": "F:/PORJECT/cihui-harmony/signing/release/cihui-release.p7b",
    "keyAlias": "cihuirelease",
    "keyPassword": "<自动生成后填入>",
    "signAlg": "SHA256withECDSA",
    "storeFile": "F:/PORJECT/cihui-harmony/signing/release/cihui-release.p12",
    "storePassword": "<自动生成后填入>"
  }
}
```

> 方式 B 的密码字段在 DevEco 里保存后会加密处理；手工明文填 `（签名密码见本地密码管理，不入库）` 也可工作（与现有 debug 配置同等待遇）。

## 第 2 步：构建上架包（.app）

1. 菜单 `Build → Build App(s)`（**注意：不是 Build Hap(s)**），构建模式选 **release**。
2. 产物位置：`Cihui/entry/build/default/outputs/release/` 下的 `.app` 文件（包名内嵌版本号）。
3. 体积参考：当前工程若超过 4GB 需裁剪（一般单词应用远低于此）。

**上传前自检（强烈建议）**：
- 用 release 包真机安装一遍（`hdc install` 或 AGC「开放测试」），全流程跑通再提审
- 确认启动无白屏/闪退、打卡提醒能正常到达

## 第 3 步：提审材料清单

| 材料 | 状态 | 说明 |
|---|---|---|
| release 签名 `.app` 包 | 按本文档生成 | — |
| **App 备案号（ICP备案核准）** | ❓ 取决于云功能 | 有云词书/同步 → 必须备案（免费，7–20 工作日，见 01 文档第 4 步）；纯单机 → 填"单机应用"免备案 |
| 应用截图（手机） | 素材已有，需筛选 | 至少 3 张，`device_*.jpeg` 可整理，注意不含 dev 调试页 |
| 应用图标（分层） | ✅ 工程已有 | `layered_image`，AGC 需单独上传同款图标 |
| 应用名称/一句话简介/详细描述 | ❌ 待写 | 分类建议：教育 → 语言学习 |
| **隐私政策 URL** | ❌ 待托管 | 正文用 02 号文档；可托管到 GitHub Pages / Gitee Pages，或让我帮你发布成在线链接 |
| 版本说明 | ❌ 待写 | 首版写核心功能即可 |
| 软著证书（可选加分） | ⚠️ 待决策 | 现有软著材料名为「词慧单词学习软件」，应用已改名「说词」——要么同步改名重新生成材料（脚本可复用），要么放弃名称加分仅作代码版权证明 |

## 第 4 步：提交审核

AGC「我的应用 → 说词 → 版本管理 → 提交版本审核」，上传 `.app`、填材料、提交。个人开发者首次提审一般 1–3 个工作日出结果，可在控制台看进度。

## ⚠️ 已识别的提审风险（提审前必须处理）

**0. 应用名称撞名/相似 → ✅ 已决策：改名「说词」（2026-11-04）**

原名称「词慧」与市场已有应用「词慧谊桥」（成都谊桥，多语词典，疑似华为市场在架）存在前缀子串+同类目相似风险，且华为名称一年限改 2 次。

**已执行改名「说词」**（查重通过：市场无同名/近似中文应用，最接近的「说说提词器」类目不同、名称不相似）：
- 工程内用户可见文案已全部替换（app_name / EntryAbility_label / 通知 / 分享语 / 备份文件名前缀），代码注释保留旧称不影响产物
- 包名 `com.cihui.word` **保持不变**（技术标识，不参与名称审核，改动会连累签名与云服务配置）
- 遗留动作：AGC 创建应用时名称填「说词」；软著材料是否同步改名见下方清单

**1. dev 探测页暴露在正式路由中**
`main_pages.json` 注册了 `pages/dev/TrOcrProbePage` 和 `pages/dev/HmsOcrProbePage`，它们是可达页面。审核若随机进入，会看到未完成的调试界面。
处理方案（二选一）：
- **方案 A（推荐）**：上架版把两页从 `main_pages.json` 移除，代码留在工程里不删
- **方案 B**：入口加开发者开关保护（仅特定手势/内部版本可见）

**2. 平板/2in1 形态声明**
`module.json5` 声明了 `deviceTypes: ["phone", "tablet", "2in1"]`，但 AGC 应用创建时可先只勾「手机」。若要同时上平板形态，需额外验证大屏布局并提供平板截图。**建议首版只上手机，过审后再扩展形态**（改动很小：只改 AGC 勾选 + module.json5 不必动）。

**3. AIGC 类目附加审核（待确认例句生成实现方式）**
华为对"生成式 AI/深度合成类应用"（含篇章生成、文本风格转换等场景）要求额外材料：**算法备案截图、安全评估报告、AI 生成内容标识**。
判断点：词慧「每日例句-整段生成」功能——
- 若例句为**本地模板拼接/词库匹配**（非生成式模型）→ 不属于 AIGC 类目，无需附加材料，但应用介绍中避免使用"AI 生成"等宣传措辞引起误判
- 若调用/内置**生成式模型**生成文本 → 按 AIGC 类目准备材料，或在提审备注中说明技术实现以争取常规通道
⚠️ 此项需开发者确认实现方式后定论。

## 防复发备忘

- 发布证书有效期 1–3 年，到期前 AGC 会通知，重申后需重新构建签名包
- 私钥 `.p12` 唯一且不可补办 → **务必异地备份一份**（U 盘/私有网盘均可）
- versionCode 当前 1010200（v1.1.2），提审版本只需递增，不可复用历史值
