/**
 * 词慧 F19+「每日例句 · 整段生成」纯函数层 Node 原生测试（零 npm 依赖）。
 * 运行：
 *   node --experimental-strip-types --no-warnings --import ./tests/register-loader.mjs tests/sentence-passage.test.mjs
 *
 * 覆盖（对应交付说明的 12 条必测）：
 * A. buildPassagePrompt：词表 english（释义）、JSON 示例、8~12 句要求、空词表不崩
 * B. parsePassagePayload：标准 JSON / ```json 围栏 + 前后解释 / 散文里孤立花括号（坑）
 * C. 单句字段缺失丢弃、全丢弃抛错、非 JSON 抛错
 * D. words 字段只保留词表内原词（小写去重）
 * E. computeCoverage：精确 / 词干（refused→refuse、encouraged→encourage）/ 前缀（improvement→improve）
 * F. missedWords 与 coverage 数值、两位小数、空词表、重复词、不做同义匹配
 * G. buildPatchPrompt：含未覆盖词 + 已有正文，要求保留原句只追加 2~3 句
 *
 * 断言器沿用 tests/ 里既有的极简风格（check / eq + 汇总 + process.exitCode），
 * 与 offline-translate / phrase-bank / scheduler 同一口径，方便 QA 一把跑完全套。
 */
import {
  PASSAGE_MIN_SENTENCES,
  PASSAGE_MAX_SENTENCES,
  PASSAGE_COVERAGE_TARGET,
  buildPassagePrompt,
  buildPatchPrompt,
  parsePassagePayload,
  computeCoverage,
  extractJsonObject,
} from '../entry/src/main/ets/model/SentenceCore.ts';

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
  const ok = actual === expected;
  if (!ok) {
    console.error(`  ✗ ${msg}（实际 ${JSON.stringify(actual)}，期望 ${JSON.stringify(expected)}）`);
  }
  check(ok, msg);
}

/* ============ 夹具 ============ */

/** 造一个合法 Word（字段与 Types.ts 的 Word 对齐） */
function w(english, meaning) {
  return {
    id: 'w-' + english,
    bookId: 'b1',
    english,
    phonetic: '',
    meanings: meaning ? [meaning] : [],
    source: 'MANUAL',
    missingMeaning: !meaning,
    diySupplement: false,
    createdAt: 0,
  };
}

/** 造一句 PassageSentence */
function s(sentence, translation, words) {
  return { sentence, translation, words: words || [] };
}

const WORDS = [w('refuse', '拒绝'), w('encourage', '鼓励'), w('improve', '改进'), w('campus', '校园')];

const STD_PASSAGE = JSON.stringify({
  title: 'A Day on Campus',
  sentences: [
    s('We refuse to give up.', '我们拒绝放弃。', ['refuse']),
    s('The teacher encouraged us.', '老师鼓励了我们。', ['encourage']),
  ],
});

/* ============ A. buildPassagePrompt ============ */
console.log('[A] buildPassagePrompt');
const prompt = buildPassagePrompt(WORDS);
check(prompt.includes('refuse') && prompt.includes('encourage')
  && prompt.includes('improve') && prompt.includes('campus'), 'Prompt 包含每个词的英文');
check(prompt.includes('拒绝') && prompt.includes('鼓励'), 'Prompt 包含中文释义');
check(prompt.includes('encourage（鼓励）'), '词表格式为 english（中文释义）');
check(prompt.includes('、'), '词表用「、」连接');
check(prompt.includes('8~12'), 'Prompt 写明 8~12 句');
check(prompt.includes('连贯'), 'Prompt 要求连贯短文而非孤立句');
check(prompt.includes('四级'), 'Prompt 指明四级难度');
check(prompt.includes('词形变化'), 'Prompt 允许词形变化');
check(prompt.includes('"title"') && prompt.includes('"sentences"') && prompt.includes('"translation"'),
  'Prompt 含 JSON 对象格式示例');
check(prompt.includes('不要输出任何解释性文字') && prompt.includes('markdown'),
  'Prompt 明确禁止解释文字与 markdown');
const emptyPrompt = buildPassagePrompt([]);
check(emptyPrompt.length > 0 && emptyPrompt.includes('"title"'), '空词表不崩且仍给出合法 Prompt');
eq(PASSAGE_MIN_SENTENCES, 8, '常量 PASSAGE_MIN_SENTENCES = 8');
eq(PASSAGE_MAX_SENTENCES, 12, '常量 PASSAGE_MAX_SENTENCES = 12');
eq(PASSAGE_COVERAGE_TARGET, 0.8, '常量 PASSAGE_COVERAGE_TARGET = 0.8');

