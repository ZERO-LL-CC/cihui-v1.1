/**
 * F14 账号服务：统一 AuthService 接口 + 本机实现。
 *
 * 三条通道：
 * - 华为账号（主）：Account Kit 客户端直取 unionID，零后端零密码；
 * - 邮箱 + 密码（兜底）：本机 accounts.json 存盐化哈希，不发邮件；
 * - 旧版本地账号：profile.json 里已有、但不在账号表中的老用户，允许继续用设备。
 *
 * 微信 / QQ 一键登录需企业资质与开放平台审核，个人开发者走不通，已下线。
 *
 * 账号切换与数据隔离：每个账号落到 files/cihui/state/u/<accountId>/ 独立分区，
 * 退出登录**不再清空学习数据**——切回上一个账号即可看到原有进度。
 */
import { AuthStore, UserProfile } from '../viewmodel/AuthStore';
import { SyncStore } from '../viewmodel/SyncStore';
import { DataStore } from '../viewmodel/DataStore';
import { LocalStateFiles, GUEST_ACCOUNT } from './LocalStateFiles';
import { LocalAccountService, AccountRecord, CHANNEL_EMAIL } from './LocalAccountService';
import { AccountKitService, CHANNEL_HUAWEI, CHANNEL_LOCAL } from './AccountKitService';
import {
  emptyRegisterForm,
  validateFieldEdit,
  validateLogin,
  validateRegister,
} from '../model/AuthCore';
import type { AccountField, FieldError, RegisterForm } from '../model/AuthCore';

export interface AuthResult {
  ok: boolean;
  message: string;
  error: FieldError | null;
}

export interface AuthService {
  isLoggedIn(): boolean;
  register(form: RegisterForm): AuthResult;
  loginByEmail(email: string, password: string): AuthResult;
  loginByHuawei(unionID: string): AuthResult;
  updateField(field: AccountField, value: string): AuthResult;
  logout(): void;
}

function fail(message: string, error: FieldError | null): AuthResult {
  return { ok: false, message, error };
}

function success(message: string): AuthResult {
  return { ok: true, message, error: null };
}

export class LocalAuthService implements AuthService {
  static readonly INSTANCE: LocalAuthService = new LocalAuthService();
  private store: AuthStore = AuthStore.INSTANCE;

  private constructor() {
  }

  /** 切换到目标账号的数据分区，并让 DataStore 重读该分区 */
  private activate(accountId: string): void {
    LocalStateFiles.bindAccount(accountId === '' ? GUEST_ACCOUNT : accountId);
    DataStore.INSTANCE.reload();
  }

  /** 已登录其他账号时拒绝切换，避免把 B 的进度写进 A 的分区 */
  private blockedByOther(accountId: string): AuthResult | null {
    const cur: UserProfile | null = this.store.profile;
    if (cur !== null && cur.accountId !== '' && cur.accountId !== accountId) {
      return fail('当前已登录其他账号，请先退出后再登录', null);
    }
    return null;
  }

  isLoggedIn(): boolean {
    return this.store.isLoggedIn();
  }

  /** 邮箱注册（不发邮件，纯本机登记） */
  register(form: RegisterForm): AuthResult {
    const error: FieldError | null = validateRegister(form);
    if (error !== null) {
      return fail(error.message, error);
    }
    const r = LocalAccountService.INSTANCE.register(form.email, form.password, form.name);
    if (!r.ok || r.record === null) {
      return fail(r.message, null);
    }
    const blocked: AuthResult | null = this.blockedByOther(r.record.accountId);
    if (blocked !== null) {
      return blocked;
    }
    const profile: UserProfile = new UserProfile();
    profile.name = r.record.name;
    profile.email = r.record.email;
    profile.accountId = r.record.accountId;
    profile.loginChannel = CHANNEL_EMAIL;
    profile.cloudEnabled = true;
    this.store.login(profile);
    this.activate(r.record.accountId);
    return success('注册成功');
  }

  /** 邮箱 + 密码登录 */
  loginByEmail(email: string, password: string): AuthResult {
    const error: FieldError | null = validateLogin(email, password);
    if (error !== null) {
      return fail(error.message, error);
    }
    const r = LocalAccountService.INSTANCE.login(email, password);
    if (!r.ok || r.record === null) {
      return fail(r.message, null);
    }
    const blocked: AuthResult | null = this.blockedByOther(r.record.accountId);
    if (blocked !== null) {
      return blocked;
    }
    const profile: UserProfile = new UserProfile();
    profile.name = r.record.name;
    profile.email = r.record.email;
    profile.accountId = r.record.accountId;
    profile.loginChannel = CHANNEL_EMAIL;
    profile.cloudEnabled = true;
    this.store.login(profile);
    this.activate(r.record.accountId);
    return success('登录成功');
  }

  /** 华为账号登录（Account Kit 拿到的 unionID 直接当账号标识，无后端） */
  loginByHuawei(unionID: string): AuthResult {
    if (unionID === '') {
      return fail('未获取到华为账号标识，请重试', null);
    }
    const blocked: AuthResult | null = this.blockedByOther(unionID);
    if (blocked !== null) {
      return blocked;
    }
    const profile: UserProfile = new UserProfile();
    profile.accountId = unionID;
    profile.loginChannel = CHANNEL_HUAWEI;
    profile.name = AccountKitService.INSTANCE.defaultNickname(unionID);
    profile.cloudEnabled = true;
    this.store.login(profile);
    this.activate(unionID);
    return success('登录成功');
  }

  updateField(field: AccountField, value: string): AuthResult {
    const p: UserProfile | null = this.store.profile;
    if (p === null) {
      return fail('尚未登录', null);
    }
    const current: RegisterForm = {
      name: p.name,
      email: p.email,
      password: '',
    };
    const error: FieldError | null = validateFieldEdit(field, value, current);
    if (error !== null) {
      return fail(error.message, error);
    }
    const v: string = value.trim();
    if (field === 'name') {
      this.store.updateProfile({ name: v });
    } else if (field === 'phone') {
      this.store.updateProfile({ phone: v });
    } else if (field === 'email') {
      this.store.updateProfile({ email: v });
    } else if (field === 'wechat') {
      this.store.updateProfile({ wechat: v });
    } else if (field === 'qq') {
      this.store.updateProfile({ qq: v });
    }
    return success('已保存');
  }

  /**
   * 退出登录：切回未登录分区，**不清空原账号数据**。
   * 重新登录同一账号即可恢复原有词本与进度。
   */
  logout(): void {
    this.store.logout();
    SyncStore.INSTANCE.reset();
    this.activate(GUEST_ACCOUNT);
  }

  /** 注册页初始值 */
  emptyForm(): RegisterForm {
    return emptyRegisterForm();
  }

  /** 当前账号在本机账号表中的记录（华为账号无记录，返回 null） */
  currentRecord(): AccountRecord | null {
    const p: UserProfile | null = this.store.profile;
    if (p === null || p.email === '') {
      return null;
    }
    return LocalAccountService.INSTANCE.findByEmail(p.email);
  }
}
