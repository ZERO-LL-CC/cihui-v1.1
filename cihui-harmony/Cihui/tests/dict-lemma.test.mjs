/**
 * 词慧 F17「卡片背面必须有中文」Node 原生测试（零 npm 依赖）。
 * 运行：node --experimental-strip-types --no-warnings --import ./tests/register-loader.mjs tests/dict-lemma.test.mjs
 *
 * 覆盖：
 * A. 词典文件结构：原形数、alias 索引、alias 指向的原形必须真实存在
 * B. 真机暴露的缺席词全部可解析（shattered / gets / executed / done / hooked ...）
 * C. lemmaCandidates 规则还原：过去式/分词/三单/复数/比较级/副词/名词化
 * D. 保守性：不返回入参自身、短词不还原、不规则表优先
 * E. 梗表全部 slang 词的释义覆盖率（低于阈值即失败，防止词典回退）
 * F. 三级查找口径等价实现（L1 直接 → L2 alias → L3 规则）与 LocalDictService 保持一致
 */
import fs from 'node:fs';
import path from 'node:path';
import { lemmaCandidates, IRREGULAR } from '../entry/src/main/ets/model/LemmaCore.ts';
import { MEME_TABLE, primarySlang } from '../entry/src/main/ets/model/OfflineTranslateCore.ts';
import { tokenizeEnglish } from '../entry/src/main/ets/model/MemeCore.ts';

/* ============ 微型断言器 ============ */
let passed = 0;
let failed = 0;
const failures = [];
function check(cond, msg) {
  if (cond) {
    passed += 1;
  } else {
    failed += 1;
    failures.push(msg);
    console.error('  ✗ ' + msg);
  }
}
function group(name) {
  console.log('\n' + name);
}

/* ============ 载入词典（与服务端同口径） ============ */
const DICT_PATH = path.resolve(
  import.meta.dirname,
  '../entry/src/main/resources/rawfile/dict/ecdict-lite.json'
);
const raw = JSON.parse(fs.readFileSync(DICT_PATH, 'utf-8'));
const words = new Map();
for (const it of raw.words) {
  const k = it.w.trim().toLowerCase();
  if (k.length > 0 && !words.has(k)) {
    words.set(k, { phonetic: it.p, meaning: it.m });
  }
}
const alias = new Map();
for (const [k, v] of Object.entries(raw.alias || {})) {
  const key = k.trim().toLowerCase();
  if (key.length > 0 && !words.has(key)) {
    alias.set(key, String(v).trim().toLowerCase());
  }
}

/** 与 LocalDictService.lookupDetail 完全一致的三级查找 */
function lookupDetail(word) {
  const key = (word || '').trim().toLowerCase();
  if (key.length === 0) return null;
  if (words.has(key)) {
    return { meaning: words.get(key).meaning, matchedWord: key, viaLemma: false };
  }
  if (alias.has(key)) {
    const base = alias.get(key);
    if (words.has(base)) {
      return { meaning: words.get(base).meaning, matchedWord: base, viaLemma: true };
    }
  }
  for (const c of lemmaCandidates(key)) {
    if (words.has(c)) {
      return { meaning: words.get(c).meaning, matchedWord: c, viaLemma: true };
    }
    if (alias.has(c)) {
      const b = alias.get(c);
      if (words.has(b)) {
        return { meaning: words.get(b).meaning, matchedWord: b, viaLemma: true };
      }
    }
  }
  return null;
}

/* ================= A. 词典文件结构 ================= */
group('[A] 词典文件结构');
check(raw.words.length === 36000, `A1 原形词条数应为 36000，实际 ${raw.words.length}`);
check(Object.keys(raw.alias || {}).length >= 25000,
  `A2 词形索引应 ≥25000 条，实际 ${Object.keys(raw.alias || {}).length}`);
check(words.size === 36000, `A3 原形去重后仍为 36000，实际 ${words.size}`);

let danglingAlias = 0;
for (const base of alias.values()) {
  if (!words.has(base)) danglingAlias += 1;
}
check(danglingAlias === 0, `A4 alias 指向的原形必须全部存在，悬空 ${danglingAlias} 条`);

const bytes = fs.statSync(DICT_PATH).size;
check(bytes < 4 * 1024 * 1024, `A5 词典体积应 <4MB，实际 ${(bytes / 1048576).toFixed(2)}MB`);
check(words.has('shatter'), 'A6 shatter 原形必须收录');
check(words.has('shattered'), 'A7 shattered 自带释义（a. 极度疲劳的；破碎的），应作为独立词条');
check(alias.get('gets') === 'get', 'A8 alias.gets 应指向 get');

/* ================= B. 真机缺席词全部可解析 ================= */
group('[B] 真机暴露的缺席词');
const MUST_RESOLVE = [
  'shattered', 'utterly', 'gets', 'executed', 'greatest', 'overheated',
  'embarrassment', 'defenses', 'done', 'nailed', 'hooked', 'moving',
  'boiled', 'crashing', 'dying', 'fried', 'broken', 'free', 'living', 'rent',
  'who', 'move', 'slack', 'rot', 'lie', 'flat', 'goat', 'brain', 'public', 'hook',
];
const unresolved = [];
for (const w of MUST_RESOLVE) {
  const hit = lookupDetail(w);
  if (hit === null || !hit.meaning || hit.meaning.trim().length === 0) {
    unresolved.push(w);
  }
}
check(unresolved.length === 0, `B1 以下词应能查到中文：${unresolved.join(', ')}`);

