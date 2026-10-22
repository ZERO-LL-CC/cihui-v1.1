/**
 * 词慧 F17「离线梗味翻译」Node 原生测试（零 npm 依赖）。
 * 运行：node --experimental-strip-types --no-warnings --import ./tests/register-loader.mjs tests/offline-translate.test.mjs
 *
 * 覆盖：
 * A. 表结构（MEME_TABLE 32 条 / PHRASE_BANK 10 条 / 字段非空）
 * B. 长词优先（破大防 不被截断；同句多梗按原文出现顺序）
 * C. L1 整句库 10 条全部命中且给英文
 * D. L2 梗词命中：level=MEME、rewrittenZh 含标准中文且不含梗词、hits 数量与顺序
 * E. L3 无命中：level=NONE、english 为空、needsManual=true
 * F. 边界：空串 / 纯空白 / 纯标点不崩
 * G. LITERAL 模式：不改写、仍能检测梗
 * H. 幂等：同输入两次结果一致
 */
import {
  MEME_TABLE,
  PHRASE_BANK,
  appendEnglish,
  normalizeZh,
  primarySlang,
  rewriteMeme,
  translateOffline,
} from '../entry/src/main/ets/model/OfflineTranslateCore.ts';
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

function eq(actual, expected, msg) {
  check(actual === expected, `${msg}（期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}）`);
}

function termsOf(hits) {
  return hits.map((h) => h.term);
}

/* ============ A. 表结构 ============ */
console.log('[A] 表结构');
eq(MEME_TABLE.length, 32, 'MEME_TABLE 应为 32 条');
// 整句库从 10 条扩到约 245 条（V1.2 止血：原库太小，自由输入必落空），
// 这里锁下限而不是精确值，后续继续补句不该让测试红。
check(PHRASE_BANK.length >= 200, `PHRASE_BANK 应 ≥200 条（实际 ${PHRASE_BANK.length}）`);
check(new Set(PHRASE_BANK.map((p) => p.zh)).size === PHRASE_BANK.length, 'PHRASE_BANK 中文不重复');
check(PHRASE_BANK.every((p) => p.zh.trim().length > 0 && p.en.trim().length > 0),
  'PHRASE_BANK 每条中英都非空');
check(PHRASE_BANK.every((p) => /[.?!]$/.test(p.en.trim())), 'PHRASE_BANK 英文都以标点收尾');
for (const e of MEME_TABLE) {
  check(e.term.length > 0 && e.standard.length > 0 && e.slang.length > 0,
    `梗词条目字段完整：${e.term}`);
}
for (const p of PHRASE_BANK) {
  check(p.zh.length > 0 && p.en.length > 0, `整句条目字段完整：${p.zh}`);
}
eq(primarySlang('this move / this play'), 'this move', 'primarySlang 取第一个候选');
eq(primarySlang('humblebrag'), 'humblebrag', 'primarySlang 无斜杠原样返回');

/* ============ A2. 归一化 ============ */
console.log('[A2] 归一化');
eq(normalizeZh('  这波操作太细了。  '), '这波操作太细了', '去空白与句末句号');
eq(normalizeZh('绝绝子，这家店真的香迷糊了！'), '绝绝子这家店真的香迷糊了', '标点（全角逗号/感叹号）全部剥掉');
eq(normalizeZh('"破防了，家人们谁懂啊"'), '破防了家人们谁懂啊', '引号/逗号/空白全部剥掉');
eq(normalizeZh('（破防了 家人们谁懂啊）'), '破防了家人们谁懂啊', '括号与空格全部剥掉');
eq(normalizeZh('，，。。'), '', '纯标点归一化为空串');

/* ============ B. 长词优先 ============ */
console.log('[B] 长词优先');
const b1 = rewriteMeme('我破大防了');
eq(b1.hits.length, 1, '「我破大防了」只应命中 1 个梗');
eq(b1.hits[0].term, '破大防', '「破大防」优先于短词，未被截断');
eq(b1.rewrittenZh.indexOf('破大防'), -1, '改写结果不应残留梗词「破大防」');
check(b1.rewrittenZh.indexOf('彻底绷不住了') >= 0, '改写结果应含标准中文「彻底绷不住了」');