/* ============ B. parsePassagePayload：标准 JSON ============ */
console.log('[B] parsePassagePayload 标准 JSON');
const r1 = parsePassagePayload(STD_PASSAGE, WORDS);
eq(r1.title, 'A Day on Campus', '标题解析正确');
eq(r1.sentences.length, 2, '两句都保留');
eq(r1.sentences[0].sentence, 'We refuse to give up.', '首句英文正确');
eq(r1.sentences[0].translation, '我们拒绝放弃。', '首句翻译正确');
eq(r1.sentences[0].words.join(','), 'refuse', '首句 words 保留词表内原词');
eq(r1.coverage, 0.5, '4 词覆盖 2 词 = 0.5');
eq(r1.coveredWords.join(','), 'refuse,encourage', 'coveredWords 按词表顺序');
eq(r1.missedWords.join(','), 'improve,campus', 'missedWords 为剩余两词');

/* ============ C. 围栏 + 解释文字 / 散文孤立花括号（坑） ============ */
console.log('[C] parsePassagePayload 容错');
const fenced = '好的，这是你要的短文：\n```json\n' + STD_PASSAGE + '\n```\n希望对你复习有帮助。';
const r2 = parsePassagePayload(fenced, WORDS);
eq(r2.title, 'A Day on Campus', '```json 围栏 + 前后解释仍能解析');
eq(r2.sentences.length, 2, '围栏场景句子数正确');

// 坑：解释文字里出现孤立 { }，朴素配平会从那个花括号一路吞到正文末尾
const braceProse = '输出格式如下：{ 这里是说明用的花括号，不是数据 }\n实际内容：\n'
  + STD_PASSAGE + '\n结束 }';
const r3 = parsePassagePayload(braceProse, WORDS);
eq(r3.title, 'A Day on Campus', '散文里的孤立花括号不影响提取');
eq(r3.sentences.length, 2, '散文孤立花括号场景句子数正确');
check(extractJsonObject(braceProse).startsWith('{"title"'), 'extractJsonObject 取到真正的 JSON 对象');

// 标题里带 } 与转义引号：字符串字面量必须被跳过
const weird = JSON.stringify({
  title: 'A {weird} "title"',
  sentences: [s('We refuse.', '我们拒绝。', ['refuse'])],
});
const r4 = parsePassagePayload(weird, WORDS);
eq(r4.title, 'A {weird} "title"', '标题内含 } 与转义引号也能正确配平');

// 模型退化成旧的数组格式 [{...}]：当「无标题整段」收下，不白丢内容
const legacyArray = JSON.stringify([
  s('He refused.', '他拒绝了。', ['refuse']),
  s('The teacher encouraged us.', '老师鼓励了我们。', ['encourage']),
]);
const rLegacy = parsePassagePayload(legacyArray, WORDS);
eq(rLegacy.title, '', '数组格式兼容，标题为空串');
eq(rLegacy.sentences.length, 2, '数组格式的两句都保留');
eq(rLegacy.coverage, 0.5, '数组格式同样计算覆盖率');

/* ============ D. 字段缺失丢弃 / 全丢弃抛错 / 非 JSON 抛错 ============ */
console.log('[D] parsePassagePayload 边界');
const partial = JSON.stringify({
  title: 'T',
  sentences: [
    s('He refused.', '他拒绝了。', ['refuse']),
    { sentence: 'Only English here.' },
    { translation: '只有中文' },
    'not-an-object',
  ],
});
const r5 = parsePassagePayload(partial, WORDS);
eq(r5.sentences.length, 1, '缺 translation / 缺 sentence / 非对象都被丢弃');
eq(r5.sentences[0].sentence, 'He refused.', '保留的那句是完整句');

let threwEmpty = false;
let emptyMsg = '';
try {
  parsePassagePayload(JSON.stringify({ title: 'T', sentences: [{ sentence: '' }, { translation: 'x' }] }), WORDS);
} catch (e) {
  threwEmpty = true;
  emptyMsg = e.message;
}
check(threwEmpty, '句子全被丢弃时必须抛错（不能返回空结果伪装成功）');
eq(emptyMsg, '模型返回中没有可用句子', '抛错文案可读');

let threwNoList = false;
try {
  parsePassagePayload(JSON.stringify({ title: 'T' }), WORDS);
} catch (e) {
  threwNoList = true;
}
check(threwNoList, '没有 sentences 字段也抛错');

let threwNotJson = false;
let notJsonMsg = '';
try {
  parsePassagePayload('模型今天心情不好，什么都没输出', WORDS);
} catch (e) {
  threwNotJson = true;
  notJsonMsg = e.message;
}
check(threwNotJson, '非 JSON 抛错');
eq(notJsonMsg, '模型返回不是合法 JSON', '非 JSON 错误文案可读');

/* ============ E. words 字段过滤 ============ */
console.log('[E] words 字段过滤');
const wordy = JSON.stringify({
  title: 'T',
  sentences: [s('We refuse to move.', '我们拒绝挪动。', ['refuse', 'banana', 'REFUSE', 'Improve'])],
});
const r6 = parsePassagePayload(wordy, WORDS);
eq(r6.sentences[0].words.join(','), 'refuse,improve', '词表外的词丢弃、同词去重、统一小写');

