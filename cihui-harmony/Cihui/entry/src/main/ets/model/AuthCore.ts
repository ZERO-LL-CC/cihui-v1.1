/**
 * F14 账号纯逻辑：注册 / 字段编辑校验（可 Node 单测，不依赖 ArkUI）。
 * 规则来自功能卡 F14：
 * - 名称必填；
 * - 手机号、邮箱至少填一项；
 * - 手机号必须为 11 位大陆手机号（1 开头，第二位 3–9）；
 * - 邮箱格式错误拦截；
 * - 微信选填。
 */

export type AccountField = 'name' | 'phone' | 'email' | 'wechat' | 'qq';

export interface RegisterForm {
  name: string;
  phone: string;
  email: string;
  wechat: string;
}

export interface FieldError {
  field: AccountField;
  message: string;
}

export function emptyRegisterForm(): RegisterForm {
  return { name: '', phone: '', email: '', wechat: '' };
}

export function isValidPhone(v: string): boolean {
  if (v === '') {
    return true; // 空值由「手机/邮箱至少一项」规则处理
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
    return { field: 'name', message: '请填写名称' };
  }
  if (form.phone.trim() === '' && form.email.trim() === '') {
    return { field: 'phone', message: '手机号和邮箱至少填写一项' };
  }
  if (form.phone.trim() !== '' && !isValidPhone(form.phone)) {
    return { field: 'phone', message: '请输入正确的 11 位手机号' };
  }
  if (form.email.trim() !== '' && !isValidEmail(form.email)) {
    return { field: 'email', message: '邮箱格式不正确' };
  }
  return null;
}

/**
 * 账号页字段编辑校验。
 * current 为编辑前的完整资料（phone/email 至少一项的跨字段约束需要它）。
 */
export function validateFieldEdit(
  field: AccountField,
  rawValue: string,
  current: RegisterForm,
): FieldError | null {
  const value: string = rawValue.trim();
  if (field === 'name') {
    if (value === '') {
      return { field, message: '名称不能为空' };
    }
    return null;
  }
  if (field === 'phone') {
    if (value !== '' && !isValidPhone(value)) {
      return { field, message: '请输入正确的 11 位手机号' };
    }
    if (value === '' && current.email.trim() === '') {
      return { field, message: '手机号和邮箱至少保留一项' };
    }
    return null;
  }
  if (field === 'email') {
    if (value !== '' && !isValidEmail(value)) {
      return { field, message: '邮箱格式不正确' };
    }
    if (value === '' && current.phone.trim() === '') {
      return { field, message: '手机号和邮箱至少保留一项' };
    }
    return null;
  }
  // wechat / qq 选填，不做格式限制
  return null;
}
