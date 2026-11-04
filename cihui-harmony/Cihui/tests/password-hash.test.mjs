/**
 * 密码哈希单测：与 node:crypto 逐字节对照，确保纯 JS SHA256 实现正确。
 * 跑法：node --import ./tests/register-loader.mjs tests/password-hash.test.mjs
 */
import { createHash } from 'node:crypto';
import {
  sha256Hex, genSalt, hashPassword, verifyPassword, validatePassword,
} from '../entry/src/main/ets/model/PasswordHash.ts';

let pass = 0;
let fail = 0;

function eq(name, actual, expected) {
  if (actual === expected) {
    pass++;
  } else {
    fail++;
    console.log(`FAIL ${name}\n  expect: ${expected}\n  actual: ${actual}`);
  }
}

function ok(name, cond) {
  if (cond) {
    pass++;
  } else {
    fail++;
    console.log(`FAIL ${name}`);
  }
}

/* ---------- 1. 与 node:crypto 对照 ---------- */
const vectors = [
  '',
  'a',
  'abc',
  'password',
  'abcdefghijklmnopqrstuvwxyz',
  'The quick brown fox jumps over the lazy dog',
  // 长度落在 padding 边界上：55/56/63/64/65 字节
  'a'.repeat(55),
  'a'.repeat(56),
  'a'.repeat(63),
  'a'.repeat(64),
  'a'.repeat(65),
  'a'.repeat(119),
  'a'.repeat(120),
  // 中文（3 字节 UTF-8）
  '密码',
  '说词单词学习软件',
  // emoji（4 字节，surrogate pair）
  '🔐',
  'a🔐b',
];
for (const v of vectors) {
  const name = v.length > 24 ? `sha256(len=${v.length})` : `sha256(${JSON.stringify(v)})`;
  eq(name, sha256Hex(v), createHash('sha256').update(v, 'utf8').digest('hex'));
}

/* ---------- 2. 盐与哈希 ---------- */
const s1 = genSalt();
const s2 = genSalt();
eq('salt 长度 32 hex', String(s1.length), '32');
ok('salt 每次不同', s1 !== s2);
ok('salt 全 hex', /^[0-9a-f]{32}$/.test(s1));

const h1 = hashPassword('abc123', s1);
const h2 = hashPassword('abc123', s2);
ok('同密码不同盐 → 不同哈希', h1 !== h2);
eq('同密码同盐 → 稳定', hashPassword('abc123', s1), h1);
eq('哈希 64 hex', String(h1.length), '64');
eq('哈希与 node 对照',
  h1, createHash('sha256').update(`${s1}:abc123`, 'utf8').digest('hex'));

/* ---------- 3. 校验 ---------- */
ok('正确密码通过', verifyPassword('abc123', s1, h1));
ok('错误密码拒绝', !verifyPassword('abc124', s1, h1));
ok('空密码拒绝', !verifyPassword('', s1, h1));
ok('大小写敏感', !verifyPassword('ABC123', s1, h1));
ok('空盐拒绝', !verifyPassword('abc123', '', h1));
ok('空哈希拒绝', !verifyPassword('abc123', s1, ''));
ok('大写哈希也能校验', verifyPassword('abc123', s1, h1.toUpperCase()));

/* ---------- 4. 密码强度 ---------- */
eq('6 位通过', validatePassword('abc123'), null);
eq('5 位拒绝', validatePassword('abc12'), '密码至少 6 位');
eq('全同字符拒绝', validatePassword('aaaaaa'), '密码过于简单');
eq('65 位拒绝', validatePassword('a'.repeat(65)), '密码过长');
eq('64 位通过', validatePassword('a'.repeat(63) + 'b'), null);
eq('中文密码通过', validatePassword('我的密码123'), null);

/* ---------- 5. 性能：本地登录不能卡 ---------- */
const t0 = Date.now();
for (let i = 0; i < 100; i++) {
  hashPassword(`pwd${i}`, s1);
}
const cost = Date.now() - t0;
ok(`100 次哈希 < 300ms（实测 ${cost}ms）`, cost < 300);

console.log(`\npassword-hash: ${pass} passed, ${fail} failed`);
if (fail > 0) {
  process.exit(1);
}
