import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  emptyRegisterForm,
  isValidEmail,
  isValidPhone,
  validateFieldEdit,
  validateRegister,
} from '../Cihui/entry/src/main/ets/model/AuthCore.ts';
import type { RegisterForm } from '../Cihui/entry/src/main/ets/model/AuthCore.ts';

function form(p: Partial<RegisterForm>): RegisterForm {
  return { ...emptyRegisterForm(), ...p };
}

test('F14 注册校验：名称为空被拦截', () => {
  const e = validateRegister(form({ phone: '13800138000' }));
  assert.notEqual(e, null);
  assert.equal(e!.field, 'name');
});

test('F14 注册校验：手机和邮箱都缺被拦截', () => {
  const e = validateRegister(form({ name: '俞蔚' }));
  assert.notEqual(e, null);
  assert.equal(e!.field, 'phone');
});

test('F14 注册校验：手机号非 11 位 / 非法号段被拦截', () => {
  assert.equal(validateRegister(form({ name: '俞蔚', phone: '123456' }))!.field, 'phone');
  assert.equal(validateRegister(form({ name: '俞蔚', phone: '23800138000' }))!.field, 'phone');
  assert.equal(validateRegister(form({ name: '俞蔚', phone: '1380013800a' }))!.field, 'phone');
  assert.ok(isValidPhone('13800138000'));
  assert.ok(!isValidPhone('12800138000'));
});

test('F14 注册校验：邮箱格式错误被拦截，合法通过', () => {
  assert.equal(validateRegister(form({ name: '俞蔚', email: 'abc@' }))!.field, 'email');
  assert.equal(validateRegister(form({ name: '俞蔚', email: 'a@b' }))!.field, 'email');
  assert.ok(isValidEmail('zhang.yw@example.com'));
  assert.ok(isValidEmail('a_b+test@sub.example.cn'));
  assert.ok(!isValidEmail('a b@example.com'));
});

test('F14 注册校验：合法表单（仅手机 / 仅邮箱 / 全填）通过', () => {
  assert.equal(validateRegister(form({ name: '俞蔚', phone: '13800138000' })), null);
  assert.equal(validateRegister(form({ name: '俞蔚', email: 'a@b.com' })), null);
  assert.equal(validateRegister(form({
    name: '俞蔚', phone: '13800138000', email: 'a@b.com', wechat: 'wxid_1',
  })), null);
});

test('F14 字段编辑：昵称不能为空', () => {
  const cur = form({ name: '俞蔚', phone: '13800138000' });
  assert.equal(validateFieldEdit('name', '   ', cur)!.field, 'name');
  assert.equal(validateFieldEdit('name', '小蔚', cur), null);
});

test('F14 字段编辑：清空手机号但邮箱在，允许；两者都空拦截', () => {
  const withEmail = form({ name: '俞蔚', phone: '13800138000', email: 'a@b.com' });
  assert.equal(validateFieldEdit('phone', '', withEmail), null);
  const noEmail = form({ name: '俞蔚', phone: '13800138000' });
  assert.equal(validateFieldEdit('phone', '', noEmail)!.field, 'phone');
});

test('F14 字段编辑：手机 / 邮箱格式错误拦截，微信选填可清空', () => {
  const cur = form({ name: '俞蔚', phone: '13800138000', email: 'a@b.com' });
  assert.equal(validateFieldEdit('phone', '123', cur)!.field, 'phone');
  assert.equal(validateFieldEdit('email', 'bad', cur)!.field, 'email');
  assert.equal(validateFieldEdit('wechat', '', cur), null);
});
