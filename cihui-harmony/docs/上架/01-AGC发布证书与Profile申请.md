# 01 · AGC 发布证书与 Profile 申请指南

> 目标：拿到「发布证书 .cer」和「发布 Profile .p7b」两份材料。
> 前置：华为开发者账号已注册并完成**个人实名认证**（未实名先去 developer.huawei.com 完成）。
> 预计耗时：15 分钟操作，证书/Profile 即时下发。

## 已为你准备好的材料

| 材料 | 路径 | 用途 |
|---|---|---|
| 发布密钥库 | `F:\PORJECT\cihui-harmony\signing\release\cihui-release.p12` | 保管发布私钥，**切勿删除/外传** |
| 证书请求文件 | `F:\PORJECT\cihui-harmony\signing\release\cihui-release.csr` | 本指南上传到 AGC |

密钥库参数（已生成，供记录）：
- alias：`cihuirelease`
- 密钥算法：RSA 2048 / SHA256withRSA，有效期 100 年
- storepass / keypass：`（签名密码见本地密码管理，不入库）`
- 申请者信息：`CN=Zhang Yuwei, OU=Dev, O=Cihui, L=Zhaoqing, ST=Guangdong, C=CN`

> ⚠️ 假设标注：CSR 的申请者信息按实名拼音 "Zhang Yuwei" 填写。若你的账号实名认证使用的是其他姓名写法，在 AGC 申请证书时如遇"信息不一致"提示，需按实名信息重新生成 CSR（找我就行）。

## 第 1 步：AGC 创建应用（若已有可跳过）

1. 打开 [AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)，用开发者账号登录。
2. 「我的项目」→「添加项目」（项目名随意，如 "Cihui"）。
3. 项目内「添加应用」，填写：
   - **应用名称**：说词
   - **应用包名**：`com.cihui.word`（必须与工程 `AppScope/app.json5` 的 bundleName 完全一致）
   - **应用分类**：教育（可再细分到语言学习/背单词）
   - 设备形态：勾选 手机；平板/2in1 建议首版先不勾（见 03 号文档说明）
4. 创建完成后记下 **APP ID**（提审时会自动关联，无需手动填）。

## 第 2 步：申请发布证书

1. AGC 左侧或顶部入口：「证书、APP ID 与 Profile」（或旧版入口「用户与访问 → 证书」）。
2. 「证书」页签 → **「新增证书」**：
   - 证书名称：`cihui-release`（任意，便于识别）
   - 上传 CSR 文件：选择 `signing/release/cihui-release.csr`
3. 提交后华为签发，**下载得到 `xxx.cer` 发布证书**，保存到：
   `F:\PORJECT\cihui-harmony\signing\release\cihui-release.cer`

> 发布证书每个账号最多 1 个（每次生成会覆盖旧证书），有效期 1~3 年，到期需重新申请。

## 第 3 步：申请发布 Profile

1. 同页面切换到「Profile」页签 → **「添加 Profile」**：
   - 名称：`cihui-release-profile`
   - **类型：选择「发布」**（Debug/发布二选一，务必选发布）
   - 关联应用：勾选 `com.cihui.word`（说词）
   - 受限权限：说词的全部权限（网络/相机/麦克风/振动/后台提醒）均为 normal 级别，**无需勾选受限权限**（已核对华为权限列表）
   - 设备类型：按需勾选（跟随应用创建时的形态）
2. 提交后**下载得到 `xxx.p7b` 发布 Profile**，保存到：
   `F:\PORJECT\cihui-harmony\signing\release\cihui-release.p7b`

## 第 4 步：App 备案（重要：与 Profile 并行启动，周期最长）

按工信部要求，**提供互联网信息服务的 App 上架国内应用市场必须有 ICP/App 备案号**，AGC 提审时必须填写且备案的应用名称、包名须与 AGC 完全一致。

**说词是否需要备案，取决于云端功能现状（请先确认）：**
- **有**云词书/学习进度同步等联网服务 → 必须备案（走华为云通道，见下）
- 纯单机离线（声明 standalone，无任何联网内容服务）→ 无需备案，AGC 填"单机应用"即可

**备案流程（有云功能时）：**
1. 接入商选择**华为云**（服务器/云开发在哪家就在哪家备案；若说词用了 AGC 云开发，即走华为云）。
2. 备案需要**发布证书的公钥 + MD5 指纹**，所以必须先完成第 2 步拿到 `.cer`：
   ```
   keytool -printcert -file cihui-release.cer
   ```
   （记录 MD5 fingerprint，备案表单要填）
3. 华为云备案系统提交：主体信息（个人：身份证+人脸核验）、App 信息（名称「说词」、包名 com.cihui.word、平台选鸿蒙）、域名/接入信息、隐私政策、承诺书。
4. 周期 **7–20 个工作日**，免费。备案号下来后填入 AGC 应用信息。

> 💡 时间线建议：备案是全流程中耗时最长的一环，拿到 .cer 后**第一时间提交备案**，期间并行做 Profile、release 构建、材料准备。

## 完成标志

`signing/release/` 目录下三件套齐备：

```
cihui-release.p12   ← 私钥（已有）
cihui-release.cer   ← 发布证书（AGC 第 2 步下载）
cihui-release.p7b   ← 发布 Profile（AGC 第 3 步下载）
```

齐了之后，打开 **03 号文档**配置 release 签名并构建上架包。
