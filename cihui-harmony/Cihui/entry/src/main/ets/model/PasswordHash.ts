/**
 * 密码哈希（纯 JS SHA256，可 Node 单测，不依赖系统 crypto 的异步接口）。
 *
 * 本机邮箱账号没有服务端，密码只能存在本地；因此：
 * - 每个账号独立 16 字节随机盐；
 * - 落盘只存 sha256(salt + password) 的十六进制串，绝不存明文；
 * - 校验用等值比较（本地场景 TiMing attack 不构成实际威胁）。
 *
 * 不引入 PBKDF2/bcrypt 的理由：本机 Offline、攻击者拿到沙箱已能读全部学习数据，
 * 加盐哈希的收益是「不泄露用户常用密码明文」，不需要抗 GPU 爆破。
 */

const K: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

function rotr(x: number, n: number): number {
  return ((x >>> n) | (x << (32 - n))) >>> 0;
}

/** UTF-8 编码；surrogate pair 按 4 字节处理 */
function utf8Bytes(s: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const c2: number = s.charCodeAt(i + 1);
      const cp: number = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
      out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      i++;
    } else {
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
  }
  return out;
}

function hex32(v: number): string {
  return (v >>> 0).toString(16).padStart(8, '0');
}

export function sha256Hex(msg: string): string {
  const bytes: number[] = utf8Bytes(msg);
  const bitLen: number = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) {
    bytes.push(0);
  }
  // 64 位大端长度（密码长度远小于 2^32 位，高 32 位恒为 0）
  const hi: number = Math.floor(bitLen / 4294967296);
  const lo: number = bitLen % 4294967296;
  bytes.push((hi >>> 24) & 255, (hi >>> 16) & 255, (hi >>> 8) & 255, hi & 255);
  bytes.push((lo >>> 24) & 255, (lo >>> 16) & 255, (lo >>> 8) & 255, lo & 255);

  let h0: number = 0x6a09e667;
  let h1: number = 0xbb67ae85;
  let h2: number = 0x3c6ef372;
  let h3: number = 0xa54ff53a;
  let h4: number = 0x510e527f;
  let h5: number = 0x9b05688c;
  let h6: number = 0x1f83d9ab;
  let h7: number = 0x5be0cd19;

  const w: number[] = new Array<number>(64);
  for (let off = 0; off < bytes.length; off += 64) {
    for (let i = 0; i < 16; i++) {
      const p: number = off + i * 4;
      w[i] = ((bytes[p] << 24) | (bytes[p + 1] << 16) | (bytes[p + 2] << 8) | bytes[p + 3]) >>> 0;
    }
    for (let i = 16; i < 64; i++) {
      const x: number = w[i - 15];
      const y: number = w[i - 2];
      const s0: number = (rotr(x, 7) ^ rotr(x, 18) ^ (x >>> 3)) >>> 0;
      const s1: number = (rotr(y, 17) ^ rotr(y, 19) ^ (y >>> 10)) >>> 0;
      w[i] = (((w[i - 16] + s0) >>> 0) + ((w[i - 7] + s1) >>> 0)) >>> 0;
    }

    let a: number = h0;
    let b: number = h1;
    let c: number = h2;
    let d: number = h3;
    let e: number = h4;
    let f: number = h5;
    let g: number = h6;
    let h: number = h7;

    for (let i = 0; i < 64; i++) {
      const S1: number = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0;
      const ch: number = ((e & f) ^ (~e & g)) >>> 0;
      const t1: number = (((h + S1) >>> 0) + ((ch + K[i]) >>> 0) + w[i]) >>> 0;
      const S0: number = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0;
      const maj: number = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
      const t2: number = (((S0 + maj) >>> 0)) >>> 0;

      h = g;
      g = f;
      f = e;
      e = ((d + t1) >>> 0);
      d = c;
      c = b;
      b = a;
      a = ((t1 + t2) >>> 0);
    }

    h0 = ((h0 + a) >>> 0);
    h1 = ((h1 + b) >>> 0);
    h2 = ((h2 + c) >>> 0);
    h3 = ((h3 + d) >>> 0);
    h4 = ((h4 + e) >>> 0);
    h5 = ((h5 + f) >>> 0);
    h6 = ((h6 + g) >>> 0);
    h7 = ((h7 + h) >>> 0);
  }

  return hex32(h0) + hex32(h1) + hex32(h2) + hex32(h3)
    + hex32(h4) + hex32(h5) + hex32(h6) + hex32(h7);
}

const SALT_HEX_LEN: number = 16;

/** 生成 16 字节随机盐（hex 串）；用 Math.random 兜底，避免依赖系统 RNG */
export function genSalt(): string {
  let s: string = '';
  for (let i = 0; i < SALT_HEX_LEN; i++) {
    s += Math.floor(Math.random() * 256).toString(16).padStart(2, '0');
  }
  return s;
}

/** 落盘用：sha256(salt + password) */
export function hashPassword(password: string, salt: string): string {
  return sha256Hex(`${salt}:${password}`);
}

/** 登录校验 */
export function verifyPassword(password: string, salt: string, expected: string): boolean {
  if (salt === '' || expected === '') {
    return false;
  }
  return hashPassword(password, salt) === expected.toLowerCase();
}

/** 密码强度：至少 6 位，不能全是同一字符（弱口令底线，不做复杂度堆砌） */
export function validatePassword(pwd: string): string | null {
  if (pwd.length < 6) {
    return '密码至少 6 位';
  }
  if (pwd.length > 64) {
    return '密码过长';
  }
  let same: boolean = true;
  for (let i = 1; i < pwd.length; i++) {
    if (pwd.charAt(i) !== pwd.charAt(0)) {
      same = false;
      break;
    }
  }
  if (same) {
    return '密码过于简单';
  }
  return null;
}
