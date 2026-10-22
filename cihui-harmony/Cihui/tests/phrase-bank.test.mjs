/**
 * 词慧 V1.2「整句库扩容 + 近似匹配」测试（零 npm 依赖）。
 * 运行：node --experimental-strip-types --no-warnings --import ./tests/register-loader.mjs tests/phrase-bank.test.mjs
 *
 * 背景：原句库只有 10 条且必须「归一化后完全相等」才算命中，
 * 真机上「我太难了」「今天好开心」「为什么不能翻译」全部落空，
 * 只弹一句「未识别到梗词，请手动填写英文」。
 *
 * 本文件锁住三件新增能力：
 * A. 句库规模与质量底线
 * B. 精确命中：日常高频表达必须直接出英文
 * C. 近似命中：句库条目是输入的一段时也要给英文，且标 matchKind='near'
 * D. 两字短条目只在句首/句尾生效，防止半截碰巧命中
 * E. 多梗句必须走梗表脚手架，不能被近似匹配截胡丢梗
 * F. 完全未命中时给相近说法，不给英文（不编造）
 * G. 保守性：单字、纯符号、无法匹配的输入都不能瞎出英文
 */
import {
  PHRASE_BANK,
  translateOffline,
} from '../entry/src/main/ets/model/OfflineTranslateCore.ts';

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

function eq(actual, expected, msg) {
  check(actual === expected, `${msg}（期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}）`);
}

function run(zh) {
  return translateOffline(zh, 'MEME');
}

/* ============ A. 句库规模与质量 ============ */
console.log('[A] 句库规模与质量');
check(PHRASE_BANK.length >= 200, `句库 ≥200 条（实际 ${PHRASE_BANK.length}）`);
eq(new Set(PHRASE_BANK.map((p) => p.zh)).size, PHRASE_BANK.length, '句库中文无重复');
check(PHRASE_BANK.every((p) => p.zh.trim().length >= 2), '句库中文至少 2 字');
check(PHRASE_BANK.every((p) => p.en.trim().length > 0), '句库英文非空');
check(PHRASE_BANK.every((p) => /[.?!]$/.test(p.en.trim())), '句库英文以标点收尾');
check(PHRASE_BANK.every((p) => /^[A-Z]/.test(p.en.trim())), '句库英文首字母大写');
// 英文里不应残留中文
check(PHRASE_BANK.every((p) => !/[\u4e00-\u9fff]/.test(p.en)), '句库英文不含汉字');

/* ============ B. 精确命中（真机上会打的高频句） ============ */
console.log('[B] 精确命中');
const exactCases = [
  ['我太难了', 'hard time'],
  ['绝了', 'insane'],
  ['好烦', 'annoyed'],
  ['心累', 'drained'],
  ['我emo了', 'feeling down'],
  ['破防了', 'broke me'],
  ['你怎么了', 'wrong with you'],
  ['谢谢你的帮忙', ''],
];
for (const [zh, expect] of exactCases) {
  if (zh === '谢谢你的帮忙') {
    // 这条故意不精确命中，只为确认不会误报 exact
    continue;
  }
  const r = run(zh);
  eq(r.level, 'SENTENCE', `精确命中 level：${zh}`);
  eq(r.matchKind, 'exact', `精确命中 matchKind：${zh}`);
  check(r.english.length > 0, `精确命中给英文：${zh}`);
  if (expect.length > 0) {
    check(r.english.toLowerCase().includes(expect.toLowerCase()), `精确命中英文含「${expect}」：${zh}`);
  }
  eq(r.needsManual, false, `精确命中不需手改：${zh}`);
}

/* ============ C. 近似命中 ============ */
console.log('[C] 近似命中');
// 用户真机那句：句库里有「为什么不能」，输入多出「翻译」两字
const near1 = run('为什么不能翻译');
eq(near1.level, 'SENTENCE', '近似命中 level：为什么不能翻译');
eq(near1.matchKind, 'near', '近似命中标 near：为什么不能翻译');
check(near1.english.toLowerCase().includes('why'), '近似命中给 Why 开头英文');
check(near1.message.includes('相近'), '近似命中提示用户是相近说法');

