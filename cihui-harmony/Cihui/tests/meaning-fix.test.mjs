/**
 * 释义清洗与校正单测（Node 直跑纯逻辑，无需真机）。
 * 跑法：node --import ./tests/register-loader.mjs tests/meaning-fix.test.mjs
 */
import { readFileSync } from 'node:fs';
import {
  cleanForDisplay, fixMeanings, levenshtein, similarity,
  cleanMeaningsInData, auditMeaningsInData,
} from '../entry/src/main/ets/model/MeaningFix.ts';

let pass = 0;
let fail = 0;
function check(ok, name) {
  if (ok) { pass++; } else { fail++; console.log(`  ✗ ${name}`); }
}
function eq(actual, expect, name) {
  check(actual === expect, `${name}（实际 ${JSON.stringify(actual)}，期望 ${JSON.stringify(expect)}）`);
}

const raw = JSON.parse(readFileSync(
  new URL('../entry/src/main/resources/rawfile/dict/ecdict-lite.json', import.meta.url), 'utf8'));
const DICT = new Map(raw.words.map((w) => [w.w.toLowerCase(), w.m]));
const dictOf = (w) => DICT.get(w.toLowerCase()) ?? null;

console.log('[1] 清洗：OCR 残渣');
eq(cleanForDisplay('a. 精密的'), '精密的', '去英文词性');
eq(cleanForDisplay('[医] 腹[部]的'), '腹部的', '领域标签删除 + 补字保留');
eq(cleanForDisplay('控制(1)'), '控制', '去括号数字残渣');
eq(cleanForDisplay('给人切象深的(adi)'), '给人切象深的', '去括号字母残渣');
eq(cleanForDisplay('代表n)'), '代表', '去尾部残字与孤立右括号');
eq(cleanForDisplay('竞争(1'), '竞争', '去尾部残字与孤立左括号');
eq(cleanForDisplay('各种名样的lad))'), '各种名样的', '去连续残渣与括号');
eq(cleanForDisplay('n.&vt. 使重要'), '使重要', '连写词性');
eq(cleanForDisplay('赝品,模仿(n)'), '赝品,模仿', '括号词性后置');
eq(cleanForDisplay('DNA'), 'DNA', '纯英文释义不动');
eq(cleanForDisplay('<法>运动队'), '运动队', '尖括号标签删除');
eq(cleanForDisplay(': 摩尔人'), '摩尔人', '前导冒号');

console.log('[2] 清洗：不猜语义，重复字原样保留');
eq(cleanForDisplay('精精密的ladi'), '精精密的', '重复字保留（让用户看到自己录错了）');
eq(cleanForDisplay('常常'), '常常', '叠词不被折叠');

console.log('[3] 编辑距离');
eq(levenshtein('精密的', '精密的'), 0, '同串距离 0');
eq(levenshtein('精密的', '阴密的'), 1, '替换 1 字');
eq(levenshtein('分', '分配'), 1, '插入 1 字');
eq(levenshtein('', '分配'), 2, '空串距离 = 长度');
check(Math.abs(similarity('精密的', '阴密的') - 2 / 3) < 1e-9, '相似度 2/3');

console.log('[4] 判档：差 1 字直接改（AUTO）');
const a1 = fixMeanings(['给入深刻印象的'], dictOf('impressive'));
eq(a1.senses[0].action, 'AUTO', '差 1 字 → AUTO');
eq(a1.fixed[0], '给人深刻印象的', '改成词库原文');
const a2 = fixMeanings(['精确的'], dictOf('precise'));
check(a2.senses[0].action === 'AUTO' || a2.senses[0].action === 'KEEP', '精确的本就在词库里，不该被乱改');

console.log('[5] 判档：差 2~3 字只建议（ASK）');
const b1 = fixMeanings(['各种名样的'], dictOf('various'));
eq(b1.senses[0].action, 'ASK', '差 2 字 → ASK');
check(b1.fixed[0] === '各种名样的', 'ASK 不自动改，保留用户原值');
check(b1.ask.length === 1, 'ASK 列表有 1 条');

console.log('[6] 判档：完全不像 → 给整条建议，不自动改');
const c1 = fixMeanings(['给人切象深的', '有货储备物'], dictOf('impressive'));
eq(c1.senses[0].action, 'KEEP', '差太远不猜');
eq(c1.suggestAll, '给人深刻印象的，威严的', '整条建议取词库首段');
check(c1.fixed.join('|') !== '给人深刻印象的|威严的', '不自动替换');

console.log('[7] 反例：不相关的话不能自动改');
const d1 = fixMeanings(['我喜欢吃饭'], dictOf('precise'));
eq(d1.senses[0].action, 'KEEP', '不相干释义不动');
eq(fixMeanings(['苹果香蕉'], dictOf('govern')).senses[0].action, 'KEEP', '不相干释义不动（2）');

