/**
 * 本机邮箱账号表（accounts.json，全局区，不随账号分区切换）。
 *
 * 定位：没有服务端时的「可登录的多账号」。密码经盐化 SHA256 存哈希，不落明文。
 * 与华为账号的关系：华为账号是主通道（一键、免密码、已实名）；
 * 邮箱是本机兜底通道，适用于非华为账号、AGC 未配置、或用户拒绝授权的情况。
 *
 * 限制（必须在 UI 讲清）：账号表只在本机，换机后需重新注册，或用「导出/导入备份」迁移。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalStateFiles } from './LocalStateFiles';
import { isValidEmail } from '../model/AuthCore';
import {
  genSalt,
  hashPassword,
  sha256Hex,
  validatePassword,
  verifyPassword,
} from '../model/PasswordHash';

export const CHANNEL_EMAIL: string = 'email';

export interface AccountRecord {
  accountId: string;
  channel: string;
  email: string;
  name: string;
  salt: string;
  pwdHash: string;
  createdAt: number;
}

interface AccountTable {
  accounts: AccountRecord[];
}

export interface AccountResult {
  ok: boolean;
  message: string;
  record: AccountRecord | null;
}

function fail(message: string): AccountResult {
  return { ok: false, message, record: null };
}

/** 邮箱规范化：去空格、转小写（同一个人不会因为大小写变成两个账号） */
export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

/** accountId 由邮箱哈希派生，避免明文邮箱出现在目录名里 */
export function accountIdOf(email: string): string {
  return `email-${sha256Hex(normalizeEmail(email)).substring(0, 16)}`;
}

export class LocalAccountService {
  static readonly INSTANCE: LocalAccountService = new LocalAccountService();
  private static readonly FILE: string = 'accounts.json';

  private accounts: AccountRecord[] = [];
  private loaded: boolean = false;

  private constructor() {
  }

  attachContext(_context: common.Context): void {
    const raw: string | null = LocalStateFiles.readGlobal(LocalAccountService.FILE);
    this.accounts = [];
    this.loaded = true;
    if (raw === null) {
      return;
    }
    try {
      const table: AccountTable = JSON.parse(raw) as AccountTable;
      if (table.accounts !== undefined && table.accounts !== null) {
        this.accounts = table.accounts;
      }
    } catch (_e) {
      // 表损坏视为无账号，不影响华为登录
    }
  }

  private persist(): void {
    const table: AccountTable = { accounts: this.accounts };
    LocalStateFiles.writeGlobal(LocalAccountService.FILE, JSON.stringify(table));
  }

  list(): AccountRecord[] {
    return this.accounts;
  }

  findByEmail(email: string): AccountRecord | null {
    const target: string = normalizeEmail(email);
    for (const a of this.accounts) {
      if (a.email === target) {
        return a;
      }
    }
    return null;
  }

  /** 注册：只做本机登记，不发任何邮件 */
  register(email: string, password: string, name: string): AccountResult {
    hilog.info(0x0000, 'CihuiAccount', 'register start email=%{public}s', email);
    const mail: string = normalizeEmail(email);
    if (!isValidEmail(mail) || mail === '') {
      return fail('邮箱格式不正确');
    }
    const pwdError: string | null = validatePassword(password);
    if (pwdError !== null) {
      return fail(pwdError);
    }
    const nick: string = name.trim();
    if (nick === '') {
      return fail('请填写昵称');
    }
    if (this.findByEmail(mail) !== null) {
      return fail('该邮箱已注册，请直接登录');
    }
    const salt: string = genSalt();
    hilog.info(0x0000, 'CihuiAccount', 'salt ready, hashing');
    const record: AccountRecord = {
      accountId: accountIdOf(mail),
      channel: CHANNEL_EMAIL,
      email: mail,
      name: nick,
      salt,
      pwdHash: hashPassword(password, salt),
      createdAt: Date.now(),
    };
    hilog.info(0x0000, 'CihuiAccount', 'hash done id=%{public}s', record.accountId);
    this.accounts.push(record);
    this.persist();
    hilog.info(0x0000, 'CihuiAccount', 'persisted, total=%{public}d', this.accounts.length);
    return { ok: true, message: '注册成功', record };
  }

  /** 登录校验；成功返回账号记录（含昵称） */
  login(email: string, password: string): AccountResult {
    const record: AccountRecord | null = this.findByEmail(email);
    if (record === null) {
      return fail('该邮箱尚未注册');
    }
    if (!verifyPassword(password, record.salt, record.pwdHash)) {
      return fail('密码不正确');
    }
    return { ok: true, message: '登录成功', record };
  }

  /** 改密码（当前账号） */
  changePassword(email: string, oldPwd: string, newPwd: string): AccountResult {
    const record: AccountRecord | null = this.findByEmail(email);
    if (record === null) {
      return fail('账号不存在');
    }
    if (!verifyPassword(oldPwd, record.salt, record.pwdHash)) {
      return fail('原密码不正确');
    }
    const pwdError: string | null = validatePassword(newPwd);
    if (pwdError !== null) {
      return fail(pwdError);
    }
    record.salt = genSalt();
    record.pwdHash = hashPassword(newPwd, record.salt);
    this.persist();
    return { ok: true, message: '密码已更新', record };
  }

  /** 删除本机账号记录（学习数据分区仍保留，可重新注册同名邮箱前清理） */
  remove(email: string): void {
    const target: string = normalizeEmail(email);
    const next: AccountRecord[] = [];
    for (const a of this.accounts) {
      if (a.email !== target) {
        next.push(a);
      }
    }
    this.accounts = next;
    this.persist();
  }

  isReady(): boolean {
    return this.loaded;
  }
}
