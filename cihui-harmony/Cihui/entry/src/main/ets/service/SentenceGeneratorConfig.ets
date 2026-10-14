/**
 * F19 大模型例句生成 · 集中配置（方案 A：客户端常量，参赛/MVP）
 *
 * 【安全说明 · 上架前必读】
 * 1. 把 DOUBAO_API_KEY 填上你在火山方舟控制台创建的 Key；同时务必在火山控制台
 *    给该 Key 绑定月度用量上限（预算告警/限额），防止反编译盗刷，这是方案 A 的兜底；
 * 2. 正式上架前应迁移到方案 B：AGC 云函数代理，Key 只存云端，本文件常量置空，
 *    页面与 SentenceGeneratorService 接口都不用改，只换实现类；
 * 3. 禁止把 Key 写进 hilog / 错误 Toast / 崩溃上报，错误信息只透传 HTTP 状态码。
 *
 * 模型字段 DOUBAO_MODEL 可填模型 ID（如当前的 lite 版本）或在线推理接入点 Endpoint ID（ep-xxxx）。
 * 接口为火山方舟 OpenAI 兼容地址，官方文档：火山方舟 → 调用指南。
 */

/** 火山方舟 OpenAI 兼容对话接口 */
export const DOUBAO_ENDPOINT: string = 'https://ark.cn-beijing.volces.com/api/v3/chat/completions';

/**
 * 火山方舟 API Key（控制台「API Key 管理」创建，名称 cihui-word-app，仅存客户端用于参赛/MVP 演示）。
 * 已在火山控制台开通 Doubao-Seed-2.0-lite 并开启「安心体验」：免费额度耗尽自动暂停、不产生费用。
 * 留空时 TodaySentencePage 整条链路直接走本地释义降级，不会发起任何网络请求。
 * 上架前必须迁移方案 B（AGC 云函数代理）并把此常量置空。
 */
export const DOUBAO_API_KEY: string = '';

/** lite 模型 ID（轻量、有免费额度，造句足够）；也可换成自己的 ep-xxxx 接入点 */
export const DOUBAO_MODEL: string = 'doubao-seed-2-0-lite-260215';

/** 单次请求连接/读取超时（毫秒）。真机弱网/蜂窝下 10s 易误报“检查网络”，放宽到 20s */
export const SENTENCE_TIMEOUT_MS: number = 20000;

/** 解析失败 / 网络失败后的自动重试次数（不含首次） */
export const SENTENCE_MAX_RETRY: number = 1;
