/**
 * F14 账号纯逻辑：邮箱注册 / 字段编辑校验（可 Node 单测，不依赖 ArkUI）。
 *
 * 规则（2026-11 调整：手机号验证码暂不做，改邮箱 + 密码为主通道）：
 * - 昵称必填；
 * - 邮箱必填且格式正确（本机账号的唯一标识）；
 * - 密码至少 6 位、不能全同字符（校验细节在 PasswordHash.validatePassword）；
 * - 手机号 / 微信 / QQ 为选填资料，可在账号页补填。
 *
 * 华为账号登录不走这里（一键授权，无表单）。
 */
import { validatePassword } from './PasswordHash';

export type AccountField = 'name' | 'phone' | 'email' | 'wechat' | 'qq' | 'password';

export interface RegisterForm {
  name: string;
  email: string;
  password: string;
}

export interface FieldError {
  field: AccountField;
  message: string;
}

export function emptyRegisterForm(): RegisterForm {
  return { name: '', email: '', password: '' };
}

export function isValidPhone(v: string): boolean {
  if (v === '') {
    return true; // 选填
  }
  return /^1[3-9]\d{9}$/.test(v.trim());
}

export function isValidEmail(v: string): boolean {
  if (v === '') {
    return true;
  }
  const s: string = v.trim();
  if (s.length > 128) {
    return false;
  }
  return /^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/.test(s);
}

/** 注册表单校验：返回第一个错误；全部通过返回 null */
export function validateRegister(form: RegisterForm): FieldError | null {
  if (form.name.trim() === '') {
    return { field: 'name', message: '请填写昵称' };
  }
  if (form.email.trim() === '') {
    return { field: 'email', message: '请填写邮箱' };
  }
  if (!isValidEmail(form.email)) {
    return { field: 'email', message: '邮箱格式不正确' };
  }
  if (form.password === '') {
    return { field: 'password', message: '请设置密码' };
  }
  const pwdError: string | null = validatePassword(form.password);
  if (pwdError !== null) {
    return { field: 'password', message: pwdError };
  }
  return null;
}

/** 登录表单校验（邮箱 + 密码） */
export function validateLogin(email: string, password: string): FieldError | null {
  if (email.trim() === '') {
    return { field: 'email', message: '请填写邮箱' };
  }
  if (!isValidEmail(email)) {
    return { field: 'email', message: '邮箱格式不正确' };
  }
  if (password === '') {
    return { field: 'password', message: '请填写密码' };
  }
  return null;
}

/**
 * 账号页字段编辑校验。
 * 邮箱是账号标识，不允许清空；手机号 / 微信 / QQ 选填。
 */
export function validateFieldEdit(
  field: AccountField,
  rawValue: string,
  current: RegisterForm,
): FieldError | null {
  const value: string = rawValue.trim();
  if (field === 'name') {
    if (value === '') {
      return { field, message: '昵称不能为空' };
    }
    return null;
  }
  if (field === 'email') {
    if (value === '') {
      return { field, message: '邮箱是账号标识，不能清空' };
    }
    if (!isValidEmail(value)) {
      return { field, message: '邮箱格式不正确' };
    }
    return null;
  }
  if (field === 'phone') {
    if (value !== '' && !isValidPhone(value)) {
      return { field, message: '请输入正确的 11 位手机号' };
    }
    return null;
  }
  // wechat / qq 选填，不做格式限制
  return null;
}