const b2 = rewriteMeme('这波操作太细了');
eq(b2.hits.length, 2, '「这波操作太细了」应命中 2 个梗');
eq(JSON.stringify(termsOf(b2.hits)), JSON.stringify(['这波操作', '太细了']), '命中顺序按原文出现顺序');

const b3 = rewriteMeme('一顿操作猛如虎，一看工资两千五');
eq(b3.hits.length, 1, '「一顿操作猛如虎」为单一长梗');
eq(b3.hits[0].term, '一顿操作猛如虎', '长梗整体命中，不被「操作」类短片段劈开');

const b4 = rewriteMeme('破防了，家人们谁懂啊');
eq(JSON.stringify(termsOf(b4.hits)), JSON.stringify(['破防了', '家人们谁懂啊']), '多梗按出现顺序返回');

/* ============ C. L1 整句库 ============ */
console.log('[C] L1 整句库');
for (const p of PHRASE_BANK) {
  const r = translateOffline(p.zh, 'MEME');
  eq(r.level, 'SENTENCE', `整句命中 level：${p.zh}`);
  eq(r.english, p.en, `整句命中 english：${p.zh}`);
  eq(r.needsManual, false, `整句命中无需人工：${p.zh}`);
  check(r.message.length > 0, `整句命中带提示：${p.zh}`);
}
// 带标点/空白的输入也应命中（归一化后比对）
const c1 = translateOffline('  破防了，家人们谁懂啊！ ', 'MEME');
eq(c1.level, 'SENTENCE', '带空白与感叹号仍命中整句库');
eq(c1.english, 'I\'m utterly shattered. Who else gets this?', '带标点输入的英文与句库一致');

/* ============ D. L2 梗词脚手架 ============ */
console.log('[D] L2 梗词脚手架');
const d1 = translateOffline('破大防了，家人们谁懂啊', 'MEME');
eq(d1.level, 'MEME', '未入整句库但含梗 → level=MEME');
eq(d1.needsManual, true, 'L2 必须人工润色');
eq(d1.english, 'Utterly shattered my defenses. Who else gets this?', '多梗以「. 」分隔成合法短句');
eq(d1.hits.length, 2, 'L2 命中 2 个梗');
eq(JSON.stringify(termsOf(d1.hits)), JSON.stringify(['破大防', '家人们谁懂啊']), 'L2 命中顺序');
check(d1.rewrittenZh.indexOf('彻底绷不住了') >= 0, 'rewrittenZh 含标准中文');
check(d1.rewrittenZh.indexOf('破大防') < 0, 'rewrittenZh 不含梗词');

// 多梗 + 有实质中文片段：产出带占位符的脚手架
const d1b = translateOffline('破大防了，家人们谁懂啊，我今天社死', 'MEME');
eq(d1b.level, 'MEME', '多梗 + 待补片段 → MEME');
eq(d1b.english,
  'Utterly shattered my defenses. Who else gets this? [...] Die of embarrassment in public',
  '占位符后只补空格，不再给占位符加句号');
check(d1b.english.indexOf('[...]') >= 0, '实质中文片段用 [...] 占位');
eq(d1b.english.indexOf(' / '), -1, 'english 只用俚语首选，不带 "/" 多候选');

const d2 = translateOffline('家人们谁懂啊，我今天社死了', 'MEME');
eq(d2.level, 'MEME', '含未命中中文片段 → 仍为 MEME');
eq(d2.english, 'Who else gets this? [...] Die of embarrassment in public', '占位符后接空格，句间用句号');
check(d2.english.indexOf('[...]') >= 0, '未命中的实质中文用 [...] 占位');
check(d2.english.charAt(0) === d2.english.charAt(0).toUpperCase(), 'english 首字母大写');

const d3 = translateOffline('今天摸鱼了', 'MEME');
eq(d3.level, 'MEME', '单词梗也能命中');

/* ============ E. L3 未命中 ============ */
console.log('[E] L3 未命中');
const e1 = translateOffline('今天天气不错，我们去公园散步', 'MEME');
eq(e1.level, 'NONE', '无梗 → level=NONE');
eq(e1.english, '', '无梗不编造英文');
eq(e1.needsManual, true, '无梗必须人工填写');
eq(e1.hits.length, 0, '无梗 hits 为空');
check(e1.message.length > 0, '无梗给出提示文案');

