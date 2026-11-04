/**
 * F14+ 华为账号登录（Account Kit，客户端直登，**零后端**）。
 *
 * 为什么用它取代原来的微信/QQ 演示登录：
 * - `openid` / `profile` 两个 scope **均无需在 AGC 申请权限审批**，
 *   客户端授权后即可拿到 unionID / openID，无需服务端换 token；
 * - 华为账号已实名，天然满足国内应用的实名要求；
 * - 华为应用市场 UX 规范强制要求使用官方 LoginWithHuaweiIDButton，不得自绘按钮；
 * - 零服务端、零短信费、零 ICP 备案。
 *
 * 前置条件（AGC 控制台，缺任一项会报 1001500001 / 1001502002）：
 * 1. 创建应用，包名 com.cihui.word；
 * 2. 上传签名证书指纹（与 release 签名 .cer 一致）；
 * 3. 开启「华为账号」服务。
 *
 * 安全边界：unionID 仅作本机账号分区键使用，不用于任何服务端鉴权
 * （本项目当前无后端），因此不校验 idToken 签名。
 */
import { loginComponentManager } from '@kit.AccountKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 登录通道 */
export const CHANNEL_HUAWEI: string = 'huawei';
export const CHANNEL_LOCAL: string = 'local';

export interface HuaweiAuthResult {
  ok: boolean;
  /** 跨应用唯一用户标识；失败时为空串 */
  unionID: string;
  message: string;
}

function fail(message: string): HuaweiAuthResult {
  return { ok: false, unionID: '', message };
}

export class AccountKitService {
  static readonly INSTANCE: AccountKitService = new AccountKitService();

  private constructor() {
  }

  /**
   * 从 LoginWithHuaweiIDButton 回调里拿到的凭据转为账号标识。
   * 注意 HuaweiIDCredential 不包含昵称/头像，昵称由调用方按 unionID 派生。
   */
  fromCredential(cred: loginComponentManager.HuaweiIDCredential | null): HuaweiAuthResult {
    if (cred === null || cred === undefined) {
      return fail('登录已取消');
    }
    const unionID: string = cred.unionID;
    if (unionID === undefined || unionID === null || unionID === '') {
      return fail('未获取到华为账号标识，请重试');
    }
    return { ok: true, unionID, message: '登录成功' };
  }

  /** 把 Account Kit 错误码翻译成用户能看懂的话 */
  describeError(err: BusinessError | null): string {
    if (err === null || err === undefined) {
      return '登录失败，请重试';
    }
    const code: number = err.code;
    if (code === 1001502001) {
      return '请先在系统设置中登录华为账号';
    }
    if (code === 1001500003) {
      // 非中国境内注册的华为账号不支持 openid scope
      return '当前华为账号地区暂不支持，请改用手机号或邮箱登录';
    }
    if (code === 1001500001) {
      return '应用签名校验失败，请安装正式版本';
    }
    if (code === 1001502002) {
      return '华为账号服务未开通，请稍后重试';
    }
    if (code === 1001500002) {
      return '登录请求处理中，请稍候';
    }
    if (code === 1001502003) {
      // module.json5 未配置 client_id，或与 AGC 的 OAuth 2.0 客户端 ID 不一致
      return '应用未在 AGC 完成配置（Client ID 缺失），请改用手机号或邮箱登录';
    }
    if (code === 1001502014) {
      return '账号权限未配置，请改用手机号或邮箱登录';
    }
    if (code === 1001500004) {
      return '网络异常，请检查网络后重试';
    }
    const msg: string = err.message !== undefined && err.message !== '' ? err.message : `错误码 ${code}`;
    return `登录失败：${msg}`;
  }

  /** 默认昵称：华为用户 + unionID 末四位（凭据里没有昵称字段） */
  defaultNickname(unionID: string): string {
    const tail: string = unionID.length >= 4 ? unionID.substring(unionID.length - 4) : unionID;
    return `华为用户${tail}`;
  }
}