console.log('[8] 词库未收录：只清洗不猜');
const e1 = fixMeanings(['代表n)'], null);
eq(e1.senses[0].action, 'KEEP', '未收录不给建议');
eq(e1.fixed[0], '代表', '仍然清洗干净');
eq(e1.suggestAll, '', '无整条建议');

console.log('[9] 真机实例（用户手机上的真实脏数据）');
const cases = [
  ['sophisticated', ['精精密的ladi'], '精精密的'],
  ['impressive', ['给人切象深的(adi)', '有货储备物(n)', '竞争(1'], '给人切象深的|有货储备物|竞争'],
  ['representattve', ['代表n)'], '代表'],
  ['Various', ['各种名样的lad))'], '各种名样的'],
  ['govern', ['控制(1)'], '控制'],
  ['imitation', ['赝品,模仿(n)'], '赝品,模仿'],
  ['grasp', ['理解,领会(以)1)'], '理解,领会'],
  ['revenne', ['收入(n)'], '收入'],
  ['distribute', ['分'], '分'],
  ['precise', ['a. 精密的'], '精密的'],
  ['abdominal', ['[医] 腹[部]的'], '腹部的'],
];
for (const [w, ms, expect] of cases) {
  const r = fixMeanings(ms, dictOf(w));
  eq(r.fixed.join('|'), expect, `${w} 清洗结果`);
  r.senses.forEach((s) => check(s.suggestion.length > 0, `${w} 有可读建议`));
}

// 用户把多个正确义项写在一个字段里，不该被判成「录错」而弹出替换按钮
eq(fixMeanings(['赝品,模仿'], dictOf('imitation')).senses[0].action, 'KEEP', '多义项写一起不误报');
eq(fixMeanings(['模仿,赝品'], dictOf('imitation')).senses[0].action, 'KEEP', '多义项顺序不同也不误报');

console.log('[10] 批量：只清洗，不动语义');
const data = {
  words: [
    { id: 'w1', bookId: 'b1', english: 'precise', phonetic: '', meanings: ['a. 精密的'], source: 'DIY', missingMeaning: false, diySupplement: false, createdAt: 0 },
    { id: 'w2', bookId: 'b1', english: 'clean', phonetic: '', meanings: ['干净的'], source: 'DIY', missingMeaning: false, diySupplement: false, createdAt: 0 },
  ],
  schedules: [], records: [], books: [], settings: {}, memeCards: [], sessions: [], checkins: [],
};
const cleaned = cleanMeaningsInData(data);
check(cleaned !== null, '有脏数据时返回新数据');
eq(cleaned.words[0].meanings[0], '精密的', '清洗后义项');
eq(cleaned.words[1].meanings[0], '干净的', '干净数据保持不变');
check(cleanMeaningsInData(cleaned) === null, '已清洗过的数据不再变更（幂等）');

console.log('[11] 批量：词库纠错只写 AUTO');
const data2 = {
  words: [
    { id: 'w1', bookId: 'b1', english: 'impressive', phonetic: '', meanings: ['给入深刻印象的'], source: 'DIY', missingMeaning: false, diySupplement: false, createdAt: 0 },
    { id: 'w2', bookId: 'b1', english: 'various', phonetic: '', meanings: ['各种名样的'], source: 'DIY', missingMeaning: false, diySupplement: false, createdAt: 0 },
    { id: 'w3', bookId: 'b1', english: 'govern', phonetic: '', meanings: ['控制'], source: 'DIY', missingMeaning: false, diySupplement: true, createdAt: 0 },
  ],
  schedules: [], records: [], books: [], settings: {}, memeCards: [], sessions: [], checkins: [],
};
const audited = auditMeaningsInData(data2, (w) => dictOf(w));
check(audited !== null, '有变更返回新数据');
eq(audited.words[0].meanings[0], '给人深刻印象的', 'AUTO：差 1 字改成词库原文');
eq(audited.words[1].meanings[0], '各种名样的', 'ASK：不自动改');
eq(audited.words[2].meanings[0], '控制', 'diySupplement 不自动改');
check(auditMeaningsInData(audited, (w) => dictOf(w)) === null, '二次审计无变更（幂等）');

console.log('[12] 全库回归：注入 1 个错字应被自动改回');
let injected = 0;
let fixedBack = 0;
for (let i = 0; i < raw.words.length; i += 17) {
  const w = raw.words[i];
  const senses = fixMeanings([w.m], w.m).senses;
  const std = senses.filter((s) => /^[\u4e00-\u9fa5]{3,}$/.test(s.cleaned))[0];
  if (!std) { continue; }
  const broken = std.cleaned[0] + '错' + std.cleaned.slice(2);
  const r = fixMeanings([broken], w.m);
  injected++;
  if (r.senses[0].action === 'AUTO' && r.fixed[0] === std.cleaned) { fixedBack++; }
}
check(injected > 50, `注入样本足够（${injected}）`);
check(fixedBack / injected > 0.9, `自动改回率 ${(fixedBack / injected * 100).toFixed(1)}% > 90%`);

console.log(`[词慧释义清洗测试] 通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail > 0 ? 1 : 0);