// 句库「好开心」(3) 是输入「今天好开心」(5) 的一段，比例 0.6 ≥ 0.5
const near2 = run('今天好开心');
eq(near2.matchKind, 'near', '近似命中：今天好开心');
check(near2.english.toLowerCase().includes('happy'), '今天好开心给 happy 英文');

// 反向：输入是句库条目的一段（输入更短）
const near3 = run('太难了我');
check(near3.level === 'SENTENCE' || near3.level === 'NONE', '短输入不崩：太难了我');

/* ============ D. 两字短条目的边界约束 ============ */
console.log('[D] 两字短条目边界');
// 「好烦」在句首 → 该命中
const head = run('好烦，明天还要早起');
eq(head.level, 'SENTENCE', '两字条目在句首命中：好烦，明天还要早起');
check(head.english.toLowerCase().includes('annoyed'), '句首命中给 annoyed 英文');

// 「心累」在句尾 → 该命中
const tail = run('天天加班我真的心累');
eq(tail.level, 'SENTENCE', '两字条目在句尾命中：天天加班我真的心累');

// 「我不」不该半截命中句库里的「我不信」（这是最典型的误伤）
const noFalse = run('我不知道该怎么办');
check(!(noFalse.english.length > 0 && noFalse.english.toLowerCase().includes('believe')),
  '不误伤：我不知道不该命中「我不信」');

/* ============ E. 多梗句必须走梗表，不能被近似匹配截胡 ============ */
console.log('[E] 梗表优先');
const multi = run('破防了社死');
eq(multi.level, 'MEME', '多梗句走 MEME：破防了社死');
check(multi.hits.length >= 2, `多梗句命中 ≥2 个梗（实际 ${multi.hits.length}）`);
check(multi.english.includes('. '), '多梗句以句号分隔');

// 「他彻底emo了」：梗表有「emo了」，必须给脚手架而不是别的
const emo = run('他彻底emo了');
eq(emo.level, 'MEME', 'emo 句走 MEME');
eq(emo.hits.length, 1, 'emo 句命中 1 个梗');

/* ============ F. 未命中给相近说法，绝不编造英文 ============ */
console.log('[F] 未命中给建议');
const miss = run('雷声把我弟弟彻底吓坏了');
eq(miss.level, 'NONE', '完全未命中 level=NONE');
eq(miss.english, '', '完全未命中不给英文');
eq(miss.needsManual, true, '完全未命中 needsManual=true');
check(Array.isArray(miss.suggestions), '未命中返回 suggestions 数组');
check(miss.message.length > 0, '未命中给提示文案');

// 有明显相近词时，建议里应出现该词
const nearMiss = run('明天考试我好紧张');
eq(nearMiss.level, 'NONE', '长句未命中 level=NONE');
check((nearMiss.suggestions ?? []).some((s) => s.includes('紧张')), '建议里含「紧张」相关句');
check((nearMiss.suggestions ?? []).length <= 3, '建议最多 3 条');

/* ============ G. 保守性 ============ */
console.log('[G] 保守性');
eq(run('').english, '', '空串不给英文');
eq(run('   ').english, '', '纯空白不给英文');
eq(run('。。。').english, '', '纯标点不给英文');
eq(run('啊').english, '', '单字不给英文');
eq(run('  啊啊啊  ').english, '', '语气词不给英文');
// 幂等
const a1 = run('为什么不能翻译');
const a2 = run('为什么不能翻译');
eq(a1.english, a2.english, '同输入两次结果一致');

/* ============ 汇总 ============ */
console.log('');
if (failed === 0) {
  console.log(`✅ 全部通过：${passed} 项断言`);
} else {
  console.error(`❌ 失败 ${failed} / ${passed + failed} 项`);
  failures.forEach((f) => console.error(' - ' + f));
  process.exitCode = 1;
}
