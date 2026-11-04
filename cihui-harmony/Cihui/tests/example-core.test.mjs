/**
 * 离线例句拼装单测（Node 直跑纯逻辑，无需真机）。
 * 跑法：node --import ./tests/register-loader.mjs tests/example-core.test.mjs
 *
 * 死守的几条：
 * - 一个词一条，缺例句的词进 missedWords，不拖累其它词
 * - 覆盖率算法 = 覆盖数 / 总词数（保留两位）
 * - 空英文/空中文都算没有例句（宁可少一条，不给空白卡）
 */
import { buildWordPassage } from '../entry/src/main/ets/model/ExampleCore.ts';

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

function w(english, id = '') {
  return {
    id: id || english, bookId: 'b1', english, phonetic: '', meanings: ['测试'],
    source: 'CLOUD', missingMeaning: false, diySupplement: false, createdAt: 0,
  };
}

const DICT = {
  abandon: { en: 'He had to abandon his car in the snow.', zh: '他不得不把车丢在雪地里。' },
  ability: { en: 'She has the ability to solve hard problems.', zh: '她有解决难题的能力。' },
  precise: { en: 'Please give me a precise answer.', zh: '请给我一个准确的答复。' },
};

function lookup(word) {
  const hit = DICT[word.english.trim().toLowerCase()];
  return hit === undefined ? null : hit;
}

// 1. 全部命中
{
  const r = buildWordPassage([w('abandon'), w('ability')], lookup);
  eq('全覆盖 sentences 数', r.sentences.length, 2);
  eq('全覆盖 covered', r.coveredWords, ['abandon', 'ability']);
  eq('全覆盖 missed', r.missedWords, []);
  eq('全覆盖 coverage', r.coverage, 1);
  eq('title 为空', r.title, '');
  eq('一条句子的词标签', r.sentences[0].words, ['abandon']);
  eq('英文原样带过来', r.sentences[0].sentence, DICT.abandon.en);
  eq('中文原样带过来', r.sentences[0].translation, DICT.abandon.zh);
}

// 2. 部分缺失
{
  const r = buildWordPassage([w('abandon'), w('zzzunknown'), w('precise')], lookup);
  eq('部分覆盖 sentences 数', r.sentences.length, 2);
  eq('部分覆盖 missed', r.missedWords, ['zzzunknown']);
  eq('部分覆盖 coverage', r.coverage, 0.67);
}

// 3. 一个都没有
{
  const r = buildWordPassage([w('qqq'), w('www')], lookup);
  eq('全缺 sentences 数', r.sentences.length, 0);
  eq('全缺 coverage', r.coverage, 0);
  eq('全缺 missed 数', r.missedWords.length, 2);
}

// 4. 空词表不炸
{
  const r = buildWordPassage([], lookup);
  eq('空词表 coverage', r.coverage, 0);
  eq('空词表 sentences', r.sentences, []);
}

// 5. 大小写与前后空格要能命中
{
  const r = buildWordPassage([w(' Abandon ')], lookup);
  eq('大小写空格命中', r.coveredWords, ['abandon']);
  eq('句子仍非空', r.sentences.length, 1);
}

// 6. 有 key 但英文/中文为空 -> 算缺失（不给空白卡）
{
  const bad = { abandon: { en: '   ', zh: '中文' }, ability: { en: 'A sentence.', zh: '' } };
  const r = buildWordPassage([w('abandon'), w('ability')], (x) => {
    const h = bad[x.english.trim().toLowerCase()];
    return h === undefined ? null : h;
  });
  eq('空英文和空中文都算缺失', r.missedWords, ['abandon', 'ability']);
  eq('缺失总数对得上', r.missedWords.length + r.coveredWords.length, 2);
  eq('空内容不生成句子', r.sentences.length, 0);
}

// 7. 顺序保持（例句顺序 = 传入词顺序）
{
  const r = buildWordPassage([w('precise'), w('abandon')], lookup);
  eq('顺序保持', r.coveredWords, ['precise', 'abandon']);
  eq('句子顺序保持', r.sentences[0].sentence, DICT.precise.en);
}

// 8. 覆盖率两位小数
{
  const r = buildWordPassage([w('abandon'), w('x1'), w('x2')], lookup);
  eq('1/3 覆盖率', r.coverage, 0.33);
}

console.log(`\n通过 ${pass}，失败 ${fail}`);
if (fail > 0) {
  process.exit(1);
}