/* ============ F. computeCoverage：精确 ============ */
console.log('[F] computeCoverage 精确命中');
const covExact = computeCoverage([s('We refuse to give up.', '我们拒绝放弃。')], [w('refuse', '拒绝')]);
eq(covExact.coveredWords.join(','), 'refuse', '句中 token 与原词相同 → 覆盖');
eq(covExact.missedWords.length, 0, '精确命中后 missedWords 为空');
eq(covExact.coverage, 1, '全覆盖 coverage = 1');
eq(covExact.sentences.length, 1, 'sentences 原样带回');

/* ============ G. computeCoverage：词形变化 ============ */
console.log('[G] computeCoverage 词形变化');
const covForm = computeCoverage([
  s('He refused the offer.', '他拒绝了那个提议。'),
  s('The teacher encouraged us.', '老师鼓励了我们。'),
], [w('refuse', '拒绝'), w('encourage', '鼓励')]);
eq(covForm.coveredWords.length, 2, 'refused→refuse、encouraged→encourage 都算覆盖');
eq(covForm.coveredWords.join(','), 'refuse,encourage', 'coveredWords 顺序跟词表');
eq(covForm.missedWords.length, 0, '词形命中后没有 missedWords');
eq(covForm.coverage, 1, '词形全命中 coverage = 1');

// 词干不同、只能靠「前缀」命中的场景（improvement 剥后缀后不是 impro 词干）
const covPrefix = computeCoverage([
  s('Her English improved a lot.', '她的英语进步很大。'),
  s('The improvement is obvious.', '这个进步很明显。'),
], [w('improve', '改进')]);
eq(covPrefix.coveredWords.join(','), 'improve', 'improved / improvement 都靠词形关系命中 improve');

/* ============ H. computeCoverage：未命中与数值 ============ */
console.log('[H] computeCoverage 未命中与数值');
const covMiss = computeCoverage([s('He refused.', '他拒绝了。')], WORDS);
eq(covMiss.coveredWords.join(','), 'refuse', '只有 refused 命中 refuse');
eq(covMiss.missedWords.join(','), 'encourage,improve,campus', '未出现的词全部进 missedWords');
eq(covMiss.coverage, 0.25, '1/4 = 0.25');

const covRound = computeCoverage([s('We refuse.', '我们拒绝。')], [w('refuse'), w('encourage'), w('improve')]);
eq(covRound.coverage, 0.33, '1/3 保留两位小数 = 0.33');

const covEmpty = computeCoverage([s('Anything here.', '随便一句。')], []);
eq(covEmpty.coverage, 0, '空词表 coverage = 0 且不抛错');
eq(covEmpty.missedWords.length, 0, '空词表 missedWords 为空');
eq(covEmpty.coveredWords.length, 0, '空词表 coveredWords 为空');

const covDup = computeCoverage([s('We refuse.', '我们拒绝。')], [w('refuse'), w('refuse')]);
eq(covDup.coverage, 1, '同一词重复入批不拉低覆盖率');

const covWordsField = computeCoverage([s('They would not budge.', '他们不肯让步。', ['refuse'])], [w('refuse', '拒绝')]);
eq(covWordsField.coverage, 1, 'words 字段也是覆盖证据（正文没出现也算）');

const covNoSyn = computeCoverage([s('We said no.', '我们说不。')], [w('refuse', '拒绝')]);
eq(covNoSyn.coverage, 0, '不做同义/语义匹配，没出现就是没覆盖');
eq(covNoSyn.missedWords.join(','), 'refuse', '同义表达不进 coveredWords');

/* ============ I. buildPatchPrompt ============ */
console.log('[I] buildPatchPrompt');
const existing = parsePassagePayload(STD_PASSAGE, WORDS);
const missedForPatch = [w('campus', '校园'), w('improve', '改进')];
const patch = buildPatchPrompt(missedForPatch, existing);
check(patch.includes('campus') && patch.includes('校园'), '补漏 Prompt 含未覆盖词与释义');
check(patch.includes('improve') && patch.includes('改进'), '补漏 Prompt 含第二个未覆盖词');
check(patch.includes('We refuse to give up.'), '补漏 Prompt 含已有短文正文');
check(patch.includes('A Day on Campus'), '补漏 Prompt 含已有标题');
check(patch.includes('保持原有句子一字不改'), '补漏 Prompt 要求保留原句');
check(patch.includes('2~3'), '补漏 Prompt 要求追加 2~3 句');
check(patch.includes('"title"') && patch.includes('"sentences"'), '补漏 Prompt 仍是同一 JSON 结构');
check(!patch.includes('encourage（鼓励）'), '补漏 Prompt 不再要求已覆盖的词');

const patchEmpty = buildPatchPrompt([w('campus', '校园')], {
  title: '', sentences: [], coveredWords: [], missedWords: ['campus'], coverage: 0,
});
check(patchEmpty.length > 0 && patchEmpty.includes('campus'), '已有短文为空时补漏 Prompt 不崩');

/* ============ 汇总 ============ */
console.log('');
if (failed === 0) {
  console.log(`✅ 全部通过：${passed} 项断言`);
} else {
  console.error(`❌ 失败 ${failed} / ${passed + failed} 项`);
  failures.forEach((f) => console.error(' - ' + f));
  process.exitCode = 1;
}
