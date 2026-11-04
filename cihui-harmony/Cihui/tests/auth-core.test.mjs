/**
 * 邮箱账号校验单测（Node 直跑纯逻辑，无需真机）。
 * 跑法：node --import ./tests/register-loader.mjs tests/auth-core.test.mjs
 */
import {
  emptyRegisterForm, isValidEmail, isValidPhone,
  validateFieldEdit, validateLogin, validateRegister,
} from '../entry/src/main/ets/model/AuthCore.ts';

let pass = 0;
let fail = 0;

function eq(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    pass++;
  } else {
    fail++;
    console.log(`FAIL ${name}\n  expect: ${e}\n  actual: ${a}`);
  }
}

/* ---------- 空表单 ---------- */
eq('空表单结构', emptyRegisterForm(), { name: '', email: '', password: '' });

/* ---------- 邮箱格式 ---------- */
const goodMails = [
  'a@b.cn', 'aze@cihui.app', 'first.last+tag@sub.example.com',
  'user_name@mail.example.org.cn',
];
for (const m of goodMails) {
  eq(`合法邮箱 ${m}`, isValidEmail(m), true);
}
const badMails = [
  'a@b', '@b.com', 'a@.com', 'a b@c.com', 'a@@b.com',
  'a@b..com', '中文@b.com', 'a@b.c',
];
for (const m of badMails) {
  eq(`非法邮箱 ${m}`, isValidEmail(m), false);
}
eq('空邮箱放行（由必填规则处理）', isValidEmail(''), true);
eq('超长邮箱拒绝', isValidEmail('a'.repeat(130) + '@b.com'), false);

/* ---------- 手机号（选填，仍要格式对） ---------- */
eq('合法手机号', isValidPhone('13800138000'), true);
eq('空手机号放行', isValidPhone(''), true);
eq('10 位拒绝', isValidPhone('1380013800'), false);
eq('12 开头拒绝', isValidPhone('12800138000'), false);

/* ---------- 注册校验 ---------- */
const base = { name: '阿泽', email: 'aze@cihui.app', password: 'cihui2026' };
eq('完整表单通过', validateRegister(base), null);
eq('缺昵称', validateRegister({ ...base, name: '  ' }),
  { field: 'name', message: '请填写昵称' });
eq('缺邮箱', validateRegister({ ...base, email: '' }),
  { field: 'email', message: '请填写邮箱' });
eq('邮箱格式错', validateRegister({ ...base, email: 'aze@' }),
  { field: 'email', message: '邮箱格式不正确' });
eq('缺密码', validateRegister({ ...base, password: '' }),
  { field: 'password', message: '请设置密码' });
eq('密码太短', validateRegister({ ...base, password: '12345' }),
  { field: 'password', message: '密码至少 6 位' });
eq('密码全同', validateRegister({ ...base, password: 'aaaaaa' }),
  { field: 'password', message: '密码过于简单' });

/* ---------- 登录校验 ---------- */
eq('登录通过', validateLogin('aze@cihui.app', 'cihui2026'), null);
eq('登录缺邮箱', validateLogin('', 'x'),
  { field: 'email', message: '请填写邮箱' });
eq('登录邮箱格式错', validateLogin('aze', 'x'),
  { field: 'email', message: '邮箱格式不正确' });
eq('登录缺密码', validateLogin('aze@cihui.app', ''),
  { field: 'password', message: '请填写密码' });

/* ---------- 账号页字段编辑 ---------- */
const cur = { name: '阿泽', email: 'aze@cihui.app', password: '' };
eq('改昵称通过', validateFieldEdit('name', '小泽', cur), null);
eq('昵称清空拒绝', validateFieldEdit('name', '  ', cur),
  { field: 'name', message: '昵称不能为空' });
eq('邮箱不能清空', validateFieldEdit('email', '', cur),
  { field: 'email', message: '邮箱是账号标识，不能清空' });
eq('邮箱格式错', validateFieldEdit('email', 'bad', cur),
  { field: 'email', message: '邮箱格式不正确' });
eq('手机号可清空', validateFieldEdit('phone', '', cur), null);
eq('手机号格式错', validateFieldEdit('phone', '123', cur),
  { field: 'phone', message: '请输入正确的 11 位手机号' });
eq('微信随意填', validateFieldEdit('wechat', '随便', cur), null);

console.log(`\nauth-core: ${pass} passed, ${fail} failed`);
if (fail > 0) {
  process.exit(1);
}