/* ============ F. 边界输入 ============ */
console.log('[F] 边界输入');
const f1 = translateOffline('', 'MEME');
eq(f1.english, '', '空串 english 为空');
eq(f1.needsManual, true, '空串 needsManual=true');
eq(f1.level, 'NONE', '空串 level=NONE');

const f2 = translateOffline('   \t\n  ', 'MEME');
eq(f2.english, '', '纯空白 english 为空');
eq(f2.needsManual, true, '纯空白 needsManual=true');

const f3 = translateOffline('，。！？……（）', 'MEME');
eq(f3.english, '', '纯标点 english 为空');
eq(f3.needsManual, true, '纯标点 needsManual=true');
eq(f3.hits.length, 0, '纯标点无命中');

const f4 = translateOffline('yyds', 'MEME');
eq(f4.level, 'MEME', '英文梗 yyds 也能识别');

/* ============ G. LITERAL 模式 ============ */
console.log('[G] LITERAL 模式');
const g1 = translateOffline('破防了，家人们谁懂啊', 'LITERAL');
eq(g1.mode, 'LITERAL', 'mode 透传 LITERAL');
eq(g1.rewrittenZh, '破防了，家人们谁懂啊', 'LITERAL 不改写原文');
eq(g1.english, '', 'LITERAL 不产出英文');
eq(g1.hits.length, 2, 'LITERAL 仍检测到 2 个梗');
eq(g1.needsManual, true, 'LITERAL needsManual=true');

const g2 = translateOffline('今天天气不错', 'LITERAL');
eq(g2.hits.length, 0, 'LITERAL 无梗时 hits 为空');
eq(g2.level, 'NONE', 'LITERAL 无梗 level=NONE');

/* ============ H. 幂等 ============ */
console.log('[H] 幂等');
const input = '天天加班，卷生卷死，我想躺平了';
const h1 = translateOffline(input, 'MEME');
const h2 = translateOffline(input, 'MEME');
eq(JSON.stringify(h1), JSON.stringify(h2), '同一输入两次结果完全一致');

/* ============ I. QA Round 1 回归（BUG-1/2/3 + 低危） ============ */
console.log('[I] QA 回归');

// BUG-2：L1 头部标点未剥 / 句中标点缺失
const i1 = translateOffline('破防了家人们谁懂啊', 'MEME');
eq(i1.level, 'SENTENCE', '少打一个逗号仍命中整句库');
eq(i1.english, 'I\'m utterly shattered. Who else gets this?', '缺逗号命中的英文与原句一致');

const i2 = translateOffline('"破防了，家人们谁懂啊"', 'MEME');
eq(i2.level, 'SENTENCE', '整句被半角双引号包住仍命中');
eq(i2.english, 'I\'m utterly shattered. Who else gets this?', '引号包裹命中的英文一致');

const i2b = translateOffline('（破防了，家人们谁懂啊）', 'MEME');
eq(i2b.level, 'SENTENCE', '整句被全角括号包住仍命中');

const i3 = translateOffline('「绝绝子，这家店真的香迷糊了」', 'MEME');
eq(i3.level, 'SENTENCE', '整句被直角引号包住仍命中');

const i4 = translateOffline('破防了，家人们谁懂啊"', 'MEME');
eq(i4.level, 'SENTENCE', '仅尾部有引号仍命中');

// BUG-3：拉丁字母梗大小写不敏感
const i5 = translateOffline('YYDS', 'MEME');
eq(i5.level, 'MEME', 'YYDS 大写命中');
eq(i5.hits[0].term, 'yyds', '命中回填表内标准写法');
check(i5.rewrittenZh.indexOf('最棒的') >= 0, 'YYDS 改写为标准中文');

const i6 = translateOffline('cpu都干烧了', 'MEME');
eq(i6.level, 'MEME', 'cpu 小写命中 CPU都干烧了');
check(i6.english.toLowerCase().indexOf('brain overheated') >= 0, '小写命中同样产出俚语');

const i7 = translateOffline('芭比q', 'MEME');
eq(i7.hits.length, 1, '芭比q 小写命中');

