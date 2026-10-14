/**
 * 账号状态（F13 先落地最小形态：未登录 / 已登录两态供个人页与首页问候使用；
 * F14 在此基础上实现微信/QQ/注册登录、字段二级编辑与 LocalAuthService；
 * F15 接入云备份状态 cloudEnabled 与同步中/失败态）。
 *
 * 状态管理 V2：@ObservedV2 + @Trace，页面直接绑定单例 profile。
 * qa19 BUG-B：账号资料随学习数据一起自动落盘沙箱（profile.json），杀进程不丢登录。
 */
import { common } from '@kit.AbilityKit';
import { LocalStateFiles } from '../service/LocalStateFiles';

/** 账号资料持久化文件中的纯数据形态 */
interface ProfileSnapshot {
  name: string;
  phone: string;
  email: string;
  wechat: string;
  qq: string;
  avatarText: string;
  cloudEnabled: boolean;
}

/** 用户资料（F14 注册表单与账号二级编辑页同构） */
@ObservedV2
export class UserProfile {
  /** 昵称（必填） */
  @Trace name: string = '';
  /** 手机号（与邮箱至少填一个） */
  @Trace phone: string = '';
  /** 邮箱（与手机号至少填一个） */
  @Trace email: string = '';
  /** 微信号（选填） */
  @Trace wechat: string = '';
  /** QQ 号（QQ 登录绑定后出现） */
  @Trace qq: string = '';
  /** 头像字（昵称最后一个字） */
  @Trace avatarText: string = '';
  /** 云备份是否已开启（F15） */
  @Trace cloudEnabled: boolean = false;
}

/** 资料字段局部更新入参 */
export interface ProfilePatch {
  name?: string;
  phone?: string;
  email?: string;
  wechat?: string;
  qq?: string;
  cloudEnabled?: boolean;
}

@ObservedV2
export class AuthStore {
  static readonly INSTANCE: AuthStore = new AuthStore();
  private static readonly FILE: string = 'profile.json';
  @Trace profile: UserProfile | null = null;

  private constructor() {
  }

  /** qa19 BUG-B：启动时从沙箱读回登录资料 */
  attachContext(context: common.Context): void {
    LocalStateFiles.boot(context);
    const raw: string | null = LocalStateFiles.read(AuthStore.FILE);
    if (raw === null) {
      return;
    }
    try {
      const snap = JSON.parse(raw) as ProfileSnapshot;
      const p: UserProfile = new UserProfile();
      p.name = snap.name;
      p.phone = snap.phone;
      p.email = snap.email;
      p.wechat = snap.wechat;
      p.qq = snap.qq;
      p.avatarText = snap.avatarText;
      p.cloudEnabled = snap.cloudEnabled;
      this.profile = p;
    } catch (_e) {
      // 损坏资料忽略，保持未登录
    }
  }

  private persist(): void {
    if (this.profile === null) {
      LocalStateFiles.remove(AuthStore.FILE);
      return;
    }
    const p: UserProfile = this.profile;
    const snap: ProfileSnapshot = {
      name: p.name,
      phone: p.phone,
      email: p.email,
      wechat: p.wechat,
      qq: p.qq,
      avatarText: p.avatarText,
      cloudEnabled: p.cloudEnabled,
    };
    LocalStateFiles.write(AuthStore.FILE, JSON.stringify(snap));
  }

  isLoggedIn(): boolean {
    return this.profile !== null;
  }

  /** F14 注册/第三方登录成功后调用 */
  login(profile: UserProfile): void {
    if (profile.avatarText === '' && profile.name !== '') {
      profile.avatarText = profile.name.charAt(profile.name.length - 1);
    }
    this.profile = profile;
    this.persist();
  }

  /** F14 账号二级页保存字段 */
  updateProfile(patch: ProfilePatch): void {
    if (this.profile === null) {
      return;
    }
    const p: UserProfile = this.profile;
    if (patch.name !== undefined) {
      p.name = patch.name;
      p.avatarText = patch.name !== '' ? patch.name.charAt(patch.name.length - 1) : '';
    }
    if (patch.phone !== undefined) {
      p.phone = patch.phone;
    }
    if (patch.email !== undefined) {
      p.email = patch.email;
    }
    if (patch.wechat !== undefined) {
      p.wechat = patch.wechat;
    }
    if (patch.qq !== undefined) {
      p.qq = patch.qq;
    }
    if (patch.cloudEnabled !== undefined) {
      p.cloudEnabled = patch.cloudEnabled;
    }
    this.profile = p;
    this.persist();
  }

  logout(): void {
    this.profile = null;
    this.persist();
  }
}
