/**
 * OCR 行解析单测（纯逻辑，无需真机）。
 * 跑法：node --import ./tests/register-loader.mjs tests/ocr-parser.test.mjs
 *
 * 重点锁住「词性缩写」：词表里 adj. 常写成 a.，漏认它整行中文会被判成「无中文」，
 * 后续选词页就会把它当成缺释义去词库补全，用户拍的释义白白丢掉。
 */
import { parseOcrLines, tokenizeEnglishWords } from '../entry/src/main/ets/service/OcrParser.ts';

let pass = 0;
let fail = 0;
function check(ok, name) {
  if (ok) { pass++; } else { fail++; console.log(`  ✗ ${name}`); }
}
function eq(actual, expect, name) {
  check(actual === expect, `${name}（实际 ${JSON.stringify(actual)}，期望 ${JSON.stringify(expect)}）`);
}

const first = (line) => {
  const d = parseOcrLines([line]);
  return d.length > 0 ? d[0] : null;
};

console.log('[1] 词性缩写都要能认出来');
const posCases = [
  ['various a. 各种的', 'various', '各种的', 'a. = adj.'],
  ['precise adj. 精密的', 'precise', '精密的', 'adj.'],
  ['abandon v. 放弃', 'abandon', '放弃', 'v.'],
  ['govern vt. 统治', 'govern', '统治', 'vt.'],
  ['image n. 图像', 'image', '图像', 'n.'],
  ['quickly adv. 快速地', 'quickly', '快速地', 'adv.'],
  ['significant a. 重要的, 重大的', 'significant', '重要的, 重大的', 'a. + 多义项'],
];
for (const [line, en, zh, name] of posCases) {
  const d = first(line);
  check(d !== null, `${name}：解析出词条`);
  if (d === null) { continue; }
  eq(d.english, en, `${name}：英文`);
  eq(d.meaning, zh, `${name}：中文`);
}

console.log('[2] 带音标与序号前缀');
{
  const d = first('abandon /əˈbændən/ v. 放弃；抛弃');
  check(d !== null, '音标行可解析');
  eq(d.english, 'abandon', '音标不干扰英文');
  eq(d.meaning, '放弃；抛弃', '中文保留多义项分隔');
  const numbered = first('1. abandon v. 放弃');
  check(numbered !== null, '序号前缀行可解析');
  eq(numbered.english, 'abandon', '序号被剥离');
}
{
  const d = first('take off v. 起飞');
  check(d !== null, '短语可解析');
  eq(d.english, 'take off', '短语英文完整');
  eq(d.meaning, '起飞', '短语中文');
}

console.log('[3] 噪声行与非词条行');
{
  const d = parseOcrLines(['Unit 1 Words and Expressions']);
  check(d.length === 0, '单元标题行被丢弃');
  const d2 = first('n.');
  check(d2 === null || d2.meaning === '', '只有词性的行不给中文');
}

console.log('[4] 选词用的 token 提取与去重');
{
  const toks = tokenizeEnglishWords([
    'abandon v. 放弃',
    'abandon v. 放弃',
    'govern v. 统治',
    'Unit 2',
  ]);
  check(toks.includes('abandon'), '提取到 abandon');
  check(toks.includes('govern'), '提取到 govern');
  eq(toks.filter((t) => t === 'abandon').length, 1, '同一个词只出现一次');
  check(!toks.includes('Unit'), '单元标题不当成单词');
}

console.log(`[词慧OCR解析测试] 通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail > 0 ? 1 : 0);