const i8 = translateOffline('EMO了', 'MEME');
eq(i8.hits.length, 1, 'EMO了 大写命中');

// BUG-1：全梗句改用「. 」拼成合法短句，不再是空格硬拼的病句
const soupCases = [
  { zh: '摸鱼社死', en: 'Slack off at work. Die of embarrassment in public' },
  { zh: '躺平摆烂', en: 'Lie flat. Let it rot' },
];
for (const c of soupCases) {
  const r = translateOffline(c.zh, 'MEME');
  eq(r.level, 'MEME', `全梗句 level=MEME：${c.zh}`);
  eq(r.english, c.en, `全梗句以句号分隔成合法短句：${c.zh}`);
  check(r.hits.length >= 2, `全梗句 hits>=2：${c.zh}`);
  check(r.needsManual, `全梗句仍需人工润色：${c.zh}`);
}
// 其余全梗组合：非空 + 多句分隔 + 无空格硬拼
for (const input of ['内卷摆烂', '破防了社死', '摸鱼社死内卷']) {
  const r = translateOffline(input, 'MEME');
  eq(r.level, 'MEME', `全梗句 level=MEME：${input}`);
  check(r.english.length > 0, `全梗句给出英文：${input}`);
  check(r.english.indexOf('. ') >= 0, `全梗句以「. 」分隔：${input}`);
  check(r.hits.length >= 2, `全梗句 hits>=2：${input}`);
}

// 低危：非法 mode 不污染 TranslateMode 契约
eq(translateOffline('破防了', 'XXX').mode, 'MEME', '非法 mode 回落为 MEME');
eq(translateOffline('破防了', 'LITERAL').mode, 'LITERAL', '合法 mode 原样透传');

// 低危：无命中时不做叠字折叠
eq(rewriteMeme('啊啊啊').rewrittenZh, '啊啊啊', '无命中不改写原文（啊啊啊）');
eq(translateOffline('啊啊啊', 'MEME').rewrittenZh, '啊啊啊', 'L3 rewrittenZh 保留原文');

// 低危：LITERAL 的 rewrittenZh 等于原文（含首尾空白）
eq(translateOffline('  破防了  ', 'LITERAL').rewrittenZh, '  破防了  ', 'LITERAL 不改写也不 trim');

/* ============ J. 英文框追加（建议区点选） ============ */
console.log('[J] appendEnglish');
eq(appendEnglish('', 'slack off at work'), 'Slack off at work', '空框首字母大写');
eq(appendEnglish('Utterly shattered my defenses', 'who else gets this?'),
  'Utterly shattered my defenses. Who else gets this?', '前文无句末标点 → 补句号');
eq(appendEnglish('Who else gets this?', 'die of embarrassment in public'),
  'Who else gets this? Die of embarrassment in public', '前文以问号结尾 → 只补空格');
eq(appendEnglish('It broke me.', 'who else gets this?'),
  'It broke me. Who else gets this?', '前文以句号结尾 → 只补空格');
eq(appendEnglish('abc', ''), 'abc', '空片段不改动');
eq(appendEnglish('', ''), '', '双空安全');

// 模拟「点两次建议行」：不能再拼出无标点病句
let box = appendEnglish('', 'utterly shattered my defenses');
box = appendEnglish(box, 'who else gets this?');
eq(box, 'Utterly shattered my defenses. Who else gets this?', '连点两次得到句号分隔的合法短句');

// 必修 5 的数据侧锚点：单词英文拆不出 2 个可背词
eq(tokenizeEnglish('Done for').length, 1, '芭比q 的英文只拆出 1 个词，必须被 goConfirm 拦下');
eq(tokenizeEnglish('Lie flat. Let it rot').length, 4, '躺平摆烂 的英文可拆出 4 个词');
check(tokenizeEnglish('The GOAT (greatest of all time)').length >= 2, 'YYDS 英文可拆出 ≥2 个词');

/* ============ 汇总 ============ */
const total = passed + failed;
console.log(`\n[offline-translate] 通过 ${passed} / ${total} 项，失败 ${failed} 项`);
if (failed > 0) {
  console.error('\n失败明细：');
  for (const f of failures) {
    console.error(' - ' + f);
  }
  process.exit(1);
}
console.log('IS_PASS: YES');
