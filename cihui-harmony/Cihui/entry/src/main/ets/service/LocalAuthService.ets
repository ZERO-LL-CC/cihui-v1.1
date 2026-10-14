/**
 * F14 账号服务：统一 AuthService 接口 + 本地模拟实现。
 *
 * ⚠️ 微信 / QQ 一键登录的真实授权需要开放平台注册、App 资质、原生 SDK 与后端，
 *    本期没有凭证：loginByThird 生成本机演示账号跑通登录闭环，
 *    UI 明确标注「演示登录」，禁止声称已完成真实授权（资质与 SDK 接入列入待核验清单）。
 * 本地注册 / 登录 / 字段编辑 / 退出全部走 AuthStore 内存态跑通；
 * 退出登录会清空本机学习数据（无后端，账号间不共享内存仓库）；
 * F15 在此接口上扩展云备份与多端资料同步。
 */
import { AuthStore, UserProfile } from '../viewmodel/AuthStore';
import { SyncStore } from '../viewmodel/SyncStore';
import { DataStore } from '../viewmodel/DataStore';
import {
  emptyRegisterForm,
  validateFieldEdit,
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
  loginByThird(channel: string): AuthResult;
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

  isLoggedIn(): boolean {
    return this.store.isLoggedIn();
  }

  register(form: RegisterForm): AuthResult {
    const error: FieldError | null = validateRegister(form);
    if (error !== null) {
      return fail(error.message, error);
    }
    const profile: UserProfile = new UserProfile();
    profile.name = form.name.trim();
    profile.phone = form.phone.trim();
    profile.email = form.email.trim();
    profile.wechat = form.wechat.trim();
    // F15：注册即开启云备份（首次本地备份由注册页在登录后静默触发）
    profile.cloudEnabled = true;
    this.store.login(profile);
    return success('登录成功');
  }

  loginByThird(channel: string): AuthResult {
    // TODO(F14+)：接入微信开放平台 / 腾讯互联 QQ SDK（需 App 资质、appid、签名、授权回调与后端）。
    // 本期无凭证：生成本机演示账号，把登录后的全部页面闭环跑通；UI 标注为演示登录。
    const isWechat: boolean = channel === 'wechat';
    const label: string = isWechat ? '微信' : 'QQ';
    const suffix: string = `${Math.floor(1000 + Math.random() * 9000)}`;
    const profile: UserProfile = new UserProfile();
    profile.name = `${isWechat ? '微信用户' : 'QQ用户'}${suffix}`;
    if (isWechat) {
      profile.wechat = `wx_demo_${suffix}`;
    } else {
      profile.qq = suffix;
    }
    // 演示第三方登录没有云端资料，不默认开启云备份，避免与 F15 文案冲突
    profile.cloudEnabled = false;
    this.store.login(profile);
    return success(`${label}演示登录成功`);
  }

  updateField(field: AccountField, value: string): AuthResult {
    if (this.store.profile === null) {
      return fail('尚未登录', null);
    }
    const p = this.store.profile;
    const current: RegisterForm = {
      name: p.name,
      phone: p.phone,
      email: p.email,
      wechat: p.wechat,
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

  logout(): void {
    this.store.logout();
    SyncStore.INSTANCE.reset();
    // P4/P5：本期无后端，学习数据是本机内存仓库，不随账号隔离；
    // 退出即清空，避免 A 账号打卡/学习进度被新账号看到。需要保留请先导出备份 JSON。
    DataStore.INSTANCE.resetLearningData();
  }

  /** 注册页初始值（已登录预填场景复用） */
  emptyForm(): RegisterForm {
    return emptyRegisterForm();
  }
}