const gs = lookupDetail('gets');
check(gs !== null && gs.matchedWord === 'get', 'B2 gets 应命中原形 get');
check(gs !== null && gs.viaLemma === true, 'B3 gets 应标记 viaLemma');
const sh = lookupDetail('shattered');
check(sh !== null && sh.matchedWord === 'shattered' && sh.viaLemma === false,
  'B4 shattered 应直接命中（自带「极度疲劳的；破碎的」）');
check(sh !== null && /破碎|打碎|粉碎/.test(sh.meaning), 'B5 shattered 释义应含「破碎/打碎」');
const dn = lookupDetail('done');
check(dn !== null && dn.matchedWord === 'do', 'B5 done 应命中 do（不规则表兜底）');
const st = lookupDetail('who');
check(st !== null && st.viaLemma === false, 'B6 who 应直接命中（不标 viaLemma）');

// 释义必须是中文，不能是空串或英文
let nonChinese = 0;
for (const w of MUST_RESOLVE) {
  const hit = lookupDetail(w);
  if (hit !== null && !/[\u4e00-\u9fa5]/.test(hit.meaning)) nonChinese += 1;
}
check(nonChinese === 0, `B7 释义必须含汉字，违例 ${nonChinese} 条`);

/* ================= C. lemmaCandidates 规则 ================= */
group('[C] 规则还原');
const RULES = [
  ['nailed', 'nail'],
  ['executed', 'execute'],
  ['stopped', 'stop'],
  ['shattered', 'shatter'],
  ['studies', 'study'],
  ['boxes', 'box'],
  ['shelves', 'shelf'],
  ['moving', 'move'],
  ['running', 'run'],
  ['greatest', 'great'],
  ['bigger', 'big'],
  ['happily', 'happy'],
  ['easily', 'easy'],
  ['embarrassment', 'embarrass'],
  ['happiness', 'happy'],
  ['utterly', 'utter'],
  ['defenses', 'defense'],
  ['hooked', 'hook'],
  ['overheated', 'overheat'],
];
for (const [form, base] of RULES) {
  const c = lemmaCandidates(form);
  check(c.includes(base), `C1 ${form} 候选应含 ${base}，实际 [${c.join(', ')}]`);
}

group('[C2] 不规则表');
const IRREG = [
  ['done', 'do'], ['gets', 'get'], ['children', 'child'], ['better', 'good'],
  ['lying', 'lie'], ['dying', 'die'], ['broken', 'break'], ['flew', 'fly'],
];
for (const [form, base] of IRREG) {
  check(lemmaCandidates(form).includes(base), `C2 ${form} 应还原为 ${base}`);
}
check(IRREGULAR.get('done') === 'do', 'C3 IRREGULAR.done 应为 do');

/* ================= D. 保守性 ================= */
group('[D] 保守性');
check(!lemmaCandidates('cat').includes('cat'), 'D1 不得返回入参自身');
check(lemmaCandidates('go').length === 0, 'D2 三字母以内原形不乱还原');
check(lemmaCandidates('').length === 0, 'D3 空串返回空数组');
check(lemmaCandidates('   ').length === 0, 'D4 纯空白返回空数组');
check(lemmaCandidates('123').length === 0, 'D5 纯数字返回空数组');
for (const form of ['cat', 'dog', 'book', 'table', 'water']) {
  const c = lemmaCandidates(form);
  check(!c.includes(form), `D6 ${form} 候选不得含自身`);
}
// 候选去重
const dup = lemmaCandidates('stopped');
check(new Set(dup).size === dup.length, 'D7 候选列表不得重复');

/* ================= E. 梗表 slang 覆盖率 ================= */
group('[E] 梗表 slang 覆盖率');
const slangTokens = new Set();
for (const e of MEME_TABLE) {
  const w = primarySlang(e.slang);
  for (const t of tokenizeEnglish(w)) slangTokens.add(t);
}
const missSlang = [];
for (const t of slangTokens) {
  if (lookupDetail(t) === null) missSlang.push(t);
}
const coverRate = 1 - missSlang.length / Math.max(1, slangTokens.size);
check(coverRate >= 0.95,
  `E1 梗表 slang 释义覆盖率应 ≥95%，实际 ${(coverRate * 100).toFixed(1)}%（缺 ${missSlang.join(', ')}）`);
console.log(`  · slang token ${slangTokens.size} 个，未收录 ${missSlang.length} 个${missSlang.length ? '：' + missSlang.join(', ') : ''}`);

/* ================= F. 真实导入句覆盖 ================= */
group('[F] 真机验证用的句子');
const SENTENCE = "I'm utterly shattered. Who else gets this?";
const TOKENS = tokenizeEnglish(SENTENCE);
const missingWord = TOKENS.filter((t) => lookupDetail(t) === null);
check(TOKENS.length >= 3, `F1 应拆出 ≥3 词，实际 ${TOKENS.join(', ')}`);
check(missingWord.length === 0,
  `F2 真机句子「${SENTENCE}」全部词应有中文，缺：${missingWord.join(', ')}`);
for (const t of TOKENS) {
  const hit = lookupDetail(t);
  console.log(`  · ${t} → ${hit === null ? '(无)' : hit.meaning.slice(0, 34) + (hit.viaLemma ? ` [← ${hit.matchedWord}]` : '')}`);
}

/* ============ 汇总 ============ */
console.log(`\n${'─'.repeat(52)}`);
if (failed === 0) {
  console.log(`✅ 全部通过：${passed} 项断言`);
} else {
  console.log(`❌ ${failed} 项失败 / 共 ${passed + failed} 项`);
  for (const f of failures) console.log('   - ' + f);
  process.exit(1);
}
